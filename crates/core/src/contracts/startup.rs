//! Startup scanner — discovers and manages auto-start entries.

use chrono::{DateTime, Utc};

/// A single auto-start entry found on the system.
#[derive(Debug, Clone)]
pub struct StartupEntryRecord {
    pub id: i64,
    pub name: String,
    /// The full command line that would be executed.
    pub command: String,
    /// Where this entry was found: "HKLM", "HKCU", "StartupFolder", "TaskScheduler".
    pub source: String,
    /// Whether this entry is currently enabled.
    pub enabled: bool,
    /// Original registry value or file path (for restore).
    pub backup_value: Option<String>,
    /// Original file path before move (for StartupFolder restore).
    pub backup_path: Option<String>,
    /// When this entry was first discovered by TimeTrace.
    pub first_seen: DateTime<Utc>,
    /// When this entry was last checked/scanned.
    pub last_checked: DateTime<Utc>,
}

/// Result of disabling a startup entry. Contains data needed for re-enable.
#[derive(Debug, Clone)]
pub struct DisableResult {
    pub backup_value: Option<String>,
    pub backup_path: Option<String>,
}

/// Scans system startup locations and manages entries.
///
/// Implemented by `engine::startup_win32` using registry, filesystem, and COM APIs.
pub trait StartupScanner: Send + Sync {
    /// Scan all known startup locations and return discovered entries.
    /// This is a potentially slow operation (COM/WMI calls); run off the UI thread.
    fn scan(&self) -> Vec<StartupEntryRecord>;

    /// Disable a startup entry. Returns backup data needed for future re-enable.
    /// The caller should persist the returned `DisableResult` via `DataStore`.
    fn disable(&self, entry: &StartupEntryRecord) -> Result<DisableResult, String>;

    /// Re-enable a previously disabled startup entry.
    /// The caller should provide the backup data from the original disable operation.
    fn enable(&self, entry: &StartupEntryRecord) -> Result<(), String>;
}
