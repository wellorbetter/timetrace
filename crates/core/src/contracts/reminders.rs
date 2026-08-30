//! Persistence contracts for application continuous-use reminder rules.
//!
//! These records intentionally remain separate from [`super::storage::DataStore`],
//! whose responsibility is historical usage and diary data.

use chrono::{DateTime, Utc};
use thiserror::Error;

/// Maximum accepted threshold or cooldown: 24 hours.
pub const MAX_APP_TIMEOUT_DURATION_SECS: i64 = 24 * 60 * 60;

/// A durable executable-specific timeout rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTimeoutRuleRecord {
    /// Stable local SQLite identifier.
    pub id: i64,
    /// Platform-normalized absolute executable path used only as identity.
    pub app_path: String,
    /// Privacy-safe application display name.
    pub app_name: String,
    /// Active foreground seconds required before the first notification.
    pub threshold_secs: i64,
    /// Additional active seconds required between repeated notifications.
    pub cooldown_secs: i64,
    /// Whether this rule participates in evaluation.
    pub enabled: bool,
    /// Whether notifications may repeat in the same continuous segment.
    pub notify_repeatedly: bool,
    /// Creation time retained across upserts.
    pub created_at: DateTime<Utc>,
    /// Last update time.
    pub updated_at: DateTime<Utc>,
}

/// User-editable fields used to create or update a timeout rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppTimeoutRuleDraft {
    /// Absolute executable path; repositories normalize it before matching.
    pub app_path: String,
    /// Privacy-safe application display name.
    pub app_name: String,
    /// Active foreground seconds required before the first notification.
    pub threshold_secs: i64,
    /// Additional active seconds required between repeated notifications.
    pub cooldown_secs: i64,
    /// Whether this rule participates in evaluation.
    pub enabled: bool,
    /// Whether notifications may repeat in the same continuous segment.
    pub notify_repeatedly: bool,
}

/// Stable, non-sensitive timeout-rule operation failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum AppTimeoutRuleError {
    /// The executable path is not a valid stable identity.
    #[error("invalid executable path")]
    InvalidPath,
    /// A display name must contain visible content.
    #[error("application name is empty")]
    EmptyAppName,
    /// Threshold and cooldown must be between one second and 24 hours.
    #[error("timeout duration is out of range")]
    InvalidDuration,
    /// No rule exists for the requested identifier.
    #[error("timeout rule was not found")]
    NotFound,
    /// SQLite could not complete the operation; details stay in local logs.
    #[error("timeout rule storage is unavailable")]
    Storage,
}

/// Narrow local persistence boundary for application timeout rules.
pub trait AppTimeoutRuleRepository: Send + Sync {
    /// Return every rule in deterministic display-name/id order.
    fn list_rules(&self) -> Result<Vec<AppTimeoutRuleRecord>, AppTimeoutRuleError>;

    /// Insert or update a rule by normalized executable identity.
    ///
    /// Updating an existing identity retains both its stable ID and creation
    /// timestamp.
    fn upsert_rule(
        &self,
        draft: &AppTimeoutRuleDraft,
    ) -> Result<AppTimeoutRuleRecord, AppTimeoutRuleError>;

    /// Delete a rule by stable ID.
    fn delete_rule(&self, id: i64) -> Result<(), AppTimeoutRuleError>;
}
