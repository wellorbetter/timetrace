//! Typed bridge for the canonical accounting ledger.
//!
//! This module deliberately does not perform accounting. It validates bridge
//! inputs, asks `timetrace-core` for one canonical snapshot, and maps the
//! public snapshot/projection types into FFI-friendly DTOs. CSV export is a
//! pure serialization of the snapshot passed to it.

use std::fmt;

use chrono::{DateTime, NaiveDate, Utc};
use timetrace_core::{
    AccountingClock, AccountingError, AccountingQuery, AccountingQueryService, AccountingSnapshot,
    AccountingState, AccountingStore, AccountingTotals, AttributionTotal, IanaLocalDayProjection,
    LocalDayProjection, SnapshotIntegrity, UtcInterval,
};

pub const ACCOUNTING_EXPORT_SCHEMA_VERSION: &str = "timetrace-accounting-csv-v1";
pub const ACCEPTED_PRODUCER_BRIDGE_INTERFACE_HASH: &str =
    "c3500be242ea4bafc6c915fbafe650b35092db4296d02aadd2df33fe328efd8f";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountingRangeRequest {
    Utc {
        start_utc: String,
        end_utc: String,
    },
    LocalDate {
        local_date: String,
        timezone: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountingAsOfRequest {
    Current,
    At { as_of_utc: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountingStateDto {
    Active,
    Idle,
    Paused,
    PrivacyExcluded,
    SystemGap,
    Unknown,
}

impl AccountingStateDto {
    fn as_csv(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Idle => "idle",
            Self::Paused => "paused",
            Self::PrivacyExcluded => "privacy_excluded",
            Self::SystemGap => "system_gap",
            Self::Unknown => "unknown",
        }
    }
}

impl From<AccountingState> for AccountingStateDto {
    fn from(value: AccountingState) -> Self {
        match value {
            AccountingState::Active => Self::Active,
            AccountingState::Idle => Self::Idle,
            AccountingState::Paused => Self::Paused,
            AccountingState::PrivacyExcluded => Self::PrivacyExcluded,
            AccountingState::SystemGap => Self::SystemGap,
            AccountingState::Unknown => Self::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotIntegrityDto {
    Complete,
    Partial,
}

impl SnapshotIntegrityDto {
    fn as_csv(self) -> &'static str {
        match self {
            Self::Complete => "complete",
            Self::Partial => "partial",
        }
    }
}

impl From<SnapshotIntegrity> for SnapshotIntegrityDto {
    fn from(value: SnapshotIntegrity) -> Self {
        match value {
            SnapshotIntegrity::Complete => Self::Complete,
            SnapshotIntegrity::Partial => Self::Partial,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountingTotalsDto {
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub paused_seconds: i64,
    pub privacy_excluded_seconds: i64,
    pub system_gap_seconds: i64,
    pub unknown_seconds: i64,
    pub accounted_seconds: i64,
}

impl From<&AccountingTotals> for AccountingTotalsDto {
    fn from(value: &AccountingTotals) -> Self {
        Self {
            active_seconds: value.active_seconds,
            idle_seconds: value.idle_seconds,
            paused_seconds: value.paused_seconds,
            privacy_excluded_seconds: value.privacy_excluded_seconds,
            system_gap_seconds: value.system_gap_seconds,
            unknown_seconds: value.unknown_seconds,
            accounted_seconds: value.accounted_seconds(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountingIntervalDto {
    pub start_utc: String,
    pub end_utc: String,
    pub state: AccountingStateDto,
    pub app_id: Option<String>,
    pub window_id: Option<String>,
    pub window_app_id: Option<String>,
    pub page_id: Option<String>,
    pub page_window_id: Option<String>,
    pub source_identity: String,
    pub source_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttributionTotalDto {
    pub id: String,
    pub parent_id: Option<String>,
    pub seconds: i64,
}

impl From<&AttributionTotal> for AttributionTotalDto {
    fn from(value: &AttributionTotal) -> Self {
        Self {
            id: value.id.clone(),
            parent_id: value.parent_id.clone(),
            seconds: value.seconds,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalHourBucketDto {
    pub stable_id: String,
    pub local_date: String,
    pub local_hour: u32,
    pub utc_offset_seconds: i32,
    pub fold: u8,
    pub start_utc: String,
    pub end_utc: String,
    pub totals: AccountingTotalsDto,
    pub apps: Vec<AttributionTotalDto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountingSnapshotDto {
    pub requested_start_utc: String,
    pub requested_end_utc: String,
    pub effective_start_utc: String,
    pub effective_end_utc: String,
    pub observed_through_utc: String,
    pub totals: AccountingTotalsDto,
    pub intervals: Vec<AccountingIntervalDto>,
    pub apps: Vec<AttributionTotalDto>,
    pub windows: Vec<AttributionTotalDto>,
    pub pages: Vec<AttributionTotalDto>,
    pub integrity: SnapshotIntegrityDto,
    pub timezone: Option<String>,
    pub local_date: Option<String>,
    pub hours: Vec<LocalHourBucketDto>,
}

impl AccountingSnapshotDto {
    pub fn from_core(
        snapshot: &AccountingSnapshot,
        local_day: Option<&LocalDayProjection>,
    ) -> Self {
        let intervals = snapshot
            .intervals
            .iter()
            .map(|item| AccountingIntervalDto {
                start_utc: format_utc(item.range.start),
                end_utc: format_utc(item.range.end),
                state: item.state.into(),
                app_id: item.attribution.app_id.clone(),
                window_id: item.attribution.window_id.clone(),
                window_app_id: item.attribution.window_app_id.clone(),
                page_id: item.attribution.page_id.clone(),
                page_window_id: item.attribution.page_window_id.clone(),
                source_identity: item.source_identity.clone(),
                source_revision: item.source_revision,
            })
            .collect();
        let hours = local_day
            .map(|day| {
                day.hours
                    .iter()
                    .map(|hour| LocalHourBucketDto {
                        stable_id: hour.stable_id.clone(),
                        local_date: hour.local_date.to_string(),
                        local_hour: hour.local_hour,
                        utc_offset_seconds: hour.utc_offset_seconds,
                        fold: hour.fold,
                        start_utc: format_utc(hour.range.start),
                        end_utc: format_utc(hour.range.end),
                        totals: (&hour.totals).into(),
                        apps: hour.apps.iter().map(AttributionTotalDto::from).collect(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        Self {
            requested_start_utc: format_utc(snapshot.requested.start),
            requested_end_utc: format_utc(snapshot.requested.end),
            effective_start_utc: format_utc(snapshot.effective.start),
            effective_end_utc: format_utc(snapshot.effective.end),
            observed_through_utc: format_utc(snapshot.observed_through),
            totals: (&snapshot.totals).into(),
            intervals,
            apps: snapshot
                .attribution
                .apps
                .iter()
                .map(AttributionTotalDto::from)
                .collect(),
            windows: snapshot
                .attribution
                .windows
                .iter()
                .map(AttributionTotalDto::from)
                .collect(),
            pages: snapshot
                .attribution
                .pages
                .iter()
                .map(AttributionTotalDto::from)
                .collect(),
            integrity: snapshot.integrity.into(),
            timezone: local_day.map(|day| day.zone.clone()),
            local_date: local_day.map(|day| day.local_date.to_string()),
            hours,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountingBridgeError {
    InvalidUtcTimestamp {
        field: String,
        value: String,
    },
    InvalidLocalDate {
        value: String,
    },
    InvalidDateRange {
        start: String,
        end: String,
    },
    InvalidRange {
        start_utc: String,
        end_utc: String,
    },
    AsOfBeforeStart {
        as_of_utc: String,
        start_utc: String,
    },
    FutureAsOf {
        as_of_utc: String,
        deadline_utc: String,
    },
    InvalidTimeZone {
        timezone: String,
    },
    InvalidLocalBoundary {
        timezone: String,
        boundary: String,
    },
    Storage {
        message: String,
    },
    StaleRevision {
        source_identity: String,
        incoming: i64,
        existing: i64,
    },
    ProducerUnavailable {
        message: String,
    },
}

impl fmt::Display for AccountingBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for AccountingBridgeError {}

impl From<AccountingError> for AccountingBridgeError {
    fn from(value: AccountingError) -> Self {
        match value {
            AccountingError::InvalidRange { start, end } => Self::InvalidRange {
                start_utc: format_utc(start),
                end_utc: format_utc(end),
            },
            AccountingError::AsOfBeforeStart { as_of, start } => Self::AsOfBeforeStart {
                as_of_utc: format_utc(as_of),
                start_utc: format_utc(start),
            },
            AccountingError::FutureAsOf { as_of, deadline } => Self::FutureAsOf {
                as_of_utc: format_utc(as_of),
                deadline_utc: format_utc(deadline),
            },
            AccountingError::InvalidTimeZone(timezone) => Self::InvalidTimeZone { timezone },
            AccountingError::InvalidLocalBoundary { zone, boundary } => {
                Self::InvalidLocalBoundary {
                    timezone: zone,
                    boundary,
                }
            }
            AccountingError::Storage(message) => Self::Storage { message },
            AccountingError::StaleRevision {
                source_identity,
                incoming,
                existing,
            } => Self::StaleRevision {
                source_identity,
                incoming,
                existing,
            },
        }
    }
}

/// Historical-only test and tooling seam. Current reads are intentionally not
/// accepted here because they must pass through `CanonicalMonitorHandle` on
/// `TimeTraceApi` before querying the canonical snapshot.
pub fn query_accounting_snapshot_at<S, C>(
    store: &S,
    clock: &C,
    range: AccountingRangeRequest,
    as_of_utc: String,
) -> Result<AccountingSnapshotDto, AccountingBridgeError>
where
    S: AccountingStore,
    C: AccountingClock,
{
    let resolved = resolve_accounting_request(range, AccountingAsOfRequest::At { as_of_utc })?;
    let snapshot = AccountingQueryService::new(store, clock)
        .snapshot(resolved.requested.clone(), resolved.query)?;
    map_accounting_snapshot(&snapshot, &resolved)
}

/// Parsed bridge request used by production orchestration. It carries only the
/// canonical core query and optional local-day projection coordinates; it does
/// not contain a second accounting model.
pub(crate) struct ResolvedAccountingRequest {
    pub(crate) requested: UtcInterval,
    pub(crate) query: AccountingQuery,
    local: Option<(String, NaiveDate)>,
}

pub(crate) fn resolve_accounting_request(
    range: AccountingRangeRequest,
    as_of: AccountingAsOfRequest,
) -> Result<ResolvedAccountingRequest, AccountingBridgeError> {
    let (requested, local) = resolve_range(&range)?;
    Ok(ResolvedAccountingRequest {
        requested,
        query: resolve_as_of(as_of)?,
        local,
    })
}

pub(crate) fn map_accounting_snapshot(
    snapshot: &AccountingSnapshot,
    request: &ResolvedAccountingRequest,
) -> Result<AccountingSnapshotDto, AccountingBridgeError> {
    let local_day = request
        .local
        .as_ref()
        .map(|(timezone, date)| IanaLocalDayProjection.project(timezone, *date, snapshot))
        .transpose()?;
    Ok(AccountingSnapshotDto::from_core(
        snapshot,
        local_day.as_ref(),
    ))
}

pub fn utc_range_for_local_dates(
    start: &str,
    end: &str,
    timezone: &str,
) -> Result<UtcInterval, AccountingBridgeError> {
    let start_date = parse_local_date(start)?;
    let end_date = parse_local_date(end)?;
    if start_date > end_date {
        return Err(AccountingBridgeError::InvalidDateRange {
            start: start.to_owned(),
            end: end.to_owned(),
        });
    }
    let projector = IanaLocalDayProjection;
    let start_range = projector.utc_day_range(timezone, start_date)?;
    let end_range = projector.utc_day_range(timezone, end_date)?;
    Ok(UtcInterval::new(start_range.start, end_range.end)?)
}

fn resolve_range(
    request: &AccountingRangeRequest,
) -> Result<(UtcInterval, Option<(String, NaiveDate)>), AccountingBridgeError> {
    match request {
        AccountingRangeRequest::Utc { start_utc, end_utc } => Ok((
            UtcInterval::new(
                parse_utc("start_utc", start_utc)?,
                parse_utc("end_utc", end_utc)?,
            )?,
            None,
        )),
        AccountingRangeRequest::LocalDate {
            local_date,
            timezone,
        } => {
            let date = parse_local_date(local_date)?;
            let range = IanaLocalDayProjection.utc_day_range(timezone, date)?;
            Ok((range, Some((timezone.clone(), date))))
        }
    }
}

fn resolve_as_of(request: AccountingAsOfRequest) -> Result<AccountingQuery, AccountingBridgeError> {
    match request {
        AccountingAsOfRequest::Current => Ok(AccountingQuery::Current),
        AccountingAsOfRequest::At { as_of_utc } => Ok(AccountingQuery::At {
            as_of: parse_utc("as_of_utc", &as_of_utc)?,
        }),
    }
}

fn parse_utc(field: &str, value: &str) -> Result<DateTime<Utc>, AccountingBridgeError> {
    let parsed = DateTime::parse_from_rfc3339(value).map_err(|_| {
        AccountingBridgeError::InvalidUtcTimestamp {
            field: field.to_owned(),
            value: value.to_owned(),
        }
    })?;
    if parsed.offset().local_minus_utc() != 0 {
        return Err(AccountingBridgeError::InvalidUtcTimestamp {
            field: field.to_owned(),
            value: value.to_owned(),
        });
    }
    Ok(parsed.with_timezone(&Utc))
}

fn parse_local_date(value: &str) -> Result<NaiveDate, AccountingBridgeError> {
    NaiveDate::parse_from_str(value, "%Y-%m-%d").map_err(|_| {
        AccountingBridgeError::InvalidLocalDate {
            value: value.to_owned(),
        }
    })
}

fn format_utc(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

#[derive(Debug, Default, Clone, Copy)]
pub struct AccountingExportCsv;

impl AccountingExportCsv {
    pub const HEADER: &'static str = "schema_version,row_type,requested_start_utc,requested_end_utc,effective_start_utc,effective_end_utc,observed_through_utc,integrity,state,id,parent_id,seconds\n";

    pub fn empty() -> String {
        Self::HEADER.to_owned()
    }

    pub fn serialize(snapshot: &AccountingSnapshot) -> String {
        let mut output = Self::empty();
        let common = CsvCommon::from_snapshot(snapshot);
        push_csv_row(
            &mut output,
            &common,
            "snapshot",
            "",
            "",
            "",
            snapshot.totals.accounted_seconds(),
        );
        for (state, seconds) in state_totals(&snapshot.totals) {
            push_csv_row(
                &mut output,
                &common,
                "state",
                state.as_csv(),
                "",
                "",
                seconds,
            );
        }
        for app in &snapshot.attribution.apps {
            push_csv_row(
                &mut output,
                &common,
                "app",
                "",
                &app.id,
                app.parent_id.as_deref().unwrap_or(""),
                app.seconds,
            );
        }
        for window in &snapshot.attribution.windows {
            push_csv_row(
                &mut output,
                &common,
                "window",
                "",
                &window.id,
                window.parent_id.as_deref().unwrap_or(""),
                window.seconds,
            );
        }
        output
    }
}

struct CsvCommon {
    requested_start_utc: String,
    requested_end_utc: String,
    effective_start_utc: String,
    effective_end_utc: String,
    observed_through_utc: String,
    integrity: SnapshotIntegrityDto,
}

impl CsvCommon {
    fn from_snapshot(snapshot: &AccountingSnapshot) -> Self {
        Self {
            requested_start_utc: format_utc(snapshot.requested.start),
            requested_end_utc: format_utc(snapshot.requested.end),
            effective_start_utc: format_utc(snapshot.effective.start),
            effective_end_utc: format_utc(snapshot.effective.end),
            observed_through_utc: format_utc(snapshot.observed_through),
            integrity: snapshot.integrity.into(),
        }
    }
}

fn state_totals(totals: &AccountingTotals) -> [(AccountingStateDto, i64); 6] {
    [
        (AccountingStateDto::Active, totals.active_seconds),
        (AccountingStateDto::Idle, totals.idle_seconds),
        (AccountingStateDto::Paused, totals.paused_seconds),
        (
            AccountingStateDto::PrivacyExcluded,
            totals.privacy_excluded_seconds,
        ),
        (AccountingStateDto::SystemGap, totals.system_gap_seconds),
        (AccountingStateDto::Unknown, totals.unknown_seconds),
    ]
}

fn push_csv_row(
    output: &mut String,
    common: &CsvCommon,
    row_type: &str,
    state: &str,
    id: &str,
    parent_id: &str,
    seconds: i64,
) {
    let fields = [
        ACCOUNTING_EXPORT_SCHEMA_VERSION.to_owned(),
        row_type.to_owned(),
        common.requested_start_utc.clone(),
        common.requested_end_utc.clone(),
        common.effective_start_utc.clone(),
        common.effective_end_utc.clone(),
        common.observed_through_utc.clone(),
        common.integrity.as_csv().to_owned(),
        state.to_owned(),
        id.to_owned(),
        parent_id.to_owned(),
        seconds.to_string(),
    ];
    for (index, field) in fields.iter().enumerate() {
        if index > 0 {
            output.push(',');
        }
        output.push_str(&csv_field(field));
    }
    output.push('\n');
}

fn csv_field(value: &str) -> String {
    if value.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_owned()
    }
}
