//! SQLite implementation of `DataStore`.
//!
//! Uses `rusqlite` with bundled SQLite. All errors are logged via `tracing::warn!`
//! and operations return sensible defaults — the trait contract says infallible.

use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use chrono::{DateTime, NaiveDate, Timelike, Utc};
use rusqlite::{Connection, params};
use tracing::{debug, warn};

use crate::contracts::{
    AppMetaRecord, AppTimeoutRuleDraft, AppTimeoutRuleError, AppTimeoutRuleRecord,
    AppTimeoutRuleRepository, AppUsageSplit, AppUsageSummary, DataStore, DiaryEntryRecord,
    DiarySource, MAX_APP_TIMEOUT_DURATION_SECS, SessionRecord, StartupEntryRecord,
};
use crate::engine::app_identity::normalize_timeout_rule_path;
use crate::storage::schema;

/// Apply guarded one-time migrations. Returns Err only on real failures.
fn run_migrations(conn: &rusqlite::Connection) -> Result<(), rusqlite::Error> {
    // Migration 1: diary_entries.date was UNIQUE (one entry/day) in old DBs.
    // Rebuild the table without the constraint so multiple entries per day
    // are allowed, preserving all existing rows.
    let has_unique: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_index_list('diary_entries') WHERE \"unique\" = 1 AND origin = 'u'",
        [],
        |row| row.get(0),
    )?;
    if has_unique > 0 {
        for stmt in schema::MIGRATIONS {
            conn.execute_batch(stmt)?;
        }
        tracing::info!("diary_entries migrated: multi-entry per day");
    }

    // Migration 2: diary_images.entry_id — add column if missing + backfill.
    let has_entry_col: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('diary_images') WHERE name = 'entry_id'",
        [],
        |row| row.get(0),
    )?;
    if has_entry_col == 0 {
        for stmt in schema::MIGRATIONS_V2 {
            conn.execute_batch(stmt)?;
        }
        tracing::info!("diary_images migrated: entry_id linked");
    }
    // Always ensure the entry index exists (fresh DBs + migrated).
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_diary_images_entry ON diary_images(entry_id)",
    )?;

    // Migration 3: diary_entries.status — add column if missing.
    let has_status: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('diary_entries') WHERE name = 'status'",
        [],
        |row| row.get(0),
    )?;
    if has_status == 0 {
        for stmt in schema::MIGRATIONS_V3 {
            conn.execute_batch(stmt)?;
        }
        tracing::info!("diary_entries migrated: status column");
    }

    // Migration 4: diary provenance and optional source model. These columns
    // are additive so entry ids, timestamps, publication status, and image
    // links remain untouched.
    let has_source: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('diary_entries') WHERE name = 'source'",
        [],
        |row| row.get(0),
    )?;
    if has_source == 0 {
        conn.execute_batch(schema::MIGRATIONS_V4[0])?;
        tracing::info!("diary_entries migrated: source column");
    }
    let has_source_model: i64 = conn.query_row(
        "SELECT COUNT(*) FROM pragma_table_info('diary_entries') WHERE name = 'source_model'",
        [],
        |row| row.get(0),
    )?;
    if has_source_model == 0 {
        conn.execute_batch(schema::MIGRATIONS_V4[1])?;
        tracing::info!("diary_entries migrated: source_model column");
    }

    // Migration 5: rule storage is additive and deliberately idempotent. It
    // is not coupled to historical usage cleanup or diary migrations.
    conn.execute_batch(schema::MIGRATIONS_V5)?;
    Ok(())
}

/// Split a session [start, end) across hour-of-day buckets (local time).
/// An hour never exceeds 60 minutes even for long sessions.
fn add_session_to_hours(hours: &mut [i64; 24], start: DateTime<Utc>, end: DateTime<Utc>) {
    let start_local = start.with_timezone(&chrono::Local);
    let end_local = end.with_timezone(&chrono::Local);
    let mut cur = start_local;
    while cur < end_local {
        let h = cur.hour() as usize;
        if h >= 24 {
            break;
        }
        let next_hour = cur
            .with_minute(0)
            .and_then(|c| c.with_second(0))
            .map(|c| c + chrono::Duration::hours(1))
            .unwrap_or(end_local);
        let seg_end = end_local.min(next_hour);
        let seg = (seg_end - cur).num_seconds().max(0);
        hours[h] += seg;
        cur = next_hour;
    }
}

pub struct SqliteStore {
    conn: Mutex<Connection>,
    degraded: AtomicBool,
}

impl SqliteStore {
    /// Open (or create) the SQLite database at the given path.
    pub fn open(path: PathBuf) -> Result<Self, rusqlite::Error> {
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }

        let conn = Connection::open(&path)?;

        // Apply pragmas
        for pragma in schema::PRAGMAS {
            conn.execute_batch(pragma)?;
        }

        // Run schema DDL
        for ddl in schema::CREATE_TABLES {
            conn.execute_batch(ddl)?;
        }

        // Run one-time migrations (guarded).
        run_migrations(&conn)?;

        debug!("SQLite opened at {}", path.display());

        Ok(Self {
            conn: Mutex::new(conn),
            degraded: AtomicBool::new(false),
        })
    }

    /// Whether any read operation has had to use its degraded fallback.
    pub fn is_degraded(&self) -> bool {
        self.degraded.load(Ordering::Relaxed)
    }

    fn mark_degraded(&self) {
        self.degraded.store(true, Ordering::Relaxed);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        match self.conn.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                warn!("SQLite connection mutex poisoned; recovering connection guard");
                poisoned.into_inner()
            }
        }
    }
}

impl DataStore for SqliteStore {
    // ── Session CRUD ──

    fn insert_session(&self, session: &SessionRecord) -> i64 {
        let conn = self.lock();
        match conn.execute(
            "INSERT INTO usage_sessions (app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                session.app_path,
                session.app_name,
                session.window_title,
                session.started_at.to_rfc3339(),
                session.ended_at.map(|t| t.to_rfc3339()),
                session.duration_secs,
                session.is_idle as i32,
                session.date.to_string(),
            ],
        ) {
            Ok(_) => conn.last_insert_rowid(),
            Err(e) => {
                warn!("Failed to insert session: {e}");
                -1
            }
        }
    }

    fn close_session(&self, id: i64, end_time: DateTime<Utc>) {
        let conn = self.lock();
        if let Ok(started_at_str) = conn.query_row(
            "SELECT started_at FROM usage_sessions WHERE id = ?1",
            params![id],
            |row| row.get::<_, String>(0),
        ) {
            if let Ok(started_at) = DateTime::parse_from_rfc3339(&started_at_str) {
                let duration = (end_time - started_at.with_timezone(&Utc))
                    .num_seconds()
                    .max(0);
                if let Err(e) = conn.execute(
                    "UPDATE usage_sessions SET ended_at = ?1, duration_secs = ?2 WHERE id = ?3",
                    params![end_time.to_rfc3339(), duration, id],
                ) {
                    warn!("Failed to close session {id}: {e}");
                }
            }
        }
    }

    fn get_active_session(&self) -> Option<SessionRecord> {
        let conn = self.lock();
        conn.query_row(
            "SELECT id, app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date
             FROM usage_sessions WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1",
            [],
            |row| Self::row_to_session(row),
        )
        .ok()
    }

    // ── Queries ──

    fn get_sessions_by_date(&self, date: NaiveDate) -> Vec<SessionRecord> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
                "SELECT id, app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date
                 FROM usage_sessions WHERE date = ?1 ORDER BY started_at",
            ) {
            Ok(stmt) => stmt,
            Err(e) => { warn!("Failed to prepare sessions-by-date query: {e}"); self.mark_degraded(); return Vec::new(); }
        };
        let rows = match stmt.query_map(params![date.to_string()], |row| Self::row_to_session(row))
        {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query sessions by date: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok()).collect()
    }

    fn get_sessions_by_range(&self, start: NaiveDate, end: NaiveDate) -> Vec<SessionRecord> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
                "SELECT id, app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date
                 FROM usage_sessions WHERE date >= ?1 AND date <= ?2 ORDER BY started_at",
            ) {
            Ok(stmt) => stmt,
            Err(e) => { warn!("Failed to prepare sessions-by-range query: {e}"); self.mark_degraded(); return Vec::new(); }
        };
        let rows = match stmt.query_map(params![start.to_string(), end.to_string()], |row| {
            Self::row_to_session(row)
        }) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query sessions by range: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok()).collect()
    }

    fn get_daily_summary(&self, date: NaiveDate) -> Vec<AppUsageSummary> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
            "SELECT app_name, COALESCE(SUM(duration_secs), 0) as total, COUNT(*) as sessions
                 FROM usage_sessions WHERE date = ?1 AND is_idle = 0 AND duration_secs IS NOT NULL
                 GROUP BY app_name ORDER BY total DESC",
        ) {
            Ok(stmt) => stmt,
            Err(e) => {
                warn!("Failed to prepare daily summary query: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        let rows = match stmt.query_map(params![date.to_string()], |row| {
            Ok(AppUsageSummary {
                app_name: row.get(0)?,
                total_seconds: row.get(1)?,
                session_count: row.get::<_, i64>(2)? as i64,
                rank: 0,
            })
        }) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query daily summary: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok())
            .enumerate()
            .map(|(i, mut s)| {
                s.rank = i + 1;
                s
            })
            .collect()
    }

    fn get_top_apps(&self, start: NaiveDate, end: NaiveDate, limit: usize) -> Vec<AppUsageSummary> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
            "SELECT app_name, COALESCE(SUM(duration_secs), 0) as total, COUNT(*) as sessions
                 FROM usage_sessions
                 WHERE date >= ?1 AND date <= ?2 AND is_idle = 0 AND duration_secs > 0
                 GROUP BY app_name
                 ORDER BY total DESC
                 LIMIT ?3",
        ) {
            Ok(stmt) => stmt,
            Err(e) => {
                warn!("Failed to prepare top apps query: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        let rows = match stmt.query_map(
            params![start.to_string(), end.to_string(), limit as i64],
            |row| {
                Ok(AppUsageSummary {
                    app_name: row.get(0)?,
                    total_seconds: row.get(1)?,
                    session_count: row.get(2)?,
                    rank: 0,
                })
            },
        ) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query top apps: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok())
            .enumerate()
            .map(|(i, mut s)| {
                s.rank = i + 1;
                s
            })
            .collect()
    }

    fn get_usage_split(&self, start: NaiveDate, end: NaiveDate) -> Vec<AppUsageSplit> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
            "SELECT app_name, MAX(app_path),
                    COALESCE(SUM(CASE WHEN is_idle = 0 THEN duration_secs ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN is_idle = 1 THEN duration_secs ELSE 0 END), 0)
             FROM usage_sessions
             WHERE date >= ?1 AND date <= ?2 AND duration_secs > 0 AND app_name != '__IDLE__'
             GROUP BY app_name ORDER BY 3 DESC",
        ) {
            Ok(stmt) => stmt,
            Err(e) => {
                warn!("Failed to prepare usage split query: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        let rows = match stmt.query_map(params![start.to_string(), end.to_string()], |row| {
            Ok(AppUsageSplit {
                app_name: row.get(0)?,
                exe_path: row.get(1)?,
                active_seconds: row.get(2)?,
                idle_seconds: row.get(3)?,
            })
        }) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query usage split: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok()).collect()
    }

    fn get_window_titles(&self, app_name: &str, date: NaiveDate) -> Vec<(String, i64)> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
            "SELECT COALESCE(window_title, ''), COALESCE(SUM(duration_secs), 0)
             FROM page_visits
             WHERE app_name = ?1 AND date = ?2 AND duration_secs > 0
             GROUP BY window_title ORDER BY SUM(duration_secs) DESC",
        ) {
            Ok(stmt) => stmt,
            Err(e) => {
                warn!("Failed to prepare window titles query: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        let rows = match stmt.query_map(params![app_name, date.to_string()], |row| {
            Ok((row.get(0)?, row.get(1)?))
        }) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query window titles: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok()).collect()
    }

    fn start_page_visit(
        &self,
        session_id: i64,
        app_name: &str,
        title: Option<&str>,
        started_at: DateTime<Utc>,
        date: NaiveDate,
    ) -> i64 {
        let conn = self.lock();
        match conn.execute(
            "INSERT INTO page_visits (session_id, app_name, window_title, started_at, ended_at, duration_secs, date)
             VALUES (?1, ?2, ?3, ?4, NULL, NULL, ?5)",
            params![session_id, app_name, title, started_at.to_rfc3339(), date.to_string()],
        ) {
            Ok(_) => conn.last_insert_rowid(),
            Err(e) => { warn!("page visit insert failed: {e}"); -1 }
        }
    }

    fn close_page_visit(&self, visit_id: i64, end_time: DateTime<Utc>) {
        if visit_id < 0 {
            return;
        }
        let conn = self.lock();
        if let Ok(started_str) = conn.query_row(
            "SELECT started_at FROM page_visits WHERE id = ?1",
            params![visit_id],
            |row| row.get::<_, String>(0),
        ) {
            if let Ok(start) = DateTime::parse_from_rfc3339(&started_str) {
                let dur = (end_time - start.with_timezone(&Utc)).num_seconds();
                if dur > 0 {
                    let _ = conn.execute(
                        "UPDATE page_visits SET ended_at = ?1, duration_secs = ?2 WHERE id = ?3",
                        params![end_time.to_rfc3339(), dur, visit_id],
                    );
                }
            }
        }
    }

    // ── Startup CRUD ──

    fn upsert_startup_entries(&self, entries: &[StartupEntryRecord]) {
        let conn = self.lock();
        for entry in entries {
            let _ = conn.execute(
                "INSERT INTO startup_entries (name, command, source, enabled, backup_value, backup_path, first_seen, last_checked)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                    command = excluded.command,
                    last_checked = excluded.last_checked",
                params![
                    entry.name,
                    entry.command,
                    entry.source,
                    entry.enabled as i32,
                    entry.backup_value,
                    entry.backup_path,
                    entry.first_seen.to_rfc3339(),
                    entry.last_checked.to_rfc3339(),
                ],
            );
        }
    }

    fn get_all_startup_entries(&self) -> Vec<StartupEntryRecord> {
        let conn = self.lock();
        let mut stmt = match conn.prepare(
                "SELECT id, name, command, source, enabled, backup_value, backup_path, first_seen, last_checked
                 FROM startup_entries ORDER BY source, name",
            ) {
            Ok(stmt) => stmt,
            Err(e) => { warn!("Failed to prepare startup entries query: {e}"); self.mark_degraded(); return Vec::new(); }
        };
        let rows = match stmt.query_map([], |row| {
            Ok(StartupEntryRecord {
                id: row.get(0)?,
                name: row.get(1)?,
                command: row.get(2)?,
                source: row.get(3)?,
                enabled: row.get::<_, i32>(4)? != 0,
                backup_value: row.get(5)?,
                backup_path: row.get(6)?,
                first_seen: parse_dt(row.get::<_, String>(7)?),
                last_checked: parse_dt(row.get::<_, String>(8)?),
            })
        }) {
            Ok(rows) => rows,
            Err(e) => {
                warn!("Failed to query startup entries: {e}");
                self.mark_degraded();
                return Vec::new();
            }
        };
        rows.filter_map(|r| r.ok()).collect()
    }

    fn set_startup_enabled(
        &self,
        id: i64,
        enabled: bool,
        backup: Option<&str>,
        backup_path: Option<&str>,
    ) {
        let conn = self.lock();
        let _ = conn.execute(
            "UPDATE startup_entries SET enabled = ?1, backup_value = ?2, backup_path = ?3 WHERE id = ?4",
            params![enabled as i32, backup, backup_path, id],
        );
    }

    // ── App Metadata ──

    fn get_app_meta(&self, exe_path: &str) -> Option<AppMetaRecord> {
        let conn = self.lock();
        conn.query_row(
            "SELECT app_path, display_name, category, is_productive FROM app_metadata WHERE app_path = ?1",
            params![exe_path],
            |row| {
                Ok(AppMetaRecord {
                    app_path: row.get(0)?,
                    display_name: row.get(1)?,
                    category: row.get(2)?,
                    is_productive: row.get::<_, Option<i32>>(3)?.map(|v| v != 0),
                })
            },
        )
        .ok()
    }

    fn set_app_meta(&self, meta: &AppMetaRecord) {
        let conn = self.lock();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO app_metadata (app_path, display_name, category, is_productive)
             VALUES (?1, ?2, ?3, ?4)",
            params![
                meta.app_path,
                meta.display_name,
                meta.category,
                meta.is_productive.map(|v| v as i32),
            ],
        );
    }

    // ── Recording Stats ──

    fn recording_started_at(&self) -> Option<DateTime<Utc>> {
        let conn = self.lock();
        conn.query_row(
            "SELECT started_at FROM usage_sessions ORDER BY started_at ASC LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .ok()
        .map(|s| parse_dt(s))
    }

    fn total_tracked_seconds(&self) -> i64 {
        let conn = self.lock();
        conn.query_row(
            "SELECT COALESCE(SUM(duration_secs), 0) FROM usage_sessions WHERE is_idle = 0 AND duration_secs IS NOT NULL",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0)
    }

    fn total_tracked_in_range(&self, start: NaiveDate, end: NaiveDate) -> i64 {
        let conn = self.lock();
        conn.query_row(
            "SELECT COALESCE(SUM(duration_secs), 0) FROM usage_sessions WHERE is_idle = 0 AND duration_secs IS NOT NULL AND date >= ?1 AND date <= ?2",
            params![start.to_string(), end.to_string()],
            |row| row.get(0),
        )
        .unwrap_or(0)
    }

    // ── Maintenance ──

    fn cleanup_old_sessions(&self, before: NaiveDate) {
        let conn = self.lock();
        if let Err(e) = conn.execute(
            "DELETE FROM usage_sessions WHERE date < ?1",
            params![before.to_string()],
        ) {
            warn!("Failed to cleanup old sessions: {e}");
        }
    }

    fn vacuum(&self) {
        let conn = self.lock();
        if let Err(e) = conn.execute_batch("PRAGMA optimize; VACUUM;") {
            warn!("Failed to vacuum: {e}");
        }
    }

    fn clear_all_data(&self) {
        let conn = self.lock();
        let _ = conn.execute_batch("DELETE FROM usage_sessions; DELETE FROM page_visits;");
    }

    fn get_diary_entries(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String)> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT date, content FROM diary_entries WHERE date >= ?1 AND date <= ?2 AND status = 'published' ORDER BY date"
        ) {
            if let Ok(rows) = stmt.query_map(params![start.to_string(), end.to_string()], |row| {
                Ok((row.get(0)?, row.get(1)?))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn get_diary(&self, date: NaiveDate) -> Option<String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT content FROM diary_entries WHERE date = ?1 AND status = 'published' ORDER BY id DESC LIMIT 1",
            params![date.to_string()],
            |row| row.get::<_, String>(0),
        )
        .ok()
    }

    fn set_diary(&self, date: NaiveDate, content: &str) -> String {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO diary_entries (date, content, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?3)
             ON CONFLICT(id) DO UPDATE SET content = excluded.content, updated_at = excluded.updated_at",
            params![date.to_string(), content, now],
        );
        content.to_string()
    }

    // ── Multi-entry diary API ──

    fn get_diary_entries_detailed(
        &self,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Vec<DiaryEntryRecord> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT id, date, content, status, source, source_model FROM diary_entries
             WHERE date >= ?1 AND date <= ?2 ORDER BY date DESC, id DESC",
        ) {
            if let Ok(rows) = stmt.query_map(params![start.to_string(), end.to_string()], |row| {
                let source = row.get::<_, String>(4)?;
                Ok(DiaryEntryRecord {
                    id: row.get(0)?,
                    date: row.get(1)?,
                    content: row.get(2)?,
                    status: row.get(3)?,
                    source: DiarySource::from_stored(&source),
                    source_model: row.get(5)?,
                })
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn add_diary_entry(&self, date: NaiveDate, content: &str) -> i64 {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO diary_entries (date, content, created_at, updated_at, status)
             VALUES (?1, ?2, ?3, ?3, 'published')",
            params![date.to_string(), content, now],
        );
        conn.last_insert_rowid()
    }

    /// Autosave a draft for a date (one draft per day) — returns its id.
    fn save_diary_draft(&self, date: NaiveDate, content: &str) -> i64 {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        // Reuse the existing draft for the day if present.
        if let Ok(existing) = conn.query_row(
            "SELECT id FROM diary_entries WHERE date = ?1 AND status = 'draft' ORDER BY id LIMIT 1",
            params![date.to_string()],
            |row| row.get::<_, i64>(0),
        ) {
            let _ = conn.execute(
                "UPDATE diary_entries SET content = ?1, updated_at = ?2 WHERE id = ?3",
                params![content, now, existing],
            );
            return existing;
        }
        let _ = conn.execute(
            "INSERT INTO diary_entries (date, content, created_at, updated_at, status)
             VALUES (?1, ?2, ?3, ?3, 'draft')",
            params![date.to_string(), content, now],
        );
        conn.last_insert_rowid()
    }

    /// Publish: promote the day's draft (or insert a new published entry).
    fn publish_diary(&self, date: NaiveDate, content: &str) -> i64 {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        if let Ok(existing) = conn.query_row(
            "SELECT id FROM diary_entries WHERE date = ?1 AND status = 'draft' ORDER BY id LIMIT 1",
            params![date.to_string()],
            |row| row.get::<_, i64>(0),
        ) {
            let _ = conn.execute(
                "UPDATE diary_entries SET content = ?1, updated_at = ?2, status = 'published' WHERE id = ?3",
                params![content, now, existing],
            );
            return existing;
        }
        let _ = conn.execute(
            "INSERT INTO diary_entries (date, content, created_at, updated_at, status)
             VALUES (?1, ?2, ?3, ?3, 'published')",
            params![date.to_string(), content, now],
        );
        conn.last_insert_rowid()
    }

    fn publish_ai_diary(
        &self,
        date: NaiveDate,
        content: &str,
        source_model: &str,
    ) -> Result<i64, String> {
        if content.trim().is_empty() {
            return Err("AI diary content must not be empty".to_string());
        }
        if source_model.trim().is_empty() {
            return Err("AI diary source model must not be empty".to_string());
        }

        let mut conn = self.lock();
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO diary_entries
                (date, content, created_at, updated_at, status, source, source_model)
             VALUES (?1, ?2, ?3, ?3, 'published', 'ai_generated', ?4)",
            params![date.to_string(), content, now, source_model.trim()],
        )
        .map_err(|e| e.to_string())?;
        let id = tx.last_insert_rowid();
        tx.commit().map_err(|e| e.to_string())?;
        Ok(id)
    }

    /// The day's draft content, if any.
    fn get_diary_draft(&self, date: NaiveDate) -> Option<String> {
        let conn = self.lock();
        conn.query_row(
            "SELECT content FROM diary_entries WHERE date = ?1 AND status = 'draft' ORDER BY id LIMIT 1",
            params![date.to_string()],
            |row| row.get::<_, String>(0),
        )
        .ok()
    }

    fn update_diary_entry(&self, id: i64, content: &str) -> Result<(), String> {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        conn.execute(
            "UPDATE diary_entries
             SET content = ?1,
                 updated_at = ?2,
                 source = CASE
                     WHEN source = 'ai_generated' THEN 'ai_assisted'
                     ELSE source
                 END
             WHERE id = ?3",
            params![content, now, id],
        )
        .and_then(|changed| {
            if changed == 0 {
                Err(rusqlite::Error::QueryReturnedNoRows)
            } else {
                Ok(())
            }
        })
        .map_err(|e| e.to_string())
    }

    fn delete_diary_entry(&self, id: i64) -> Result<(), String> {
        let conn = self.lock();
        conn.execute("DELETE FROM diary_entries WHERE id = ?1", params![id])
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    fn get_day_hourly(&self, date: NaiveDate) -> Vec<i64> {
        let conn = self.lock();
        let mut hours = vec![0i64; 24];
        if let Ok(mut stmt) = conn.prepare(
            "SELECT started_at, duration_secs FROM usage_sessions
             WHERE date = ?1 AND is_idle = 0 AND duration_secs > 0",
        ) {
            if let Ok(rows) = stmt.query_map(params![date.to_string()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            }) {
                for row in rows.flatten() {
                    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&row.0) {
                        let start = dt.with_timezone(&chrono::Local);
                        let end = start + chrono::Duration::seconds(row.1);
                        // Split the session across hour buckets so an
                        // hour never exceeds 60 minutes (was: whole session
                        // counted into its start hour → e.g. "9时 · 79分").
                        let mut cur = start;
                        while cur < end {
                            let h = cur.hour() as usize;
                            if h >= 24 {
                                break;
                            }
                            let next_hour = cur
                                .with_minute(0)
                                .and_then(|c| c.with_second(0))
                                .map(|c| c + chrono::Duration::hours(1))
                                .unwrap_or(end);
                            let seg_end = end.min(next_hour);
                            let seg = (seg_end - cur).num_seconds().max(0);
                            hours[h] += seg;
                            cur = next_hour;
                        }
                    }
                }
            }
        }
        hours
    }

    fn get_hour_apps(&self, date: NaiveDate, hour: u32) -> Vec<(String, i64)> {
        let conn = self.lock();
        let mut acc: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT app_name, started_at, duration_secs FROM usage_sessions
             WHERE date = ?1 AND is_idle = 0 AND duration_secs > 0",
        ) {
            if let Ok(rows) = stmt.query_map(params![date.to_string()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            }) {
                for row in rows.flatten() {
                    let (app, started, dur) = row;
                    if let Ok(dt) = DateTime::parse_from_rfc3339(&started) {
                        let start = dt.with_timezone(&Utc);
                        let end = start + chrono::Duration::seconds(dur);
                        let mut buckets = [0i64; 24];
                        add_session_to_hours(&mut buckets, start, end);
                        let secs = buckets.get(hour as usize).copied().unwrap_or(0);
                        if secs > 0 {
                            *acc.entry(app).or_insert(0) += secs;
                        }
                    }
                }
            }
        }
        let mut out: Vec<(String, i64)> = acc.into_iter().collect();
        out.sort_by(|a, b| b.1.cmp(&a.1));
        out
    }

    fn get_app_hourly(&self, app_name: &str, date: NaiveDate) -> Vec<i64> {
        let conn = self.lock();
        let mut hours = [0i64; 24];
        if let Ok(mut stmt) = conn.prepare(
            "SELECT started_at, duration_secs FROM usage_sessions
             WHERE app_name = ?1 AND date = ?2 AND is_idle = 0 AND duration_secs > 0",
        ) {
            if let Ok(rows) = stmt.query_map(params![app_name, date.to_string()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            }) {
                for row in rows.flatten() {
                    if let Ok(parsed) = DateTime::parse_from_rfc3339(&row.0) {
                        let start = parsed.with_timezone(&Utc);
                        let end = start + chrono::Duration::seconds(row.1);
                        add_session_to_hours(&mut hours, start, end);
                    }
                }
            }
        }
        hours.to_vec()
    }

    fn get_diary_images(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String)> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT date, path FROM diary_images WHERE date >= ?1 AND date <= ?2 ORDER BY id",
        ) {
            if let Ok(rows) = stmt.query_map(params![start.to_string(), end.to_string()], |row| {
                Ok((row.get(0)?, row.get(1)?))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn get_diary_images_detailed(
        &self,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Vec<(String, Option<i64>, String)> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT date, entry_id, path FROM diary_images WHERE date >= ?1 AND date <= ?2 ORDER BY id",
        ) {
            if let Ok(rows) = stmt.query_map(params![start.to_string(), end.to_string()], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn add_diary_image(&self, date: NaiveDate, path: &str) -> String {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO diary_images (date, path, created_at) VALUES (?1, ?2, ?3)",
            params![date.to_string(), path, now],
        );
        path.to_string()
    }

    fn set_diary_image_entry(&self, path: &str, entry_id: i64) -> Result<(), String> {
        let conn = self.lock();
        conn.execute(
            "UPDATE diary_images SET entry_id = ?2 WHERE path = ?1",
            params![path, entry_id],
        )
        .map(|_| ())
        .map_err(|e| e.to_string())
    }

    fn get_diary_images_for_entry(&self, entry_id: i64) -> Vec<String> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) =
            conn.prepare("SELECT path FROM diary_images WHERE entry_id = ?1 ORDER BY id")
        {
            if let Ok(rows) = stmt.query_map(params![entry_id], |row| row.get::<_, String>(0)) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn remove_diary_image(&self, path: &str) {
        let conn = self.lock();
        let _ = conn.execute("DELETE FROM diary_images WHERE path = ?1", params![path]);
    }

    fn get_day_sessions(&self, date: NaiveDate) -> Vec<(String, bool, i64, String)> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT app_name, is_idle, COALESCE(duration_secs, 0), started_at
             FROM usage_sessions WHERE date = ?1 AND duration_secs > 0 ORDER BY started_at",
        ) {
            if let Ok(rows) = stmt.query_map(params![date.to_string()], |row| {
                Ok((
                    row.get(0)?,
                    row.get::<_, i32>(1)? != 0,
                    row.get(2)?,
                    row.get(3)?,
                ))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    fn export_rows(&self, start: NaiveDate, end: NaiveDate) -> Vec<(String, String, i64, i64)> {
        let conn = self.lock();
        let mut out = Vec::new();
        if let Ok(mut stmt) = conn.prepare(
            "SELECT app_name, date,
                    COALESCE(SUM(CASE WHEN is_idle = 0 THEN duration_secs ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN is_idle = 1 THEN duration_secs ELSE 0 END), 0)
             FROM usage_sessions
             WHERE date >= ?1 AND date <= ?2 AND app_name != '__IDLE__'
             GROUP BY app_name, date ORDER BY date",
        ) {
            if let Ok(rows) = stmt.query_map(params![start.to_string(), end.to_string()], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }
}

impl AppTimeoutRuleRepository for SqliteStore {
    fn list_rules(&self) -> Result<Vec<AppTimeoutRuleRecord>, AppTimeoutRuleError> {
        let conn = self.lock();
        let mut statement = conn
            .prepare(
                "SELECT id, app_path, app_name, threshold_secs, cooldown_secs,
                        enabled, notify_repeatedly, created_at, updated_at
                 FROM app_timeout_rules
                 ORDER BY app_name COLLATE NOCASE, id",
            )
            .map_err(|error| {
                warn!("Failed to prepare timeout rule list query: {error}");
                AppTimeoutRuleError::Storage
            })?;
        let rows = statement
            .query_map([], Self::row_to_timeout_rule)
            .map_err(|error| {
                warn!("Failed to query timeout rules: {error}");
                AppTimeoutRuleError::Storage
            })?;

        let mut rules = Vec::new();
        for row in rows {
            match row {
                Ok(rule) => rules.push(rule),
                Err(error) => {
                    warn!("Failed to decode a timeout rule: {error}");
                    return Err(AppTimeoutRuleError::Storage);
                }
            }
        }
        Ok(rules)
    }

    fn upsert_rule(
        &self,
        draft: &AppTimeoutRuleDraft,
    ) -> Result<AppTimeoutRuleRecord, AppTimeoutRuleError> {
        let app_path = normalize_timeout_rule_path(&draft.app_path)
            .map_err(|_| AppTimeoutRuleError::InvalidPath)?;
        let app_name = draft.app_name.trim();
        if app_name.is_empty() {
            return Err(AppTimeoutRuleError::EmptyAppName);
        }
        if !(1..=MAX_APP_TIMEOUT_DURATION_SECS).contains(&draft.threshold_secs)
            || !(1..=MAX_APP_TIMEOUT_DURATION_SECS).contains(&draft.cooldown_secs)
        {
            return Err(AppTimeoutRuleError::InvalidDuration);
        }

        let now = Utc::now().to_rfc3339();
        let mut conn = self.lock();
        let transaction = conn.transaction().map_err(|error| {
            warn!("Failed to start timeout rule transaction: {error}");
            AppTimeoutRuleError::Storage
        })?;
        transaction
            .execute(
                "INSERT INTO app_timeout_rules
                    (app_path, app_name, threshold_secs, cooldown_secs, enabled,
                     notify_repeatedly, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
                 ON CONFLICT(app_path) DO UPDATE SET
                    app_name = excluded.app_name,
                    threshold_secs = excluded.threshold_secs,
                    cooldown_secs = excluded.cooldown_secs,
                    enabled = excluded.enabled,
                    notify_repeatedly = excluded.notify_repeatedly,
                    updated_at = excluded.updated_at",
                params![
                    app_path,
                    app_name,
                    draft.threshold_secs,
                    draft.cooldown_secs,
                    i64::from(draft.enabled),
                    i64::from(draft.notify_repeatedly),
                    now,
                ],
            )
            .map_err(|error| {
                warn!("Failed to upsert timeout rule: {error}");
                AppTimeoutRuleError::Storage
            })?;

        let rule = transaction
            .query_row(
                "SELECT id, app_path, app_name, threshold_secs, cooldown_secs,
                        enabled, notify_repeatedly, created_at, updated_at
                 FROM app_timeout_rules WHERE app_path = ?1",
                params![app_path],
                Self::row_to_timeout_rule,
            )
            .map_err(|error| {
                warn!("Failed to read timeout rule after upsert: {error}");
                AppTimeoutRuleError::Storage
            })?;
        transaction.commit().map_err(|error| {
            warn!("Failed to commit timeout rule upsert: {error}");
            AppTimeoutRuleError::Storage
        })?;
        Ok(rule)
    }

    fn delete_rule(&self, id: i64) -> Result<(), AppTimeoutRuleError> {
        let conn = self.lock();
        let changed = conn
            .execute("DELETE FROM app_timeout_rules WHERE id = ?1", params![id])
            .map_err(|error| {
                warn!("Failed to delete timeout rule: {error}");
                AppTimeoutRuleError::Storage
            })?;
        if changed == 0 {
            return Err(AppTimeoutRuleError::NotFound);
        }
        Ok(())
    }
}

// ── Internal helpers ──

impl SqliteStore {
    fn row_to_session(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRecord> {
        Ok(SessionRecord {
            id: row.get(0)?,
            app_path: row.get(1)?,
            app_name: row.get(2)?,
            window_title: row.get(3)?,
            started_at: parse_dt(row.get::<_, String>(4)?),
            ended_at: row.get::<_, Option<String>>(5)?.map(parse_dt),
            duration_secs: row.get(6)?,
            is_idle: row.get::<_, i32>(7)? != 0,
            date: NaiveDate::parse_from_str(&row.get::<_, String>(8)?, "%Y-%m-%d")
                .unwrap_or_default(),
        })
    }

    fn row_to_timeout_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<AppTimeoutRuleRecord> {
        Ok(AppTimeoutRuleRecord {
            id: row.get(0)?,
            app_path: row.get(1)?,
            app_name: row.get(2)?,
            threshold_secs: row.get(3)?,
            cooldown_secs: row.get(4)?,
            enabled: row.get::<_, i64>(5)? != 0,
            notify_repeatedly: row.get::<_, i64>(6)? != 0,
            created_at: parse_dt(row.get(7)?),
            updated_at: parse_dt(row.get(8)?),
        })
    }
}

fn parse_dt(s: String) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(&s)
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or_default()
}

// ── In-memory store for testing ──

/// In-memory implementation of `DataStore` for unit tests and UI prototyping.
#[cfg(test)]
pub struct MemoryStore {
    sessions: Mutex<Vec<SessionRecord>>,
    startups: Mutex<Vec<StartupEntryRecord>>,
    metas: Mutex<Vec<AppMetaRecord>>,
    next_id: Mutex<i64>,
}

#[cfg(test)]
impl MemoryStore {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(Vec::new()),
            startups: Mutex::new(Vec::new()),
            metas: Mutex::new(Vec::new()),
            next_id: Mutex::new(1),
        }
    }

    fn lock<'a, T>(mutex: &'a Mutex<T>) -> std::sync::MutexGuard<'a, T> {
        match mutex.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[cfg(test)]
impl DataStore for MemoryStore {
    fn insert_session(&self, session: &SessionRecord) -> i64 {
        let mut sessions = Self::lock(&self.sessions);
        let mut next_id = Self::lock(&self.next_id);
        let id = *next_id;
        *next_id += 1;
        let mut s = session.clone();
        s.id = id;
        sessions.push(s);
        id
    }

    fn close_session(&self, id: i64, end_time: DateTime<Utc>) {
        let mut sessions = Self::lock(&self.sessions);
        if let Some(s) = sessions.iter_mut().find(|s| s.id == id) {
            s.ended_at = Some(end_time);
            s.duration_secs = Some((end_time - s.started_at).num_seconds());
        }
    }

    fn get_active_session(&self) -> Option<SessionRecord> {
        Self::lock(&self.sessions)
            .iter()
            .rev()
            .find(|s| s.ended_at.is_none())
            .cloned()
    }

    fn get_sessions_by_date(&self, date: NaiveDate) -> Vec<SessionRecord> {
        Self::lock(&self.sessions)
            .iter()
            .filter(|s| s.date == date)
            .cloned()
            .collect()
    }

    fn get_sessions_by_range(&self, start: NaiveDate, end: NaiveDate) -> Vec<SessionRecord> {
        Self::lock(&self.sessions)
            .iter()
            .filter(|s| s.date >= start && s.date <= end)
            .cloned()
            .collect()
    }

    fn get_daily_summary(&self, _date: NaiveDate) -> Vec<AppUsageSummary> {
        vec![] // Simplified for testing; real logic in SqliteStore
    }

    fn get_top_apps(
        &self,
        _start: NaiveDate,
        _end: NaiveDate,
        _limit: usize,
    ) -> Vec<AppUsageSummary> {
        vec![]
    }

    fn get_usage_split(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<AppUsageSplit> {
        vec![]
    }

    fn start_page_visit(
        &self,
        _session_id: i64,
        _app_name: &str,
        _title: Option<&str>,
        _started_at: DateTime<Utc>,
        _date: NaiveDate,
    ) -> i64 {
        -1
    }

    fn close_page_visit(&self, _visit_id: i64, _end_time: DateTime<Utc>) {}

    fn get_window_titles(&self, app_name: &str, _date: NaiveDate) -> Vec<(String, i64)> {
        Self::lock(&self.sessions)
            .iter()
            .filter(|s| s.app_name == app_name && !s.is_idle)
            .filter_map(|s| {
                s.duration_secs
                    .map(|d| (s.window_title.clone().unwrap_or_default(), d))
            })
            .fold(std::collections::HashMap::new(), |mut acc, (title, dur)| {
                *acc.entry(title).or_insert(0) += dur;
                acc
            })
            .into_iter()
            .collect()
    }

    fn upsert_startup_entries(&self, entries: &[StartupEntryRecord]) {
        let mut startups = Self::lock(&self.startups);
        for e in entries {
            startups.push(e.clone());
        }
    }

    fn get_all_startup_entries(&self) -> Vec<StartupEntryRecord> {
        Self::lock(&self.startups).clone()
    }

    fn set_startup_enabled(
        &self,
        id: i64,
        enabled: bool,
        backup: Option<&str>,
        backup_path: Option<&str>,
    ) {
        let mut startups = Self::lock(&self.startups);
        if let Some(e) = startups.iter_mut().find(|e| e.id == id) {
            e.enabled = enabled;
            if let Some(v) = backup {
                e.backup_value = Some(v.to_string());
            }
            if let Some(p) = backup_path {
                e.backup_path = Some(p.to_string());
            }
        }
    }

    fn get_app_meta(&self, exe_path: &str) -> Option<AppMetaRecord> {
        Self::lock(&self.metas)
            .iter()
            .find(|m| m.app_path == exe_path)
            .cloned()
    }

    fn set_app_meta(&self, meta: &AppMetaRecord) {
        let mut metas = Self::lock(&self.metas);
        if let Some(existing) = metas.iter_mut().find(|m| m.app_path == meta.app_path) {
            *existing = meta.clone();
        } else {
            metas.push(meta.clone());
        }
    }

    fn recording_started_at(&self) -> Option<DateTime<Utc>> {
        Self::lock(&self.sessions)
            .iter()
            .min_by_key(|s| s.started_at)
            .map(|s| s.started_at)
    }

    fn total_tracked_seconds(&self) -> i64 {
        Self::lock(&self.sessions)
            .iter()
            .filter(|s| !s.is_idle)
            .filter_map(|s| s.duration_secs)
            .sum()
    }

    fn total_tracked_in_range(&self, start: NaiveDate, end: NaiveDate) -> i64 {
        Self::lock(&self.sessions)
            .iter()
            .filter(|s| !s.is_idle && s.date >= start && s.date <= end)
            .filter_map(|s| s.duration_secs)
            .sum()
    }

    fn cleanup_old_sessions(&self, before: NaiveDate) {
        Self::lock(&self.sessions).retain(|s| s.date >= before);
    }

    fn vacuum(&self) {}

    fn clear_all_data(&self) {
        Self::lock(&self.sessions).clear();
    }

    fn export_rows(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<(String, String, i64, i64)> {
        vec![]
    }

    fn get_diary_entries(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<(String, String)> {
        vec![]
    }

    fn get_diary(&self, _date: NaiveDate) -> Option<String> {
        None
    }

    fn set_diary(&self, _date: NaiveDate, content: &str) -> String {
        content.to_string()
    }

    fn get_diary_entries_detailed(
        &self,
        _start: NaiveDate,
        _end: NaiveDate,
    ) -> Vec<DiaryEntryRecord> {
        vec![]
    }

    fn save_diary_draft(&self, _date: NaiveDate, _content: &str) -> i64 {
        1
    }

    fn publish_diary(&self, _date: NaiveDate, _content: &str) -> i64 {
        1
    }

    fn publish_ai_diary(
        &self,
        _date: NaiveDate,
        _content: &str,
        _source_model: &str,
    ) -> Result<i64, String> {
        Ok(1)
    }

    fn get_diary_draft(&self, _date: NaiveDate) -> Option<String> {
        None
    }

    fn add_diary_entry(&self, _date: NaiveDate, _content: &str) -> i64 {
        1
    }

    fn update_diary_entry(&self, _id: i64, _content: &str) -> Result<(), String> {
        Ok(())
    }

    fn delete_diary_entry(&self, _id: i64) -> Result<(), String> {
        Ok(())
    }

    fn get_day_sessions(&self, _date: NaiveDate) -> Vec<(String, bool, i64, String)> {
        vec![]
    }

    fn get_day_hourly(&self, _date: NaiveDate) -> Vec<i64> {
        vec![0; 24]
    }

    fn get_hour_apps(&self, _date: NaiveDate, _hour: u32) -> Vec<(String, i64)> {
        vec![]
    }

    fn get_app_hourly(&self, _app_name: &str, _date: NaiveDate) -> Vec<i64> {
        vec![0; 24]
    }

    fn get_diary_images(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<(String, String)> {
        vec![]
    }

    fn get_diary_images_detailed(
        &self,
        _start: NaiveDate,
        _end: NaiveDate,
    ) -> Vec<(String, Option<i64>, String)> {
        vec![]
    }

    fn add_diary_image(&self, _date: NaiveDate, path: &str) -> String {
        path.to_string()
    }

    fn set_diary_image_entry(&self, _path: &str, _entry_id: i64) -> Result<(), String> {
        Ok(())
    }

    fn get_diary_images_for_entry(&self, _entry_id: i64) -> Vec<String> {
        vec![]
    }

    fn remove_diary_image(&self, _path: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn make_session(
        app: &str,
        started: DateTime<Utc>,
        dur: Option<i64>,
        idle: bool,
    ) -> SessionRecord {
        SessionRecord {
            id: 0,
            app_path: format!("C:/{app}.exe"),
            app_name: app.into(),
            window_title: None,
            started_at: started,
            ended_at: None,
            duration_secs: dur,
            is_idle: idle,
            date: started.date_naive(),
        }
    }

    #[test]
    fn test_memory_store_insert_and_query() {
        let store = MemoryStore::new();
        let id = store.insert_session(&make_session("TestApp", Utc::now(), None, false));
        assert!(id > 0);
        assert!(store.get_active_session().is_some());
    }

    #[test]
    fn test_recording_started_at() {
        let store = MemoryStore::new();
        let t1 = Utc::now();
        let t2 = t1 + chrono::Duration::hours(1);
        store.insert_session(&make_session("A", t1, Some(3600), false));
        store.insert_session(&make_session("B", t2, Some(1800), false));
        assert_eq!(store.recording_started_at().unwrap(), t1);
    }

    #[test]
    fn test_total_tracked_excludes_idle() {
        let store = MemoryStore::new();
        let now = Utc::now();
        store.insert_session(&make_session("Work", now, Some(1000), false));
        store.insert_session(&make_session("Idle", now, Some(500), true));
        assert_eq!(store.total_tracked_seconds(), 1000);
    }
}

#[cfg(test)]
mod sqlite_tests {
    use super::*;
    use chrono::{Duration, Utc};
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_path(label: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path =
            std::env::temp_dir().join(format!("tt_sqlite_{label}_{}_{}.db", std::process::id(), n));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&format!("{}-wal", path.display()));
        let _ = std::fs::remove_file(&format!("{}-shm", path.display()));
        path
    }

    fn temp_store() -> SqliteStore {
        SqliteStore::open(temp_path("test")).unwrap()
    }

    fn sess(app: &str, started: DateTime<Utc>, dur: i64, idle: bool) -> SessionRecord {
        SessionRecord {
            id: 0,
            app_path: format!("c:/{app}.exe"),
            app_name: app.into(),
            window_title: None,
            started_at: started,
            ended_at: Some(started + Duration::seconds(dur)),
            duration_secs: Some(dur),
            is_idle: idle,
            date: started.date_naive(),
        }
    }

    #[test]
    fn test_usage_split_active_and_idle() {
        let store = temp_store();
        let now = Utc::now();
        let today = now.date_naive();
        store.insert_session(&sess("code", now - Duration::hours(2), 3600, false));
        store.insert_session(&sess("code", now - Duration::hours(1), 1800, true));
        store.insert_session(&sess("edge", now - Duration::minutes(30), 900, false));

        let split = store.get_usage_split(today, today);
        assert_eq!(split.len(), 2);
        let code = split.iter().find(|s| s.app_name == "code").unwrap();
        assert_eq!(code.active_seconds, 3600);
        assert_eq!(code.idle_seconds, 1800);
    }

    #[test]
    fn test_zero_duration_sessions_excluded() {
        let store = temp_store();
        let now = Utc::now();
        let today = now.date_naive();
        store.insert_session(&sess("code", now, 0, false)); // 0s — excluded
        store.insert_session(&sess("edge", now - Duration::minutes(5), 300, false));

        let split = store.get_usage_split(today, today);
        assert_eq!(split.len(), 1);
        assert_eq!(split[0].app_name, "edge");
    }

    #[test]
    fn test_window_titles_via_page_visits() {
        let store = temp_store();
        let now = Utc::now();
        let today = now.date_naive();
        let sid = store.insert_session(&sess("edge", now - Duration::minutes(20), 1200, false));

        let v1 = store.start_page_visit(sid, "edge", Some("bilibili - Edge"), Utc::now(), today);
        let _v2 = store.start_page_visit(sid, "edge", Some("github - Edge"), Utc::now(), today);
        store.close_page_visit(v1, now + Duration::minutes(5));
        store.close_page_visit(_v2, now + Duration::minutes(10));

        let titles = store.get_window_titles("edge", today);
        assert!(
            titles.iter().any(|(t, _)| t == "bilibili - Edge"),
            "bilibili missing: {titles:?}"
        );
        assert!(
            titles.iter().any(|(t, _)| t == "github - Edge"),
            "github missing: {titles:?}"
        );
    }

    #[test]
    fn test_recording_stats() {
        let store = temp_store();
        let now = Utc::now();
        let today = now.date_naive();
        let t1 = now - Duration::days(2);
        store.insert_session(&sess("code", t1, 7200, false));
        store.insert_session(&sess("code", now - Duration::hours(1), 600, true)); // idle excluded

        assert_eq!(
            store.recording_started_at().unwrap().date_naive(),
            t1.date_naive()
        );
        assert_eq!(store.total_tracked_seconds(), 7200); // idle not counted
        assert!(store.total_tracked_in_range(today, today) >= 0);
    }
    #[test]
    fn test_hour_apps_and_app_hourly_cross_boundary() {
        let store = temp_store();
        let day = chrono::Local::now().date_naive();
        let start10 = day
            .and_hms_opt(10, 55, 0)
            .unwrap()
            .and_local_timezone(chrono::Local)
            .unwrap()
            .with_timezone(&Utc);
        let start11 = day
            .and_hms_opt(11, 0, 0)
            .unwrap()
            .and_local_timezone(chrono::Local)
            .unwrap()
            .with_timezone(&Utc);
        // code: 10:55 -> 11:05 (5min in hour 10, 5min in hour 11)
        store.insert_session(&sess("code", start10, 600, false));
        // edge: 11:00 -> 11:05 (5min in hour 11)
        store.insert_session(&sess("edge", start11, 300, false));
        let h10 = store.get_hour_apps(day, 10);
        let h11 = store.get_hour_apps(day, 11);
        let find = |list: &[(String, i64)], name: &str| {
            list.iter()
                .find(|(a, _)| a == name)
                .map(|(_, s)| *s)
                .unwrap_or(0)
        };
        assert_eq!(find(&h10, "code"), 300, "hour10 code should be 300s");
        assert_eq!(find(&h11, "code"), 300, "hour11 code should be 300s");
        assert_eq!(find(&h11, "edge"), 300, "hour11 edge should be 300s");
        assert_eq!(find(&h10, "edge"), 0, "hour10 edge should be 0s");
        let code_hourly = store.get_app_hourly("code", day);
        assert_eq!(code_hourly[10], 300);
        assert_eq!(code_hourly[11], 300);
    }

    #[test]
    fn test_diary_provenance_migration_preserves_legacy_rows_and_images() {
        let path = temp_path("legacy_diary");
        let legacy = Connection::open(&path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE diary_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date TEXT NOT NULL UNIQUE,
                    content TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE diary_images (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    date TEXT NOT NULL,
                    path TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                INSERT INTO diary_entries
                    (id, date, content, created_at, updated_at)
                VALUES
                    (42, '2026-08-29', 'legacy diary',
                     '2026-08-29T08:00:00Z', '2026-08-29T09:00:00Z');
                INSERT INTO diary_images (id, date, path, created_at)
                VALUES
                    (7, '2026-08-29', 'legacy-image.png',
                     '2026-08-29T08:30:00Z');",
            )
            .unwrap();
        drop(legacy);

        let store = SqliteStore::open(path).unwrap();
        let day = NaiveDate::from_ymd_opt(2026, 8, 29).unwrap();
        let entries = store.get_diary_entries_detailed(day, day);
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];
        assert_eq!(entry.id, 42);
        assert_eq!(entry.date, "2026-08-29");
        assert_eq!(entry.content, "legacy diary");
        assert_eq!(entry.status, "published");
        assert_eq!(entry.source, DiarySource::Manual);
        assert_eq!(entry.source_model, None);

        let conn = store.lock();
        let timestamps: (String, String) = conn
            .query_row(
                "SELECT created_at, updated_at FROM diary_entries WHERE id = 42",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(timestamps.0, "2026-08-29T08:00:00Z");
        assert_eq!(timestamps.1, "2026-08-29T09:00:00Z");
        let image: (i64, String, Option<i64>) = conn
            .query_row(
                "SELECT id, path, entry_id FROM diary_images WHERE id = 7",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(image, (7, "legacy-image.png".to_string(), Some(42)));
    }

    #[test]
    fn test_ai_diary_publish_and_user_edit_preserve_provenance() {
        let store = temp_store();
        let day = NaiveDate::from_ymd_opt(2026, 8, 30).unwrap();

        let ai_id = store
            .publish_ai_diary(day, "AI wrote this diary", "deepseek-v4-flash")
            .unwrap();
        let manual_id = store.add_diary_entry(day, "Handwritten diary");

        let initial = store.get_diary_entries_detailed(day, day);
        let ai = initial.iter().find(|entry| entry.id == ai_id).unwrap();
        assert_eq!(ai.status, "published");
        assert_eq!(ai.source, DiarySource::AiGenerated);
        assert_eq!(ai.source_model.as_deref(), Some("deepseek-v4-flash"));
        let manual = initial.iter().find(|entry| entry.id == manual_id).unwrap();
        assert_eq!(manual.source, DiarySource::Manual);
        assert_eq!(manual.source_model, None);

        store
            .update_diary_entry(ai_id, "User refined the AI diary")
            .unwrap();
        store
            .update_diary_entry(manual_id, "User refined the manual diary")
            .unwrap();

        let edited = store.get_diary_entries_detailed(day, day);
        let ai = edited.iter().find(|entry| entry.id == ai_id).unwrap();
        assert_eq!(ai.source, DiarySource::AiAssisted);
        assert_eq!(ai.source_model.as_deref(), Some("deepseek-v4-flash"));
        let manual = edited.iter().find(|entry| entry.id == manual_id).unwrap();
        assert_eq!(manual.source, DiarySource::Manual);
        assert_eq!(manual.source_model, None);
    }

    #[test]
    fn test_ai_diary_publish_rejects_incomplete_rows_atomically() {
        let store = temp_store();
        let day = NaiveDate::from_ymd_opt(2026, 8, 30).unwrap();

        assert!(store.publish_ai_diary(day, "", "model").is_err());
        assert!(store.publish_ai_diary(day, "content", "  ").is_err());
        assert!(store.get_diary_entries_detailed(day, day).is_empty());

        store
            .lock()
            .execute_batch(
                "CREATE TRIGGER reject_ai_diary
                 BEFORE INSERT ON diary_entries
                 WHEN NEW.source = 'ai_generated'
                 BEGIN
                     SELECT RAISE(ABORT, 'forced storage failure');
                 END;",
            )
            .unwrap();
        assert!(
            store
                .publish_ai_diary(day, "valid content", "valid-model")
                .is_err()
        );
        assert!(store.get_diary_entries_detailed(day, day).is_empty());
    }

    fn rule_path(name: &str) -> String {
        #[cfg(target_os = "windows")]
        {
            format!(r"C:\Apps\{name}.exe")
        }
        #[cfg(not(target_os = "windows"))]
        {
            format!("/Applications/{name}.app/Contents/MacOS/{name}")
        }
    }

    fn rule_draft(name: &str) -> AppTimeoutRuleDraft {
        AppTimeoutRuleDraft {
            app_path: rule_path(name),
            app_name: name.to_string(),
            threshold_secs: 60 * 60,
            cooldown_secs: 30 * 60,
            enabled: true,
            notify_repeatedly: false,
        }
    }

    #[test]
    fn timeout_rule_migration_is_idempotent_and_preserves_legacy_usage() {
        let path = temp_path("legacy_timeout_rules");
        let legacy = Connection::open(&path).unwrap();
        legacy
            .execute_batch(
                "CREATE TABLE usage_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    app_path TEXT NOT NULL,
                    app_name TEXT NOT NULL,
                    window_title TEXT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    duration_secs INTEGER,
                    is_idle INTEGER NOT NULL DEFAULT 0,
                    date TEXT NOT NULL
                );
                INSERT INTO usage_sessions
                    (app_path, app_name, started_at, ended_at, duration_secs, is_idle, date)
                VALUES
                    ('legacy.exe', 'Legacy', '2026-08-30T10:00:00Z',
                     '2026-08-30T10:01:00Z', 60, 0, '2026-08-30');",
            )
            .unwrap();
        drop(legacy);

        let store = SqliteStore::open(path.clone()).unwrap();
        assert!(store.list_rules().unwrap().is_empty());
        let legacy_count: i64 = store
            .lock()
            .query_row("SELECT COUNT(*) FROM usage_sessions", [], |row| row.get(0))
            .unwrap();
        assert_eq!(legacy_count, 1);
        drop(store);

        let reopened = SqliteStore::open(path).unwrap();
        assert!(reopened.list_rules().unwrap().is_empty());
        let index_count: i64 = reopened
            .lock()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master
                 WHERE type = 'index' AND name = 'idx_app_timeout_rules_enabled_path'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(index_count, 1);
    }

    #[test]
    fn timeout_rule_upsert_retains_identity_and_updates_fields() {
        let store = temp_store();
        let first = store.upsert_rule(&rule_draft("Editor")).unwrap();
        assert!(first.id > 0);
        assert_eq!(first.threshold_secs, 3600);

        let mut edited = rule_draft("Editor");
        edited.app_name = "Code Editor".to_string();
        edited.threshold_secs = 45 * 60;
        edited.cooldown_secs = 10 * 60;
        edited.enabled = false;
        edited.notify_repeatedly = true;
        let second = store.upsert_rule(&edited).unwrap();

        assert_eq!(second.id, first.id);
        assert_eq!(second.created_at, first.created_at);
        assert_eq!(second.app_name, "Code Editor");
        assert_eq!(second.threshold_secs, 2700);
        assert_eq!(second.cooldown_secs, 600);
        assert!(!second.enabled);
        assert!(second.notify_repeatedly);
        assert_eq!(store.list_rules().unwrap(), vec![second]);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn timeout_rule_upsert_matches_windows_case_and_separator_variants() {
        let store = temp_store();
        let first = store.upsert_rule(&rule_draft("Editor")).unwrap();
        let mut duplicate = rule_draft("Editor");
        duplicate.app_path = "c:/apps/EDITOR.EXE".to_string();
        duplicate.threshold_secs = 120;
        let updated = store.upsert_rule(&duplicate).unwrap();

        assert_eq!(updated.id, first.id);
        assert_eq!(updated.threshold_secs, 120);
        assert_eq!(store.list_rules().unwrap().len(), 1);
    }

    #[test]
    fn timeout_rule_delete_and_clear_usage_have_separate_lifecycles() {
        let store = temp_store();
        let rule = store.upsert_rule(&rule_draft("Browser")).unwrap();
        let now = Utc::now();
        store.insert_session(&sess("Browser", now, 30, false));

        store.clear_all_data();
        assert!(store.get_sessions_by_date(now.date_naive()).is_empty());
        assert_eq!(store.list_rules().unwrap().len(), 1);

        store.delete_rule(rule.id).unwrap();
        assert!(store.list_rules().unwrap().is_empty());
        assert_eq!(
            store.delete_rule(rule.id),
            Err(AppTimeoutRuleError::NotFound)
        );
    }

    #[test]
    fn timeout_rule_validation_rejects_ambiguous_inputs() {
        let store = temp_store();
        let mut draft = rule_draft("Editor");
        draft.app_path = "relative.exe".to_string();
        assert_eq!(
            store.upsert_rule(&draft),
            Err(AppTimeoutRuleError::InvalidPath)
        );

        #[cfg(target_os = "windows")]
        {
            draft = rule_draft("Editor");
            draft.app_path = r"\\?\C:\Apps\Editor.exe.".to_string();
            assert_eq!(
                store.upsert_rule(&draft),
                Err(AppTimeoutRuleError::InvalidPath)
            );

            draft = rule_draft("Editor");
            draft.app_path = r"C:\Apps\Σ.exe".to_string();
            assert_eq!(
                store.upsert_rule(&draft),
                Err(AppTimeoutRuleError::InvalidPath),
                "portable lowercase must not be stored as Windows ordinal identity"
            );

            draft = rule_draft("Editor");
            draft.app_path = "C:\\Apps\\\u{fffd}.exe".to_string();
            assert_eq!(
                store.upsert_rule(&draft),
                Err(AppTimeoutRuleError::InvalidPath),
                "lossy Windows replacement characters must not become rule identities"
            );
        }

        draft = rule_draft("Editor");
        draft.app_name = "   ".to_string();
        assert_eq!(
            store.upsert_rule(&draft),
            Err(AppTimeoutRuleError::EmptyAppName)
        );

        draft = rule_draft("Editor");
        draft.threshold_secs = 0;
        assert_eq!(
            store.upsert_rule(&draft),
            Err(AppTimeoutRuleError::InvalidDuration)
        );
        draft.threshold_secs = 60;
        draft.cooldown_secs = MAX_APP_TIMEOUT_DURATION_SECS + 1;
        assert_eq!(
            store.upsert_rule(&draft),
            Err(AppTimeoutRuleError::InvalidDuration)
        );
    }
}
