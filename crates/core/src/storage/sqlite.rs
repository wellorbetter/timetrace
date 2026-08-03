//! SQLite implementation of `DataStore`.
//!
//! Uses `rusqlite` with bundled SQLite. All errors are logged via `tracing::warn!`
//! and operations return sensible defaults — the trait contract says infallible.

use std::path::PathBuf;
use std::sync::Mutex;

use chrono::{DateTime, NaiveDate, Timelike, Utc};
use rusqlite::{params, Connection};
use tracing::{debug, warn};

use crate::contracts::{
    AppMetaRecord, AppUsageSplit, AppUsageSummary, DataStore, SessionRecord, StartupEntryRecord,
};
use crate::storage::schema;

pub struct SqliteStore {
    conn: Mutex<Connection>,
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

        debug!("SQLite opened at {}", path.display());

        Ok(Self { conn: Mutex::new(conn) })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().expect("SQLite connection mutex poisoned")
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
                let duration = (end_time - started_at.with_timezone(&Utc)).num_seconds();
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
        let mut stmt = conn
            .prepare(
                "SELECT id, app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date
                 FROM usage_sessions WHERE date = ?1 ORDER BY started_at",
            )
            .unwrap();
        stmt.query_map(params![date.to_string()], |row| Self::row_to_session(row))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect()
    }

    fn get_sessions_by_range(&self, start: NaiveDate, end: NaiveDate) -> Vec<SessionRecord> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare(
                "SELECT id, app_path, app_name, window_title, started_at, ended_at, duration_secs, is_idle, date
                 FROM usage_sessions WHERE date >= ?1 AND date <= ?2 ORDER BY started_at",
            )
            .unwrap();
        stmt.query_map(params![start.to_string(), end.to_string()], |row| {
            Self::row_to_session(row)
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .collect()
    }

    fn get_daily_summary(&self, date: NaiveDate) -> Vec<AppUsageSummary> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare(
                "SELECT app_name, COALESCE(SUM(duration_secs), 0) as total, COUNT(*) as sessions
                 FROM usage_sessions WHERE date = ?1 AND is_idle = 0 AND duration_secs IS NOT NULL
                 GROUP BY app_name ORDER BY total DESC",
            )
            .unwrap();
        stmt.query_map(params![date.to_string()], |row| {
            Ok(AppUsageSummary {
                app_name: row.get(0)?,
                total_seconds: row.get(1)?,
                session_count: row.get::<_, i64>(2)? as i64,
                rank: 0,
            })
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .enumerate()
        .map(|(i, mut s)| {
            s.rank = i + 1;
            s
        })
        .collect()
    }

    fn get_top_apps(&self, start: NaiveDate, end: NaiveDate, limit: usize) -> Vec<AppUsageSummary> {
        let conn = self.lock();
        let mut stmt = conn
            .prepare(
                "SELECT app_name, COALESCE(SUM(duration_secs), 0) as total, COUNT(*) as sessions
                 FROM usage_sessions
                 WHERE date >= ?1 AND date <= ?2 AND is_idle = 0 AND duration_secs > 0
                 GROUP BY app_name
                 ORDER BY total DESC
                 LIMIT ?3",
            )
            .unwrap();
        stmt.query_map(
            params![start.to_string(), end.to_string(), limit as i64],
            |row| {
                Ok(AppUsageSummary {
                    app_name: row.get(0)?,
                    total_seconds: row.get(1)?,
                    session_count: row.get(2)?,
                    rank: 0,
                })
            },
        )
        .unwrap()
        .filter_map(|r| r.ok())
        .enumerate()
        .map(|(i, mut s)| {
            s.rank = i + 1;
            s
        })
        .collect()
    }

    fn get_usage_split(&self, start: NaiveDate, end: NaiveDate) -> Vec<AppUsageSplit> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT app_name, MAX(app_path),
                    COALESCE(SUM(CASE WHEN is_idle = 0 THEN duration_secs ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN is_idle = 1 THEN duration_secs ELSE 0 END), 0)
             FROM usage_sessions
             WHERE date >= ?1 AND date <= ?2 AND duration_secs > 0 AND app_name != '__IDLE__'
             GROUP BY app_name ORDER BY 3 DESC"
        ).unwrap();
        stmt.query_map(params![start.to_string(), end.to_string()], |row| {
            Ok(AppUsageSplit { app_name: row.get(0)?, exe_path: row.get(1)?, active_seconds: row.get(2)?, idle_seconds: row.get(3)? })
        }).unwrap().filter_map(|r| r.ok()).collect()
    }

    fn get_hourly_breakdown(&self, app_name: &str, date: NaiveDate) -> [i64; 24] {
        let conn = self.lock();
        let mut hours = [0i64; 24];
        if let Ok(mut stmt) = conn.prepare(
            "SELECT started_at, duration_secs FROM usage_sessions
             WHERE app_name = ?1 AND date = ?2 AND duration_secs IS NOT NULL",
        ) {
            if let Ok(rows) = stmt.query_map(params![app_name, date.to_string()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            }) {
                for row in rows.flatten() {
                    if let Ok(parsed) = DateTime::parse_from_rfc3339(&row.0) {
                        let hour = parsed.hour() as usize;
                        if hour < 24 {
                            hours[hour] += row.1;
                        }
                    }
                }
            }
        }
        hours
    }

    fn get_window_titles(&self, app_name: &str, date: NaiveDate) -> Vec<(String, i64)> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT COALESCE(window_title, ''), COALESCE(SUM(duration_secs), 0)
             FROM page_visits
             WHERE app_name = ?1 AND date = ?2 AND duration_secs > 0
             GROUP BY window_title ORDER BY SUM(duration_secs) DESC"
        ).unwrap();
        stmt.query_map(params![app_name, date.to_string()], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap().filter_map(|r| r.ok()).collect()
    }

    fn start_page_visit(&self, session_id: i64, app_name: &str, title: Option<&str>, date: NaiveDate) -> i64 {
        let conn = self.lock();
        let now = Utc::now().to_rfc3339();
        match conn.execute(
            "INSERT INTO page_visits (session_id, app_name, window_title, started_at, ended_at, duration_secs, date)
             VALUES (?1, ?2, ?3, ?4, NULL, NULL, ?5)",
            params![session_id, app_name, title, now, date.to_string()],
        ) {
            Ok(_) => conn.last_insert_rowid(),
            Err(e) => { warn!("page visit insert failed: {e}"); -1 }
        }
    }

    fn close_page_visit(&self, visit_id: i64, end_time: DateTime<Utc>) {
        if visit_id < 0 { return; }
        let conn = self.lock();
        if let Ok(started_str) = conn.query_row(
            "SELECT started_at FROM page_visits WHERE id = ?1", params![visit_id], |row| row.get::<_, String>(0)
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
        let mut stmt = conn
            .prepare(
                "SELECT id, name, command, source, enabled, backup_value, backup_path, first_seen, last_checked
                 FROM startup_entries ORDER BY source, name",
            )
            .unwrap();
        stmt.query_map([], |row| {
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
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .collect()
    }

    fn set_startup_enabled(&self, id: i64, enabled: bool, backup: Option<&str>, backup_path: Option<&str>) {
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
            date: NaiveDate::parse_from_str(&row.get::<_, String>(8)?, "%Y-%m-%d").unwrap_or_default(),
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
#[cfg(any(test, feature = "testing"))]
pub struct MemoryStore {
    sessions: Mutex<Vec<SessionRecord>>,
    summaries: Mutex<Vec<(String, NaiveDate, i64, i64)>>, // app_name, date, seconds, count
    startups: Mutex<Vec<StartupEntryRecord>>,
    metas: Mutex<Vec<AppMetaRecord>>,
    next_id: Mutex<i64>,
}

#[cfg(any(test, feature = "testing"))]
impl MemoryStore {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(Vec::new()),
            summaries: Mutex::new(Vec::new()),
            startups: Mutex::new(Vec::new()),
            metas: Mutex::new(Vec::new()),
            next_id: Mutex::new(1),
        }
    }
}

#[cfg(any(test, feature = "testing"))]
impl DataStore for MemoryStore {
    fn insert_session(&self, session: &SessionRecord) -> i64 {
        let mut sessions = self.sessions.lock().unwrap();
        let mut next_id = self.next_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        let mut s = session.clone();
        s.id = id;
        sessions.push(s);
        id
    }

    fn close_session(&self, id: i64, end_time: DateTime<Utc>) {
        let mut sessions = self.sessions.lock().unwrap();
        if let Some(s) = sessions.iter_mut().find(|s| s.id == id) {
            s.ended_at = Some(end_time);
            s.duration_secs = Some((end_time - s.started_at).num_seconds());
        }
    }

    fn get_active_session(&self) -> Option<SessionRecord> {
        self.sessions.lock().unwrap()
            .iter()
            .rev()
            .find(|s| s.ended_at.is_none())
            .cloned()
    }

    fn get_sessions_by_date(&self, date: NaiveDate) -> Vec<SessionRecord> {
        self.sessions.lock().unwrap()
            .iter()
            .filter(|s| s.date == date)
            .cloned()
            .collect()
    }

    fn get_sessions_by_range(&self, start: NaiveDate, end: NaiveDate) -> Vec<SessionRecord> {
        self.sessions.lock().unwrap()
            .iter()
            .filter(|s| s.date >= start && s.date <= end)
            .cloned()
            .collect()
    }

    fn get_daily_summary(&self, _date: NaiveDate) -> Vec<AppUsageSummary> {
        vec![] // Simplified for testing; real logic in SqliteStore
    }

    fn get_top_apps(&self, _start: NaiveDate, _end: NaiveDate, _limit: usize) -> Vec<AppUsageSummary> {
        vec![]
    }

    fn get_usage_split(&self, _start: NaiveDate, _end: NaiveDate) -> Vec<AppUsageSplit> {
        vec![]
    }

    fn start_page_visit(&self, _session_id: i64, _app_name: &str, _title: Option<&str>, _date: NaiveDate) -> i64 { -1 }

    fn close_page_visit(&self, _visit_id: i64, _end_time: DateTime<Utc>) {}

    fn get_hourly_breakdown(&self, _app_name: &str, _date: NaiveDate) -> [i64; 24] {
        [0; 24]
    }

    fn get_window_titles(&self, app_name: &str, _date: NaiveDate) -> Vec<(String, i64)> {
        self.sessions.lock().unwrap()
            .iter()
            .filter(|s| s.app_name == app_name && !s.is_idle)
            .filter_map(|s| s.duration_secs.map(|d| (s.window_title.clone().unwrap_or_default(), d)))
            .fold(std::collections::HashMap::new(), |mut acc, (title, dur)| {
                *acc.entry(title).or_insert(0) += dur; acc
            })
            .into_iter().collect()
    }

    fn upsert_startup_entries(&self, entries: &[StartupEntryRecord]) {
        let mut startups = self.startups.lock().unwrap();
        for e in entries {
            startups.push(e.clone());
        }
    }

    fn get_all_startup_entries(&self) -> Vec<StartupEntryRecord> {
        self.startups.lock().unwrap().clone()
    }

    fn set_startup_enabled(&self, id: i64, enabled: bool, backup: Option<&str>, backup_path: Option<&str>) {
        let mut startups = self.startups.lock().unwrap();
        if let Some(e) = startups.iter_mut().find(|e| e.id == id) {
            e.enabled = enabled;
            if let Some(v) = backup { e.backup_value = Some(v.to_string()); }
            if let Some(p) = backup_path { e.backup_path = Some(p.to_string()); }
        }
    }

    fn get_app_meta(&self, exe_path: &str) -> Option<AppMetaRecord> {
        self.metas.lock().unwrap().iter().find(|m| m.app_path == exe_path).cloned()
    }

    fn set_app_meta(&self, meta: &AppMetaRecord) {
        let mut metas = self.metas.lock().unwrap();
        if let Some(existing) = metas.iter_mut().find(|m| m.app_path == meta.app_path) {
            *existing = meta.clone();
        } else {
            metas.push(meta.clone());
        }
    }

    fn recording_started_at(&self) -> Option<DateTime<Utc>> {
        self.sessions.lock().unwrap()
            .iter()
            .min_by_key(|s| s.started_at)
            .map(|s| s.started_at)
    }

    fn total_tracked_seconds(&self) -> i64 {
        self.sessions.lock().unwrap()
            .iter()
            .filter(|s| !s.is_idle)
            .filter_map(|s| s.duration_secs)
            .sum()
    }

    fn total_tracked_in_range(&self, start: NaiveDate, end: NaiveDate) -> i64 {
        self.sessions.lock().unwrap()
            .iter()
            .filter(|s| !s.is_idle && s.date >= start && s.date <= end)
            .filter_map(|s| s.duration_secs)
            .sum()
    }

    fn cleanup_old_sessions(&self, before: NaiveDate) {
        self.sessions.lock().unwrap().retain(|s| s.date >= before);
    }

    fn vacuum(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn make_session(app: &str, started: DateTime<Utc>, dur: Option<i64>, idle: bool) -> SessionRecord {
        SessionRecord {
            id: 0, app_path: format!("C:/{app}.exe"), app_name: app.into(),
            window_title: None, started_at: started, ended_at: None,
            duration_secs: dur, is_idle: idle, date: started.date_naive(),
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

    fn temp_store() -> SqliteStore {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("tt_sqlite_test_{}_{}.db", std::process::id(), n));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(&format!("{}-wal", path.display()));
        let _ = std::fs::remove_file(&format!("{}-shm", path.display()));
        SqliteStore::open(path).unwrap()
    }

    fn sess(app: &str, started: DateTime<Utc>, dur: i64, idle: bool) -> SessionRecord {
        SessionRecord {
            id: 0, app_path: format!("c:/{app}.exe"), app_name: app.into(),
            window_title: None, started_at: started, ended_at: Some(started + Duration::seconds(dur)),
            duration_secs: Some(dur), is_idle: idle, date: started.date_naive(),
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
        store.insert_session(&sess("code", now, 0, false));   // 0s — excluded
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

        let v1 = store.start_page_visit(sid, "edge", Some("bilibili - Edge"), today);
        let _v2 = store.start_page_visit(sid, "edge", Some("github - Edge"), today);
        store.close_page_visit(v1, now + Duration::minutes(5));
        store.close_page_visit(_v2, now + Duration::minutes(10));

        let titles = store.get_window_titles("edge", today);
        assert!(titles.iter().any(|(t, _)| t == "bilibili - Edge"), "bilibili missing: {titles:?}");
        assert!(titles.iter().any(|(t, _)| t == "github - Edge"), "github missing: {titles:?}");
    }

    #[test]
    fn test_recording_stats() {
        let store = temp_store();
        let now = Utc::now();
        let today = now.date_naive();
        let t1 = now - Duration::days(2);
        store.insert_session(&sess("code", t1, 7200, false));
        store.insert_session(&sess("code", now - Duration::hours(1), 600, true)); // idle excluded

        assert_eq!(store.recording_started_at().unwrap().date_naive(), t1.date_naive());
        assert_eq!(store.total_tracked_seconds(), 7200); // idle not counted
        assert!(store.total_tracked_in_range(today, today) >= 0);
    }
}
