//! Canonical, time-zone independent accounting contracts.
//!
//! All ledger ranges are UTC half-open intervals. Consumers must supply an
//! explicit query range and clock; the accounting layer never guesses a date
//! or extends an interval to the process wall clock.

use std::sync::{Arc, Mutex};

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountingState {
    Active,
    Idle,
    Paused,
    PrivacyExcluded,
    SystemGap,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UtcInterval {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

impl UtcInterval {
    pub fn new(start: DateTime<Utc>, end: DateTime<Utc>) -> Result<Self, AccountingError> {
        if start >= end {
            return Err(AccountingError::InvalidRange { start, end });
        }
        Ok(Self { start, end })
    }

    pub fn seconds(&self) -> i64 {
        (self.end - self.start).num_seconds().max(0)
    }

    pub fn intersection(&self, other: &Self) -> Option<Self> {
        let start = self.start.max(other.start);
        let end = self.end.min(other.end);
        (start < end).then_some(Self { start, end })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AttributionIdentity {
    pub app_id: Option<String>,
    pub window_id: Option<String>,
    pub window_app_id: Option<String>,
    pub page_id: Option<String>,
    pub page_window_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountingEvidence {
    Observation,
    ResolverFailure,
    ObservationMissing,
    Pause,
    Privacy,
    Idle,
    /// Only `precise=true` is allowed to produce `SystemGap`.
    LifecycleGap {
        precise: bool,
    },
    Legacy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountingSignal {
    pub interval: UtcInterval,
    pub state: AccountingState,
    pub evidence: AccountingEvidence,
    #[serde(default)]
    pub attribution: AttributionIdentity,
}

impl AccountingSignal {
    pub fn effective_state(&self) -> AccountingState {
        match self.evidence {
            AccountingEvidence::ResolverFailure => AccountingState::Active,
            AccountingEvidence::ObservationMissing => AccountingState::Unknown,
            AccountingEvidence::LifecycleGap { precise: true } => AccountingState::SystemGap,
            AccountingEvidence::LifecycleGap { precise: false } => AccountingState::Unknown,
            AccountingEvidence::Pause => AccountingState::Paused,
            AccountingEvidence::Privacy => AccountingState::PrivacyExcluded,
            AccountingEvidence::Idle => AccountingState::Idle,
            AccountingEvidence::Observation => {
                if self.state == AccountingState::SystemGap {
                    AccountingState::Unknown
                } else {
                    self.state
                }
            }
            AccountingEvidence::Legacy => match self.state {
                AccountingState::Active | AccountingState::Idle => self.state,
                _ => AccountingState::Unknown,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountingInterval {
    pub range: UtcInterval,
    pub state: AccountingState,
    #[serde(default)]
    pub attribution: AttributionIdentity,
    pub source_identity: String,
    pub source_revision: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AccountingTotals {
    pub active_seconds: i64,
    pub idle_seconds: i64,
    pub paused_seconds: i64,
    pub privacy_excluded_seconds: i64,
    pub system_gap_seconds: i64,
    pub unknown_seconds: i64,
}

impl AccountingTotals {
    pub fn add(&mut self, state: AccountingState, seconds: i64) {
        let slot = match state {
            AccountingState::Active => &mut self.active_seconds,
            AccountingState::Idle => &mut self.idle_seconds,
            AccountingState::Paused => &mut self.paused_seconds,
            AccountingState::PrivacyExcluded => &mut self.privacy_excluded_seconds,
            AccountingState::SystemGap => &mut self.system_gap_seconds,
            AccountingState::Unknown => &mut self.unknown_seconds,
        };
        *slot += seconds.max(0);
    }

    pub fn accounted_seconds(&self) -> i64 {
        self.active_seconds
            + self.idle_seconds
            + self.paused_seconds
            + self.privacy_excluded_seconds
            + self.system_gap_seconds
            + self.unknown_seconds
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttributionTotal {
    pub id: String,
    pub parent_id: Option<String>,
    pub seconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ActiveAttribution {
    pub apps: Vec<AttributionTotal>,
    pub windows: Vec<AttributionTotal>,
    pub pages: Vec<AttributionTotal>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotIntegrity {
    Complete,
    Partial,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountingSnapshot {
    pub requested: UtcInterval,
    pub effective: UtcInterval,
    pub observed_through: DateTime<Utc>,
    pub totals: AccountingTotals,
    pub intervals: Vec<AccountingInterval>,
    pub attribution: ActiveAttribution,
    pub integrity: SnapshotIntegrity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountingQuery {
    At { as_of: DateTime<Utc> },
    Current,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CanonicalBatch {
    pub intervals: Vec<AccountingInterval>,
    pub observed_through: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointReason {
    Heartbeat,
    CurrentRead,
    Pause,
    Resume,
    Stop,
    StartupRecovery,
    FirstCutover,
}

impl CheckpointReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Heartbeat => "heartbeat",
            Self::CurrentRead => "current_read",
            Self::Pause => "pause",
            Self::Resume => "resume",
            Self::Stop => "stop",
            Self::StartupRecovery => "startup_recovery",
            Self::FirstCutover => "first_cutover",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum ProducerCheckpointState {
    LegacyPreCutover {
        legacy_observed_through: Option<DateTime<Utc>>,
    },
    CanonicalCurrent {
        cutover_at: DateTime<Utc>,
        observed_through: DateTime<Utc>,
        lifecycle: CheckpointReason,
        last_source_identity: String,
        last_source_revision: i64,
        last_content_hash: String,
    },
}

impl ProducerCheckpointState {
    pub fn observed_through(&self) -> Option<DateTime<Utc>> {
        match self {
            Self::LegacyPreCutover {
                legacy_observed_through,
            } => *legacy_observed_through,
            Self::CanonicalCurrent {
                observed_through, ..
            } => Some(*observed_through),
        }
    }

    pub fn load<S: AccountingStore + ?Sized>(store: &S) -> Result<Self, ProductionCheckpointError> {
        store.load_producer_checkpoint_state()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProductionCheckpoint {
    pub reason: CheckpointReason,
    pub boundary: DateTime<Utc>,
    pub expected_from: Option<DateTime<Utc>>,
    pub source_identity: String,
    pub source_revision: i64,
    pub batch: CanonicalBatch,
    pub first_cutover: bool,
    pub content_hash: String,
}

impl ProductionCheckpoint {
    pub fn staged(
        reason: CheckpointReason,
        boundary: DateTime<Utc>,
        expected_from: Option<DateTime<Utc>>,
        source_identity: String,
        source_revision: i64,
        batch: CanonicalBatch,
        first_cutover: bool,
    ) -> Result<Self, ProductionCheckpointError> {
        if source_identity.trim().is_empty() || source_revision < 0 {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "source identity/revision is invalid".to_owned(),
            ));
        }
        if boundary != batch.observed_through {
            return Err(ProductionCheckpointError::InvalidCheckpoint(
                "boundary must equal batch observed_through".to_owned(),
            ));
        }
        let mut value = Self {
            reason,
            boundary,
            expected_from,
            source_identity,
            source_revision,
            batch,
            first_cutover,
            content_hash: String::new(),
        };
        value.content_hash = value.compute_content_hash();
        Ok(value)
    }

    pub fn compute_content_hash(&self) -> String {
        fn feed(hash: &mut u64, value: &str) {
            for byte in value.as_bytes() {
                *hash ^= u64::from(*byte);
                *hash = hash.wrapping_mul(0x100000001b3);
            }
        }
        let mut hash = 0xcbf29ce484222325_u64;
        feed(&mut hash, self.reason.as_str());
        feed(&mut hash, &self.boundary.to_rfc3339());
        feed(
            &mut hash,
            &self
                .expected_from
                .map(|value| value.to_rfc3339())
                .unwrap_or_default(),
        );
        feed(&mut hash, &self.source_identity);
        feed(&mut hash, &self.source_revision.to_string());
        feed(&mut hash, if self.first_cutover { "1" } else { "0" });
        for item in &self.batch.intervals {
            feed(&mut hash, &item.source_identity);
            feed(&mut hash, &item.source_revision.to_string());
            feed(&mut hash, &item.range.start.to_rfc3339());
            feed(&mut hash, &item.range.end.to_rfc3339());
            feed(&mut hash, &format!("{:?}", item.state));
            feed(&mut hash, item.attribution.app_id.as_deref().unwrap_or(""));
            feed(
                &mut hash,
                item.attribution.window_id.as_deref().unwrap_or(""),
            );
            feed(
                &mut hash,
                item.attribution.window_app_id.as_deref().unwrap_or(""),
            );
            feed(&mut hash, item.attribution.page_id.as_deref().unwrap_or(""));
            feed(
                &mut hash,
                item.attribution.page_window_id.as_deref().unwrap_or(""),
            );
        }
        format!("fnv1a64:{hash:016x}")
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckpointAck {
    pub durable_observed_through: DateTime<Utc>,
    pub cutover_at: DateTime<Utc>,
    pub lifecycle: CheckpointReason,
    pub source_identity: String,
    pub source_revision: i64,
    pub content_hash: String,
    pub replayed: bool,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum ProductionCheckpointError {
    #[error(transparent)]
    Accounting(#[from] AccountingError),
    #[error("invalid production checkpoint: {0}")]
    InvalidCheckpoint(String),
    #[error("checkpoint mode conflict: {0}")]
    ModeConflict(String),
    #[error("stale expected_from: expected {expected:?}, actual {actual:?}")]
    StaleExpectedFrom {
        expected: Option<DateTime<Utc>>,
        actual: Option<DateTime<Utc>>,
    },
    #[error("conflicting replay for {source_identity}@{source_revision}")]
    ConflictingReplay {
        source_identity: String,
        source_revision: i64,
    },
    #[error("stale checkpoint revision for {source_identity}: {incoming} < {existing}")]
    StaleRevision {
        source_identity: String,
        incoming: i64,
        existing: i64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LifecycleEvidence {
    pub interval: UtcInterval,
    pub precise: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoveryPoint {
    pub restart_at: DateTime<Utc>,
    pub first_successful_observation: DateTime<Utc>,
    pub lifecycle: Option<LifecycleEvidence>,
    pub source_identity: String,
    pub source_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalHourBucket {
    pub stable_id: String,
    pub local_date: NaiveDate,
    pub local_hour: u32,
    pub utc_offset_seconds: i32,
    pub fold: u8,
    pub range: UtcInterval,
    pub totals: AccountingTotals,
    pub apps: Vec<AttributionTotal>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalDayProjection {
    pub zone: String,
    pub local_date: NaiveDate,
    pub utc_range: UtcInterval,
    pub hours: Vec<LocalHourBucket>,
    pub totals: AccountingTotals,
}

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AccountingError {
    #[error("invalid accounting range [{start}, {end})")]
    InvalidRange {
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    },
    #[error("as_of {as_of} predates range start {start}")]
    AsOfBeforeStart {
        as_of: DateTime<Utc>,
        start: DateTime<Utc>,
    },
    #[error("as_of {as_of} is later than allowed deadline {deadline}")]
    FutureAsOf {
        as_of: DateTime<Utc>,
        deadline: DateTime<Utc>,
    },
    #[error("invalid IANA time zone: {0}")]
    InvalidTimeZone(String),
    #[error("local boundary is ambiguous or missing in {zone}: {boundary}")]
    InvalidLocalBoundary { zone: String, boundary: String },
    #[error("accounting storage error: {0}")]
    Storage(String),
    #[error(
        "stale accounting revision for {source_identity}: incoming {incoming}, existing {existing}"
    )]
    StaleRevision {
        source_identity: String,
        incoming: i64,
        existing: i64,
    },
}

pub trait AccountingClock: Send + Sync {
    fn now_utc(&self) -> DateTime<Utc>;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemAccountingClock;

impl AccountingClock for SystemAccountingClock {
    fn now_utc(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

#[derive(Debug, Clone)]
pub struct FixedAccountingClock {
    now: Arc<Mutex<DateTime<Utc>>>,
}

impl FixedAccountingClock {
    pub fn new(now: DateTime<Utc>) -> Self {
        Self {
            now: Arc::new(Mutex::new(now)),
        }
    }

    pub fn set(&self, now: DateTime<Utc>) {
        match self.now.lock() {
            Ok(mut guard) => *guard = now,
            Err(poisoned) => *poisoned.into_inner() = now,
        }
    }
}

impl AccountingClock for FixedAccountingClock {
    fn now_utc(&self) -> DateTime<Utc> {
        match self.now.lock() {
            Ok(guard) => *guard,
            Err(poisoned) => *poisoned.into_inner(),
        }
    }
}

pub trait AccountingStore: Send + Sync {
    fn load_producer_checkpoint_state(
        &self,
    ) -> Result<ProducerCheckpointState, ProductionCheckpointError> {
        Err(ProductionCheckpointError::InvalidCheckpoint(
            "producer checkpoint state is not supported by this store".to_owned(),
        ))
    }
    fn commit_production_checkpoint(
        &self,
        checkpoint: &ProductionCheckpoint,
    ) -> Result<CheckpointAck, ProductionCheckpointError> {
        let _ = checkpoint;
        Err(ProductionCheckpointError::InvalidCheckpoint(
            "production checkpoint commit is not supported by this store".to_owned(),
        ))
    }
    fn write_canonical_batch(&self, batch: &CanonicalBatch) -> Result<(), AccountingError>;
    fn load_accounting_intervals(
        &self,
        range: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError>;
    fn durable_observed_through(&self) -> Result<Option<DateTime<Utc>>, AccountingError>;
    /// Best-effort cached/last committed watermark used only by degraded
    /// `Current` reads. It must never exceed a successfully committed value.
    fn last_known_observed_through(&self) -> Option<DateTime<Utc>> {
        None
    }
    /// Refresh/checkpoint the currently open source at one explicit `as_of`.
    /// Implementations must return the new durable watermark only after the
    /// checkpoint transaction commits.
    fn refresh_current(
        &self,
        as_of: DateTime<Utc>,
    ) -> Result<Option<DateTime<Utc>>, AccountingError>;
    /// Read the last committed facts without attempting another refresh. This
    /// fallback lets `Current` preserve known facts after a primary read error.
    fn load_last_durable_intervals(
        &self,
        range: &UtcInterval,
    ) -> Result<Vec<AccountingInterval>, AccountingError> {
        self.load_accounting_intervals(range)
    }
    fn recover_after_restart(&self, point: &RecoveryPoint) -> Result<(), AccountingError>;
}
