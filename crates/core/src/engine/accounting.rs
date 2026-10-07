//! Exclusive accounting reducer, query orchestration, attribution and IANA projections.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Duration, LocalResult, NaiveDate, Offset, TimeZone, Timelike, Utc};
use chrono_tz::Tz;

use crate::contracts::accounting::{
    AccountingClock, AccountingError, AccountingInterval, AccountingQuery, AccountingSignal,
    AccountingSnapshot, AccountingState, AccountingStore, AccountingTotals, ActiveAttribution,
    AttributionIdentity, AttributionTotal, LocalDayProjection, LocalHourBucket, SnapshotIntegrity,
    UtcInterval,
};

pub const UNATTRIBUTED_APP: &str = "__UNATTRIBUTED_APP__";
pub const UNATTRIBUTED_WINDOW: &str = "__UNATTRIBUTED_WINDOW__";
pub const UNATTRIBUTED_PAGE: &str = "__UNATTRIBUTED_PAGE__";

#[derive(Debug, Default, Clone, Copy)]
pub struct AccountingReducer;

impl AccountingReducer {
    pub fn reduce_signals(
        &self,
        range: &UtcInterval,
        signals: &[AccountingSignal],
    ) -> Vec<AccountingInterval> {
        let normalized: Vec<_> = signals
            .iter()
            .filter_map(|signal| {
                signal
                    .interval
                    .intersection(range)
                    .map(|clipped| AccountingInterval {
                        range: clipped,
                        state: signal.effective_state(),
                        attribution: signal.attribution.clone(),
                        source_identity: "reducer".to_owned(),
                        source_revision: 0,
                    })
            })
            .collect();
        self.reduce_intervals(range, &normalized)
    }

    pub fn reduce_intervals(
        &self,
        range: &UtcInterval,
        intervals: &[AccountingInterval],
    ) -> Vec<AccountingInterval> {
        let mut boundaries = vec![range.start, range.end];
        let clipped: Vec<_> = intervals
            .iter()
            .filter_map(|item| {
                item.range.intersection(range).map(|clipped_range| {
                    boundaries.push(clipped_range.start);
                    boundaries.push(clipped_range.end);
                    (item, clipped_range)
                })
            })
            .collect();
        boundaries.sort_unstable();
        boundaries.dedup();

        let mut result: Vec<AccountingInterval> = Vec::new();
        for pair in boundaries.windows(2) {
            let segment = UtcInterval {
                start: pair[0],
                end: pair[1],
            };
            if segment.start >= segment.end {
                continue;
            }
            let winner = clipped
                .iter()
                .filter(|(_, candidate)| {
                    candidate.start <= segment.start && candidate.end >= segment.end
                })
                .max_by_key(|(item, _)| state_priority(item.state));
            let (state, attribution, source_identity, source_revision) = match winner {
                Some((item, _)) => (
                    item.state,
                    item.attribution.clone(),
                    item.source_identity.clone(),
                    item.source_revision,
                ),
                None => (
                    AccountingState::Unknown,
                    AttributionIdentity::default(),
                    "synthetic:unknown".to_owned(),
                    0,
                ),
            };
            if let Some(previous) = result.last_mut() {
                if previous.range.end == segment.start
                    && previous.state == state
                    && previous.attribution == attribution
                    && previous.source_identity == source_identity
                    && previous.source_revision == source_revision
                {
                    previous.range.end = segment.end;
                    continue;
                }
            }
            result.push(AccountingInterval {
                range: segment,
                state,
                attribution,
                source_identity,
                source_revision,
            });
        }
        result
    }
}

fn state_priority(state: AccountingState) -> u8 {
    match state {
        AccountingState::SystemGap => 6,
        AccountingState::PrivacyExcluded => 5,
        AccountingState::Paused => 4,
        AccountingState::Idle => 3,
        AccountingState::Active => 2,
        AccountingState::Unknown => 1,
    }
}

#[derive(Debug, Default, Clone, Copy)]
pub struct ActiveAttributionProjector;

impl ActiveAttributionProjector {
    pub fn project(&self, intervals: &[AccountingInterval]) -> ActiveAttribution {
        let mut apps: BTreeMap<String, i64> = BTreeMap::new();
        let mut windows: BTreeMap<(String, String), i64> = BTreeMap::new();
        let mut pages: BTreeMap<(String, String), i64> = BTreeMap::new();

        for item in intervals
            .iter()
            .filter(|item| item.state == AccountingState::Active)
        {
            let seconds = item.range.seconds();
            if seconds == 0 {
                continue;
            }
            let app = item
                .attribution
                .app_id
                .as_deref()
                .filter(|value| !value.is_empty())
                .unwrap_or(UNATTRIBUTED_APP)
                .to_owned();

            let mut window = item
                .attribution
                .window_id
                .as_deref()
                .filter(|value| !value.is_empty())
                .unwrap_or(UNATTRIBUTED_WINDOW)
                .to_owned();
            if item
                .attribution
                .window_app_id
                .as_deref()
                .is_some_and(|parent| parent != app)
            {
                window = UNATTRIBUTED_WINDOW.to_owned();
            }

            let mut page = item
                .attribution
                .page_id
                .as_deref()
                .filter(|value| !value.is_empty())
                .unwrap_or(UNATTRIBUTED_PAGE)
                .to_owned();
            if item
                .attribution
                .page_window_id
                .as_deref()
                .is_some_and(|parent| parent != window)
            {
                page = UNATTRIBUTED_PAGE.to_owned();
            }

            *apps.entry(app.clone()).or_default() += seconds;
            *windows.entry((window.clone(), app)).or_default() += seconds;
            *pages.entry((page, window)).or_default() += seconds;
        }

        ActiveAttribution {
            apps: apps
                .into_iter()
                .map(|(id, seconds)| AttributionTotal {
                    id,
                    parent_id: None,
                    seconds,
                })
                .collect(),
            windows: windows
                .into_iter()
                .map(|((id, parent_id), seconds)| AttributionTotal {
                    id,
                    parent_id: Some(parent_id),
                    seconds,
                })
                .collect(),
            pages: pages
                .into_iter()
                .map(|((id, parent_id), seconds)| AttributionTotal {
                    id,
                    parent_id: Some(parent_id),
                    seconds,
                })
                .collect(),
        }
    }
}

pub struct AccountingQueryService<'a, S: AccountingStore, C: AccountingClock> {
    store: &'a S,
    clock: &'a C,
}

impl<'a, S: AccountingStore, C: AccountingClock> AccountingQueryService<'a, S, C> {
    pub fn new(store: &'a S, clock: &'a C) -> Self {
        Self { store, clock }
    }

    pub fn snapshot(
        &self,
        requested: UtcInterval,
        query: AccountingQuery,
    ) -> Result<AccountingSnapshot, AccountingError> {
        let deadline = self.clock.now_utc();
        let is_current = matches!(query, AccountingQuery::Current);
        let as_of = match query {
            AccountingQuery::At { as_of } => as_of,
            AccountingQuery::Current => deadline,
        };
        if as_of < requested.start {
            return Err(AccountingError::AsOfBeforeStart {
                as_of,
                start: requested.start,
            });
        }
        if as_of > deadline {
            return Err(AccountingError::FutureAsOf { as_of, deadline });
        }
        let effective_end = requested.end.min(as_of);
        if effective_end <= requested.start {
            return Err(AccountingError::InvalidRange {
                start: requested.start,
                end: effective_end,
            });
        }
        let effective = UtcInterval {
            start: requested.start,
            end: effective_end,
        };
        let mut degraded = false;
        let old_durable = match self.store.durable_observed_through() {
            Ok(value) => value,
            Err(_) if is_current => {
                degraded = true;
                self.store.last_known_observed_through()
            }
            Err(error) => return Err(error),
        };
        let refreshed = if is_current {
            match self.store.refresh_current(effective.end) {
                Ok(value) => value,
                Err(_) => {
                    degraded = true;
                    old_durable
                }
            }
        } else {
            old_durable
        };
        let durable = refreshed
            .or(old_durable)
            .unwrap_or(effective.start)
            .min(effective.end)
            .max(effective.start);
        let readable = UtcInterval {
            start: effective.start,
            end: durable.max(effective.start),
        };
        let mut stored = if readable.start < readable.end {
            match self.store.load_accounting_intervals(&readable) {
                Ok(intervals) => intervals,
                Err(_) if is_current => {
                    degraded = true;
                    self.store
                        .load_last_durable_intervals(&readable)
                        .unwrap_or_default()
                }
                Err(error) => return Err(error),
            }
        } else {
            Vec::new()
        };
        if durable < effective.end {
            stored.push(AccountingInterval {
                range: UtcInterval {
                    start: durable,
                    end: effective.end,
                },
                state: AccountingState::Unknown,
                attribution: AttributionIdentity::default(),
                source_identity: "synthetic:watermark-tail".to_owned(),
                source_revision: 0,
            });
        }
        let intervals = AccountingReducer.reduce_intervals(&effective, &stored);
        let totals = totals_for(&intervals);
        let attribution = ActiveAttributionProjector.project(&intervals);
        Ok(AccountingSnapshot {
            requested,
            effective,
            observed_through: durable,
            totals,
            intervals,
            attribution,
            integrity: if !degraded && durable >= effective_end {
                SnapshotIntegrity::Complete
            } else {
                SnapshotIntegrity::Partial
            },
        })
    }
}

pub fn totals_for(intervals: &[AccountingInterval]) -> AccountingTotals {
    let mut totals = AccountingTotals::default();
    for item in intervals {
        totals.add(item.state, item.range.seconds());
    }
    totals
}

#[derive(Debug, Default, Clone, Copy)]
pub struct IanaLocalDayProjection;

impl IanaLocalDayProjection {
    pub fn utc_day_range(
        &self,
        zone: &str,
        date: NaiveDate,
    ) -> Result<UtcInterval, AccountingError> {
        let tz: Tz = zone
            .parse()
            .map_err(|_| AccountingError::InvalidTimeZone(zone.to_owned()))?;
        let next_date = date
            .succ_opt()
            .ok_or_else(|| AccountingError::InvalidLocalBoundary {
                zone: zone.to_owned(),
                boundary: date.to_string(),
            })?;
        let start = first_valid_in_local_date(&tz, date, zone)?.with_timezone(&Utc);
        let end = first_valid_in_local_date(&tz, next_date, zone)?.with_timezone(&Utc);
        UtcInterval::new(start, end)
    }

    pub fn project(
        &self,
        zone: &str,
        date: NaiveDate,
        snapshot: &AccountingSnapshot,
    ) -> Result<LocalDayProjection, AccountingError> {
        let tz: Tz = zone
            .parse()
            .map_err(|_| AccountingError::InvalidTimeZone(zone.to_owned()))?;
        let utc_range = self.utc_day_range(zone, date)?;
        let day_intervals: Vec<_> = snapshot
            .intervals
            .iter()
            .filter_map(|item| {
                item.range
                    .intersection(&utc_range)
                    .map(|range| AccountingInterval {
                        range,
                        ..item.clone()
                    })
            })
            .collect();
        let mut hours = Vec::new();
        let mut fold_by_hour: HashMap<(NaiveDate, u32), u8> = HashMap::new();
        let mut cursor = utc_range.start;
        while cursor < utc_range.end {
            let end = (cursor + Duration::hours(1)).min(utc_range.end);
            let local = cursor.with_timezone(&tz);
            let key = (local.date_naive(), local.hour());
            let fold = *fold_by_hour
                .entry(key)
                .and_modify(|value| *value += 1)
                .or_insert(0);
            let offset = local.offset().fix().local_minus_utc();
            let bucket_range = UtcInterval { start: cursor, end };
            let bucket_intervals: Vec<_> = day_intervals
                .iter()
                .filter_map(|item| {
                    item.range
                        .intersection(&bucket_range)
                        .map(|range| AccountingInterval {
                            range,
                            ..item.clone()
                        })
                })
                .collect();
            hours.push(LocalHourBucket {
                stable_id: format!(
                    "{}-{:02}-{:+05}-{}-{}",
                    local.date_naive(),
                    local.hour(),
                    offset,
                    fold,
                    cursor.timestamp()
                ),
                local_date: local.date_naive(),
                local_hour: local.hour(),
                utc_offset_seconds: offset,
                fold,
                range: bucket_range,
                totals: totals_for(&bucket_intervals),
                apps: ActiveAttributionProjector.project(&bucket_intervals).apps,
            });
            cursor = end;
        }
        Ok(LocalDayProjection {
            zone: zone.to_owned(),
            local_date: date,
            utc_range,
            totals: totals_for(&day_intervals),
            hours,
        })
    }
}

fn first_valid_in_local_date(
    tz: &Tz,
    date: NaiveDate,
    zone: &str,
) -> Result<DateTime<Tz>, AccountingError> {
    let midnight =
        date.and_hms_opt(0, 0, 0)
            .ok_or_else(|| AccountingError::InvalidLocalBoundary {
                zone: zone.to_owned(),
                boundary: date.to_string(),
            })?;
    // Some zones advance or repeat at local midnight. Search the local date for
    // its first representable wall instant; for a fold choose the earlier UTC
    // occurrence. The same function defines the next day's boundary, so
    // adjacent local-day ranges remain continuous without fixed-offset guesses.
    for seconds in 0..86_400 {
        let candidate = midnight + Duration::seconds(seconds);
        match tz.from_local_datetime(&candidate) {
            LocalResult::Single(value) => return Ok(value),
            LocalResult::Ambiguous(first, second) => {
                return Ok(if first.with_timezone(&Utc) <= second.with_timezone(&Utc) {
                    first
                } else {
                    second
                });
            }
            LocalResult::None => {}
        }
    }
    Err(AccountingError::InvalidLocalBoundary {
        zone: zone.to_owned(),
        boundary: date.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use crate::contracts::accounting::{
        AccountingEvidence, AccountingStore, CanonicalBatch, FixedAccountingClock, RecoveryPoint,
    };

    struct FakeStore {
        intervals: Mutex<Vec<AccountingInterval>>,
        watermark: Mutex<DateTime<Utc>>,
        refresh_to: Option<DateTime<Utc>>,
        refresh_fails: bool,
        watermark_read_fails: bool,
        interval_read_fails: bool,
        refresh_calls: AtomicUsize,
    }

    impl FakeStore {
        fn new(intervals: Vec<AccountingInterval>, watermark: DateTime<Utc>) -> Self {
            Self {
                intervals: Mutex::new(intervals),
                watermark: Mutex::new(watermark),
                refresh_to: None,
                refresh_fails: false,
                watermark_read_fails: false,
                interval_read_fails: false,
                refresh_calls: AtomicUsize::new(0),
            }
        }

        fn clipped(&self, range: &UtcInterval) -> Vec<AccountingInterval> {
            self.intervals
                .lock()
                .unwrap()
                .iter()
                .filter_map(|item| {
                    item.range
                        .intersection(range)
                        .map(|clipped| AccountingInterval {
                            range: clipped,
                            ..item.clone()
                        })
                })
                .collect()
        }
    }

    impl AccountingStore for FakeStore {
        fn write_canonical_batch(&self, _batch: &CanonicalBatch) -> Result<(), AccountingError> {
            unreachable!()
        }

        fn load_accounting_intervals(
            &self,
            range: &UtcInterval,
        ) -> Result<Vec<AccountingInterval>, AccountingError> {
            if self.interval_read_fails {
                return Err(AccountingError::Storage("injected read failure".into()));
            }
            Ok(self.clipped(range))
        }

        fn durable_observed_through(&self) -> Result<Option<DateTime<Utc>>, AccountingError> {
            if self.watermark_read_fails {
                return Err(AccountingError::Storage(
                    "injected watermark failure".into(),
                ));
            }
            Ok(Some(*self.watermark.lock().unwrap()))
        }

        fn last_known_observed_through(&self) -> Option<DateTime<Utc>> {
            Some(*self.watermark.lock().unwrap())
        }

        fn refresh_current(
            &self,
            _as_of: DateTime<Utc>,
        ) -> Result<Option<DateTime<Utc>>, AccountingError> {
            self.refresh_calls.fetch_add(1, Ordering::SeqCst);
            if self.refresh_fails {
                return Err(AccountingError::Storage("injected refresh failure".into()));
            }
            if let Some(next) = self.refresh_to {
                *self.watermark.lock().unwrap() = next;
            }
            Ok(Some(*self.watermark.lock().unwrap()))
        }

        fn load_last_durable_intervals(
            &self,
            range: &UtcInterval,
        ) -> Result<Vec<AccountingInterval>, AccountingError> {
            Ok(self.clipped(range))
        }

        fn recover_after_restart(&self, _point: &RecoveryPoint) -> Result<(), AccountingError> {
            unreachable!()
        }
    }
    use chrono::TimeZone;

    fn t(hour: u32, minute: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 1, 15, hour, minute, 0)
            .single()
            .unwrap()
    }

    fn signal(
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        state: AccountingState,
    ) -> AccountingSignal {
        AccountingSignal {
            interval: UtcInterval::new(start, end).unwrap(),
            state,
            evidence: AccountingEvidence::Observation,
            attribution: AttributionIdentity::default(),
        }
    }

    #[test]
    fn reducer_is_exclusive_and_conserves_all_six_states() {
        let range = UtcInterval::new(t(10, 0), t(11, 0)).unwrap();
        let signals = vec![
            signal(t(10, 0), t(10, 20), AccountingState::Active),
            signal(t(10, 10), t(10, 30), AccountingState::Idle),
            signal(t(10, 30), t(10, 40), AccountingState::Paused),
            signal(t(10, 40), t(10, 45), AccountingState::PrivacyExcluded),
            AccountingSignal {
                interval: UtcInterval::new(t(10, 45), t(10, 50)).unwrap(),
                state: AccountingState::Unknown,
                evidence: AccountingEvidence::LifecycleGap { precise: true },
                attribution: AttributionIdentity::default(),
            },
            AccountingSignal {
                interval: UtcInterval::new(t(10, 50), t(11, 0)).unwrap(),
                state: AccountingState::Active,
                evidence: AccountingEvidence::ObservationMissing,
                attribution: AttributionIdentity::default(),
            },
        ];
        let out = AccountingReducer.reduce_signals(&range, &signals);
        let totals = totals_for(&out);
        assert_eq!(totals.accounted_seconds(), 3600);
        assert_eq!(totals.active_seconds, 600);
        assert_eq!(totals.idle_seconds, 1200);
        assert_eq!(totals.paused_seconds, 600);
        assert_eq!(totals.privacy_excluded_seconds, 300);
        assert_eq!(totals.system_gap_seconds, 300);
        assert_eq!(totals.unknown_seconds, 600);
        assert!(
            out.windows(2)
                .all(|pair| pair[0].range.end == pair[1].range.start)
        );
    }

    #[test]
    fn only_precise_lifecycle_evidence_can_create_system_gap() {
        let range = UtcInterval::new(t(10, 0), t(10, 1)).unwrap();
        let cases = [
            (AccountingEvidence::Observation, AccountingState::Unknown),
            (AccountingEvidence::ResolverFailure, AccountingState::Active),
            (
                AccountingEvidence::ObservationMissing,
                AccountingState::Unknown,
            ),
            (
                AccountingEvidence::LifecycleGap { precise: false },
                AccountingState::Unknown,
            ),
            (
                AccountingEvidence::LifecycleGap { precise: true },
                AccountingState::SystemGap,
            ),
        ];
        for (evidence, expected) in cases {
            let out = AccountingReducer.reduce_signals(
                &range,
                &[AccountingSignal {
                    interval: range.clone(),
                    state: AccountingState::SystemGap,
                    evidence,
                    attribution: AttributionIdentity::default(),
                }],
            );
            assert_eq!(out.len(), 1);
            assert_eq!(out[0].state, expected);
            assert_eq!(
                totals_for(&out).system_gap_seconds,
                if expected == AccountingState::SystemGap {
                    60
                } else {
                    0
                }
            );
        }
    }

    #[test]
    fn active_attribution_uses_stable_synthetic_parents() {
        let interval = AccountingInterval {
            range: UtcInterval::new(t(10, 0), t(10, 50)).unwrap(),
            state: AccountingState::Active,
            attribution: AttributionIdentity {
                app_id: Some("editor".into()),
                window_id: Some("window-a".into()),
                window_app_id: Some("different-app".into()),
                page_id: Some("page-a".into()),
                page_window_id: Some("different-window".into()),
            },
            source_identity: "fixture".into(),
            source_revision: 1,
        };
        let projected = ActiveAttributionProjector.project(&[interval]);
        assert_eq!(
            projected.apps.iter().map(|item| item.seconds).sum::<i64>(),
            3000
        );
        assert_eq!(projected.windows[0].id, UNATTRIBUTED_WINDOW);
        assert_eq!(projected.windows[0].seconds, 3000);
        assert_eq!(projected.pages[0].id, UNATTRIBUTED_PAGE);
        assert_eq!(projected.pages[0].seconds, 3000);
    }

    #[test]
    fn fixed_clock_is_explicit_and_mutable_without_wall_clock() {
        let clock = FixedAccountingClock::new(t(11, 0));
        assert_eq!(clock.now_utc(), t(11, 0));
        clock.set(t(11, 30));
        assert_eq!(clock.now_utc(), t(11, 30));
    }

    fn interval(
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        state: AccountingState,
        app: Option<&str>,
    ) -> AccountingInterval {
        let app_id = app.map(str::to_owned);
        AccountingInterval {
            range: UtcInterval::new(start, end).unwrap(),
            state,
            attribution: AttributionIdentity {
                app_id: app_id.clone(),
                window_id: app.map(|_| "window".to_owned()),
                window_app_id: app_id,
                page_id: app.map(|_| "page".to_owned()),
                page_window_id: app.map(|_| "window".to_owned()),
            },
            source_identity: format!("fixture:{}", start.timestamp()),
            source_revision: 1,
        }
    }

    #[test]
    fn fixed_clock_snapshot_conserves_active_idle_and_attribution() {
        let store = FakeStore::new(
            vec![
                interval(t(10, 0), t(10, 50), AccountingState::Active, Some("editor")),
                interval(t(10, 50), t(11, 0), AccountingState::Idle, None),
            ],
            t(11, 0),
        );
        let clock = FixedAccountingClock::new(t(11, 0));
        let snapshot = AccountingQueryService::new(&store, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::Current,
            )
            .unwrap();
        assert_eq!(snapshot.totals.active_seconds, 3000);
        assert_eq!(snapshot.totals.idle_seconds, 600);
        assert_eq!(snapshot.totals.accounted_seconds(), 3600);
        assert_eq!(
            snapshot
                .attribution
                .apps
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3000
        );
        assert_eq!(
            snapshot
                .attribution
                .windows
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3000
        );
        assert_eq!(
            snapshot
                .attribution
                .pages
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3000
        );
    }

    #[test]
    fn checkpointed_open_tail_uses_one_effective_end_and_partial_tail_is_unknown() {
        let intervals = vec![
            interval(t(10, 0), t(10, 40), AccountingState::Active, Some("editor")),
            interval(t(10, 40), t(11, 0), AccountingState::Active, Some("editor")),
        ];
        let complete_store = FakeStore::new(intervals.clone(), t(11, 0));
        let clock = FixedAccountingClock::new(t(12, 0));
        let complete = AccountingQueryService::new(&complete_store, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::At { as_of: t(11, 0) },
            )
            .unwrap();
        assert_eq!(complete_store.refresh_calls.load(Ordering::SeqCst), 0);
        assert_eq!(complete.effective.end, t(11, 0));
        assert_eq!(complete.totals.active_seconds, 3600);
        assert_eq!(
            complete
                .attribution
                .apps
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3600
        );
        assert_eq!(
            complete
                .attribution
                .windows
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3600
        );
        assert_eq!(
            complete
                .attribution
                .pages
                .iter()
                .map(|v| v.seconds)
                .sum::<i64>(),
            3600
        );

        let mut partial_store = FakeStore::new(intervals, t(10, 40));
        partial_store.refresh_fails = true;
        let partial = AccountingQueryService::new(&partial_store, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::Current,
            )
            .unwrap();
        assert_eq!(partial.totals.active_seconds, 2400);
        assert_eq!(partial.totals.unknown_seconds, 1200);
        assert_eq!(partial.totals.accounted_seconds(), 3600);
        assert_eq!(partial.integrity, SnapshotIntegrity::Partial);
    }

    #[test]
    fn current_refresh_success_advances_open_tail() {
        let mut store = FakeStore::new(
            vec![interval(
                t(10, 0),
                t(11, 0),
                AccountingState::Active,
                Some("editor"),
            )],
            t(10, 40),
        );
        store.refresh_to = Some(t(11, 0));
        let clock = FixedAccountingClock::new(t(11, 0));
        let snapshot = AccountingQueryService::new(&store, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::Current,
            )
            .unwrap();
        assert_eq!(snapshot.observed_through, t(11, 0));
        assert_eq!(snapshot.totals.active_seconds, 3600);
        assert_eq!(snapshot.integrity, SnapshotIntegrity::Complete);
        assert_eq!(store.refresh_calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn current_read_failures_keep_last_committed_facts_and_force_partial() {
        let facts = vec![interval(
            t(10, 0),
            t(11, 0),
            AccountingState::Active,
            Some("editor"),
        )];
        let mut interval_fail = FakeStore::new(facts.clone(), t(11, 0));
        interval_fail.interval_read_fails = true;
        let clock = FixedAccountingClock::new(t(11, 0));
        let snapshot = AccountingQueryService::new(&interval_fail, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::Current,
            )
            .unwrap();
        assert_eq!(snapshot.totals.active_seconds, 3600);
        assert_eq!(snapshot.integrity, SnapshotIntegrity::Partial);

        let mut watermark_fail = FakeStore::new(facts, t(10, 40));
        watermark_fail.watermark_read_fails = true;
        watermark_fail.refresh_fails = true;
        let snapshot = AccountingQueryService::new(&watermark_fail, &clock)
            .snapshot(
                UtcInterval::new(t(10, 0), t(11, 0)).unwrap(),
                AccountingQuery::Current,
            )
            .unwrap();
        assert_eq!(snapshot.observed_through, t(10, 40));
        assert_eq!(snapshot.totals.active_seconds, 2400);
        assert_eq!(snapshot.totals.unknown_seconds, 1200);
        assert_eq!(snapshot.integrity, SnapshotIntegrity::Partial);
    }

    #[test]
    fn iana_projection_has_23_and_25_hour_days_and_distinct_folds() {
        let projection = IanaLocalDayProjection;
        let spring = projection
            .utc_day_range(
                "America/New_York",
                NaiveDate::from_ymd_opt(2026, 3, 8).unwrap(),
            )
            .unwrap();
        let fall = projection
            .utc_day_range(
                "America/New_York",
                NaiveDate::from_ymd_opt(2026, 11, 1).unwrap(),
            )
            .unwrap();
        assert_eq!(spring.seconds(), 23 * 3600);
        assert_eq!(fall.seconds(), 25 * 3600);

        let intervals = vec![AccountingInterval {
            range: fall.clone(),
            state: AccountingState::Active,
            attribution: AttributionIdentity::default(),
            source_identity: "dst".into(),
            source_revision: 1,
        }];
        let snapshot = AccountingSnapshot {
            requested: fall.clone(),
            effective: fall.clone(),
            observed_through: fall.end,
            totals: totals_for(&intervals),
            intervals,
            attribution: ActiveAttribution::default(),
            integrity: SnapshotIntegrity::Complete,
        };
        let day = projection
            .project(
                "America/New_York",
                NaiveDate::from_ymd_opt(2026, 11, 1).unwrap(),
                &snapshot,
            )
            .unwrap();
        assert_eq!(day.hours.len(), 25);
        assert_eq!(
            day.hours
                .iter()
                .map(|hour| hour.totals.accounted_seconds())
                .sum::<i64>(),
            25 * 3600
        );
        let repeated: Vec<_> = day
            .hours
            .iter()
            .filter(|hour| hour.local_hour == 1)
            .collect();
        assert_eq!(repeated.len(), 2);
        assert_ne!(repeated[0].stable_id, repeated[1].stable_id);
        assert_ne!(
            repeated[0].utc_offset_seconds,
            repeated[1].utc_offset_seconds
        );
        assert_eq!((repeated[0].fold, repeated[1].fold), (0, 1));
    }

    #[test]
    fn local_hour_apps_conserve_active_time_across_23_24_and_25_hour_days() {
        let projection = IanaLocalDayProjection;
        for (year, month, day, expected_hours) in
            [(2026, 3, 8, 23), (2026, 2, 1, 24), (2026, 11, 1, 25)]
        {
            let date = NaiveDate::from_ymd_opt(year, month, day).unwrap();
            let range = projection.utc_day_range("America/New_York", date).unwrap();
            let split = range.start + Duration::minutes(90);
            let idle_start = range.end - Duration::minutes(10);
            let intervals = vec![
                interval(range.start, split, AccountingState::Active, Some("editor")),
                interval(split, idle_start, AccountingState::Active, Some("browser")),
                interval(idle_start, range.end, AccountingState::Idle, None),
            ];
            let snapshot = AccountingSnapshot {
                requested: range.clone(),
                effective: range.clone(),
                observed_through: range.end,
                totals: totals_for(&intervals),
                attribution: ActiveAttributionProjector.project(&intervals),
                intervals,
                integrity: SnapshotIntegrity::Complete,
            };
            let projected = projection
                .project("America/New_York", date, &snapshot)
                .unwrap();
            assert_eq!(projected.hours.len(), expected_hours);
            assert_eq!(
                projected
                    .hours
                    .iter()
                    .map(|hour| hour.totals.active_seconds)
                    .sum::<i64>(),
                projected.totals.active_seconds
            );
            for hour in &projected.hours {
                assert_eq!(
                    hour.apps.iter().map(|app| app.seconds).sum::<i64>(),
                    hour.totals.active_seconds
                );
                assert!(hour.apps.iter().all(|app| app.parent_id.is_none()));
            }
            assert_eq!(projected.hours[0].apps[0].id, "editor");
            assert_eq!(
                projected.hours[1]
                    .apps
                    .iter()
                    .map(|app| app.seconds)
                    .sum::<i64>(),
                3600
            );
            assert!(
                projected
                    .hours
                    .last()
                    .unwrap()
                    .apps
                    .iter()
                    .all(|app| app.id != "__IDLE__")
            );
        }
    }

    #[test]
    fn iana_midnight_transitions_resolve_to_contiguous_local_days() {
        let projection = IanaLocalDayProjection;
        let fixtures = [
            ("America/Havana", (2026, 3, 8)),
            ("America/Santiago", (2026, 9, 6)),
            ("Africa/Cairo", (2026, 4, 24)),
            ("Asia/Beirut", (2026, 3, 29)),
        ];
        for (zone, (year, month, day)) in fixtures {
            let date = NaiveDate::from_ymd_opt(year, month, day).unwrap();
            let range = projection.utc_day_range(zone, date).unwrap();
            let next = projection
                .utc_day_range(zone, date.succ_opt().unwrap())
                .unwrap();
            assert_eq!(
                range.end, next.start,
                "non-contiguous local days for {zone}"
            );

            let intervals = vec![AccountingInterval {
                range: range.clone(),
                state: AccountingState::Unknown,
                attribution: AttributionIdentity::default(),
                source_identity: format!("iana:{zone}"),
                source_revision: 1,
            }];
            let snapshot = AccountingSnapshot {
                requested: range.clone(),
                effective: range.clone(),
                observed_through: range.end,
                totals: totals_for(&intervals),
                intervals,
                attribution: ActiveAttribution::default(),
                integrity: SnapshotIntegrity::Complete,
            };
            let day = projection.project(zone, date, &snapshot).unwrap();
            assert_eq!(
                day.hours
                    .iter()
                    .map(|hour| hour.totals.accounted_seconds())
                    .sum::<i64>(),
                range.seconds(),
                "hour/day mismatch for {zone}"
            );
            let unique: std::collections::HashSet<_> =
                day.hours.iter().map(|hour| &hour.stable_id).collect();
            assert_eq!(unique.len(), day.hours.len());
        }

        let ordinary = projection
            .utc_day_range(
                "America/New_York",
                NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
            )
            .unwrap();
        assert_eq!(ordinary.seconds(), 24 * 3600);
        assert!(matches!(
            projection.utc_day_range("Not/A_Zone", NaiveDate::from_ymd_opt(2026, 1, 1).unwrap()),
            Err(AccountingError::InvalidTimeZone(_))
        ));
    }
}
