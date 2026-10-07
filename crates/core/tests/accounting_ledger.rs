use std::collections::BTreeSet;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};

use chrono::{DateTime, NaiveDate, Utc};
use serde_json::{Value, json};
use timetrace_core::{
    AccountingError, AccountingInterval, AccountingQuery, AccountingQueryService,
    AccountingReducer, AccountingSignal, AccountingState, AccountingStore, AppInfo,
    AttributionIdentity, CanonicalBatch, CheckpointReason, DataStore, EventSink,
    FixedAccountingClock, IanaLocalDayProjection, IdleDetector, ProducerCheckpointState,
    ProductionCheckpoint, ProductionCheckpointError, RecoveryPoint, SessionAggregator,
    SessionRecord, SnapshotIntegrity, SqliteStore, TrackedEvent, UtcInterval, WindowResolver,
    run_monitor_loop,
};

static NEXT_DB: AtomicUsize = AtomicUsize::new(0);

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("tests")
        .join("fixtures")
        .join("accounting")
        .join(name);
    serde_json::from_reader(File::open(path).unwrap()).unwrap()
}

fn scenario<'a>(document: &'a Value, id: &str) -> &'a Value {
    document["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == id)
        .unwrap()
}

fn expectation<'a>(document: &'a Value, id: &str) -> &'a Value {
    &document["expectations"][id]
}

fn ts(value: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(value)
        .unwrap()
        .with_timezone(&Utc)
}

fn json_ts(value: &Value) -> DateTime<Utc> {
    ts(value.as_str().unwrap())
}

fn range(start: &str, end: &str) -> UtcInterval {
    UtcInterval::new(ts(start), ts(end)).unwrap()
}

fn identity(app: &str) -> AttributionIdentity {
    AttributionIdentity {
        app_id: Some(app.to_owned()),
        window_id: Some(format!("{app}.window")),
        window_app_id: Some(app.to_owned()),
        page_id: Some(format!("{app}.page")),
        page_window_id: Some(format!("{app}.window")),
    }
}

fn interval(
    start: &str,
    end: &str,
    state: AccountingState,
    app: Option<&str>,
    source: &str,
    revision: i64,
) -> AccountingInterval {
    AccountingInterval {
        range: range(start, end),
        state,
        attribution: app.map(identity).unwrap_or_default(),
        source_identity: source.to_owned(),
        source_revision: revision,
    }
}

fn checkpoint(
    state: &ProducerCheckpointState,
    reason: CheckpointReason,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    producer_revision: i64,
    accounting_state: AccountingState,
) -> ProductionCheckpoint {
    let first_cutover = reason == CheckpointReason::FirstCutover;
    ProductionCheckpoint::staged(
        reason,
        end,
        state.observed_through(),
        "fixture:producer:v8".to_owned(),
        producer_revision,
        CanonicalBatch {
            intervals: vec![AccountingInterval {
                range: UtcInterval::new(start, end).unwrap(),
                state: accounting_state,
                attribution: if accounting_state == AccountingState::Active {
                    identity("editor.synthetic")
                } else {
                    AttributionIdentity::default()
                },
                source_identity: format!("fixture:checkpoint:interval:{producer_revision}"),
                source_revision: 0,
            }],
            observed_through: end,
        },
        first_cutover,
    )
    .unwrap()
}

fn legacy_signature(
    store: &SqliteStore,
    date: NaiveDate,
) -> Vec<(String, Option<DateTime<Utc>>, Option<i64>)> {
    store
        .get_sessions_by_date(date)
        .into_iter()
        .map(|row| (row.app_name, row.ended_at, row.duration_secs))
        .collect()
}

#[derive(Clone, Copy)]
enum Refresh {
    Keep,
    Advance(DateTime<Utc>),
    Fail,
}

struct FixtureStore {
    intervals: Vec<AccountingInterval>,
    watermark: Mutex<DateTime<Utc>>,
    refresh: Refresh,
    watermark_read_fails: bool,
    primary_read_fails: bool,
    refresh_calls: AtomicUsize,
}

impl FixtureStore {
    fn new(intervals: Vec<AccountingInterval>, watermark: DateTime<Utc>) -> Self {
        Self {
            intervals,
            watermark: Mutex::new(watermark),
            refresh: Refresh::Keep,
            watermark_read_fails: false,
            primary_read_fails: false,
            refresh_calls: AtomicUsize::new(0),
        }
    }

    fn clipped(&self, requested: &UtcInterval) -> Vec<AccountingInterval> {
        self.intervals
            .iter()
            .filter_map(|item| {
                item.range
                    .intersection(requested)
                    .map(|range| AccountingInterval {
                        range,
                        ..item.clone()
                    })
            })
            .collect()
    }
}

impl AccountingStore for FixtureStore {
    fn write_canonical_batch(&self, _: &CanonicalBatch) -> Result<(), AccountingError> {
        unreachable!("fixture query store is read-only")
    }

    fn load_accounting_intervals(
        &self,
        requested: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        if self.primary_read_fails {
            Err(AccountingError::Storage("fixture primary read".into()))
        } else {
            Ok(self.clipped(requested))
        }
    }

    fn durable_observed_through(&self) -> Result<Option<DateTime<Utc>>, AccountingError> {
        if self.watermark_read_fails {
            Err(AccountingError::Storage("fixture watermark read".into()))
        } else {
            Ok(Some(*self.watermark.lock().unwrap()))
        }
    }

    fn last_known_observed_through(&self) -> Option<DateTime<Utc>> {
        Some(*self.watermark.lock().unwrap())
    }

    fn refresh_current(&self, _: DateTime<Utc>) -> Result<Option<DateTime<Utc>>, AccountingError> {
        self.refresh_calls.fetch_add(1, Ordering::SeqCst);
        match self.refresh {
            Refresh::Keep => Ok(Some(*self.watermark.lock().unwrap())),
            Refresh::Advance(next) => {
                *self.watermark.lock().unwrap() = next;
                Ok(Some(next))
            }
            Refresh::Fail => Err(AccountingError::Storage("fixture checkpoint".into())),
        }
    }

    fn load_last_durable_intervals(
        &self,
        requested: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        Ok(self.clipped(requested))
    }

    fn recover_after_restart(&self, _: &RecoveryPoint) -> Result<(), AccountingError> {
        unreachable!("fixture query store does not recover")
    }
}

fn snapshot(
    store: &FixtureStore,
    clock: DateTime<Utc>,
    requested: UtcInterval,
    query: AccountingQuery,
) -> timetrace_core::AccountingSnapshot {
    AccountingQueryService::new(store, &FixedAccountingClock::new(clock))
        .snapshot(requested, query)
        .unwrap()
}

fn temp_db(label: &str) -> (SqliteStore, PathBuf) {
    let serial = NEXT_DB.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-accounting-fixture-{label}-{}-{serial}.sqlite3",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    (SqliteStore::open(path.clone()).unwrap(), path)
}

fn temp_db_path(label: &str) -> PathBuf {
    let serial = NEXT_DB.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-accounting-fixture-{label}-{}-{serial}.sqlite3",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn app_from_fixture(name: &str) -> AppInfo {
    AppInfo::new(format!("synthetic/{name}.exe"), name.to_owned())
        .with_title(format!("{name}.window"))
}

struct FixtureResolver {
    app: AppInfo,
    calls: mpsc::Sender<()>,
}

impl WindowResolver for FixtureResolver {
    fn get_foreground_app(&self) -> Option<AppInfo> {
        let _ = self.calls.send(());
        Some(self.app.clone())
    }

    fn get_window_title(&self, _: isize) -> Option<String> {
        None
    }
}

struct FixtureIdle(Arc<AtomicBool>);

impl IdleDetector for FixtureIdle {
    fn is_idle(&self, _: std::time::Duration) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    fn idle_duration(&self) -> std::time::Duration {
        std::time::Duration::ZERO
    }
}

#[test]
fn open_tail_and_active_idle_fixtures_conserve_and_attribute_only_active() {
    let scenarios = fixture("scenarios.json");
    let expected = fixture("expected.json");

    let open = scenario(&scenarios, "closed_40_open_20");
    let open_range =
        UtcInterval::new(json_ts(&open["range"][0]), json_ts(&open["range"][1])).unwrap();
    let records = open["durable_records"].as_array().unwrap();
    assert!(
        records[1]["end"].is_null(),
        "fixture must retain an open tail"
    );
    let open_db = Arc::new(SqliteStore::open(temp_db_path("open-tail")).unwrap());
    let mut open_aggregator = SessionAggregator::new(open_db.clone());
    let first = app_from_fixture(records[0]["app"].as_str().unwrap());
    open_aggregator.accept(TrackedEvent::AppSwitched {
        previous: None,
        current: first.clone(),
        timestamp: json_ts(&records[0]["start"]),
    });
    let second = app_from_fixture(records[1]["app"].as_str().unwrap());
    open_aggregator.accept(TrackedEvent::AppSwitched {
        previous: Some(first),
        current: second.clone(),
        timestamp: json_ts(&records[1]["start"]),
    });
    open_aggregator.observation_checkpoint(second, json_ts(&records[1]["observed_through"]));
    let open_snapshot = AccountingQueryService::new(
        open_db.as_ref(),
        &FixedAccountingClock::new(ts("2026-01-15T12:00:00Z")),
    )
    .snapshot(
        open_range,
        AccountingQuery::At {
            as_of: json_ts(&records[1]["observed_through"]),
        },
    )
    .unwrap();
    let open_totals = &expectation(&expected, "closed_40_open_20")["totals"];
    assert_eq!(open_snapshot.totals.active_seconds, open_totals["active"]);
    assert_eq!(open_snapshot.totals.idle_seconds, 0);
    assert_eq!(open_snapshot.totals.accounted_seconds(), 3600);

    let mixed = scenario(&scenarios, "active_idle_one_hour");
    let mixed_range =
        UtcInterval::new(json_ts(&mixed["range"][0]), json_ts(&mixed["range"][1])).unwrap();
    let series = &mixed["observation_series"][0];
    let last_input = mixed["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["kind"] == "last_input")
        .unwrap();
    let idle_threshold = scenarios["defaults"]["idle_threshold_seconds"]
        .as_i64()
        .unwrap();
    let idle_start = json_ts(&last_input["event_time"]) + chrono::Duration::seconds(idle_threshold);
    let mixed_db = Arc::new(SqliteStore::open(temp_db_path("active-idle")).unwrap());
    let mut mixed_aggregator = SessionAggregator::new(mixed_db.clone());
    mixed_aggregator.accept(TrackedEvent::AppSwitched {
        previous: None,
        current: app_from_fixture(series["app"].as_str().unwrap()),
        timestamp: json_ts(&series["start"]),
    });
    mixed_aggregator.accept(TrackedEvent::IdleStarted {
        timestamp: idle_start,
        grace: std::time::Duration::ZERO,
    });
    mixed_aggregator.observation_checkpoint(AppInfo::idle(), mixed_range.end);
    let mixed_snapshot = AccountingQueryService::new(
        mixed_db.as_ref(),
        &FixedAccountingClock::new(ts("2026-01-15T12:00:00Z")),
    )
    .snapshot(
        mixed_range,
        AccountingQuery::At {
            as_of: ts("2026-01-15T11:00:00Z"),
        },
    )
    .unwrap();
    let mixed_totals = &expectation(&expected, "active_idle_one_hour")["totals"];
    assert_eq!(mixed_snapshot.totals.active_seconds, mixed_totals["active"]);
    assert_eq!(mixed_snapshot.totals.idle_seconds, mixed_totals["idle"]);
    assert_eq!(
        mixed_snapshot.totals.accounted_seconds(),
        mixed_totals["accounted"]
    );
    assert_eq!(
        mixed_snapshot
            .attribution
            .apps
            .iter()
            .map(|item| item.seconds)
            .sum::<i64>(),
        mixed_snapshot.totals.active_seconds
    );
    assert_eq!(
        mixed_snapshot
            .attribution
            .windows
            .iter()
            .map(|item| item.seconds)
            .sum::<i64>(),
        mixed_snapshot.totals.active_seconds
    );
    assert_eq!(
        mixed_snapshot
            .attribution
            .pages
            .iter()
            .map(|item| item.seconds)
            .sum::<i64>(),
        mixed_snapshot.totals.active_seconds
    );
    let day = IanaLocalDayProjection
        .project(
            "Etc/UTC",
            NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
            &mixed_snapshot,
        )
        .unwrap();
    assert_eq!(
        day.hours
            .iter()
            .map(|hour| hour.totals.active_seconds)
            .sum::<i64>(),
        mixed_snapshot.totals.active_seconds
    );
}

#[test]
fn resolver_poll_and_identity_fixtures_preserve_evidence_and_hierarchy() {
    let expected = fixture("expected.json");
    let requested = range("2026-01-15T12:00:00Z", "2026-01-15T12:20:00Z");
    let signal = |start: &str,
                  end: &str,
                  state: &str,
                  evidence: Value,
                  attribution: Value|
     -> AccountingSignal {
        serde_json::from_value(json!({
            "interval": {"start": start, "end": end},
            "state": state,
            "evidence": evidence,
            "attribution": attribution
        }))
        .unwrap()
    };
    let signals = vec![
        signal(
            "2026-01-15T12:00:00Z",
            "2026-01-15T12:00:07Z",
            "system_gap",
            json!("resolver_failure"),
            json!({}),
        ),
        signal(
            "2026-01-15T12:00:07Z",
            "2026-01-15T12:10:00Z",
            "system_gap",
            json!("observation_missing"),
            json!({}),
        ),
        signal(
            "2026-01-15T12:10:00Z",
            "2026-01-15T12:15:00Z",
            "active",
            json!("observation"),
            json!({
                "app_id": "browser.synthetic",
                "window_id": "browser.window",
                "window_app_id": "different.app",
                "page_id": "browser.page",
                "page_window_id": "different.window"
            }),
        ),
        signal(
            "2026-01-15T12:15:00Z",
            "2026-01-15T12:18:00Z",
            "unknown",
            json!({"lifecycle_gap": {"precise": true}}),
            json!({}),
        ),
        signal(
            "2026-01-15T12:18:00Z",
            "2026-01-15T12:19:00Z",
            "system_gap",
            json!({"lifecycle_gap": {"precise": false}}),
            json!({}),
        ),
        signal(
            "2026-01-15T12:19:00Z",
            "2026-01-15T12:20:00Z",
            "active",
            json!("observation"),
            json!({"app_id": "terminal.synthetic"}),
        ),
    ];
    let reduced = AccountingReducer.reduce_signals(&requested, &signals);
    let store = FixtureStore::new(reduced, requested.end);
    let snapshot = snapshot(
        &store,
        requested.end,
        requested,
        AccountingQuery::At {
            as_of: ts("2026-01-15T12:20:00Z"),
        },
    );
    let totals = &expectation(&expected, "continuity_and_attribution")["totals"];
    assert_eq!(snapshot.totals.active_seconds, totals["active"]);
    assert_eq!(snapshot.totals.system_gap_seconds, totals["system_gap"]);
    assert_eq!(snapshot.totals.unknown_seconds, totals["unknown"]);
    assert_eq!(snapshot.totals.accounted_seconds(), 1200);
    assert!(
        snapshot
            .attribution
            .apps
            .iter()
            .any(|item| item.id == "__UNATTRIBUTED_APP__" && item.seconds == 7)
    );
    let app_ids: BTreeSet<_> = snapshot
        .attribution
        .apps
        .iter()
        .map(|item| item.id.as_str())
        .collect();
    let window_ids: BTreeSet<_> = snapshot
        .attribution
        .windows
        .iter()
        .map(|item| item.id.as_str())
        .collect();
    assert!(snapshot.attribution.windows.iter().all(|item| {
        item.parent_id
            .as_deref()
            .is_some_and(|parent| app_ids.contains(parent))
    }));
    assert!(snapshot.attribution.pages.iter().all(|item| {
        item.parent_id
            .as_deref()
            .is_some_and(|parent| window_ids.contains(parent))
    }));
    assert_eq!(
        snapshot
            .attribution
            .apps
            .iter()
            .map(|item| item.seconds)
            .sum::<i64>(),
        snapshot.totals.active_seconds
    );
}

#[test]
fn pause_stop_and_crash_recovery_fixtures_keep_boundaries_durable() {
    let scenarios = fixture("scenarios.json");
    let expected = fixture("expected.json");
    let pause_range = range("2026-01-15T13:00:00Z", "2026-01-15T13:30:00Z");
    let signals: Vec<AccountingSignal> = vec![
        serde_json::from_value(json!({"interval":{"start":"2026-01-15T13:00:00Z","end":"2026-01-15T13:10:00Z"},"state":"active","evidence":"observation","attribution":{"app_id":"editor.synthetic"}})).unwrap(),
        serde_json::from_value(json!({"interval":{"start":"2026-01-15T13:10:00Z","end":"2026-01-15T13:20:00Z"},"state":"active","evidence":"pause"})).unwrap(),
        serde_json::from_value(json!({"interval":{"start":"2026-01-15T13:20:00Z","end":"2026-01-15T13:21:00Z"},"state":"active","evidence":"observation_missing"})).unwrap(),
        serde_json::from_value(json!({"interval":{"start":"2026-01-15T13:21:00Z","end":"2026-01-15T13:30:00Z"},"state":"active","evidence":"observation","attribution":{"app_id":"editor.synthetic"}})).unwrap(),
    ];
    let pause_rows = AccountingReducer.reduce_signals(&pause_range, &signals);
    let pause_store = FixtureStore::new(pause_rows, pause_range.end);
    let pause = snapshot(
        &pause_store,
        pause_range.end,
        pause_range,
        AccountingQuery::At {
            as_of: ts("2026-01-15T13:30:00Z"),
        },
    );
    let pause_expected = &expectation(&expected, "pause_resume")["totals"];
    assert_eq!(pause.totals.active_seconds, pause_expected["active"]);
    assert_eq!(pause.totals.paused_seconds, pause_expected["paused"]);
    assert_eq!(pause.totals.unknown_seconds, pause_expected["unknown"]);

    let stop_fixture = scenario(&scenarios, "normal_stop");
    assert_eq!(stop_fixture["events"].as_array().unwrap().len(), 5);
    let stop_db = Arc::new(SqliteStore::open(temp_db_path("monitor-stop")).unwrap());
    let (calls_tx, calls_rx) = mpsc::channel();
    let handle = run_monitor_loop(
        FixtureResolver {
            app: app_from_fixture("editor.synthetic"),
            calls: calls_tx,
        },
        FixtureIdle(Arc::new(AtomicBool::new(false))),
        std::time::Duration::from_millis(100),
        std::time::Duration::from_millis(400),
        vec![],
        Box::new(SessionAggregator::new(stop_db.clone())),
    );
    for _ in 0..12 {
        calls_rx
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
    }
    assert!(
        handle.stop(),
        "stop acknowledgement includes fence and joins"
    );
    assert!(stop_db.get_active_session().is_none());
    assert!(stop_db.durable_observed_through().unwrap().is_some());

    let crash_fixture = scenario(&scenarios, "crash_unknown_tail");
    let crash_expected = expectation(&expected, "crash_unknown_tail");
    let mut variant_totals = Vec::new();
    for (index, kill) in crash_fixture["kill_variants"]
        .as_array()
        .unwrap()
        .iter()
        .enumerate()
    {
        let path = temp_db_path(&format!("crash-{index}"));
        let store = Arc::new(SqliteStore::open(path).unwrap());
        let durable = &crash_fixture["durable_records"][0];
        let app = app_from_fixture(durable["app"].as_str().unwrap());
        let mut aggregator = SessionAggregator::new(store.clone());
        aggregator.accept(TrackedEvent::AppSwitched {
            previous: None,
            current: app.clone(),
            timestamp: json_ts(&durable["start"]),
        });
        aggregator.observation_checkpoint(app, json_ts(&durable["end"]));
        assert!(json_ts(kill) > json_ts(&durable["end"]));
        drop(aggregator);
        assert_eq!(
            store.durable_observed_through().unwrap(),
            Some(json_ts(&crash_fixture["durable_observed_through"]))
        );
        let first_observation = json_ts(&crash_fixture["events"][1]["event_time"]);
        let recovery = RecoveryPoint {
            restart_at: json_ts(&crash_fixture["restart_at_metadata"]),
            first_successful_observation: first_observation,
            lifecycle: None,
            source_identity: format!("recovery:synthetic-{index}"),
            source_revision: 1,
        };
        store.recover_after_restart(&recovery).unwrap();
        let query_range = UtcInterval::new(
            json_ts(&crash_fixture["range"][0]),
            json_ts(&crash_fixture["range"][1]),
        )
        .unwrap();
        let rows_after_first = store.load_accounting_intervals(&query_range).unwrap();
        store.recover_after_restart(&recovery).unwrap();
        assert_eq!(
            rows_after_first,
            store.load_accounting_intervals(&query_range).unwrap(),
            "recovery replay must be idempotent"
        );
        let crash = AccountingQueryService::new(
            store.as_ref(),
            &FixedAccountingClock::new(ts("2026-01-15T15:00:00Z")),
        )
        .snapshot(
            query_range,
            AccountingQuery::At {
                as_of: first_observation,
            },
        )
        .unwrap();
        assert_eq!(
            crash.totals.active_seconds,
            crash_expected["segments"][0]["seconds"]
        );
        assert_eq!(
            crash.totals.unknown_seconds,
            crash_expected["segments"][1]["seconds"]
        );
        assert!(crash.intervals.iter().all(|item| {
            item.range.end <= json_ts(&durable["end"]) || item.state != AccountingState::Active
        }));
        variant_totals.push(crash.totals);
    }
    assert_eq!(variant_totals[0], variant_totals[1]);

    let failed_fixture = scenario(&scenarios, "checkpoint_failure_then_kill");
    let failed_path = temp_db_path("failed-checkpoint");
    let failed_store = Arc::new(SqliteStore::open(failed_path.clone()).unwrap());
    let series = &failed_fixture["observation_series"][0];
    let mut aggregator = SessionAggregator::new(failed_store.clone());
    let app = app_from_fixture(series["app"].as_str().unwrap());
    aggregator.accept(TrackedEvent::AppSwitched {
        previous: None,
        current: app.clone(),
        timestamp: json_ts(&series["start"]),
    });
    let committed = failed_fixture["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["kind"] == "checkpoint_committed")
        .unwrap();
    aggregator.observation_checkpoint(app.clone(), json_ts(&committed["observed_through"]));
    let raw = rusqlite::Connection::open(&failed_path).unwrap();
    raw.execute_batch(
        "CREATE TRIGGER fixture_fail_checkpoint
         BEFORE UPDATE OF duration_secs ON usage_sessions
         WHEN NEW.duration_secs > 600
         BEGIN SELECT RAISE(ABORT, 'fixture checkpoint failure'); END;",
    )
    .unwrap();
    drop(raw);
    let failed = failed_fixture["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["kind"] == "checkpoint_failed")
        .unwrap();
    aggregator.observation_checkpoint(app, json_ts(&failed["candidate_observed_through"]));
    assert_eq!(
        aggregator.durable_observed_through(),
        Some(json_ts(&committed["observed_through"]))
    );
    drop(aggregator);
    assert_eq!(
        failed_store.durable_observed_through().unwrap(),
        Some(json_ts(&committed["observed_through"]))
    );
    let first_observation = json_ts(&failed_fixture["events"][4]["event_time"]);
    let recovery = RecoveryPoint {
        restart_at: json_ts(&failed_fixture["events"][3]["event_time"]),
        first_successful_observation: first_observation,
        lifecycle: None,
        source_identity: "recovery:failed-checkpoint".into(),
        source_revision: 1,
    };
    failed_store.recover_after_restart(&recovery).unwrap();
    let failed_snapshot = AccountingQueryService::new(
        failed_store.as_ref(),
        &FixedAccountingClock::new(first_observation),
    )
    .snapshot(
        UtcInterval::new(
            json_ts(&failed_fixture["range"][0]),
            json_ts(&failed_fixture["range"][1]),
        )
        .unwrap(),
        AccountingQuery::At {
            as_of: first_observation,
        },
    )
    .unwrap();
    let failed_expected = expectation(&expected, "checkpoint_failure_then_kill");
    assert_eq!(
        failed_snapshot.totals.active_seconds,
        failed_expected["segments"][0]["seconds"]
    );
    assert_eq!(
        failed_snapshot.totals.unknown_seconds,
        failed_expected["segments"][1]["seconds"]
    );
}

#[test]
fn current_and_historical_queries_share_effective_end_and_degrade_conservatively() {
    let scenarios = fixture("scenarios.json");
    let expected = fixture("expected.json");
    let matrix = scenario(&scenarios, "as_of_matrix");
    let requested =
        UtcInterval::new(json_ts(&matrix["range"][0]), json_ts(&matrix["range"][1])).unwrap();
    let facts = vec![interval(
        "2026-01-15T17:59:00Z",
        "2026-01-15T18:00:00Z",
        AccountingState::Active,
        Some("editor.synthetic"),
        "query-source",
        1,
    )];
    let old_watermark = ts("2026-01-15T17:59:50Z");
    let expected_matrix = &expectation(&expected, "as_of_matrix");
    let now = json_ts(&matrix["request_now"]);
    let mut consumed = BTreeSet::new();
    for case in matrix["queries"].as_array().unwrap() {
        let id = case["id"].as_str().unwrap();
        assert!(
            consumed.insert(id.to_owned()),
            "duplicate query fixture {id}"
        );
        let mut store = FixtureStore::new(facts.clone(), old_watermark);
        let query = if case["kind"] == "at" {
            AccountingQuery::At {
                as_of: json_ts(&case["value"]),
            }
        } else {
            match id {
                "current_success" => store.refresh = Refresh::Advance(now),
                "current_sample_failed" | "current_sample_timeout" | "current_commit_failure" => {
                    store.refresh = Refresh::Fail
                }
                "current_read_failure" => store.primary_read_fails = true,
                other => panic!("unmapped current fixture {other}"),
            }
            AccountingQuery::Current
        };
        let result = AccountingQueryService::new(&store, &FixedAccountingClock::new(now))
            .snapshot(requested.clone(), query);
        let case_expected = &expected_matrix[id];
        if id == "future" {
            assert!(matches!(result, Err(AccountingError::FutureAsOf { .. })));
            assert_eq!(
                store.refresh_calls.load(Ordering::SeqCst),
                case_expected["refresh_calls"]
            );
            continue;
        }
        let result = result.unwrap();
        assert_eq!(
            result.effective.end,
            json_ts(&case_expected["effective_end"])
        );
        assert_eq!(result.totals.active_seconds, case_expected["active"]);
        assert_eq!(result.totals.unknown_seconds, case_expected["unknown"]);
        assert_eq!(
            result.totals.accounted_seconds(),
            result.effective.seconds()
        );
        assert_eq!(
            store.refresh_calls.load(Ordering::SeqCst),
            case_expected["refresh_calls"]
        );
        let expected_integrity = if case_expected["integrity"] == "complete" {
            SnapshotIntegrity::Complete
        } else {
            SnapshotIntegrity::Partial
        };
        assert_eq!(result.integrity, expected_integrity);
        if let Some(observed) = case_expected["observed_through"].as_str() {
            assert_eq!(result.observed_through, ts(observed));
        }
        assert!(
            result
                .intervals
                .iter()
                .all(|item| item.range.end <= result.effective.end)
        );
    }
    let expected_ids: BTreeSet<_> = expected_matrix
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    assert_eq!(consumed, expected_ids);
}

#[test]
fn utc_midnight_and_iana_days_use_half_open_machine_independent_buckets() {
    let dst = fixture("dst_buckets.json");
    let expected = fixture("expected.json");
    let fact = interval(
        "2026-01-15T23:50:00Z",
        "2026-01-16T00:10:00Z",
        AccountingState::Active,
        Some("editor.synthetic"),
        "cross-midnight",
        1,
    );
    let store = FixtureStore::new(vec![fact], ts("2026-01-17T00:00:00Z"));
    for (start, end, key) in [
        ("2026-01-15T00:00:00Z", "2026-01-16T00:00:00Z", "2026-01-15"),
        ("2026-01-16T00:00:00Z", "2026-01-17T00:00:00Z", "2026-01-16"),
    ] {
        let day = snapshot(
            &store,
            ts("2026-01-17T00:00:00Z"),
            range(start, end),
            AccountingQuery::At { as_of: ts(end) },
        );
        assert_eq!(
            day.totals.active_seconds,
            expectation(&expected, "cross_midnight")[key]["active_seconds"]
        );
    }

    let projection = IanaLocalDayProjection;
    let zone = dst["timezone"].as_str().unwrap();
    for (fixture_key, seconds) in [
        ("normal_day", 86_400),
        ("spring_forward", 82_800),
        ("fall_back", 90_000),
    ] {
        let locked = &dst[fixture_key];
        let date =
            NaiveDate::parse_from_str(locked["local_date"].as_str().unwrap(), "%Y-%m-%d").unwrap();
        let day_range = projection.utc_day_range(zone, date).unwrap();
        assert_eq!(day_range.start, json_ts(&locked["day_start_utc"]));
        assert_eq!(day_range.end, json_ts(&locked["day_end_utc"]));
        assert_eq!(day_range.seconds(), seconds);
        let full_store = FixtureStore::new(
            vec![AccountingInterval {
                range: day_range.clone(),
                state: AccountingState::Unknown,
                attribution: AttributionIdentity::default(),
                source_identity: "full-day".into(),
                source_revision: 1,
            }],
            day_range.end,
        );
        let day_snapshot = snapshot(
            &full_store,
            day_range.end,
            day_range.clone(),
            AccountingQuery::At {
                as_of: day_range.end,
            },
        );
        let projected = projection.project(zone, date, &day_snapshot).unwrap();
        let locked_buckets = locked["buckets"].as_array().unwrap();
        assert_eq!(projected.hours.len(), locked_buckets.len());
        for (index, (actual, expected_bucket)) in projected
            .hours
            .iter()
            .zip(locked_buckets.iter())
            .enumerate()
        {
            let wall_hour: u32 = expected_bucket[0].as_str().unwrap().parse().unwrap();
            let start = json_ts(&expected_bucket[1]);
            let end = json_ts(&expected_bucket[2]);
            let offset = expected_bucket[3].as_i64().unwrap() as i32;
            let fold = expected_bucket[4].as_u64().unwrap() as u8;
            assert_eq!(actual.local_hour, wall_hour, "{fixture_key} bucket {index}");
            assert_eq!(actual.range.start, start, "{fixture_key} bucket {index}");
            assert_eq!(actual.range.end, end, "{fixture_key} bucket {index}");
            assert_eq!(
                actual.utc_offset_seconds, offset,
                "{fixture_key} bucket {index}"
            );
            assert_eq!(actual.fold, fold, "{fixture_key} bucket {index}");
            assert_eq!(
                actual.stable_id,
                format!(
                    "{}-{:02}-{:+05}-{}-{}",
                    date,
                    wall_hour,
                    offset,
                    fold,
                    start.timestamp()
                )
            );
            assert_eq!(actual.totals.unknown_seconds, actual.range.seconds());
            if index > 0 {
                assert_eq!(projected.hours[index - 1].range.end, actual.range.start);
            }
        }
        assert_eq!(
            projected
                .hours
                .iter()
                .map(|hour| hour.totals.accounted_seconds())
                .sum::<i64>(),
            seconds
        );
        assert_eq!(projected.totals.accounted_seconds(), seconds);
        let ids: BTreeSet<_> = projected
            .hours
            .iter()
            .map(|hour| hour.stable_id.as_str())
            .collect();
        assert_eq!(ids.len(), projected.hours.len());
        if locked_buckets.len() == 25 {
            let folds: Vec<_> = projected
                .hours
                .iter()
                .filter(|hour| hour.local_hour == 1)
                .collect();
            assert_eq!(folds.len(), 2);
            assert_ne!(folds[0].utc_offset_seconds, folds[1].utc_offset_seconds);
            assert_ne!(folds[0].fold, folds[1].fold);
            assert_ne!(folds[0].stable_id, folds[1].stable_id);
        }
    }
    assert!(matches!(
        projection.utc_day_range(
            "Mars/Olympus",
            NaiveDate::from_ymd_opt(2026, 1, 15).unwrap()
        ),
        Err(AccountingError::InvalidTimeZone(_))
    ));
    assert!(matches!(
        projection.utc_day_range("Etc/UTC", NaiveDate::MAX),
        Err(AccountingError::InvalidLocalBoundary { .. })
    ));
    assert!(matches!(
        UtcInterval::new(ts("2026-01-15T19:00:00Z"), ts("2026-01-15T18:00:00Z")),
        Err(AccountingError::InvalidRange { .. })
    ));
    assert!(NaiveDate::parse_from_str("2026-02-30", "%Y-%m-%d").is_err());
}

#[test]
fn sqlite_cutover_replay_open_legacy_and_transaction_failure_are_conservative() {
    let scenarios = fixture("scenarios.json");
    let expected = fixture("expected.json");
    let migration = scenario(&scenarios, "legacy_migration_restart");
    assert_eq!(migration["migration_attempts"].as_array().unwrap().len(), 3);
    let query_range = UtcInterval::new(
        json_ts(&migration["range"][0]),
        json_ts(&migration["range"][1]),
    )
    .unwrap();
    let migration_path = temp_db_path("legacy-migration");
    let insert_legacy = |store: &SqliteStore, row: &Value| {
        let start = json_ts(&row["start"]);
        let end = row["end"].as_str().map(ts);
        store.insert_session(&SessionRecord {
            id: 0,
            app_path: format!("synthetic/{}.exe", row["app"].as_str().unwrap()),
            app_name: row["app"].as_str().unwrap().to_owned(),
            window_title: Some("synthetic.window".into()),
            started_at: start,
            ended_at: end,
            duration_secs: end.map(|value| (value - start).num_seconds()),
            is_idle: row["is_idle"].as_bool().unwrap(),
            date: start.date_naive(),
        });
    };
    let legacy_rows = migration["legacy_rows"].as_array().unwrap();

    let run1 = SqliteStore::open(migration_path.clone()).unwrap();
    insert_legacy(&run1, &legacy_rows[0]);
    insert_legacy(&run1, &legacy_rows[1]);
    assert_eq!(
        run1.load_accounting_intervals(&query_range).unwrap().len(),
        2
    );
    assert_eq!(
        run1.durable_observed_through().unwrap(),
        Some(json_ts(&legacy_rows[1]["end"]))
    );
    drop(run1);

    let run2 = SqliteStore::open(migration_path.clone()).unwrap();
    insert_legacy(&run2, &legacy_rows[2]);
    let native = &migration["native_rows"][0];
    let canonical = CanonicalBatch {
        intervals: vec![interval(
            native["start"].as_str().unwrap(),
            native["end"].as_str().unwrap(),
            AccountingState::Active,
            Some(native["app"].as_str().unwrap()),
            native["source_id"].as_str().unwrap(),
            1,
        )],
        observed_through: json_ts(&legacy_rows[1]["end"]),
    };
    run2.write_canonical_batch(&canonical).unwrap();
    run2.write_canonical_batch(&canonical).unwrap();
    let after_run2 =
        AccountingQueryService::new(&run2, &FixedAccountingClock::new(query_range.end))
            .snapshot(
                query_range.clone(),
                AccountingQuery::At {
                    as_of: query_range.end,
                },
            )
            .unwrap();
    let expected_migration = expectation(&expected, "legacy_migration_restart");
    assert_eq!(
        after_run2.totals.active_seconds,
        expected_migration["totals"]["active"]
    );
    assert_eq!(
        after_run2.totals.idle_seconds,
        expected_migration["totals"]["idle"]
    );
    assert_eq!(
        after_run2.totals.unknown_seconds,
        expected_migration["totals"]["unknown"]
    );
    assert!(after_run2.intervals.iter().all(|item| {
        item.range.end <= json_ts(&legacy_rows[2]["start"]) || item.state != AccountingState::Active
    }));
    let source_ids: BTreeSet<_> = run2
        .load_accounting_intervals(&query_range)
        .unwrap()
        .into_iter()
        .map(|item| item.source_identity)
        .collect();
    let expected_sources: BTreeSet<_> = expected_migration["canonical_source_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(source_ids, expected_sources);
    let row_count = run2.load_accounting_intervals(&query_range).unwrap().len();
    drop(run2);

    let run3 = SqliteStore::open(migration_path).unwrap();
    run3.write_canonical_batch(&canonical).unwrap();
    assert_eq!(
        run3.load_accounting_intervals(&query_range).unwrap().len(),
        row_count
    );
    assert_eq!(expected_migration["run_3_additional_rows"], 0);

    let (store, path) = temp_db("transaction-rollback");
    let baseline = CanonicalBatch {
        intervals: vec![interval(
            "2026-01-15T15:00:00Z",
            "2026-01-15T15:10:00Z",
            AccountingState::Active,
            Some("canonical.synthetic"),
            "transaction:source",
            1,
        )],
        observed_through: ts("2026-01-15T15:10:00Z"),
    };
    store.write_canonical_batch(&baseline).unwrap();
    let replacement = CanonicalBatch {
        intervals: vec![interval(
            "2026-01-15T15:00:00Z",
            "2026-01-15T15:20:00Z",
            AccountingState::Active,
            Some("canonical.synthetic"),
            "transaction:source",
            2,
        )],
        observed_through: ts("2026-01-15T15:20:00Z"),
    };
    drop(store);
    let raw = rusqlite::Connection::open(&path).unwrap();
    raw.execute_batch(
        "CREATE TRIGGER fixture_fail_watermark
         BEFORE UPDATE OF observed_through ON accounting_metadata
         BEGIN SELECT RAISE(ABORT, 'fixture transaction failure'); END;",
    )
    .unwrap();
    drop(raw);
    let store = SqliteStore::open(path.clone()).unwrap();
    assert!(matches!(
        store.write_canonical_batch(&replacement),
        Err(AccountingError::Storage(_))
    ));
    assert_eq!(
        store.durable_observed_through().unwrap(),
        Some(ts("2026-01-15T15:10:00Z"))
    );
    let rows = store
        .load_accounting_intervals(&range("2026-01-15T15:00:00Z", "2026-01-15T15:20:00Z"))
        .unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].source_revision, 1);
    drop(store);
    let raw = rusqlite::Connection::open(&path).unwrap();
    raw.execute_batch("DROP TRIGGER fixture_fail_watermark;")
        .unwrap();
    drop(raw);
    let store = SqliteStore::open(path).unwrap();
    store.write_canonical_batch(&replacement).unwrap();
    assert_eq!(
        store.durable_observed_through().unwrap(),
        Some(ts("2026-01-15T15:20:00Z"))
    );
}

#[test]
fn production_checkpoint_cutover_faults_roll_back_and_retry_exactly() {
    let expected = fixture("expected.json");
    let matrix = expectation(&expected, "production_checkpoint_matrix");
    let start = json_ts(&matrix["range"][0]);
    let durable = json_ts(&matrix["legacy_observed_through"]);
    let boundary = json_ts(&matrix["cutover_observed_through"]);
    let date = start.date_naive();
    let faults = matrix["fault_points"].as_array().unwrap();
    assert_eq!(faults.len(), 4, "fixture must lock every transaction phase");

    for fault in faults {
        let fault = fault.as_str().unwrap();
        let (store, path) = temp_db(&format!("checkpoint-fault-{fault}"));
        store.insert_session(&SessionRecord {
            id: 0,
            app_path: "synthetic/stale.exe".into(),
            app_name: "stale.synthetic".into(),
            window_title: Some("stale.window".into()),
            started_at: start,
            ended_at: None,
            duration_secs: None,
            is_idle: false,
            date,
        });
        store.insert_session(&SessionRecord {
            id: 0,
            app_path: "synthetic/current.exe".into(),
            app_name: "current.synthetic".into(),
            window_title: Some("current.window".into()),
            started_at: start + chrono::Duration::minutes(10),
            ended_at: None,
            duration_secs: Some((durable - (start + chrono::Duration::minutes(10))).num_seconds()),
            is_idle: false,
            date,
        });
        {
            let raw = rusqlite::Connection::open(&path).unwrap();
            raw.execute(
                "INSERT INTO accounting_metadata(singleton_id, observed_through)
                 VALUES (1, ?1)
                 ON CONFLICT(singleton_id) DO UPDATE SET observed_through = excluded.observed_through",
                [durable.to_rfc3339()],
            )
            .unwrap();
        }
        let before_state = ProducerCheckpointState::load(&store).unwrap();
        let before_legacy = legacy_signature(&store, date);
        let query_range = UtcInterval::new(start, boundary).unwrap();
        let before_rows = store.load_accounting_intervals(&query_range).unwrap();
        let staged = checkpoint(
            &before_state,
            CheckpointReason::FirstCutover,
            durable,
            boundary,
            0,
            AccountingState::Active,
        );
        let trigger = match fault {
            "after_legacy_closure" => {
                "CREATE TRIGGER fixture_fail BEFORE INSERT ON accounting_intervals
                 BEGIN SELECT RAISE(ABORT, 'after legacy closure'); END;"
            }
            "after_canonical_interval" => {
                "CREATE TRIGGER fixture_fail BEFORE UPDATE OF last_source_identity ON accounting_metadata
                 BEGIN SELECT RAISE(ABORT, 'after canonical interval'); END;"
            }
            "after_metadata_identity_hash" => {
                "CREATE TRIGGER fixture_fail AFTER UPDATE OF last_content_hash ON accounting_metadata
                 BEGIN SELECT RAISE(ABORT, 'after metadata identity hash'); END;"
            }
            "after_observed_through" => {
                "CREATE TRIGGER fixture_fail AFTER UPDATE OF observed_through ON accounting_metadata
                 BEGIN SELECT RAISE(ABORT, 'after observed through'); END;"
            }
            other => panic!("unknown fault point {other}"),
        };
        {
            let raw = rusqlite::Connection::open(&path).unwrap();
            raw.execute_batch(trigger).unwrap();
        }

        assert!(matches!(
            store.commit_production_checkpoint(&staged),
            Err(ProductionCheckpointError::Accounting(
                AccountingError::Storage(_)
            ))
        ));
        assert_eq!(ProducerCheckpointState::load(&store).unwrap(), before_state);
        assert_eq!(legacy_signature(&store, date), before_legacy);
        assert_eq!(
            store.load_accounting_intervals(&query_range).unwrap(),
            before_rows
        );
        assert_eq!(store.durable_observed_through().unwrap(), Some(durable));
        drop(store);

        let reopened = SqliteStore::open(path.clone()).unwrap();
        assert_eq!(
            ProducerCheckpointState::load(&reopened).unwrap(),
            before_state
        );
        assert_eq!(legacy_signature(&reopened, date), before_legacy);
        {
            let raw = rusqlite::Connection::open(&path).unwrap();
            raw.execute_batch("DROP TRIGGER fixture_fail;").unwrap();
        }
        let ack = reopened.commit_production_checkpoint(&staged).unwrap();
        assert!(!ack.replayed);
        let rows_after_commit = reopened.load_accounting_intervals(&query_range).unwrap();
        let legacy_after_commit = legacy_signature(&reopened, date);
        assert_eq!(legacy_after_commit[0].1, Some(start));
        assert_eq!(legacy_after_commit[0].2, Some(0));
        assert_eq!(legacy_after_commit[1].1, Some(durable));
        assert_eq!(legacy_after_commit[1].2, Some(600));
        let replay = reopened.commit_production_checkpoint(&staged).unwrap();
        assert!(replay.replayed);
        assert_eq!(
            replay.durable_observed_through,
            ack.durable_observed_through
        );
        assert_eq!(
            reopened.load_accounting_intervals(&query_range).unwrap(),
            rows_after_commit
        );
        assert_eq!(legacy_signature(&reopened, date), legacy_after_commit);
        drop(reopened);

        let restarted = SqliteStore::open(path.clone()).unwrap();
        assert!(
            restarted
                .commit_production_checkpoint(&staged)
                .unwrap()
                .replayed
        );
        assert_eq!(
            restarted.load_accounting_intervals(&query_range).unwrap(),
            rows_after_commit
        );
        let snapshot =
            AccountingQueryService::new(&restarted, &FixedAccountingClock::new(boundary))
                .snapshot(query_range, AccountingQuery::At { as_of: boundary })
                .unwrap();
        assert_eq!(
            snapshot.totals.active_seconds,
            matrix["post_cutover_totals"]["active"]
        );
        assert_eq!(
            snapshot.totals.unknown_seconds,
            matrix["post_cutover_totals"]["unknown"]
        );
        assert_eq!(
            snapshot.totals.accounted_seconds(),
            (boundary - start).num_seconds()
        );
        drop(restarted);
        let _ = std::fs::remove_file(path);
    }
}

#[test]
fn production_checkpoint_replay_rejections_and_lifecycle_recovery_are_deterministic() {
    let expected = fixture("expected.json");
    let matrix = expectation(&expected, "production_checkpoint_matrix");
    let start = ts("2026-02-11T10:00:00Z");
    let step = chrono::Duration::seconds(matrix["step_seconds"].as_i64().unwrap());
    let (store, path) = temp_db("checkpoint-lifecycle-matrix");
    let initial_state = ProducerCheckpointState::load(&store).unwrap();
    let first = checkpoint(
        &initial_state,
        CheckpointReason::FirstCutover,
        start,
        start + step,
        0,
        AccountingState::Active,
    );
    let first_ack = store.commit_production_checkpoint(&first).unwrap();
    assert_eq!(first_ack.lifecycle, CheckpointReason::FirstCutover);
    assert!(!first_ack.replayed);
    let first_rows = store
        .load_accounting_intervals(&UtcInterval::new(start, start + step).unwrap())
        .unwrap();
    let replay = store.commit_production_checkpoint(&first).unwrap();
    assert!(replay.replayed);
    assert_eq!(
        replay.durable_observed_through,
        first_ack.durable_observed_through
    );
    assert_eq!(
        store
            .load_accounting_intervals(&UtcInterval::new(start, start + step).unwrap())
            .unwrap(),
        first_rows
    );

    let mut conflict = first.clone();
    conflict.batch.intervals[0].attribution = identity("different.synthetic");
    conflict.content_hash = conflict.compute_content_hash();
    assert!(matches!(
        store.commit_production_checkpoint(&conflict),
        Err(ProductionCheckpointError::ConflictingReplay { .. })
    ));
    let state_after_first = ProducerCheckpointState::load(&store).unwrap();
    let mut stale_from = checkpoint(
        &state_after_first,
        CheckpointReason::Heartbeat,
        start + step,
        start + step * 2,
        1,
        AccountingState::Active,
    );
    stale_from.expected_from = Some(start);
    stale_from.content_hash = stale_from.compute_content_hash();
    assert!(matches!(
        store.commit_production_checkpoint(&stale_from),
        Err(ProductionCheckpointError::StaleExpectedFrom { .. })
    ));
    let illegal = ProductionCheckpoint::staged(
        CheckpointReason::FirstCutover,
        start + step * 2,
        state_after_first.observed_through(),
        "fixture:illegal-cutover".into(),
        1,
        CanonicalBatch {
            intervals: vec![AccountingInterval {
                range: UtcInterval::new(start + step, start + step * 2).unwrap(),
                state: AccountingState::Active,
                attribution: identity("editor.synthetic"),
                source_identity: "fixture:illegal-cutover:interval".into(),
                source_revision: 0,
            }],
            observed_through: start + step * 2,
        },
        true,
    )
    .unwrap();
    assert!(matches!(
        store.commit_production_checkpoint(&illegal),
        Err(ProductionCheckpointError::ModeConflict(_))
    ));
    assert_eq!(
        ProducerCheckpointState::load(&store).unwrap(),
        state_after_first
    );

    let reasons = [
        (CheckpointReason::Heartbeat, AccountingState::Active),
        (CheckpointReason::CurrentRead, AccountingState::Active),
        (CheckpointReason::Pause, AccountingState::Paused),
        (CheckpointReason::Resume, AccountingState::Unknown),
        (CheckpointReason::Stop, AccountingState::Active),
    ];
    let mut last = first;
    for (index, (reason, accounting_state)) in reasons.into_iter().enumerate() {
        let state = ProducerCheckpointState::load(&store).unwrap();
        let from = start + step * (index as i32 + 1);
        let staged = checkpoint(
            &state,
            reason,
            from,
            from + step,
            index as i64 + 1,
            accounting_state,
        );
        let ack = store.commit_production_checkpoint(&staged).unwrap();
        assert_eq!(ack.lifecycle, reason);
        assert_eq!(ack.durable_observed_through, from + step);
        assert!(!ack.replayed);
        last = staged;
    }
    let stale = checkpoint(
        &ProducerCheckpointState::load(&store).unwrap(),
        CheckpointReason::Heartbeat,
        start + step * 6,
        start + step * 7,
        4,
        AccountingState::Active,
    );
    assert!(matches!(
        store.commit_production_checkpoint(&stale),
        Err(ProductionCheckpointError::StaleRevision { .. })
    ));
    let before_restart_rows = store
        .load_accounting_intervals(&UtcInterval::new(start, start + step * 6).unwrap())
        .unwrap();
    drop(store);

    let restarted = SqliteStore::open(path.clone()).unwrap();
    assert!(
        restarted
            .commit_production_checkpoint(&last)
            .unwrap()
            .replayed
    );
    assert_eq!(
        restarted
            .load_accounting_intervals(&UtcInterval::new(start, start + step * 6).unwrap())
            .unwrap(),
        before_restart_rows
    );
    let recovery_state = ProducerCheckpointState::load(&restarted).unwrap();
    let recovery_from = recovery_state.observed_through().unwrap();
    let recovery = checkpoint(
        &recovery_state,
        CheckpointReason::StartupRecovery,
        recovery_from,
        recovery_from + step,
        6,
        AccountingState::Unknown,
    );
    let recovery_ack = restarted.commit_production_checkpoint(&recovery).unwrap();
    assert_eq!(recovery_ack.lifecycle, CheckpointReason::StartupRecovery);
    assert_eq!(recovery.batch.intervals[0].range.start, recovery_from);
    assert_eq!(recovery.batch.intervals[0].state, AccountingState::Unknown);
    assert!(recovery.batch.intervals[0].attribution.app_id.is_none());
    let final_range = UtcInterval::new(start, recovery_from + step).unwrap();
    let final_rows = restarted.load_accounting_intervals(&final_range).unwrap();
    let snapshot =
        AccountingQueryService::new(&restarted, &FixedAccountingClock::new(final_range.end))
            .snapshot(
                final_range.clone(),
                AccountingQuery::At {
                    as_of: final_range.end,
                },
            )
            .unwrap();
    assert_eq!(
        snapshot.totals.accounted_seconds(),
        (final_range.end - start).num_seconds()
    );
    assert_eq!(
        snapshot.totals.unknown_seconds,
        matrix["lifecycle_totals"]["unknown"]
    );
    drop(restarted);

    let reopened = SqliteStore::open(path.clone()).unwrap();
    assert!(
        reopened
            .commit_production_checkpoint(&recovery)
            .unwrap()
            .replayed
    );
    assert_eq!(
        reopened.load_accounting_intervals(&final_range).unwrap(),
        final_rows
    );
    let lifecycle = match ProducerCheckpointState::load(&reopened).unwrap() {
        ProducerCheckpointState::CanonicalCurrent { lifecycle, .. } => lifecycle,
        other => panic!("expected canonical producer state, got {other:?}"),
    };
    assert_eq!(lifecycle, CheckpointReason::StartupRecovery);
    let expected_lifecycle: Vec<_> = matrix["lifecycle_order"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_str().unwrap())
        .collect();
    assert_eq!(
        expected_lifecycle,
        vec![
            "first_cutover",
            "heartbeat",
            "current_read",
            "pause",
            "resume",
            "stop",
            "startup_recovery",
        ]
    );
    drop(reopened);
    let _ = std::fs::remove_file(path);
}

#[test]
fn fixture_documents_are_runtime_loaded_versioned_and_synthetic() {
    let manifest_dir = std::env::var_os("CARGO_MANIFEST_DIR").unwrap();
    let fixture_dir = Path::new(&manifest_dir)
        .join("tests")
        .join("fixtures")
        .join("accounting");
    for name in ["scenarios.json", "expected.json", "dst_buckets.json"] {
        let path = fixture_dir.join(name);
        let text = std::fs::read_to_string(&path).unwrap();
        let document: Value = serde_json::from_str(&text).unwrap();
        assert!(document["schema_version"].as_u64().unwrap() >= 1);
        assert!(!text.contains("C:\\Users\\"));
        assert!(!text.contains("AppData"));
        assert!(!text.contains("Documents"));
    }
}
