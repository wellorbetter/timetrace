//! SQLite schema definition and migrations.

pub const SCHEMA_VERSION: i32 = 1;

/// All SQL statements to create the initial schema.
pub const CREATE_TABLES: &[&str] = &[
    // ── Usage sessions (raw event data) ──
    // Create only what we use
    "CREATE TABLE IF NOT EXISTS usage_sessions (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        app_path        TEXT    NOT NULL,
        app_name        TEXT    NOT NULL,
        window_title    TEXT,
        started_at      TEXT    NOT NULL,
        ended_at        TEXT,
        duration_secs   INTEGER,
        is_idle         INTEGER NOT NULL DEFAULT 0,
        date            TEXT    NOT NULL
    )",
    "CREATE TABLE IF NOT EXISTS startup_entries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        name            TEXT    NOT NULL,
        command         TEXT    NOT NULL,
        source          TEXT    NOT NULL,
        enabled         INTEGER NOT NULL DEFAULT 1,
        backup_value    TEXT,
        backup_path     TEXT,
        first_seen      TEXT    NOT NULL,
        last_checked    TEXT    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS idx_sessions_date ON usage_sessions(date)",
    "CREATE INDEX IF NOT EXISTS idx_sessions_app_date ON usage_sessions(app_name, date)",

    // Page-level visits within a session (window title segments)
    "CREATE TABLE IF NOT EXISTS page_visits (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id      INTEGER NOT NULL,
        app_name        TEXT    NOT NULL,
        window_title    TEXT,
        started_at      TEXT    NOT NULL,
        ended_at        TEXT,
        duration_secs   INTEGER,
        date            TEXT    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS idx_page_visits_app ON page_visits(app_name, date)",
];

/// Enable WAL mode and set pragmas for performance.
pub const PRAGMAS: &[&str] = &[
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA cache_size = -8000",       // 8 MB cache
    "PRAGMA busy_timeout = 5000",
];
