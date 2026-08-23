//! Default-deny capability grants and session-bound authorization.

use std::{
    collections::{BTreeSet, HashMap, HashSet},
    fmt,
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicU64, Ordering},
        mpsc::{Receiver, SyncSender, TryRecvError, TrySendError, sync_channel},
    },
};

use sha2::{Digest, Sha256};
use thiserror::Error;
use timetrace_plugin_api::{
    CAPABILITY_PROOF_BYTES, CapabilityConstraints, CapabilityGrant, CapabilityHandle, CapabilityId,
    ContractError, GrantId, MAX_QUERY_BYTES, MAX_QUERY_RANGE_DAYS, MAX_QUERY_ROWS, PluginId,
    UsageGranularity,
};

use crate::{
    CommitDomain, CommitError, CommitOperation, CommitOperationId, CommitPermit,
    CommitRecoveryHandle, CommitRecoveryResolution, CommitResourceScope, PermissionAuthorityId,
    PermissionGrantScope, PermissionMutationFence, PermissionMutationScope, PermissionSessionScope,
    PluginCatalog,
};

/// Maximum simultaneously active grants retained by one authorizer.
pub const MAX_ACTIVE_GRANTS: usize = 1_024;
/// Maximum simultaneously active authenticated plugin sessions.
pub const MAX_ACTIVE_SESSIONS: usize = 256;
/// Maximum permission audit events retained in memory.
pub const MAX_AUDIT_EVENTS: usize = 256;
/// Maximum capability admissions bound to one persistence commit.
pub const MAX_PERMISSION_COMMIT_AUTHORIZATIONS: usize = 8;

const SESSION_ID_BYTES: usize = 16;
const SESSION_PROOF_BYTES: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct CapabilityKey {
    plugin_id: PluginId,
    capability_id: CapabilityId,
}

impl CapabilityKey {
    fn new(plugin_id: PluginId, capability_id: CapabilityId) -> Self {
        Self {
            plugin_id,
            capability_id,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct SessionId([u8; SESSION_ID_BYTES]);

/// Fully explicit capability constraints enforced by host services.
///
/// Numeric `None` values from wire DTOs are normalized to canonical hard
/// limits. Empty granularities and domains uniformly mean "allow none".
#[derive(Debug, PartialEq, Eq)]
pub struct EffectiveConstraints {
    max_range_days: u16,
    allowed_granularities: BTreeSet<UsageGranularity>,
    max_rows: u32,
    max_bytes: u64,
    allowed_domains: BTreeSet<String>,
}

impl EffectiveConstraints {
    fn from_contract(value: &CapabilityConstraints) -> Self {
        Self {
            max_range_days: value.max_range_days.unwrap_or(MAX_QUERY_RANGE_DAYS),
            allowed_granularities: value.allowed_granularities.clone(),
            max_rows: value.max_rows.unwrap_or(MAX_QUERY_ROWS),
            max_bytes: value.max_bytes.unwrap_or(MAX_QUERY_BYTES),
            allowed_domains: value.allowed_domains.clone(),
        }
    }

    /// Returns the explicit maximum inclusive query range in days.
    #[must_use]
    pub fn max_range_days(&self) -> u16 {
        self.max_range_days
    }

    /// Returns allowed aggregate granularities; empty denies all.
    #[must_use]
    pub fn allowed_granularities(&self) -> &BTreeSet<UsageGranularity> {
        &self.allowed_granularities
    }

    /// Returns the explicit maximum row count.
    #[must_use]
    pub fn max_rows(&self) -> u32 {
        self.max_rows
    }

    /// Returns the explicit maximum serialized response size.
    #[must_use]
    pub fn max_bytes(&self) -> u64 {
        self.max_bytes
    }

    /// Returns exact authorized endpoint domains; empty denies all.
    #[must_use]
    pub fn allowed_domains(&self) -> &BTreeSet<String> {
        &self.allowed_domains
    }

    fn is_narrower_or_equal(&self, declared: &Self) -> bool {
        self.max_range_days <= declared.max_range_days
            && self.max_rows <= declared.max_rows
            && self.max_bytes <= declared.max_bytes
            && self
                .allowed_granularities
                .is_subset(&declared.allowed_granularities)
            && self.allowed_domains.is_subset(&declared.allowed_domains)
    }
}

/// Host-authenticated, non-serializable plugin session.
///
/// The random session identity and proof are private. Only
/// [`PermissionControlPlane::open_session`] creates this value, and future RPC
/// transports must retain it in host state rather than rebuild it from a
/// plugin-supplied payload.
pub struct AuthenticatedPluginSession {
    plugin_id: PluginId,
    session_id: SessionId,
    bearer_proof: [u8; SESSION_PROOF_BYTES],
    shared: Arc<PermissionShared>,
    closed: bool,
}

impl AuthenticatedPluginSession {
    /// Returns the host-authenticated plugin identity.
    #[must_use]
    pub fn plugin_id(&self) -> &PluginId {
        &self.plugin_id
    }
}

impl fmt::Debug for AuthenticatedPluginSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthenticatedPluginSession")
            .field("plugin_id", &self.plugin_id)
            .field("session_id", &"[REDACTED]")
            .field("bearer_proof", &"[REDACTED]")
            .finish()
    }
}

impl Drop for AuthenticatedPluginSession {
    fn drop(&mut self) {
        if !self.closed {
            self.closed = true;
            let shared = Arc::clone(&self.shared);
            let _ = shared.close_session_lease(self);
        }
    }
}

/// A single-use host approval bound to one exact authenticated session and grant.
///
/// This value deliberately implements neither `Clone` nor serde. Only
/// [`PermissionControlPlane::approve_grant`] can create it, and
/// [`PermissionControlPlane::grant`] consumes it.
pub struct ApprovedGrantDecision {
    shared: Arc<PermissionShared>,
    session_id: SessionId,
    session_proof_hash: [u8; 32],
    plugin_id: PluginId,
    grant: CapabilityGrant,
    constraints: Arc<EffectiveConstraints>,
}

impl fmt::Debug for ApprovedGrantDecision {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ApprovedGrantDecision")
            .field("plugin_id", &self.plugin_id)
            .field("grant_id", &self.grant.id)
            .field("capability_id", &self.grant.capability_id)
            .field("session", &"[BOUND]")
            .finish()
    }
}

/// A host-service operation requiring one capability.
///
/// Caller identity is intentionally absent and comes only from an authenticated
/// session. This type is not a wire DTO and does not implement serde.
#[derive(Debug, PartialEq, Eq)]
pub struct CapabilityOperation {
    capability_id: CapabilityId,
}

impl CapabilityOperation {
    /// Creates a host-side operation for one required capability.
    pub fn requiring(capability_id: CapabilityId) -> Result<Self, ContractError> {
        capability_id.validate()?;
        Ok(Self { capability_id })
    }

    /// Returns the capability required by the host service operation.
    #[must_use]
    pub fn capability_id(&self) -> &CapabilityId {
        &self.capability_id
    }
}

/// A single admission result passed by value to a narrow host service.
///
/// This type deliberately does not implement `Clone`. Revocation or session
/// closure rejects new admissions but does not cancel an already admitted call.
#[derive(Debug, PartialEq, Eq)]
pub struct AuthorizedCall {
    grant_id: GrantId,
    generation: u64,
    plugin_id: PluginId,
    capability_id: CapabilityId,
    constraints: Arc<EffectiveConstraints>,
}

#[derive(Debug)]
struct CommitGrantSnapshot {
    grant_id: GrantId,
    generation: u64,
    plugin_id: PluginId,
    capability_id: CapabilityId,
}

/// Move-only permission binding for one exact pre-commit operation.
///
/// This host-only value implements neither `Clone` nor serde. It retains the
/// canonical operation and exact session/grant generations until final
/// validation atomically admits the operation in its [`CommitDomain`].
pub struct PermissionCommitBinding {
    operation: CommitOperation,
    session_id: SessionId,
    session_proof_hash: [u8; 32],
    plugin_id: PluginId,
    grants: Vec<CommitGrantSnapshot>,
    grant_scopes: Vec<PermissionGrantScope>,
    resource_scope: Option<CommitResourceScope>,
}

impl PermissionCommitBinding {
    /// Binds the exact provider/resource revision required by this operation.
    ///
    /// The binding is move-only and a record can bind a resource only once.
    pub fn bind_resource(
        mut self,
        scope: CommitResourceScope,
    ) -> Result<ResourceBoundPermissionCommitBinding, CommitError> {
        self.operation.bind_resource(scope)?;
        self.resource_scope = Some(scope);
        Ok(ResourceBoundPermissionCommitBinding { inner: self })
    }
}

/// Move-only permission binding proven to carry one canonical resource scope.
pub struct ResourceBoundPermissionCommitBinding {
    inner: PermissionCommitBinding,
}

impl fmt::Debug for ResourceBoundPermissionCommitBinding {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("ResourceBoundPermissionCommitBinding")
            .field(&self.inner)
            .finish()
    }
}

/// Commit permit that proves permission and canonical resource freshness.
pub struct ResourceCommitPermit {
    inner: CommitPermit,
}

impl ResourceCommitPermit {
    /// Returns the opaque operation identity admitted for physical commit.
    #[must_use]
    pub fn operation_id(&self) -> CommitOperationId {
        self.inner.operation_id()
    }

    /// Records a proven successful physical commit.
    pub fn mark_committed(self) -> Result<(), CommitError> {
        self.inner.mark_committed()
    }

    /// Records an indeterminate physical outcome that requires recovery.
    pub fn mark_durability_unknown(self) -> Result<ResourceCommitRecoveryHandle, CommitError> {
        self.inner
            .mark_durability_unknown()
            .map(|inner| ResourceCommitRecoveryHandle { inner })
    }
}

impl fmt::Debug for ResourceCommitPermit {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ResourceCommitPermit([ADMITTED])")
    }
}

/// Move-only authority for resolving one resource commit with unknown durability.
///
/// The handle retains the canonical commit domain, permission authority, and
/// operation identity that admitted the physical commit. It implements neither
/// `Clone` nor serde, and dropping it intentionally leaves the operation in
/// `DurabilityUnknown` for fail-closed recovery.
pub struct ResourceCommitRecoveryHandle {
    inner: CommitRecoveryHandle,
}

impl ResourceCommitRecoveryHandle {
    /// Resolves the exact durability-unknown operation and consumes this authority.
    pub fn resolve(self, resolution: CommitRecoveryResolution) -> Result<(), CommitError> {
        self.inner.resolve(resolution)
    }
}

impl fmt::Debug for ResourceCommitRecoveryHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ResourceCommitRecoveryHandle([REDACTED])")
    }
}

impl fmt::Debug for PermissionCommitBinding {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PermissionCommitBinding")
            .field("operation_id", &self.operation.id())
            .field("plugin_id", &self.plugin_id)
            .field("grant_count", &self.grants.len())
            .field("resource_bound", &self.resource_scope.is_some())
            .field("session", &"[BOUND]")
            .finish()
    }
}

impl AuthorizedCall {
    /// Returns the grant responsible for this admission.
    #[must_use]
    pub fn grant_id(&self) -> &GrantId {
        &self.grant_id
    }

    /// Returns the generation admitted for this call.
    #[must_use]
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Returns the host-authenticated caller identity.
    #[must_use]
    pub fn plugin_id(&self) -> &PluginId {
        &self.plugin_id
    }

    /// Returns the capability admitted for this call.
    #[must_use]
    pub fn capability_id(&self) -> &CapabilityId {
        &self.capability_id
    }

    /// Returns explicit least-privilege constraints for service enforcement.
    #[must_use]
    pub fn constraints(&self) -> &EffectiveConstraints {
        &self.constraints
    }
}

/// Narrow service operation that consumes one authorization admission.
pub trait AuthorizedOperation {
    /// Result produced after the service consumes the authorization.
    type Output;

    /// Executes the operation while consuming the non-cloneable admission.
    fn execute(self, authorization: AuthorizedCall) -> Self::Output;
}

#[derive(Debug)]
struct ActiveSession {
    plugin_id: PluginId,
    proof_hash: [u8; 32],
}

#[derive(Debug)]
struct ActiveGrant {
    generation: u64,
    plugin_id: PluginId,
    capability_id: CapabilityId,
    constraints: Arc<EffectiveConstraints>,
    proof_hash: [u8; 32],
    session_id: SessionId,
}

#[derive(Debug)]
struct GrantInsertFailure {
    error: PermissionError,
    reason: PermissionAuditReason,
    existing_generation: Option<u64>,
}

#[derive(Debug, Default)]
struct PermissionState {
    sessions: HashMap<SessionId, ActiveSession>,
    grants: HashMap<GrantId, ActiveGrant>,
}

/// Permission operation recorded by the typed audit boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionAuditAction {
    /// The host attempted to open an authenticated plugin session.
    OpenSession,
    /// The host attempted to close an authenticated plugin session.
    CloseSession,
    /// A user or host policy attempted to create a grant.
    Grant,
    /// The host attempted to revoke a grant.
    Revoke,
    /// A plugin operation attempted to use a handle.
    Authorize,
}

/// Stable outcome of a permission audit event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionAuditOutcome {
    /// The permission operation completed successfully.
    Allowed,
    /// The permission operation failed closed.
    Denied,
}

/// Privacy-safe reason for a permission decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionAuditReason {
    /// A host-authenticated plugin session was opened.
    SessionOpened,
    /// A host-authenticated plugin session was closed.
    SessionClosed,
    /// The requested plugin session was invalid, closed, or unavailable.
    SessionRejected,
    /// A least-privilege session-bound grant was created.
    Granted,
    /// An active grant was revoked.
    Revoked,
    /// A current handle matched the session and operation.
    Authorized,
    /// The grant DTO failed canonical validation.
    InvalidGrant,
    /// The capability was not declared by a compatible manifest.
    UndeclaredCapability,
    /// The requested grant was broader than its manifest declaration.
    ConstraintsTooBroad,
    /// The grant identifier is already active.
    AlreadyGranted,
    /// The bounded active registry is full.
    ActiveLimitReached,
    /// The grant identifier was unknown or already revoked.
    UnknownOrRevokedGrant,
    /// The handle proof was unknown, revoked, or from an earlier grant.
    StaleHandle,
    /// The session or operation did not match the handle's grant.
    OperationMismatch,
    /// Cryptographically secure proof generation failed.
    EntropyUnavailable,
    /// Host synchronization or generation state failed safely.
    InternalState,
}

/// A bounded permission decision containing no payload or bearer proof.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermissionAuditEvent {
    /// Permission operation being audited.
    pub action: PermissionAuditAction,
    /// Whether the operation was allowed or denied.
    pub outcome: PermissionAuditOutcome,
    /// Stable, privacy-safe decision reason.
    pub reason: PermissionAuditReason,
    /// Validated plugin identity when it is known.
    pub plugin_id: Option<PluginId>,
    /// Validated capability identity when it is known.
    pub capability_id: Option<CapabilityId>,
    /// Validated grant identity when it is known.
    pub grant_id: Option<GrantId>,
    /// Handle generation when it is known.
    pub generation: Option<u64>,
}

/// A bounded batch drained from the host-owned permission audit queue.
#[derive(Debug, PartialEq, Eq)]
pub struct PermissionAuditDrain {
    events: Vec<PermissionAuditEvent>,
    dropped_total: u64,
}

impl PermissionAuditDrain {
    /// Returns drained audit events in producer order.
    #[must_use]
    pub fn events(&self) -> &[PermissionAuditEvent] {
        &self.events
    }

    /// Consumes the batch and returns its owned events.
    #[must_use]
    pub fn into_events(self) -> Vec<PermissionAuditEvent> {
        self.events
    }

    /// Returns the cumulative count of events dropped because the queue was full.
    #[must_use]
    pub fn dropped_total(&self) -> u64 {
        self.dropped_total
    }
}

#[derive(Debug)]
struct PermissionShared {
    compatible_plugins: HashSet<PluginId>,
    declarations: HashMap<CapabilityKey, Arc<EffectiveConstraints>>,
    state: RwLock<PermissionState>,
    next_generation: AtomicU64,
    audit_tx: SyncSender<PermissionAuditEvent>,
    audit_rx: Mutex<Receiver<PermissionAuditEvent>>,
    dropped_audit_events: AtomicU64,
    commit_domain: Arc<CommitDomain>,
    commit_authority: Option<PermissionAuthorityId>,
}

/// Host-only control plane for sessions, approvals, grants, and revocation.
///
/// Keep this object in trusted bootstrap/UI policy code. Plugin and RPC service
/// adapters should receive only [`PermissionAuthorizer`]. Creating a separate
/// control plane creates a separate authority and cannot mutate this one.
pub struct PermissionControlPlane {
    shared: Arc<PermissionShared>,
}

/// Default-deny data plane that can only authorize host-approved handles.
///
/// This is the only permission object intended for plugin/RPC service adapters.
/// It intentionally exposes no session, approval, grant, or revoke operation.
///
/// ```compile_fail
/// # use timetrace_plugin_host::PermissionAuthorizer;
/// fn plugin_rpc(authorizer: PermissionAuthorizer) {
///     authorizer.revoke(todo!());
/// }
/// ```
#[derive(Clone)]
pub struct PermissionAuthorizer {
    shared: Arc<PermissionShared>,
}

impl PermissionControlPlane {
    /// Creates a permission-only control plane from compatible descriptors.
    ///
    /// This convenience constructor cannot mint commit operations. Production
    /// composition that persists plugin-derived data must explicitly bootstrap
    /// the sole commit authority with [`Self::from_catalog_with_commit_domain`].
    #[must_use]
    pub fn from_catalog(catalog: &PluginCatalog) -> Self {
        Self::build(catalog, CommitDomain::process(), None)
    }

    /// Creates a control plane bound to the sole process commit authority.
    ///
    /// This explicit composition seam rejects any detached `Arc` identity.
    pub fn from_catalog_with_commit_domain(
        catalog: &PluginCatalog,
        commit_domain: Arc<CommitDomain>,
    ) -> Result<Self, CommitError> {
        if !Arc::ptr_eq(&commit_domain, &CommitDomain::process()) {
            return Err(CommitError::WrongDomain);
        }
        let authority = commit_domain.register_permission_authority()?;
        Ok(Self::build(catalog, commit_domain, Some(authority)))
    }

    fn build(
        catalog: &PluginCatalog,
        commit_domain: Arc<CommitDomain>,
        commit_authority: Option<PermissionAuthorityId>,
    ) -> Self {
        let snapshot = catalog.snapshot();
        let mut compatible_plugins = HashSet::new();
        let mut declarations = HashMap::new();
        for descriptor in snapshot
            .plugins()
            .iter()
            .filter(|item| item.is_compatible())
        {
            compatible_plugins.insert(descriptor.manifest().id.clone());
            for request in &descriptor.manifest().requested_capabilities {
                declarations.insert(
                    CapabilityKey::new(descriptor.manifest().id.clone(), request.id.clone()),
                    Arc::new(EffectiveConstraints::from_contract(&request.constraints)),
                );
            }
        }
        let (audit_tx, audit_rx) = sync_channel(MAX_AUDIT_EVENTS);
        let shared = Arc::new(PermissionShared {
            compatible_plugins,
            declarations,
            state: RwLock::new(PermissionState::default()),
            next_generation: AtomicU64::new(1),
            audit_tx,
            audit_rx: Mutex::new(audit_rx),
            dropped_audit_events: AtomicU64::new(0),
            commit_domain,
            commit_authority,
        });
        Self { shared }
    }

    /// Returns the canonical commit domain shared with provider/store composition.
    #[must_use]
    pub fn commit_domain(&self) -> Arc<CommitDomain> {
        Arc::clone(&self.shared.commit_domain)
    }

    /// Starts a session-bound pre-commit operation with a bounded lifetime.
    pub fn begin_commit_operation(
        &self,
        session: &AuthenticatedPluginSession,
        ttl: std::time::Duration,
    ) -> Result<CommitOperation, CommitError> {
        let authority = self
            .shared
            .commit_authority
            .ok_or(CommitError::WrongDomain)?;
        if !Arc::ptr_eq(&self.shared, &session.shared) {
            return Err(CommitError::WrongDomain);
        }
        {
            let state = self
                .shared
                .state
                .read()
                .map_err(|_| CommitError::InternalState)?;
            if !session_is_active(&state, session) {
                return Err(CommitError::PermissionDenied);
            }
        }
        self.shared.commit_domain.begin_operation(
            authority,
            permission_session_scope(session.session_id),
            ttl,
        )
    }

    /// Acknowledges and releases one resolved committed or cancelled operation.
    pub fn acknowledge_commit_terminal(
        &self,
        operation_id: &CommitOperationId,
    ) -> Result<(), CommitError> {
        let authority = self
            .shared
            .commit_authority
            .ok_or(CommitError::WrongDomain)?;
        self.shared
            .commit_domain
            .acknowledge_terminal(authority, operation_id)
    }

    /// Returns the cloneable data plane intended for plugin/RPC services.
    #[must_use]
    pub fn authorizer(&self) -> PermissionAuthorizer {
        PermissionAuthorizer {
            shared: Arc::clone(&self.shared),
        }
    }

    /// Opens a random, non-serializable session for an identity authenticated by
    /// host-owned transport code.
    ///
    /// This is a host control-plane API and must not be exposed as a plugin RPC
    /// method or called with a plugin-supplied identity field.
    pub fn open_session(
        &self,
        plugin_id: &PluginId,
    ) -> Result<AuthenticatedPluginSession, PermissionError> {
        if plugin_id.validate().is_err() || !self.shared.compatible_plugins.contains(plugin_id) {
            self.shared.emit_session(
                PermissionAuditAction::OpenSession,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
                None,
            );
            return Err(PermissionError::SessionRejected);
        }

        let mut entropy = [0_u8; SESSION_ID_BYTES + SESSION_PROOF_BYTES];
        if getrandom::fill(&mut entropy).is_err() {
            self.shared.emit_session(
                PermissionAuditAction::OpenSession,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::EntropyUnavailable,
                Some(plugin_id.clone()),
            );
            return Err(PermissionError::EntropyUnavailable);
        }
        let mut session_id = [0_u8; SESSION_ID_BYTES];
        session_id.copy_from_slice(&entropy[..SESSION_ID_BYTES]);
        let mut bearer_proof = [0_u8; SESSION_PROOF_BYTES];
        bearer_proof.copy_from_slice(&entropy[SESSION_ID_BYTES..]);
        let session_id = SessionId(session_id);
        let proof_hash = hash_bytes(&bearer_proof);

        let inserted = {
            let mut state = self.shared.state.write().map_err(|_| {
                self.shared.emit_session(
                    PermissionAuditAction::OpenSession,
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                    Some(plugin_id.clone()),
                );
                PermissionError::InternalState
            })?;
            if state.sessions.len() >= MAX_ACTIVE_SESSIONS {
                Err(PermissionError::ActiveSessionLimitReached)
            } else {
                match state.sessions.entry(session_id) {
                    std::collections::hash_map::Entry::Vacant(entry) => {
                        entry.insert(ActiveSession {
                            plugin_id: plugin_id.clone(),
                            proof_hash,
                        });
                        Ok(())
                    }
                    std::collections::hash_map::Entry::Occupied(_) => {
                        Err(PermissionError::InternalState)
                    }
                }
            }
        };
        if let Err(error) = inserted {
            self.shared.emit_session(
                PermissionAuditAction::OpenSession,
                PermissionAuditOutcome::Denied,
                if error == PermissionError::ActiveSessionLimitReached {
                    PermissionAuditReason::ActiveLimitReached
                } else {
                    PermissionAuditReason::InternalState
                },
                Some(plugin_id.clone()),
            );
            return Err(error);
        }

        self.shared.emit_session(
            PermissionAuditAction::OpenSession,
            PermissionAuditOutcome::Allowed,
            PermissionAuditReason::SessionOpened,
            Some(plugin_id.clone()),
        );
        Ok(AuthenticatedPluginSession {
            plugin_id: plugin_id.clone(),
            session_id,
            bearer_proof,
            shared: Arc::clone(&self.shared),
            closed: false,
        })
    }

    /// Closes a host-owned session and atomically invalidates all handles issued
    /// to it. The session is consumed so safe Rust callers cannot reuse it.
    /// This host control-plane API must not accept a reconstructed RPC payload.
    pub fn close_session(
        &self,
        mut session: AuthenticatedPluginSession,
    ) -> Result<(), PermissionError> {
        if !Arc::ptr_eq(&self.shared, &session.shared) {
            self.shared.emit_session(
                PermissionAuditAction::CloseSession,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
                None,
            );
            return Err(PermissionError::SessionRejected);
        }
        session.closed = true;
        self.shared.close_session_lease(&session)
    }

    /// Approves one exact grant for one exact active session.
    ///
    /// Calling this method is the trusted host UI/policy approval boundary.
    /// The returned decision is single-use, non-serializable, and cannot be
    /// widened or moved to another session or authority.
    pub fn approve_grant(
        &self,
        session: &AuthenticatedPluginSession,
        grant: CapabilityGrant,
    ) -> Result<ApprovedGrantDecision, PermissionError> {
        if !Arc::ptr_eq(&self.shared, &session.shared) || !self.shared.is_session_active(session)? {
            self.shared.emit_grant_session_rejected(session);
            return Err(PermissionError::SessionRejected);
        }
        if let Err(source) = grant.validate_basic() {
            self.shared.emit_invalid_grant();
            return Err(PermissionError::InvalidGrant { source });
        }
        if grant.plugin_id != session.plugin_id {
            self.shared.emit_for_grant(
                &session.plugin_id,
                &grant,
                None,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::OperationMismatch,
            );
            return Err(PermissionError::PermissionDenied);
        }

        let key = CapabilityKey::new(session.plugin_id.clone(), grant.capability_id.clone());
        let Some(declared) = self.shared.declarations.get(&key) else {
            self.shared.emit_for_grant(
                &session.plugin_id,
                &grant,
                None,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::UndeclaredCapability,
            );
            return Err(PermissionError::UndeclaredCapability);
        };
        let effective = EffectiveConstraints::from_contract(&grant.constraints);
        if !effective.is_narrower_or_equal(declared) {
            self.shared.emit_for_grant(
                &session.plugin_id,
                &grant,
                None,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::ConstraintsTooBroad,
            );
            return Err(PermissionError::ConstraintsTooBroad);
        }

        Ok(ApprovedGrantDecision {
            shared: Arc::clone(&self.shared),
            session_id: session.session_id,
            session_proof_hash: hash_bytes(&session.bearer_proof),
            plugin_id: session.plugin_id.clone(),
            grant,
            constraints: Arc::new(effective),
        })
    }

    /// Consumes one host-approved decision and issues its exact bound handle.
    pub fn grant(
        &self,
        decision: ApprovedGrantDecision,
    ) -> Result<CapabilityHandle, PermissionError> {
        let ApprovedGrantDecision {
            shared,
            session_id,
            session_proof_hash,
            plugin_id,
            grant,
            constraints,
        } = decision;
        if !Arc::ptr_eq(&self.shared, &shared) {
            self.shared.emit_for_grant(
                &plugin_id,
                &grant,
                None,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
            );
            return Err(PermissionError::SessionRejected);
        }

        let mut proof = [0_u8; CAPABILITY_PROOF_BYTES];
        if getrandom::fill(&mut proof).is_err() {
            self.shared.emit_for_grant(
                &plugin_id,
                &grant,
                None,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::EntropyUnavailable,
            );
            return Err(PermissionError::EntropyUnavailable);
        }
        let generation = match self.shared.allocate_generation() {
            Some(generation) => generation,
            None => {
                self.shared.emit_for_grant(
                    &plugin_id,
                    &grant,
                    None,
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                );
                return Err(PermissionError::GenerationExhausted);
            }
        };
        let handle = match CapabilityHandle::from_host_parts(grant.id.clone(), generation, proof) {
            Ok(handle) => handle,
            Err(_) => {
                self.shared.emit_for_grant(
                    &plugin_id,
                    &grant,
                    Some(generation),
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                );
                return Err(PermissionError::InternalState);
            }
        };
        let active = ActiveGrant {
            generation,
            plugin_id: plugin_id.clone(),
            capability_id: grant.capability_id.clone(),
            constraints,
            proof_hash: hash_bytes(handle.bearer_proof()),
            session_id,
        };

        let insert_result: Result<(), GrantInsertFailure> = {
            let mut state = self.shared.state.write().map_err(|_| {
                self.shared.emit_for_grant(
                    &plugin_id,
                    &grant,
                    Some(generation),
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                );
                PermissionError::InternalState
            })?;
            if !session_binding_is_active(&state, session_id, &plugin_id, &session_proof_hash) {
                Err(GrantInsertFailure {
                    error: PermissionError::SessionRejected,
                    reason: PermissionAuditReason::SessionRejected,
                    existing_generation: None,
                })
            } else if let Some(existing) = state.grants.get(&grant.id) {
                Err(GrantInsertFailure {
                    error: PermissionError::AlreadyGranted,
                    reason: PermissionAuditReason::AlreadyGranted,
                    existing_generation: Some(existing.generation),
                })
            } else if state.grants.len() >= MAX_ACTIVE_GRANTS {
                Err(GrantInsertFailure {
                    error: PermissionError::ActiveGrantLimitReached,
                    reason: PermissionAuditReason::ActiveLimitReached,
                    existing_generation: None,
                })
            } else {
                state.grants.insert(grant.id.clone(), active);
                Ok(())
            }
        };
        if let Err(failure) = insert_result {
            self.shared.emit_for_grant(
                &plugin_id,
                &grant,
                failure.existing_generation,
                PermissionAuditOutcome::Denied,
                failure.reason,
            );
            return Err(failure.error);
        }

        self.shared.emit_for_grant(
            &plugin_id,
            &grant,
            Some(generation),
            PermissionAuditOutcome::Allowed,
            PermissionAuditReason::Granted,
        );
        Ok(handle)
    }

    /// Revokes and removes an active grant from host policy or lifecycle code in
    /// average O(1) time.
    pub fn revoke(&self, grant_id: &GrantId) -> Result<(), PermissionError> {
        if grant_id.validate().is_err() {
            self.shared.emit_unknown_revoke(None);
            return Err(PermissionError::PermissionDenied);
        }
        let expected = {
            let state = self
                .shared
                .state
                .read()
                .map_err(|_| PermissionError::InternalState)?;
            state.grants.get(grant_id).map(|active| {
                (
                    permission_session_scope(active.session_id),
                    permission_grant_scope(grant_id, active.generation),
                )
            })
        };
        let Some((owner_session, expected_scope)) = expected else {
            self.shared.emit_unknown_revoke(Some(grant_id.clone()));
            return Err(PermissionError::PermissionDenied);
        };
        let mutation = self
            .shared
            .begin_commit_mutation(PermissionMutationScope::Grant {
                session: owner_session,
                grant: expected_scope.clone(),
            })?;
        let removed = {
            let mut state = self.shared.state.write().map_err(|_| {
                self.shared.emit(PermissionAuditEvent {
                    action: PermissionAuditAction::Revoke,
                    outcome: PermissionAuditOutcome::Denied,
                    reason: PermissionAuditReason::InternalState,
                    plugin_id: None,
                    capability_id: None,
                    grant_id: Some(grant_id.clone()),
                    generation: None,
                });
                PermissionError::InternalState
            })?;
            match state.grants.get(grant_id) {
                Some(active)
                    if permission_grant_scope(grant_id, active.generation) == expected_scope =>
                {
                    state.grants.remove(grant_id)
                }
                _ => None,
            }
        };
        let Some(active) = removed else {
            self.shared.finish_commit_mutation(mutation)?;
            self.shared.emit_unknown_revoke(Some(grant_id.clone()));
            return Err(PermissionError::PermissionDenied);
        };
        self.shared.finish_commit_mutation(mutation)?;
        self.shared.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Revoke,
            outcome: PermissionAuditOutcome::Allowed,
            reason: PermissionAuditReason::Revoked,
            plugin_id: Some(active.plugin_id),
            capability_id: Some(active.capability_id),
            grant_id: Some(grant_id.clone()),
            generation: Some(active.generation),
        });
        Ok(())
    }
}

impl PermissionAuthorizer {
    /// Authorizes a handle for the exact active session and host operation.
    pub fn authorize(
        &self,
        session: &AuthenticatedPluginSession,
        handle: &CapabilityHandle,
        operation: &CapabilityOperation,
    ) -> Result<AuthorizedCall, PermissionError> {
        if !Arc::ptr_eq(&self.shared, &session.shared) {
            self.shared.emit_authorization(
                session,
                handle,
                operation,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
            );
            return Err(PermissionError::PermissionDenied);
        }
        if handle.validate_basic().is_err() {
            self.shared.emit_authorization(
                session,
                handle,
                operation,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::StaleHandle,
            );
            return Err(PermissionError::PermissionDenied);
        }
        let supplied_hash = hash_bytes(handle.bearer_proof());
        let decision = {
            let state = self.shared.state.read().map_err(|_| {
                self.shared.emit_authorization(
                    session,
                    handle,
                    operation,
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                );
                PermissionError::InternalState
            })?;
            if !session_is_active(&state, session) {
                Err(PermissionAuditReason::SessionRejected)
            } else {
                match state.grants.get(handle.grant_id()) {
                    Some(active)
                        if active.generation == handle.generation()
                            && active.proof_hash == supplied_hash
                            && active.session_id == session.session_id
                            && active.plugin_id == session.plugin_id
                            && active.capability_id == operation.capability_id =>
                    {
                        Ok(AuthorizedCall {
                            grant_id: handle.grant_id().clone(),
                            generation: active.generation,
                            plugin_id: active.plugin_id.clone(),
                            capability_id: active.capability_id.clone(),
                            constraints: Arc::clone(&active.constraints),
                        })
                    }
                    Some(active)
                        if active.generation == handle.generation()
                            && active.proof_hash == supplied_hash =>
                    {
                        Err(PermissionAuditReason::OperationMismatch)
                    }
                    _ => Err(PermissionAuditReason::StaleHandle),
                }
            }
        };
        match decision {
            Ok(call) => {
                self.shared.emit_authorization(
                    session,
                    handle,
                    operation,
                    PermissionAuditOutcome::Allowed,
                    PermissionAuditReason::Authorized,
                );
                Ok(call)
            }
            Err(reason) => {
                self.shared.emit_authorization(
                    session,
                    handle,
                    operation,
                    PermissionAuditOutcome::Denied,
                    reason,
                );
                Err(PermissionError::PermissionDenied)
            }
        }
    }

    /// Binds current session/grant generations to one canonical pre-commit operation.
    ///
    /// The permission read lock is released before this method returns. The
    /// binding is later consumed by [`Self::validate_commit`] for the final
    /// permission read followed by the domain CAS.
    pub fn bind_commit(
        &self,
        operation: CommitOperation,
        session: &AuthenticatedPluginSession,
        authorizations: &[&AuthorizedCall],
    ) -> Result<PermissionCommitBinding, CommitError> {
        let authority = self
            .shared
            .commit_authority
            .ok_or(CommitError::WrongDomain)?;
        let session_scope = permission_session_scope(session.session_id);
        if !Arc::ptr_eq(&self.shared, &session.shared)
            || !operation.belongs_to(&self.shared.commit_domain, authority, session_scope)
            || authorizations.is_empty()
            || authorizations.len() > MAX_PERMISSION_COMMIT_AUTHORIZATIONS
        {
            return Err(CommitError::WrongDomain);
        }
        let mut grants = Vec::new();
        let mut grant_scopes = Vec::new();
        grants
            .try_reserve_exact(authorizations.len())
            .map_err(|_| CommitError::InternalState)?;
        grant_scopes
            .try_reserve_exact(authorizations.len())
            .map_err(|_| CommitError::InternalState)?;
        for authorization in authorizations {
            if authorization.plugin_id != session.plugin_id
                || grants.iter().any(|existing: &CommitGrantSnapshot| {
                    existing.grant_id == authorization.grant_id
                })
            {
                return Err(CommitError::PermissionDenied);
            }
            grants.push(CommitGrantSnapshot {
                grant_id: authorization.grant_id.clone(),
                generation: authorization.generation,
                plugin_id: authorization.plugin_id.clone(),
                capability_id: authorization.capability_id.clone(),
            });
            grant_scopes.push(permission_grant_scope(
                &authorization.grant_id,
                authorization.generation,
            ));
        }
        let session_proof_hash = hash_bytes(&session.bearer_proof);
        {
            let state = self
                .shared
                .state
                .read()
                .map_err(|_| CommitError::InternalState)?;
            validate_commit_snapshot(
                &state,
                session.session_id,
                &session.plugin_id,
                &session_proof_hash,
                &grants,
            )?;
        }
        operation.bind_grants(&grant_scopes)?;
        Ok(PermissionCommitBinding {
            operation,
            session_id: session.session_id,
            session_proof_hash,
            plugin_id: session.plugin_id.clone(),
            grants,
            grant_scopes,
            resource_scope: None,
        })
    }

    /// Revalidates exact permission state, releases its read lock, then performs
    /// the sole `PreCommit -> Committing` domain CAS.
    pub fn validate_commit(
        &self,
        binding: PermissionCommitBinding,
        session: &AuthenticatedPluginSession,
    ) -> Result<CommitPermit, CommitError> {
        self.validate_live_session_binding(&binding, session)?;
        self.validate_bound_commit_inner(binding, false)
    }

    /// Revalidates permission and requires an exact resource binding before
    /// performing the sole `PreCommit -> Committing` domain CAS.
    pub fn validate_commit_with_resource(
        &self,
        binding: ResourceBoundPermissionCommitBinding,
        session: &AuthenticatedPluginSession,
    ) -> Result<ResourceCommitPermit, CommitError> {
        self.validate_live_session_binding(&binding.inner, session)?;
        self.validate_bound_commit_inner(binding.inner, true)
            .map(|inner| ResourceCommitPermit { inner })
    }

    /// Revalidates a private session/grant snapshot and its exact resource
    /// binding without requiring the non-cloneable live session lease.
    ///
    /// This worker-facing API is safe only because the binding is move-only,
    /// non-serializable, and was minted by this exact authorizer from an active
    /// authenticated session. Session closure and grant revocation still update
    /// the shared state and commit-domain fences checked immediately before the
    /// admission CAS.
    pub fn validate_bound_commit_with_resource(
        &self,
        binding: ResourceBoundPermissionCommitBinding,
    ) -> Result<ResourceCommitPermit, CommitError> {
        self.validate_bound_commit_inner(binding.inner, true)
            .map(|inner| ResourceCommitPermit { inner })
    }

    fn validate_live_session_binding(
        &self,
        binding: &PermissionCommitBinding,
        session: &AuthenticatedPluginSession,
    ) -> Result<(), CommitError> {
        let authority = self
            .shared
            .commit_authority
            .ok_or(CommitError::WrongDomain)?;
        if !Arc::ptr_eq(&self.shared, &session.shared)
            || !binding.operation.belongs_to(
                &self.shared.commit_domain,
                authority,
                permission_session_scope(session.session_id),
            )
            || binding.session_id != session.session_id
            || binding.session_proof_hash != hash_bytes(&session.bearer_proof)
            || binding.plugin_id != session.plugin_id
        {
            return Err(CommitError::WrongDomain);
        }
        Ok(())
    }

    fn validate_bound_commit_inner(
        &self,
        binding: PermissionCommitBinding,
        resource_required: bool,
    ) -> Result<CommitPermit, CommitError> {
        let authority = self
            .shared
            .commit_authority
            .ok_or(CommitError::WrongDomain)?;
        if !binding.operation.belongs_to(
            &self.shared.commit_domain,
            authority,
            permission_session_scope(binding.session_id),
        ) {
            return Err(CommitError::WrongDomain);
        }
        if resource_required != binding.resource_scope.is_some() {
            return Err(CommitError::PermissionDenied);
        }
        {
            let state = self
                .shared
                .state
                .read()
                .map_err(|_| CommitError::InternalState)?;
            validate_commit_snapshot(
                &state,
                binding.session_id,
                &binding.plugin_id,
                &binding.session_proof_hash,
                &binding.grants,
            )?;
        }
        binding.operation.bind_grants(&binding.grant_scopes)?;
        if resource_required {
            binding.operation.admit_full()
        } else {
            binding.operation.admit()
        }
    }
}

impl PermissionControlPlane {
    /// Drains the current bounded audit queue without blocking producers.
    #[must_use]
    pub fn drain_audit_events(&self) -> PermissionAuditDrain {
        let receiver = match self.shared.audit_rx.lock() {
            Ok(receiver) => receiver,
            Err(poisoned) => poisoned.into_inner(),
        };
        let mut events = Vec::with_capacity(MAX_AUDIT_EVENTS);
        while events.len() < MAX_AUDIT_EVENTS {
            match receiver.try_recv() {
                Ok(event) => events.push(event),
                Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
            }
        }
        PermissionAuditDrain {
            events,
            dropped_total: self.audit_dropped_count(),
        }
    }

    /// Returns the cumulative number of audit events dropped by the full queue.
    #[must_use]
    pub fn audit_dropped_count(&self) -> u64 {
        self.shared.dropped_audit_events.load(Ordering::Relaxed)
    }
}

impl PermissionShared {
    fn begin_commit_mutation(
        &self,
        scope: PermissionMutationScope,
    ) -> Result<Option<PermissionMutationFence>, PermissionError> {
        let Some(authority) = self.commit_authority else {
            return Ok(None);
        };
        self.commit_domain
            .begin_permission_mutation(authority, scope)
            .map(Some)
            .map_err(|_| PermissionError::InternalState)
    }

    fn finish_commit_mutation(
        &self,
        mutation: Option<PermissionMutationFence>,
    ) -> Result<(), PermissionError> {
        if let Some(mutation) = mutation {
            mutation
                .finish()
                .map(|_| ())
                .map_err(|_| PermissionError::InternalState)?;
        }
        Ok(())
    }

    fn close_session_lease(
        &self,
        session: &AuthenticatedPluginSession,
    ) -> Result<(), PermissionError> {
        let active = {
            let state = self
                .state
                .read()
                .map_err(|_| PermissionError::InternalState)?;
            session_is_active(&state, session)
        };
        if !active {
            self.emit_session(
                PermissionAuditAction::CloseSession,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
                None,
            );
            return Err(PermissionError::SessionRejected);
        }
        let mutation = self.begin_commit_mutation(PermissionMutationScope::Session(
            permission_session_scope(session.session_id),
        ))?;
        let closed = {
            let mut state = self.state.write().map_err(|_| {
                self.emit_session(
                    PermissionAuditAction::CloseSession,
                    PermissionAuditOutcome::Denied,
                    PermissionAuditReason::InternalState,
                    Some(session.plugin_id.clone()),
                );
                PermissionError::InternalState
            })?;
            if !session_is_active(&state, session) {
                false
            } else {
                state.sessions.remove(&session.session_id);
                state
                    .grants
                    .retain(|_, grant| grant.session_id != session.session_id);
                true
            }
        };
        if !closed {
            self.finish_commit_mutation(mutation)?;
            self.emit_session(
                PermissionAuditAction::CloseSession,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::SessionRejected,
                None,
            );
            return Err(PermissionError::SessionRejected);
        }
        self.finish_commit_mutation(mutation)?;
        self.emit_session(
            PermissionAuditAction::CloseSession,
            PermissionAuditOutcome::Allowed,
            PermissionAuditReason::SessionClosed,
            Some(session.plugin_id.clone()),
        );
        Ok(())
    }

    fn is_session_active(
        &self,
        session: &AuthenticatedPluginSession,
    ) -> Result<bool, PermissionError> {
        let state = self.state.read().map_err(|_| {
            self.emit_session(
                PermissionAuditAction::Grant,
                PermissionAuditOutcome::Denied,
                PermissionAuditReason::InternalState,
                Some(session.plugin_id.clone()),
            );
            PermissionError::InternalState
        })?;
        Ok(session_is_active(&state, session))
    }

    fn allocate_generation(&self) -> Option<u64> {
        self.next_generation
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
                current.checked_add(1)
            })
            .ok()
    }

    fn emit_invalid_grant(&self) {
        self.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Grant,
            outcome: PermissionAuditOutcome::Denied,
            reason: PermissionAuditReason::InvalidGrant,
            plugin_id: None,
            capability_id: None,
            grant_id: None,
            generation: None,
        });
    }

    fn emit_grant_session_rejected(&self, session: &AuthenticatedPluginSession) {
        self.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Grant,
            outcome: PermissionAuditOutcome::Denied,
            reason: PermissionAuditReason::SessionRejected,
            plugin_id: Some(session.plugin_id.clone()),
            capability_id: None,
            grant_id: None,
            generation: None,
        });
    }

    fn emit_for_grant(
        &self,
        plugin_id: &PluginId,
        grant: &CapabilityGrant,
        generation: Option<u64>,
        outcome: PermissionAuditOutcome,
        reason: PermissionAuditReason,
    ) {
        self.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Grant,
            outcome,
            reason,
            plugin_id: Some(plugin_id.clone()),
            capability_id: Some(grant.capability_id.clone()),
            grant_id: Some(grant.id.clone()),
            generation,
        });
    }

    fn emit_unknown_revoke(&self, grant_id: Option<GrantId>) {
        self.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Revoke,
            outcome: PermissionAuditOutcome::Denied,
            reason: PermissionAuditReason::UnknownOrRevokedGrant,
            plugin_id: None,
            capability_id: None,
            grant_id,
            generation: None,
        });
    }

    fn emit_authorization(
        &self,
        session: &AuthenticatedPluginSession,
        handle: &CapabilityHandle,
        operation: &CapabilityOperation,
        outcome: PermissionAuditOutcome,
        reason: PermissionAuditReason,
    ) {
        self.emit(PermissionAuditEvent {
            action: PermissionAuditAction::Authorize,
            outcome,
            reason,
            plugin_id: Some(session.plugin_id.clone()),
            capability_id: Some(operation.capability_id.clone()),
            grant_id: Some(handle.grant_id().clone()),
            generation: Some(handle.generation()),
        });
    }

    fn emit_session(
        &self,
        action: PermissionAuditAction,
        outcome: PermissionAuditOutcome,
        reason: PermissionAuditReason,
        plugin_id: Option<PluginId>,
    ) {
        self.emit(PermissionAuditEvent {
            action,
            outcome,
            reason,
            plugin_id,
            capability_id: None,
            grant_id: None,
            generation: None,
        });
    }

    fn emit(&self, event: PermissionAuditEvent) {
        match self.audit_tx.try_send(event) {
            Ok(()) => {}
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
                let _ = self.dropped_audit_events.fetch_update(
                    Ordering::Relaxed,
                    Ordering::Relaxed,
                    |current| Some(current.saturating_add(1)),
                );
            }
        }
    }
}

fn validate_commit_snapshot(
    state: &PermissionState,
    session_id: SessionId,
    plugin_id: &PluginId,
    session_proof_hash: &[u8; 32],
    grants: &[CommitGrantSnapshot],
) -> Result<(), CommitError> {
    if !session_binding_is_active(state, session_id, plugin_id, session_proof_hash)
        || grants.iter().any(|snapshot| {
            state.grants.get(&snapshot.grant_id).is_none_or(|active| {
                active.generation != snapshot.generation
                    || active.session_id != session_id
                    || active.plugin_id != snapshot.plugin_id
                    || active.capability_id != snapshot.capability_id
            })
        })
    {
        return Err(CommitError::PermissionDenied);
    }
    Ok(())
}

/// Errors returned by the host permission boundary.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum PermissionError {
    /// A grant failed canonical DTO validation.
    #[error("capability grant failed canonical validation")]
    InvalidGrant {
        /// Underlying contract validation error.
        #[source]
        source: ContractError,
    },
    /// A compatible plugin session could not be opened or was closed.
    #[error("authenticated plugin session rejected")]
    SessionRejected,
    /// A compatible manifest did not declare the requested capability.
    #[error("capability was not declared by a compatible plugin")]
    UndeclaredCapability,
    /// Grant constraints exceeded the manifest declaration.
    #[error("capability grant constraints exceed the manifest declaration")]
    ConstraintsTooBroad,
    /// The same grant identifier is already active.
    #[error("capability grant is already active")]
    AlreadyGranted,
    /// The bounded active-grant registry is full.
    #[error("active capability grant limit reached")]
    ActiveGrantLimitReached,
    /// The bounded active-session registry is full.
    #[error("active plugin session limit reached")]
    ActiveSessionLimitReached,
    /// Authorization failed without revealing handle existence or state.
    #[error("capability permission denied")]
    PermissionDenied,
    /// The operating system could not provide secure randomness.
    #[error("secure capability proof generation is unavailable")]
    EntropyUnavailable,
    /// The grant generation counter cannot advance safely.
    #[error("capability grant generation exhausted")]
    GenerationExhausted,
    /// Internal synchronization state failed closed.
    #[error("capability authorization state is unavailable")]
    InternalState,
}

fn session_is_active(state: &PermissionState, session: &AuthenticatedPluginSession) -> bool {
    session_binding_is_active(
        state,
        session.session_id,
        &session.plugin_id,
        &hash_bytes(&session.bearer_proof),
    )
}

fn session_binding_is_active(
    state: &PermissionState,
    session_id: SessionId,
    plugin_id: &PluginId,
    proof_hash: &[u8; 32],
) -> bool {
    state
        .sessions
        .get(&session_id)
        .is_some_and(|active| active.plugin_id == *plugin_id && active.proof_hash == *proof_hash)
}

fn hash_bytes(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

fn permission_session_scope(session_id: SessionId) -> PermissionSessionScope {
    let mut hasher = Sha256::new();
    hasher.update(b"timetrace.commit.permission-session.v1\0");
    hasher.update(session_id.0);
    PermissionSessionScope::from_hash(hasher.finalize().into())
}

fn permission_grant_scope(grant_id: &GrantId, generation: u64) -> PermissionGrantScope {
    let mut hasher = Sha256::new();
    hasher.update(b"timetrace.commit.permission-grant.v1\0");
    hasher.update(grant_id.as_str().as_bytes());
    PermissionGrantScope::from_hash(hasher.finalize().into(), generation)
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Arc, Barrier},
        thread,
    };

    use semver::Version;
    use timetrace_plugin_api::{
        CURRENT_MANIFEST_SCHEMA_VERSION, CapabilityRequest, HostApiRange, Platform, PluginManifest,
        PublisherId, USAGE_AGGREGATE_READ,
    };

    use super::*;
    use crate::CommitOperationState;

    fn plugin_id() -> PluginId {
        PluginId::new("sample-plugin").expect("valid plugin")
    }

    fn capability_id() -> CapabilityId {
        CapabilityId::new(USAGE_AGGREGATE_READ).expect("valid capability")
    }

    fn declared_constraints() -> CapabilityConstraints {
        CapabilityConstraints {
            max_range_days: Some(7),
            allowed_granularities: [UsageGranularity::Day, UsageGranularity::Application]
                .into_iter()
                .collect(),
            max_rows: Some(1_000),
            max_bytes: Some(64 * 1_024),
            allowed_domains: Default::default(),
        }
    }

    fn manifest(id: &str, platforms: Vec<Platform>) -> PluginManifest {
        PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: PluginId::new(id).expect("valid plugin"),
            publisher: PublisherId::new("wellorbetter").expect("valid publisher"),
            display_name: "Sample plugin".to_owned(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("valid range"),
            platforms,
            contributions: Vec::new(),
            requested_capabilities: vec![CapabilityRequest {
                id: capability_id(),
                constraints: declared_constraints(),
                rationale: None,
            }],
        }
    }

    fn catalog(manifests: impl IntoIterator<Item = PluginManifest>) -> PluginCatalog {
        PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, manifests)
            .expect("valid catalog")
    }

    fn single_catalog() -> PluginCatalog {
        catalog([manifest("sample-plugin", vec![Platform::WindowsX64])])
    }

    fn grant(id: &str, constraints: CapabilityConstraints) -> CapabilityGrant {
        CapabilityGrant {
            id: GrantId::new(id).expect("valid grant id"),
            plugin_id: plugin_id(),
            capability_id: capability_id(),
            constraints,
        }
    }

    fn operation() -> CapabilityOperation {
        CapabilityOperation::requiring(capability_id()).expect("valid operation")
    }

    fn authority(catalog: &PluginCatalog) -> (PermissionControlPlane, PermissionAuthorizer) {
        let control = PermissionControlPlane::from_catalog(catalog);
        let authorizer = control.authorizer();
        (control, authorizer)
    }

    fn isolated_authority(
        catalog: &PluginCatalog,
    ) -> (PermissionControlPlane, PermissionAuthorizer) {
        let domain = CommitDomain::isolated_for_test();
        let authority = domain
            .register_permission_authority()
            .expect("isolated commit authority");
        let control = PermissionControlPlane::build(catalog, domain, Some(authority));
        let authorizer = control.authorizer();
        (control, authorizer)
    }

    fn session(control: &PermissionControlPlane) -> AuthenticatedPluginSession {
        control
            .open_session(&plugin_id())
            .expect("authenticated session")
    }

    fn issue(
        control: &PermissionControlPlane,
        session: &AuthenticatedPluginSession,
        grant: CapabilityGrant,
    ) -> CapabilityHandle {
        let decision = control
            .approve_grant(session, grant)
            .expect("host approves exact grant");
        control.grant(decision).expect("approved grant is issued")
    }

    fn admitted_resource_commit(
        control: &PermissionControlPlane,
        authorizer: &PermissionAuthorizer,
        session: &AuthenticatedPluginSession,
        grant_id: &str,
        resource_key: &[u8],
    ) -> (CommitOperationId, ResourceCommitPermit) {
        let (operation_id, binding, _, _) =
            resource_bound_binding(control, authorizer, session, grant_id, resource_key);
        let permit = authorizer
            .validate_bound_commit_with_resource(binding)
            .expect("resource commit admitted");
        (operation_id, permit)
    }

    fn resource_bound_binding(
        control: &PermissionControlPlane,
        authorizer: &PermissionAuthorizer,
        session: &AuthenticatedPluginSession,
        grant_id: &str,
        resource_key: &[u8],
    ) -> (
        CommitOperationId,
        ResourceBoundPermissionCommitBinding,
        crate::CommitResourceAuthority,
        crate::CommitResourceKey,
    ) {
        let resources = control
            .commit_domain()
            .register_resource_authority()
            .expect("resource authority");
        let scope = resources
            .register_initial(resource_key, 1)
            .expect("resource scope");
        let key = scope.key();
        let handle = issue(control, session, grant(grant_id, declared_constraints()));
        let call = authorizer
            .authorize(session, &handle, &operation())
            .expect("authorization");
        let operation = control
            .begin_commit_operation(session, crate::MAX_PRECOMMIT_TTL)
            .expect("commit operation");
        let operation_id = operation.id();
        let binding = authorizer
            .bind_commit(operation, session, &[&call])
            .expect("permission binding")
            .bind_resource(scope)
            .expect("resource binding");
        (operation_id, binding, resources, key)
    }

    #[test]
    fn data_plane_only_authorizes_host_approved_session_bound_handle() {
        fn plugin_rpc_boundary(authorizer: PermissionAuthorizer) -> PermissionAuthorizer {
            authorizer
        }

        let (control, authorizer) = authority(&single_catalog());
        let authorizer = plugin_rpc_boundary(authorizer);
        let first = session(&control);
        let second = session(&control);
        let handle = issue(
            &control,
            &first,
            grant("grant-session", declared_constraints()),
        );

        assert!(authorizer.authorize(&first, &handle, &operation()).is_ok());
        assert_eq!(
            authorizer.authorize(&second, &handle, &operation()),
            Err(PermissionError::PermissionDenied)
        );
        assert!(format!("{first:?}").contains("REDACTED"));
    }

    #[test]
    fn approved_decision_cannot_move_to_another_same_plugin_session() {
        let (control, _) = authority(&single_catalog());
        let first = session(&control);
        let decision = control
            .approve_grant(
                &first,
                grant("grant-bound-decision", declared_constraints()),
            )
            .expect("host approval");
        drop(first);
        let _second = session(&control);

        assert_eq!(
            control.grant(decision),
            Err(PermissionError::SessionRejected)
        );
    }

    #[test]
    fn approval_rejects_a_grant_claiming_another_plugin() {
        let plugin_catalog = catalog([
            manifest("sample-plugin", vec![Platform::WindowsX64]),
            manifest("other-plugin", vec![Platform::WindowsX64]),
        ]);
        let (control, _) = authority(&plugin_catalog);
        let other_id = PluginId::new("other-plugin").expect("valid plugin");
        let other = control
            .open_session(&other_id)
            .expect("other authenticated session");

        assert!(matches!(
            control.approve_grant(&other, grant("grant-spoof", declared_constraints())),
            Err(PermissionError::PermissionDenied)
        ));
    }

    #[test]
    fn constraints_are_normalized_and_can_only_narrow() {
        let mut default_manifest = manifest("sample-plugin", vec![Platform::WindowsX64]);
        default_manifest.requested_capabilities[0].constraints = CapabilityConstraints::default();
        let (control, authorizer) = authority(&catalog([default_manifest]));
        let default_session = session(&control);
        let handle = issue(
            &control,
            &default_session,
            grant("grant-default", CapabilityConstraints::default()),
        );
        let call = authorizer
            .authorize(&default_session, &handle, &operation())
            .expect("authorized call");
        assert_eq!(call.constraints().max_range_days(), MAX_QUERY_RANGE_DAYS);
        assert_eq!(call.constraints().max_rows(), MAX_QUERY_ROWS);
        assert_eq!(call.constraints().max_bytes(), MAX_QUERY_BYTES);
        assert!(call.constraints().allowed_granularities().is_empty());
        assert!(call.constraints().allowed_domains().is_empty());

        let (constrained_control, _) = authority(&single_catalog());
        let constrained_session = session(&constrained_control);
        let broader = CapabilityConstraints {
            max_range_days: Some(8),
            allowed_granularities: [UsageGranularity::Day, UsageGranularity::Hour]
                .into_iter()
                .collect(),
            max_rows: Some(500),
            max_bytes: Some(32 * 1_024),
            allowed_domains: Default::default(),
        };
        assert!(matches!(
            constrained_control
                .approve_grant(&constrained_session, grant("grant-too-broad", broader)),
            Err(PermissionError::ConstraintsTooBroad)
        ));
    }

    #[test]
    fn forged_proof_and_control_plane_revoke_fail_closed() {
        let (control, authorizer) = authority(&single_catalog());
        let session = session(&control);
        let grant = grant("grant-proof", declared_constraints());
        let handle = issue(&control, &session, grant.clone());
        let forged = CapabilityHandle::from_host_parts(
            handle.grant_id().clone(),
            handle.generation(),
            [9; CAPABILITY_PROOF_BYTES],
        )
        .expect("valid forged shape");
        assert_eq!(
            authorizer.authorize(&session, &forged, &operation()),
            Err(PermissionError::PermissionDenied)
        );
        control.revoke(&grant.id).expect("host revokes grant");
        assert_eq!(
            authorizer.authorize(&session, &handle, &operation()),
            Err(PermissionError::PermissionDenied)
        );
    }

    #[test]
    fn dropping_session_without_close_reclaims_it_and_all_grants() {
        let (control, authorizer) = authority(&single_catalog());
        let first = session(&control);
        let handle = issue(
            &control,
            &first,
            grant("grant-drop", declared_constraints()),
        );
        drop(first);
        let replacement = session(&control);

        assert_eq!(
            authorizer.authorize(&replacement, &handle, &operation()),
            Err(PermissionError::PermissionDenied)
        );
    }

    #[test]
    fn admitted_call_can_complete_after_explicit_close() {
        let (control, authorizer) = authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-concurrent", declared_constraints()),
        );
        let admitted = authorizer
            .authorize(&session, &handle, &operation())
            .expect("call admitted");
        let barrier = Arc::new(Barrier::new(2));
        let worker_barrier = Arc::clone(&barrier);
        let worker = thread::spawn(move || {
            worker_barrier.wait();
            worker_barrier.wait();
            admitted
        });
        barrier.wait();
        control.close_session(session).expect("close session");
        barrier.wait();
        assert_eq!(
            worker
                .join()
                .expect("admitted operation completes")
                .grant_id()
                .as_str(),
            "grant-concurrent"
        );
    }

    #[test]
    fn global_session_and_grant_slots_reclaim_on_raii_drop() {
        let (control, _) = authority(&single_catalog());
        let mut sessions = Vec::with_capacity(MAX_ACTIVE_SESSIONS);
        for _ in 0..MAX_ACTIVE_SESSIONS {
            sessions.push(session(&control));
        }
        assert!(matches!(
            control.open_session(&plugin_id()),
            Err(PermissionError::ActiveSessionLimitReached)
        ));
        drop(sessions.pop().expect("one active session"));
        let grant_session = session(&control);

        for index in 0..MAX_ACTIVE_GRANTS {
            issue(
                &control,
                &grant_session,
                grant(&format!("grant-{index}"), declared_constraints()),
            );
        }
        let overflow = control
            .approve_grant(
                &grant_session,
                grant("grant-over-limit", declared_constraints()),
            )
            .expect("approval itself is bounded to the session");
        assert_eq!(
            control.grant(overflow),
            Err(PermissionError::ActiveGrantLimitReached)
        );
        drop(grant_session);
        let replacement = session(&control);
        issue(
            &control,
            &replacement,
            grant("grant-after-drop", declared_constraints()),
        );
    }

    #[test]
    fn authorized_operation_trait_consumes_admission_by_value() {
        struct Service;
        impl AuthorizedOperation for Service {
            type Output = PluginId;

            fn execute(self, authorization: AuthorizedCall) -> Self::Output {
                authorization.plugin_id().clone()
            }
        }

        let (control, authorizer) = authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-consume", declared_constraints()),
        );
        let admitted = authorizer
            .authorize(&session, &handle, &operation())
            .expect("call admitted");
        assert_eq!(Service.execute(admitted), plugin_id());
    }

    #[test]
    fn audit_queue_is_bounded_nonblocking_and_reports_drops() {
        let (control, _) = authority(&single_catalog());
        assert!(control.drain_audit_events().events().is_empty());
        let unknown = PluginId::new("unknown-plugin").expect("valid plugin");
        for _ in 0..(MAX_AUDIT_EVENTS + 7) {
            assert!(matches!(
                control.open_session(&unknown),
                Err(PermissionError::SessionRejected)
            ));
        }
        let drained = control.drain_audit_events();
        assert_eq!(drained.events().len(), MAX_AUDIT_EVENTS);
        assert_eq!(drained.dropped_total(), 7);
        assert_eq!(control.audit_dropped_count(), 7);
    }

    #[test]
    fn explicit_close_emits_exactly_one_close_audit() {
        let (control, authorizer) = authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-audit", declared_constraints()),
        );
        authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorize accepted");
        let before_close = control.drain_audit_events().into_events();
        assert_eq!(before_close.len(), 3);
        control.close_session(session).expect("close session");

        let close_events = control.drain_audit_events().into_events();
        assert_eq!(close_events.len(), 1);
        assert_eq!(close_events[0].reason, PermissionAuditReason::SessionClosed);
    }

    #[test]
    fn commit_binding_revalidates_then_admits_without_retaining_permission_lock() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-commit", declared_constraints()),
        );
        let admission = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let commit = control
            .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
            .expect("commit operation");
        let id = commit.id();
        let binding = authorizer
            .bind_commit(commit, &session, &[&admission])
            .expect("permission binding");
        let permit = authorizer
            .validate_commit(binding, &session)
            .expect("commit admitted");

        assert_eq!(
            control.commit_domain().operation_state(&id),
            Ok(Some(CommitOperationState::Committing))
        );
        permit.mark_committed().expect("commit result");
        assert_eq!(
            control.commit_domain().operation_state(&id),
            Ok(Some(CommitOperationState::Committed))
        );
    }

    #[test]
    fn convenience_constructor_is_permission_only() {
        let control = PermissionControlPlane::from_catalog(&single_catalog());
        let session = session(&control);
        assert_eq!(
            control
                .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::WrongDomain)
        );
    }

    #[test]
    fn resource_bound_commit_rejects_stale_revision_then_admits_current() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let resources = control
            .commit_domain()
            .register_resource_authority()
            .expect("resource authority");
        let scope = resources.register_initial(b"provider-a", 1).expect("scope");
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-full-resource", declared_constraints()),
        );
        let call = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let binding = authorizer
            .bind_commit(
                control
                    .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
                    .expect("operation"),
                &session,
                &[&call],
            )
            .expect("binding")
            .bind_resource(scope)
            .expect("resource binding");
        resources
            .begin_mutation(scope.key())
            .expect("update")
            .finish_updated(2)
            .expect("publish R2");
        assert_eq!(
            authorizer
                .validate_commit_with_resource(binding, &session)
                .err(),
            Some(CommitError::Cancelled)
        );

        let scope = resources
            .current_scope(scope.key())
            .expect("current scope")
            .expect("live R2");
        let call = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let binding = authorizer
            .bind_commit(
                control
                    .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
                    .expect("operation"),
                &session,
                &[&call],
            )
            .expect("binding")
            .bind_resource(scope)
            .expect("resource binding");
        authorizer
            .validate_commit_with_resource(binding, &session)
            .expect("full admission")
            .mark_committed()
            .expect("commit");
    }

    #[test]
    fn revoke_before_commit_validation_yields_no_permit() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let grant = grant("grant-precommit-revoke", declared_constraints());
        let handle = issue(&control, &session, grant.clone());
        let admission = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let commit = control
            .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
            .expect("commit operation");
        let id = commit.id();
        let binding = authorizer
            .bind_commit(commit, &session, &[&admission])
            .expect("permission binding");

        control.revoke(&grant.id).expect("revoke");
        assert_eq!(
            authorizer.validate_commit(binding, &session).err(),
            Some(CommitError::PermissionDenied)
        );
        assert_eq!(
            control.commit_domain().operation_state(&id),
            Ok(Some(CommitOperationState::Cancelled))
        );
    }

    #[test]
    fn revoke_after_commit_admission_is_bounded_and_too_late() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let grant = grant("grant-post-admission", declared_constraints());
        let handle = issue(&control, &session, grant.clone());
        let admission = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let commit = control
            .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
            .expect("commit operation");
        let binding = authorizer
            .bind_commit(commit, &session, &[&admission])
            .expect("permission binding");
        let permit = authorizer
            .validate_commit(binding, &session)
            .expect("commit admitted");

        let started = std::time::Instant::now();
        control.revoke(&grant.id).expect("revoke after admission");
        assert!(started.elapsed() < std::time::Duration::from_millis(250));
        permit
            .mark_committed()
            .expect("commit remains authoritative");
    }

    #[test]
    fn detached_operation_is_rejected_by_canonical_permission_authority() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-wrong-domain", declared_constraints()),
        );
        let admission = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorization");
        let detached_domain = CommitDomain::isolated_for_test();
        let detached_authority = detached_domain
            .register_permission_authority()
            .expect("detached authority");
        let detached = detached_domain
            .begin_operation(
                detached_authority,
                permission_session_scope(session.session_id),
                crate::MAX_PRECOMMIT_TTL,
            )
            .expect("detached operation");
        assert_eq!(
            authorizer
                .bind_commit(detached, &session, &[&admission])
                .err(),
            Some(CommitError::WrongDomain)
        );
    }

    #[test]
    fn explicit_and_raii_session_close_cancel_precommit_work() {
        let (control, _) = isolated_authority(&single_catalog());
        let explicit = session(&control);
        let explicit_commit = control
            .begin_commit_operation(&explicit, crate::MAX_PRECOMMIT_TTL)
            .expect("operation");
        let explicit_id = explicit_commit.id();
        control.close_session(explicit).expect("explicit close");
        assert_eq!(
            control.commit_domain().operation_state(&explicit_id),
            Ok(Some(CommitOperationState::Cancelled))
        );
        let replacement_session = session(&control);
        let replacement = control
            .begin_commit_operation(&replacement_session, crate::MAX_PRECOMMIT_TTL)
            .expect("closed session terminal does not consume active capacity");
        drop(replacement);
        drop(replacement_session);

        let raii = session(&control);
        let raii_commit = control
            .begin_commit_operation(&raii, crate::MAX_PRECOMMIT_TTL)
            .expect("operation");
        let raii_id = raii_commit.id();
        drop(raii);
        assert_eq!(
            control.commit_domain().operation_state(&raii_id),
            Ok(Some(CommitOperationState::Cancelled))
        );
    }

    #[test]
    fn scoped_revoke_cancels_only_the_matching_session_and_grant() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session_a = session(&control);
        let session_b = session(&control);
        let grant_a = grant("grant-scope-a", declared_constraints());
        let grant_b = grant("grant-scope-b", declared_constraints());
        let handle_a = issue(&control, &session_a, grant_a.clone());
        let handle_b = issue(&control, &session_b, grant_b);
        let call_a = authorizer
            .authorize(&session_a, &handle_a, &operation())
            .expect("authorize A");
        let call_b = authorizer
            .authorize(&session_b, &handle_b, &operation())
            .expect("authorize B");
        let binding_a = authorizer
            .bind_commit(
                control
                    .begin_commit_operation(&session_a, crate::MAX_PRECOMMIT_TTL)
                    .expect("operation A"),
                &session_a,
                &[&call_a],
            )
            .expect("binding A");
        let binding_b = authorizer
            .bind_commit(
                control
                    .begin_commit_operation(&session_b, crate::MAX_PRECOMMIT_TTL)
                    .expect("operation B"),
                &session_b,
                &[&call_b],
            )
            .expect("binding B");

        control.revoke(&grant_a.id).expect("revoke A");
        assert_eq!(
            authorizer.validate_commit(binding_a, &session_a).err(),
            Some(CommitError::PermissionDenied)
        );
        authorizer
            .validate_commit(binding_b, &session_b)
            .expect("B remains admissible")
            .mark_committed()
            .expect("B commits");
    }

    #[test]
    fn unknown_revoke_does_not_invalidate_unrelated_bound_operation() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let handle = issue(
            &control,
            &session,
            grant("grant-known", declared_constraints()),
        );
        let call = authorizer
            .authorize(&session, &handle, &operation())
            .expect("authorize");
        let binding = authorizer
            .bind_commit(
                control
                    .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
                    .expect("operation"),
                &session,
                &[&call],
            )
            .expect("binding");
        let unknown = GrantId::new("grant-unknown").expect("valid unknown grant");

        assert_eq!(
            control.revoke(&unknown),
            Err(PermissionError::PermissionDenied)
        );
        authorizer
            .validate_commit(binding, &session)
            .expect("unknown revoke leaves binding current")
            .mark_committed()
            .expect("commit");
    }

    #[test]
    fn resource_recovery_handle_resolves_each_terminal_outcome() {
        for (suffix, resolution, expected) in [
            (
                "committed",
                CommitRecoveryResolution::Committed,
                CommitOperationState::Committed,
            ),
            (
                "absent",
                CommitRecoveryResolution::DefinitelyAbsent,
                CommitOperationState::Cancelled,
            ),
        ] {
            let (control, authorizer) = isolated_authority(&single_catalog());
            let session = session(&control);
            let (operation_id, permit) = admitted_resource_commit(
                &control,
                &authorizer,
                &session,
                &format!("grant-recovery-{suffix}"),
                suffix.as_bytes(),
            );
            let recovery = permit
                .mark_durability_unknown()
                .expect("durability becomes unknown");

            assert_eq!(
                control.commit_domain().operation_state(&operation_id),
                Ok(Some(CommitOperationState::DurabilityUnknown))
            );
            recovery
                .resolve(resolution)
                .expect("recovery resolves once");
            assert_eq!(
                control.commit_domain().operation_state(&operation_id),
                Ok(Some(expected))
            );
        }
    }

    #[test]
    fn dropping_resource_recovery_handle_preserves_unknown_state() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let (operation_id, permit) = admitted_resource_commit(
            &control,
            &authorizer,
            &session,
            "grant-recovery-drop",
            b"provider-drop",
        );
        let recovery = permit
            .mark_durability_unknown()
            .expect("durability becomes unknown");

        drop(recovery);

        assert_eq!(
            control.commit_domain().operation_state(&operation_id),
            Ok(Some(CommitOperationState::DurabilityUnknown))
        );
        assert_eq!(
            control
                .begin_commit_operation(&session, crate::MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::CapacityReached)
        );
    }

    #[test]
    fn resource_recovery_authority_is_domain_bound_and_debug_redacted() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let (operation_id, permit) = admitted_resource_commit(
            &control,
            &authorizer,
            &session,
            "grant-recovery-domain",
            b"provider-domain",
        );
        let recovery = permit
            .mark_durability_unknown()
            .expect("durability becomes unknown");
        assert_eq!(
            format!("{recovery:?}"),
            "ResourceCommitRecoveryHandle([REDACTED])"
        );

        let detached = CommitDomain::isolated_for_test();
        let detached_authority = detached
            .register_permission_authority()
            .expect("detached authority");
        assert_eq!(
            detached.resolve_recovery(
                detached_authority,
                &operation_id,
                CommitRecoveryResolution::Committed,
            ),
            Err(CommitError::InvalidTransition)
        );
        recovery
            .resolve(CommitRecoveryResolution::Committed)
            .expect("canonical handle resolves canonical domain");
        assert_eq!(
            control.commit_domain().operation_state(&operation_id),
            Ok(Some(CommitOperationState::Committed))
        );
    }

    #[test]
    fn bound_resource_validation_rejects_closed_session_without_live_lease() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let (_, binding, _, _) = resource_bound_binding(
            &control,
            &authorizer,
            &session,
            "grant-bound-close",
            b"provider-bound-close",
        );

        control.close_session(session).expect("close session");

        assert_eq!(
            authorizer
                .validate_bound_commit_with_resource(binding)
                .err(),
            Some(CommitError::PermissionDenied)
        );
    }

    #[test]
    fn bound_resource_validation_rejects_revoked_and_reissued_grant_generation() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let grant_id = "grant-bound-stale";
        let (_, binding, _, _) = resource_bound_binding(
            &control,
            &authorizer,
            &session,
            grant_id,
            b"provider-bound-stale",
        );
        let id = GrantId::new(grant_id).expect("grant id");

        control.revoke(&id).expect("revoke old generation");
        let replacement = issue(&control, &session, grant(grant_id, declared_constraints()));
        assert!(replacement.generation() > 0);

        assert_eq!(
            authorizer
                .validate_bound_commit_with_resource(binding)
                .err(),
            Some(CommitError::PermissionDenied)
        );
    }

    #[test]
    fn bound_resource_validation_rejects_wrong_authorizer_domain() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let (_, binding, _, _) = resource_bound_binding(
            &control,
            &authorizer,
            &session,
            "grant-bound-domain",
            b"provider-bound-domain",
        );
        let (_, detached_authorizer) = isolated_authority(&single_catalog());

        assert_eq!(
            detached_authorizer
                .validate_bound_commit_with_resource(binding)
                .err(),
            Some(CommitError::WrongDomain)
        );
    }

    #[test]
    fn resource_mutation_fence_wins_before_bound_worker_admission() {
        let (control, authorizer) = isolated_authority(&single_catalog());
        let session = session(&control);
        let (_, binding, resources, resource_key) = resource_bound_binding(
            &control,
            &authorizer,
            &session,
            "grant-bound-fence",
            b"provider-bound-fence",
        );
        let fence = resources
            .begin_mutation(resource_key)
            .expect("resource mutation fence");

        assert_eq!(
            authorizer
                .validate_bound_commit_with_resource(binding)
                .err(),
            Some(CommitError::MutationInProgress)
        );
        fence.abort().expect("clean mutation abort");
    }
}
