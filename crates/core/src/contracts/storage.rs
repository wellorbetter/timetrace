//! Storage contracts — the DataStore trait and all record types.

use chrono::{DateTime, NaiveDate, Utc};

use super::startup::StartupEntryRecord;

// ── Record Types ──

/// A single tracked application session.
#[derive(Debug, Clone)]
pub struct SessionRecord {
    pub id: i64,
    /// Full path to the executable.
    pub app_path: String,
    /// Display name (e.g., "Visual Studio Code").
    pub app_name: String,
    /// Window title at session start (optional).
    pub window_title: Option<String>,
    /// When the session started.
    pub started_at: DateTime<Utc>,
    /// When the session ended (None if still active).
    pub ended_at: Option<DateTime<Utc>>,
    /// Duration in seconds (computed when session closes).
    pub duration_secs: Option<i64>,
    /// Whether this session was an idle period.
    pub is_idle: bool,
    /// Date key for fast date-based queries (YYYY-MM-DD).
    pub date: NaiveDate,
}

/// Aggregated usage stats for a single application on a single day.
#[derive(Debug, Clone)]
pub struct AppUsageSummary {
    pub app_name: String,
    pub total_seconds: i64,
    pub session_count: i64,
    pub rank: usize,
}

/// Per-app usage split between active and idle time.
#[derive(Debug, Clone)]
pub struct AppUsageSplit {
    pub app_name: String,
    pub active_seconds: i64,
    pub idle_seconds: i64,
}

/// User-assigned metadata for an application.
#[derive(Debug, Clone)]
pub struct AppMetaRecord {
    pub app_path: String,
    pub display_name: Option<String>,
    /// User-defined category (e.g., "Work", "Entertainment").
    pub category: Option<String>,
    /// User-defined productivity flag.
    pub is_productive: Option<bool>,
}

// ── DataStore Trait ──

/// Persistent storage for all TimeTrace data.
///
/// All methods are synchronous and infallible at this level —
/// errors are logged internally via `tracing`.
///
/// Implemented by `storage::sqlite::SqliteStore`.
pub trait DataStore: Send + Sync {
    // ── Session CRUD ──

    /// Insert a new session. Returns the auto-generated ID.
    fn insert_session(&self, session: &SessionRecord) -> i64;

    /// Close an active session: set `ended_at` and compute `duration_secs`.
    fn close_session(&self, id: i64, end_time: DateTime<Utc>);

    /// Get the currently active session (the one without `ended_at`).
    fn get_active_session(&self) -> Option<SessionRecord>;

    // ── Queries ──

    /// Get all sessions for a specific date.
    fn get_sessions_by_date(&self, date: NaiveDate) -> Vec<SessionRecord>;

    /// Get all sessions in a date range (inclusive).
    fn get_sessions_by_range(&self, start: NaiveDate, end: NaiveDate) -> Vec<SessionRecord>;

    /// Get aggregated usage summary for a single day.
    fn get_daily_summary(&self, date: NaiveDate) -> Vec<AppUsageSummary>;

    /// Get top N apps by total usage time in a date range.
    fn get_top_apps(&self, start: NaiveDate, end: NaiveDate, limit: usize) -> Vec<AppUsageSummary>;

    /// Get per-app active + idle time split for a date range.
    fn get_usage_split(&self, start: NaiveDate, end: NaiveDate) -> Vec<AppUsageSplit>;

    /// Get hourly breakdown for a specific app on a specific date.
    /// Returns 24 entries (one per hour), each with total seconds.
    fn get_hourly_breakdown(&self, app_name: &str, date: NaiveDate) -> [i64; 24];

    /// Get per-window-title breakdown for an app on a date.
    /// Returns Vec of (window_title, total_seconds).
    fn get_window_titles(&self, app_name: &str, date: NaiveDate) -> Vec<(String, i64)>;

    // ── Startup CRUD ──

    /// Insert or update startup entries from a scan.
    fn upsert_startup_entries(&self, entries: &[StartupEntryRecord]);

    /// Get all known startup entries.
    fn get_all_startup_entries(&self) -> Vec<StartupEntryRecord>;

    /// Set the enabled status of a startup entry and update backup data.
    fn set_startup_enabled(&self, id: i64, enabled: bool, backup: Option<&str>, backup_path: Option<&str>);

    // ── App Metadata ──

    fn get_app_meta(&self, exe_path: &str) -> Option<AppMetaRecord>;
    fn set_app_meta(&self, meta: &AppMetaRecord);

    // ── Recording Stats ──

    /// Timestamp of the very first recorded session (when tracking began).
    fn recording_started_at(&self) -> Option<DateTime<Utc>>;

    /// Total tracked time across all sessions (excluding idle), in seconds.
    fn total_tracked_seconds(&self) -> i64;

    /// Total tracked time for a specific date range.
    fn total_tracked_in_range(&self, start: NaiveDate, end: NaiveDate) -> i64;

    // ── Maintenance ──

    /// Delete sessions older than `before` date.
    fn cleanup_old_sessions(&self, before: NaiveDate);

    /// Reclaim space from deleted records.
    fn vacuum(&self);
}
