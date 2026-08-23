//! Deterministic plugin lifecycle DTOs.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::{PluginErrorCode, PluginId, TimestampMillis};

/// User-persisted desired plugin state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DesiredPluginState {
    /// The plugin should remain disabled.
    Disabled,
    /// The plugin should be activated when compatible and authorized.
    Enabled,
}

/// Transient and terminal runtime states owned by the plugin host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PluginRuntimeState {
    /// Manifest registered but not yet evaluated.
    Registered,
    /// Manifest or platform is incompatible with the host.
    Incompatible,
    /// Plugin is disabled and has no projected contributions.
    Disabled,
    /// Activation is in progress.
    Starting,
    /// Plugin is ready and may project authorized contributions.
    Ready,
    /// Shutdown and receipt revocation are in progress.
    Stopping,
    /// Plugin reached a failure terminal state.
    Failed,
}

/// Idempotent lifecycle commands accepted by the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum LifecycleCommand {
    /// Persist the enabled preference.
    Enable,
    /// Persist the disabled preference and revoke contributions.
    Disable,
    /// Start an enabled plugin.
    Start,
    /// Stop a running plugin while retaining its desired state.
    Stop,
    /// Retry activation after an explicit failure.
    Retry,
}

/// Optional non-sensitive lifecycle failure summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct LifecycleFailure {
    /// Stable failure class.
    pub code: PluginErrorCode,
    /// Whether a retry may succeed without changing configuration.
    pub retryable: bool,
    /// Number of consecutive activation failures.
    pub consecutive_failures: u32,
}

/// Immutable lifecycle state published by the plugin host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct LifecycleSnapshot {
    /// Plugin described by this snapshot.
    pub plugin_id: PluginId,
    /// Persisted user or host-policy preference.
    pub desired_state: DesiredPluginState,
    /// Current host-owned runtime state.
    pub runtime_state: PluginRuntimeState,
    /// Whether host API and platform compatibility checks passed.
    pub compatible: bool,
    /// Whether every requested capability required for activation is granted.
    pub grants_satisfied: bool,
    /// Monotonic host generation used to suppress late results.
    pub generation: u64,
    /// Timestamp of the last completed transition.
    pub updated_at: TimestampMillis,
    /// Last non-sensitive failure summary, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<LifecycleFailure>,
}

impl LifecycleSnapshot {
    /// Returns the fail-closed projection condition required by the contract.
    #[must_use]
    pub fn is_projectable(&self) -> bool {
        self.compatible
            && self.grants_satisfied
            && self.desired_state == DesiredPluginState::Enabled
            && self.runtime_state == PluginRuntimeState::Ready
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot() -> LifecycleSnapshot {
        LifecycleSnapshot {
            plugin_id: PluginId::new("sample-plugin").expect("valid plugin"),
            desired_state: DesiredPluginState::Enabled,
            runtime_state: PluginRuntimeState::Ready,
            compatible: true,
            grants_satisfied: true,
            generation: 1,
            updated_at: TimestampMillis(1),
            failure: None,
        }
    }

    #[test]
    fn projection_requires_every_safe_state_condition() {
        let mut value = snapshot();
        assert!(value.is_projectable());
        value.grants_satisfied = false;
        assert!(!value.is_projectable());
        value.grants_satisfied = true;
        value.runtime_state = PluginRuntimeState::Failed;
        assert!(!value.is_projectable());
    }
}
