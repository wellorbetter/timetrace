use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use chrono::{Duration, TimeZone, Timelike, Utc};
use timetrace_bridge::{TimeTraceApi, current_accounting_snapshot};
use timetrace_core::engine::aggregator::{CheckpointStore, SessionAggregator};
use timetrace_core::engine::run_canonical_monitor_loop;
use timetrace_core::{
    AccountingError, AccountingInterval, AccountingQuery, AccountingQueryService, AccountingStore,
    AppInfo, CheckpointAck, CheckpointReason, DataStore, FixedAccountingClock, IdleDetector,
    ProducerCheckpointState, ProductionCheckpoint, ProductionCheckpointError, RecoveryPoint,
    SessionRecord, SnapshotIntegrity, SqliteStore, UtcInterval, WindowResolver,
};

static NEXT_DB: AtomicUsize = AtomicUsize::new(0);

fn isolated_db(label: &str) -> (PathBuf, SqliteStore) {
    let id = NEXT_DB.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-dashboard-{label}-{}-{id}.sqlite3",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    let store = SqliteStore::open(path.clone()).expect("open isolated fixture database");
    (path, store)
}

fn session(
    app_name: &str,
    start: chrono::DateTime<Utc>,
    duration_seconds: Option<i64>,
    idle: bool,
) -> SessionRecord {
    SessionRecord {
        id: 0,
        app_path: if idle {
            String::new()
        } else {
            format!("C:/{app_name}.exe")
        },
        app_name: app_name.to_owned(),
        window_title: None,
        started_at: start,
        ended_at: duration_seconds.map(|seconds| start + Duration::seconds(seconds)),
        duration_secs: duration_seconds,
        is_idle: idle,
        date: start.date_naive(),
    }
}

#[test]
fn open_tail_fixture_is_visible_in_dashboard_and_stats() {
    let (path, store) = isolated_db("open-tail");
    let start = Utc
        .with_ymd_and_hms(2026, 1, 15, 10, 0, 0)
        .single()
        .unwrap();
    store.insert_session(&session("work-editor", start, Some(2400), false));
    let open_id = store.insert_session(&session(
        "web-client",
        start + Duration::seconds(2400),
        None,
        false,
    ));
    store
        .checkpoint_open_interval(open_id, None, start + Duration::seconds(3600))
        .expect("checkpoint open tail");
    drop(store);

    let api = TimeTraceApi::create(path.to_string_lossy().into_owned()).unwrap();
    let dashboard = api.get_dashboard_data("2026-01-15".into(), "2026-01-15".into());
    let stats = api.get_stats("2026-01-15".into(), "2026-01-15".into());
    let app_total: i64 = dashboard.apps.iter().map(|app| app.active_seconds).sum();
    assert_eq!(
        (dashboard.active_seconds, dashboard.idle_seconds),
        (3600, 0)
    );
    assert_eq!(dashboard.active_seconds + dashboard.idle_seconds, 3600);
    assert_eq!((stats.active_seconds, stats.idle_seconds), (3600, 0));
    assert_eq!(stats.active_seconds + stats.idle_seconds, 3600);
    assert_eq!(app_total, 3600);
}

#[test]
fn active_idle_fixture_is_conserved_without_idle_pseudo_app() {
    let (path, store) = isolated_db("active-idle");
    let start = Utc
        .with_ymd_and_hms(2026, 2, 16, 10, 0, 0)
        .single()
        .unwrap();
    store.insert_session(&session("work-editor", start, Some(3000), false));
    store.insert_session(&session(
        "__IDLE__",
        start + Duration::seconds(3000),
        Some(600),
        true,
    ));
    drop(store);

    let api = TimeTraceApi::create(path.to_string_lossy().into_owned()).unwrap();
    let dashboard = api.get_dashboard_data("2026-02-16".into(), "2026-02-16".into());
    let stats = api.get_stats("2026-02-16".into(), "2026-02-16".into());
    let app_total: i64 = dashboard.apps.iter().map(|app| app.active_seconds).sum();
    assert_eq!(
        (dashboard.active_seconds, dashboard.idle_seconds),
        (3000, 600)
    );
    assert_eq!(dashboard.active_seconds + dashboard.idle_seconds, 3600);
    assert_eq!((stats.active_seconds, stats.idle_seconds), (3000, 600));
    assert_eq!(stats.active_seconds + stats.idle_seconds, 3600);
    assert_eq!(app_total, 3000);
    assert!(dashboard.apps.iter().all(|app| app.app_name != "__IDLE__"));
}

struct FixedWindow;

impl WindowResolver for FixedWindow {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        Some(AppInfo::new(
            "C:/fixture.exe".to_owned(),
            "fixture-app".to_owned(),
        ))
    }

    fn get_window_title(&self, _hwnd: isize) -> Option<String> {
        Some("fixture-window".to_owned())
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

struct FailOneCurrentCheckpoint {
    inner: Arc<SqliteStore>,
    fail_next_current: AtomicBool,
    fail_next_reason: Mutex<Option<CheckpointReason>>,
    last_checkpoint: Mutex<Option<ProductionCheckpoint>>,
}

impl FailOneCurrentCheckpoint {
    fn new(inner: Arc<SqliteStore>) -> Self {
        Self {
            inner,
            fail_next_current: AtomicBool::new(false),
            fail_next_reason: Mutex::new(None),
            last_checkpoint: Mutex::new(None),
        }
    }

    fn fail_next_current(&self) {
        self.fail_next_current.store(true, Ordering::SeqCst);
    }

    fn fail_next(&self, reason: CheckpointReason) {
        *self.fail_next_reason.lock().unwrap() = Some(reason);
    }

    fn last_checkpoint(&self) -> ProductionCheckpoint {
        self.last_checkpoint
            .lock()
            .unwrap()
            .clone()
            .expect("a checkpoint was committed")
    }
}

impl AccountingStore for FailOneCurrentCheckpoint {
    fn load_producer_checkpoint_state(
        &self,
    ) -> Result<ProducerCheckpointState, ProductionCheckpointError> {
        self.inner.load_producer_checkpoint_state()
    }

    fn commit_production_checkpoint(
        &self,
        checkpoint: &ProductionCheckpoint,
    ) -> Result<CheckpointAck, ProductionCheckpointError> {
        if checkpoint.reason == CheckpointReason::CurrentRead
            && self.fail_next_current.swap(false, Ordering::SeqCst)
        {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "injected current checkpoint failure".to_owned(),
            ));
        }
        if self
            .fail_next_reason
            .lock()
            .unwrap()
            .is_some_and(|reason| reason == checkpoint.reason)
        {
            *self.fail_next_reason.lock().unwrap() = None;
            return Err(ProductionCheckpointError::InvalidCheckpoint(format!(
                "injected {:?} checkpoint failure",
                checkpoint.reason
            )));
        }
        let ack = self.inner.commit_production_checkpoint(checkpoint)?;
        *self.last_checkpoint.lock().unwrap() = Some(checkpoint.clone());
        Ok(ack)
    }

    fn write_canonical_batch(
        &self,
        batch: &timetrace_core::CanonicalBatch,
    ) -> Result<(), AccountingError> {
        self.inner.write_canonical_batch(batch)
    }

    fn load_accounting_intervals(
        &self,
        range: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        self.inner.load_accounting_intervals(range)
    }

    fn durable_observed_through(&self) -> Result<Option<chrono::DateTime<Utc>>, AccountingError> {
        self.inner.durable_observed_through()
    }

    fn last_known_observed_through(&self) -> Option<chrono::DateTime<Utc>> {
        self.inner.last_known_observed_through()
    }

    fn refresh_current(
        &self,
        as_of: chrono::DateTime<Utc>,
    ) -> Result<Option<chrono::DateTime<Utc>>, AccountingError> {
        self.inner.refresh_current(as_of)
    }

    fn load_last_durable_intervals(
        &self,
        range: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        self.inner.load_last_durable_intervals(range)
    }

    fn recover_after_restart(&self, point: &RecoveryPoint) -> Result<(), AccountingError> {
        self.inner.recover_after_restart(point)
    }
}

#[test]
fn canonical_current_fence_survives_failure_and_fences_lifecycle() {
    let (path, raw_store) = isolated_db("canonical-current");
    let sqlite = Arc::new(raw_store);
    let accounting = Arc::new(FailOneCurrentCheckpoint::new(sqlite.clone()));
    let start = Utc::now().with_nanosecond(0).unwrap() - Duration::seconds(5);
    let clock = FixedAccountingClock::new(start);
    let legacy_sink = Box::new(SessionAggregator::new(sqlite.clone()));
    let handle = run_canonical_monitor_loop(
        FixedWindow,
        NeverIdle,
        StdDuration::from_millis(5),
        StdDuration::from_secs(300),
        Vec::new(),
        legacy_sink,
        accounting.clone(),
        sqlite,
        Arc::new(clock.clone()),
    );
    std::thread::sleep(StdDuration::from_millis(40));

    let requested = UtcInterval::new(start, start + Duration::seconds(90)).unwrap();
    clock.set(start + Duration::seconds(20));
    let first = current_accounting_snapshot(
        &handle,
        &*accounting,
        &clock,
        requested.clone(),
        StdDuration::from_secs(2),
    )
    .expect("first Current snapshot");
    assert_eq!(first.observed_through, start + Duration::seconds(20));
    assert_eq!(first.effective.end, start + Duration::seconds(20));
    assert_eq!(first.totals.accounted_seconds(), 20);

    accounting.fail_next_current();
    clock.set(start + Duration::seconds(30));
    let partial = current_accounting_snapshot(
        &handle,
        &*accounting,
        &clock,
        requested.clone(),
        StdDuration::from_secs(2),
    )
    .expect("failed checkpoint still yields the one canonical partial snapshot");
    assert_eq!(partial.integrity, SnapshotIntegrity::Partial);
    assert_eq!(partial.observed_through, start + Duration::seconds(20));
    assert_eq!(partial.effective.end, start + Duration::seconds(30));
    assert!(partial.totals.unknown_seconds >= 10);
    assert_eq!(partial.totals.accounted_seconds(), 30);

    clock.set(start + Duration::seconds(40));
    let recovered = current_accounting_snapshot(
        &handle,
        &*accounting,
        &clock,
        requested.clone(),
        StdDuration::from_secs(2),
    )
    .expect("checkpoint worker remains alive after a typed failure");
    assert_eq!(recovered.observed_through, start + Duration::seconds(40));
    assert_eq!(recovered.totals.accounted_seconds(), 40);
    assert!(recovered.totals.active_seconds >= first.totals.active_seconds);

    clock.set(start + Duration::seconds(45));
    let timeout = handle
        .checkpoint_current(StdDuration::ZERO)
        .expect_err("zero checkpoint budget is a deterministic timeout");
    assert_eq!(timeout.requested_as_of, start + Duration::seconds(45));
    assert_eq!(
        timeout.last_acknowledged_observed_through,
        Some(start + Duration::seconds(40))
    );

    accounting.fail_next(CheckpointReason::Pause);
    clock.set(start + Duration::seconds(50));
    let pause_failure = handle
        .pause(StdDuration::from_secs(2))
        .expect_err("injected Pause commit failure");
    assert_eq!(pause_failure.requested_as_of, start + Duration::seconds(50));
    assert_eq!(
        pause_failure.last_acknowledged_observed_through,
        Some(start + Duration::seconds(40))
    );

    clock.set(start + Duration::seconds(55));
    let third = current_accounting_snapshot(
        &handle,
        &*accounting,
        &clock,
        requested.clone(),
        StdDuration::from_secs(2),
    )
    .expect("monitor remains live after compensated Pause failure");
    assert_eq!(third.totals.accounted_seconds(), 55);
    assert!(third.totals.active_seconds > recovered.totals.active_seconds);
    let raw = accounting
        .load_accounting_intervals(&UtcInterval::new(start, third.observed_through).unwrap())
        .expect("load all committed increments");
    let sources: BTreeSet<_> = raw
        .iter()
        .filter(|item| item.source_identity.contains(":interval:"))
        .map(|item| item.source_identity.as_str())
        .collect();
    assert!(
        sources.len() >= 3,
        "each increment keeps a unique stable source"
    );

    clock.set(start + Duration::seconds(60));
    let paused = handle
        .pause(StdDuration::from_secs(2))
        .expect("pause fence");
    assert_eq!(paused.lifecycle, CheckpointReason::Pause);
    assert_eq!(
        paused.durable_observed_through,
        start + Duration::seconds(60)
    );
    clock.set(start + Duration::seconds(70));
    let resumed = handle
        .resume(StdDuration::from_secs(2))
        .expect("resume fence");
    assert_eq!(resumed.lifecycle, CheckpointReason::Resume);
    assert_eq!(
        resumed.durable_observed_through,
        start + Duration::seconds(70)
    );
    clock.set(start + Duration::seconds(80));
    let stopped = handle
        .stop(StdDuration::from_secs(2))
        .expect("stop fence and joins");
    assert_eq!(stopped.lifecycle, CheckpointReason::Stop);
    assert_eq!(
        stopped.durable_observed_through,
        start + Duration::seconds(80)
    );

    let stop_checkpoint = accounting.last_checkpoint();
    let range = UtcInterval::new(start, start + Duration::seconds(80)).unwrap();
    let rows_before_restart = accounting
        .load_accounting_intervals(&range)
        .expect("rows before restart");
    drop(accounting);
    let reopened = SqliteStore::open(path.clone()).expect("reopen canonical ledger");
    let replay = reopened
        .commit_production_checkpoint(&stop_checkpoint)
        .expect("exact replay after restart");
    assert!(replay.replayed);
    assert_eq!(
        reopened.load_accounting_intervals(&range).unwrap(),
        rows_before_restart
    );
    let restart_clock = FixedAccountingClock::new(start + Duration::seconds(80));
    let after_restart = AccountingQueryService::new(&reopened, &restart_clock)
        .snapshot(range.clone(), AccountingQuery::At { as_of: range.end })
        .expect("snapshot after restart and exact replay");
    assert_eq!(after_restart.totals.accounted_seconds(), 80);

    drop(reopened);
    let _ = std::fs::remove_file(path);
}
