use std::sync::Arc;

use chrono::{Duration, Local, TimeZone, Utc};
use timetrace_core::{AppInfo, DataStore, EventSink, SessionAggregator, SqliteStore, TrackedEvent};

fn store() -> (Arc<SqliteStore>, std::path::PathBuf) {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-p0-accounting-{}-{id}.sqlite3",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    (Arc::new(SqliteStore::open(path.clone()).expect("open test database")), path)
}

fn app(name: &str, title: &str) -> AppInfo {
    AppInfo::new(format!("C:/{name}.exe"), name.to_owned()).with_title(title.to_owned())
}

fn switched(current: AppInfo, timestamp: chrono::DateTime<Utc>) -> TrackedEvent {
    TrackedEvent::AppSwitched { previous: None, current, timestamp }
}

#[test]
fn forty_closed_plus_twenty_checkpointed_open_is_exactly_one_hour() {
    let (db, _) = store();
    let mut aggregator = SessionAggregator::new(db.clone());
    let start = Utc.with_ymd_and_hms(2026, 1, 15, 10, 0, 0).single().unwrap();
    let day = start.with_timezone(&Local).date_naive();

    aggregator.accept(switched(app("work-editor", "code"), start));
    aggregator.accept(switched(app("web-client", "docs"), start + Duration::minutes(40)));
    aggregator.accept(switched(app("web-client", "docs"), start + Duration::minutes(60)));

    let split = db.get_usage_split(day, day);
    let active: i64 = split.iter().map(|row| row.active_seconds).sum();
    assert_eq!(active, 3600);
    assert_eq!(split.iter().find(|row| row.app_name == "work-editor").unwrap().active_seconds, 2400);
    assert_eq!(split.iter().find(|row| row.app_name == "web-client").unwrap().active_seconds, 1200);
    assert!(db.get_active_session().unwrap().ended_at.is_none());
}

#[test]
fn fifty_active_plus_real_idle_is_conserved_without_idle_as_active() {
    let (db, _) = store();
    let mut aggregator = SessionAggregator::new(db.clone());
    let start = Utc.with_ymd_and_hms(2026, 1, 15, 12, 0, 0).single().unwrap();
    let day = start.with_timezone(&Local).date_naive();
    let editor = app("editor", "code");

    aggregator.accept(switched(editor.clone(), start));
    aggregator.accept(TrackedEvent::IdleStarted {
        timestamp: start + Duration::minutes(50),
        grace: std::time::Duration::ZERO,
    });
    aggregator.accept(TrackedEvent::IdleEnded {
        idle_duration: std::time::Duration::from_secs(600),
        current_app: editor,
        timestamp: start + Duration::minutes(60),
    });

    let split = db.get_usage_split(day, day);
    let active: i64 = split.iter().map(|row| row.active_seconds).sum();
    let idle = db.get_idle_time_total(day, day).seconds;
    assert_eq!((active, idle, active + idle), (3000, 600, 3600));
    assert!(split.iter().all(|row| row.app_name != "__IDLE__"));
}

#[test]
fn open_tail_stops_at_last_successful_observation_not_wall_clock() {
    let (db, path) = store();
    let mut aggregator = SessionAggregator::new(db.clone());
    let start = Utc.with_ymd_and_hms(2020, 1, 2, 10, 0, 0).single().unwrap();
    let day = start.with_timezone(&Local).date_naive();
    let editor = app("editor", "same-title");

    aggregator.accept(switched(editor.clone(), start));
    aggregator.accept(switched(editor, start + Duration::minutes(20)));

    let split = db.get_usage_split(day, day);
    assert_eq!(split.iter().map(|row| row.active_seconds).sum::<i64>(), 1200);
    let open = db.get_active_session().unwrap();
    assert_eq!(open.duration_secs, Some(1200));
    assert!(open.ended_at.is_none());
    let conn = rusqlite::Connection::open(path).unwrap();
    let (count, duration, ended_at): (i64, i64, Option<String>) = conn.query_row(
        "SELECT COUNT(*), COALESCE(MAX(duration_secs), 0), MAX(ended_at) FROM page_visits WHERE window_title = 'same-title'",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    ).unwrap();
    assert_eq!((count, duration), (1, 1200));
    assert!(ended_at.is_none());
}
