use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use timetrace_bridge::{
    ACCEPTED_PRODUCER_BRIDGE_INTERFACE_HASH, AccountingBridgeError, AccountingRangeRequest,
    AccountingStateDto, SnapshotIntegrityDto, TimeTraceApi, query_accounting_snapshot_at,
};
use timetrace_core::engine::aggregator::CheckpointStore;
use timetrace_core::{
    AccountingInterval, AccountingState, AccountingStore, AttributionIdentity, CanonicalBatch,
    DataStore, FixedAccountingClock, IanaLocalDayProjection, SessionRecord, SqliteStore,
    UtcInterval,
};

static NEXT_DB: AtomicUsize = AtomicUsize::new(0);

#[test]
fn consumer_is_bound_to_the_accepted_producer_bridge_interface() {
    assert_eq!(
        ACCEPTED_PRODUCER_BRIDGE_INTERFACE_HASH,
        "c3500be242ea4bafc6c915fbafe650b35092db4296d02aadd2df33fe328efd8f"
    );
}

fn isolated_store(label: &str) -> SqliteStore {
    let id = NEXT_DB.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-accounting-bridge-{label}-{}-{id}.sqlite3",
        std::process::id()
    ));
    remove_sqlite_files(&path);
    SqliteStore::open(path).expect("open isolated accounting fixture database")
}

fn remove_sqlite_files(path: &PathBuf) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

fn at(hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 1, 15, hour, minute, 0)
        .single()
        .unwrap()
}

fn utc_request(start: DateTime<Utc>, end: DateTime<Utc>) -> AccountingRangeRequest {
    AccountingRangeRequest::Utc {
        start_utc: start.to_rfc3339(),
        end_utc: end.to_rfc3339(),
    }
}

fn at_request(as_of: DateTime<Utc>) -> String {
    as_of.to_rfc3339()
}

fn session(
    app_name: &str,
    start: DateTime<Utc>,
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
        window_title: (!idle).then(|| format!("{app_name}-window")),
        started_at: start,
        ended_at: duration_seconds.map(|seconds| start + Duration::seconds(seconds)),
        duration_secs: duration_seconds,
        is_idle: idle,
        date: start.date_naive(),
    }
}

#[test]
fn open_tail_and_active_idle_map_the_canonical_snapshot_without_recalculation() {
    // These are the two locked P0 accounting fixture outcomes: closed_40_open_20
    // and active_idle_one_hour. The bridge drives the public production store
    // and query seam rather than constructing a bridge-only projection.
    let open_store = isolated_store("open-tail");
    let start = at(10, 0);
    open_store.insert_session(&session("work-editor", start, Some(2400), false));
    let open_id = open_store.insert_session(&session(
        "web-client",
        start + Duration::seconds(2400),
        None,
        false,
    ));
    open_store
        .checkpoint_open_interval(open_id, None, start + Duration::seconds(3600))
        .expect("checkpoint fixture open tail through fixed as_of");
    let clock = FixedAccountingClock::new(start + Duration::seconds(3600));
    let open = query_accounting_snapshot_at(
        &open_store,
        &clock,
        utc_request(start, start + Duration::seconds(3600)),
        at_request(start + Duration::seconds(3600)),
    )
    .expect("query open-tail snapshot");
    assert_eq!(open.totals.active_seconds, 3600);
    assert_eq!(open.totals.idle_seconds, 0);
    assert_eq!(open.totals.accounted_seconds, 3600);
    assert_eq!(open.effective_end_utc, "2026-01-15T11:00:00Z");
    assert!(
        open.intervals
            .iter()
            .all(|item| item.end_utc <= open.effective_end_utc)
    );

    let split_store = isolated_store("active-idle");
    split_store.insert_session(&session("work-editor", start, Some(3000), false));
    split_store.insert_session(&session(
        "__IDLE__",
        start + Duration::seconds(3000),
        Some(600),
        true,
    ));
    let split = query_accounting_snapshot_at(
        &split_store,
        &clock,
        utc_request(start, start + Duration::seconds(3600)),
        at_request(start + Duration::seconds(3600)),
    )
    .expect("query active-idle snapshot");
    assert_eq!(split.totals.active_seconds, 3000);
    assert_eq!(split.totals.idle_seconds, 600);
    assert_eq!(split.totals.accounted_seconds, 3600);
    assert_eq!(
        split.apps.iter().map(|item| item.seconds).sum::<i64>(),
        3000
    );
    assert!(split.apps.iter().all(|item| item.id != "__IDLE__"));
}

#[test]
fn six_states_and_partial_unknown_are_typed_and_conserved() {
    let start = at(10, 0);
    let states = [
        AccountingState::Active,
        AccountingState::Idle,
        AccountingState::Paused,
        AccountingState::PrivacyExcluded,
        AccountingState::SystemGap,
        AccountingState::Unknown,
    ];
    let store = isolated_store("six-states");
    let intervals = states
        .into_iter()
        .enumerate()
        .map(|(index, state)| {
            let range_start = start + Duration::seconds(index as i64 * 600);
            AccountingInterval {
                range: UtcInterval::new(range_start, range_start + Duration::seconds(600)).unwrap(),
                state,
                attribution: if state == AccountingState::Active {
                    AttributionIdentity {
                        app_id: Some("editor".into()),
                        window_id: Some("document".into()),
                        window_app_id: Some("editor".into()),
                        page_id: Some("chapter".into()),
                        page_window_id: Some("document".into()),
                    }
                } else {
                    AttributionIdentity::default()
                },
                source_identity: format!("fixture:{index}"),
                source_revision: 1,
            }
        })
        .collect::<Vec<_>>();
    store
        .write_canonical_batch(&CanonicalBatch {
            intervals,
            observed_through: start + Duration::seconds(3600),
        })
        .unwrap();
    let clock = FixedAccountingClock::new(start + Duration::seconds(3600));
    let snapshot = query_accounting_snapshot_at(
        &store,
        &clock,
        utc_request(start, start + Duration::seconds(3600)),
        at_request(start + Duration::seconds(3600)),
    )
    .unwrap();
    assert_eq!(snapshot.totals.active_seconds, 600);
    assert_eq!(snapshot.totals.idle_seconds, 600);
    assert_eq!(snapshot.totals.paused_seconds, 600);
    assert_eq!(snapshot.totals.privacy_excluded_seconds, 600);
    assert_eq!(snapshot.totals.system_gap_seconds, 600);
    assert_eq!(snapshot.totals.unknown_seconds, 600);
    assert_eq!(snapshot.totals.accounted_seconds, 3600);
    assert_eq!(snapshot.integrity, SnapshotIntegrityDto::Complete);
    assert_eq!(snapshot.apps[0].seconds, 600);
    assert_eq!(snapshot.windows[0].seconds, 600);
    assert_eq!(snapshot.pages[0].seconds, 600);
    assert_eq!(
        snapshot
            .intervals
            .iter()
            .map(|item| item.state)
            .collect::<Vec<_>>(),
        vec![
            AccountingStateDto::Active,
            AccountingStateDto::Idle,
            AccountingStateDto::Paused,
            AccountingStateDto::PrivacyExcluded,
            AccountingStateDto::SystemGap,
            AccountingStateDto::Unknown,
        ]
    );

    let partial_store = isolated_store("partial");
    partial_store
        .write_canonical_batch(&CanonicalBatch {
            intervals: vec![AccountingInterval {
                range: UtcInterval::new(start, start + Duration::seconds(3000)).unwrap(),
                state: AccountingState::Active,
                attribution: AttributionIdentity {
                    app_id: Some("editor".into()),
                    ..AttributionIdentity::default()
                },
                source_identity: "fixture:partial".into(),
                source_revision: 1,
            }],
            observed_through: start + Duration::seconds(3000),
        })
        .unwrap();
    let partial = query_accounting_snapshot_at(
        &partial_store,
        &clock,
        utc_request(start, start + Duration::seconds(3600)),
        at_request(start + Duration::seconds(3600)),
    )
    .unwrap();
    assert_eq!(partial.totals.active_seconds, 3000);
    assert_eq!(partial.totals.unknown_seconds, 600);
    assert_eq!(partial.totals.accounted_seconds, 3600);
    assert_eq!(partial.integrity, SnapshotIntegrityDto::Partial);
    assert_eq!(partial.observed_through_utc, "2026-01-15T10:50:00Z");
}

#[test]
fn local_day_projection_preserves_23_24_and_25_hour_buckets() {
    let cases = [
        ("2026-02-01", "2026-02-02T05:00:00Z", 24usize),
        ("2026-03-08", "2026-03-09T04:00:00Z", 23usize),
        ("2026-11-01", "2026-11-02T05:00:00Z", 25usize),
    ];
    for (date, day_end, expected_hours) in cases {
        let store = isolated_store(date);
        let deadline = DateTime::parse_from_rfc3339(day_end)
            .unwrap()
            .with_timezone(&Utc);
        let day_range = IanaLocalDayProjection
            .utc_day_range(
                "America/New_York",
                NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(),
            )
            .unwrap();
        let idle_start = deadline - Duration::minutes(10);
        store
            .write_canonical_batch(&CanonicalBatch {
                intervals: vec![
                    AccountingInterval {
                        range: UtcInterval::new(day_range.start, idle_start).unwrap(),
                        state: AccountingState::Active,
                        attribution: AttributionIdentity {
                            app_id: Some("editor".into()),
                            window_id: Some("document".into()),
                            window_app_id: Some("editor".into()),
                            ..AttributionIdentity::default()
                        },
                        source_identity: format!("fixture:{date}:active"),
                        source_revision: 1,
                    },
                    AccountingInterval {
                        range: UtcInterval::new(idle_start, deadline).unwrap(),
                        state: AccountingState::Idle,
                        attribution: AttributionIdentity::default(),
                        source_identity: format!("fixture:{date}:idle"),
                        source_revision: 1,
                    },
                ],
                observed_through: deadline,
            })
            .unwrap();
        let clock = FixedAccountingClock::new(deadline);
        let snapshot = query_accounting_snapshot_at(
            &store,
            &clock,
            AccountingRangeRequest::LocalDate {
                local_date: date.into(),
                timezone: "America/New_York".into(),
            },
            at_request(deadline),
        )
        .unwrap();
        assert_eq!(snapshot.hours.len(), expected_hours, "{date}");
        assert_eq!(
            snapshot.totals.accounted_seconds,
            expected_hours as i64 * 3600,
            "{date}"
        );
        assert_eq!(
            snapshot
                .hours
                .iter()
                .map(|hour| hour.totals.accounted_seconds)
                .sum::<i64>(),
            snapshot.totals.accounted_seconds,
            "{date}"
        );
        assert_eq!(snapshot.effective_end_utc, day_end, "{date}");
        assert_eq!(
            snapshot
                .hours
                .iter()
                .map(|hour| hour.totals.active_seconds)
                .sum::<i64>(),
            snapshot.totals.active_seconds,
            "{date}"
        );
        for hour in &snapshot.hours {
            assert_eq!(
                hour.apps.iter().map(|app| app.seconds).sum::<i64>(),
                hour.totals.active_seconds,
                "{date}: {}",
                hour.stable_id
            );
            assert!(hour.apps.iter().all(|app| app.id != "__IDLE__"));
        }
        assert_eq!(snapshot.windows.len(), 1, "{date}");
        assert_eq!(snapshot.windows[0].parent_id.as_deref(), Some("editor"));
    }
}

#[cfg(windows)]
#[test]
fn system_iana_timezone_resolves_to_a_supported_local_day() {
    let zone = TimeTraceApi::get_system_iana_timezone().expect("Windows IANA zone lookup");
    assert!(!zone.trim().is_empty());
    IanaLocalDayProjection
        .utc_day_range(&zone, NaiveDate::from_ymd_opt(2026, 1, 15).unwrap())
        .expect("system zone accepted by canonical local-day projection");
}

#[test]
fn invalid_range_timezone_and_future_as_of_return_typed_errors() {
    let store = isolated_store("typed-errors");
    let start = at(10, 0);
    let clock = FixedAccountingClock::new(start + Duration::hours(1));

    assert!(matches!(
        query_accounting_snapshot_at(
            &store,
            &clock,
            utc_request(start + Duration::minutes(1), start),
            at_request(start + Duration::hours(1)),
        ),
        Err(AccountingBridgeError::InvalidRange { .. })
    ));
    assert!(matches!(
        query_accounting_snapshot_at(
            &store,
            &clock,
            AccountingRangeRequest::LocalDate {
                local_date: "2026-01-15".into(),
                timezone: "Mars/Olympus".into(),
            },
            at_request(start + Duration::hours(1)),
        ),
        Err(AccountingBridgeError::InvalidTimeZone { .. })
    ));
    assert!(matches!(
        query_accounting_snapshot_at(
            &store,
            &clock,
            utc_request(start, start + Duration::hours(1)),
            at_request(start + Duration::hours(2)),
        ),
        Err(AccountingBridgeError::FutureAsOf { .. })
    ));
    assert!(matches!(
        query_accounting_snapshot_at(
            &store,
            &clock,
            AccountingRangeRequest::Utc {
                start_utc: "2026-01-15T10:00:00+08:00".into(),
                end_utc: "2026-01-15T11:00:00+08:00".into(),
            },
            at_request(start + Duration::hours(1)),
        ),
        Err(AccountingBridgeError::InvalidUtcTimestamp { .. })
    ));
}
