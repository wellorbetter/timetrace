//! Short-critical-section commit admission shared by host control planes.

use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};
use thiserror::Error;

/// Maximum retained commit operations in one domain.
pub const MAX_COMMIT_OPERATIONS: usize = 64;
/// Maximum retained operations for one authenticated plugin principal.
pub const MAX_COMMIT_OPERATIONS_PER_PRINCIPAL: usize = 1;
/// Maximum retained resolved terminal receipts.
pub const MAX_RECENT_COMMIT_TERMINALS: usize = 64;
/// Maximum canonical resource identities retained by one commit domain.
pub const MAX_COMMIT_RESOURCES: usize = 256;
/// Maximum canonical bytes accepted when minting a resource identity.
pub const MAX_COMMIT_RESOURCE_KEY_BYTES: usize = 256;
/// Maximum lifetime of the pre-commit validation phase.
pub const MAX_PRECOMMIT_TTL: Duration = Duration::from_secs(60);

const ID_BYTES: usize = 32;
const MAX_PERMISSION_MUTATION_FENCES: usize = 64;

/// Stable failures from the host commit linearization boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CommitError {
    /// The supplied binding belongs to another composition authority.
    #[error("commit_wrong_domain")]
    WrongDomain,
    /// The process already registered its one production commit authority.
    #[error("commit_authority_already_registered")]
    AuthorityAlreadyRegistered,
    /// Current permission state no longer matches the prepared binding.
    #[error("commit_permission_denied")]
    PermissionDenied,
    /// A control-plane mutation won before commit admission.
    #[error("commit_cancelled")]
    Cancelled,
    /// Commit admission already won, so cancellation is too late.
    #[error("commit_already_started")]
    CommitAlreadyStarted,
    /// A matching control-plane mutation is already fenced.
    #[error("commit_mutation_in_progress")]
    MutationInProgress,
    /// The operation state cannot perform the requested transition.
    #[error("commit_invalid_transition")]
    InvalidTransition,
    /// The bounded operation registry has no available slot.
    #[error("commit_capacity_reached")]
    CapacityReached,
    /// Secure identity generation is unavailable.
    #[error("commit_entropy_unavailable")]
    EntropyUnavailable,
    /// Physical commit succeeded, but host bookkeeping could not record it.
    ///
    /// Callers MUST NOT retry the database commit or model inference.
    #[error("commit_durable_success_bookkeeping_unavailable")]
    DurableSuccessBookkeepingUnavailable,
    /// Synchronization state failed closed.
    #[error("commit_internal_state")]
    InternalState,
}

/// Canonical lifecycle of one persistence operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitOperationState {
    /// Strict validation succeeded, but commit admission has not occurred.
    PreCommit,
    /// The linearization CAS succeeded and physical commit may be running.
    Committing,
    /// Physical commit completed successfully.
    Committed,
    /// Admission succeeded but durable outcome could not be proven.
    DurabilityUnknown,
    /// A mutation, timeout, or explicit abandon won before admission.
    Cancelled,
}

/// Result of opening a permission-mutation fence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitMutationOutcome {
    /// Matching work was still pre-commit and is now cancelled.
    Invalidated,
    /// At least one matching operation had already crossed commit admission.
    CommitAlreadyStarted,
}

/// Explicit recovery result for an operation with unknown durability.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommitRecoveryResolution {
    /// Recovery proved that the commit is durable.
    Committed,
    /// Recovery proved that the commit is absent.
    DefinitelyAbsent,
}

/// Opaque host operation identity that never enters plugin wire data.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CommitOperationId([u8; ID_BYTES]);

impl fmt::Debug for CommitOperationId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitOperationId([REDACTED])")
    }
}

/// Opaque host-owned identity for a revisioned commit dependency.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct CommitResourceKey([u8; ID_BYTES]);

impl fmt::Debug for CommitResourceKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitResourceKey([REDACTED])")
    }
}

/// Exact revision of a host-owned resource required by a commit.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct CommitResourceScope {
    key: CommitResourceKey,
    revision: u64,
    authority: ResourceAuthorityId,
}

impl CommitResourceScope {
    /// Returns the opaque resource identity.
    #[must_use]
    pub fn key(&self) -> CommitResourceKey {
        self.key
    }

    /// Returns the exact validated resource revision.
    #[must_use]
    pub fn revision(&self) -> u64 {
        self.revision
    }
}

impl fmt::Debug for CommitResourceScope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommitResourceScope")
            .field("key", &"[REDACTED]")
            .field("revision", &self.revision)
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct PermissionAuthorityId([u8; ID_BYTES]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct ResourceAuthorityId([u8; ID_BYTES]);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) struct PermissionSessionScope([u8; ID_BYTES]);

impl PermissionSessionScope {
    pub(crate) fn from_hash(hash: [u8; ID_BYTES]) -> Self {
        Self(hash)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) struct PermissionGrantScope {
    key: [u8; ID_BYTES],
    generation: u64,
}

impl PermissionGrantScope {
    pub(crate) fn from_hash(key: [u8; ID_BYTES], generation: u64) -> Self {
        Self { key, generation }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum PermissionMutationScope {
    Session(PermissionSessionScope),
    Grant {
        session: PermissionSessionScope,
        grant: PermissionGrantScope,
    },
}

#[derive(Debug)]
struct CommitRecord {
    authority: PermissionAuthorityId,
    session: PermissionSessionScope,
    grants: Vec<PermissionGrantScope>,
    resource: Option<CommitResourceScope>,
    state: CommitOperationState,
    expires_at: Instant,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct MutationFenceKey {
    authority: PermissionAuthorityId,
    scope: PermissionMutationScope,
}

#[derive(Debug)]
struct TerminalRecord {
    id: CommitOperationId,
    authority: PermissionAuthorityId,
    state: CommitOperationState,
}

#[derive(Debug, Clone, Copy)]
struct CanonicalResourceState {
    revision: u64,
    tombstone: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResourceExpectedState {
    Absent,
    Live(u64),
    Tombstone(u64),
}

#[derive(Debug, Clone, Copy)]
enum ResourceMutationRequest {
    Absent,
    CurrentLive,
    Tombstone(u64),
}

#[derive(Debug, Default)]
struct CommitDomainState {
    registered_authority: Option<PermissionAuthorityId>,
    registered_resource_authority: Option<ResourceAuthorityId>,
    resources: HashMap<CommitResourceKey, CanonicalResourceState>,
    operations: HashMap<CommitOperationId, CommitRecord>,
    recent_terminals: VecDeque<TerminalRecord>,
    mutation_fences: HashSet<MutationFenceKey>,
    resource_fences: HashMap<CommitResourceKey, ResourceExpectedState>,
}

/// The sole process composition authority for persistence linearization.
///
/// Its mutex is held only for bounded in-memory state transitions. A
/// [`CommitPermit`] contains no guard, so physical commit never retains the
/// domain lock.
pub struct CommitDomain {
    state: Mutex<CommitDomainState>,
}

/// Unique host composition authority for canonical provider/resource state.
///
/// This value is neither serializable nor constructible from plugin input.
pub struct CommitResourceAuthority {
    domain: Arc<CommitDomain>,
    id: ResourceAuthorityId,
}

impl CommitResourceAuthority {
    /// Registers a new canonical resource and returns its authority-bound scope.
    pub fn register_initial(
        &self,
        canonical_key: &[u8],
        revision: u64,
    ) -> Result<CommitResourceScope, CommitError> {
        let mut scopes = self.register_initial_batch(&[(canonical_key, revision)])?;
        scopes.pop().ok_or(CommitError::InternalState)
    }

    /// Atomically registers a bounded batch of canonical initial resources.
    ///
    /// Validation, identity derivation, duplicate checks, capacity checks, and
    /// reservation all complete before the first canonical state is inserted.
    pub fn register_initial_batch(
        &self,
        entries: &[(&[u8], u64)],
    ) -> Result<Vec<CommitResourceScope>, CommitError> {
        if entries.is_empty() || entries.len() > MAX_COMMIT_RESOURCES {
            return Err(CommitError::InvalidTransition);
        }
        let mut state = self
            .domain
            .state
            .lock()
            .map_err(|_| CommitError::InternalState)?;
        validate_resource_authority(&state, self.id)?;
        let pending_creates = state
            .resource_fences
            .values()
            .filter(|state| **state == ResourceExpectedState::Absent)
            .count();
        if state
            .resources
            .len()
            .checked_add(pending_creates)
            .and_then(|total| total.checked_add(entries.len()))
            .is_none_or(|total| total > MAX_COMMIT_RESOURCES)
        {
            return Err(CommitError::CapacityReached);
        }
        let mut scopes = Vec::new();
        scopes
            .try_reserve_exact(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;
        let mut unique = HashSet::new();
        unique
            .try_reserve(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;
        for (canonical_key, revision) in entries {
            if *revision == 0 {
                return Err(CommitError::InvalidTransition);
            }
            let key = derive_resource_key(canonical_key)?;
            if state.resources.contains_key(&key)
                || state.resource_fences.contains_key(&key)
                || !unique.insert(key)
            {
                return Err(CommitError::InvalidTransition);
            }
            scopes.push(CommitResourceScope {
                key,
                revision: *revision,
                authority: self.id,
            });
        }
        state
            .resources
            .try_reserve(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;
        for scope in &scopes {
            state.resources.insert(
                scope.key,
                CanonicalResourceState {
                    revision: scope.revision,
                    tombstone: false,
                },
            );
        }
        Ok(scopes)
    }

    /// Returns the current live scope, or `None` for an unknown/tombstoned key.
    pub fn current_scope(
        &self,
        key: CommitResourceKey,
    ) -> Result<Option<CommitResourceScope>, CommitError> {
        let state = self
            .domain
            .state
            .lock()
            .map_err(|_| CommitError::InternalState)?;
        validate_resource_authority(&state, self.id)?;
        Ok(state.resources.get(&key).and_then(|current| {
            (!current.tombstone).then_some(CommitResourceScope {
                key,
                revision: current.revision,
                authority: self.id,
            })
        }))
    }

    /// Opens an exact canonical resource mutation fence.
    pub fn begin_mutation(
        &self,
        key: CommitResourceKey,
    ) -> Result<CommitResourceMutationFence, CommitError> {
        self.domain
            .begin_resource_mutation(self.id, key, ResourceMutationRequest::CurrentLive)
    }

    /// Opens a recreate fence for an exact canonical tombstone revision.
    pub fn begin_recreate(
        &self,
        key: CommitResourceKey,
        expected_tombstone_revision: u64,
    ) -> Result<CommitResourceMutationFence, CommitError> {
        if expected_tombstone_revision == 0 {
            return Err(CommitError::InvalidTransition);
        }
        self.domain.begin_resource_mutation(
            self.id,
            key,
            ResourceMutationRequest::Tombstone(expected_tombstone_revision),
        )
    }

    /// Opens an absent-state fence for a never-known canonical resource.
    pub fn begin_create(
        &self,
        canonical_key: &[u8],
    ) -> Result<CommitResourceMutationFence, CommitError> {
        let key = derive_resource_key(canonical_key)?;
        self.domain
            .begin_resource_mutation(self.id, key, ResourceMutationRequest::Absent)
    }
}

impl fmt::Debug for CommitResourceAuthority {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitResourceAuthority([HOST-OWNED])")
    }
}

impl CommitDomain {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(CommitDomainState::default()),
        })
    }

    /// Returns the sole process-canonical domain for production composition.
    #[must_use]
    pub fn process() -> Arc<Self> {
        static DOMAIN: OnceLock<Arc<CommitDomain>> = OnceLock::new();
        Arc::clone(DOMAIN.get_or_init(CommitDomain::new))
    }

    #[cfg(test)]
    pub(crate) fn isolated_for_test() -> Arc<Self> {
        Self::new()
    }

    pub(crate) fn register_permission_authority(
        &self,
    ) -> Result<PermissionAuthorityId, CommitError> {
        let mut identity = [0_u8; ID_BYTES];
        getrandom::fill(&mut identity).map_err(|_| CommitError::EntropyUnavailable)?;
        let authority = PermissionAuthorityId(identity);
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        if state.registered_authority.is_some() {
            return Err(CommitError::AuthorityAlreadyRegistered);
        }
        state.registered_authority = Some(authority);
        Ok(authority)
    }

    /// Registers the sole resource authority for this canonical domain.
    pub fn register_resource_authority(
        self: &Arc<Self>,
    ) -> Result<CommitResourceAuthority, CommitError> {
        self.register_resource_authority_with_initial_batch(&[])
            .map(|(authority, _)| authority)
    }

    /// Atomically registers the sole resource authority and its initial resources.
    ///
    /// Every identity derivation, validation, uniqueness/capacity check, and
    /// allocation reservation completes under the domain mutex before either
    /// the authority slot or any resource becomes visible. Any error therefore
    /// leaves both collections unchanged and the bootstrap may be retried.
    pub fn register_resource_authority_with_initial_batch(
        self: &Arc<Self>,
        entries: &[(&[u8], u64)],
    ) -> Result<(CommitResourceAuthority, Vec<CommitResourceScope>), CommitError> {
        if entries.len() > MAX_COMMIT_RESOURCES {
            return Err(CommitError::InvalidTransition);
        }
        let mut identity = [0_u8; ID_BYTES];
        getrandom::fill(&mut identity).map_err(|_| CommitError::EntropyUnavailable)?;
        let authority = ResourceAuthorityId(identity);
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;

        let pending_creates = state
            .resource_fences
            .values()
            .filter(|state| **state == ResourceExpectedState::Absent)
            .count();
        if state
            .resources
            .len()
            .checked_add(pending_creates)
            .and_then(|total| total.checked_add(entries.len()))
            .is_none_or(|total| total > MAX_COMMIT_RESOURCES)
        {
            return Err(CommitError::CapacityReached);
        }
        let mut scopes = Vec::new();
        scopes
            .try_reserve_exact(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;
        let mut unique = HashSet::new();
        unique
            .try_reserve(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;
        for (canonical_key, revision) in entries {
            if *revision == 0 {
                return Err(CommitError::InvalidTransition);
            }
            let key = derive_resource_key(canonical_key)?;
            if state.resources.contains_key(&key)
                || state.resource_fences.contains_key(&key)
                || !unique.insert(key)
            {
                return Err(CommitError::InvalidTransition);
            }
            scopes.push(CommitResourceScope {
                key,
                revision: *revision,
                authority,
            });
        }
        if state.registered_resource_authority.is_some() {
            return Err(CommitError::AuthorityAlreadyRegistered);
        }
        state
            .resources
            .try_reserve(entries.len())
            .map_err(|_| CommitError::CapacityReached)?;

        state.registered_resource_authority = Some(authority);
        for scope in &scopes {
            state.resources.insert(
                scope.key,
                CanonicalResourceState {
                    revision: scope.revision,
                    tombstone: false,
                },
            );
        }
        Ok((
            CommitResourceAuthority {
                domain: Arc::clone(self),
                id: authority,
            },
            scopes,
        ))
    }

    pub(crate) fn begin_operation(
        self: &Arc<Self>,
        authority: PermissionAuthorityId,
        session: PermissionSessionScope,
        ttl: Duration,
    ) -> Result<CommitOperation, CommitError> {
        if ttl.is_zero() || ttl > MAX_PRECOMMIT_TTL {
            return Err(CommitError::InvalidTransition);
        }
        let now = Instant::now();
        let expires_at = now.checked_add(ttl).ok_or(CommitError::InvalidTransition)?;
        let mut identity = [0_u8; ID_BYTES];
        getrandom::fill(&mut identity).map_err(|_| CommitError::EntropyUnavailable)?;
        let id = CommitOperationId(identity);
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, now);
        validate_registered_authority(&state, authority)?;
        if state
            .mutation_fences
            .iter()
            .any(|fence| fence_matches_session(fence, authority, session))
        {
            return Err(CommitError::MutationInProgress);
        }
        if state.operations.len() >= MAX_COMMIT_OPERATIONS
            || state
                .operations
                .values()
                .any(|record| record.authority == authority && record.session == session)
        {
            return Err(CommitError::CapacityReached);
        }
        if state.operations.contains_key(&id) {
            return Err(CommitError::EntropyUnavailable);
        }
        state.operations.insert(
            id,
            CommitRecord {
                authority,
                session,
                grants: Vec::new(),
                resource: None,
                state: CommitOperationState::PreCommit,
                expires_at,
            },
        );
        Ok(CommitOperation {
            domain: Arc::clone(self),
            authority,
            session,
            id,
            armed: true,
        })
    }

    /// Returns the retained canonical state for an operation.
    pub fn operation_state(
        &self,
        operation_id: &CommitOperationId,
    ) -> Result<Option<CommitOperationState>, CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        Ok(state
            .operations
            .get(operation_id)
            .map(|record| record.state)
            .or_else(|| {
                state
                    .recent_terminals
                    .iter()
                    .find(|record| record.id == *operation_id)
                    .map(|record| record.state)
            }))
    }

    pub(crate) fn begin_permission_mutation(
        self: &Arc<Self>,
        authority: PermissionAuthorityId,
        scope: PermissionMutationScope,
    ) -> Result<PermissionMutationFence, CommitError> {
        let key = MutationFenceKey { authority, scope };
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        validate_registered_authority(&state, authority)?;
        if state.mutation_fences.len() + state.resource_fences.len()
            >= MAX_PERMISSION_MUTATION_FENCES
        {
            return Err(CommitError::CapacityReached);
        }
        state
            .mutation_fences
            .try_reserve(1)
            .map_err(|_| CommitError::CapacityReached)?;
        let mut cancelled = Vec::new();
        cancelled
            .try_reserve_exact(MAX_COMMIT_OPERATIONS)
            .map_err(|_| CommitError::CapacityReached)?;
        if !state.mutation_fences.insert(key.clone()) {
            return Err(CommitError::MutationInProgress);
        }
        let mut commit_started = false;
        for (id, record) in &state.operations {
            if record_matches_fence(record, &key) {
                match record.state {
                    CommitOperationState::PreCommit => cancelled.push(*id),
                    CommitOperationState::Committing => commit_started = true,
                    CommitOperationState::Committed
                    | CommitOperationState::DurabilityUnknown
                    | CommitOperationState::Cancelled => {}
                }
            }
        }
        for id in cancelled {
            move_to_terminal(&mut state, id, CommitOperationState::Cancelled);
        }
        Ok(PermissionMutationFence {
            domain: Arc::clone(self),
            key,
            outcome: if commit_started {
                CommitMutationOutcome::CommitAlreadyStarted
            } else {
                CommitMutationOutcome::Invalidated
            },
            finished: false,
        })
    }

    fn begin_resource_mutation(
        self: &Arc<Self>,
        authority: ResourceAuthorityId,
        key: CommitResourceKey,
        request: ResourceMutationRequest,
    ) -> Result<CommitResourceMutationFence, CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        validate_resource_authority(&state, authority)?;
        let expected = match (request, state.resources.get(&key).copied()) {
            (ResourceMutationRequest::Absent, None) => ResourceExpectedState::Absent,
            (ResourceMutationRequest::CurrentLive, Some(current)) if !current.tombstone => {
                ResourceExpectedState::Live(current.revision)
            }
            (ResourceMutationRequest::Tombstone(expected), Some(current))
                if current.tombstone && current.revision == expected =>
            {
                ResourceExpectedState::Tombstone(expected)
            }
            _ => return Err(CommitError::InvalidTransition),
        };
        if expected == ResourceExpectedState::Absent {
            let pending_creates = state
                .resource_fences
                .values()
                .filter(|state| **state == ResourceExpectedState::Absent)
                .count();
            if state.resources.len() + pending_creates >= MAX_COMMIT_RESOURCES {
                return Err(CommitError::CapacityReached);
            }
        }
        if state.mutation_fences.len() + state.resource_fences.len()
            >= MAX_PERMISSION_MUTATION_FENCES
        {
            return Err(CommitError::CapacityReached);
        }
        state
            .resource_fences
            .try_reserve(1)
            .map_err(|_| CommitError::CapacityReached)?;
        if state.resource_fences.contains_key(&key) {
            return Err(CommitError::MutationInProgress);
        }
        state.resource_fences.insert(key, expected);
        let mut commit_started = false;
        for record in state.operations.values() {
            if record.resource.is_some_and(|scope| scope.key == key) {
                match record.state {
                    CommitOperationState::Committing => commit_started = true,
                    CommitOperationState::PreCommit
                    | CommitOperationState::Committed
                    | CommitOperationState::DurabilityUnknown
                    | CommitOperationState::Cancelled => {}
                }
            }
        }
        Ok(CommitResourceMutationFence {
            domain: Arc::clone(self),
            authority,
            key,
            expected,
            outcome: if commit_started {
                CommitMutationOutcome::CommitAlreadyStarted
            } else {
                CommitMutationOutcome::Invalidated
            },
            finished: false,
        })
    }

    pub(crate) fn bind_grants(
        &self,
        operation: &CommitOperation,
        grants: &[PermissionGrantScope],
    ) -> Result<(), CommitError> {
        if grants.is_empty() {
            return Err(CommitError::PermissionDenied);
        }
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        validate_registered_authority(&state, operation.authority)?;
        let fenced = state.mutation_fences.iter().any(|fence| {
            fence.authority == operation.authority
                && (matches!(&fence.scope, PermissionMutationScope::Session(session) if *session == operation.session)
                    || matches!(&fence.scope, PermissionMutationScope::Grant { session, grant } if *session == operation.session && grants.contains(grant)))
        });
        if fenced {
            return Err(CommitError::Cancelled);
        }
        let record = state
            .operations
            .get_mut(&operation.id)
            .ok_or(CommitError::Cancelled)?;
        if record.authority != operation.authority
            || record.session != operation.session
            || record.state != CommitOperationState::PreCommit
        {
            return Err(CommitError::Cancelled);
        }
        if !record.grants.is_empty() && record.grants != grants {
            return Err(CommitError::PermissionDenied);
        }
        if record.grants.is_empty() {
            record.grants = grants.to_vec();
        }
        Ok(())
    }

    fn bind_resource(
        &self,
        operation: &CommitOperation,
        resource: CommitResourceScope,
    ) -> Result<(), CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        validate_registered_authority(&state, operation.authority)?;
        validate_resource_authority(&state, resource.authority)?;
        if !resource_is_current(&state, resource) {
            return Err(CommitError::PermissionDenied);
        }
        if state.resource_fences.contains_key(&resource.key) {
            return Err(CommitError::MutationInProgress);
        }
        let record = state
            .operations
            .get_mut(&operation.id)
            .ok_or(CommitError::Cancelled)?;
        if record.authority != operation.authority
            || record.session != operation.session
            || record.state != CommitOperationState::PreCommit
        {
            return Err(CommitError::Cancelled);
        }
        if record.resource.is_some() {
            return Err(CommitError::InvalidTransition);
        }
        record.resource = Some(resource);
        Ok(())
    }

    fn admit(
        &self,
        operation: &CommitOperation,
        resource_required: bool,
    ) -> Result<(), CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        expire_precommit(&mut state, Instant::now());
        validate_registered_authority(&state, operation.authority)?;
        let record = state
            .operations
            .get(&operation.id)
            .ok_or(CommitError::Cancelled)?;
        if record.authority != operation.authority
            || record.session != operation.session
            || record.grants.is_empty()
            || (resource_required && record.resource.is_none())
        {
            return Err(CommitError::PermissionDenied);
        }
        if state
            .mutation_fences
            .iter()
            .any(|fence| record_matches_fence(record, fence))
        {
            return Err(CommitError::MutationInProgress);
        }
        if record
            .resource
            .is_some_and(|resource| state.resource_fences.contains_key(&resource.key))
        {
            return Err(CommitError::MutationInProgress);
        }
        if resource_required
            && !record
                .resource
                .is_some_and(|resource| resource_is_current(&state, resource))
        {
            return Err(CommitError::PermissionDenied);
        }
        let record = state
            .operations
            .get_mut(&operation.id)
            .ok_or(CommitError::Cancelled)?;
        match record.state {
            CommitOperationState::PreCommit => {
                record.state = CommitOperationState::Committing;
                Ok(())
            }
            CommitOperationState::Committing => Err(CommitError::CommitAlreadyStarted),
            CommitOperationState::Cancelled => Err(CommitError::Cancelled),
            CommitOperationState::Committed | CommitOperationState::DurabilityUnknown => {
                Err(CommitError::InvalidTransition)
            }
        }
    }

    fn finish(
        &self,
        authority: PermissionAuthorityId,
        id: CommitOperationId,
        terminal: CommitOperationState,
    ) -> Result<(), CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        validate_registered_authority(&state, authority)?;
        let record = state
            .operations
            .get(&id)
            .ok_or(CommitError::InvalidTransition)?;
        if record.authority != authority
            || record.state != CommitOperationState::Committing
            || !matches!(
                terminal,
                CommitOperationState::Committed | CommitOperationState::DurabilityUnknown
            )
        {
            return Err(CommitError::InvalidTransition);
        }
        if terminal == CommitOperationState::Committed {
            move_to_terminal(&mut state, id, terminal);
        } else if let Some(record) = state.operations.get_mut(&id) {
            record.state = terminal;
        }
        Ok(())
    }

    pub(crate) fn resolve_recovery(
        &self,
        authority: PermissionAuthorityId,
        id: &CommitOperationId,
        resolution: CommitRecoveryResolution,
    ) -> Result<(), CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        validate_registered_authority(&state, authority)?;
        let record = state
            .operations
            .get(id)
            .ok_or(CommitError::InvalidTransition)?;
        if record.authority != authority || record.state != CommitOperationState::DurabilityUnknown
        {
            return Err(CommitError::InvalidTransition);
        }
        let terminal = match resolution {
            CommitRecoveryResolution::Committed => CommitOperationState::Committed,
            CommitRecoveryResolution::DefinitelyAbsent => CommitOperationState::Cancelled,
        };
        move_to_terminal(&mut state, *id, terminal);
        Ok(())
    }

    pub(crate) fn acknowledge_terminal(
        &self,
        authority: PermissionAuthorityId,
        id: &CommitOperationId,
    ) -> Result<(), CommitError> {
        let mut state = self.state.lock().map_err(|_| CommitError::InternalState)?;
        validate_registered_authority(&state, authority)?;
        let position = state
            .recent_terminals
            .iter()
            .position(|record| record.id == *id)
            .ok_or(CommitError::InvalidTransition)?;
        if state.recent_terminals[position].authority != authority {
            return Err(CommitError::InvalidTransition);
        }
        state.recent_terminals.remove(position);
        Ok(())
    }

    fn cancel_precommit(&self, operation: &CommitOperation) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        if let Some(record) = state.operations.get(&operation.id)
            && record.authority == operation.authority
            && record.session == operation.session
            && record.state == CommitOperationState::PreCommit
        {
            move_to_terminal(&mut state, operation.id, CommitOperationState::Cancelled);
        }
    }

    #[cfg(test)]
    pub(crate) fn poison_for_test(self: &Arc<Self>) {
        let poisoned = Arc::clone(self);
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            let _guard = poisoned.state.lock().expect("lock");
            panic!("poison commit domain");
        }));
    }
}

impl fmt::Debug for CommitDomain {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitDomain([HOST-OWNED])")
    }
}

fn validate_registered_authority(
    state: &CommitDomainState,
    authority: PermissionAuthorityId,
) -> Result<(), CommitError> {
    if state.registered_authority == Some(authority) {
        Ok(())
    } else {
        Err(CommitError::WrongDomain)
    }
}

fn validate_resource_authority(
    state: &CommitDomainState,
    authority: ResourceAuthorityId,
) -> Result<(), CommitError> {
    if state.registered_resource_authority == Some(authority) {
        Ok(())
    } else {
        Err(CommitError::WrongDomain)
    }
}

fn derive_resource_key(canonical_key: &[u8]) -> Result<CommitResourceKey, CommitError> {
    if canonical_key.is_empty() || canonical_key.len() > MAX_COMMIT_RESOURCE_KEY_BYTES {
        return Err(CommitError::InvalidTransition);
    }
    let digest = Sha256::digest(canonical_key);
    let mut bytes = [0_u8; ID_BYTES];
    bytes.copy_from_slice(&digest);
    Ok(CommitResourceKey(bytes))
}

fn resource_is_current(state: &CommitDomainState, scope: CommitResourceScope) -> bool {
    state.resources.get(&scope.key).is_some_and(|current| {
        !current.tombstone
            && current.revision == scope.revision
            && state.registered_resource_authority == Some(scope.authority)
    })
}

fn expire_precommit(state: &mut CommitDomainState, now: Instant) {
    let expired = state
        .operations
        .iter()
        .filter_map(|(id, record)| {
            (record.state == CommitOperationState::PreCommit && now >= record.expires_at)
                .then_some(*id)
        })
        .collect::<Vec<_>>();
    for id in expired {
        move_to_terminal(state, id, CommitOperationState::Cancelled);
    }
}

fn move_to_terminal(
    state: &mut CommitDomainState,
    id: CommitOperationId,
    terminal: CommitOperationState,
) {
    let Some(record) = state.operations.remove(&id) else {
        return;
    };
    if state.recent_terminals.len() == MAX_RECENT_COMMIT_TERMINALS {
        state.recent_terminals.pop_front();
    }
    state.recent_terminals.push_back(TerminalRecord {
        id,
        authority: record.authority,
        state: terminal,
    });
}

fn record_matches_fence(record: &CommitRecord, fence: &MutationFenceKey) -> bool {
    if record.authority != fence.authority {
        return false;
    }
    match &fence.scope {
        PermissionMutationScope::Session(session) => record.session == *session,
        PermissionMutationScope::Grant { session, grant } => {
            record.session == *session
                && (record.grants.is_empty() || record.grants.contains(grant))
        }
    }
}

fn fence_matches_session(
    fence: &MutationFenceKey,
    authority: PermissionAuthorityId,
    session: PermissionSessionScope,
) -> bool {
    if fence.authority != authority {
        return false;
    }
    match &fence.scope {
        PermissionMutationScope::Session(owner)
        | PermissionMutationScope::Grant { session: owner, .. } => *owner == session,
    }
}

/// Move-only pre-commit operation owned by trusted host coordination.
pub struct CommitOperation {
    domain: Arc<CommitDomain>,
    authority: PermissionAuthorityId,
    session: PermissionSessionScope,
    id: CommitOperationId,
    armed: bool,
}

impl CommitOperation {
    /// Returns the opaque operation identity for host correlation and recovery.
    #[must_use]
    pub fn id(&self) -> CommitOperationId {
        self.id
    }

    pub(crate) fn belongs_to(
        &self,
        domain: &Arc<CommitDomain>,
        authority: PermissionAuthorityId,
        session: PermissionSessionScope,
    ) -> bool {
        Arc::ptr_eq(&self.domain, domain) && self.authority == authority && self.session == session
    }

    pub(crate) fn bind_grants(&self, grants: &[PermissionGrantScope]) -> Result<(), CommitError> {
        self.domain.bind_grants(self, grants)
    }

    pub(crate) fn bind_resource(&self, resource: CommitResourceScope) -> Result<(), CommitError> {
        self.domain.bind_resource(self, resource)
    }

    pub(crate) fn admit(mut self) -> Result<CommitPermit, CommitError> {
        self.domain.admit(&self, false)?;
        self.armed = false;
        Ok(CommitPermit {
            domain: Arc::clone(&self.domain),
            authority: self.authority,
            id: self.id,
            finished: false,
        })
    }

    pub(crate) fn admit_full(mut self) -> Result<CommitPermit, CommitError> {
        self.domain.admit(&self, true)?;
        self.armed = false;
        Ok(CommitPermit {
            domain: Arc::clone(&self.domain),
            authority: self.authority,
            id: self.id,
            finished: false,
        })
    }
}

impl fmt::Debug for CommitOperation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommitOperation")
            .field("id", &self.id)
            .field("authority", &"[BOUND]")
            .finish()
    }
}

impl Drop for CommitOperation {
    fn drop(&mut self) {
        if self.armed {
            self.domain.cancel_precommit(self);
        }
    }
}

pub(crate) struct PermissionMutationFence {
    domain: Arc<CommitDomain>,
    key: MutationFenceKey,
    outcome: CommitMutationOutcome,
    finished: bool,
}

impl PermissionMutationFence {
    pub(crate) fn finish(mut self) -> Result<CommitMutationOutcome, CommitError> {
        let mut state = self
            .domain
            .state
            .lock()
            .map_err(|_| CommitError::InternalState)?;
        if !state.mutation_fences.remove(&self.key) {
            return Err(CommitError::InvalidTransition);
        }
        self.finished = true;
        Ok(self.outcome)
    }
}

impl Drop for PermissionMutationFence {
    fn drop(&mut self) {
        // An unfinished mutation deliberately leaves its fence installed. This
        // prevents admission after a poisoned or otherwise uncertain WRITE.
        let _ = self.finished;
    }
}

/// Move-only resource mutation fence owned by a trusted host registry.
pub struct CommitResourceMutationFence {
    domain: Arc<CommitDomain>,
    authority: ResourceAuthorityId,
    key: CommitResourceKey,
    expected: ResourceExpectedState,
    outcome: CommitMutationOutcome,
    finished: bool,
}

impl CommitResourceMutationFence {
    /// Returns the opaque canonical resource key fenced by this mutation.
    #[must_use]
    pub fn key(&self) -> CommitResourceKey {
        self.key
    }

    /// Atomically publishes a newer live revision and releases the fence.
    pub fn finish_updated(self, new_revision: u64) -> Result<CommitMutationOutcome, CommitError> {
        self.finish(Some((new_revision, false)))
    }

    /// Atomically publishes a newer tombstone revision and releases the fence.
    pub fn finish_removed(
        self,
        tombstone_revision: u64,
    ) -> Result<CommitMutationOutcome, CommitError> {
        self.finish(Some((tombstone_revision, true)))
    }

    /// Releases a clean mutation miss without changing canonical state.
    pub fn abort(self) -> Result<CommitMutationOutcome, CommitError> {
        self.finish(None)
    }

    fn finish(
        mut self,
        replacement: Option<(u64, bool)>,
    ) -> Result<CommitMutationOutcome, CommitError> {
        let mut state = self
            .domain
            .state
            .lock()
            .map_err(|_| CommitError::InternalState)?;
        validate_resource_authority(&state, self.authority)?;
        let actual = match state.resources.get(&self.key).copied() {
            None => ResourceExpectedState::Absent,
            Some(current) if current.tombstone => {
                ResourceExpectedState::Tombstone(current.revision)
            }
            Some(current) => ResourceExpectedState::Live(current.revision),
        };
        if actual != self.expected || state.resource_fences.get(&self.key) != Some(&self.expected) {
            return Err(CommitError::InvalidTransition);
        }
        let expected_revision = match self.expected {
            ResourceExpectedState::Absent => 0,
            ResourceExpectedState::Live(revision) | ResourceExpectedState::Tombstone(revision) => {
                revision
            }
        };
        let clean_invalid = replacement.is_some_and(|(revision, tombstone)| {
            revision == 0
                || revision <= expected_revision
                || (!matches!(self.expected, ResourceExpectedState::Live(_)) && tombstone)
        });
        if clean_invalid {
            state.resource_fences.remove(&self.key);
            self.finished = true;
            return Err(CommitError::InvalidTransition);
        }
        if let Some((revision, tombstone)) = replacement {
            if self.expected == ResourceExpectedState::Absent {
                if state.resources.len() >= MAX_COMMIT_RESOURCES {
                    return Err(CommitError::CapacityReached);
                }
                state
                    .resources
                    .try_reserve(1)
                    .map_err(|_| CommitError::CapacityReached)?;
            }
            let mut cancelled = Vec::new();
            cancelled
                .try_reserve_exact(MAX_COMMIT_OPERATIONS)
                .map_err(|_| CommitError::CapacityReached)?;
            cancelled.extend(state.operations.iter().filter_map(|(id, record)| {
                (record.state == CommitOperationState::PreCommit
                    && record.resource.is_some_and(|scope| scope.key == self.key))
                .then_some(*id)
            }));
            for id in cancelled {
                move_to_terminal(&mut state, id, CommitOperationState::Cancelled);
            }
            state.resources.insert(
                self.key,
                CanonicalResourceState {
                    revision,
                    tombstone,
                },
            );
        }
        state.resource_fences.remove(&self.key);
        self.finished = true;
        Ok(self.outcome)
    }
}

impl fmt::Debug for CommitResourceMutationFence {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitResourceMutationFence([HOST-OWNED])")
    }
}

impl Drop for CommitResourceMutationFence {
    fn drop(&mut self) {
        // An unfinished mutation keeps the exact key fenced after an uncertain
        // registry update. This is bounded by MAX_PERMISSION_MUTATION_FENCES.
        let _ = self.finished;
    }
}

/// Admission proof held across physical commit without retaining a host lock.
pub struct CommitPermit {
    domain: Arc<CommitDomain>,
    authority: PermissionAuthorityId,
    id: CommitOperationId,
    finished: bool,
}

impl CommitPermit {
    /// Returns the opaque operation identity admitted for physical commit.
    #[must_use]
    pub fn operation_id(&self) -> CommitOperationId {
        self.id
    }

    /// Records a proven successful physical commit.
    ///
    /// A bookkeeping failure is reported distinctly and MUST NOT be retried.
    pub fn mark_committed(mut self) -> Result<(), CommitError> {
        let result = self
            .domain
            .finish(self.authority, self.id, CommitOperationState::Committed);
        self.finished = true;
        result.map_err(|_| CommitError::DurableSuccessBookkeepingUnavailable)
    }

    /// Records an admitted commit whose durability cannot be proven.
    pub(crate) fn mark_durability_unknown(mut self) -> Result<CommitRecoveryHandle, CommitError> {
        self.domain.finish(
            self.authority,
            self.id,
            CommitOperationState::DurabilityUnknown,
        )?;
        self.finished = true;
        Ok(CommitRecoveryHandle {
            domain: Arc::clone(&self.domain),
            authority: self.authority,
            id: self.id,
        })
    }
}

impl fmt::Debug for CommitPermit {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CommitPermit")
            .field("operation_id", &self.id)
            .field("state", &"[COMMITTING]")
            .finish()
    }
}

impl Drop for CommitPermit {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.domain.finish(
                self.authority,
                self.id,
                CommitOperationState::DurabilityUnknown,
            );
        }
    }
}

/// Canonical authority for resolving one durability-unknown commit.
///
/// This value is crate-private so only a typed public permit can expose the
/// corresponding recovery capability. It deliberately has no `Clone` or serde
/// implementation.
pub(crate) struct CommitRecoveryHandle {
    domain: Arc<CommitDomain>,
    authority: PermissionAuthorityId,
    id: CommitOperationId,
}

impl CommitRecoveryHandle {
    pub(crate) fn resolve(self, resolution: CommitRecoveryResolution) -> Result<(), CommitError> {
        self.domain
            .resolve_recovery(self.authority, &self.id, resolution)
    }
}

impl fmt::Debug for CommitRecoveryHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("CommitRecoveryHandle([REDACTED])")
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::Barrier, thread, time::Duration};

    use super::*;

    fn authority(domain: &Arc<CommitDomain>) -> PermissionAuthorityId {
        domain.register_permission_authority().expect("authority")
    }

    fn session(value: u8) -> PermissionSessionScope {
        PermissionSessionScope::from_hash([value; ID_BYTES])
    }

    fn grant(value: u8) -> PermissionGrantScope {
        PermissionGrantScope::from_hash([value; ID_BYTES], u64::from(value))
    }

    fn resource(
        authority: &CommitResourceAuthority,
        value: u8,
        revision: u64,
    ) -> CommitResourceScope {
        authority
            .register_initial(&[value], revision)
            .expect("resource scope")
    }

    #[test]
    fn mutation_fence_cancels_matching_and_blocks_window() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        let operation = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        operation.bind_grants(&[grant(1)]).expect("bind");
        let fence = domain
            .begin_permission_mutation(
                authority,
                PermissionMutationScope::Grant {
                    session: session(1),
                    grant: grant(1),
                },
            )
            .expect("fence");
        assert_eq!(operation.admit().err(), Some(CommitError::Cancelled));
        assert_eq!(
            domain
                .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::MutationInProgress)
        );
        let unrelated = domain
            .begin_operation(authority, session(2), MAX_PRECOMMIT_TTL)
            .expect("unrelated session is not fenced");
        assert_eq!(
            fence.finish().expect("finish mutation"),
            CommitMutationOutcome::Invalidated
        );
        drop(unrelated);
    }

    #[test]
    fn terminal_and_unknown_require_explicit_resolution_and_ack() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        let operation = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        let id = operation.id();
        operation.bind_grants(&[grant(1)]).expect("bind");
        let recovery = operation
            .admit()
            .expect("permit")
            .mark_durability_unknown()
            .expect("unknown");
        assert_eq!(
            domain
                .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::CapacityReached)
        );
        assert_eq!(
            domain.acknowledge_terminal(authority, &id),
            Err(CommitError::InvalidTransition)
        );
        recovery
            .resolve(CommitRecoveryResolution::Committed)
            .expect("resolve");
        domain.acknowledge_terminal(authority, &id).expect("ack");
        assert_eq!(domain.operation_state(&id), Ok(None));
    }

    #[test]
    fn ttl_and_principal_cap_fail_closed() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        assert_eq!(
            domain
                .begin_operation(authority, session(1), Duration::ZERO)
                .err(),
            Some(CommitError::InvalidTransition)
        );
        let operation = domain
            .begin_operation(authority, session(1), Duration::from_millis(1))
            .expect("operation");
        let id = operation.id();
        assert_eq!(
            domain
                .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::CapacityReached)
        );
        thread::sleep(Duration::from_millis(2));
        assert_eq!(
            domain.operation_state(&id),
            Ok(Some(CommitOperationState::Cancelled))
        );
        let replacement = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("expired terminal does not consume active principal capacity");
        drop(replacement);
        domain
            .acknowledge_terminal(authority, &id)
            .expect("ack expired");
    }

    #[test]
    fn second_authority_and_postcommit_poison_fail_distinctly() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        assert_eq!(
            domain.register_permission_authority().err(),
            Some(CommitError::AuthorityAlreadyRegistered)
        );
        let operation = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        operation.bind_grants(&[grant(1)]).expect("bind");
        let permit = operation.admit().expect("permit");
        domain.poison_for_test();
        assert_eq!(
            permit.mark_committed(),
            Err(CommitError::DurableSuccessBookkeepingUnavailable)
        );
    }

    #[test]
    fn authority_registration_is_atomic_and_global_capacity_is_bounded() {
        let domain = CommitDomain::isolated_for_test();
        let barrier = Arc::new(std::sync::Barrier::new(3));
        let mut registrations = Vec::new();
        for _ in 0..2 {
            let domain = Arc::clone(&domain);
            let barrier = Arc::clone(&barrier);
            registrations.push(thread::spawn(move || {
                barrier.wait();
                domain.register_permission_authority()
            }));
        }
        barrier.wait();
        let results = registrations
            .into_iter()
            .map(|thread| thread.join().expect("registration thread"))
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        let authority = results.into_iter().find_map(Result::ok).expect("winner");

        let operations = (0..MAX_COMMIT_OPERATIONS)
            .map(|value| {
                let byte = u8::try_from(value + 1).expect("capacity fits scope byte");
                domain
                    .begin_operation(authority, session(byte), MAX_PRECOMMIT_TTL)
                    .expect("within global capacity")
            })
            .collect::<Vec<_>>();
        assert_eq!(
            domain
                .begin_operation(authority, session(255), MAX_PRECOMMIT_TTL)
                .err(),
            Some(CommitError::CapacityReached)
        );
        drop(operations);
        let replacement = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("cancelled terminals do not consume active capacity");
        drop(replacement);
    }

    #[test]
    fn resource_scope_is_validated_redacted_and_bound_once() {
        let domain = CommitDomain::isolated_for_test();
        let permission = authority(&domain);
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        assert_eq!(
            resources.register_initial(&[], 1),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources.register_initial(&[7], 0),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources.register_initial(&vec![7; MAX_COMMIT_RESOURCE_KEY_BYTES + 1], 1),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            domain.register_resource_authority().err(),
            Some(CommitError::AuthorityAlreadyRegistered)
        );
        let scope = resource(&resources, 7, 1);
        let second = resource(&resources, 8, 1);
        let key = scope.key();
        assert!(!format!("{key:?}").contains("0707"));
        let operation = domain
            .begin_operation(permission, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        operation.bind_grants(&[grant(1)]).expect("grants");
        operation.bind_resource(scope).expect("resource");
        assert_eq!(
            operation.bind_resource(second),
            Err(CommitError::InvalidTransition)
        );

        let detached = CommitDomain::isolated_for_test();
        let detached_permission = authority(&detached);
        let detached_operation = detached
            .begin_operation(detached_permission, session(2), MAX_PRECOMMIT_TTL)
            .expect("detached operation");
        detached_operation
            .bind_grants(&[grant(2)])
            .expect("detached grants");
        assert_eq!(
            detached_operation.bind_resource(scope),
            Err(CommitError::WrongDomain)
        );
    }

    #[test]
    fn resource_mutation_is_exact_and_linearizes_against_admission() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        let scope_a = resource(&resources, 1, 1);
        let scope_b = resource(&resources, 2, 1);
        let operation_a = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("A");
        operation_a.bind_grants(&[grant(1)]).expect("A grants");
        operation_a.bind_resource(scope_a).expect("A resource");
        let operation_b = domain
            .begin_operation(authority, session(2), MAX_PRECOMMIT_TTL)
            .expect("B");
        operation_b.bind_grants(&[grant(2)]).expect("B grants");
        operation_b.bind_resource(scope_b).expect("B resource");
        let unbound = domain
            .begin_operation(authority, session(3), MAX_PRECOMMIT_TTL)
            .expect("unbound");
        unbound.bind_grants(&[grant(3)]).expect("unbound grants");

        let fence = resources
            .begin_mutation(scope_a.key())
            .expect("resource fence");
        let fenced = domain
            .begin_operation(authority, session(4), MAX_PRECOMMIT_TTL)
            .expect("fenced operation");
        fenced.bind_grants(&[grant(4)]).expect("fenced grants");
        assert_eq!(
            fenced.bind_resource(scope_a),
            Err(CommitError::MutationInProgress)
        );
        assert_eq!(
            fence.finish_updated(2).expect("finish"),
            CommitMutationOutcome::Invalidated
        );
        assert_eq!(operation_a.admit_full().err(), Some(CommitError::Cancelled));
        operation_b
            .admit_full()
            .expect("B unaffected")
            .mark_committed()
            .expect("B committed");
        unbound
            .admit()
            .expect("unbound permission-only seam unaffected")
            .mark_committed()
            .expect("unbound committed");
    }

    #[test]
    fn unknown_resource_does_not_invalidate_and_cas_wins_late_mutation() {
        let domain = CommitDomain::isolated_for_test();
        let authority = authority(&domain);
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        let known = resource(&resources, 1, 1);
        let operation = domain
            .begin_operation(authority, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        operation.bind_grants(&[grant(1)]).expect("grants");
        operation.bind_resource(known).expect("resource");
        assert_eq!(
            resources
                .begin_mutation(CommitResourceKey([9; ID_BYTES]))
                .err(),
            Some(CommitError::InvalidTransition)
        );
        resources
            .begin_mutation(known.key())
            .expect("clean same-key fence")
            .abort()
            .expect("clean abort");
        let permit = operation
            .admit_full()
            .expect("known resource remains current");

        let late = resources.begin_mutation(known.key()).expect("late update");
        assert_eq!(
            late.finish_updated(2).expect("finish late update"),
            CommitMutationOutcome::CommitAlreadyStarted
        );
        permit.mark_committed().expect("CAS already won");
    }

    #[test]
    fn completed_update_and_tombstone_reject_stale_scopes() {
        let domain = CommitDomain::isolated_for_test();
        let permission = authority(&domain);
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        let first = resource(&resources, 1, 1);
        let operation = domain
            .begin_operation(permission, session(1), MAX_PRECOMMIT_TTL)
            .expect("operation");
        operation.bind_grants(&[grant(1)]).expect("grants");
        operation.bind_resource(first).expect("R1 binding");
        resources
            .begin_mutation(first.key())
            .expect("R1 update")
            .finish_updated(2)
            .expect("publish R2");
        assert_eq!(operation.admit_full().err(), Some(CommitError::Cancelled));

        let second = resources
            .current_scope(first.key())
            .expect("current")
            .expect("R2");
        assert_eq!(second.revision(), 2);
        resources
            .begin_mutation(first.key())
            .expect("remove")
            .finish_removed(3)
            .expect("tombstone");
        assert_eq!(resources.current_scope(first.key()), Ok(None));
        assert_eq!(
            resources.register_initial(&[1], 4),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources.begin_recreate(first.key(), 2).err(),
            Some(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources
                .begin_recreate(first.key(), 3)
                .expect("invalid recreate")
                .finish_updated(3),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources
                .begin_recreate(first.key(), 3)
                .expect("invalid remove of tombstone")
                .finish_removed(4),
            Err(CommitError::InvalidTransition)
        );
        resources
            .begin_recreate(first.key(), 3)
            .expect("recreate")
            .finish_updated(4)
            .expect("publish recreated R4");
        assert_eq!(
            resources
                .current_scope(first.key())
                .expect("current")
                .expect("recreated")
                .revision(),
            4
        );

        let stale = domain
            .begin_operation(permission, session(2), MAX_PRECOMMIT_TTL)
            .expect("stale operation");
        stale.bind_grants(&[grant(2)]).expect("stale grants");
        assert_eq!(
            stale.bind_resource(second),
            Err(CommitError::PermissionDenied)
        );
    }

    #[test]
    fn canonical_resource_registry_is_hard_bounded() {
        let domain = CommitDomain::isolated_for_test();
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        for value in 0..MAX_COMMIT_RESOURCES {
            resources
                .register_initial(&value.to_le_bytes(), 1)
                .expect("within resource capacity");
        }
        assert_eq!(
            resources.register_initial(b"over-capacity", 1),
            Err(CommitError::CapacityReached)
        );
        assert_eq!(
            resources.begin_create(b"over-capacity").err(),
            Some(CommitError::CapacityReached)
        );
    }

    #[test]
    fn invalid_resource_revision_is_clean_and_does_not_leak_fence_capacity() {
        let domain = CommitDomain::isolated_for_test();
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        let scope = resource(&resources, 1, 5);
        for _ in 0..=MAX_PERMISSION_MUTATION_FENCES {
            assert_eq!(
                resources
                    .begin_mutation(scope.key())
                    .expect("fence remains available")
                    .finish_updated(5),
                Err(CommitError::InvalidTransition)
            );
        }
        assert_eq!(
            resources
                .begin_mutation(scope.key())
                .expect("lower revision fence")
                .finish_removed(4),
            Err(CommitError::InvalidTransition)
        );
        resources
            .begin_mutation(scope.key())
            .expect("final clean fence")
            .abort()
            .expect("abort");
        assert_eq!(resources.current_scope(scope.key()), Ok(Some(scope)));
    }

    #[test]
    fn initial_batch_is_atomic_on_validation_and_duplicate_failure() {
        let domain = CommitDomain::isolated_for_test();
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        assert_eq!(
            resources.register_initial_batch(&[(b"batch-a", 1), (b"batch-b", 0)]),
            Err(CommitError::InvalidTransition)
        );
        resources
            .register_initial(b"batch-a", 1)
            .expect("failed batch inserted nothing");
        assert_eq!(
            resources.register_initial_batch(&[(b"duplicate", 1), (b"duplicate", 2)]),
            Err(CommitError::InvalidTransition)
        );
        resources
            .register_initial(b"duplicate", 1)
            .expect("duplicate batch inserted nothing");
        let scopes = resources
            .register_initial_batch(&[(b"batch-c", 3), (b"batch-d", 4)])
            .expect("valid batch");
        assert_eq!(scopes.len(), 2);
        assert_eq!(scopes[0].revision(), 3);
        assert_eq!(scopes[1].revision(), 4);
    }

    #[test]
    fn authority_bootstrap_batch_failure_is_zero_change_and_retryable() {
        let domain = CommitDomain::isolated_for_test();
        assert!(matches!(
            domain.register_resource_authority_with_initial_batch(&[
                (b"bootstrap-a", 1),
                (b"bootstrap-invalid", 0),
            ]),
            Err(CommitError::InvalidTransition)
        ));
        {
            let state = domain.state.lock().expect("domain state");
            assert!(state.registered_resource_authority.is_none());
            assert!(state.resources.is_empty());
        }

        let (authority, scopes) = domain
            .register_resource_authority_with_initial_batch(&[
                (b"bootstrap-a", 1),
                (b"bootstrap-b", 2),
            ])
            .expect("retry succeeds atomically");
        assert_eq!(scopes.len(), 2);
        assert_eq!(
            authority.current_scope(scopes[0].key()),
            Ok(Some(scopes[0]))
        );
        assert_eq!(
            authority.current_scope(scopes[1].key()),
            Ok(Some(scopes[1]))
        );
    }

    #[test]
    fn concurrent_authority_bootstrap_has_exactly_one_winner() {
        let domain = CommitDomain::isolated_for_test();
        let barrier = Arc::new(Barrier::new(3));
        let workers = [b"concurrent-a".as_slice(), b"concurrent-b".as_slice()]
            .into_iter()
            .map(|key| {
                let domain = Arc::clone(&domain);
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || {
                    barrier.wait();
                    domain.register_resource_authority_with_initial_batch(&[(key, 1)])
                })
            })
            .collect::<Vec<_>>();
        barrier.wait();
        let results = workers
            .into_iter()
            .map(|worker| worker.join().expect("bootstrap worker"))
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, Err(CommitError::AuthorityAlreadyRegistered)))
                .count(),
            1
        );
        let state = domain.state.lock().expect("domain state");
        assert!(state.registered_resource_authority.is_some());
        assert_eq!(state.resources.len(), 1);
    }

    #[test]
    fn absent_create_is_atomic_abortable_and_does_not_affect_other_keys() {
        let domain = CommitDomain::isolated_for_test();
        let permission = authority(&domain);
        let resources = domain
            .register_resource_authority()
            .expect("resource authority");
        let other = resource(&resources, 2, 1);
        let create = resources.begin_create(b"created-a").expect("create fence");
        let created_key = create.key();
        assert_eq!(resources.current_scope(created_key), Ok(None));
        assert_eq!(
            resources.register_initial(b"created-a", 1),
            Err(CommitError::InvalidTransition)
        );
        assert_eq!(
            resources.begin_create(b"created-a").err(),
            Some(CommitError::MutationInProgress)
        );

        let unknown = domain
            .begin_operation(permission, session(1), MAX_PRECOMMIT_TTL)
            .expect("unknown operation");
        unknown.bind_grants(&[grant(1)]).expect("unknown grants");
        let unavailable_scope = CommitResourceScope {
            key: created_key,
            revision: 1,
            authority: resources.id,
        };
        assert_eq!(
            unknown.bind_resource(unavailable_scope),
            Err(CommitError::PermissionDenied)
        );

        let unrelated = domain
            .begin_operation(permission, session(2), MAX_PRECOMMIT_TTL)
            .expect("unrelated operation");
        unrelated
            .bind_grants(&[grant(2)])
            .expect("unrelated grants");
        unrelated.bind_resource(other).expect("unrelated resource");
        unrelated
            .admit_full()
            .expect("other key is unaffected")
            .mark_committed()
            .expect("other commit");
        create.abort().expect("abort create");
        assert_eq!(resources.current_scope(created_key), Ok(None));

        assert_eq!(
            resources
                .begin_create(b"created-a")
                .expect("invalid create")
                .finish_updated(0),
            Err(CommitError::InvalidTransition)
        );
        let create = resources.begin_create(b"created-a").expect("retry create");
        assert_eq!(
            create.finish_updated(1).expect("publish create"),
            CommitMutationOutcome::Invalidated
        );
        assert_eq!(
            resources
                .current_scope(created_key)
                .expect("current")
                .expect("created")
                .revision(),
            1
        );
        assert_eq!(
            resources.begin_create(b"created-a").err(),
            Some(CommitError::InvalidTransition)
        );
    }
}
