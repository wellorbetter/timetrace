#![cfg(windows)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Timelike, Utc};
use timetrace_core::engine::run_canonical_monitor_loop;
use timetrace_core::{
    AccountingQuery, AccountingQueryService, AccountingStore, AppInfo, CheckpointReason,
    FixedAccountingClock, IdleDetector, ProducerCheckpointState, SessionAggregator,
    SnapshotIntegrity, SqliteStore, UtcInterval, WindowResolver,
};

const INTERFACE_HASH: &str = "c3500be242ea4bafc6c915fbafe650b35092db4296d02aadd2df33fe328efd8f";
static NEXT_DB: AtomicUsize = AtomicUsize::new(0);

fn temp_db(label: &str) -> (PathBuf, SqliteStore) {
    let path = std::env::temp_dir().join(format!(
        "timetrace-production-monitor-{label}-{}-{}.db",
        std::process::id(),
        NEXT_DB.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&path);
    let store = SqliteStore::open(path.clone()).expect("open isolated sqlite ledger");
    (path, store)
}

struct FixedWindow;

impl WindowResolver for FixedWindow {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        Some(
            AppInfo::new(
                "C:/synthetic/editor.exe".to_owned(),
                "editor.synthetic".to_owned(),
            )
            .with_title("document.synthetic".to_owned()),
        )
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> {
        Some("document.synthetic".to_owned())
    }
}

struct NeverIdle;

impl IdleDetector for NeverIdle {
    fn is_idle(&self, _threshold: StdDuration) -> bool {
        false
    }

    fn idle_duration(&self) -> StdDuration {
        StdDuration::ZERO
    }
}

struct ControlledIdle {
    idle: Arc<AtomicBool>,
}

impl IdleDetector for ControlledIdle {
    fn is_idle(&self, _threshold: StdDuration) -> bool {
        self.idle.load(Ordering::SeqCst)
    }

    fn idle_duration(&self) -> StdDuration {
        if self.idle.load(Ordering::SeqCst) {
            StdDuration::from_secs(600)
        } else {
            StdDuration::ZERO
        }
    }
}

#[test]
fn production_monitor_virtual_hour_is_conserved_and_lifecycle_is_fenced() {
    let wall_started = std::time::Instant::now();
    let start = Utc::now().with_nanosecond(0).unwrap() - Duration::seconds(5);
    let (monitor_path, monitor_store) = temp_db("lifecycle");
    let sqlite = Arc::new(monitor_store);
    let clock = FixedAccountingClock::new(start);
    let legacy_sink = Box::new(SessionAggregator::new(sqlite.clone()));
    let handle = run_canonical_monitor_loop(
        FixedWindow,
        NeverIdle,
        StdDuration::from_millis(5),
        StdDuration::from_secs(600),
        Vec::new(),
        legacy_sink,
        sqlite.clone(),
        sqlite.clone(),
        Arc::new(clock.clone()),
    );
    std::thread::sleep(StdDuration::from_millis(60));

    let requested = UtcInterval::new(start, start + Duration::seconds(100)).unwrap();
    clock.set(start + Duration::seconds(20));
    let first_ack = handle
        .checkpoint_current(StdDuration::from_secs(2))
        .expect("first production Current fence");
    let first = AccountingQueryService::new(&*sqlite, &clock)
        .snapshot(
            requested.clone(),
            AccountingQuery::At {
                as_of: first_ack.durable_observed_through,
            },
        )
        .unwrap();
    clock.set(start + Duration::seconds(40));
    let second_ack = handle
        .checkpoint_current(StdDuration::from_secs(2))
        .expect("same-app Current advances without a foreground switch");
    let second = AccountingQueryService::new(&*sqlite, &clock)
        .snapshot(
            requested.clone(),
            AccountingQuery::At {
                as_of: second_ack.durable_observed_through,
            },
        )
        .unwrap();
    assert!(second_ack.durable_observed_through > first_ack.durable_observed_through);
    assert!(second.effective.end > first.effective.end);
    assert!(first.totals.active_seconds > 0);
    assert!(first.totals.accounted_seconds() > 0);
    assert!(second.totals.active_seconds > first.totals.active_seconds);
    assert!(second.totals.accounted_seconds() > first.totals.accounted_seconds());

    clock.set(start + Duration::seconds(50));
    let pause = handle.pause(StdDuration::from_secs(2)).expect("pause ack");
    assert_eq!(pause.lifecycle, CheckpointReason::Pause);
    clock.set(start + Duration::seconds(60));
    let resume = handle
        .resume(StdDuration::from_secs(2))
        .expect("resume ack");
    assert_eq!(resume.lifecycle, CheckpointReason::Resume);
    assert!(resume.durable_observed_through > pause.durable_observed_through);

    clock.set(start + Duration::seconds(70));
    let failure = handle
        .checkpoint_current(StdDuration::ZERO)
        .expect_err("zero budget is a deterministic Current failure");
    assert_eq!(
        failure.last_acknowledged_observed_through,
        Some(resume.durable_observed_through)
    );
    assert_eq!(
        sqlite.durable_observed_through().unwrap(),
        Some(resume.durable_observed_through)
    );
    let partial = AccountingQueryService::new(&*sqlite, &clock)
        .snapshot(
            requested.clone(),
            AccountingQuery::At {
                as_of: start + Duration::seconds(70),
            },
        )
        .unwrap();
    assert_eq!(partial.integrity, SnapshotIntegrity::Partial);
    assert_eq!(partial.observed_through, resume.durable_observed_through);
    assert!(partial.totals.unknown_seconds >= 10);

    clock.set(start + Duration::seconds(80));
    let stop = handle
        .stop(StdDuration::from_secs(2))
        .expect("stop flush and joins");
    assert_eq!(stop.lifecycle, CheckpointReason::Stop);
    assert_eq!(stop.durable_observed_through, start + Duration::seconds(80));
    drop(sqlite);

    let reopened = Arc::new(SqliteStore::open(monitor_path.clone()).unwrap());
    let restart_clock = FixedAccountingClock::new(start + Duration::seconds(90));
    let restarted = run_canonical_monitor_loop(
        FixedWindow,
        NeverIdle,
        StdDuration::from_millis(5),
        StdDuration::from_secs(600),
        Vec::new(),
        Box::new(SessionAggregator::new(reopened.clone())),
        reopened.clone(),
        reopened.clone(),
        Arc::new(restart_clock.clone()),
    );
    let recovery_state = ProducerCheckpointState::load(&*reopened).unwrap();
    assert_eq!(
        recovery_state.observed_through(),
        Some(start + Duration::seconds(90))
    );
    restart_clock.set(start + Duration::seconds(100));
    let restart_stop = restarted
        .stop(StdDuration::from_secs(2))
        .expect("restart stop flush and joins");
    assert_eq!(restart_stop.lifecycle, CheckpointReason::Stop);
    drop(reopened);
    let _ = std::fs::remove_file(monitor_path);

    let virtual_start = DateTime::parse_from_rfc3339("2026-02-20T10:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let (hour_path, hour_store) = temp_db("virtual-hour");
    let hour_store = Arc::new(hour_store);
    let hour_clock = FixedAccountingClock::new(virtual_start);
    let idle_state = Arc::new(AtomicBool::new(false));
    let hour_monitor = run_canonical_monitor_loop(
        FixedWindow,
        ControlledIdle {
            idle: idle_state.clone(),
        },
        StdDuration::from_millis(5),
        StdDuration::from_secs(600),
        Vec::new(),
        Box::new(SessionAggregator::new(hour_store.clone())),
        hour_store.clone(),
        hour_store.clone(),
        Arc::new(hour_clock.clone()),
    );
    std::thread::sleep(StdDuration::from_millis(30));

    hour_clock.set(virtual_start + Duration::seconds(1500));
    std::thread::sleep(StdDuration::from_millis(30));
    hour_monitor
        .checkpoint_current(StdDuration::from_secs(2))
        .expect("real monitor first active checkpoint");
    hour_clock.set(virtual_start + Duration::seconds(3000));
    std::thread::sleep(StdDuration::from_millis(30));
    hour_monitor
        .checkpoint_current(StdDuration::from_secs(2))
        .expect("real monitor second active checkpoint");

    hour_clock.set(virtual_start + Duration::seconds(3600));
    idle_state.store(true, Ordering::SeqCst);
    std::thread::sleep(StdDuration::from_millis(30));
    let virtual_hour_ack = hour_monitor
        .checkpoint_current(StdDuration::from_secs(2))
        .expect("real monitor idle checkpoint");
    let virtual_range =
        UtcInterval::new(virtual_start, virtual_start + Duration::seconds(3600)).unwrap();
    let snapshot = AccountingQueryService::new(&*hour_store, &hour_clock)
        .snapshot(
            virtual_range.clone(),
            AccountingQuery::At {
                as_of: virtual_hour_ack.durable_observed_through,
            },
        )
        .unwrap();
    assert_eq!(snapshot.totals.active_seconds, 3000);
    assert_eq!(snapshot.totals.idle_seconds, 600);
    assert_eq!(snapshot.totals.paused_seconds, 0);
    assert_eq!(snapshot.totals.privacy_excluded_seconds, 0);
    assert_eq!(snapshot.totals.system_gap_seconds, 0);
    assert_eq!(snapshot.totals.unknown_seconds, 0);
    assert_eq!(snapshot.totals.accounted_seconds(), 3600);
    assert_eq!(
        snapshot
            .attribution
            .apps
            .iter()
            .map(|item| item.seconds)
            .sum::<i64>(),
        3000
    );
    assert!(snapshot
        .attribution
        .apps
        .iter()
        .all(|item| item.id != "__IDLE__"));
    let hour_stop = hour_monitor
        .stop(StdDuration::from_secs(2))
        .expect("real monitor virtual-hour stop");
    assert_eq!(hour_stop.durable_observed_through, virtual_range.end);
    drop(hour_store);
    let reopened_hour = SqliteStore::open(hour_path.clone()).unwrap();
    let reopened_snapshot = AccountingQueryService::new(&reopened_hour, &hour_clock)
        .snapshot(
            virtual_range.clone(),
            AccountingQuery::At {
                as_of: virtual_range.end,
            },
        )
        .unwrap();
    assert_eq!(reopened_snapshot.totals, snapshot.totals);
    drop(reopened_hour);
    let _ = std::fs::remove_file(hour_path);

    assert!(wall_started.elapsed() < StdDuration::from_secs(30));
    println!("INTERFACE_HASH={INTERFACE_HASH}");
    println!("VIRTUAL_SECONDS=3600 ACTIVE=3000 IDLE=600 ACCOUNTED=3600");
    println!("CURRENT_COUNT=2 PAUSE_ACK=1 RESUME_ACK=1 STOP_ACK=1 RESTART_ACK=1");
}
