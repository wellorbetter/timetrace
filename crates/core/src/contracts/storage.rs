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
    /// Example exe path for icon extraction (first seen).
    pub exe_path: String,
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

    /// Record a page visit (window title segment) within a session.
    fn start_page_visit(&self, session_id: i64, app_name: &str, title: Option<&str>, date: NaiveDate) -> i64;

    /// Close a page visit, computing its duration.
    fn close_page_visit(&self, visit_id: i64, end_time: DateTime<Utc>);

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

    /// Delete ALL sessions and page visits (used by settings "clear data").
    fn clear_all_data(&self);

    /// Raw export rows: (app_name, date, active_secs, idle_secs).
    fn export_rows(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String, i64, i64)>;

    /// All diary entries in a month range: (date_str, content).
    fn get_diary_entries(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String)>;

    /// Get or create the diary entry for a date.
    fn get_diary(&self, date: NaiveDate) -> Option<String>;

    /// Upsert a diary entry for a date. Returns the new content.
    fn set_diary(&self, date: NaiveDate, content: &str) -> String;

    /// Per-session detail for a day: (app_name, is_idle, duration_secs, started_at).
    fn get_day_sessions(&self, date: NaiveDate) -> Vec<(String, bool, i64, String)>;

    /// Hourly active-seconds for a day (24 buckets).
    fn get_day_hourly(&self, date: NaiveDate) -> Vec<i64>;

    /// Diary image paths in a range: (date_str, path).
    fn get_diary_images(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String)>;

    /// Add a diary image for a date. Returns the stored path.
    fn add_diary_image(&self, date: NaiveDate, path: &str) -> String;

    /// Remove a diary image by path.
    fn remove_diary_image(&self, path: &str);
}
