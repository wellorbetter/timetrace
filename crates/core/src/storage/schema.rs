//! SQLite schema definition and migrations.

pub const SCHEMA_VERSION: i32 = 1;

/// All SQL statements to create the initial schema.
pub const CREATE_TABLES: &[&str] = &[
    // ── Usage sessions (raw event data) ──
    "CREATE TABLE IF NOT EXISTS usage_sessions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        app_path        TEXT    NOT NULL,
        app_name        TEXT    NOT NULL,
        window_title    TEXT,
        started_at      TEXT    NOT NULL,   -- ISO 8601 UTC
        ended_at        TEXT,               -- NULL if still active
        duration_secs   INTEGER,            -- computed on close
        is_idle         INTEGER NOT NULL DEFAULT 0,
        date            TEXT    NOT NULL    -- YYYY-MM-DD
    )",

    // ── Pre-aggregated daily summaries (fast dashboard queries) ──
    "CREATE TABLE IF NOT EXISTS daily_summary (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        app_name        TEXT    NOT NULL,
        date            TEXT    NOT NULL,
        total_seconds   INTEGER NOT NULL,
        session_count   INTEGER NOT NULL,
        UNIQUE(app_name, date)
    )",

    // ── Startup entries ──
    "CREATE TABLE IF NOT EXISTS startup_entries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        name            TEXT    NOT NULL,
        command         TEXT    NOT NULL,
        source          TEXT    NOT NULL,   -- HKLM, HKCU, StartupFolder, TaskScheduler
        enabled         INTEGER NOT NULL DEFAULT 1,
        backup_value    TEXT,               -- original registry value
        backup_path     TEXT,               -- original file path
        first_seen      TEXT    NOT NULL,
        last_checked    TEXT    NOT NULL
    )",

    // ── App metadata (user-assigned) ──
    "CREATE TABLE IF NOT EXISTS app_metadata (
        app_path        TEXT    PRIMARY KEY,
        display_name    TEXT,
        category        TEXT,
        is_productive   INTEGER
    )",

    // ── Indexes ──
    "CREATE INDEX IF NOT EXISTS idx_sessions_date ON usage_sessions(date)",
    "CREATE INDEX IF NOT EXISTS idx_sessions_app_date ON usage_sessions(app_name, date)",
    "CREATE INDEX IF NOT EXISTS idx_daily_date ON daily_summary(date)",
    "CREATE INDEX IF NOT EXISTS idx_startup_source ON startup_entries(source)",
];

/// Enable WAL mode and set pragmas for performance.
pub const PRAGMAS: &[&str] = &[
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA cache_size = -8000",       // 8 MB cache
    "PRAGMA busy_timeout = 5000",
];
