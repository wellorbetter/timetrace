//! Host-owned, fail-closed marketplace package installation seam.
//!
//! This module deliberately has no HTTP client, UI, or dynamic runtime.  A
//! platform adapter supplies a bounded byte stream and an archive verifier;
//! the host verifies the signed release again before atomically making the
//! exact archive available to the local extension store.

use std::{
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::Deserialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use timetrace_plugin_api::{
    MarketplaceCatalogPage, MarketplaceCompatibilityInput, MarketplaceInstallDisposition,
    MarketplaceReleaseSummary, MarketplaceSignatureVerifier, PluginManifest,
    VerifiedMarketplaceCatalogPage, plan_marketplace_install,
};

/// P0 local hard limit, independent of a remote release declaration.
pub const MAX_MARKETPLACE_PACKAGE_BYTES: u64 = 16 * 1024 * 1024;
/// Maximum archive members accepted by Marketplace TTX v1.
pub const MAX_TTX_ENTRIES: usize = 256;
/// Maximum total uncompressed archive bytes accepted by Marketplace TTX v1.
pub const MAX_TTX_DECOMPRESSED_BYTES: u64 = 64 * 1024 * 1024;
const SIGNATURE_PREFIX: &[u8] = b"timetrace.ttx.publisher.v1\0";

/// A host-audited, compile-time identity for a bundled first-party renderer.
///
/// This carries no factory, package path, or host service capability.  The
/// bridge may only map this exact binding to already-compiled code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BundledRendererBinding {
    /// Publisher identity fixed by the host build.
    pub publisher_id: &'static str,
    /// Plugin identity fixed by the host build.
    pub plugin_id: &'static str,
    /// Renderer contract fixed by the host build.
    pub renderer_contract_id: &'static str,
    /// Renderer schema version fixed by the host build.
    pub renderer_schema_version: u32,
}

const PRIVATE_FLIGHT_BUNDLED_BINDING: BundledRendererBinding = BundledRendererBinding {
    publisher_id: "wellorbetter",
    plugin_id: "private-flight",
    renderer_contract_id: "private-flight-v1",
    renderer_schema_version: 1,
};

const AI_RECAP_BUNDLED_BINDING: BundledRendererBinding = BundledRendererBinding {
    publisher_id: "wellorbetter",
    plugin_id: "ai-recap",
    renderer_contract_id: "ai-recap-v1",
    renderer_schema_version: 1,
};

const BUNDLED_RENDERER_BINDINGS: &[BundledRendererBinding] =
    &[PRIVATE_FLIGHT_BUNDLED_BINDING, AI_RECAP_BUNDLED_BINDING];

/// Returns the exact P2 renderer binding admitted by this host build.
///
/// A manifest must pass the complete first-party bundled profile check before
/// this lookup succeeds.  In particular, this is not a plugin-id-only lookup.
pub fn marketplace_bundled_renderer_binding(
    manifest: &PluginManifest,
) -> Result<&'static BundledRendererBinding, MarketplaceInstallError> {
    manifest
        .validate_marketplace_first_party_bundled_v1_profile()
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    let (renderer_contract_id, renderer_schema_version) = match manifest.contributions.first() {
        Some(timetrace_plugin_api::ContributionDescriptor::Page(page)) => match &page.renderer {
            timetrace_plugin_api::RendererRef::BundledTyped {
                contract_id,
                schema_version,
            } => (contract_id.as_str(), *schema_version),
            _ => return Err(MarketplaceInstallError::ArchiveInvalid),
        },
        _ => return Err(MarketplaceInstallError::ArchiveInvalid),
    };
    BUNDLED_RENDERER_BINDINGS
        .iter()
        .find(|binding| {
            binding.publisher_id == manifest.publisher.as_str()
                && binding.plugin_id == manifest.id.as_str()
                && binding.renderer_contract_id == renderer_contract_id
                && binding.renderer_schema_version == renderer_schema_version
        })
        .ok_or(MarketplaceInstallError::ArchiveInvalid)
}

/// Stable local installation failures.  No remote response text is retained.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum MarketplaceInstallError {
    /// The bounded marketplace catalog could not be verified with the pinned root.
    #[error("marketplace catalog verification failed")]
    CatalogInvalid,
    /// The release was not locally eligible at the time of installation.
    #[error("marketplace install is not eligible")]
    NotInstallable,
    /// Consent did not cover every permission in the signed release.
    #[error("marketplace permission consent is missing or changed")]
    ConsentMismatch,
    /// A downloaded stream exceeded its advertised or local byte limit.
    #[error("marketplace package exceeded its byte limit")]
    PackageTooLarge,
    /// The exact archive digest differed from the reviewed release.
    #[error("marketplace package digest mismatch")]
    DigestMismatch,
    /// The archive verifier rejected publisher signature or archive layout.
    #[error("marketplace archive verification failed")]
    ArchiveInvalid,
    /// The verified manifest did not exactly match the reviewed release.
    #[error("marketplace release identity changed")]
    ReleaseIdentityMismatch,
    /// Local storage could not complete the atomic installation.
    #[error("marketplace local storage unavailable")]
    StorageUnavailable,
    /// The platform fetch adapter did not produce a readable package.
    #[error("marketplace package unavailable")]
    PackageUnavailable,
}

/// Supplies the package for an immutable release without exposing a URL to UI.
pub trait MarketplacePackageFetcher {
    /// Opens a fresh readable package stream for exactly this release id.
    fn open_package(&self, release_id: &str) -> Result<Box<dyn Read>, MarketplaceInstallError>;
}

/// Host-owned byte transport for the signed catalog; no UI URL is exposed.
pub trait MarketplaceCatalogFetcher {
    /// Retrieves one bounded catalog response as raw bytes.
    fn fetch_catalog(&self) -> Result<Vec<u8>, MarketplaceInstallError>;
}

/// Minimal production application service for verified marketplace operations.
pub struct MarketplaceHostService<C, R, F, A> {
    catalog_fetcher: C,
    root_verifier: R,
    installer: MarketplacePackageInstaller<F, A>,
}

impl<C, R, F, A> MarketplaceHostService<C, R, F, A>
where
    C: MarketplaceCatalogFetcher,
    R: MarketplaceSignatureVerifier,
    F: MarketplacePackageFetcher,
    A: MarketplaceArchiveVerifier,
{
    /// Creates a host service from explicit transport, pinned-root and installer seams.
    pub fn new(
        catalog_fetcher: C,
        root_verifier: R,
        installer: MarketplacePackageInstaller<F, A>,
    ) -> Self {
        Self {
            catalog_fetcher,
            root_verifier,
            installer,
        }
    }

    /// Retrieves a bounded catalog and returns it only after root verification.
    pub fn verified_catalog(
        &self,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceInstallError> {
        let bytes = self.catalog_fetcher.fetch_catalog()?;
        MarketplaceCatalogPage::parse_bounded(&bytes)
            .and_then(|page| page.verify(&self.root_verifier))
            .map_err(|_| MarketplaceInstallError::CatalogInvalid)
    }

    /// Installs exactly the immutable release selected from a verified catalog.
    pub fn install_verified_release(
        &self,
        release: &MarketplaceReleaseSummary,
        compatibility: &MarketplaceCompatibilityInput,
        consent: &MarketplaceConsent,
    ) -> Result<MarketplaceInstalledPackage, MarketplaceInstallError> {
        self.installer.install(release, compatibility, consent)
    }
}

/// Result of a platform-owned `.ttx` archive verifier.
///
/// Implementations must reject unsafe archive paths, duplicate/control files,
/// compression bombs, malformed signed payload indexes and invalid publisher
/// Ed25519 signatures before returning this value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedMarketplaceArchive {
    /// Canonical plugin manifest loaded from the signed archive member.
    pub manifest: PluginManifest,
}

/// Verifies the archive's publisher signature and returns its canonical
/// manifest.  This seam is intentionally separate from marketplace-root
/// catalog verification: neither signature substitutes for the other.
pub trait MarketplaceArchiveVerifier {
    /// Verifies the complete local archive at `package_path`.
    fn verify_archive(
        &self,
        package_path: &Path,
    ) -> Result<VerifiedMarketplaceArchive, MarketplaceInstallError>;
}

/// Resolves host-approved publisher keys. Archive-contained keys are never trusted.
pub trait MarketplacePublisherKeyResolver {
    /// Returns the active Ed25519 public key for a publisher key id.
    fn active_public_key(
        &self,
        publisher: &str,
        key_id: &str,
    ) -> Result<[u8; 32], MarketplaceInstallError>;
}

/// Concrete verifier for the frozen `.ttx` v1 archive profile.
pub struct TtxArchiveVerifier<K>(K);
impl<K> TtxArchiveVerifier<K> {
    /// Creates a verifier backed by host-owned publisher keys.
    pub fn new(keys: K) -> Self {
        Self(keys)
    }
}
impl<K: MarketplacePublisherKeyResolver> MarketplaceArchiveVerifier for TtxArchiveVerifier<K> {
    fn verify_archive(
        &self,
        path: &Path,
    ) -> Result<VerifiedMarketplaceArchive, MarketplaceInstallError> {
        if fs::metadata(path)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?
            .len()
            > MAX_MARKETPLACE_PACKAGE_BYTES
        {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let mut zip = zip::ZipArchive::new(
            File::open(path).map_err(|_| MarketplaceInstallError::ArchiveInvalid)?,
        )
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        if zip.len() > MAX_TTX_ENTRIES {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let mut names = BTreeSet::new();
        let mut expanded = 0_u64;
        for i in 0..zip.len() {
            let file = zip
                .by_index(i)
                .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
            safe_zip_member(&file)?;
            expanded = expanded
                .checked_add(file.size())
                .ok_or(MarketplaceInstallError::ArchiveInvalid)?;
            if expanded > MAX_TTX_DECOMPRESSED_BYTES || !names.insert(file.name().to_owned()) {
                return Err(MarketplaceInstallError::ArchiveInvalid);
            }
        }
        let required = ["manifest.json", "payload-index.json", "signature.json"];
        if !required.iter().all(|name| names.contains(*name)) {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let manifest_bytes = member(&mut zip, "manifest.json", 64 * 1024)?;
        let manifest = PluginManifest::parse_ttx_v1_canonical(&manifest_bytes)
            .or_else(|_| {
                PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(
                    &manifest_bytes,
                )
            })
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        let manifest_value: Value = exact_value(&manifest_bytes)?;
        let index_bytes = member(&mut zip, "payload-index.json", MAX_TTX_DECOMPRESSED_BYTES)?;
        let index_value: Value = exact_value(&index_bytes)?;
        let index: PayloadIndex = serde_json::from_value(index_value.clone())
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        validate_index(&index, &names, &mut zip)?;
        validate_marketplace_member_set(&names, &manifest)?;
        let signature_bytes = member(&mut zip, "signature.json", 8 * 1024)?;
        let signature: TtxSignature = serde_json::from_value(exact_value(&signature_bytes)?)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        if signature.algorithm != "ed25519" || !key_id(&signature.key_id) {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let key_id = signature.key_id;
        let signature = Signature::from_slice(
            &URL_SAFE_NO_PAD
                .decode(signature.value)
                .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?,
        )
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        let key = VerifyingKey::from_bytes(
            &self
                .0
                .active_public_key(manifest.publisher.as_str(), &key_id)?,
        )
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        let mut message = SIGNATURE_PREFIX.to_vec();
        message.extend_from_slice(
            canonical(
                &serde_json::json!({"manifest": manifest_value, "payload_index": index_value}),
            )?
            .as_bytes(),
        );
        key.verify_strict(&message, &signature)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        Ok(VerifiedMarketplaceArchive { manifest })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TtxSignature {
    algorithm: String,
    key_id: String,
    value: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PayloadIndex {
    schema_version: u32,
    files: Vec<PayloadIndexFile>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PayloadIndexFile {
    path: String,
    sha256: String,
    bytes: u64,
}
fn safe_zip_member(file: &zip::read::ZipFile<'_>) -> Result<(), MarketplaceInstallError> {
    let n = file.name();
    let mode = file.unix_mode().unwrap_or(0);
    if n.is_empty()
        || n.ends_with('/')
        || n.starts_with('/')
        || n.contains('\\')
        || n.split('/').any(|s| s.is_empty() || s == "..")
        || file.is_dir()
        || file.encrypted()
        || !matches!(
            file.compression(),
            zip::CompressionMethod::Stored | zip::CompressionMethod::Deflated
        )
        || (mode & 0o170000) == 0o120000
    {
        Err(MarketplaceInstallError::ArchiveInvalid)
    } else {
        Ok(())
    }
}
fn member(
    zip: &mut zip::ZipArchive<File>,
    name: &str,
    limit: u64,
) -> Result<Vec<u8>, MarketplaceInstallError> {
    let mut f = zip
        .by_name(name)
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    if f.size() > limit {
        return Err(MarketplaceInstallError::ArchiveInvalid);
    }
    let mut data = Vec::with_capacity(f.size() as usize);
    f.read_to_end(&mut data)
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    Ok(data)
}
fn validate_index(
    index: &PayloadIndex,
    names: &BTreeSet<String>,
    zip: &mut zip::ZipArchive<File>,
) -> Result<(), MarketplaceInstallError> {
    if index.schema_version != 1 || index.files.len() > MAX_TTX_ENTRIES - 3 {
        return Err(MarketplaceInstallError::ArchiveInvalid);
    }
    let actual = names
        .iter()
        .filter(|n| n.starts_with("payload/") || n.starts_with("resources/"))
        .cloned()
        .collect::<Vec<_>>();
    if actual.len() + 3 != names.len() {
        return Err(MarketplaceInstallError::ArchiveInvalid);
    }
    let mut listed = Vec::new();
    for item in &index.files {
        if !(item.path.starts_with("payload/") || item.path.starts_with("resources/"))
            || item.path.contains('\\')
            || item.path.split('/').any(|s| s.is_empty() || s == "..")
            || item.bytes == 0
            || !hash(&item.sha256)
        {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let mut f = zip
            .by_name(&item.path)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        if f.size() != item.bytes {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        let mut h = Sha256::new();
        let mut b = [0; 32768];
        loop {
            let n = f
                .read(&mut b)
                .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
            if n == 0 {
                break;
            }
            h.update(&b[..n])
        }
        if format!("{:x}", h.finalize()) != item.sha256 {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
        listed.push(item.path.clone())
    }
    let mut ordered = listed.clone();
    ordered.sort();
    if listed == ordered && listed == actual {
        Ok(())
    } else {
        Err(MarketplaceInstallError::ArchiveInvalid)
    }
}

/// Derives the whole, closed resource surface allowed by the Marketplace P1
/// manifest profile.  A package cannot use `payload/**` as an activation
/// escape hatch and cannot carry arbitrary signed resources for later use.
fn expected_marketplace_p1_resources(
    manifest: &PluginManifest,
) -> Result<BTreeSet<String>, MarketplaceInstallError> {
    manifest
        .validate_marketplace_ttx_v1_activation_profile()
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    let mut expected = BTreeSet::new();
    for contribution in &manifest.contributions {
        let id = match contribution {
            timetrace_plugin_api::ContributionDescriptor::Page(page) => Some(&page.metadata.id),
            timetrace_plugin_api::ContributionDescriptor::DashboardCard(card) => {
                Some(&card.metadata.id)
            }
            _ => None,
        };
        if let Some(id) = id {
            expected.insert(format!("resources/declarative-v1/{}.json", id.as_str()));
        }
    }
    Ok(expected)
}

fn validate_marketplace_p1_member_set(
    names: &BTreeSet<String>,
    manifest: &PluginManifest,
) -> Result<(), MarketplaceInstallError> {
    let expected = expected_marketplace_p1_resources(manifest)?;
    let actual_resources = names
        .iter()
        .filter(|name| name.starts_with("resources/"))
        .cloned()
        .collect::<BTreeSet<_>>();
    let has_payload = names.iter().any(|name| name.starts_with("payload/"));
    (!has_payload && actual_resources == expected)
        .then_some(())
        .ok_or(MarketplaceInstallError::ArchiveInvalid)
}

/// Validates a P2 entitlement archive, which must have no archived behavior.
fn validate_marketplace_first_party_bundled_member_set(
    names: &BTreeSet<String>,
    manifest: &PluginManifest,
) -> Result<(), MarketplaceInstallError> {
    marketplace_bundled_renderer_binding(manifest)?;
    let expected = BTreeSet::from([
        "manifest.json".to_owned(),
        "payload-index.json".to_owned(),
        "signature.json".to_owned(),
    ]);
    (names == &expected)
        .then_some(())
        .ok_or(MarketplaceInstallError::ArchiveInvalid)
}

/// Selects the closed member set for a verified Marketplace archive profile.
fn validate_marketplace_member_set(
    names: &BTreeSet<String>,
    manifest: &PluginManifest,
) -> Result<(), MarketplaceInstallError> {
    if manifest
        .validate_marketplace_ttx_v1_activation_profile()
        .is_ok()
    {
        validate_marketplace_p1_member_set(names, manifest)
    } else {
        validate_marketplace_first_party_bundled_member_set(names, manifest)
    }
}

/// Re-checks the closed archive surface after a registry load.
///
/// Signature/index validation remains the verifier's responsibility.  This
/// independent scan ensures P1 cannot project undeclared resources and P2
/// entitlements cannot acquire archived content after their original install.
pub(crate) fn validate_marketplace_archive_members(
    path: &Path,
    manifest: &PluginManifest,
) -> Result<(), MarketplaceInstallError> {
    let mut zip = zip::ZipArchive::new(
        File::open(path).map_err(|_| MarketplaceInstallError::ArchiveInvalid)?,
    )
    .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    if zip.len() > MAX_TTX_ENTRIES {
        return Err(MarketplaceInstallError::ArchiveInvalid);
    }
    let mut names = BTreeSet::new();
    let mut expanded = 0_u64;
    for index in 0..zip.len() {
        let file = zip
            .by_index(index)
            .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
        safe_zip_member(&file)?;
        expanded = expanded
            .checked_add(file.size())
            .ok_or(MarketplaceInstallError::ArchiveInvalid)?;
        if expanded > MAX_TTX_DECOMPRESSED_BYTES || !names.insert(file.name().to_owned()) {
            return Err(MarketplaceInstallError::ArchiveInvalid);
        }
    }
    validate_marketplace_member_set(&names, manifest)
}
fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn key_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'_' | b'.' | b':')
        })
}
fn exact_value(bytes: &[u8]) -> Result<Value, MarketplaceInstallError> {
    let value =
        serde_json::from_slice(bytes).map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    (canonical(&value)?.as_bytes() == bytes)
        .then_some(value)
        .ok_or(MarketplaceInstallError::ArchiveInvalid)
}
fn canonical(value: &Value) -> Result<String, MarketplaceInstallError> {
    match value {
        Value::Null | Value::Bool(_) | Value::String(_) => {
            serde_json::to_string(value).map_err(|_| MarketplaceInstallError::ArchiveInvalid)
        }
        Value::Number(n) if n.is_i64() || n.is_u64() => Ok(n.to_string()),
        Value::Number(_) => Err(MarketplaceInstallError::ArchiveInvalid),
        Value::Array(a) => a
            .iter()
            .map(canonical)
            .collect::<Result<Vec<_>, _>>()
            .map(|v| format!("[{}]", v.join(","))),
        Value::Object(o) => o
            .iter()
            .map(|(k, v)| {
                Ok(format!(
                    "{}:{}",
                    serde_json::to_string(k)
                        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?,
                    canonical(v)?
                ))
            })
            .collect::<Result<Vec<_>, MarketplaceInstallError>>()
            .map(|v| format!("{{{}}}", v.join(","))),
    }
}

/// Explicit local confirmation for the exact release permissions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceConsent {
    /// Capability identifiers accepted by the user for this installation.
    pub capability_ids: Vec<String>,
}

/// A completed local installation, containing no executable handle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceInstalledPackage {
    /// Immutable reviewed release identifier.
    pub release_id: String,
    /// Local archive path after atomic promotion.
    pub archive_path: PathBuf,
}

/// Downloads, verifies and atomically persists an exact marketplace release.
pub struct MarketplacePackageInstaller<F, V> {
    fetcher: F,
    verifier: V,
    root: PathBuf,
}

impl<F, V> MarketplacePackageInstaller<F, V>
where
    F: MarketplacePackageFetcher,
    V: MarketplaceArchiveVerifier,
{
    /// Creates an installer rooted in a host-owned extension package directory.
    pub fn new(root: PathBuf, fetcher: F, verifier: V) -> Self {
        Self {
            fetcher,
            verifier,
            root,
        }
    }

    /// Installs only a previously reviewed, locally recomputed install plan.
    pub fn install(
        &self,
        release: &MarketplaceReleaseSummary,
        compatibility: &MarketplaceCompatibilityInput,
        consent: &MarketplaceConsent,
    ) -> Result<MarketplaceInstalledPackage, MarketplaceInstallError> {
        let disposition = plan_marketplace_install(release.clone(), compatibility).disposition;
        if !matches!(
            &disposition,
            MarketplaceInstallDisposition::Installable
                | MarketplaceInstallDisposition::UpdateAvailable
        ) {
            return Err(MarketplaceInstallError::NotInstallable);
        }
        if release.package_bytes > MAX_MARKETPLACE_PACKAGE_BYTES
            || !consent_matches(release, consent)
        {
            return Err(if release.package_bytes > MAX_MARKETPLACE_PACKAGE_BYTES {
                MarketplaceInstallError::PackageTooLarge
            } else {
                MarketplaceInstallError::ConsentMismatch
            });
        }
        fs::create_dir_all(&self.root).map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        let staging = self.root.join(format!(".{}.download", release.release_id));
        remove_file_if_present(&staging)?;
        if let Err(error) = self.download_bounded(release, &staging) {
            let _ = remove_file_if_present(&staging);
            return Err(error);
        }
        let result = (|| {
            let verified = self.verifier.verify_archive(&staging)?;
            verify_release_identity(release, &verified.manifest)?;
            let release_dir = self
                .root
                .join("packages")
                .join(release.identity.plugin_id.as_str())
                .join(release.version.to_string());
            fs::create_dir_all(&release_dir)
                .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
            let final_path = release_dir.join(format!("{}.ttx", release.package_digest));
            // `rename` is atomic within one filesystem.  The staged and final paths
            // are under the same host-owned root; no unverified archive is visible.
            fs::rename(&staging, &final_path)
                .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
            Ok(MarketplaceInstalledPackage {
                release_id: release.release_id.clone(),
                archive_path: final_path,
            })
        })();
        if result.is_err() {
            let _ = remove_file_if_present(&staging);
        }
        result
    }

    fn download_bounded(
        &self,
        release: &MarketplaceReleaseSummary,
        staging: &Path,
    ) -> Result<(), MarketplaceInstallError> {
        let mut input = self.fetcher.open_package(&release.release_id)?;
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(staging)
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        let mut digest = Sha256::new();
        let mut total = 0_u64;
        let mut buffer = [0_u8; 32 * 1024];
        loop {
            let read = input
                .read(&mut buffer)
                .map_err(|_| MarketplaceInstallError::PackageUnavailable)?;
            if read == 0 {
                break;
            }
            total = total
                .checked_add(read as u64)
                .ok_or(MarketplaceInstallError::PackageTooLarge)?;
            if total > release.package_bytes || total > MAX_MARKETPLACE_PACKAGE_BYTES {
                return Err(MarketplaceInstallError::PackageTooLarge);
            }
            output
                .write_all(&buffer[..read])
                .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
            digest.update(&buffer[..read]);
        }
        output
            .sync_all()
            .map_err(|_| MarketplaceInstallError::StorageUnavailable)?;
        if total != release.package_bytes {
            return Err(MarketplaceInstallError::DigestMismatch);
        }
        let actual = format!("{:x}", digest.finalize());
        (actual == release.package_digest)
            .then_some(())
            .ok_or(MarketplaceInstallError::DigestMismatch)
    }
}

fn consent_matches(release: &MarketplaceReleaseSummary, consent: &MarketplaceConsent) -> bool {
    let mut accepted = consent.capability_ids.clone();
    accepted.sort();
    accepted.dedup();
    let mut requested = release
        .permissions
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    requested.sort();
    requested.dedup();
    accepted == requested
}

fn verify_release_identity(
    release: &MarketplaceReleaseSummary,
    manifest: &PluginManifest,
) -> Result<(), MarketplaceInstallError> {
    manifest
        .validate_basic()
        .map_err(|_| MarketplaceInstallError::ArchiveInvalid)?;
    let manifest_permissions = manifest
        .requested_capabilities
        .iter()
        .map(|item| item.id.to_string())
        .collect::<Vec<_>>();
    let mut expected = release
        .permissions
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let mut actual = manifest_permissions;
    expected.sort();
    actual.sort();
    (manifest.publisher == release.identity.publisher_id
        && manifest.id == release.identity.plugin_id
        && manifest.version == release.version
        && manifest.host_api == release.host_api
        && manifest.platforms == release.platforms
        && actual == expected)
        .then_some(())
        .ok_or(MarketplaceInstallError::ReleaseIdentityMismatch)
}

fn remove_file_if_present(path: &Path) -> Result<(), MarketplaceInstallError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(MarketplaceInstallError::StorageUnavailable),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        MarketplaceActivationError, MarketplaceInstalledPolicyState, MarketplaceInstalledRecord,
        MarketplaceInstalledRegistry, verified_marketplace_declarative_documents,
    };
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use ed25519_dalek::{Signer, SigningKey};
    use semver::Version;
    use std::io::Cursor;
    use timetrace_plugin_api::{
        DesiredPluginState, HostApiRange, MarketplaceChannel, MarketplaceIdentity,
        MarketplaceReleaseState, MarketplaceTimestamp, Platform, PluginId, PublisherId,
    };

    struct Fetch(Vec<u8>);
    impl MarketplacePackageFetcher for Fetch {
        fn open_package(&self, _: &str) -> Result<Box<dyn Read>, MarketplaceInstallError> {
            Ok(Box::new(Cursor::new(self.0.clone())))
        }
    }
    struct Verify(PluginManifest);
    impl MarketplaceArchiveVerifier for Verify {
        fn verify_archive(
            &self,
            _: &Path,
        ) -> Result<VerifiedMarketplaceArchive, MarketplaceInstallError> {
            Ok(VerifiedMarketplaceArchive {
                manifest: self.0.clone(),
            })
        }
    }
    struct FailingVerify;
    impl MarketplaceArchiveVerifier for FailingVerify {
        fn verify_archive(
            &self,
            _: &Path,
        ) -> Result<VerifiedMarketplaceArchive, MarketplaceInstallError> {
            Err(MarketplaceInstallError::ArchiveInvalid)
        }
    }
    struct CatalogFetch(Vec<u8>);
    impl MarketplaceCatalogFetcher for CatalogFetch {
        fn fetch_catalog(&self) -> Result<Vec<u8>, MarketplaceInstallError> {
            Ok(self.0.clone())
        }
    }
    struct Root;
    impl MarketplaceSignatureVerifier for Root {
        fn verify_ed25519(
            &self,
            _: &str,
            _: &[u8],
            _: &[u8; 64],
        ) -> Result<(), timetrace_plugin_api::MarketplaceError> {
            Ok(())
        }
    }
    fn release(bytes: &[u8], manifest: &PluginManifest) -> MarketplaceReleaseSummary {
        MarketplaceReleaseSummary {
            release_id: "00000000-0000-4000-8000-000000000001".into(),
            identity: MarketplaceIdentity {
                publisher_id: manifest.publisher.clone(),
                plugin_id: manifest.id.clone(),
            },
            version: manifest.version.clone(),
            channel: MarketplaceChannel::Stable,
            state: MarketplaceReleaseState::Published,
            display_name: "Example".into(),
            description: None,
            badges: vec![],
            package_digest: format!("{:x}", Sha256::digest(bytes)),
            package_bytes: bytes.len() as u64,
            host_api: manifest.host_api.clone(),
            platforms: manifest.platforms.clone(),
            permissions: manifest
                .requested_capabilities
                .iter()
                .map(|p| p.id.clone())
                .collect(),
            published_at: MarketplaceTimestamp::parse("2026-08-23T00:00:00.000Z").unwrap(),
        }
    }
    fn manifest() -> PluginManifest {
        PluginManifest {
            schema_version: 1,
            id: PluginId::new("example.plugin").unwrap(),
            publisher: PublisherId::new("example").unwrap(),
            display_name: "Example".into(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").unwrap(),
            platforms: vec![Platform::WindowsX64],
            contributions: vec![],
            requested_capabilities: vec![],
        }
    }
    #[test]
    fn verifies_digest_before_archive_and_promotes_atomically() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = manifest();
        let bytes = b"archive";
        let release = release(bytes, &manifest);
        let installed = MarketplacePackageInstaller::new(
            temp.path().join("packages"),
            Fetch(bytes.to_vec()),
            Verify(manifest),
        )
        .install(
            &release,
            &compatibility(),
            &MarketplaceConsent {
                capability_ids: vec![],
            },
        )
        .unwrap();
        assert_eq!(fs::read(installed.archive_path).unwrap(), bytes);
    }
    #[test]
    fn consent_or_digest_changes_fail_closed() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = manifest();
        let release = release(b"expected", &manifest);
        let installer = MarketplacePackageInstaller::new(
            temp.path().join("packages"),
            Fetch(b"changed".to_vec()),
            Verify(manifest),
        );
        assert_eq!(
            installer.install(
                &release,
                &compatibility(),
                &MarketplaceConsent {
                    capability_ids: vec![]
                }
            ),
            Err(MarketplaceInstallError::DigestMismatch)
        );
    }

    #[test]
    fn verifier_failure_removes_staging_download() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = manifest();
        let bytes = b"archive";
        let release = release(bytes, &manifest);
        let root = temp.path().join("packages");
        let installer =
            MarketplacePackageInstaller::new(root.clone(), Fetch(bytes.to_vec()), FailingVerify);
        assert_eq!(
            installer.install(
                &release,
                &compatibility(),
                &MarketplaceConsent {
                    capability_ids: vec![]
                }
            ),
            Err(MarketplaceInstallError::ArchiveInvalid)
        );
        assert!(
            !root
                .join(format!(".{}.download", release.release_id))
                .exists()
        );
    }

    #[test]
    fn host_service_only_projects_root_verified_catalogs() {
        let temp = tempfile::tempdir().unwrap();
        let manifest = manifest();
        let installer = MarketplacePackageInstaller::new(
            temp.path().join("packages"),
            Fetch(vec![]),
            Verify(manifest),
        );
        let service = MarketplaceHostService::new(
            CatalogFetch(
                include_bytes!("../../../contracts/fixtures/marketplace-catalog-v1/catalog.json")
                    .strip_suffix(b"\n")
                    .unwrap()
                    .to_vec(),
            ),
            Root,
            installer,
        );
        assert_eq!(service.verified_catalog().unwrap().as_page().items.len(), 1);
    }

    fn compatibility() -> MarketplaceCompatibilityInput {
        MarketplaceCompatibilityInput {
            host_api: Version::new(1, 0, 0),
            platform: Platform::WindowsX64,
            max_package_bytes: MAX_MARKETPLACE_PACKAGE_BYTES,
            approved_permissions: Default::default(),
            installed_version: None,
            locally_blocked: false,
        }
    }

    struct Keys([u8; 32]);
    impl MarketplacePublisherKeyResolver for Keys {
        fn active_public_key(
            &self,
            publisher: &str,
            key_id: &str,
        ) -> Result<[u8; 32], MarketplaceInstallError> {
            ((publisher == "timetrace-labs" || publisher == "wellorbetter")
                && key_id == "fixture-key")
                .then_some(self.0)
                .ok_or(MarketplaceInstallError::ArchiveInvalid)
        }
    }

    fn fixture_manifest() -> Vec<u8> {
        include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/manifest.json")
            .strip_suffix(b"\n")
            .unwrap()
            .to_vec()
    }

    fn fixture_p1_manifest() -> Vec<u8> {
        include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/manifest-p1.json")
            .strip_suffix(b"\n")
            .unwrap()
            .to_vec()
    }

    fn fixture_first_party_bundled_manifest() -> Vec<u8> {
        include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json"
        )
        .strip_suffix(b"\n")
        .unwrap()
        .to_vec()
    }

    fn fixture_ai_recap_bundled_manifest() -> Vec<u8> {
        include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/ai-recap.manifest.json"
        )
        .strip_suffix(b"\n")
        .unwrap()
        .to_vec()
    }

    fn p1_resources(include_extra: bool) -> Vec<(&'static str, Vec<u8>)> {
        let mut resources = vec![
            (
                "resources/declarative-v1/sample-insights.card.json",
                br#"{"contribution_id":"sample-insights.card","root":{"kind":"metric","label":"Focus","value":"2h"},"schema_version":1}"#.to_vec(),
            ),
            (
                "resources/declarative-v1/sample-insights.overview.json",
                include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/resources/declarative-v1/sample-insights.overview.json")
                    .strip_suffix(b"\n")
                    .unwrap()
                    .to_vec(),
            ),
        ];
        if include_extra {
            resources.insert(
                1,
                (
                    "resources/declarative-v1/extra.json",
                    br#"{"contribution_id":"extra","root":{"kind":"text","text":"no"},"schema_version":1}"#.to_vec(),
                ),
            );
        }
        resources
    }

    fn payload_index(members: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let mut ordered = members.iter().collect::<Vec<_>>();
        ordered.sort_by(|left, right| left.0.cmp(right.0));
        let files = ordered
            .into_iter()
            .map(|(path, bytes)| {
                format!(
                    "{{\"bytes\":{},\"path\":\"{}\",\"sha256\":\"{:x}\"}}",
                    bytes.len(),
                    path,
                    Sha256::digest(bytes)
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!("{{\"files\":[{files}],\"schema_version\":1}}").into_bytes()
    }

    fn write_ttx(
        path: &Path,
        manifest: Vec<u8>,
        payload_index: Vec<u8>,
        payload: Vec<(&str, Vec<u8>)>,
        duplicate_manifest: bool,
        invalid_signature: bool,
    ) -> SigningKey {
        let signing = SigningKey::from_bytes(&[9; 32]);
        let manifest_value: Value = serde_json::from_slice(&manifest).unwrap();
        let index_value: Value = serde_json::from_slice(&payload_index).unwrap();
        let mut message = SIGNATURE_PREFIX.to_vec();
        message.extend_from_slice(
            canonical(
                &serde_json::json!({"manifest": manifest_value, "payload_index": index_value}),
            )
            .unwrap()
            .as_bytes(),
        );
        let mut signature = signing.sign(&message).to_bytes();
        if invalid_signature {
            signature[0] ^= 1;
        }
        let signature = format!(
            "{{\"algorithm\":\"ed25519\",\"key_id\":\"fixture-key\",\"value\":\"{}\"}}",
            URL_SAFE_NO_PAD.encode(signature)
        );
        let file = File::create(path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file("manifest.json", options).unwrap();
        zip.write_all(&manifest).unwrap();
        if duplicate_manifest {
            zip.start_file("manifest.json", options).unwrap();
            zip.write_all(&manifest).unwrap();
        }
        zip.start_file("payload-index.json", options).unwrap();
        zip.write_all(&payload_index).unwrap();
        zip.start_file("signature.json", options).unwrap();
        zip.write_all(signature.as_bytes()).unwrap();
        for (name, bytes) in payload {
            zip.start_file(name, options).unwrap();
            zip.write_all(&bytes).unwrap();
        }
        zip.finish().unwrap();
        signing
    }

    #[test]
    fn ttx_verifier_accepts_signed_shared_fixture() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("valid.ttx");
        let signing = write_ttx(
            &path,
            fixture_manifest(),
            b"{\"files\":[],\"schema_version\":1}".to_vec(),
            vec![],
            false,
            false,
        );
        let result = TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
            .verify_archive(&path)
            .unwrap();
        assert_eq!(result.manifest.id.as_str(), "sample-insights");
    }

    #[test]
    fn ttx_verifier_accepts_exact_p1_declarative_resource_set() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("p1-valid.ttx");
        let resources = p1_resources(false);
        let signing = write_ttx(
            &path,
            fixture_p1_manifest(),
            payload_index(&resources),
            resources,
            false,
            false,
        );
        let archive = TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
            .verify_archive(&path)
            .unwrap();
        assert_eq!(archive.manifest.contributions.len(), 4);
    }

    #[test]
    fn ttx_verifier_accepts_only_the_fixed_first_party_bundled_entitlement() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("private-flight.ttx");
        let signing = write_ttx(
            &path,
            fixture_first_party_bundled_manifest(),
            b"{\"files\":[],\"schema_version\":1}".to_vec(),
            vec![],
            false,
            false,
        );
        let archive = TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
            .verify_archive(&path)
            .expect("fixed P2 fixture");
        assert_eq!(
            marketplace_bundled_renderer_binding(&archive.manifest).unwrap(),
            &PRIVATE_FLIGHT_BUNDLED_BINDING
        );

        let path = temp.path().join("ai-recap.ttx");
        let signing = write_ttx(
            &path,
            fixture_ai_recap_bundled_manifest(),
            b"{\"files\":[],\"schema_version\":1}".to_vec(),
            vec![],
            false,
            false,
        );
        let archive = TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
            .verify_archive(&path)
            .expect("fixed AI Recap P2 fixture");
        assert_eq!(
            marketplace_bundled_renderer_binding(&archive.manifest).unwrap(),
            &AI_RECAP_BUNDLED_BINDING
        );
    }

    #[test]
    fn bundled_renderer_binding_rejects_unknown_and_cross_bound_identities() {
        let bytes = fixture_ai_recap_bundled_manifest();
        let mut ai_recap =
            PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(&bytes)
                .expect("fixture");
        ai_recap.id = timetrace_plugin_api::PluginId::new("unknown-recap").expect("id");
        assert_eq!(
            marketplace_bundled_renderer_binding(&ai_recap),
            Err(MarketplaceInstallError::ArchiveInvalid)
        );

        let mut cross_bound =
            PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(
                &fixture_ai_recap_bundled_manifest(),
            )
            .expect("fixture");
        let timetrace_plugin_api::ContributionDescriptor::Page(page) =
            &mut cross_bound.contributions[0]
        else {
            panic!("fixture page")
        };
        page.renderer = timetrace_plugin_api::RendererRef::BundledTyped {
            contract_id: timetrace_plugin_api::RendererContractId::new("private-flight-v1")
                .expect("id"),
            schema_version: 1,
        };
        assert_eq!(
            marketplace_bundled_renderer_binding(&cross_bound),
            Err(MarketplaceInstallError::ArchiveInvalid)
        );
    }

    #[test]
    fn ttx_verifier_rejects_first_party_bundled_archive_content_or_identity_changes() {
        let temp = tempfile::tempdir().unwrap();
        let payload = vec![("payload/forbidden.bin", b"no".to_vec())];
        let index = payload_index(&payload);
        let resource = vec![("resources/forbidden.json", b"{}".to_vec())];
        let resource_index = payload_index(&resource);
        let changed_renderer = String::from_utf8(fixture_first_party_bundled_manifest())
            .unwrap()
            .replace("private-flight-v1", "private-flight-v2")
            .into_bytes();
        let cases = [
            (
                "payload",
                fixture_first_party_bundled_manifest(),
                index,
                payload,
            ),
            (
                "renderer",
                changed_renderer,
                b"{\"files\":[],\"schema_version\":1}".to_vec(),
                vec![],
            ),
            (
                "resource",
                fixture_first_party_bundled_manifest(),
                resource_index,
                resource,
            ),
        ];
        for (name, manifest, index, files) in cases {
            let path = temp.path().join(format!("private-flight-{name}.ttx"));
            let signing = write_ttx(&path, manifest, index, files, false, false);
            assert_eq!(
                TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
                    .verify_archive(&path),
                Err(MarketplaceInstallError::ArchiveInvalid),
                "{name}"
            );
        }
    }

    #[test]
    fn ttx_verifier_rejects_missing_or_extra_p1_resources() {
        let temp = tempfile::tempdir().unwrap();
        let mut expected = p1_resources(false);
        let only_page = vec![expected.pop().unwrap()];
        let mut payload_activation = p1_resources(false);
        payload_activation.push(("payload/ignored", b"not executable".to_vec()));
        let cases = [
            ("missing", only_page),
            ("extra", p1_resources(true)),
            ("payload", payload_activation),
        ];
        for (name, resources) in cases {
            let path = temp.path().join(format!("p1-{name}.ttx"));
            let signing = write_ttx(
                &path,
                fixture_p1_manifest(),
                payload_index(&resources),
                resources,
                false,
                false,
            );
            assert_eq!(
                TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
                    .verify_archive(&path),
                Err(MarketplaceInstallError::ArchiveInvalid),
                "{name}"
            );
        }
    }

    #[test]
    fn registry_reload_fails_closed_when_archive_has_extra_p1_resource() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("extra-source.ttx");
        let resources = p1_resources(true);
        let signing = write_ttx(
            &source,
            fixture_p1_manifest(),
            payload_index(&resources),
            resources,
            false,
            false,
        );
        let bytes = fs::read(&source).unwrap();
        let digest = format!("{:x}", Sha256::digest(&bytes));
        let archive_rel_path = PathBuf::from("packages")
            .join("sample-insights")
            .join("1.2.3")
            .join(format!("{digest}.ttx"));
        let archive_path = temp.path().join(&archive_rel_path);
        fs::create_dir_all(archive_path.parent().unwrap()).unwrap();
        fs::write(&archive_path, bytes).unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let record = MarketplaceInstalledRecord {
            plugin_id: PluginId::new("sample-insights").unwrap(),
            publisher_id: PublisherId::new("timetrace-labs").unwrap(),
            release_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            selected_version: Version::new(1, 2, 3),
            package_digest: digest,
            archive_rel_path,
            desired_state: DesiredPluginState::Enabled,
            policy_state: MarketplaceInstalledPolicyState::Allowed,
            policy_refreshed_at_ms: Some(1),
        };
        let prepared = registry.prepare_install(record).unwrap();
        registry.commit(prepared).unwrap();
        assert_eq!(
            verified_marketplace_declarative_documents(
                &registry,
                &TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes())),
            ),
            Err(MarketplaceActivationError::ArchiveInvalid)
        );
    }

    #[test]
    fn registry_reload_projects_only_exact_p1_documents() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("valid-source.ttx");
        let resources = p1_resources(false);
        let signing = write_ttx(
            &source,
            fixture_p1_manifest(),
            payload_index(&resources),
            resources,
            false,
            false,
        );
        let bytes = fs::read(&source).unwrap();
        let digest = format!("{:x}", Sha256::digest(&bytes));
        let archive_rel_path = PathBuf::from("packages")
            .join("sample-insights")
            .join("1.2.3")
            .join(format!("{digest}.ttx"));
        let archive_path = temp.path().join(&archive_rel_path);
        fs::create_dir_all(archive_path.parent().unwrap()).unwrap();
        fs::write(&archive_path, bytes).unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let record = MarketplaceInstalledRecord {
            plugin_id: PluginId::new("sample-insights").unwrap(),
            publisher_id: PublisherId::new("timetrace-labs").unwrap(),
            release_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            selected_version: Version::new(1, 2, 3),
            package_digest: digest,
            archive_rel_path,
            desired_state: DesiredPluginState::Enabled,
            policy_state: MarketplaceInstalledPolicyState::Allowed,
            policy_refreshed_at_ms: Some(1),
        };
        let prepared = registry.prepare_install(record).unwrap();
        registry.commit(prepared).unwrap();
        let documents = verified_marketplace_declarative_documents(
            &registry,
            &TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes())),
        )
        .unwrap();
        assert_eq!(
            documents[&PluginId::new("sample-insights").unwrap()].len(),
            2
        );
    }

    #[test]
    fn registry_reload_returns_no_declarative_documents_for_a_verified_p2_entitlement() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("private-flight-source.ttx");
        let signing = write_ttx(
            &source,
            fixture_first_party_bundled_manifest(),
            b"{\"files\":[],\"schema_version\":1}".to_vec(),
            vec![],
            false,
            false,
        );
        let bytes = fs::read(&source).unwrap();
        let digest = format!("{:x}", Sha256::digest(&bytes));
        let archive_rel_path = PathBuf::from("packages")
            .join("private-flight")
            .join("1.0.0")
            .join(format!("{digest}.ttx"));
        let archive_path = temp.path().join(&archive_rel_path);
        fs::create_dir_all(archive_path.parent().unwrap()).unwrap();
        fs::write(&archive_path, bytes).unwrap();
        let registry = MarketplaceInstalledRegistry::open(temp.path().to_owned()).unwrap();
        let record = MarketplaceInstalledRecord {
            plugin_id: PluginId::new("private-flight").unwrap(),
            publisher_id: PublisherId::new("wellorbetter").unwrap(),
            release_id: "00000000-0000-4000-8000-000000000002".to_owned(),
            selected_version: Version::new(1, 0, 0),
            package_digest: digest,
            archive_rel_path,
            desired_state: DesiredPluginState::Enabled,
            policy_state: MarketplaceInstalledPolicyState::Allowed,
            policy_refreshed_at_ms: Some(1),
        };
        let prepared = registry.prepare_install(record).unwrap();
        registry.commit(prepared).unwrap();
        let documents = verified_marketplace_declarative_documents(
            &registry,
            &TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes())),
        )
        .expect("P2 entitlement is not a declarative archive");
        assert!(documents.is_empty());
    }

    #[test]
    fn ttx_verifier_rejects_profile_and_content_negative_cases() {
        let temp = tempfile::tempdir().unwrap();
        let cases = [
            ("noncanonical", b"{ \"schema_version\":1}".to_vec(), b"{\"files\":[],\"schema_version\":1}".to_vec(), vec![], false, false),
            ("capability", String::from_utf8(fixture_manifest()).unwrap().replace("usage.aggregate.read", "journal.read________").into_bytes(), b"{\"files\":[],\"schema_version\":1}".to_vec(), vec![], false, false),
            ("signature", fixture_manifest(), b"{\"files\":[],\"schema_version\":1}".to_vec(), vec![], false, true),
            ("hash", fixture_manifest(), b"{\"files\":[{\"bytes\":3,\"path\":\"payload/a\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}],\"schema_version\":1}".to_vec(), vec![("payload/a", b"abc".to_vec())], false, false),
            ("path", fixture_manifest(), b"{\"files\":[],\"schema_version\":1}".to_vec(), vec![("../payload/a", b"abc".to_vec())], false, false),
        ];
        for (name, manifest, index, payload, duplicate, invalid_signature) in cases {
            let path = temp.path().join(format!("{name}.ttx"));
            let signing = write_ttx(
                &path,
                manifest,
                index,
                payload,
                duplicate,
                invalid_signature,
            );
            assert_eq!(
                TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes()))
                    .verify_archive(&path),
                Err(MarketplaceInstallError::ArchiveInvalid),
                "{name}"
            );
        }
    }

    #[test]
    fn ttx_verifier_rejects_handcrafted_duplicate_central_directory_name() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("duplicate.ttx");
        let index = b"{\"files\":[{\"bytes\":3,\"path\":\"payload/aaaaa\",\"sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}],\"schema_version\":1}".to_vec();
        let signing = write_ttx(
            &path,
            fixture_manifest(),
            index,
            vec![("payload/aaaaa", b"abc".to_vec())],
            false,
            false,
        );
        let mut bytes = fs::read(&path).unwrap();
        let from = b"payload/aaaaa";
        let to = b"manifest.json";
        let mut rewrites = 0;
        for offset in 0..=bytes.len() - from.len() {
            if bytes[offset..].starts_with(from) {
                bytes[offset..offset + from.len()].copy_from_slice(to);
                rewrites += 1;
            }
        }
        // One occurrence is in the signed payload-index JSON; the other two
        // are the ZIP local and central-directory file names.  Verification
        // scans duplicate central names before consuming either control JSON.
        assert_eq!(rewrites, 3);
        fs::write(&path, bytes).unwrap();
        assert_eq!(
            TtxArchiveVerifier::new(Keys(signing.verifying_key().to_bytes())).verify_archive(&path),
            Err(MarketplaceInstallError::ArchiveInvalid)
        );
    }
}
