use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{DateTime, Duration, TimeZone, Utc};
use timetrace_bridge::{AccountingExportCsv, ACCOUNTING_EXPORT_SCHEMA_VERSION};
use timetrace_core::{
    AccountingInterval, AccountingQuery, AccountingQueryService, AccountingSnapshot,
    AccountingState, AccountingStore, AttributionIdentity, CanonicalBatch, FixedAccountingClock,
    IanaLocalDayProjection, SnapshotIntegrity, SqliteStore, UtcInterval,
};

static NEXT_DB: AtomicUsize = AtomicUsize::new(0);

fn isolated_store(label: &str) -> SqliteStore {
    let id = NEXT_DB.fetch_add(1, Ordering::SeqCst);
    let path = std::env::temp_dir().join(format!(
        "timetrace-accounting-export-{label}-{}-{id}.sqlite3",
        std::process::id()
    ));
    remove_sqlite_files(&path);
    SqliteStore::open(path).expect("open isolated export fixture database")
}

fn remove_sqlite_files(path: &PathBuf) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-wal", path.display()));
    let _ = std::fs::remove_file(format!("{}-shm", path.display()));
}

fn at(day: u32, hour: u32, minute: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 1, day, hour, minute, 0)
        .single()
        .unwrap()
}

fn interval(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    state: AccountingState,
    source: &str,
    app: Option<&str>,
    window: Option<&str>,
) -> AccountingInterval {
    AccountingInterval {
        range: UtcInterval::new(start, end).unwrap(),
        state,
        attribution: AttributionIdentity {
            app_id: app.map(str::to_owned),
            window_id: window.map(str::to_owned),
            window_app_id: app.zip(window).map(|(app, _)| app.to_owned()),
            page_id: None,
            page_window_id: None,
        },
        source_identity: source.into(),
        source_revision: 1,
    }
}

fn fixed_snapshot(
    label: &str,
    requested: UtcInterval,
    intervals: Vec<AccountingInterval>,
    observed_through: DateTime<Utc>,
    current: bool,
) -> AccountingSnapshot {
    let store = isolated_store(label);
    store
        .write_canonical_batch(&CanonicalBatch {
            intervals,
            observed_through,
        })
        .unwrap();
    let clock = FixedAccountingClock::new(requested.end);
    let query = if current {
        AccountingQuery::Current
    } else {
        AccountingQuery::At {
            as_of: requested.end,
        }
    };
    AccountingQueryService::new(&store, &clock)
        .snapshot(requested, query)
        .unwrap()
}

#[derive(Debug)]
struct CsvRow {
    fields: Vec<String>,
}

impl CsvRow {
    fn get(&self, index: usize) -> &str {
        &self.fields[index]
    }
}

fn parse_csv(csv: &str) -> Vec<CsvRow> {
    let mut lines = csv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "schema_version,row_type,requested_start_utc,requested_end_utc,effective_start_utc,effective_end_utc,observed_through_utc,integrity,state,id,parent_id,seconds"
        )
    );
    lines
        .map(|line| {
            let fields = parse_csv_line(line);
            assert_eq!(fields.len(), 12, "{fields:?}");
            CsvRow { fields }
        })
        .collect()
}

fn parse_csv_line(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut field = String::new();
    let mut chars = line.chars().peekable();
    let mut quoted = false;
    while let Some(character) = chars.next() {
        match character {
            '"' if quoted && chars.peek() == Some(&'"') => {
                chars.next();
                field.push('"');
            }
            '"' => quoted = !quoted,
            ',' if !quoted => fields.push(std::mem::take(&mut field)),
            _ => field.push(character),
        }
    }
    assert!(!quoted, "unterminated CSV quote in {line:?}");
    fields.push(field);
    fields
}

fn format_utc(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn state_totals(snapshot: &AccountingSnapshot) -> BTreeMap<&'static str, i64> {
    BTreeMap::from([
        ("active", snapshot.totals.active_seconds),
        ("idle", snapshot.totals.idle_seconds),
        ("paused", snapshot.totals.paused_seconds),
        ("privacy_excluded", snapshot.totals.privacy_excluded_seconds),
        ("system_gap", snapshot.totals.system_gap_seconds),
        ("unknown", snapshot.totals.unknown_seconds),
    ])
}

fn assert_csv_parity(snapshot: &AccountingSnapshot) {
    let csv = AccountingExportCsv::serialize(snapshot);
    let rows = parse_csv(&csv);
    assert_eq!(
        rows.len(),
        1 + 6 + snapshot.attribution.apps.len() + snapshot.attribution.windows.len()
    );
    let expected_integrity = match snapshot.integrity {
        SnapshotIntegrity::Complete => "complete",
        SnapshotIntegrity::Partial => "partial",
    };
    for row in &rows {
        assert_eq!(row.get(0), ACCOUNTING_EXPORT_SCHEMA_VERSION);
        assert_eq!(row.get(2), format_utc(snapshot.requested.start));
        assert_eq!(row.get(3), format_utc(snapshot.requested.end));
        assert_eq!(row.get(4), format_utc(snapshot.effective.start));
        assert_eq!(row.get(5), format_utc(snapshot.effective.end));
        assert_eq!(row.get(6), format_utc(snapshot.observed_through));
        assert_eq!(row.get(7), expected_integrity);
    }
    let metadata = rows.iter().find(|row| row.get(1) == "snapshot").unwrap();
    assert_eq!(
        metadata.get(11).parse::<i64>().unwrap(),
        snapshot.effective.seconds()
    );

    let exported_states = rows
        .iter()
        .filter(|row| row.get(1) == "state")
        .map(|row| (row.get(8), row.get(11).parse::<i64>().unwrap()))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(exported_states, state_totals(snapshot));
    assert_eq!(
        exported_states.values().sum::<i64>(),
        snapshot.effective.seconds()
    );

    let exported_apps = rows
        .iter()
        .filter(|row| row.get(1) == "app")
        .map(|row| (row.get(9).to_owned(), row.get(11).parse::<i64>().unwrap()))
        .collect::<BTreeMap<_, _>>();
    let expected_apps = snapshot
        .attribution
        .apps
        .iter()
        .map(|item| (item.id.clone(), item.seconds))
        .collect::<BTreeMap<_, _>>();
    assert_eq!(exported_apps, expected_apps);

    let exported_windows = rows
        .iter()
        .filter(|row| row.get(1) == "window")
        .map(|row| {
            (
                (row.get(9).to_owned(), row.get(10).to_owned()),
                row.get(11).parse::<i64>().unwrap(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    let expected_windows = snapshot
        .attribution
        .windows
        .iter()
        .map(|item| {
            (
                (item.id.clone(), item.parent_id.clone().unwrap_or_default()),
                item.seconds,
            )
        })
        .collect::<BTreeMap<_, _>>();
    assert_eq!(exported_windows, expected_windows);
    for ((_, app), seconds) in exported_windows {
        assert!(seconds <= exported_apps[&app]);
    }
}

#[test]
fn cross_midnight_snapshot_exports_exact_effective_range_and_attribution() {
    let start = at(15, 23, 50);
    let end = at(16, 0, 10);
    let snapshot = fixed_snapshot(
        "cross-midnight",
        UtcInterval::new(start, end).unwrap(),
        vec![interval(
            start,
            end,
            AccountingState::Active,
            "cross-midnight",
            Some("Editor, Inc."),
            Some("Draft \"A\""),
        )],
        end,
        false,
    );
    assert_csv_parity(&snapshot);
}

#[test]
fn dst_23_and_25_hour_snapshots_export_without_assuming_24_hours() {
    for (label, date, expected_seconds) in [
        ("dst-23", "2026-03-08", 23 * 3600),
        ("dst-25", "2026-11-01", 25 * 3600),
    ] {
        let range = IanaLocalDayProjection
            .utc_day_range(
                "America/New_York",
                chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(),
            )
            .unwrap();
        let snapshot = fixed_snapshot(
            label,
            range.clone(),
            vec![interval(
                range.start,
                range.end,
                AccountingState::Unknown,
                label,
                None,
                None,
            )],
            range.end,
            false,
        );
        assert_eq!(snapshot.effective.seconds(), expected_seconds);
        assert_csv_parity(&snapshot);
    }
}

#[test]
fn active_idle_snapshot_exports_3000_600_and_active_only_attribution() {
    let start = at(15, 10, 0);
    let end = start + Duration::hours(1);
    let snapshot = fixed_snapshot(
        "active-idle",
        UtcInterval::new(start, end).unwrap(),
        vec![
            interval(
                start,
                start + Duration::seconds(3000),
                AccountingState::Active,
                "active",
                Some("editor"),
                Some("document"),
            ),
            interval(
                start + Duration::seconds(3000),
                end,
                AccountingState::Idle,
                "idle",
                None,
                None,
            ),
        ],
        end,
        false,
    );
    assert_eq!(snapshot.totals.active_seconds, 3000);
    assert_eq!(snapshot.totals.idle_seconds, 600);
    assert_eq!(snapshot.attribution.apps[0].seconds, 3000);
    assert_csv_parity(&snapshot);
}

#[test]
fn partial_snapshot_exports_unknown_tail_and_durable_watermark_verbatim() {
    let start = at(15, 10, 0);
    let observed = start + Duration::seconds(3000);
    let end = start + Duration::hours(1);
    let snapshot = fixed_snapshot(
        "partial",
        UtcInterval::new(start, end).unwrap(),
        vec![interval(
            start,
            observed,
            AccountingState::Active,
            "partial",
            Some("editor"),
            Some("document"),
        )],
        observed,
        true,
    );
    assert_eq!(snapshot.integrity, SnapshotIntegrity::Partial);
    assert_eq!(snapshot.observed_through, observed);
    assert_eq!(snapshot.totals.active_seconds, 3000);
    assert_eq!(snapshot.totals.unknown_seconds, 600);
    assert_csv_parity(&snapshot);
}
