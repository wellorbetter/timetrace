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

    // Daily diary / journal entries (multiple per day allowed)
    "CREATE TABLE IF NOT EXISTS diary_entries (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        date            TEXT    NOT NULL,
        content         TEXT    NOT NULL DEFAULT '',
        created_at      TEXT    NOT NULL,
        updated_at      TEXT    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS idx_diary_entries_date ON diary_entries(date)",
    "CREATE INDEX IF NOT EXISTS idx_diary_entries_date_id ON diary_entries(date, id)",

    // Diary images (stackable per day, overlaid on calendar cells)
    "CREATE TABLE IF NOT EXISTS diary_images (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        date            TEXT    NOT NULL,
        path            TEXT    NOT NULL,
        created_at      TEXT    NOT NULL
    )",
    "CREATE INDEX IF NOT EXISTS idx_diary_images_date ON diary_images(date)",
];

/// One-time migration for databases created before multi-entry diaries:
/// the old `diary_entries.date` was UNIQUE (one entry per day). Rebuild the
/// table without the constraint, preserving all rows.
pub const MIGRATIONS: &[&str] = &[
    // Only runs when the old unique index exists (checked in open()).
    "CREATE TABLE IF NOT EXISTS diary_entries_v2 (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        date            TEXT    NOT NULL,
        content         TEXT    NOT NULL DEFAULT '',
        created_at      TEXT    NOT NULL,
        updated_at      TEXT    NOT NULL
    )",
    "INSERT OR IGNORE INTO diary_entries_v2 (id, date, content, created_at, updated_at)
     SELECT id, date, content, COALESCE(updated_at, date || 'T00:00:00'), updated_at
     FROM diary_entries",
    "DROP TABLE diary_entries",
    "ALTER TABLE diary_entries_v2 RENAME TO diary_entries",
    "CREATE INDEX IF NOT EXISTS idx_diary_entries_date ON diary_entries(date)",
    "CREATE INDEX IF NOT EXISTS idx_diary_entries_date_id ON diary_entries(date, id)",
];

/// Enable WAL mode and set pragmas for performance.
pub const PRAGMAS: &[&str] = &[
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = ON",
    "PRAGMA cache_size = -8000",       // 8 MB cache
    "PRAGMA busy_timeout = 5000",
];
