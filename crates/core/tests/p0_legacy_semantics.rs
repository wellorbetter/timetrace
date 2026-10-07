use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use chrono::{DateTime, FixedOffset, NaiveDate, SecondsFormat, Timelike};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use timetrace_core::{DataStore, SqliteStore};

const FIXTURE_SQL: &str = include_str!("fixtures/p0_legacy_semantics.sql");
const EXPECTED_JSON: &str = include_str!("fixtures/p0_legacy_expected.json");
const DATE: &str = "2024-01-15";
const APPS: [&str; 2] = ["app-alpha", "app-beta"];

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Deserialize)]
struct ExpectedFile {
    fixture_version: u32,
    time_policy: TimePolicy,
    hashes: FixtureHashes,
    snapshot: Snapshot,
}

#[derive(Debug, Deserialize)]
struct TimePolicy {
    fixture_offset: String,
    canonical_bucket_offset: String,
    current_clock_reads: bool,
}

#[derive(Debug, Deserialize)]
struct FixtureHashes {
    sql_sha256: String,
    expected_snapshot_sha256: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct Snapshot {
    date: String,
    daily_app_summary: Vec<AppSummary>,
    usage_split: Vec<UsageSplit>,
    window_summary: Vec<AppWindows>,
    hourly_active_seconds: Vec<i64>,
    app_hourly: Vec<AppHourly>,
    idle_samples: Vec<IdleSample>,
    cross_day_sessions: Vec<CrossDaySession>,
    diary_relations: DiaryRelations,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct AppSummary {
    app_id: String,
    active_seconds: i64,
    session_count: i64,
    rank: usize,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct UsageSplit {
    app_id: String,
    active_seconds: i64,
    idle_seconds: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct AppWindows {
    app_id: String,
    windows: Vec<WindowSummary>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct WindowSummary {
    window_id: String,
    seconds: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct AppHourly {
    app_id: String,
    seconds: Vec<i64>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct IdleSample {
    started_at: String,
    duration_seconds: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct CrossDaySession {
    app_id: String,
    date_key: String,
    started_at: String,
    ended_at: String,
    duration_seconds: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct DiaryRelations {
    entries: Vec<DiaryEntry>,
    images: Vec<DiaryImage>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct DiaryEntry {
    entry_id: i64,
    date: String,
    status: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct DiaryImage {
    image_token: String,
    date: String,
    entry_id: i64,
}

struct TempDb {
    path: PathBuf,
}

impl TempDb {
    fn create() -> Self {
        let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "timetrace-p0-legacy-{}-{sequence}.sqlite",
            std::process::id()
        ));
        remove_sqlite_files(&path);
        Self { path }
    }
}

impl Drop for TempDb {
    fn drop(&mut self) {
        remove_sqlite_files(&self.path);
    }
}

fn remove_sqlite_files(path: &Path) {
    let _ = fs::remove_file(path);
    let _ = fs::remove_file(format!("{}-wal", path.display()));
    let _ = fs::remove_file(format!("{}-shm", path.display()));
}

#[test]
fn legacy_semantics_are_identical_before_and_after_migration() {
    let expected: ExpectedFile = serde_json::from_str(EXPECTED_JSON).expect("valid expected JSON");
    assert_eq!(expected.fixture_version, 1);
    assert_eq!(expected.time_policy.fixture_offset, "+00:00");
    assert_eq!(expected.time_policy.canonical_bucket_offset, "+00:00");
    assert!(!expected.time_policy.current_clock_reads);
    assert_eq!(
        sha256_hex(FIXTURE_SQL.as_bytes()),
        expected.hashes.sql_sha256,
        "fixture SQL changed; review semantics instead of blindly refreshing the hash"
    );

    let expected_document: Value =
        serde_json::from_str(EXPECTED_JSON).expect("expected document is valid JSON");
    let canonical_snapshot = canonical_json(&expected_document["snapshot"]);
    assert_eq!(
        sha256_hex(canonical_snapshot.as_bytes()),
        expected.hashes.expected_snapshot_sha256,
        "expected snapshot changed; semantic changes require Spec/Plan and independent review"
    );

    let temp = TempDb::create();
    let legacy = Connection::open(&temp.path).expect("create legacy fixture database");
    legacy
        .execute_batch(FIXTURE_SQL)
        .expect("load anonymous legacy SQL fixture");

    let pre = read_pre_migration_snapshot(&legacy);
    assert_eq!(
        pre, expected.snapshot,
        "pre-migration reader drifted from the reviewed legacy snapshot"
    );
    drop(legacy);

    let migrated = SqliteStore::open(temp.path.clone()).expect("migrate fixture with SqliteStore");
    let post = read_post_migration_snapshot(&migrated);
    assert_eq!(
        post, expected.snapshot,
        "public DataStore queries changed legacy semantics after migration"
    );
    drop(migrated);

    let reopened =
        SqliteStore::open(temp.path.clone()).expect("repeat migration/open is idempotent");
    let repeated = read_post_migration_snapshot(&reopened);
    assert_eq!(
        repeated, expected.snapshot,
        "reopening the migrated fixture changed its semantic snapshot"
    );
}

#[test]
fn hourly_fixture_is_invariant_across_explicit_fixed_offsets() {
    let expected: ExpectedFile = serde_json::from_str(EXPECTED_JSON).expect("valid expected JSON");
    let temp = TempDb::create();
    let connection = Connection::open(&temp.path).expect("create fixture database");
    connection.execute_batch(FIXTURE_SQL).expect("load fixture");
    let rows = load_active_rows(&connection, DATE, None);

    for seconds in [-43_200, -12_600, 0, 20_700, 50_400] {
        let offset = FixedOffset::east_opt(seconds).expect("valid explicit fixed offset");
        assert_eq!(
            bucket_rows(&rows, offset),
            expected.snapshot.hourly_active_seconds,
            "hour buckets must not depend on the execution machine timezone"
        );
    }
}

fn read_pre_migration_snapshot(connection: &Connection) -> Snapshot {
    let date = NaiveDate::parse_from_str(DATE, "%Y-%m-%d").expect("fixed date");

    let daily_app_summary = {
        let mut statement = connection
            .prepare(
                "SELECT app_name, COALESCE(SUM(duration_secs), 0), COUNT(*)
                 FROM usage_sessions
                 WHERE date = ?1 AND is_idle = 0 AND duration_secs IS NOT NULL
                 GROUP BY app_name ORDER BY 2 DESC",
            )
            .expect("prepare pre daily summary");
        statement
            .query_map(params![DATE], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })
            .expect("query pre daily summary")
            .enumerate()
            .map(|(index, row)| {
                let (app_id, active_seconds, session_count) = row.expect("daily summary row");
                AppSummary {
                    app_id,
                    active_seconds,
                    session_count,
                    rank: index + 1,
                }
            })
            .collect()
    };

    let usage_split = {
        let mut statement = connection
            .prepare(
                "SELECT app_name,
                        COALESCE(SUM(CASE WHEN is_idle = 0 THEN duration_secs ELSE 0 END), 0),
                        COALESCE(SUM(CASE WHEN is_idle = 1 THEN duration_secs ELSE 0 END), 0)
                 FROM usage_sessions
                 WHERE date >= ?1 AND date <= ?1 AND duration_secs > 0
                   AND app_name != '__IDLE__'
                 GROUP BY app_name ORDER BY 2 DESC",
            )
            .expect("prepare pre usage split");
        statement
            .query_map(params![DATE], |row| {
                Ok(UsageSplit {
                    app_id: row.get(0)?,
                    active_seconds: row.get(1)?,
                    idle_seconds: row.get(2)?,
                })
            })
            .expect("query pre usage split")
            .map(|row| row.expect("usage split row"))
            .collect()
    };

    let window_summary = APPS
        .iter()
        .map(|app_id| AppWindows {
            app_id: (*app_id).to_string(),
            windows: read_pre_windows(connection, app_id),
        })
        .collect();

    let active_rows = load_active_rows(connection, DATE, None);
    let hourly_active_seconds = bucket_rows(
        &active_rows,
        FixedOffset::east_opt(0).expect("UTC fixed offset"),
    );
    let app_hourly = APPS
        .iter()
        .map(|app_id| AppHourly {
            app_id: (*app_id).to_string(),
            seconds: bucket_rows(
                &load_active_rows(connection, DATE, Some(app_id)),
                FixedOffset::east_opt(0).expect("UTC fixed offset"),
            ),
        })
        .collect();

    let raw_sessions = read_pre_day_sessions(connection);
    let idle_samples = idle_samples(&raw_sessions);
    let cross_day_sessions = cross_day_sessions(&raw_sessions, date);

    let entries = {
        let mut statement = connection
            .prepare(
                "SELECT id, date, status FROM diary_entries
                 WHERE date >= '2024-01-15' AND date <= '2024-01-16'
                 ORDER BY date DESC, id DESC",
            )
            .expect("prepare pre diary entries");
        statement
            .query_map([], |row| {
                Ok(DiaryEntry {
                    entry_id: row.get(0)?,
                    date: row.get(1)?,
                    status: row.get(2)?,
                })
            })
            .expect("query pre diary entries")
            .map(|row| row.expect("diary entry row"))
            .collect()
    };

    let images = {
        let mut statement = connection
            .prepare(
                "SELECT path, date,
                        (SELECT MAX(entry.id) FROM diary_entries entry
                         WHERE entry.date = diary_images.date)
                 FROM diary_images ORDER BY id",
            )
            .expect("prepare pre diary image relations");
        statement
            .query_map([], |row| {
                Ok(DiaryImage {
                    image_token: row.get(0)?,
                    date: row.get(1)?,
                    entry_id: row.get(2)?,
                })
            })
            .expect("query pre diary images")
            .map(|row| row.expect("diary image row"))
            .collect()
    };

    Snapshot {
        date: DATE.to_string(),
        daily_app_summary,
        usage_split,
        window_summary,
        hourly_active_seconds,
        app_hourly,
        idle_samples,
        cross_day_sessions,
        diary_relations: DiaryRelations { entries, images },
    }
}

fn read_post_migration_snapshot(store: &SqliteStore) -> Snapshot {
    let date = NaiveDate::parse_from_str(DATE, "%Y-%m-%d").expect("fixed date");
    let diary_end = NaiveDate::parse_from_str("2024-01-16", "%Y-%m-%d").expect("fixed end");

    let daily_app_summary = store
        .get_daily_summary(date)
        .into_iter()
        .map(|row| AppSummary {
            app_id: row.app_name,
            active_seconds: row.total_seconds,
            session_count: row.session_count,
            rank: row.rank,
        })
        .collect();

    let usage_split = store
        .get_usage_split(date, date)
        .into_iter()
        .map(|row| UsageSplit {
            app_id: row.app_name,
            active_seconds: row.active_seconds,
            idle_seconds: row.idle_seconds,
        })
        .collect();

    let window_summary = APPS
        .iter()
        .map(|app_id| AppWindows {
            app_id: (*app_id).to_string(),
            windows: store
                .get_window_titles(app_id, date)
                .into_iter()
                .map(|(window_id, seconds)| WindowSummary { window_id, seconds })
                .collect(),
        })
        .collect();

    let app_hourly = APPS
        .iter()
        .map(|app_id| AppHourly {
            app_id: (*app_id).to_string(),
            seconds: store.get_app_hourly(app_id, date),
        })
        .collect();

    let raw_sessions: Vec<RawDaySession> = store
        .get_day_sessions(date)
        .into_iter()
        .map(
            |(app_id, is_idle, duration_seconds, started_at)| RawDaySession {
                app_id,
                is_idle,
                duration_seconds,
                started_at,
            },
        )
        .collect();

    let entries = store
        .get_diary_entries_detailed(date, diary_end)
        .into_iter()
        .map(|(entry_id, date, _content, status)| DiaryEntry {
            entry_id,
            date,
            status,
        })
        .collect();

    let images = store
        .get_diary_images_detailed(date, diary_end)
        .into_iter()
        .map(|(date, entry_id, image_token)| DiaryImage {
            image_token,
            date,
            entry_id: entry_id.expect("migration must link every fixture image"),
        })
        .collect();

    Snapshot {
        date: DATE.to_string(),
        daily_app_summary,
        usage_split,
        window_summary,
        hourly_active_seconds: store.get_day_hourly(date),
        app_hourly,
        idle_samples: idle_samples(&raw_sessions),
        cross_day_sessions: cross_day_sessions(&raw_sessions, date),
        diary_relations: DiaryRelations { entries, images },
    }
}

fn read_pre_windows(connection: &Connection, app_id: &str) -> Vec<WindowSummary> {
    let mut statement = connection
        .prepare(
            "SELECT COALESCE(window_title, ''), COALESCE(SUM(duration_secs), 0)
             FROM page_visits
             WHERE app_name = ?1 AND date = ?2 AND duration_secs > 0
             GROUP BY window_title ORDER BY SUM(duration_secs) DESC",
        )
        .expect("prepare pre window summary");
    statement
        .query_map(params![app_id, DATE], |row| {
            Ok(WindowSummary {
                window_id: row.get(0)?,
                seconds: row.get(1)?,
            })
        })
        .expect("query pre windows")
        .map(|row| row.expect("window row"))
        .collect()
}

fn load_active_rows(
    connection: &Connection,
    date: &str,
    app_id: Option<&str>,
) -> Vec<(String, i64)> {
    let (sql, values): (&str, Vec<&str>) = if let Some(app_id) = app_id {
        (
            "SELECT started_at, duration_secs FROM usage_sessions
             WHERE date = ?1 AND app_name = ?2 AND is_idle = 0 AND duration_secs > 0",
            vec![date, app_id],
        )
    } else {
        (
            "SELECT started_at, duration_secs FROM usage_sessions
             WHERE date = ?1 AND is_idle = 0 AND duration_secs > 0",
            vec![date],
        )
    };
    let mut statement = connection.prepare(sql).expect("prepare active rows");
    let mut rows = statement
        .query(rusqlite::params_from_iter(values))
        .expect("query active rows");
    let mut result = Vec::new();
    while let Some(row) = rows.next().expect("advance active rows") {
        result.push((
            row.get(0).expect("started_at"),
            row.get(1).expect("duration"),
        ));
    }
    result
}

fn bucket_rows(rows: &[(String, i64)], offset: FixedOffset) -> Vec<i64> {
    let mut hours = vec![0_i64; 24];
    for (started_at, duration_seconds) in rows {
        let parsed = DateTime::parse_from_rfc3339(started_at).expect("fixture timestamp");
        let mut cursor = parsed.with_timezone(&offset);
        let end = cursor + chrono::Duration::seconds(*duration_seconds);
        while cursor < end {
            let hour = cursor.hour() as usize;
            let next_hour = cursor
                .with_minute(0)
                .and_then(|value| value.with_second(0))
                .map(|value| value + chrono::Duration::hours(1))
                .expect("fixed-offset next hour");
            let segment_end = end.min(next_hour);
            hours[hour] += (segment_end - cursor).num_seconds().max(0);
            cursor = segment_end;
        }
    }
    hours
}

#[derive(Debug)]
struct RawDaySession {
    app_id: String,
    is_idle: bool,
    duration_seconds: i64,
    started_at: String,
}

fn read_pre_day_sessions(connection: &Connection) -> Vec<RawDaySession> {
    let mut statement = connection
        .prepare(
            "SELECT app_name, is_idle, COALESCE(duration_secs, 0), started_at
             FROM usage_sessions WHERE date = ?1 AND duration_secs > 0 ORDER BY started_at",
        )
        .expect("prepare pre day sessions");
    statement
        .query_map(params![DATE], |row| {
            Ok(RawDaySession {
                app_id: row.get(0)?,
                is_idle: row.get::<_, i32>(1)? != 0,
                duration_seconds: row.get(2)?,
                started_at: row.get(3)?,
            })
        })
        .expect("query pre day sessions")
        .map(|row| row.expect("day session row"))
        .collect()
}

fn idle_samples(rows: &[RawDaySession]) -> Vec<IdleSample> {
    rows.iter()
        .filter(|row| row.is_idle)
        .map(|row| IdleSample {
            started_at: row.started_at.clone(),
            duration_seconds: row.duration_seconds,
        })
        .collect()
}

fn cross_day_sessions(rows: &[RawDaySession], date_key: NaiveDate) -> Vec<CrossDaySession> {
    rows.iter()
        .filter(|row| !row.is_idle)
        .filter_map(|row| {
            let start = DateTime::parse_from_rfc3339(&row.started_at).expect("fixture timestamp");
            let end = start + chrono::Duration::seconds(row.duration_seconds);
            (end.date_naive() != start.date_naive()).then(|| CrossDaySession {
                app_id: row.app_id.clone(),
                date_key: date_key.to_string(),
                started_at: row.started_at.clone(),
                ended_at: end.to_rfc3339_opts(SecondsFormat::Secs, false),
                duration_seconds: row.duration_seconds,
            })
        })
        .collect()
}

fn canonical_json(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        Value::String(value) => serde_json::to_string(value).expect("serialize string"),
        Value::Array(values) => format!(
            "[{}]",
            values
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        Value::Object(values) => {
            let mut keys: Vec<_> = values.keys().collect();
            keys.sort_unstable();
            let fields = keys
                .into_iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).expect("serialize key"),
                        canonical_json(&values[key])
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{fields}}}")
        }
    }
}

fn sha256_hex(input: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut state: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let bit_length = (input.len() as u64).wrapping_mul(8);
    let mut padded = input.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    for chunk in padded.chunks_exact(64) {
        let mut words = [0_u32; 64];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let start = index * 4;
            *word = u32::from_be_bytes([
                chunk[start],
                chunk[start + 1],
                chunk[start + 2],
                chunk[start + 3],
            ]);
        }
        for index in 16..64 {
            let s0 = words[index - 15].rotate_right(7)
                ^ words[index - 15].rotate_right(18)
                ^ (words[index - 15] >> 3);
            let s1 = words[index - 2].rotate_right(17)
                ^ words[index - 2].rotate_right(19)
                ^ (words[index - 2] >> 10);
            words[index] = words[index - 16]
                .wrapping_add(s0)
                .wrapping_add(words[index - 7])
                .wrapping_add(s1);
        }

        let mut a = state[0];
        let mut b = state[1];
        let mut c = state[2];
        let mut d = state[3];
        let mut e = state[4];
        let mut f = state[5];
        let mut g = state[6];
        let mut h = state[7];
        for index in 0..64 {
            let sigma1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(sigma1)
                .wrapping_add(choice)
                .wrapping_add(K[index])
                .wrapping_add(words[index]);
            let sigma0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = sigma0.wrapping_add(majority);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        state[0] = state[0].wrapping_add(a);
        state[1] = state[1].wrapping_add(b);
        state[2] = state[2].wrapping_add(c);
        state[3] = state[3].wrapping_add(d);
        state[4] = state[4].wrapping_add(e);
        state[5] = state[5].wrapping_add(f);
        state[6] = state[6].wrapping_add(g);
        state[7] = state[7].wrapping_add(h);
    }

    state.iter().map(|word| format!("{word:08x}")).collect()
}
