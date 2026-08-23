//! Host-owned composition root for installed plugin lifecycle and projection.

use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}},
};

use semver::Version;
use thiserror::Error;
use timetrace_plugin_api::{
    AI_CLOUD, AI_LOCAL, CURRENT_MANIFEST_SCHEMA_VERSION, ContributionDescriptor, ContributionId,
    ContributionMetadata, DesiredPluginState, DisplayMetadata, HostApiRange, LifecycleSnapshot,
    NavigationDescriptor, PageDescriptor, Platform, PluginErrorCode, PluginId, PluginManifest,
    PluginRuntimeState, PublisherId, RendererContractId, RendererRef, TimestampMillis,
    USAGE_AGGREGATE_READ,
};
use timetrace_plugin_host::{
    CatalogSnapshot, ContributionProjector, LifecycleCompletion, LifecycleHostError, LifecycleWork,
    MarketplaceArchiveVerifier, MarketplaceInstalledRegistry, PluginCatalog, PluginLifecycleHost,
    ProjectedContribution, ProjectionError, marketplace_bundled_renderer_binding,
    verified_marketplace_declarative_documents, verified_marketplace_manifests,
};
use super::store::FileLifecycleStateStore;

const START_STOP_BUDGET_MILLIS: i64 = 30_000;
const MAX_SNAPSHOT_WIRE_BYTES: usize = 1024 * 1024;

/// Opaque, host-owned cancellation signal for a trusted adapter lease.
/// Marketplace data cannot create, revive, or clear this signal.
#[derive(Debug, Clone, Default)]
pub(crate) struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    fn new() -> Self {
        Self::default()
    }

    pub(crate) fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

/// Immutable, host-compiled identity for a trusted first-party adapter.
///
/// This type has no public fields or general constructor: Marketplace data
/// cannot select an adapter, feature token, or supported version.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FirstPartyAdapterBinding {
    publisher_id: &'static str,
    plugin_id: &'static str,
    trusted_feature: &'static str,
    trusted_feature_version: u32,
}

impl FirstPartyAdapterBinding {
    /// Returns the sole AI Recap adapter identity supported by this host build.
    #[must_use]
    pub(crate) const fn ai_recap_v1() -> Self {
        Self {
            publisher_id: "wellorbetter",
            plugin_id: "ai-recap",
            trusted_feature: "ai-recap",
            trusted_feature_version: 1,
        }
    }
}

/// Non-serializable, revocable admission for one trusted first-party adapter.
///
/// It is intentionally opaque to Flutter and Marketplace packages. Callers
/// must reauthorize it before every authority-sensitive phase and use its
/// cancellation token to interrupt work when lifecycle authority changes.
#[derive(Debug)]
pub(crate) struct FirstPartyAdapterLease {
    lease_id: u64,
    binding: FirstPartyAdapterBinding,
    lifecycle_generation: u64,
    publication_revision: u64,
}

/// Flutter-facing immutable host contribution snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostContributionSnapshotDto {
    /// Host-owned monotonic complete-publication revision.
    pub revision: u64,
    /// Canonical plugin management states in plugin identifier order.
    pub plugins: Vec<HostPluginUiStateDto>,
    /// Currently projectable canonical contributions.
    pub active: Vec<HostProjectedContributionDto>,
}

/// Flutter-facing lifecycle and canonical manifest state for one plugin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostPluginUiStateDto {
    /// Canonical plugin identifier.
    pub plugin_id: String,
    /// JSON serialized only from the canonical Rust manifest DTO.
    pub manifest_json: String,
    /// Canonical desired-state wire token.
    pub desired_state: String,
    /// Canonical runtime-state wire token.
    pub runtime_state: String,
    /// Whether host API and platform compatibility passed.
    pub compatible: bool,
    /// Whether activation grants are currently satisfied.
    pub grants_satisfied: bool,
    /// Host lifecycle generation.
    pub generation: u64,
    /// Stable lifecycle failure token, when present.
    pub failure_code: Option<String>,
    /// Whether the current failure may be retried.
    pub failure_retryable: bool,
}

/// Flutter-facing active contribution serialized from canonical Rust DTOs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostProjectedContributionDto {
    /// Canonical owning plugin identifier.
    pub plugin_id: String,
    /// JSON serialized only from the canonical Rust contribution DTO.
    pub contribution_json: String,
    /// Host-generated extension route for pages and navigation destinations.
    pub route: Option<String>,
    /// Fixed-path, host-parsed P1 document for declarative page/card content.
    pub declarative_document: Option<HostDeclarativeV1DocumentDto>,
}

/// A typed, non-executable projection of one signed P1 document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostDeclarativeV1DocumentDto {
    /// Canonical contribution identity bound to the fixed archive resource path.
    pub contribution_id: String,
    /// Closed host-rendered root node.
    pub root: HostDeclarativeV1NodeDto,
}

/// Closed P1 node grammar; no markup, URLs, actions, paths, or raw JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostDeclarativeV1NodeDto {
    /// Plain inert text.
    Text { text: String },
    /// A host-rendered label/value pair.
    Metric { label: String, value: String },
    /// Vertical host layout.
    Stack {
        children: Vec<HostDeclarativeV1NodeDto>,
    },
    /// Plain inert list items.
    List { items: Vec<String> },
}

/// Stable, privacy-safe plugin service failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum PluginServiceError {
    /// The supplied identifier is not canonical.
    #[error("invalid_plugin_id")]
    InvalidPluginId,
    /// The canonical identifier is not registered by this host.
    #[error("plugin_not_found")]
    UnknownPlugin,
    /// Host persistence or synchronization is temporarily unavailable.
    #[error("plugin_service_unavailable")]
    Unavailable,
    /// The host shutdown fence has closed and no new lifecycle work is accepted.
    #[error("host_shutting_down")]
    ShuttingDown,
    /// The plugin is not currently ready and authorized for data-plane work.
    #[error("plugin_not_projectable")]
    NotProjectable,
    /// A bundled contract or internal transition violated its invariant.
    #[error("plugin_service_internal")]
    Internal,
}

struct ServiceState {
    catalog: CatalogSnapshot,
    manifest_json: BTreeMap<PluginId, String>,
    contribution_json: BTreeMap<ContributionId, String>,
    declarative_documents: BTreeMap<ContributionId, HostDeclarativeV1DocumentDto>,
    lifecycle: PluginLifecycleHost,
    projector: ContributionProjector,
    logical_time: i64,
    publication_revision: u64,
    snapshot: HostContributionSnapshotDto,
    accepting: bool,
    adapter_leases: BTreeMap<u64, CancellationToken>,
    next_adapter_lease_id: u64,
}

/// Serialized owner of installed plugin lifecycle, persistence and projection.
pub struct PluginService {
    store: Arc<FileLifecycleStateStore>,
    state: Mutex<ServiceState>,
}

impl PluginService {
    /// Creates the installed-plugin service beside the main database file.
    pub fn from_database_path(database_path: &Path) -> Result<Self, PluginServiceError> {
        let state_path = database_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("plugin-state.json");
        Self::new(state_path)
    }

    /// Creates the installed-plugin service with an explicit state file.
    pub fn new(state_path: PathBuf) -> Result<Self, PluginServiceError> {
        let catalog = PluginCatalog::build(
            Version::new(1, 0, 0),
            Platform::WindowsX64,
            std::iter::empty::<PluginManifest>(),
        )
        .map_err(|_| PluginServiceError::Internal)?;
        let catalog_snapshot = catalog.snapshot();
        let manifest_json = catalog_snapshot
            .plugins()
            .iter()
            .map(|plugin| {
                serde_json::to_string(plugin.manifest())
                    .map(|json| (plugin.manifest().id.clone(), json))
                    .map_err(|_| PluginServiceError::Internal)
            })
            .collect::<Result<BTreeMap<_, _>, _>>()?;
        let contribution_json = catalog_snapshot
            .plugins()
            .iter()
            .flat_map(|plugin| plugin.contributions())
            .map(|contribution| {
                serde_json::to_string(contribution)
                    .map(|json| (contribution.id().clone(), json))
                    .map_err(|_| PluginServiceError::Internal)
            })
            .collect::<Result<BTreeMap<_, _>, _>>()?;
        let store = Arc::new(FileLifecycleStateStore::new(state_path));
        let lifecycle =
            PluginLifecycleHost::from_catalog(&catalog, store.clone(), TimestampMillis(0))
                .map_err(map_lifecycle_error)?;
        let projector =
            ContributionProjector::new(&catalog_snapshot).map_err(map_projection_error)?;
        let mut service = Self {
            store,
            state: Mutex::new(ServiceState {
                catalog: catalog_snapshot,
                manifest_json,
                contribution_json,
                declarative_documents: BTreeMap::new(),
                lifecycle,
                projector,
                logical_time: 0,
                publication_revision: 0,
                snapshot: HostContributionSnapshotDto {
                    revision: 0,
                    plugins: Vec::new(),
                    active: Vec::new(),
                },
                accepting: true,
                adapter_leases: BTreeMap::new(),
                next_adapter_lease_id: 0,
            }),
        };
        service.initialize_runtime()?;
        Ok(service)
    }

    /// Re-discovers installed Marketplace records, re-verifies every archive,
    /// and atomically replaces the dynamic catalog. No third-party code is run.
    pub(crate) fn reload_marketplace(
        &self,
        registry: &MarketplaceInstalledRegistry,
        verifier: &dyn MarketplaceArchiveVerifier,
    ) -> Result<HostContributionSnapshotDto, PluginServiceError> {
        let dynamic = verified_marketplace_manifests(registry, verifier)
            .map_err(|_| PluginServiceError::Internal)?;
        let declarative_documents = verified_marketplace_declarative_documents(registry, verifier)
            .map_err(|_| PluginServiceError::Internal)?
            .into_values()
            .flat_map(BTreeMap::into_values)
            .map(project_declarative_document)
            .map(|document| {
                Ok((
                    ContributionId::new(document.contribution_id.clone())
                        .map_err(|_| PluginServiceError::Internal)?,
                    document,
                ))
            })
            .collect::<Result<BTreeMap<_, _>, PluginServiceError>>()?;
        let catalog = PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, dynamic)
            .map_err(|_| PluginServiceError::Internal)?;
        let catalog_snapshot = catalog.snapshot();
        let manifest_json = serialize_manifests(&catalog_snapshot)?;
        let contribution_json = serialize_contributions(&catalog_snapshot)?;
        let lifecycle =
            PluginLifecycleHost::from_catalog(&catalog, self.store.clone(), TimestampMillis(0))
                .map_err(map_lifecycle_error)?;
        let projector =
            ContributionProjector::new(&catalog_snapshot).map_err(map_projection_error)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        if !state.accepting {
            return Err(PluginServiceError::ShuttingDown);
        }
        // Archive re-verification has completed. A replacement catalog may
        // revoke policy, identity, renderer version, or consent, so cancel all
        // in-flight adapter work before publishing any replacement lifecycle.
        invalidate_first_party_adapter_leases(&mut state);
        state.catalog = catalog_snapshot;
        state.manifest_json = manifest_json;
        state.contribution_json = contribution_json;
        state.declarative_documents = declarative_documents;
        state.lifecycle = lifecycle;
        state.projector = projector;
        state.logical_time = 0;
        // Dynamic records are catalogued with their lifecycle default before
        // initialization.  Suppress every Marketplace plugin first so a
        // persisted Disabled/Blocked/Revoked record can never briefly start
        // between catalog construction and policy projection.
        suppress_marketplace_initial_activation(&mut state, registry)?;
        initialize_runtime_state(&mut state)?;
        apply_marketplace_desired_state(&mut state, registry)?;
        publish_state(&mut state)
    }

    /// Returns the latest immutable in-memory UI snapshot.
    pub fn snapshot(&self) -> Result<HostContributionSnapshotDto, PluginServiceError> {
        self.state
            .lock()
            .map(|state| state.snapshot.clone())
            .map_err(|_| PluginServiceError::Unavailable)
    }

    /// Runs one installed-plugin data-plane operation while holding the same lifecycle
    /// gate used by enable/disable/shutdown. Revocation cannot race admission.
    pub(crate) fn with_projectable<T>(
        &self,
        plugin_id: &str,
        operation: impl FnOnce() -> T,
    ) -> Result<T, PluginServiceError> {
        let plugin_id =
            PluginId::new(plugin_id.to_owned()).map_err(|_| PluginServiceError::InvalidPluginId)?;
        let state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        if !state.accepting {
            return Err(PluginServiceError::ShuttingDown);
        }
        let lifecycle = state
            .lifecycle
            .snapshot(&plugin_id)
            // Data-plane callers must not be able to distinguish a missing
            // entitlement from an installed-but-not-projectable one.  In
            // particular, legacy private-flight operations use this same
            // opaque denial after uninstall or policy revocation.
            .map_err(|_| PluginServiceError::NotProjectable)?;
        if !lifecycle.is_projectable() {
            return Err(PluginServiceError::NotProjectable);
        }
        Ok(operation())
    }

    /// Atomically admits one compiled first-party adapter against the current
    /// verified Marketplace entitlement and lifecycle state.
    pub(crate) fn acquire_first_party_adapter(
        &self,
        binding: FirstPartyAdapterBinding,
    ) -> Result<FirstPartyAdapterLease, PluginServiceError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        let lifecycle_generation = authorize_first_party_adapter(&state, binding)?;
        state.next_adapter_lease_id = state
            .next_adapter_lease_id
            .checked_add(1)
            .ok_or(PluginServiceError::Internal)?;
        let lease_id = state.next_adapter_lease_id;
        state
            .adapter_leases
            .insert(lease_id, CancellationToken::new());
        Ok(FirstPartyAdapterLease {
            lease_id,
            binding,
            lifecycle_generation,
            publication_revision: state.publication_revision,
        })
    }

    /// Reauthorizes an opaque adapter lease and returns its cancellation signal.
    ///
    /// A disable, policy reload/revocation, or host stop cancels and removes
    /// every outstanding lease before it changes lifecycle state. This check is
    /// repeated under the same mutex used by lifecycle mutations, so callers
    /// cannot race authority admission.
    pub(crate) fn reauthorize_first_party_adapter(
        &self,
        lease: &FirstPartyAdapterLease,
    ) -> Result<CancellationToken, PluginServiceError> {
        let state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        let lifecycle_generation = authorize_first_party_adapter(&state, lease.binding)?;
        if lifecycle_generation != lease.lifecycle_generation
            || state.publication_revision != lease.publication_revision
        {
            return Err(PluginServiceError::NotProjectable);
        }
        state
            .adapter_leases
            .get(&lease.lease_id)
            .cloned()
            .filter(|token| !token.is_cancelled())
            .ok_or(PluginServiceError::NotProjectable)
    }

    /// Runs an adapter action only while its exact trusted entitlement remains
    /// authorized. The closure executes while the lifecycle mutex is held.
    pub(crate) fn with_first_party_adapter<T>(
        &self,
        lease: &FirstPartyAdapterLease,
        operation: impl FnOnce(CancellationToken) -> T,
    ) -> Result<T, PluginServiceError> {
        let state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        let lifecycle_generation = authorize_first_party_adapter(&state, lease.binding)?;
        if lifecycle_generation != lease.lifecycle_generation
            || state.publication_revision != lease.publication_revision
        {
            return Err(PluginServiceError::NotProjectable);
        }
        let cancellation = state
            .adapter_leases
            .get(&lease.lease_id)
            .cloned()
            .filter(|token| !token.is_cancelled())
            .ok_or(PluginServiceError::NotProjectable)?;
        Ok(operation(cancellation))
    }

    /// Enables or disables one known plugin and publishes atomically.
    pub fn set_enabled(
        &self,
        plugin_id: &str,
        enabled: bool,
    ) -> Result<HostContributionSnapshotDto, PluginServiceError> {
        let plugin_id =
            PluginId::new(plugin_id.to_owned()).map_err(|_| PluginServiceError::InvalidPluginId)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        if !state.accepting {
            return Err(PluginServiceError::ShuttingDown);
        }
        invalidate_first_party_adapter_leases(&mut state);
        if state.catalog.find(&plugin_id).is_none() {
            return Err(PluginServiceError::UnknownPlugin);
        }
        if enabled {
            enable_bundled(&mut state, &plugin_id)?;
        } else {
            disable_bundled(&mut state, &plugin_id)?;
        }
        publish_state(&mut state)
    }

    /// Stops every active runtime while preserving desired state.
    pub fn stop_all(&self) -> Result<HostContributionSnapshotDto, PluginServiceError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| PluginServiceError::Unavailable)?;
        // Close the admission gate before stopping anything. This makes a
        // timed-out Flutter mutation harmless even if it reaches Rust late.
        state.accepting = false;
        invalidate_first_party_adapter_leases(&mut state);
        let plugin_ids = state
            .lifecycle
            .snapshots()
            .into_iter()
            .filter(|snapshot| {
                matches!(
                    snapshot.runtime_state,
                    PluginRuntimeState::Ready | PluginRuntimeState::Starting
                )
            })
            .map(|snapshot| snapshot.plugin_id)
            .collect::<Vec<_>>();
        for plugin_id in plugin_ids {
            stop_bundled(&mut state, &plugin_id)?;
        }
        publish_state(&mut state)
    }

    fn initialize_runtime(&mut self) -> Result<(), PluginServiceError> {
        let state = self
            .state
            .get_mut()
            .map_err(|_| PluginServiceError::Unavailable)?;
        initialize_runtime_state(state)?;
        publish_state(state)?;
        Ok(())
    }
}

fn authorize_first_party_adapter(
    state: &ServiceState,
    binding: FirstPartyAdapterBinding,
) -> Result<u64, PluginServiceError> {
    if !state.accepting {
        return Err(PluginServiceError::ShuttingDown);
    }
    let plugin_id =
        PluginId::new(binding.plugin_id.to_owned()).map_err(|_| PluginServiceError::Internal)?;
    let plugin = state
        .catalog
        .find(&plugin_id)
        .ok_or(PluginServiceError::NotProjectable)?;
    let manifest = plugin.manifest();
    let host_binding = marketplace_bundled_renderer_binding(manifest)
        .map_err(|_| PluginServiceError::NotProjectable)?;
    if host_binding.publisher_id != binding.publisher_id
        || host_binding.plugin_id != binding.plugin_id
        || host_binding.renderer_contract_id != binding.trusted_feature_versioned_contract()
        || host_binding.renderer_schema_version != binding.trusted_feature_version
        || manifest.publisher.as_str() != binding.publisher_id
        || manifest.id.as_str() != binding.plugin_id
        || !has_exact_adapter_capability_shape(manifest, binding)
    {
        return Err(PluginServiceError::NotProjectable);
    }
    let lifecycle = state
        .lifecycle
        .snapshot(&plugin_id)
        .map_err(|_| PluginServiceError::NotProjectable)?;
    if !lifecycle.is_projectable() || !lifecycle.grants_satisfied {
        return Err(PluginServiceError::NotProjectable);
    }
    Ok(lifecycle.generation)
}

impl FirstPartyAdapterBinding {
    fn trusted_feature_versioned_contract(self) -> &'static str {
        match (self.trusted_feature, self.trusted_feature_version) {
            ("ai-recap", 1) => "ai-recap-v1",
            _ => "",
        }
    }
}

fn has_exact_adapter_capability_shape(
    manifest: &PluginManifest,
    binding: FirstPartyAdapterBinding,
) -> bool {
    if binding != FirstPartyAdapterBinding::ai_recap_v1() {
        return false;
    }
    let capabilities = manifest
        .requested_capabilities
        .iter()
        .map(|request| request.id.as_str())
        .collect::<BTreeSet<_>>();
    capabilities.len() == manifest.requested_capabilities.len()
        && capabilities.contains(USAGE_AGGREGATE_READ)
        && (capabilities.contains(AI_LOCAL) || capabilities.contains(AI_CLOUD))
        && capabilities
            .iter()
            .all(|capability| matches!(*capability, USAGE_AGGREGATE_READ | AI_LOCAL | AI_CLOUD))
}

fn invalidate_first_party_adapter_leases(state: &mut ServiceState) {
    for cancellation in state.adapter_leases.values() {
        cancellation.cancel();
    }
    state.adapter_leases.clear();
}

fn serialize_manifests(
    catalog: &CatalogSnapshot,
) -> Result<BTreeMap<PluginId, String>, PluginServiceError> {
    catalog
        .plugins()
        .iter()
        .map(|plugin| {
            serde_json::to_string(plugin.manifest())
                .map(|json| (plugin.manifest().id.clone(), json))
                .map_err(|_| PluginServiceError::Internal)
        })
        .collect()
}

fn serialize_contributions(
    catalog: &CatalogSnapshot,
) -> Result<BTreeMap<ContributionId, String>, PluginServiceError> {
    catalog
        .plugins()
        .iter()
        .flat_map(|plugin| plugin.contributions())
        .map(|contribution| {
            serde_json::to_string(contribution)
                .map(|json| (contribution.id().clone(), json))
                .map_err(|_| PluginServiceError::Internal)
        })
        .collect()
}

fn initialize_runtime_state(state: &mut ServiceState) -> Result<(), PluginServiceError> {
    for snapshot in state.lifecycle.snapshots() {
        let now = next_time(state)?;
        state
            .lifecycle
            .set_grants_satisfied(&snapshot.plugin_id, true, now)
            .map_err(map_lifecycle_error)?;
        if snapshot.desired_state == DesiredPluginState::Enabled {
            start_bundled(state, &snapshot.plugin_id)?;
        }
    }
    Ok(())
}

fn apply_marketplace_desired_state(
    state: &mut ServiceState,
    registry: &MarketplaceInstalledRegistry,
) -> Result<(), PluginServiceError> {
    for record in registry
        .load()
        .map_err(|_| PluginServiceError::Unavailable)?
    {
        if !record.policy_state.permits_activation()
            || state.catalog.find(&record.plugin_id).is_none()
        {
            continue;
        }
        if record.desired_state == DesiredPluginState::Enabled {
            enable_bundled(state, &record.plugin_id)?;
        } else {
            disable_bundled(state, &record.plugin_id)?;
        }
    }
    Ok(())
}

fn suppress_marketplace_initial_activation(
    state: &mut ServiceState,
    registry: &MarketplaceInstalledRegistry,
) -> Result<(), PluginServiceError> {
    for record in registry
        .load()
        .map_err(|_| PluginServiceError::Unavailable)?
    {
        if state.catalog.find(&record.plugin_id).is_some() {
            disable_bundled(state, &record.plugin_id)?;
        }
    }
    Ok(())
}

fn publish_state(
    state: &mut ServiceState,
) -> Result<HostContributionSnapshotDto, PluginServiceError> {
    let catalog = state.catalog.clone();
    let manifests = state.manifest_json.clone();
    let contributions = state.contribution_json.clone();
    let declarative_documents = state.declarative_documents.clone();
    publish(
        &catalog,
        &manifests,
        &contributions,
        &declarative_documents,
        state,
    )
}

fn project_declarative_document(
    document: timetrace_plugin_api::DeclarativeV1Document,
) -> HostDeclarativeV1DocumentDto {
    HostDeclarativeV1DocumentDto {
        contribution_id: document.contribution_id.to_string(),
        root: project_declarative_node(document.root),
    }
}

fn project_declarative_node(
    node: timetrace_plugin_api::DeclarativeV1Node,
) -> HostDeclarativeV1NodeDto {
    match node {
        timetrace_plugin_api::DeclarativeV1Node::Text { text } => {
            HostDeclarativeV1NodeDto::Text { text }
        }
        timetrace_plugin_api::DeclarativeV1Node::Metric { label, value } => {
            HostDeclarativeV1NodeDto::Metric { label, value }
        }
        timetrace_plugin_api::DeclarativeV1Node::Stack { children } => {
            HostDeclarativeV1NodeDto::Stack {
                children: children.into_iter().map(project_declarative_node).collect(),
            }
        }
        timetrace_plugin_api::DeclarativeV1Node::List { items } => {
            HostDeclarativeV1NodeDto::List { items }
        }
    }
}

#[cfg(test)]
const PRIVATE_FLIGHT_PLUGIN_ID: &str = "private-flight";

#[cfg(test)]
fn canonical_private_flight_manifest() -> Result<PluginManifest, PluginServiceError> {
    let plugin_id = PluginId::new(PRIVATE_FLIGHT_PLUGIN_ID.to_owned())
        .map_err(|_| PluginServiceError::Internal)?;
    let page_id = ContributionId::new("private-flight.page".to_owned())
        .map_err(|_| PluginServiceError::Internal)?;
    let renderer = RendererRef::BundledTyped {
        contract_id: RendererContractId::new("private-flight-v1".to_owned())
            .map_err(|_| PluginServiceError::Internal)?,
        schema_version: 1,
    };
    let metadata = |id: ContributionId, title: &str, order: i32| ContributionMetadata {
        id,
        display: DisplayMetadata {
            title: title.to_owned(),
            description: None,
            icon: Some("flight".to_owned()),
        },
        order,
        required_capabilities: Vec::new(),
    };
    Ok(PluginManifest {
        schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
        id: plugin_id,
        publisher: PublisherId::new("wellorbetter".to_owned())
            .map_err(|_| PluginServiceError::Internal)?,
        display_name: "起飞记录".to_owned(),
        description: Some("本地专注与私人飞行记录".to_owned()),
        version: Version::new(1, 0, 0),
        host_api: HostApiRange::parse(">=1.0.0, <2.0.0")
            .map_err(|_| PluginServiceError::Internal)?,
        platforms: vec![Platform::WindowsX64],
        contributions: vec![
            ContributionDescriptor::Page(PageDescriptor {
                metadata: metadata(page_id.clone(), "起飞记录", 0),
                view_id: "flight".to_owned(),
                renderer,
            }),
            ContributionDescriptor::Navigation(NavigationDescriptor {
                metadata: metadata(
                    ContributionId::new("private-flight.navigation".to_owned())
                        .map_err(|_| PluginServiceError::Internal)?,
                    "起飞记录",
                    0,
                ),
                page_id,
            }),
        ],
        requested_capabilities: Vec::new(),
    })
}

fn enable_bundled(
    state: &mut ServiceState,
    plugin_id: &PluginId,
) -> Result<(), PluginServiceError> {
    let now = next_time(state)?;
    state
        .lifecycle
        .enable(plugin_id, now)
        .map_err(map_lifecycle_error)?;
    let now = next_time(state)?;
    state
        .lifecycle
        .set_grants_satisfied(plugin_id, true, now)
        .map_err(map_lifecycle_error)?;
    start_bundled(state, plugin_id)
}

fn start_bundled(state: &mut ServiceState, plugin_id: &PluginId) -> Result<(), PluginServiceError> {
    let now = next_time(state)?;
    let deadline = deadline(now)?;
    let decision = state
        .lifecycle
        .start(plugin_id, now, deadline)
        .map_err(map_lifecycle_error)?;
    if let Some(LifecycleWork::Start { generation, .. }) = decision.work() {
        let generation = *generation;
        let completed_at = next_time(state)?;
        state
            .lifecycle
            .complete_start(
                plugin_id,
                generation,
                LifecycleCompletion::Succeeded,
                completed_at,
            )
            .map_err(map_lifecycle_error)?;
    }
    Ok(())
}

fn disable_bundled(
    state: &mut ServiceState,
    plugin_id: &PluginId,
) -> Result<(), PluginServiceError> {
    let now = next_time(state)?;
    let deadline = deadline(now)?;
    let decision = state
        .lifecycle
        .disable(plugin_id, now, deadline)
        .map_err(map_lifecycle_error)?;
    complete_stop_work(state, plugin_id, decision.work())
}

fn stop_bundled(state: &mut ServiceState, plugin_id: &PluginId) -> Result<(), PluginServiceError> {
    let now = next_time(state)?;
    let deadline = deadline(now)?;
    let decision = state
        .lifecycle
        .stop(plugin_id, now, deadline)
        .map_err(map_lifecycle_error)?;
    complete_stop_work(state, plugin_id, decision.work())
}

fn complete_stop_work(
    state: &mut ServiceState,
    plugin_id: &PluginId,
    work: Option<&LifecycleWork>,
) -> Result<(), PluginServiceError> {
    if let Some(LifecycleWork::Stop { generation, .. }) = work {
        let generation = *generation;
        let completed_at = next_time(state)?;
        state
            .lifecycle
            .complete_stop(
                plugin_id,
                generation,
                LifecycleCompletion::Succeeded,
                completed_at,
            )
            .map_err(map_lifecycle_error)?;
    }
    Ok(())
}

fn publish(
    catalog: &CatalogSnapshot,
    manifest_json: &BTreeMap<PluginId, String>,
    contribution_json: &BTreeMap<ContributionId, String>,
    declarative_documents: &BTreeMap<ContributionId, HostDeclarativeV1DocumentDto>,
    state: &mut ServiceState,
) -> Result<HostContributionSnapshotDto, PluginServiceError> {
    let publication_revision = state
        .publication_revision
        .checked_add(1)
        .ok_or(PluginServiceError::Internal)?;
    let lifecycles = state.lifecycle.snapshots();
    let projected = state
        .projector
        .update(publication_revision, lifecycles.clone())
        .map_err(map_projection_error)?;
    let lifecycle_by_id = lifecycles
        .into_iter()
        .map(|snapshot| (snapshot.plugin_id.clone(), snapshot))
        .collect::<BTreeMap<_, _>>();
    let plugins = catalog
        .plugins()
        .iter()
        .filter_map(|plugin| {
            let lifecycle = lifecycle_by_id.get(&plugin.manifest().id)?;
            let manifest_json = manifest_json.get(&plugin.manifest().id)?;
            Some(plugin_ui_state(lifecycle, manifest_json.clone()))
        })
        .collect();
    let mut projected_values = projected
        .navigation()
        .iter()
        .chain(projected.pages())
        .chain(projected.dashboard_cards())
        .chain(projected.dashboard_carousels())
        .chain(projected.settings())
        .chain(projected.commands())
        .collect::<Vec<_>>();
    projected_values.sort_by(|left, right| {
        left.descriptor()
            .metadata()
            .order
            .cmp(&right.descriptor().metadata().order)
            .then_with(|| left.descriptor().id().cmp(right.descriptor().id()))
    });
    let active = projected_values
        .into_iter()
        .filter_map(|contribution| {
            projected_dto(contribution, contribution_json, declarative_documents)
        })
        .collect();
    let snapshot = HostContributionSnapshotDto {
        revision: publication_revision,
        plugins,
        active,
    };
    ensure_snapshot_within_budget(&snapshot)?;
    state.publication_revision = publication_revision;
    state.snapshot = snapshot.clone();
    Ok(snapshot)
}

fn ensure_snapshot_within_budget(
    snapshot: &HostContributionSnapshotDto,
) -> Result<(), PluginServiceError> {
    // Fixed allowances cover scalar fields, collection framing and FRB wire
    // metadata. Dynamic UTF-8 payloads are counted exactly before publication.
    let mut bytes = 64usize;
    for plugin in &snapshot.plugins {
        bytes = bytes
            .checked_add(128)
            .and_then(|value| value.checked_add(plugin.plugin_id.len()))
            .and_then(|value| value.checked_add(plugin.manifest_json.len()))
            .and_then(|value| value.checked_add(plugin.desired_state.len()))
            .and_then(|value| value.checked_add(plugin.runtime_state.len()))
            .and_then(|value| value.checked_add(plugin.failure_code.as_deref().map_or(0, str::len)))
            .ok_or(PluginServiceError::Unavailable)?;
    }
    for contribution in &snapshot.active {
        bytes = bytes
            .checked_add(96)
            .and_then(|value| value.checked_add(contribution.plugin_id.len()))
            .and_then(|value| value.checked_add(contribution.contribution_json.len()))
            .and_then(|value| value.checked_add(contribution.route.as_deref().map_or(0, str::len)))
            .ok_or(PluginServiceError::Unavailable)?;
    }
    if bytes > MAX_SNAPSHOT_WIRE_BYTES {
        return Err(PluginServiceError::Unavailable);
    }
    Ok(())
}

fn plugin_ui_state(lifecycle: &LifecycleSnapshot, manifest_json: String) -> HostPluginUiStateDto {
    HostPluginUiStateDto {
        plugin_id: lifecycle.plugin_id.to_string(),
        manifest_json,
        desired_state: desired_state_token(lifecycle.desired_state).to_owned(),
        runtime_state: runtime_state_token(lifecycle.runtime_state).to_owned(),
        compatible: lifecycle.compatible,
        grants_satisfied: lifecycle.grants_satisfied,
        generation: lifecycle.generation,
        failure_code: lifecycle
            .failure
            .as_ref()
            .map(|failure| error_code_token(failure.code).to_owned()),
        failure_retryable: lifecycle
            .failure
            .as_ref()
            .is_some_and(|failure| failure.retryable),
    }
}

fn projected_dto(
    projected: &ProjectedContribution,
    contribution_json: &BTreeMap<ContributionId, String>,
    declarative_documents: &BTreeMap<ContributionId, HostDeclarativeV1DocumentDto>,
) -> Option<HostProjectedContributionDto> {
    Some(HostProjectedContributionDto {
        plugin_id: projected.plugin_id().to_string(),
        contribution_json: contribution_json.get(projected.descriptor().id())?.clone(),
        route: projected.route().map(str::to_owned),
        declarative_document: declarative_documents
            .get(projected.descriptor().id())
            .cloned(),
    })
}

fn next_time(state: &mut ServiceState) -> Result<TimestampMillis, PluginServiceError> {
    state.logical_time = state
        .logical_time
        .checked_add(1)
        .ok_or(PluginServiceError::Internal)?;
    Ok(TimestampMillis(state.logical_time))
}

fn deadline(now: TimestampMillis) -> Result<TimestampMillis, PluginServiceError> {
    now.0
        .checked_add(START_STOP_BUDGET_MILLIS)
        .map(TimestampMillis)
        .ok_or(PluginServiceError::Internal)
}

fn map_lifecycle_error(error: LifecycleHostError) -> PluginServiceError {
    match error {
        LifecycleHostError::UnknownPlugin => PluginServiceError::UnknownPlugin,
        LifecycleHostError::Store(_) => PluginServiceError::Unavailable,
        LifecycleHostError::InvalidDeadline | LifecycleHostError::GenerationExhausted => {
            PluginServiceError::Internal
        }
    }
}

fn map_projection_error(_error: ProjectionError) -> PluginServiceError {
    PluginServiceError::Internal
}

fn desired_state_token(state: DesiredPluginState) -> &'static str {
    match state {
        DesiredPluginState::Disabled => "disabled",
        DesiredPluginState::Enabled => "enabled",
    }
}

fn runtime_state_token(state: PluginRuntimeState) -> &'static str {
    match state {
        PluginRuntimeState::Registered => "registered",
        PluginRuntimeState::Incompatible => "incompatible",
        PluginRuntimeState::Disabled => "disabled",
        PluginRuntimeState::Starting => "starting",
        PluginRuntimeState::Ready => "ready",
        PluginRuntimeState::Stopping => "stopping",
        PluginRuntimeState::Failed => "failed",
    }
}

fn error_code_token(code: PluginErrorCode) -> &'static str {
    match code {
        PluginErrorCode::ValidationFailed => "validation_failed",
        PluginErrorCode::NotFound => "not_found",
        PluginErrorCode::DuplicateId => "duplicate_id",
        PluginErrorCode::IncompatibleHost => "incompatible_host",
        PluginErrorCode::UnsupportedPlatform => "unsupported_platform",
        PluginErrorCode::PermissionDenied => "permission_denied",
        PluginErrorCode::LimitExceeded => "limit_exceeded",
        PluginErrorCode::InvalidState => "invalid_state",
        PluginErrorCode::StartFailed => "start_failed",
        PluginErrorCode::StopFailed => "stop_failed",
        PluginErrorCode::Timeout => "timeout",
        PluginErrorCode::Cancelled => "cancelled",
        PluginErrorCode::ModelFailed => "model_failed",
        PluginErrorCode::Unavailable => "unavailable",
        PluginErrorCode::Internal => "internal",
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, io::Write, path::PathBuf};

    use sha2::{Digest, Sha256};
    use tempfile::TempDir;
    use timetrace_plugin_host::{
        MarketplaceArchiveVerifier, MarketplaceInstalledPolicyState, MarketplaceInstalledRecord,
        MarketplaceInstalledRegistry, VerifiedMarketplaceArchive,
    };

    use super::*;

    fn service(temp: &TempDir) -> PluginService {
        PluginService::new(temp.path().join("plugin-state.json")).expect("plugin service")
    }

    #[derive(Clone)]
    struct StaticArchiveVerifier(PluginManifest);
    impl MarketplaceArchiveVerifier for StaticArchiveVerifier {
        fn verify_archive(
            &self,
            _: &std::path::Path,
        ) -> Result<VerifiedMarketplaceArchive, timetrace_plugin_host::MarketplaceInstallError>
        {
            Ok(VerifiedMarketplaceArchive {
                manifest: self.0.clone(),
            })
        }
    }

    fn p1_manifest() -> PluginManifest {
        let mut manifest = PluginManifest::parse_ttx_v1_canonical(
            include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/manifest-p1.json")
                .strip_suffix(b"\n")
                .unwrap_or(include_bytes!(
                    "../../../contracts/fixtures/ttx-manifest-v1/manifest-p1.json"
                )),
        )
        .expect("P1 fixture manifest");
        manifest
            .contributions
            .retain(|contribution| matches!(contribution, ContributionDescriptor::Page(_)));
        manifest
    }

    fn registry_record(
        root: &std::path::Path,
        manifest: &PluginManifest,
        desired_state: DesiredPluginState,
        policy_state: MarketplaceInstalledPolicyState,
    ) -> MarketplaceInstalledRecord {
        let mut archive = Vec::new();
        {
            let cursor = std::io::Cursor::new(&mut archive);
            let mut zip = zip::ZipWriter::new(cursor);
            let options = zip::write::SimpleFileOptions::default();
            if manifest
                .validate_marketplace_first_party_bundled_v1_profile()
                .is_ok()
            {
                for (name, bytes) in [
                    ("manifest.json", b"{}".as_slice()),
                    ("payload-index.json", b"{}".as_slice()),
                    ("signature.json", b"{}".as_slice()),
                ] {
                    zip.start_file(name, options).expect("control entry");
                    zip.write_all(bytes).expect("control bytes");
                }
            } else {
                for contribution in &manifest.contributions {
                    let ContributionDescriptor::Page(page) = contribution else {
                        continue;
                    };
                    zip.start_file(
                        timetrace_plugin_api::DeclarativeV1Document::resource_path(
                            &page.metadata.id,
                        ),
                        options,
                    )
                    .expect("resource entry");
                    zip.write_all(include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/resources/declarative-v1/sample-insights.overview.json")).expect("resource bytes");
                }
            }
            zip.finish().expect("finish archive");
        }
        let digest = format!("{:x}", Sha256::digest(&archive));
        let relative = PathBuf::from("packages")
            .join(manifest.id.as_str())
            .join(manifest.version.to_string())
            .join(format!("{digest}.ttx"));
        let path = root.join(&relative);
        fs::create_dir_all(path.parent().expect("archive parent")).expect("create archive parent");
        fs::write(path, archive).expect("write archive");
        MarketplaceInstalledRecord {
            plugin_id: manifest.id.clone(),
            publisher_id: manifest.publisher.clone(),
            release_id: "123e4567-e89b-12d3-a456-426614174000".into(),
            selected_version: manifest.version.clone(),
            package_digest: digest,
            archive_rel_path: relative,
            desired_state,
            policy_state,
            policy_refreshed_at_ms: Some(1),
        }
    }

    fn installed_p1_service(temp: &TempDir) -> PluginService {
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        let manifest = p1_manifest();
        let prepared = registry
            .prepare_install(registry_record(
                registry.root(),
                &manifest,
                DesiredPluginState::Disabled,
                MarketplaceInstalledPolicyState::Allowed,
            ))
            .expect("prepare");
        registry.commit(prepared).expect("commit");
        let service = service(temp);
        service
            .reload_marketplace(&registry, &StaticArchiveVerifier(manifest))
            .expect("reload");
        service
    }

    fn first_party_private_flight_manifest() -> PluginManifest {
        PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(
            include_bytes!(
                "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json"
            )
            .strip_suffix(b"\n")
            .unwrap_or(include_bytes!(
                "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json"
            )),
        )
        .expect("first-party fixture manifest")
    }

    fn first_party_ai_recap_manifest() -> PluginManifest {
        PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(
            include_bytes!(
                "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/ai-recap.manifest.json"
            )
            .strip_suffix(b"\n")
            .unwrap_or(include_bytes!(
                "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/ai-recap.manifest.json"
            )),
        )
        .expect("AI Recap first-party fixture manifest")
    }

    fn installed_private_flight_service(
        temp: &TempDir,
        desired_state: DesiredPluginState,
        policy_state: MarketplaceInstalledPolicyState,
    ) -> PluginService {
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        let manifest = first_party_private_flight_manifest();
        let prepared = registry
            .prepare_install(registry_record(
                registry.root(),
                &manifest,
                desired_state,
                policy_state,
            ))
            .expect("prepare");
        registry.commit(prepared).expect("commit");
        let service = service(temp);
        service
            .reload_marketplace(&registry, &StaticArchiveVerifier(manifest))
            .expect("reload");
        service
    }

    fn installed_ai_recap_service(
        temp: &TempDir,
        desired_state: DesiredPluginState,
        policy_state: MarketplaceInstalledPolicyState,
    ) -> PluginService {
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        let manifest = first_party_ai_recap_manifest();
        let prepared = registry
            .prepare_install(registry_record(
                registry.root(),
                &manifest,
                desired_state,
                policy_state,
            ))
            .expect("prepare");
        registry.commit(prepared).expect("commit");
        let service = service(temp);
        service
            .reload_marketplace(&registry, &StaticArchiveVerifier(manifest))
            .expect("reload");
        service
    }

    #[test]
    fn marketplace_reload_discovers_enabled_record_on_restart_and_honors_disabled_and_blocked() {
        let temp = TempDir::new().expect("temp dir");
        let manifest = p1_manifest();
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        let record = registry_record(
            registry.root(),
            &manifest,
            DesiredPluginState::Enabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        let prepared = registry.prepare_install(record).expect("prepare");
        registry.commit(prepared).expect("commit");
        let verifier = StaticArchiveVerifier(manifest.clone());
        let first = service(&temp);
        let active = first
            .reload_marketplace(&registry, &verifier)
            .expect("reload");
        assert!(
            active
                .plugins
                .iter()
                .any(|p| p.plugin_id == "sample-insights" && p.runtime_state == "ready")
        );
        assert!(active.active.iter().any(|contribution| {
            contribution.plugin_id == "sample-insights"
                && matches!(
                    contribution
                        .declarative_document
                        .as_ref()
                        .map(|document| &document.root),
                    Some(HostDeclarativeV1NodeDto::Stack { .. })
                )
        }));
        drop(first);
        let restarted = service(&temp);
        let recovered = restarted
            .reload_marketplace(&registry, &verifier)
            .expect("restart reload");
        assert!(
            recovered
                .plugins
                .iter()
                .any(|p| p.plugin_id == "sample-insights" && p.runtime_state == "ready")
        );
        registry
            .set_desired_state(&manifest.id, DesiredPluginState::Disabled)
            .expect("disable desired");
        let disabled = restarted
            .reload_marketplace(&registry, &verifier)
            .expect("disabled reload");
        assert!(
            disabled
                .plugins
                .iter()
                .any(|p| p.plugin_id == "sample-insights" && p.runtime_state == "disabled")
        );
        registry
            .set_policy_state(&manifest.id, MarketplaceInstalledPolicyState::Blocked)
            .expect("block policy");
        let blocked = restarted
            .reload_marketplace(&registry, &verifier)
            .expect("blocked reload");
        assert!(
            !blocked
                .plugins
                .iter()
                .any(|p| p.plugin_id == "sample-insights")
        );
    }

    #[test]
    fn marketplace_collision_fails_closed_without_replacing_published_snapshot() {
        let temp = TempDir::new().expect("temp dir");
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        let manifest = canonical_private_flight_manifest().expect("bundled manifest");
        let record = registry_record(
            registry.root(),
            &manifest,
            DesiredPluginState::Enabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        let prepared = registry.prepare_install(record).expect("prepare");
        registry.commit(prepared).expect("commit");
        let subject = service(&temp);
        let before = subject.snapshot().expect("before");
        assert_eq!(
            subject.reload_marketplace(&registry, &StaticArchiveVerifier(manifest)),
            Err(PluginServiceError::Internal)
        );
        assert_eq!(subject.snapshot().expect("after"), before);
    }

    #[test]
    fn fresh_service_has_no_static_private_flight_entitlement_or_projection() {
        let temp = TempDir::new().expect("temp dir");
        let service = service(&temp);
        let snapshot = service.snapshot().expect("snapshot");
        assert!(snapshot.active.is_empty());
        assert!(snapshot.plugins.is_empty());
        assert_eq!(
            service.with_projectable(PRIVATE_FLIGHT_PLUGIN_ID, || ()),
            Err(PluginServiceError::NotProjectable)
        );
    }

    #[test]
    fn first_party_private_flight_visibility_follows_installed_desired_and_policy_state() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_private_flight_service(
            &temp,
            DesiredPluginState::Disabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        assert!(service.snapshot().expect("disabled").active.is_empty());
        assert_eq!(
            service.with_projectable(PRIVATE_FLIGHT_PLUGIN_ID, || ()),
            Err(PluginServiceError::NotProjectable)
        );

        let enabled = service
            .set_enabled(PRIVATE_FLIGHT_PLUGIN_ID, true)
            .expect("enable entitlement");
        assert_eq!(enabled.active.len(), 2);
        assert!(enabled.active.iter().all(|entry| {
            entry.route.as_deref() == Some("/extensions/private-flight/private-flight")
        }));
        assert_eq!(
            service.with_projectable(PRIVATE_FLIGHT_PLUGIN_ID, || 7),
            Ok(7)
        );

        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        registry
            .set_policy_state(
                &PluginId::new(PRIVATE_FLIGHT_PLUGIN_ID.to_owned()).expect("plugin id"),
                MarketplaceInstalledPolicyState::Revoked,
            )
            .expect("revoke");
        let revoked = service
            .reload_marketplace(
                &registry,
                &StaticArchiveVerifier(first_party_private_flight_manifest()),
            )
            .expect("reload revoked");
        assert!(revoked.active.is_empty());
        assert_eq!(
            service.with_projectable(PRIVATE_FLIGHT_PLUGIN_ID, || ()),
            Err(PluginServiceError::NotProjectable)
        );
    }

    #[test]
    fn ai_recap_adapter_requires_verified_enabled_entitlement_and_grants() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_ai_recap_service(
            &temp,
            DesiredPluginState::Disabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        let binding = FirstPartyAdapterBinding::ai_recap_v1();
        assert!(matches!(
            service.acquire_first_party_adapter(binding),
            Err(PluginServiceError::NotProjectable)
        ));

        service
            .set_enabled("ai-recap", true)
            .expect("enable AI Recap");
        let lease = service
            .acquire_first_party_adapter(binding)
            .expect("admit adapter");
        let cancellation = service
            .reauthorize_first_party_adapter(&lease)
            .expect("reauthorize adapter");
        assert!(!cancellation.is_cancelled());
        assert_eq!(
            service.with_first_party_adapter(&lease, |token| token.is_cancelled()),
            Ok(false)
        );
    }

    #[test]
    fn ai_recap_adapter_leases_cancel_before_disable_reload_and_stop() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_ai_recap_service(
            &temp,
            DesiredPluginState::Enabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        let binding = FirstPartyAdapterBinding::ai_recap_v1();
        let disabled_lease = service.acquire_first_party_adapter(binding).expect("lease");
        let disabled_token = service
            .reauthorize_first_party_adapter(&disabled_lease)
            .expect("token");
        service.set_enabled("ai-recap", false).expect("disable");
        assert!(disabled_token.is_cancelled());
        assert!(matches!(
            service.reauthorize_first_party_adapter(&disabled_lease),
            Err(PluginServiceError::NotProjectable)
        ));

        service.set_enabled("ai-recap", true).expect("enable");
        let reload_lease = service.acquire_first_party_adapter(binding).expect("lease");
        let reload_token = service
            .reauthorize_first_party_adapter(&reload_lease)
            .expect("token");
        let registry =
            MarketplaceInstalledRegistry::open(temp.path().join("marketplace")).expect("registry");
        registry
            .set_policy_state(
                &PluginId::new("ai-recap".to_owned()).expect("plugin id"),
                MarketplaceInstalledPolicyState::Revoked,
            )
            .expect("revoke");
        service
            .reload_marketplace(
                &registry,
                &StaticArchiveVerifier(first_party_ai_recap_manifest()),
            )
            .expect("reload revoked");
        assert!(reload_token.is_cancelled());
        assert!(matches!(
            service.reauthorize_first_party_adapter(&reload_lease),
            Err(PluginServiceError::NotProjectable)
        ));

        let second_temp = TempDir::new().expect("second temp dir");
        let fresh = installed_ai_recap_service(
            &second_temp,
            DesiredPluginState::Enabled,
            MarketplaceInstalledPolicyState::Allowed,
        );
        let stop_lease = fresh.acquire_first_party_adapter(binding).expect("lease");
        let stop_token = fresh
            .reauthorize_first_party_adapter(&stop_lease)
            .expect("token");
        fresh.stop_all().expect("stop");
        assert!(stop_token.is_cancelled());
        assert!(matches!(
            fresh.reauthorize_first_party_adapter(&stop_lease),
            Err(PluginServiceError::ShuttingDown)
        ));
    }

    #[test]
    fn installed_entitlement_projects_only_after_enable_then_hides_on_disable() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_p1_service(&temp);
        assert!(service.snapshot().expect("initial").active.is_empty());
        let enabled = service
            .set_enabled("sample-insights", true)
            .expect("enable installed entitlement");
        assert_eq!(enabled.active.len(), 1);
        assert_eq!(
            enabled.active[0].route.as_deref(),
            Some("/extensions/sample-insights/overview")
        );
        let disabled = service
            .set_enabled("sample-insights", false)
            .expect("disable installed entitlement");
        assert!(disabled.active.is_empty());
    }

    #[test]
    fn legacy_preference_is_ignored_after_entitlement_migration() {
        let temp = TempDir::new().expect("temp dir");
        std::fs::write(
            temp.path().join("ui_config.json"),
            br#"{\"pluginEnabled\":{\"private-flight\":true}}"#,
        )
        .expect("legacy preference");
        let snapshot = service(&temp).snapshot().expect("snapshot");
        assert!(snapshot.plugins.is_empty());
        assert!(snapshot.active.is_empty());
    }

    #[test]
    fn stop_all_revokes_active_contributions_but_preserves_enabled_preference() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_p1_service(&temp);
        let enabled = service
            .set_enabled("sample-insights", true)
            .expect("enable plugin");
        let stopped = service.stop_all().expect("stop bundled plugins");

        assert!(stopped.revision > enabled.revision);
        assert!(stopped.active.is_empty());
        assert_eq!(stopped.plugins[0].desired_state, "enabled");
        assert_eq!(stopped.plugins[0].runtime_state, "registered");
    }

    #[test]
    fn stop_all_permanently_rejects_late_lifecycle_mutations() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_p1_service(&temp);
        service
            .set_enabled("sample-insights", true)
            .expect("enable plugin");
        let stopped = service.stop_all().expect("stop bundled plugins");

        assert_eq!(
            service.set_enabled("sample-insights", false),
            Err(PluginServiceError::ShuttingDown)
        );
        let after_late_mutation = service.snapshot().expect("snapshot");
        assert_eq!(after_late_mutation, stopped);
        assert!(after_late_mutation.active.is_empty());
        assert_eq!(after_late_mutation.plugins[0].desired_state, "enabled");
    }

    #[test]
    fn data_plane_admission_is_atomic_with_lifecycle_and_shutdown() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_p1_service(&temp);
        let invoked = std::cell::Cell::new(false);

        assert_eq!(
            service.with_projectable("sample-insights", || invoked.set(true)),
            Err(PluginServiceError::NotProjectable)
        );
        assert!(!invoked.get());

        service
            .set_enabled("sample-insights", true)
            .expect("enable plugin");
        assert_eq!(service.with_projectable("sample-insights", || 7), Ok(7));

        service.stop_all().expect("stop plugins");
        assert_eq!(
            service.with_projectable("sample-insights", || 9),
            Err(PluginServiceError::ShuttingDown)
        );
    }

    #[test]
    fn legacy_preference_does_not_create_a_marketplace_entitlement() {
        let temp = TempDir::new().expect("temp dir");
        std::fs::write(
            temp.path().join("ui_config.json"),
            br#"{"pluginEnabled":{"private-flight":true}}"#,
        )
        .expect("write legacy preference");

        let snapshot = service(&temp).snapshot().expect("snapshot");
        assert!(snapshot.plugins.is_empty());
        assert!(snapshot.active.is_empty());
    }

    #[test]
    fn corrupt_state_defaults_disabled_without_failing_creation() {
        let temp = TempDir::new().expect("temp dir");
        std::fs::write(temp.path().join("plugin-state.json"), b"not-json")
            .expect("write corrupt state");
        let rebuilt = service(&temp).snapshot().expect("snapshot");
        assert!(rebuilt.plugins.is_empty());
        assert!(rebuilt.active.is_empty());
    }

    #[test]
    fn unknown_plugin_returns_typed_non_echoing_error() {
        let temp = TempDir::new().expect("temp dir");
        let service = service(&temp);
        let error = service
            .set_enabled("secret-plugin", true)
            .expect_err("unknown plugin");
        assert_eq!(error, PluginServiceError::UnknownPlugin);
        assert_eq!(error.to_string(), "plugin_not_found");
        assert!(!error.to_string().contains("secret-plugin"));
    }

    #[test]
    fn poisoned_service_lock_fails_closed_instead_of_returning_active_state() {
        let temp = TempDir::new().expect("temp dir");
        let service = installed_p1_service(&temp);
        service
            .set_enabled("sample-insights", true)
            .expect("enable plugin");
        let poisoned = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _guard = service.state.lock().expect("lock before poison");
            panic!("poison service lock");
        }));
        assert!(poisoned.is_err());
        assert_eq!(service.snapshot(), Err(PluginServiceError::Unavailable));
    }

    #[test]
    fn oversized_snapshot_is_rejected_before_bridge_publication() {
        let snapshot = HostContributionSnapshotDto {
            revision: 1,
            plugins: vec![HostPluginUiStateDto {
                plugin_id: PRIVATE_FLIGHT_PLUGIN_ID.to_owned(),
                manifest_json: "x".repeat(MAX_SNAPSHOT_WIRE_BYTES),
                desired_state: "enabled".to_owned(),
                runtime_state: "ready".to_owned(),
                compatible: true,
                grants_satisfied: true,
                generation: 1,
                failure_code: None,
                failure_retryable: false,
            }],
            active: Vec::new(),
        };

        assert_eq!(
            ensure_snapshot_within_budget(&snapshot),
            Err(PluginServiceError::Unavailable)
        );
    }
}
