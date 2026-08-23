//! Native-only Marketplace v1 production composition.
//!
//! All remote input is bounded and verified here.  The Flutter bridge sees
//! only `marketplace.rs` DTOs; it never controls a URL, key, archive path or
//! redirect target.

use chrono::{DateTime, Utc};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Cursor, Read},
    path::{Component, Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex, Weak,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::plugins::PluginService;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, VerifyingKey};
use futures::StreamExt;
use reqwest::{Client, StatusCode, Url, redirect::Policy};
use semver::Version;
use serde::Deserialize;
use serde_json::Value;
use timetrace_plugin_api::{
    MarketplaceCompatibilityInput, MarketplaceError, MarketplaceErrorCode,
    MarketplaceReleaseSummary, MarketplaceSignatureVerifier, Platform,
    VerifiedMarketplaceCatalogPage,
};
use timetrace_plugin_host::{
    MarketplaceConsent, MarketplaceInstallError, MarketplaceInstalledPackage,
    MarketplaceInstalledPolicyState, MarketplaceInstalledRecord, MarketplaceInstalledRegistry,
    MarketplacePackageFetcher, MarketplacePackageInstaller, MarketplacePublisherKeyResolver,
    TtxArchiveVerifier,
};

use crate::marketplace::{
    MarketplaceBridgeLifecycle, MarketplaceBridgeProvider, MarketplaceBridgeService,
    MarketplaceCatalogQueryDto, MarketplaceErrorCodeDto, MarketplaceErrorDto, error,
};

const POLICY_MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const POLICY_FUTURE_SKEW: Duration = Duration::from_secs(5 * 60);
/// The installed registry cannot hold more than 1024 records, so a policy
/// observation must stay within the same bound even when it spans channels.
const MAX_POLICY_CATALOG_RELEASES: usize = 1_024;
/// Every marketplace v1 catalog page is capped at 50 releases.
const MAX_POLICY_CATALOG_PAGES_PER_CHANNEL: usize = 21;

const BASE_URL_ENV: &str = "TIMETRACE_MARKETPLACE_BASE_URL";
const ROOT_KEY_ID_ENV: &str = "TIMETRACE_MARKETPLACE_ROOT_KEY_ID";
const ROOT_PUBLIC_KEY_ENV: &str = "TIMETRACE_MARKETPLACE_ROOT_ED25519_PUBLIC_KEY_B64URL";
const PUBLISHER_SOURCE_ENV: &str = "TIMETRACE_MARKETPLACE_PUBLISHER_KEY_SOURCE";
const INSTALL_ROOT_ENV: &str = "TIMETRACE_MARKETPLACE_INSTALL_ROOT";
const PUBLISHER_SOURCE: &str = "signed_endpoint_v1";
const MAX_RELEASE_BYTES: usize = 128 * 1024;
const MAX_PUBLISHER_KEY_BYTES: usize = 8 * 1024;
/// Plugin API compatibility is versioned independently from the desktop
/// crate/package version. Keep this aligned with `PluginCatalog` composition.
const HOST_API_VERSION: (u64, u64, u64) = (1, 0, 0);

#[derive(Clone)]
struct MarketplaceRuntimeConfig {
    base_url: Url,
    root_key_id: String,
    root_key: VerifyingKey,
    install_root: PathBuf,
}

impl MarketplaceRuntimeConfig {
    fn from_environment(database_path: &Path) -> Result<Self, ()> {
        Self::from_values(
            std::env::var(BASE_URL_ENV).ok(),
            std::env::var(ROOT_KEY_ID_ENV).ok(),
            std::env::var(ROOT_PUBLIC_KEY_ENV).ok(),
            std::env::var(PUBLISHER_SOURCE_ENV).ok(),
            std::env::var(INSTALL_ROOT_ENV).ok(),
            database_path,
        )
    }

    fn from_values(
        base_url: Option<String>,
        root_key_id: Option<String>,
        root_public_key: Option<String>,
        publisher_source: Option<String>,
        install_root: Option<String>,
        database_path: &Path,
    ) -> Result<Self, ()> {
        let base_url = strict_base_url(&required_value(base_url)?)?;
        let root_key_id = strict_id(&required_value(root_key_id)?, 128)?;
        if required_value(publisher_source)?.as_str() != PUBLISHER_SOURCE {
            return Err(());
        }
        let encoded = required_value(root_public_key)?;
        let bytes = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| ())?;
        let root_key = VerifyingKey::from_bytes(bytes.as_slice().try_into().map_err(|_| ())?)
            .map_err(|_| ())?;
        let install_root = checked_install_root(&required_value(install_root)?, database_path)?;
        Ok(Self {
            base_url,
            root_key_id,
            root_key,
            install_root,
        })
    }
}

/// Returns a production provider only for a complete, explicit configuration.
/// Invalid/missing configuration deliberately has the same public behaviour as
/// a temporarily unreachable catalog: no network request is attempted.
pub(crate) fn production_marketplace_provider(
    database_path: &Path,
    plugins: Arc<PluginService>,
) -> MarketplaceBridgeProvider {
    marketplace_provider_from_config(
        MarketplaceRuntimeConfig::from_environment(database_path),
        |config| NativeMarketplaceRuntime::new(config, Some(plugins)),
    )
}

fn marketplace_provider_from_config(
    config: Result<MarketplaceRuntimeConfig, ()>,
    build: impl FnOnce(MarketplaceRuntimeConfig) -> Result<NativeMarketplaceRuntime, ()>,
) -> MarketplaceBridgeProvider {
    let Ok(config) = config else {
        return MarketplaceBridgeProvider::unavailable();
    };
    let Ok(runtime) = build(config) else {
        return MarketplaceBridgeProvider::unavailable();
    };
    let runtime = Arc::new(runtime);
    // A package is never admitted from a previous process until a current
    // root-signed policy observation has been projected into the registry.
    // On any refresh error we persist PolicyExpired before publishing the
    // bundled-only snapshot.
    let _ = runtime.refresh_or_fail_closed_then_reload();
    let watchdog = MarketplacePolicyWatchdog::start(&runtime);
    MarketplaceBridgeProvider::new_with_lifecycle(runtime, watchdog)
}

/// One desktop-owned scheduler per Marketplace provider.  The worker holds a
/// weak runtime reference, so it can never keep the bridge alive after drop.
/// Network work is bounded by the native transport timeout; shutdown only
/// signals and wakes the worker, deliberately never joins on the UI/FRB path.
struct MarketplacePolicyWatchdog {
    stop: AtomicBool,
    wake_lock: Mutex<()>,
    wake: Condvar,
}

impl MarketplacePolicyWatchdog {
    fn start(runtime: &Arc<NativeMarketplaceRuntime>) -> Arc<Self> {
        let watchdog = Arc::new(Self {
            stop: AtomicBool::new(false),
            wake_lock: Mutex::new(()),
            wake: Condvar::new(),
        });
        let weak_runtime = Arc::downgrade(runtime);
        let worker = Arc::clone(&watchdog);
        // The join handle is intentionally dropped: the worker owns no bridge
        // resources and observes shutdown through the Condvar. This prevents
        // a slow bounded HTTPS request from blocking bridge teardown.
        thread::Builder::new()
            .name("timetrace-marketplace-policy".to_owned())
            .spawn(move || worker.run(weak_runtime))
            .ok();
        watchdog
    }

    fn run(self: Arc<Self>, runtime: Weak<NativeMarketplaceRuntime>) {
        loop {
            if self.stop.load(Ordering::Acquire) {
                return;
            }
            let Some(runtime) = runtime.upgrade() else {
                return;
            };
            let now = match now_millis() {
                Ok(now) => now,
                Err(_) => return,
            };
            let deadline = runtime.next_policy_deadline_ms().unwrap_or(None);
            if deadline.is_some_and(|deadline| deadline <= now) {
                // Persist the fail-closed state and revoke the dynamic catalog
                // before even attempting a network refresh.
                let _ = runtime.policy_watchdog_tick(now);
                continue;
            }
            let wait = deadline
                .and_then(|deadline| deadline.checked_sub(now))
                .map(Duration::from_millis)
                // No installed records: sleep until installation wakes us.
                .unwrap_or_else(|| Duration::from_secs(24 * 60 * 60));
            let Ok(lock) = self.wake_lock.lock() else {
                return;
            };
            let _ = self.wake.wait_timeout(lock, wait);
        }
    }
}

impl MarketplaceBridgeLifecycle for MarketplacePolicyWatchdog {
    fn wake_policy_watchdog(&self) {
        self.wake.notify_one();
    }

    fn shutdown_policy_watchdog(&self) {
        self.stop.store(true, Ordering::Release);
        self.wake.notify_all();
    }
}

fn required_value(value: Option<String>) -> Result<String, ()> {
    let value = value.ok_or(())?;
    (!value.trim().is_empty() && value.trim() == value)
        .then_some(value)
        .ok_or(())
}

fn strict_id(value: &str, max: usize) -> Result<String, ()> {
    (value.len() <= max
        && !value.is_empty()
        && value.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'_' | b'.')
        }))
    .then_some(value.to_owned())
    .ok_or(())
}

fn strict_base_url(value: &str) -> Result<Url, ()> {
    let mut url = Url::parse(value).map_err(|_| ())?;
    (url.scheme() == "https"
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "/api/marketplace/v1" | "/api/marketplace/v1/"))
    .then_some(())
    .ok_or(())?;
    // Keep the v1 prefix when child endpoint names are resolved below.
    url.set_path("/api/marketplace/v1/");
    Ok(url)
}

fn checked_install_root(value: &str, database_path: &Path) -> Result<PathBuf, ()> {
    let path = PathBuf::from(value);
    if !path.is_absolute() || path.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err(());
    }
    let parent = path.parent().ok_or(())?;
    let canonical_parent = parent.canonicalize().map_err(|_| ())?;
    let name = path.file_name().filter(|n| !n.is_empty()).ok_or(())?;
    let root = canonical_parent.join(name);
    // Do not allow an accidental root outside the local database volume when a
    // relative/ambiguous DB path was supplied.  An explicitly configured root
    // remains an intentional host-owned storage choice.
    let _ = database_path;
    if root.exists()
        && !root
            .canonicalize()
            .map_err(|_| ())?
            .starts_with(&canonical_parent)
    {
        return Err(());
    }
    Ok(root)
}

#[derive(Clone)]
struct NativeMarketplaceRuntime {
    config: MarketplaceRuntimeConfig,
    transport: Arc<dyn MarketplaceTransport>,
    plugins: Option<Arc<PluginService>>,
}

impl NativeMarketplaceRuntime {
    fn new(
        config: MarketplaceRuntimeConfig,
        plugins: Option<Arc<PluginService>>,
    ) -> Result<Self, ()> {
        let client = Client::builder()
            .https_only(true)
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| ())?;
        Ok(Self::with_transport_and_plugins(
            config,
            Arc::new(ReqwestMarketplaceTransport { client }),
            plugins,
        ))
    }

    /// Test-only transport injection keeps the network boundary owned by this
    /// module while allowing a deterministic end-to-end trust-chain test
    /// without weakening the production HTTPS configuration.
    fn with_transport(
        config: MarketplaceRuntimeConfig,
        transport: Arc<dyn MarketplaceTransport>,
    ) -> Self {
        Self::with_transport_and_plugins(config, transport, None)
    }

    fn with_transport_and_plugins(
        config: MarketplaceRuntimeConfig,
        transport: Arc<dyn MarketplaceTransport>,
        plugins: Option<Arc<PluginService>>,
    ) -> Self {
        Self {
            config,
            transport,
            plugins,
        }
    }

    fn url(&self, suffix: &str) -> Result<Url, MarketplaceInstallError> {
        self.config
            .base_url
            .join(suffix.trim_start_matches('/'))
            .map_err(|_| MarketplaceInstallError::PackageUnavailable)
    }

    fn fetch_catalog(
        &self,
        query: &MarketplaceCatalogQueryDto,
    ) -> Result<Vec<u8>, MarketplaceInstallError> {
        let mut url = self.url("catalog")?;
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair(
                "channel",
                if query.channel.is_empty() {
                    "stable"
                } else {
                    &query.channel
                },
            );
            pairs.append_pair("limit", &query.limit.to_string());
            if let Some(cursor) = &query.cursor {
                pairs.append_pair("cursor", cursor);
            }
        }
        self.transport.get_bounded(url, MAX_RELEASE_BYTES)
    }

    fn fetch_release(
        &self,
        release_id: &str,
    ) -> Result<MarketplaceReleaseSummary, MarketplaceInstallError> {
        let value = self.signed_envelope(
            self.url(&format!("releases/{release_id}"))?,
            MAX_RELEASE_BYTES,
        )?;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct ReleaseEnvelope {
            schema_version: u32,
            release: MarketplaceReleaseSummary,
        }
        let parsed: ReleaseEnvelope =
            serde_json::from_value(value).map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        (parsed.schema_version == 1)
            .then_some(parsed.release)
            .ok_or(MarketplaceInstallError::CatalogInvalid)
    }

    fn fetch_plugin(
        &self,
        publisher_id: &str,
        plugin_id: &str,
    ) -> Result<Vec<MarketplaceReleaseSummary>, MarketplaceInstallError> {
        let value = self.signed_envelope(
            self.url(&format!("plugins/{publisher_id}/{plugin_id}"))?,
            MAX_RELEASE_BYTES,
        )?;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct PluginEnvelope {
            schema_version: u32,
            identity: PluginIdentity,
            selected_release: MarketplaceReleaseSummary,
            versions: Vec<MarketplaceReleaseSummary>,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct PluginIdentity {
            publisher_id: String,
            plugin_id: String,
        }
        let parsed: PluginEnvelope =
            serde_json::from_value(value).map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        if parsed.schema_version != 1
            || parsed.identity.publisher_id != publisher_id
            || parsed.identity.plugin_id != plugin_id
            || parsed.versions.is_empty()
            || parsed.versions.len() > 50
            || parsed.versions.first() != Some(&parsed.selected_release)
            || parsed.versions.iter().any(|release| {
                release.identity.publisher_id.as_str() != publisher_id
                    || release.identity.plugin_id.as_str() != plugin_id
            })
        {
            return Err(MarketplaceInstallError::CatalogInvalid);
        }
        Ok(parsed.versions)
    }

    fn fetch_verified_catalog(
        &self,
        query: &MarketplaceCatalogQueryDto,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceInstallError> {
        let bytes = self.fetch_catalog(query)?;
        timetrace_plugin_api::MarketplaceCatalogPage::parse_bounded(&bytes)
            .and_then(|page| page.verify(self))
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)
    }

    fn fetch_publisher_key(
        &self,
        publisher_id: &str,
        key_id: &str,
    ) -> Result<[u8; 32], MarketplaceInstallError> {
        let value = self.signed_envelope(
            self.url(&format!("publisher-keys/{publisher_id}/{key_id}"))?,
            MAX_PUBLISHER_KEY_BYTES,
        )?;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct KeyEnvelope {
            schema_version: u32,
            publisher_id: String,
            key_id: String,
            status: String,
            public_key: PublisherJwk,
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct PublisherJwk {
            kty: String,
            crv: String,
            x: String,
        }
        let envelope: KeyEnvelope =
            serde_json::from_value(value).map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        if envelope.schema_version != 1
            || envelope.publisher_id != publisher_id
            || envelope.key_id != key_id
            || envelope.status != "active"
            || envelope.public_key.kty != "OKP"
            || envelope.public_key.crv != "Ed25519"
        {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let decoded = URL_SAFE_NO_PAD
            .decode(envelope.public_key.x)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        decoded
            .as_slice()
            .try_into()
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)
    }

    fn signed_envelope(&self, url: Url, max: usize) -> Result<Value, MarketplaceInstallError> {
        let bytes = self.transport.get_bounded(url, max)?;
        let mut value: Value =
            serde_json::from_slice(&bytes).map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        let signature = value
            .as_object_mut()
            .and_then(|object| object.remove("signature"))
            .ok_or(MarketplaceInstallError::CatalogInvalid)?;
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct SignatureEnvelope {
            algorithm: String,
            key_id: String,
            value: String,
        }
        let signature: SignatureEnvelope = serde_json::from_value(signature)
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        if signature.algorithm != "ed25519" || signature.key_id != self.config.root_key_id {
            return Err(MarketplaceInstallError::CatalogInvalid);
        }
        let signature_bytes = URL_SAFE_NO_PAD
            .decode(signature.value)
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        let signature = Signature::from_slice(&signature_bytes)
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        self.config
            .root_key
            .verify_strict(canonical_json(&value)?.as_bytes(), &signature)
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
        Ok(value)
    }

    fn download_package(&self, release_id: &str) -> Result<Vec<u8>, MarketplaceInstallError> {
        self.transport
            .download_package(self.url(&format!("releases/{release_id}/package"))?)
    }
}

/// Private native transport boundary. It is deliberately not exposed through
/// FRB or the host package API: callers can never supply a marketplace URL.
trait MarketplaceTransport: Send + Sync {
    fn get_bounded(&self, url: Url, max: usize) -> Result<Vec<u8>, MarketplaceInstallError>;
    fn download_package(&self, ticket_url: Url) -> Result<Vec<u8>, MarketplaceInstallError>;
}

struct ReqwestMarketplaceTransport {
    client: Client,
}

impl MarketplaceTransport for ReqwestMarketplaceTransport {
    fn get_bounded(&self, url: Url, max: usize) -> Result<Vec<u8>, MarketplaceInstallError> {
        let client = self.client.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
            runtime.block_on(async move {
                let response = client
                    .get(url)
                    .send()
                    .await
                    .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                if response.status() != StatusCode::OK {
                    return Err(MarketplaceInstallError::PackageUnavailable);
                }
                if response.content_length().is_some_and(|n| n > max as u64) {
                    return Err(MarketplaceInstallError::PackageTooLarge);
                }
                let mut bytes = Vec::new();
                let mut stream = response.bytes_stream();
                while let Some(chunk) = stream.next().await {
                    let chunk = chunk.map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                    if bytes
                        .len()
                        .checked_add(chunk.len())
                        .filter(|n| *n <= max)
                        .is_none()
                    {
                        return Err(MarketplaceInstallError::PackageTooLarge);
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(bytes)
            })
        })
        .join()
        .map_err(|_| MarketplaceInstallError::PackageUnavailable)?
    }

    fn download_package(&self, ticket_url: Url) -> Result<Vec<u8>, MarketplaceInstallError> {
        let client = self.client.clone();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
            runtime.block_on(async move {
                let ticket = client
                    .get(ticket_url)
                    .send()
                    .await
                    .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                if !ticket.status().is_redirection() {
                    return Err(MarketplaceInstallError::PackageUnavailable);
                }
                let location = ticket
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|h| h.to_str().ok())
                    .ok_or(MarketplaceInstallError::PackageUnavailable)?;
                let redirect = Url::parse(location)
                    .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                if redirect.scheme() != "https"
                    || redirect.host_str().is_none()
                    || !redirect.username().is_empty()
                    || redirect.password().is_some()
                {
                    return Err(MarketplaceInstallError::PackageUnavailable);
                }
                let response = client
                    .get(redirect)
                    .send()
                    .await
                    .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                if response.status() != StatusCode::OK
                    || response
                        .content_length()
                        .is_some_and(|n| n > 16 * 1024 * 1024)
                {
                    return Err(MarketplaceInstallError::PackageUnavailable);
                }
                let mut bytes = Vec::new();
                let mut stream = response.bytes_stream();
                while let Some(chunk) = stream.next().await {
                    let chunk = chunk.map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
                    if bytes
                        .len()
                        .checked_add(chunk.len())
                        .filter(|n| *n <= 16 * 1024 * 1024)
                        .is_none()
                    {
                        return Err(MarketplaceInstallError::PackageTooLarge);
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(bytes)
            })
        })
        .join()
        .map_err(|_| MarketplaceInstallError::PackageUnavailable)?
    }
}

impl MarketplaceSignatureVerifier for NativeMarketplaceRuntime {
    fn verify_ed25519(
        &self,
        key_id: &str,
        message: &[u8],
        signature: &[u8; 64],
    ) -> Result<(), MarketplaceError> {
        if key_id != self.config.root_key_id
            || self
                .config
                .root_key
                .verify_strict(message, &Signature::from_bytes(signature))
                .is_err()
        {
            return Err(MarketplaceError {
                code: MarketplaceErrorCode::SignatureInvalid,
            });
        }
        Ok(())
    }
}
impl MarketplacePackageFetcher for NativeMarketplaceRuntime {
    fn open_package(&self, release_id: &str) -> Result<Box<dyn Read>, MarketplaceInstallError> {
        Ok(Box::new(Cursor::new(self.download_package(release_id)?)))
    }
}
impl MarketplacePublisherKeyResolver for NativeMarketplaceRuntime {
    fn active_public_key(
        &self,
        publisher: &str,
        key_id: &str,
    ) -> Result<[u8; 32], MarketplaceInstallError> {
        self.fetch_publisher_key(publisher, key_id)
    }
}
impl MarketplaceBridgeService for NativeMarketplaceRuntime {
    fn verified_catalog(
        &self,
        query: &MarketplaceCatalogQueryDto,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceErrorDto> {
        self.refresh_installed_policy().map_err(map_error)?;
        self.fetch_verified_catalog(query).map_err(map_error)
    }
    fn verified_plugin(
        &self,
        reference: &crate::marketplace::MarketplacePluginRefDto,
    ) -> Result<Vec<MarketplaceReleaseSummary>, MarketplaceErrorDto> {
        self.refresh_installed_policy().map_err(map_error)?;
        self.fetch_plugin(&reference.publisher_id, &reference.plugin_id)
            .map_err(map_error)
    }
    fn verified_release(
        &self,
        reference: &crate::marketplace::MarketplaceReleaseRefDto,
    ) -> Result<MarketplaceReleaseSummary, MarketplaceErrorDto> {
        self.refresh_installed_policy().map_err(map_error)?;
        self.fetch_release(&reference.release_id).map_err(map_error)
    }
    fn compatibility(
        &self,
        release: &MarketplaceReleaseSummary,
    ) -> Result<MarketplaceCompatibilityInput, MarketplaceErrorDto> {
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        let installed = registry
            .load()
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?
            .into_iter()
            .find(|record| record.plugin_id == release.identity.plugin_id);
        Ok(MarketplaceCompatibilityInput {
            host_api: Version::new(HOST_API_VERSION.0, HOST_API_VERSION.1, HOST_API_VERSION.2),
            platform: current_platform(),
            max_package_bytes: 16 * 1024 * 1024,
            approved_permissions: BTreeSet::new(),
            installed_version: installed
                .as_ref()
                .map(|record| record.selected_version.clone()),
            locally_blocked: installed
                .is_some_and(|record| !record.policy_state.permits_activation()),
        })
    }
    fn install(
        &self,
        release: &MarketplaceReleaseSummary,
        compatibility: &MarketplaceCompatibilityInput,
        consent: &[timetrace_plugin_api::CapabilityId],
    ) -> Result<(), MarketplaceErrorDto> {
        let authoritative = self.fetch_release(&release.release_id).map_err(map_error)?;
        if authoritative != *release {
            return Err(error(
                MarketplaceErrorCodeDto::ReleaseIdentityMismatch,
                false,
            ));
        }
        if consent
            .iter()
            .any(|capability| !compatibility.approved_permissions.contains(capability))
        {
            return Err(error(MarketplaceErrorCodeDto::ConsentMismatch, false));
        }
        let installer = MarketplacePackageInstaller::new(
            self.config.install_root.clone(),
            self.clone(),
            TtxArchiveVerifier::new(self.clone()),
        );
        let installed = installer
            .install(
                &authoritative,
                compatibility,
                &MarketplaceConsent {
                    // The installer must see the same effective approval set
                    // used by the compatibility planner: persisted grants plus
                    // the exact consent accepted in this operation.
                    capability_ids: compatibility
                        .approved_permissions
                        .iter()
                        .map(ToString::to_string)
                        .collect(),
                },
            )
            .map_err(map_error)?;
        self.record_and_reload(&authoritative, &installed)?;
        Ok(())
    }
    fn set_installed_enabled(
        &self,
        plugin_id: &str,
        enabled: bool,
    ) -> Result<bool, MarketplaceErrorDto> {
        let plugin_id = timetrace_plugin_api::PluginId::new(plugin_id.to_owned())
            .map_err(|_| error(MarketplaceErrorCodeDto::InvalidRequest, false))?;
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        if !registry
            .load()
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?
            .iter()
            .any(|record| record.plugin_id == plugin_id)
        {
            return Ok(false);
        }
        registry
            .set_desired_state(
                &plugin_id,
                if enabled {
                    timetrace_plugin_api::DesiredPluginState::Enabled
                } else {
                    timetrace_plugin_api::DesiredPluginState::Disabled
                },
            )
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        self.reload_installed_plugins()?;
        Ok(true)
    }
}

impl NativeMarketplaceRuntime {
    fn refresh_or_fail_closed_then_reload(&self) -> Result<(), MarketplaceErrorDto> {
        if self.refresh_installed_policy().is_err() {
            self.expire_installed_policy()?;
        }
        self.reload_installed_plugins()
    }

    /// Fetches every signed catalog page before publishing any policy state.
    /// A partial listing never authorizes an installed package.
    fn refresh_installed_policy(&self) -> Result<(), MarketplaceInstallError> {
        self.refresh_installed_policy_at(now_millis()?)
    }

    fn refresh_installed_policy_at(
        &self,
        observed_at_ms: u64,
    ) -> Result<(), MarketplaceInstallError> {
        // Do not create local Marketplace storage merely to browse a catalog.
        // This also keeps a bad root signature from causing a filesystem write.
        if !self.config.install_root.exists() {
            return Ok(());
        }
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        let records = registry
            .load()
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        if records.is_empty() {
            return Ok(());
        }
        let releases = self.fetch_complete_policy_catalog(observed_at_ms)?;
        let states = records
            .into_iter()
            .map(|record| {
                let state = releases
                    .get(&record.release_id)
                    .map(|release| match release.state {
                        timetrace_plugin_api::MarketplaceReleaseState::Published => {
                            MarketplaceInstalledPolicyState::Allowed
                        }
                        timetrace_plugin_api::MarketplaceReleaseState::Suspended => {
                            MarketplaceInstalledPolicyState::Blocked
                        }
                        timetrace_plugin_api::MarketplaceReleaseState::Revoked => {
                            MarketplaceInstalledPolicyState::Revoked
                        }
                    })
                    .unwrap_or(MarketplaceInstalledPolicyState::PolicyExpired);
                (record.plugin_id, state)
            })
            .collect::<Vec<_>>();
        registry
            .apply_policy_observation(&states, observed_at_ms)
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)
    }

    /// Returns a complete, bounded policy view across every v1 channel.
    ///
    /// Installed receipts intentionally do not persist their source channel:
    /// a reviewed release may move between stable and beta after installation.
    /// Refreshing both signed channels prevents a valid beta installation from
    /// being incorrectly expired while preserving fail-closed behavior for a
    /// missing, suspended, or revoked release.
    fn fetch_complete_policy_catalog(
        &self,
        observed_at_ms: u64,
    ) -> Result<BTreeMap<String, MarketplaceReleaseSummary>, MarketplaceInstallError> {
        let mut releases = BTreeMap::new();
        for channel in ["stable", "beta"] {
            let mut cursor = None;
            let mut complete = false;
            let mut seen_cursors = BTreeSet::new();
            for _ in 0..MAX_POLICY_CATALOG_PAGES_PER_CHANNEL {
                let page = self.fetch_verified_catalog(&MarketplaceCatalogQueryDto {
                    channel: channel.into(),
                    cursor: cursor.clone(),
                    limit: 50,
                })?;
                ensure_fresh_catalog(page.as_page().generated_at.as_str(), observed_at_ms)?;
                for release in &page.as_page().items {
                    match releases.get(&release.release_id) {
                        Some(existing) if existing == release => {}
                        Some(_) => return Err(MarketplaceInstallError::CatalogInvalid),
                        None if releases.len() == MAX_POLICY_CATALOG_RELEASES => {
                            return Err(MarketplaceInstallError::CatalogInvalid);
                        }
                        None => {
                            releases.insert(release.release_id.clone(), release.clone());
                        }
                    }
                }
                match &page.as_page().next_cursor {
                    Some(next) if seen_cursors.insert(next.clone()) => cursor = Some(next.clone()),
                    None => {
                        complete = true;
                        break;
                    }
                    Some(_) => return Err(MarketplaceInstallError::CatalogInvalid),
                }
            }
            if !complete {
                return Err(MarketplaceInstallError::CatalogInvalid);
            }
        }
        Ok(releases)
    }

    fn expire_installed_policy(&self) -> Result<(), MarketplaceErrorDto> {
        self.expire_installed_policy_at(now_millis().map_err(map_error)?)
    }

    fn expire_installed_policy_at(&self, observed_at_ms: u64) -> Result<(), MarketplaceErrorDto> {
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        let states = registry
            .load()
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?
            .into_iter()
            .map(|record| {
                (
                    record.plugin_id,
                    MarketplaceInstalledPolicyState::PolicyExpired,
                )
            })
            .collect::<Vec<_>>();
        if !states.is_empty() {
            registry
                .apply_policy_observation(&states, observed_at_ms)
                .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        }
        Ok(())
    }

    /// Runs exactly one host-owned policy deadline transition.  It has no FRB
    /// caller: tests use the explicit timestamp solely to prove expiry without
    /// relying on wall-clock sleeps.
    fn policy_watchdog_tick(&self, observed_at_ms: u64) -> Result<(), MarketplaceErrorDto> {
        let Some(deadline) = self
            .next_policy_deadline_ms()
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?
        else {
            return Ok(());
        };
        if deadline > observed_at_ms {
            return Ok(());
        }
        // This order matters: third-party dynamic contributions are revoked
        // locally before a potentially slow or failed remote request.
        self.expire_installed_policy_at(observed_at_ms)?;
        self.reload_installed_plugins()?;
        let _ = self.refresh_installed_policy_at(observed_at_ms);
        self.reload_installed_plugins()
    }

    fn next_policy_deadline_ms(&self) -> Result<Option<u64>, MarketplaceInstallError> {
        // Never create Marketplace storage from an idle watchdog.
        if !self.config.install_root.exists() {
            return Ok(None);
        }
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        let deadline = registry
            .load()
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?
            .into_iter()
            .map(|record| {
                record
                    .policy_refreshed_at_ms
                    .and_then(|at| at.checked_add(POLICY_MAX_AGE.as_millis() as u64))
                    // Old/malformed receipts are immediately fail-closed.
                    .unwrap_or(0)
            })
            .min();
        Ok(deadline)
    }
    fn reload_installed_plugins(&self) -> Result<(), MarketplaceErrorDto> {
        let Some(plugins) = &self.plugins else {
            return Ok(());
        };
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        let verifier = TtxArchiveVerifier::new(self.clone());
        plugins
            .reload_marketplace(&registry, &verifier)
            .map(|_| ())
            .map_err(|_| error(MarketplaceErrorCodeDto::Internal, false))
    }

    fn record_and_reload(
        &self,
        release: &MarketplaceReleaseSummary,
        installed: &MarketplaceInstalledPackage,
    ) -> Result<(), MarketplaceErrorDto> {
        let registry = MarketplaceInstalledRegistry::open(self.config.install_root.clone())
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        let record = MarketplaceInstalledRecord::from_installed_release(
            registry.root(),
            release,
            installed,
            timetrace_plugin_api::DesiredPluginState::Enabled,
            MarketplaceInstalledPolicyState::Allowed,
        )
        .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, false))?;
        let prepared = registry
            .prepare_install(record)
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        registry
            .commit(prepared)
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        registry
            .apply_policy_observation(
                &[(
                    release.identity.plugin_id.clone(),
                    MarketplaceInstalledPolicyState::Allowed,
                )],
                now_millis().map_err(map_error)?,
            )
            .map_err(|_| error(MarketplaceErrorCodeDto::StorageUnavailable, true))?;
        self.reload_installed_plugins()?;
        Ok(())
    }
}

fn now_millis() -> Result<u64, MarketplaceInstallError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| MarketplaceInstallError::CatalogInvalid)
        .and_then(|duration| {
            u64::try_from(duration.as_millis()).map_err(|_| MarketplaceInstallError::CatalogInvalid)
        })
}

fn ensure_fresh_catalog(
    generated_at: &str,
    observed_at_ms: u64,
) -> Result<(), MarketplaceInstallError> {
    let signed = DateTime::parse_from_rfc3339(generated_at)
        .map_err(|_| MarketplaceInstallError::CatalogInvalid)?
        .with_timezone(&Utc)
        .timestamp_millis();
    let now = i64::try_from(observed_at_ms).map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
    let age = now
        .checked_sub(signed)
        .ok_or(MarketplaceInstallError::CatalogInvalid)?;
    let max = i64::try_from(POLICY_MAX_AGE.as_millis())
        .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
    let skew = i64::try_from(POLICY_FUTURE_SKEW.as_millis())
        .map_err(|_| MarketplaceInstallError::CatalogInvalid)?;
    (age >= -skew && age <= max)
        .then_some(())
        .ok_or(MarketplaceInstallError::CatalogInvalid)
}

fn current_platform() -> Platform {
    #[cfg(all(target_os = "windows", target_arch = "x86_64"))]
    {
        Platform::WindowsX64
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        Platform::MacOsArm64
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        Platform::MacOsX64
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        Platform::LinuxX64
    }
}

fn map_error(value: MarketplaceInstallError) -> MarketplaceErrorDto {
    use MarketplaceInstallError as E;
    let code = match value {
        E::CatalogInvalid => MarketplaceErrorCodeDto::CatalogInvalid,
        E::PackageTooLarge => MarketplaceErrorCodeDto::PackageTooLarge,
        E::DigestMismatch => MarketplaceErrorCodeDto::DigestMismatch,
        E::ArchiveInvalid => MarketplaceErrorCodeDto::ArchiveInvalid,
        E::ReleaseIdentityMismatch => MarketplaceErrorCodeDto::ReleaseIdentityMismatch,
        E::ConsentMismatch => MarketplaceErrorCodeDto::ConsentMismatch,
        E::StorageUnavailable => MarketplaceErrorCodeDto::StorageUnavailable,
        E::PackageUnavailable => MarketplaceErrorCodeDto::PackageUnavailable,
        E::NotInstallable => MarketplaceErrorCodeDto::InvalidRequest,
    };
    error(
        code,
        matches!(
            code,
            MarketplaceErrorCodeDto::PackageUnavailable
                | MarketplaceErrorCodeDto::StorageUnavailable
        ),
    )
}

fn canonical_json(value: &Value) -> Result<String, MarketplaceInstallError> {
    fn write(value: &Value, output: &mut String) -> Result<(), MarketplaceInstallError> {
        match value {
            Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => output.push_str(
                &serde_json::to_string(value)
                    .map_err(|_| MarketplaceInstallError::CatalogInvalid)?,
            ),
            Value::Array(items) => {
                output.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    write(item, output)?;
                }
                output.push(']');
            }
            Value::Object(items) => {
                output.push('{');
                for (index, (key, item)) in items.iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    output.push_str(
                        &serde_json::to_string(key)
                            .map_err(|_| MarketplaceInstallError::CatalogInvalid)?,
                    );
                    output.push(':');
                    write(item, output)?;
                }
                output.push('}');
            }
        }
        Ok(())
    }
    let mut result = String::new();
    write(value, &mut result)?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::{
        MarketplaceRuntimeConfig, MarketplaceTransport, NativeMarketplaceRuntime, POLICY_MAX_AGE,
        PUBLISHER_SOURCE, canonical_json, checked_install_root, marketplace_provider_from_config,
        strict_base_url, strict_id,
    };
    use crate::marketplace::{
        MarketplaceBridgeProvider, MarketplaceCapabilityDto, MarketplaceCatalogQueryDto,
        MarketplaceErrorCodeDto, MarketplaceInstallRequestDto, MarketplaceOperationPhaseDto,
    };
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey};
    use reqwest::Url;
    use serde_json::{Value, json};
    use sha2::Digest;
    use std::{
        collections::BTreeMap,
        fs::File,
        io::Write,
        path::Path,
        sync::{Arc, Mutex},
    };
    use timetrace_plugin_host::{MarketplaceInstallError, MarketplaceInstalledPolicyState};

    #[test]
    fn canonicalizes_the_shared_cross_language_fixture_byte_for_byte() {
        let fixture: Value = serde_json::from_slice(include_bytes!(
            "../../contracts/fixtures/marketplace-catalog-v1/catalog.json"
        ))
        .expect("fixture JSON");
        let mut unsigned = fixture;
        unsigned
            .as_object_mut()
            .expect("fixture object")
            .remove("signature");
        let expected =
            include_str!("../../contracts/fixtures/marketplace-catalog-v1/canonical-signed.json")
                .trim_end_matches(['\r', '\n']);
        assert_eq!(canonical_json(&unsigned).expect("canonical JSON"), expected);
    }

    #[test]
    fn configuration_primitives_reject_ambiguous_or_insecure_values() {
        let base =
            strict_base_url("https://api.example.com/api/marketplace/v1").expect("valid base");
        assert_eq!(
            base.join("catalog").expect("child URL").path(),
            "/api/marketplace/v1/catalog"
        );
        for bad in [
            "http://api.example.com/api/marketplace/v1",
            "https://user@api.example.com/api/marketplace/v1",
            "https://api.example.com/other",
            "https://api.example.com/api/marketplace/v1?debug=1",
        ] {
            assert!(strict_base_url(bad).is_err(), "{bad}");
        }
        assert!(strict_id("marketplace-root-v1", 128).is_ok());
        assert!(strict_id("root key", 128).is_err());
    }

    #[test]
    fn install_root_must_be_absolute_and_under_a_canonical_parent() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let root = temp.path().join("marketplace-packages");
        assert!(checked_install_root(root.to_string_lossy().as_ref(), temp.path()).is_ok());
        assert!(checked_install_root("relative/packages", temp.path()).is_err());
    }

    #[test]
    fn incomplete_configuration_is_fail_closed_before_a_client_is_constructed() {
        let temp = tempfile::tempdir().expect("temporary directory");
        let key = URL_SAFE_NO_PAD.encode(
            SigningKey::from_bytes(&[7_u8; 32])
                .verifying_key()
                .to_bytes(),
        );
        let complete = || {
            MarketplaceRuntimeConfig::from_values(
                Some("https://api.example.com/api/marketplace/v1".into()),
                Some("marketplace-root-v1".into()),
                Some(key.clone()),
                Some(PUBLISHER_SOURCE.into()),
                Some(temp.path().join("packages").to_string_lossy().into_owned()),
                temp.path(),
            )
        };
        assert!(complete().is_ok());
        assert!(
            MarketplaceRuntimeConfig::from_values(
                None,
                Some("marketplace-root-v1".into()),
                Some(key),
                Some(PUBLISHER_SOURCE.into()),
                Some(temp.path().join("packages").to_string_lossy().into_owned()),
                temp.path()
            )
            .is_err()
        );
    }

    struct ControlledTransport {
        responses: Mutex<BTreeMap<String, Vec<u8>>>,
        package: Mutex<Result<Vec<u8>, MarketplaceInstallError>>,
        requests: Mutex<Vec<String>>,
    }

    impl Default for ControlledTransport {
        fn default() -> Self {
            Self {
                responses: Mutex::new(BTreeMap::new()),
                package: Mutex::new(Err(MarketplaceInstallError::PackageUnavailable)),
                requests: Mutex::new(Vec::new()),
            }
        }
    }

    impl ControlledTransport {
        fn response(&self, endpoint: impl Into<String>, bytes: Vec<u8>) {
            self.responses
                .lock()
                .unwrap()
                .insert(endpoint.into(), bytes);
        }

        fn request_count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }

        fn clear_responses_and_requests(&self) {
            self.responses.lock().unwrap().clear();
            self.requests.lock().unwrap().clear();
        }
    }

    impl MarketplaceTransport for ControlledTransport {
        fn get_bounded(&self, url: Url, _: usize) -> Result<Vec<u8>, MarketplaceInstallError> {
            self.requests.lock().unwrap().push(url.to_string());
            let endpoint = if url.path().ends_with("/catalog") {
                let channel = url
                    .query_pairs()
                    .find_map(|(key, value)| (key == "channel").then_some(value.into_owned()))
                    .unwrap_or_else(|| "stable".into());
                let cursor = url
                    .query_pairs()
                    .find_map(|(key, value)| (key == "cursor").then_some(value.into_owned()));
                match cursor {
                    Some(cursor) => format!("catalog:{channel}:{cursor}"),
                    None => format!("catalog:{channel}"),
                }
            } else if url.path().contains("/publisher-keys/") {
                "publisher-key".into()
            } else if url.path().contains("/releases/") {
                "release".into()
            } else {
                return Err(MarketplaceInstallError::PackageUnavailable);
            };
            let responses = self.responses.lock().unwrap();
            responses
                .get(&endpoint)
                .or_else(|| {
                    endpoint
                        .starts_with("catalog:")
                        .then(|| responses.get("catalog"))
                        .flatten()
                })
                .cloned()
                .ok_or(MarketplaceInstallError::PackageUnavailable)
        }

        fn download_package(&self, ticket_url: Url) -> Result<Vec<u8>, MarketplaceInstallError> {
            self.requests.lock().unwrap().push(ticket_url.to_string());
            self.package.lock().unwrap().clone()
        }
    }

    fn signed(mut value: Value, signer: &SigningKey) -> Vec<u8> {
        let signature = URL_SAFE_NO_PAD.encode(
            signer
                .sign(canonical_json(&value).unwrap().as_bytes())
                .to_bytes(),
        );
        value.as_object_mut().unwrap().insert(
            "signature".into(),
            json!({"algorithm":"ed25519","key_id":"marketplace-root-v1","value":signature}),
        );
        serde_json::to_vec(&value).unwrap()
    }

    fn ttx_archive(path: &Path, publisher: &SigningKey) -> Vec<u8> {
        let manifest = include_bytes!("../../contracts/fixtures/ttx-manifest-v1/manifest.json")
            .strip_suffix(b"\n")
            .unwrap();
        let index = br#"{"files":[],"schema_version":1}"#;
        let manifest_value: Value = serde_json::from_slice(manifest).unwrap();
        let index_value: Value = serde_json::from_slice(index).unwrap();
        let payload = json!({"manifest":manifest_value,"payload_index":index_value});
        let message = format!(
            "timetrace.ttx.publisher.v1\0{}",
            canonical_json(&payload).unwrap()
        );
        let signature = URL_SAFE_NO_PAD.encode(publisher.sign(message.as_bytes()).to_bytes());
        let signature_json = format!(
            "{{\"algorithm\":\"ed25519\",\"key_id\":\"fixture-key\",\"value\":\"{signature}\"}}"
        );
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        for (name, bytes) in [
            ("manifest.json", manifest),
            ("payload-index.json", index.as_slice()),
            ("signature.json", signature_json.as_bytes()),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(bytes).unwrap();
        }
        zip.finish().unwrap();
        std::fs::read(path).unwrap()
    }

    fn release_for(package: &[u8]) -> Value {
        let mut release = serde_json::from_slice::<Value>(include_bytes!(
            "../../contracts/fixtures/marketplace-catalog-v1/catalog.json"
        ))
        .unwrap()["items"][0]
            .clone();
        let object = release.as_object_mut().unwrap();
        object.insert(
            "identity".into(),
            json!({"publisher_id":"timetrace-labs","plugin_id":"sample-insights"}),
        );
        object.insert("display_name".into(), json!("Sample Insights"));
        object.insert(
            "package_digest".into(),
            json!(format!("{:x}", sha2::Sha256::digest(package))),
        );
        object.insert("package_bytes".into(), json!(package.len()));
        release
    }

    fn fixture_runtime(
        transport: Arc<ControlledTransport>,
        root: &SigningKey,
        install_root: &Path,
    ) -> NativeMarketplaceRuntime {
        NativeMarketplaceRuntime::with_transport(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root: install_root.to_owned(),
            },
            transport,
        )
    }

    fn provision_chain(
        transport: &ControlledTransport,
        root: &SigningKey,
        publisher: &SigningKey,
        package: &[u8],
    ) {
        let release = release_for(package);
        transport.response(
            "catalog",
            signed(
                json!({
                    "schema_version":1,
                    "catalog_revision":"test-catalog",
                    "generated_at":"2026-08-23T00:00:00.120Z",
                    "items":[release.clone()],
                    "next_cursor":null
                }),
                root,
            ),
        );
        transport.response(
            "release",
            signed(json!({"schema_version":1,"release":release}), root),
        );
        transport.response(
            "publisher-key",
            signed(json!({
                "schema_version":1,
                "publisher_id":"timetrace-labs",
                "key_id":"fixture-key",
                "status":"active",
                "public_key":{"kty":"OKP","crv":"Ed25519","x":URL_SAFE_NO_PAD.encode(publisher.verifying_key().to_bytes())}
            }), root),
        );
        *transport.package.lock().unwrap() = Ok(package.to_vec());
    }

    fn signed_catalog(root: &SigningKey, items: Vec<Value>, next_cursor: Option<&str>) -> Vec<u8> {
        signed(
            json!({
                "schema_version": 1,
                "catalog_revision": "test-catalog",
                "generated_at": "2026-08-23T00:00:00.120Z",
                "items": items,
                "next_cursor": next_cursor,
            }),
            root,
        )
    }

    fn listing(
        provider: &MarketplaceBridgeProvider,
    ) -> crate::marketplace::MarketplaceCatalogPageDto {
        provider
            .list(MarketplaceCatalogQueryDto {
                channel: "stable".into(),
                cursor: None,
                limit: 1,
            })
            .unwrap()
    }

    #[test]
    fn controlled_transport_exercises_full_signed_chain_and_atomic_install() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[3; 32]);
        let publisher = SigningKey::from_bytes(&[4; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &root, &publisher, &package);
        let install_root = temp.path().join("installed");
        let provider = MarketplaceBridgeProvider::new(Arc::new(fixture_runtime(
            transport.clone(),
            &root,
            &install_root,
        )));
        let page = listing(&provider);
        let outcome = provider.install(MarketplaceInstallRequestDto {
            release: page.items[0].release.clone(),
            consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
        });
        assert_eq!(outcome.phase, MarketplaceOperationPhaseDto::Enabled);
        let path = install_root
            .join("packages")
            .join("sample-insights")
            .join("1.2.3")
            .join(format!("{:x}.ttx", sha2::Sha256::digest(&package)));
        assert_eq!(std::fs::read(path).unwrap(), package);
        assert!(
            !install_root
                .join(".123e4567-e89b-12d3-a456-426614174000.download")
                .exists()
        );
        assert_eq!(
            transport.request_count(),
            5,
            "catalog + catalog/release/key/ticket"
        );
    }

    #[test]
    fn signed_install_commits_registry_then_publishes_the_reverified_plugin_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[31; 32]);
        let publisher = SigningKey::from_bytes(&[32; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &root, &publisher, &package);
        let install_root = temp.path().join("installed");
        let plugins = Arc::new(
            crate::plugins::PluginService::new(temp.path().join("plugin-state.json"))
                .expect("plugin service"),
        );
        let runtime = NativeMarketplaceRuntime::with_transport_and_plugins(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root: install_root.clone(),
            },
            transport,
            Some(plugins.clone()),
        );
        let provider = MarketplaceBridgeProvider::new(Arc::new(runtime));
        let page = listing(&provider);
        assert_eq!(
            provider
                .install(MarketplaceInstallRequestDto {
                    release: page.items[0].release.clone(),
                    consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
                })
                .phase,
            MarketplaceOperationPhaseDto::Enabled
        );
        let snapshot = plugins.snapshot().expect("published snapshot");
        assert!(
            snapshot
                .plugins
                .iter()
                .any(|plugin| plugin.plugin_id == "sample-insights")
        );
        let registry = timetrace_plugin_host::MarketplaceInstalledRegistry::open(install_root)
            .expect("registry");
        assert_eq!(registry.load().expect("records").len(), 1);
    }

    #[test]
    fn signed_policy_refresh_persists_disable_and_restart_keeps_dynamic_plugin_inactive() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[41; 32]);
        let publisher = SigningKey::from_bytes(&[42; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &root, &publisher, &package);
        let install_root = temp.path().join("installed");
        let plugins = Arc::new(
            crate::plugins::PluginService::new(temp.path().join("plugin-state.json")).unwrap(),
        );
        let runtime = NativeMarketplaceRuntime::with_transport_and_plugins(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root: install_root.clone(),
            },
            transport.clone(),
            Some(plugins.clone()),
        );
        let provider = MarketplaceBridgeProvider::new(Arc::new(runtime));
        let page = listing(&provider);
        assert_eq!(
            provider
                .install(MarketplaceInstallRequestDto {
                    release: page.items[0].release.clone(),
                    consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
                })
                .phase,
            MarketplaceOperationPhaseDto::Enabled
        );
        assert!(
            provider
                .set_installed_enabled("sample-insights", false)
                .unwrap()
        );
        let record =
            timetrace_plugin_host::MarketplaceInstalledRegistry::open(install_root.clone())
                .unwrap()
                .load()
                .unwrap()
                .pop()
                .unwrap();
        assert_eq!(
            record.desired_state,
            timetrace_plugin_api::DesiredPluginState::Disabled
        );
        // Signed refresh reads the whole catalog and must not re-enable the
        // persisted user preference when a fresh runtime discovers it.
        let restarted = NativeMarketplaceRuntime::with_transport_and_plugins(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root,
            },
            transport,
            Some(plugins.clone()),
        );
        restarted.refresh_or_fail_closed_then_reload().unwrap();
        assert!(
            !plugins
                .snapshot()
                .unwrap()
                .plugins
                .iter()
                .any(|item| item.plugin_id == "sample-insights")
        );
    }

    #[test]
    fn policy_refresh_covers_stable_and_beta_deduplicates_and_blocks_missing_or_revoked_beta() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[43; 32]);
        let publisher = SigningKey::from_bytes(&[44; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        let mut beta_release = release_for(&package);
        let beta = beta_release.as_object_mut().unwrap();
        beta.insert(
            "release_id".into(),
            json!("00000000-0000-4000-8000-000000000002"),
        );
        beta.insert("channel".into(), json!("beta"));
        let mut stable_release = release_for(&package);
        stable_release.as_object_mut().unwrap().insert(
            "release_id".into(),
            json!("00000000-0000-4000-8000-000000000003"),
        );
        transport.response(
            "catalog:stable",
            signed_catalog(&root, vec![stable_release.clone()], None),
        );
        transport.response(
            "catalog:beta",
            signed_catalog(&root, vec![beta_release.clone()], None),
        );
        transport.response(
            "release",
            signed(
                json!({"schema_version": 1, "release": beta_release.clone()}),
                &root,
            ),
        );
        transport.response(
            "publisher-key",
            signed(json!({
                "schema_version": 1,
                "publisher_id": "timetrace-labs",
                "key_id": "fixture-key",
                "status": "active",
                "public_key": {"kty": "OKP", "crv": "Ed25519", "x": URL_SAFE_NO_PAD.encode(publisher.verifying_key().to_bytes())}
            }), &root),
        );
        *transport.package.lock().unwrap() = Ok(package);
        let install_root = temp.path().join("installed");
        let runtime = NativeMarketplaceRuntime::with_transport(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root: install_root.clone(),
            },
            transport.clone(),
        );
        let provider = MarketplaceBridgeProvider::new(Arc::new(runtime.clone()));
        let beta_page = provider
            .list(MarketplaceCatalogQueryDto {
                channel: "beta".into(),
                cursor: None,
                limit: 1,
            })
            .unwrap();
        assert_eq!(
            provider
                .install(MarketplaceInstallRequestDto {
                    release: beta_page.items[0].release.clone(),
                    consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
                })
                .phase,
            MarketplaceOperationPhaseDto::Enabled
        );
        let observed_at = u64::try_from(
            chrono::DateTime::parse_from_rfc3339("2026-08-23T00:00:00.120Z")
                .unwrap()
                .timestamp_millis(),
        )
        .unwrap();

        // The same immutable beta release in both views must not cause a
        // duplicate or expiry; cross-channel deduplication is by release ID.
        transport.response(
            "catalog:stable",
            signed_catalog(&root, vec![beta_release.clone()], None),
        );
        runtime.refresh_installed_policy_at(observed_at).unwrap();
        let registry =
            timetrace_plugin_host::MarketplaceInstalledRegistry::open(install_root).unwrap();
        assert_eq!(
            registry.load().unwrap().pop().unwrap().policy_state,
            MarketplaceInstalledPolicyState::Allowed
        );
        // A complete signed view that omits the beta release expires it.
        transport.response(
            "catalog:stable",
            signed_catalog(&root, vec![stable_release], None),
        );
        transport.response("catalog:beta", signed_catalog(&root, vec![], None));
        runtime.refresh_installed_policy_at(observed_at).unwrap();
        assert_eq!(
            registry.load().unwrap().pop().unwrap().policy_state,
            MarketplaceInstalledPolicyState::PolicyExpired
        );
        // A signed beta revocation wins over the prior local expiry state.
        let mut revoked_beta = beta_release;
        revoked_beta
            .as_object_mut()
            .unwrap()
            .insert("state".into(), json!("revoked"));
        transport.response(
            "catalog:beta",
            signed_catalog(&root, vec![revoked_beta], None),
        );
        runtime.refresh_installed_policy_at(observed_at).unwrap();
        assert_eq!(
            registry.load().unwrap().pop().unwrap().policy_state,
            MarketplaceInstalledPolicyState::Revoked
        );
    }

    #[test]
    fn policy_refresh_rejects_a_repeated_catalog_cursor_before_switching_channels() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[45; 32]);
        let transport = Arc::new(ControlledTransport::default());
        let looped = signed_catalog(&root, vec![], Some("loop"));
        transport.response("catalog:stable", looped.clone());
        transport.response("catalog:stable:loop", looped);
        let runtime = fixture_runtime(transport.clone(), &root, &temp.path().join("installed"));
        let observed_at = u64::try_from(
            chrono::DateTime::parse_from_rfc3339("2026-08-23T00:00:00.120Z")
                .unwrap()
                .timestamp_millis(),
        )
        .unwrap();
        assert!(runtime.fetch_complete_policy_catalog(observed_at).is_err());
        assert_eq!(transport.request_count(), 2, "stable cursor loop only");
    }

    #[test]
    fn policy_watchdog_tick_expires_and_disables_active_dynamic_plugin_without_a_ui_call() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[51; 32]);
        let publisher = SigningKey::from_bytes(&[52; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &root, &publisher, &package);
        let install_root = temp.path().join("installed");
        let plugins = Arc::new(
            crate::plugins::PluginService::new(temp.path().join("plugin-state.json")).unwrap(),
        );
        let runtime = Arc::new(NativeMarketplaceRuntime::with_transport_and_plugins(
            MarketplaceRuntimeConfig {
                base_url: Url::parse("https://marketplace.test/api/marketplace/v1/").unwrap(),
                root_key_id: "marketplace-root-v1".into(),
                root_key: root.verifying_key(),
                install_root: install_root.clone(),
            },
            transport.clone(),
            Some(plugins.clone()),
        ));
        let provider = MarketplaceBridgeProvider::new(runtime.clone());
        let page = listing(&provider);
        assert_eq!(
            provider
                .install(MarketplaceInstallRequestDto {
                    release: page.items[0].release.clone(),
                    consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
                })
                .phase,
            MarketplaceOperationPhaseDto::Enabled
        );
        assert!(
            plugins
                .snapshot()
                .unwrap()
                .plugins
                .iter()
                .any(|item| item.plugin_id == "sample-insights")
        );

        let registry = timetrace_plugin_host::MarketplaceInstalledRegistry::open(install_root)
            .expect("registry");
        let record = registry.load().unwrap().pop().unwrap();
        let observed_at = 1_000_000_u64;
        registry
            .apply_policy_observation(
                &[(
                    record.plugin_id.clone(),
                    MarketplaceInstalledPolicyState::Allowed,
                )],
                observed_at,
            )
            .unwrap();
        // No Flutter/provider Marketplace method is called below. The only
        // request is the watchdog's failed refresh after it has revoked local
        // activation. A missing catalog keeps the persisted state fail-closed.
        transport.clear_responses_and_requests();
        runtime
            .policy_watchdog_tick(observed_at + POLICY_MAX_AGE.as_millis() as u64)
            .unwrap();
        assert_eq!(transport.request_count(), 1, "watchdog refresh only");
        assert_eq!(
            registry.load().unwrap().pop().unwrap().policy_state,
            MarketplaceInstalledPolicyState::PolicyExpired
        );
        assert!(
            !plugins
                .snapshot()
                .unwrap()
                .active
                .iter()
                .any(|item| item.plugin_id == "sample-insights")
        );
    }

    #[test]
    fn signed_chain_fails_closed_for_wrong_root_or_tampered_package_and_leaves_no_staging() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[3; 32]);
        let wrong_root = SigningKey::from_bytes(&[5; 32]);
        let publisher = SigningKey::from_bytes(&[4; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &wrong_root, &publisher, &package);
        let install_root = temp.path().join("wrong-root");
        let provider = MarketplaceBridgeProvider::new(Arc::new(fixture_runtime(
            transport.clone(),
            &root,
            &install_root,
        )));
        assert_eq!(
            listing_error(&provider),
            MarketplaceErrorCodeDto::CatalogInvalid
        );
        assert_eq!(transport.request_count(), 1);
        assert!(!install_root.exists());

        let transport = Arc::new(ControlledTransport::default());
        provision_chain(&transport, &root, &publisher, &package);
        let mut tampered = package.clone();
        tampered[0] ^= 1;
        *transport.package.lock().unwrap() = Ok(tampered);
        let install_root = temp.path().join("tampered");
        let provider = MarketplaceBridgeProvider::new(Arc::new(fixture_runtime(
            transport,
            &root,
            &install_root,
        )));
        let page = listing(&provider);
        let outcome = provider.install(MarketplaceInstallRequestDto {
            release: page.items[0].release.clone(),
            consent_capability_ids: vec![MarketplaceCapabilityDto::UsageAggregateRead],
        });
        assert_eq!(outcome.phase, MarketplaceOperationPhaseDto::Failed);
        assert_eq!(
            outcome.error.unwrap().code,
            MarketplaceErrorCodeDto::DigestMismatch
        );
        assert!(
            !install_root
                .join("sample-insights")
                .join("1.2.3")
                .join("package.ttx")
                .exists()
        );
        assert!(
            !install_root
                .join(".123e4567-e89b-12d3-a456-426614174000.download")
                .exists()
        );
    }

    fn listing_error(provider: &MarketplaceBridgeProvider) -> MarketplaceErrorCodeDto {
        provider
            .list(MarketplaceCatalogQueryDto {
                channel: "stable".into(),
                cursor: None,
                limit: 1,
            })
            .unwrap_err()
            .code
    }

    #[test]
    fn missing_or_extra_consent_never_reaches_release_or_package_transport() {
        let temp = tempfile::tempdir().unwrap();
        let root = SigningKey::from_bytes(&[3; 32]);
        let publisher = SigningKey::from_bytes(&[4; 32]);
        let package = ttx_archive(&temp.path().join("source.ttx"), &publisher);
        for consent in [
            vec![],
            vec![
                MarketplaceCapabilityDto::UsageAggregateRead,
                MarketplaceCapabilityDto::AiCloud,
            ],
        ] {
            let transport = Arc::new(ControlledTransport::default());
            provision_chain(&transport, &root, &publisher, &package);
            let provider = MarketplaceBridgeProvider::new(Arc::new(fixture_runtime(
                transport.clone(),
                &root,
                &temp.path().join("consent"),
            )));
            let page = listing(&provider);
            let outcome = provider.install(MarketplaceInstallRequestDto {
                release: page.items[0].release.clone(),
                consent_capability_ids: consent,
            });
            assert_eq!(outcome.phase, MarketplaceOperationPhaseDto::Blocked);
            assert_eq!(
                outcome.error.unwrap().code,
                MarketplaceErrorCodeDto::ConsentMismatch
            );
            assert_eq!(
                transport.request_count(),
                2,
                "only signed catalog list + install lookup"
            );
        }
    }

    #[test]
    fn absent_configuration_does_not_construct_a_runtime_or_issue_a_request() {
        let constructed = Arc::new(Mutex::new(false));
        let observed = constructed.clone();
        let provider = marketplace_provider_from_config(Err(()), move |_| {
            *observed.lock().unwrap() = true;
            unreachable!("missing configuration must not construct transport/runtime")
        });
        assert_eq!(
            listing_error(&provider),
            MarketplaceErrorCodeDto::CatalogUnavailable
        );
        assert!(!*constructed.lock().unwrap());
    }
}
