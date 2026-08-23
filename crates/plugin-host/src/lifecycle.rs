//! Deterministic, transport-neutral plugin lifecycle state machine.

use std::{
    collections::BTreeMap,
    sync::{Arc, RwLock},
};

use thiserror::Error;
use timetrace_plugin_api::{
    DesiredPluginState, LifecycleFailure, LifecycleSnapshot, PluginErrorCode, PluginId,
    PluginRuntimeState, TimestampMillis,
};

use crate::PluginCatalog;

/// Consecutive activation failures required to enter plugin-local safe mode.
pub const SAFE_MODE_FAILURE_THRESHOLD: u32 = 3;

/// The only lifecycle state that may be persisted across host restarts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PersistedLifecycleState {
    desired_state: DesiredPluginState,
    consecutive_start_failures: u32,
}

impl PersistedLifecycleState {
    /// Creates a persisted lifecycle record without transient runtime state.
    #[must_use]
    pub fn new(desired_state: DesiredPluginState, consecutive_start_failures: u32) -> Self {
        Self {
            desired_state,
            consecutive_start_failures,
        }
    }

    /// Returns the persisted desired state.
    #[must_use]
    pub fn desired_state(self) -> DesiredPluginState {
        self.desired_state
    }

    /// Returns the persisted consecutive activation failure count.
    #[must_use]
    pub fn consecutive_start_failures(self) -> u32 {
        self.consecutive_start_failures
    }

    /// Returns whether the persisted failure count requires safe mode.
    #[must_use]
    pub fn is_safe_mode(self) -> bool {
        self.consecutive_start_failures >= SAFE_MODE_FAILURE_THRESHOLD
    }
}

impl Default for PersistedLifecycleState {
    fn default() -> Self {
        Self::new(DesiredPluginState::Disabled, 0)
    }
}

/// Persistence boundary for desired state and minimal crash accounting.
///
/// Implementations must not persist transient runtime states, generations, or
/// operation deadlines.
pub trait LifecycleStateStore: Send + Sync {
    /// Loads one plugin's persisted lifecycle record.
    fn load(
        &self,
        plugin_id: &PluginId,
    ) -> Result<Option<PersistedLifecycleState>, LifecycleStoreError>;

    /// Atomically saves one plugin's persisted lifecycle record.
    fn save(
        &self,
        plugin_id: &PluginId,
        state: PersistedLifecycleState,
    ) -> Result<(), LifecycleStoreError>;
}

/// Stable failures returned by lifecycle persistence adapters.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum LifecycleStoreError {
    /// The persistence adapter is temporarily unavailable.
    #[error("plugin lifecycle state store is unavailable")]
    Unavailable,
}

/// Thread-safe in-memory lifecycle store intended for tests and host previews.
#[derive(Debug, Clone, Default)]
pub struct InMemoryLifecycleStateStore {
    values: Arc<RwLock<BTreeMap<PluginId, PersistedLifecycleState>>>,
}

impl InMemoryLifecycleStateStore {
    /// Creates an empty in-memory lifecycle store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Seeds one persisted record for a restart or migration test.
    pub fn seed(
        &self,
        plugin_id: PluginId,
        state: PersistedLifecycleState,
    ) -> Result<(), LifecycleStoreError> {
        self.save(&plugin_id, state)
    }

    /// Returns a copied record for test assertions.
    pub fn get(
        &self,
        plugin_id: &PluginId,
    ) -> Result<Option<PersistedLifecycleState>, LifecycleStoreError> {
        self.load(plugin_id)
    }
}

impl LifecycleStateStore for InMemoryLifecycleStateStore {
    fn load(
        &self,
        plugin_id: &PluginId,
    ) -> Result<Option<PersistedLifecycleState>, LifecycleStoreError> {
        self.values
            .read()
            .map_err(|_| LifecycleStoreError::Unavailable)
            .map(|values| values.get(plugin_id).copied())
    }

    fn save(
        &self,
        plugin_id: &PluginId,
        state: PersistedLifecycleState,
    ) -> Result<(), LifecycleStoreError> {
        self.values
            .write()
            .map_err(|_| LifecycleStoreError::Unavailable)?
            .insert(plugin_id.clone(), state);
        Ok(())
    }
}

/// External lifecycle work requested by the pure host state machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LifecycleWork {
    /// Start the bundled or future isolated plugin runtime.
    Start {
        /// Plugin to start.
        plugin_id: PluginId,
        /// Generation that must accompany the completion.
        generation: u64,
        /// Absolute host deadline for the operation.
        deadline: TimestampMillis,
    },
    /// Stop and dispose the plugin runtime.
    Stop {
        /// Plugin to stop.
        plugin_id: PluginId,
        /// Generation that must accompany the completion.
        generation: u64,
        /// Absolute host deadline for the operation.
        deadline: TimestampMillis,
    },
    /// Cancel an activation and dispose any runtime that it may have created.
    CancelAndDisposeStart {
        /// Plugin whose activation must be cancelled and disposed.
        plugin_id: PluginId,
        /// Start generation to cancel and dispose exactly once.
        generation: u64,
    },
}

/// Snapshot and optional external work produced by a lifecycle command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LifecycleDecision {
    snapshot: LifecycleSnapshot,
    work: Option<LifecycleWork>,
}

impl LifecycleDecision {
    /// Returns the immutable state after applying the command.
    #[must_use]
    pub fn snapshot(&self) -> &LifecycleSnapshot {
        &self.snapshot
    }

    /// Returns external work only when a new transition was admitted.
    #[must_use]
    pub fn work(&self) -> Option<&LifecycleWork> {
        self.work.as_ref()
    }

    /// Consumes the decision and returns its optional external work.
    #[must_use]
    pub fn into_work(self) -> Option<LifecycleWork> {
        self.work
    }
}

/// Result reported by the external plugin engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleCompletion {
    /// The requested transition completed successfully.
    Succeeded,
    /// The requested transition failed with a stable, non-sensitive code.
    Failed {
        /// Stable failure class.
        code: PluginErrorCode,
        /// Whether retry may succeed without a configuration change.
        retryable: bool,
    },
}

/// Whether a completion changed state or was suppressed as stale.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LifecycleCompletionResult {
    snapshot: LifecycleSnapshot,
    applied: bool,
    work: Option<LifecycleWork>,
}

impl LifecycleCompletionResult {
    /// Returns the immutable state after considering the completion.
    #[must_use]
    pub fn snapshot(&self) -> &LifecycleSnapshot {
        &self.snapshot
    }

    /// Returns false when generation or runtime state made the result stale.
    #[must_use]
    pub fn was_applied(&self) -> bool {
        self.applied
    }

    /// Returns fail-closed cleanup work produced while applying the completion.
    #[must_use]
    pub fn work(&self) -> Option<&LifecycleWork> {
        self.work.as_ref()
    }

    /// Consumes the result and returns its optional fail-closed cleanup work.
    #[must_use]
    pub fn into_work(self) -> Option<LifecycleWork> {
        self.work
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PendingKind {
    Start,
    Stop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingTransition {
    kind: PendingKind,
    generation: u64,
    deadline: TimestampMillis,
}

#[derive(Debug)]
struct LifecycleEntry {
    plugin_id: PluginId,
    desired_state: DesiredPluginState,
    runtime_state: PluginRuntimeState,
    compatible: bool,
    grants_satisfied: bool,
    generation: u64,
    updated_at: TimestampMillis,
    failure: Option<LifecycleFailure>,
    consecutive_start_failures: u32,
    pending: Option<PendingTransition>,
}

impl LifecycleEntry {
    fn is_safe_mode(&self) -> bool {
        self.consecutive_start_failures >= SAFE_MODE_FAILURE_THRESHOLD
    }

    fn snapshot(&self) -> LifecycleSnapshot {
        LifecycleSnapshot {
            plugin_id: self.plugin_id.clone(),
            desired_state: self.desired_state,
            runtime_state: self.runtime_state,
            compatible: self.compatible,
            grants_satisfied: self.grants_satisfied,
            generation: self.generation,
            updated_at: self.updated_at,
            failure: self.failure.clone(),
        }
    }
}

/// Pure host lifecycle state machine initialized from a validated catalog.
///
/// The owner supplies serialization if the host is shared across threads. All
/// external runtime work is returned as data and no lock is held across store
/// or engine calls.
pub struct PluginLifecycleHost {
    store: Arc<dyn LifecycleStateStore>,
    entries: BTreeMap<PluginId, LifecycleEntry>,
}

impl PluginLifecycleHost {
    /// Builds lifecycle state from catalog compatibility and persisted records.
    pub fn from_catalog(
        catalog: &PluginCatalog,
        store: Arc<dyn LifecycleStateStore>,
        now: TimestampMillis,
    ) -> Result<Self, LifecycleHostError> {
        let mut entries = BTreeMap::new();
        for descriptor in catalog.snapshot().plugins() {
            let plugin_id = descriptor.manifest().id.clone();
            let persisted = store.load(&plugin_id)?.unwrap_or_default();
            let compatible = descriptor.is_compatible();
            let safe_mode = persisted.is_safe_mode();
            let runtime_state = if !compatible {
                PluginRuntimeState::Incompatible
            } else if persisted.desired_state() == DesiredPluginState::Disabled {
                PluginRuntimeState::Disabled
            } else if safe_mode {
                PluginRuntimeState::Failed
            } else {
                PluginRuntimeState::Registered
            };
            let failure =
                (persisted.consecutive_start_failures() > 0).then_some(LifecycleFailure {
                    code: PluginErrorCode::StartFailed,
                    retryable: !safe_mode,
                    consecutive_failures: persisted.consecutive_start_failures(),
                });
            entries.insert(
                plugin_id.clone(),
                LifecycleEntry {
                    plugin_id,
                    desired_state: persisted.desired_state(),
                    runtime_state,
                    compatible,
                    grants_satisfied: false,
                    generation: 0,
                    updated_at: now,
                    failure,
                    consecutive_start_failures: persisted.consecutive_start_failures(),
                    pending: None,
                },
            );
        }
        Ok(Self { store, entries })
    }

    /// Returns snapshots in deterministic plugin identifier order.
    #[must_use]
    pub fn snapshots(&self) -> Vec<LifecycleSnapshot> {
        self.entries
            .values()
            .map(LifecycleEntry::snapshot)
            .collect()
    }

    /// Returns one plugin's immutable lifecycle snapshot.
    pub fn snapshot(&self, plugin_id: &PluginId) -> Result<LifecycleSnapshot, LifecycleHostError> {
        self.entry(plugin_id).map(LifecycleEntry::snapshot)
    }

    /// Updates the current capability-grant readiness used by projection.
    pub fn set_grants_satisfied(
        &mut self,
        plugin_id: &PluginId,
        satisfied: bool,
        now: TimestampMillis,
    ) -> Result<LifecycleSnapshot, LifecycleHostError> {
        let entry = self.entry_mut(plugin_id)?;
        if entry.grants_satisfied != satisfied {
            entry.grants_satisfied = satisfied;
            entry.updated_at = now;
        }
        Ok(entry.snapshot())
    }

    /// Persists the enabled preference without implicitly starting the plugin.
    pub fn enable(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        if self.entry(plugin_id)?.desired_state != DesiredPluginState::Enabled {
            let entry = self.entry(plugin_id)?;
            self.store.save(
                plugin_id,
                PersistedLifecycleState::new(
                    DesiredPluginState::Enabled,
                    entry.consecutive_start_failures,
                ),
            )?;
            let entry = self.entry_mut(plugin_id)?;
            entry.desired_state = DesiredPluginState::Enabled;
            entry.updated_at = now;
            if entry.compatible && entry.runtime_state == PluginRuntimeState::Disabled {
                entry.runtime_state = if entry.is_safe_mode() {
                    PluginRuntimeState::Failed
                } else {
                    PluginRuntimeState::Registered
                };
            }
        }
        self.decision(plugin_id, None)
    }

    /// Persists disabled and revokes projectability before requesting shutdown.
    pub fn disable(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
        stop_deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let needs_stop = matches!(
            self.entry(plugin_id)?.runtime_state,
            PluginRuntimeState::Ready | PluginRuntimeState::Starting
        );
        if needs_stop {
            validate_deadline(now, stop_deadline)?;
        }
        if self.entry(plugin_id)?.desired_state != DesiredPluginState::Disabled {
            let entry = self.entry(plugin_id)?;
            self.store.save(
                plugin_id,
                PersistedLifecycleState::new(
                    DesiredPluginState::Disabled,
                    entry.consecutive_start_failures,
                ),
            )?;
            let entry = self.entry_mut(plugin_id)?;
            entry.desired_state = DesiredPluginState::Disabled;
            entry.updated_at = now;
        }
        if needs_stop {
            return self.begin_stop(plugin_id, stop_deadline);
        }
        let entry = self.entry_mut(plugin_id)?;
        if entry.compatible && !matches!(entry.runtime_state, PluginRuntimeState::Stopping) {
            entry.runtime_state = PluginRuntimeState::Disabled;
            entry.pending = None;
        }
        self.decision(plugin_id, None)
    }

    /// Starts an enabled, compatible, authorized plugin exactly once.
    pub fn start(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
        deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let entry = self.entry(plugin_id)?;
        let admitted = entry.compatible
            && entry.desired_state == DesiredPluginState::Enabled
            && entry.grants_satisfied
            && !entry.is_safe_mode()
            && entry.runtime_state == PluginRuntimeState::Registered;
        if !admitted {
            return self.decision(plugin_id, None);
        }
        validate_deadline(now, deadline)?;
        self.begin_start(plugin_id, deadline)
    }

    /// Stops a running or starting plugin while preserving desired enabled state.
    pub fn stop(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
        deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let admitted = matches!(
            self.entry(plugin_id)?.runtime_state,
            PluginRuntimeState::Ready | PluginRuntimeState::Starting
        );
        if !admitted {
            return self.decision(plugin_id, None);
        }
        validate_deadline(now, deadline)?;
        self.begin_stop(plugin_id, deadline)
    }

    /// Retries a failed plugin unless persistent safe mode requires recovery.
    pub fn retry(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
        deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let entry = self.entry(plugin_id)?;
        let admitted = entry.compatible
            && entry.desired_state == DesiredPluginState::Enabled
            && entry.grants_satisfied
            && !entry.is_safe_mode()
            && entry.runtime_state == PluginRuntimeState::Failed;
        if !admitted {
            return self.decision(plugin_id, None);
        }
        validate_deadline(now, deadline)?;
        self.begin_start(plugin_id, deadline)
    }

    /// Explicitly clears plugin-local safe mode and persisted crash accounting.
    pub fn recover(
        &mut self,
        plugin_id: &PluginId,
        now: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let entry = self.entry(plugin_id)?;
        let recoverable = entry.runtime_state == PluginRuntimeState::Failed
            && entry.is_safe_mode()
            && entry.pending.is_none();
        if !recoverable {
            return self.decision(plugin_id, None);
        }
        self.store.save(
            plugin_id,
            PersistedLifecycleState::new(entry.desired_state, 0),
        )?;
        let entry = self.entry_mut(plugin_id)?;
        entry.consecutive_start_failures = 0;
        entry.failure = None;
        entry.pending = None;
        entry.runtime_state = if !entry.compatible {
            PluginRuntimeState::Incompatible
        } else if entry.desired_state == DesiredPluginState::Disabled {
            PluginRuntimeState::Disabled
        } else {
            PluginRuntimeState::Registered
        };
        entry.updated_at = now;
        self.decision(plugin_id, None)
    }

    /// Applies a start completion only when its generation is still current.
    pub fn complete_start(
        &mut self,
        plugin_id: &PluginId,
        generation: u64,
        completion: LifecycleCompletion,
        now: TimestampMillis,
    ) -> Result<LifecycleCompletionResult, LifecycleHostError> {
        if !self.matches_pending(plugin_id, generation, PendingKind::Start)? {
            return self.completion_result(plugin_id, false, None);
        }
        let work = match completion {
            LifecycleCompletion::Succeeded => {
                let entry = self.entry(plugin_id)?;
                let persisted = PersistedLifecycleState::new(entry.desired_state, 0);
                if self.store.save(plugin_id, persisted).is_err() {
                    let entry = self.entry_mut(plugin_id)?;
                    entry.generation = entry.generation.saturating_add(1);
                    entry.runtime_state = PluginRuntimeState::Failed;
                    entry.failure = Some(LifecycleFailure {
                        code: PluginErrorCode::Unavailable,
                        retryable: true,
                        consecutive_failures: entry.consecutive_start_failures,
                    });
                    entry.pending = None;
                    entry.updated_at = now;
                    return self.completion_result(
                        plugin_id,
                        true,
                        Some(LifecycleWork::CancelAndDisposeStart {
                            plugin_id: plugin_id.clone(),
                            generation,
                        }),
                    );
                }
                let entry = self.entry_mut(plugin_id)?;
                entry.consecutive_start_failures = 0;
                entry.runtime_state = PluginRuntimeState::Ready;
                entry.failure = None;
                entry.pending = None;
                entry.updated_at = now;
                None
            }
            LifecycleCompletion::Failed { code, retryable } => {
                self.apply_start_failure(plugin_id, code, retryable, now, false)?;
                Some(LifecycleWork::CancelAndDisposeStart {
                    plugin_id: plugin_id.clone(),
                    generation,
                })
            }
        };
        self.completion_result(plugin_id, true, work)
    }

    /// Applies a stop completion only when its generation is still current.
    pub fn complete_stop(
        &mut self,
        plugin_id: &PluginId,
        generation: u64,
        completion: LifecycleCompletion,
        now: TimestampMillis,
    ) -> Result<LifecycleCompletionResult, LifecycleHostError> {
        if !self.matches_pending(plugin_id, generation, PendingKind::Stop)? {
            return self.completion_result(plugin_id, false, None);
        }
        let entry = self.entry_mut(plugin_id)?;
        entry.pending = None;
        entry.updated_at = now;
        match completion {
            LifecycleCompletion::Succeeded => {
                entry.runtime_state = if entry.desired_state == DesiredPluginState::Disabled {
                    PluginRuntimeState::Disabled
                } else {
                    PluginRuntimeState::Registered
                };
                entry.failure = None;
            }
            LifecycleCompletion::Failed { code, retryable } => {
                entry.runtime_state = PluginRuntimeState::Failed;
                entry.failure = Some(LifecycleFailure {
                    code,
                    retryable,
                    consecutive_failures: entry.consecutive_start_failures,
                });
            }
        }
        self.completion_result(plugin_id, true, None)
    }

    /// Records an unexpected failure of a ready plugin and revokes projection.
    ///
    /// Calls for plugins that are not currently ready are idempotently ignored.
    pub fn report_runtime_failure(
        &mut self,
        plugin_id: &PluginId,
        code: PluginErrorCode,
        retryable: bool,
        now: TimestampMillis,
    ) -> Result<LifecycleCompletionResult, LifecycleHostError> {
        if self.entry(plugin_id)?.runtime_state != PluginRuntimeState::Ready {
            return self.completion_result(plugin_id, false, None);
        }
        let generation = self.entry(plugin_id)?.generation;
        self.apply_start_failure(plugin_id, code, retryable, now, true)?;
        self.completion_result(
            plugin_id,
            true,
            Some(LifecycleWork::CancelAndDisposeStart {
                plugin_id: plugin_id.clone(),
                generation,
            }),
        )
    }

    /// Applies every expired start or stop deadline at the explicit host time.
    pub fn tick(
        &mut self,
        now: TimestampMillis,
    ) -> Result<Vec<LifecycleDecision>, LifecycleHostError> {
        let expired = self
            .entries
            .iter()
            .filter_map(|(plugin_id, entry)| {
                entry
                    .pending
                    .filter(|pending| pending.deadline.0 <= now.0)
                    .map(|pending| (plugin_id.clone(), pending.kind, pending.generation))
            })
            .collect::<Vec<_>>();
        let mut changed = Vec::with_capacity(expired.len());
        for (plugin_id, kind, expired_generation) in expired {
            let work = match kind {
                PendingKind::Start => {
                    self.apply_start_failure(
                        &plugin_id,
                        PluginErrorCode::Timeout,
                        true,
                        now,
                        true,
                    )?;
                    Some(LifecycleWork::CancelAndDisposeStart {
                        plugin_id: plugin_id.clone(),
                        generation: expired_generation,
                    })
                }
                PendingKind::Stop => {
                    let next_generation = next_generation(self.entry(&plugin_id)?.generation)?;
                    let entry = self.entry_mut(&plugin_id)?;
                    entry.generation = next_generation;
                    entry.runtime_state = PluginRuntimeState::Failed;
                    entry.pending = None;
                    entry.updated_at = now;
                    entry.failure = Some(LifecycleFailure {
                        code: PluginErrorCode::Timeout,
                        retryable: true,
                        consecutive_failures: entry.consecutive_start_failures,
                    });
                    None
                }
            };
            changed.push(self.decision(&plugin_id, work)?);
        }
        Ok(changed)
    }

    fn begin_start(
        &mut self,
        plugin_id: &PluginId,
        deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let generation = next_generation(self.entry(plugin_id)?.generation)?;
        let entry = self.entry_mut(plugin_id)?;
        entry.generation = generation;
        entry.runtime_state = PluginRuntimeState::Starting;
        entry.pending = Some(PendingTransition {
            kind: PendingKind::Start,
            generation,
            deadline,
        });
        self.decision(
            plugin_id,
            Some(LifecycleWork::Start {
                plugin_id: plugin_id.clone(),
                generation,
                deadline,
            }),
        )
    }

    fn begin_stop(
        &mut self,
        plugin_id: &PluginId,
        deadline: TimestampMillis,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        let generation = next_generation(self.entry(plugin_id)?.generation)?;
        let entry = self.entry_mut(plugin_id)?;
        entry.generation = generation;
        entry.runtime_state = PluginRuntimeState::Stopping;
        entry.pending = Some(PendingTransition {
            kind: PendingKind::Stop,
            generation,
            deadline,
        });
        self.decision(
            plugin_id,
            Some(LifecycleWork::Stop {
                plugin_id: plugin_id.clone(),
                generation,
                deadline,
            }),
        )
    }

    fn apply_start_failure(
        &mut self,
        plugin_id: &PluginId,
        code: PluginErrorCode,
        retryable: bool,
        now: TimestampMillis,
        invalidate_generation: bool,
    ) -> Result<(), LifecycleHostError> {
        let entry = self.entry(plugin_id)?;
        let failure_count = entry.consecutive_start_failures.saturating_add(1);
        let generation = if invalidate_generation {
            next_generation(entry.generation)?
        } else {
            entry.generation
        };
        self.store.save(
            plugin_id,
            PersistedLifecycleState::new(entry.desired_state, failure_count),
        )?;
        let entry = self.entry_mut(plugin_id)?;
        entry.consecutive_start_failures = failure_count;
        entry.generation = generation;
        entry.runtime_state = PluginRuntimeState::Failed;
        entry.pending = None;
        entry.updated_at = now;
        entry.failure = Some(LifecycleFailure {
            code,
            retryable: retryable && failure_count < SAFE_MODE_FAILURE_THRESHOLD,
            consecutive_failures: failure_count,
        });
        Ok(())
    }

    fn matches_pending(
        &self,
        plugin_id: &PluginId,
        generation: u64,
        kind: PendingKind,
    ) -> Result<bool, LifecycleHostError> {
        Ok(self
            .entry(plugin_id)?
            .pending
            .is_some_and(|pending| pending.generation == generation && pending.kind == kind))
    }

    fn decision(
        &self,
        plugin_id: &PluginId,
        work: Option<LifecycleWork>,
    ) -> Result<LifecycleDecision, LifecycleHostError> {
        Ok(LifecycleDecision {
            snapshot: self.snapshot(plugin_id)?,
            work,
        })
    }

    fn completion_result(
        &self,
        plugin_id: &PluginId,
        applied: bool,
        work: Option<LifecycleWork>,
    ) -> Result<LifecycleCompletionResult, LifecycleHostError> {
        Ok(LifecycleCompletionResult {
            snapshot: self.snapshot(plugin_id)?,
            applied,
            work,
        })
    }

    fn entry(&self, plugin_id: &PluginId) -> Result<&LifecycleEntry, LifecycleHostError> {
        self.entries
            .get(plugin_id)
            .ok_or(LifecycleHostError::UnknownPlugin)
    }

    fn entry_mut(
        &mut self,
        plugin_id: &PluginId,
    ) -> Result<&mut LifecycleEntry, LifecycleHostError> {
        self.entries
            .get_mut(plugin_id)
            .ok_or(LifecycleHostError::UnknownPlugin)
    }
}

/// Stable failures returned by the host lifecycle state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum LifecycleHostError {
    /// The requested plugin is not present in the catalog snapshot.
    #[error("plugin is not registered in the lifecycle host")]
    UnknownPlugin,
    /// An external transition deadline was not later than the current time.
    #[error("plugin lifecycle deadline must be later than now")]
    InvalidDeadline,
    /// The monotonic lifecycle generation cannot advance safely.
    #[error("plugin lifecycle generation is exhausted")]
    GenerationExhausted,
    /// Persisted desired state or crash accounting could not be accessed.
    #[error(transparent)]
    Store(#[from] LifecycleStoreError),
}

fn validate_deadline(
    now: TimestampMillis,
    deadline: TimestampMillis,
) -> Result<(), LifecycleHostError> {
    if deadline.0 <= now.0 {
        return Err(LifecycleHostError::InvalidDeadline);
    }
    Ok(())
}

fn next_generation(current: u64) -> Result<u64, LifecycleHostError> {
    current
        .checked_add(1)
        .ok_or(LifecycleHostError::GenerationExhausted)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use semver::Version;
    use timetrace_plugin_api::{
        CURRENT_MANIFEST_SCHEMA_VERSION, HostApiRange, Platform, PluginManifest, PublisherId,
    };

    use super::*;

    fn at(value: i64) -> TimestampMillis {
        TimestampMillis(value)
    }

    fn plugin_id(value: &str) -> PluginId {
        PluginId::new(value).expect("valid plugin id")
    }

    fn manifest(id: &str, platform: Platform) -> PluginManifest {
        PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: plugin_id(id),
            publisher: PublisherId::new("timetrace-labs").expect("valid publisher"),
            display_name: id.to_owned(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("valid host API"),
            platforms: vec![platform],
            contributions: Vec::new(),
            requested_capabilities: Vec::new(),
        }
    }

    fn catalog() -> PluginCatalog {
        PluginCatalog::build(
            Version::new(1, 0, 0),
            Platform::WindowsX64,
            [
                manifest("plugin-b", Platform::WindowsX64),
                manifest("plugin-a", Platform::WindowsX64),
                manifest("plugin-incompatible", Platform::LinuxX64),
            ],
        )
        .expect("valid catalog")
    }

    fn host(store: InMemoryLifecycleStateStore) -> Result<PluginLifecycleHost, LifecycleHostError> {
        PluginLifecycleHost::from_catalog(&catalog(), Arc::new(store), at(0))
    }

    #[derive(Clone, Default)]
    struct ToggleFailStore {
        inner: InMemoryLifecycleStateStore,
        fail_saves: Arc<AtomicBool>,
    }

    impl LifecycleStateStore for ToggleFailStore {
        fn load(
            &self,
            plugin_id: &PluginId,
        ) -> Result<Option<PersistedLifecycleState>, LifecycleStoreError> {
            self.inner.load(plugin_id)
        }

        fn save(
            &self,
            plugin_id: &PluginId,
            state: PersistedLifecycleState,
        ) -> Result<(), LifecycleStoreError> {
            if self.fail_saves.load(Ordering::SeqCst) {
                return Err(LifecycleStoreError::Unavailable);
            }
            self.inner.save(plugin_id, state)
        }
    }

    fn enable_and_authorize(
        host: &mut PluginLifecycleHost,
        id: &PluginId,
    ) -> Result<(), LifecycleHostError> {
        host.enable(id, at(1))?;
        host.set_grants_satisfied(id, true, at(2))?;
        Ok(())
    }

    fn start_generation(
        host: &mut PluginLifecycleHost,
        id: &PluginId,
        now: i64,
    ) -> Result<u64, LifecycleHostError> {
        let decision = host.start(id, at(now), at(now + 10))?;
        match decision.work() {
            Some(LifecycleWork::Start { generation, .. }) => Ok(*generation),
            _ => Err(LifecycleHostError::UnknownPlugin),
        }
    }

    #[test]
    fn desired_state_and_crash_accounting_persist_without_transients() {
        let store = InMemoryLifecycleStateStore::new();
        let id = plugin_id("plugin-a");
        let mut first = host(store.clone()).expect("host");
        enable_and_authorize(&mut first, &id).expect("enable");
        let generation = start_generation(&mut first, &id, 3).expect("start");
        first
            .complete_start(
                &id,
                generation,
                LifecycleCompletion::Failed {
                    code: PluginErrorCode::StartFailed,
                    retryable: true,
                },
                at(4),
            )
            .expect("failure");

        let persisted = store.get(&id).expect("store").expect("record");
        assert_eq!(persisted.desired_state(), DesiredPluginState::Enabled);
        assert_eq!(persisted.consecutive_start_failures(), 1);
        let restarted = host(store).expect("restart");
        let snapshot = restarted.snapshot(&id).expect("snapshot");
        assert_eq!(snapshot.runtime_state, PluginRuntimeState::Registered);
        assert_eq!(snapshot.generation, 0);
    }

    #[test]
    fn commands_are_idempotent_and_stop_revokes_projection_first() {
        let store = InMemoryLifecycleStateStore::new();
        let id = plugin_id("plugin-a");
        let mut host = host(store.clone()).expect("host");
        enable_and_authorize(&mut host, &id).expect("enable");
        assert!(
            host.enable(&id, at(3))
                .expect("enable twice")
                .work()
                .is_none()
        );
        let generation = start_generation(&mut host, &id, 4).expect("start");
        assert!(
            host.start(&id, at(5), at(15))
                .expect("start twice")
                .work()
                .is_none()
        );
        host.complete_start(&id, generation, LifecycleCompletion::Succeeded, at(6))
            .expect("ready");
        assert!(host.snapshot(&id).expect("snapshot").is_projectable());

        let stopping = host.stop(&id, at(7), at(17)).expect("stop");
        assert_eq!(
            stopping.snapshot().runtime_state,
            PluginRuntimeState::Stopping
        );
        assert!(!stopping.snapshot().is_projectable());
        assert!(
            host.stop(&id, at(8), at(18))
                .expect("stop twice")
                .work()
                .is_none()
        );
        let stop_generation = match stopping.work() {
            Some(LifecycleWork::Stop { generation, .. }) => *generation,
            _ => panic!("ready plugin should produce stop work"),
        };
        host.complete_stop(&id, stop_generation, LifecycleCompletion::Succeeded, at(9))
            .expect("stopped");

        let generation = start_generation(&mut host, &id, 10).expect("restart");
        host.complete_start(
            &id,
            generation,
            LifecycleCompletion::Failed {
                code: PluginErrorCode::StartFailed,
                retryable: true,
            },
            at(11),
        )
        .expect("start failure");
        let retrying = host.retry(&id, at(12), at(22)).expect("retry");
        assert!(matches!(retrying.work(), Some(LifecycleWork::Start { .. })));
        assert!(
            host.retry(&id, at(13), at(23))
                .expect("retry twice")
                .work()
                .is_none()
        );

        let disabling = host.disable(&id, at(14), at(24)).expect("disable");
        assert_eq!(
            disabling.snapshot().desired_state,
            DesiredPluginState::Disabled
        );
        assert!(!disabling.snapshot().is_projectable());
        assert!(
            host.disable(&id, at(15), at(25))
                .expect("disable twice")
                .work()
                .is_none()
        );
        assert_eq!(
            store
                .get(&id)
                .expect("store")
                .expect("record")
                .desired_state(),
            DesiredPluginState::Disabled
        );
    }

    #[test]
    fn tick_times_out_and_late_completion_is_suppressed_by_generation() {
        let id = plugin_id("plugin-a");
        let mut host = host(InMemoryLifecycleStateStore::new()).expect("host");
        enable_and_authorize(&mut host, &id).expect("enable");
        let generation = start_generation(&mut host, &id, 3).expect("start");

        assert!(host.tick(at(12)).expect("before deadline").is_empty());
        let timed_out = host.tick(at(13)).expect("deadline");
        assert_eq!(timed_out.len(), 1);
        assert_eq!(
            timed_out[0].snapshot().runtime_state,
            PluginRuntimeState::Failed
        );
        assert!(timed_out[0].snapshot().generation > generation);
        assert!(matches!(
            timed_out[0].work(),
            Some(LifecycleWork::CancelAndDisposeStart {
                generation: cleanup_generation,
                ..
            }) if *cleanup_generation == generation
        ));
        assert!(host.tick(at(14)).expect("already expired").is_empty());
        let late = host
            .complete_start(&id, generation, LifecycleCompletion::Succeeded, at(14))
            .expect("late completion");
        assert!(!late.was_applied());
        assert!(late.work().is_none());
        assert_eq!(late.snapshot().runtime_state, PluginRuntimeState::Failed);
    }

    #[test]
    fn stop_timeout_stays_nonprojectable_and_suppresses_late_completion() {
        let id = plugin_id("plugin-a");
        let mut host = host(InMemoryLifecycleStateStore::new()).expect("host");
        enable_and_authorize(&mut host, &id).expect("enable");
        let start_generation = start_generation(&mut host, &id, 1).expect("start");
        host.complete_start(&id, start_generation, LifecycleCompletion::Succeeded, at(2))
            .expect("ready");
        let stopping = host.stop(&id, at(3), at(5)).expect("stop");
        let stop_generation = match stopping.work() {
            Some(LifecycleWork::Stop { generation, .. }) => *generation,
            _ => panic!("ready plugin should produce stop work"),
        };

        let timed_out = host.tick(at(5)).expect("stop deadline");
        assert_eq!(timed_out.len(), 1);
        assert_eq!(
            timed_out[0].snapshot().runtime_state,
            PluginRuntimeState::Failed
        );
        assert!(!timed_out[0].snapshot().is_projectable());
        assert!(timed_out[0].snapshot().generation > stop_generation);
        let late = host
            .complete_stop(&id, stop_generation, LifecycleCompletion::Succeeded, at(6))
            .expect("late stop completion");
        assert!(!late.was_applied());
    }

    #[test]
    fn one_plugin_failure_does_not_change_other_plugins() {
        let first = plugin_id("plugin-a");
        let second = plugin_id("plugin-b");
        let mut host = host(InMemoryLifecycleStateStore::new()).expect("host");
        enable_and_authorize(&mut host, &first).expect("first enabled");
        enable_and_authorize(&mut host, &second).expect("second enabled");
        let first_generation = start_generation(&mut host, &first, 3).expect("first start");
        let second_generation = start_generation(&mut host, &second, 3).expect("second start");
        host.complete_start(
            &first,
            first_generation,
            LifecycleCompletion::Succeeded,
            at(4),
        )
        .expect("first starts");
        host.complete_start(
            &second,
            second_generation,
            LifecycleCompletion::Succeeded,
            at(4),
        )
        .expect("second succeeds");
        assert!(host.snapshot(&first).expect("first ready").is_projectable());
        host.report_runtime_failure(&first, PluginErrorCode::Internal, true, at(5))
            .expect("first crashes");

        assert_eq!(
            host.snapshot(&first).expect("first").runtime_state,
            PluginRuntimeState::Failed
        );
        assert!(host.snapshot(&second).expect("second").is_projectable());
    }

    #[test]
    fn safe_mode_requires_explicit_recovery() {
        let store = InMemoryLifecycleStateStore::new();
        let id = plugin_id("plugin-a");
        let mut host = host(store.clone()).expect("host");
        enable_and_authorize(&mut host, &id).expect("enable");
        for attempt in 0..SAFE_MODE_FAILURE_THRESHOLD {
            let generation = if attempt == 0 {
                start_generation(&mut host, &id, 3).expect("start")
            } else {
                let decision = host
                    .retry(&id, at(10 + i64::from(attempt)), at(30))
                    .expect("retry");
                match decision.work() {
                    Some(LifecycleWork::Start { generation, .. }) => *generation,
                    _ => panic!("retry should start before safe mode"),
                }
            };
            host.complete_start(
                &id,
                generation,
                LifecycleCompletion::Failed {
                    code: PluginErrorCode::StartFailed,
                    retryable: true,
                },
                at(20 + i64::from(attempt)),
            )
            .expect("failure");
        }
        let safe = host.snapshot(&id).expect("safe mode");
        assert_eq!(
            safe.failure.as_ref().map(|failure| failure.retryable),
            Some(false)
        );
        assert!(
            host.retry(&id, at(40), at(50))
                .expect("blocked")
                .work()
                .is_none()
        );

        let recovered = host.recover(&id, at(41)).expect("recover");
        assert_eq!(
            recovered.snapshot().runtime_state,
            PluginRuntimeState::Registered
        );
        assert!(recovered.snapshot().failure.is_none());
        assert_eq!(
            store
                .get(&id)
                .expect("store")
                .expect("record")
                .consecutive_start_failures(),
            0
        );
    }

    #[test]
    fn recover_is_ignored_until_failed_safe_mode_is_quiescent() {
        let store = InMemoryLifecycleStateStore::new();
        let id = plugin_id("plugin-a");
        store
            .seed(
                id.clone(),
                PersistedLifecycleState::new(
                    DesiredPluginState::Disabled,
                    SAFE_MODE_FAILURE_THRESHOLD,
                ),
            )
            .expect("seed safe mode");
        let mut host = host(store.clone()).expect("host");

        let disabled = host.recover(&id, at(1)).expect("ignored while disabled");
        assert_eq!(
            disabled.snapshot().runtime_state,
            PluginRuntimeState::Disabled
        );
        assert_eq!(
            store
                .get(&id)
                .expect("store")
                .expect("record")
                .consecutive_start_failures(),
            SAFE_MODE_FAILURE_THRESHOLD
        );

        host.enable(&id, at(2))
            .expect("enable into failed safe mode");
        let recovered = host.recover(&id, at(3)).expect("recover safe failure");
        assert_eq!(
            recovered.snapshot().runtime_state,
            PluginRuntimeState::Registered
        );
    }

    #[test]
    fn successful_start_with_store_failure_fails_closed_and_disposes_once() {
        let store = ToggleFailStore::default();
        let id = plugin_id("plugin-a");
        let mut host =
            PluginLifecycleHost::from_catalog(&catalog(), Arc::new(store.clone()), at(0))
                .expect("host");
        enable_and_authorize(&mut host, &id).expect("enable");
        let first_generation = start_generation(&mut host, &id, 3).expect("first start");
        host.complete_start(
            &id,
            first_generation,
            LifecycleCompletion::Failed {
                code: PluginErrorCode::StartFailed,
                retryable: true,
            },
            at(4),
        )
        .expect("persist first failure");

        let retry = host.retry(&id, at(5), at(15)).expect("retry");
        let retry_generation = match retry.work() {
            Some(LifecycleWork::Start { generation, .. }) => *generation,
            _ => panic!("retry should start"),
        };
        store.fail_saves.store(true, Ordering::SeqCst);
        let failed_closed = host
            .complete_start(&id, retry_generation, LifecycleCompletion::Succeeded, at(6))
            .expect("store failure becomes a fail-closed result");
        assert!(failed_closed.was_applied());
        assert_eq!(
            failed_closed.snapshot().runtime_state,
            PluginRuntimeState::Failed
        );
        assert!(!failed_closed.snapshot().is_projectable());
        assert_eq!(
            failed_closed
                .snapshot()
                .failure
                .as_ref()
                .map(|failure| failure.code),
            Some(PluginErrorCode::Unavailable)
        );
        assert!(matches!(
            failed_closed.work(),
            Some(LifecycleWork::CancelAndDisposeStart { generation, .. })
                if *generation == retry_generation
        ));

        let duplicate = host
            .complete_start(&id, retry_generation, LifecycleCompletion::Succeeded, at(7))
            .expect("duplicate completion");
        assert!(!duplicate.was_applied());
        assert!(duplicate.work().is_none());
    }

    #[test]
    fn restart_resets_starting_and_stopping_to_registered() {
        let store = InMemoryLifecycleStateStore::new();
        let first = plugin_id("plugin-a");
        let second = plugin_id("plugin-b");
        let mut running = host(store.clone()).expect("host");
        enable_and_authorize(&mut running, &first).expect("first");
        enable_and_authorize(&mut running, &second).expect("second");
        let generation = start_generation(&mut running, &first, 3).expect("start");
        start_generation(&mut running, &second, 3).expect("start second");
        running
            .complete_start(&first, generation, LifecycleCompletion::Succeeded, at(4))
            .expect("ready");
        running.stop(&first, at(5), at(10)).expect("stopping");

        let restarted = host(store).expect("restart");
        assert_eq!(
            restarted.snapshot(&first).expect("first").runtime_state,
            PluginRuntimeState::Registered
        );
        assert_eq!(
            restarted.snapshot(&second).expect("second").runtime_state,
            PluginRuntimeState::Registered
        );
        let ids = restarted
            .snapshots()
            .into_iter()
            .map(|snapshot| snapshot.plugin_id.into_string())
            .collect::<Vec<_>>();
        assert_eq!(ids, ["plugin-a", "plugin-b", "plugin-incompatible"]);
    }
}
