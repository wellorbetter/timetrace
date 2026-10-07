//! Privacy-minimized coverage domain types.
//!
//! Persisted states and query-synthesized states are intentionally separate:
//! storage transitions can only accept [`CoverageState`], while legacy,
//! missing, corrupt, overlap, and unknown-version results exist only as
//! [`SynthesizedCoverageState`] values in query evidence.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use thiserror::Error;

use super::time::{TimeRangeError, UtcIntervalBounds, UtcRange, parse_utc_rfc3339};

/// The only states normal collection is allowed to persist.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageState {
    Active,
    Paused,
    PrivacyExcluded,
    Idle,
    SystemGap,
}

/// Closed, non-sensitive reasons. There is no arbitrary text payload.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageReason {
    NormalObservation,
    UserPaused,
    AutoStartDisabled,
    PrivacyPolicy,
    IdleThreshold,
    ScreenLocked,
    ResolverUnavailable,
    SleepOrFreeze,
    AwaitingInitialObservation,
    UncleanShutdown,
    StorageUnavailable,
}

impl CoverageReason {
    fn is_valid_for(self, state: CoverageState) -> bool {
        match state {
            CoverageState::Active => matches!(self, Self::NormalObservation),
            CoverageState::Paused => {
                matches!(self, Self::UserPaused | Self::AutoStartDisabled)
            }
            CoverageState::PrivacyExcluded => matches!(self, Self::PrivacyPolicy),
            CoverageState::Idle => matches!(self, Self::IdleThreshold | Self::ScreenLocked),
            CoverageState::SystemGap => matches!(
                self,
                Self::ResolverUnavailable
                    | Self::SleepOrFreeze
                    | Self::AwaitingInitialObservation
                    | Self::UncleanShutdown
                    | Self::StorageUnavailable
            ),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Completeness {
    Complete,
    Partial,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OverallCompleteness {
    Complete,
    Partial,
    Unknown,
}

/// Version pair attached to persisted facts and returned by queries.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
pub struct ContractVersions {
    policy_version: u32,
    schema_version: u32,
}

impl ContractVersions {
    pub fn new(policy_version: u32, schema_version: u32) -> Result<Self, CoverageError> {
        if policy_version == 0 || schema_version == 0 {
            return Err(CoverageError::ZeroVersion);
        }
        Ok(Self {
            policy_version,
            schema_version,
        })
    }

    pub const fn policy_version(&self) -> u32 {
        self.policy_version
    }

    pub const fn schema_version(&self) -> u32 {
        self.schema_version
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawContractVersions {
    policy_version: u32,
    schema_version: u32,
}

impl<'de> Deserialize<'de> for ContractVersions {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawContractVersions::deserialize(deserializer)?;
        Self::new(raw.policy_version, raw.schema_version).map_err(D::Error::custom)
    }
}

/// Explicit allow-list for contract pairs understood by a query evaluator.
///
/// Persisted rows retain their original numeric versions. Trust is granted only
/// after the complete policy/schema pair has been validated against this value.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SupportedVersionPolicy {
    supported: BTreeSet<ContractVersions>,
}

impl SupportedVersionPolicy {
    pub fn exact(versions: ContractVersions) -> Self {
        Self {
            supported: BTreeSet::from([versions]),
        }
    }

    pub fn from_pairs(
        versions: impl IntoIterator<Item = ContractVersions>,
    ) -> Result<Self, CoverageError> {
        let supported = versions.into_iter().collect::<BTreeSet<_>>();
        if supported.is_empty() {
            return Err(CoverageError::EmptySupportedVersionPolicy);
        }
        Ok(Self { supported })
    }

    pub fn validate(&self, versions: ContractVersions) -> Option<KnownContractVersions> {
        self.supported
            .contains(&versions)
            .then_some(KnownContractVersions(versions))
    }
}

/// Proof that a complete policy/schema pair is understood by the evaluator.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct KnownContractVersions(ContractVersions);

impl KnownContractVersions {
    pub const fn get(self) -> ContractVersions {
        self.0
    }
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum CoverageError {
    #[error(transparent)]
    Time(#[from] TimeRangeError),
    #[error("policy_version and schema_version must be non-zero")]
    ZeroVersion,
    #[error("supported-version policy must contain at least one complete pair")]
    EmptySupportedVersionPolicy,
    #[error("revision must be non-zero")]
    ZeroRevision,
    #[error("reason is not valid for persisted state {state:?}")]
    InvalidReason { state: CoverageState },
    #[error("system_gap intervals must be partial")]
    CompleteSystemGap,
    #[error("observed_through precedes started_at")]
    ObservationBeforeStart,
    #[error("observed_through exceeds ended_at")]
    ObservationAfterEnd,
    #[error("complete closed interval must be observed through ended_at")]
    IncompleteObservationForCompleteInterval,
    #[error("segment lies outside the requested UTC range")]
    SegmentOutsideRequest,
    #[error("persisted interval does not contain the requested segment range")]
    SegmentOutsideInterval,
    #[error("serialized coverage segment violates state or observation invariants")]
    InvalidSerializedSegment,
    #[error("serialized coverage diagnostic violates its closed wire contract")]
    InvalidSerializedDiagnostic,
    #[error("serialized coverage evidence is not a validated ordered partition")]
    InvalidSerializedEvidence,
}

/// A validated persisted interval. Its serialized form has no free-text or
/// identity-bearing fields.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoverageInterval {
    state: CoverageState,
    bounds: UtcIntervalBounds,
    reason: CoverageReason,
    completeness: Completeness,
    versions: ContractVersions,
    observed_through: DateTime<Utc>,
    revision: u64,
}

impl CoverageInterval {
    pub fn closed(
        state: CoverageState,
        range: UtcRange,
        reason: CoverageReason,
        completeness: Completeness,
        versions: ContractVersions,
        observed_through: DateTime<Utc>,
        revision: u64,
    ) -> Result<Self, CoverageError> {
        Self::new(
            state,
            UtcIntervalBounds::closed(range),
            reason,
            completeness,
            versions,
            observed_through,
            revision,
        )
    }

    pub fn open(
        state: CoverageState,
        started_at: DateTime<Utc>,
        reason: CoverageReason,
        completeness: Completeness,
        versions: ContractVersions,
        observed_through: DateTime<Utc>,
        revision: u64,
    ) -> Result<Self, CoverageError> {
        Self::new(
            state,
            UtcIntervalBounds::open(started_at),
            reason,
            completeness,
            versions,
            observed_through,
            revision,
        )
    }

    fn new(
        state: CoverageState,
        bounds: UtcIntervalBounds,
        reason: CoverageReason,
        completeness: Completeness,
        versions: ContractVersions,
        observed_through: DateTime<Utc>,
        revision: u64,
    ) -> Result<Self, CoverageError> {
        if revision == 0 {
            return Err(CoverageError::ZeroRevision);
        }
        if !reason.is_valid_for(state) {
            return Err(CoverageError::InvalidReason { state });
        }
        if state == CoverageState::SystemGap && completeness == Completeness::Complete {
            return Err(CoverageError::CompleteSystemGap);
        }
        if observed_through < bounds.started_at() {
            return Err(CoverageError::ObservationBeforeStart);
        }
        if let Some(ended_at) = bounds.ended_at() {
            if observed_through > ended_at {
                return Err(CoverageError::ObservationAfterEnd);
            }
            if completeness == Completeness::Complete && observed_through != ended_at {
                return Err(CoverageError::IncompleteObservationForCompleteInterval);
            }
        }
        Ok(Self {
            state,
            bounds,
            reason,
            completeness,
            versions,
            observed_through,
            revision,
        })
    }

    pub const fn state(&self) -> CoverageState {
        self.state
    }

    pub const fn bounds(&self) -> UtcIntervalBounds {
        self.bounds
    }

    pub const fn reason(&self) -> CoverageReason {
        self.reason
    }

    pub const fn completeness(&self) -> Completeness {
        self.completeness
    }

    pub const fn versions(&self) -> ContractVersions {
        self.versions
    }

    pub const fn observed_through(&self) -> DateTime<Utc> {
        self.observed_through
    }

    pub const fn revision(&self) -> u64 {
        self.revision
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCoverageInterval {
    state: CoverageState,
    bounds: UtcIntervalBounds,
    reason: CoverageReason,
    completeness: Completeness,
    versions: ContractVersions,
    observed_through: String,
    revision: u64,
}

impl<'de> Deserialize<'de> for CoverageInterval {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawCoverageInterval::deserialize(deserializer)?;
        Self::new(
            raw.state,
            raw.bounds,
            raw.reason,
            raw.completeness,
            raw.versions,
            parse_utc_rfc3339(&raw.observed_through).map_err(D::Error::custom)?,
            raw.revision,
        )
        .map_err(D::Error::custom)
    }
}

/// Query output state. Synthesized variants can never be passed to a normal
/// persistence transition because [`CoverageInterval`] accepts only
/// [`CoverageState`].
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(tag = "kind", content = "state", rename_all = "snake_case")]
pub enum SynthesizedCoverageState {
    Persisted(CoverageState),
    LegacyUnknown,
    Missing,
    Corrupt,
    Overlap,
    UnknownVersion,
}

/// Query segment with a closed, validated serde contract. Persistence input
/// still uses [`CoverageInterval`], so synthesized states cannot be stored as
/// normal collection facts.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoverageSegment {
    range: UtcRange,
    state: SynthesizedCoverageState,
    completeness: Completeness,
    versions: Option<ContractVersions>,
    observed_through: Option<DateTime<Utc>>,
}

impl CoverageSegment {
    pub fn persisted(range: UtcRange, interval: &CoverageInterval) -> Result<Self, CoverageError> {
        if range.started_at() < interval.bounds().started_at()
            || interval
                .bounds()
                .ended_at()
                .is_some_and(|ended_at| range.ended_at() > ended_at)
        {
            return Err(CoverageError::SegmentOutsideInterval);
        }
        Ok(Self {
            range,
            state: SynthesizedCoverageState::Persisted(interval.state()),
            completeness: interval.completeness(),
            versions: Some(interval.versions()),
            observed_through: Some(interval.observed_through()),
        })
    }

    pub fn legacy_unknown(range: UtcRange) -> Self {
        Self::synthesized(range, SynthesizedCoverageState::LegacyUnknown, None)
    }

    pub fn missing(range: UtcRange) -> Self {
        Self::synthesized(range, SynthesizedCoverageState::Missing, None)
    }

    pub fn corrupt(range: UtcRange, versions: Option<ContractVersions>) -> Self {
        Self::synthesized(range, SynthesizedCoverageState::Corrupt, versions)
    }

    pub fn overlap(range: UtcRange, versions: Option<ContractVersions>) -> Self {
        Self::synthesized(range, SynthesizedCoverageState::Overlap, versions)
    }

    pub fn unknown_version(range: UtcRange, versions: ContractVersions) -> Self {
        Self::synthesized(
            range,
            SynthesizedCoverageState::UnknownVersion,
            Some(versions),
        )
    }

    fn synthesized(
        range: UtcRange,
        state: SynthesizedCoverageState,
        versions: Option<ContractVersions>,
    ) -> Self {
        Self {
            range,
            state,
            completeness: Completeness::Partial,
            versions,
            observed_through: None,
        }
    }

    pub const fn range(&self) -> UtcRange {
        self.range
    }

    pub const fn state(&self) -> SynthesizedCoverageState {
        self.state
    }

    pub const fn completeness(&self) -> Completeness {
        self.completeness
    }

    pub const fn versions(&self) -> Option<ContractVersions> {
        self.versions
    }

    pub const fn observed_through(&self) -> Option<DateTime<Utc>> {
        self.observed_through
    }

    fn slice_for_query(&self, range: UtcRange, supported: &SupportedVersionPolicy) -> Self {
        if let Some(versions) = self.versions
            && supported.validate(versions).is_none()
        {
            return Self::unknown_version(range, versions);
        }
        let observation_valid_completeness = if self.completeness == Completeness::Complete
            && self
                .observed_through
                .is_some_and(|observed| observed >= range.ended_at())
        {
            Completeness::Complete
        } else {
            Completeness::Partial
        };
        Self {
            range,
            state: self.state,
            completeness: observation_valid_completeness,
            versions: self.versions,
            observed_through: self.observed_through,
        }
    }

    fn is_trusted_complete_active(&self, supported: &SupportedVersionPolicy) -> bool {
        self.state == SynthesizedCoverageState::Persisted(CoverageState::Active)
            && self.completeness == Completeness::Complete
            && self
                .observed_through
                .is_some_and(|observed| observed >= self.range.ended_at())
            && self
                .versions
                .and_then(|versions| supported.validate(versions))
                .is_some()
    }

    fn has_valid_wire_shape(&self) -> bool {
        match self.state {
            SynthesizedCoverageState::Persisted(_) => {
                self.versions.is_some()
                    && self.observed_through.is_some()
                    && (self.completeness == Completeness::Partial
                        || self
                            .observed_through
                            .is_some_and(|observed| observed >= self.range.ended_at()))
            }
            SynthesizedCoverageState::LegacyUnknown | SynthesizedCoverageState::Missing => {
                self.completeness == Completeness::Partial
                    && self.versions.is_none()
                    && self.observed_through.is_none()
            }
            SynthesizedCoverageState::Corrupt | SynthesizedCoverageState::Overlap => {
                self.completeness == Completeness::Partial && self.observed_through.is_none()
            }
            SynthesizedCoverageState::UnknownVersion => {
                self.completeness == Completeness::Partial
                    && self.versions.is_some()
                    && self.observed_through.is_none()
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCoverageSegment {
    range: UtcRange,
    state: SynthesizedCoverageState,
    completeness: Completeness,
    versions: Option<ContractVersions>,
    observed_through: Option<String>,
}

impl<'de> Deserialize<'de> for CoverageSegment {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawCoverageSegment::deserialize(deserializer)?;
        let segment = Self {
            range: raw.range,
            state: raw.state,
            completeness: raw.completeness,
            versions: raw.versions,
            observed_through: raw
                .observed_through
                .map(|value| parse_utc_rfc3339(&value))
                .transpose()
                .map_err(D::Error::custom)?,
        };
        if !segment.has_valid_wire_shape() {
            return Err(D::Error::custom(CoverageError::InvalidSerializedSegment));
        }
        Ok(segment)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoverageDiagnosticKind {
    LegacyBoundary,
    MissingCoverage,
    CorruptInterval,
    Overlap,
    UnknownVersion,
    UsageQueryIncomplete,
    UsageRangeMissing,
    UsageRangeMismatch,
}

/// Closed diagnostic with validated serde input. It contains no arbitrary text.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoverageDiagnostic {
    kind: CoverageDiagnosticKind,
    range: Option<UtcRange>,
    versions: Option<ContractVersions>,
}

impl CoverageDiagnostic {
    fn new(
        kind: CoverageDiagnosticKind,
        range: Option<UtcRange>,
        versions: Option<ContractVersions>,
    ) -> Self {
        Self {
            kind,
            range,
            versions,
        }
    }

    pub const fn kind(&self) -> CoverageDiagnosticKind {
        self.kind
    }

    pub const fn range(&self) -> Option<UtcRange> {
        self.range
    }

    pub const fn versions(&self) -> Option<ContractVersions> {
        self.versions
    }

    fn has_valid_wire_shape(&self) -> bool {
        if self.range.is_none() {
            return false;
        }
        match self.kind {
            CoverageDiagnosticKind::UnknownVersion => self.versions.is_some(),
            CoverageDiagnosticKind::LegacyBoundary
            | CoverageDiagnosticKind::MissingCoverage
            | CoverageDiagnosticKind::UsageQueryIncomplete
            | CoverageDiagnosticKind::UsageRangeMissing
            | CoverageDiagnosticKind::UsageRangeMismatch => self.versions.is_none(),
            CoverageDiagnosticKind::CorruptInterval | CoverageDiagnosticKind::Overlap => true,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCoverageDiagnostic {
    kind: CoverageDiagnosticKind,
    range: Option<UtcRange>,
    versions: Option<ContractVersions>,
}

impl<'de> Deserialize<'de> for CoverageDiagnostic {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawCoverageDiagnostic::deserialize(deserializer)?;
        let diagnostic = Self {
            kind: raw.kind,
            range: raw.range,
            versions: raw.versions,
        };
        if !diagnostic.has_valid_wire_shape() {
            return Err(D::Error::custom(CoverageError::InvalidSerializedDiagnostic));
        }
        Ok(diagnostic)
    }
}

/// Usage-query input carries the exact UTC range it represents. A missing or
/// mismatched range can never confirm presence or absence of activity.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(tag = "completeness", rename_all = "snake_case")]
pub enum UsageObservation {
    Complete { range: UtcRange, event_count: u64 },
    Incomplete { range: Option<UtcRange> },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityAssertion {
    ObservedActivity,
    ConfirmedNoActivity,
    NotAssertable,
}

/// Aggregate query evidence with deterministic ordering and validated serde
/// input for the later typed bridge boundary.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoverageEvidence {
    requested: UtcRange,
    segments: Vec<CoverageSegment>,
    overall: OverallCompleteness,
    versions: Vec<ContractVersions>,
    diagnostics: Vec<CoverageDiagnostic>,
    activity: ActivityAssertion,
}

impl CoverageEvidence {
    pub fn evaluate(
        requested: UtcRange,
        segments: Vec<CoverageSegment>,
        usage: UsageObservation,
        supported: &SupportedVersionPolicy,
    ) -> Result<Self, CoverageError> {
        if segments
            .iter()
            .any(|segment| !requested.contains_range(&segment.range))
        {
            return Err(CoverageError::SegmentOutsideRequest);
        }
        let had_source_segments = !segments.is_empty();
        let mut boundaries = BTreeSet::from([requested.started_at(), requested.ended_at()]);
        for segment in &segments {
            boundaries.insert(segment.range.started_at());
            boundaries.insert(segment.range.ended_at());
            if let Some(observed_through) = segment.observed_through
                && segment.range.contains_instant(observed_through)
            {
                boundaries.insert(observed_through);
            }
        }
        let boundaries = boundaries.into_iter().collect::<Vec<_>>();
        let mut ordered = Vec::with_capacity(boundaries.len().saturating_sub(1));
        let mut diagnostics = Vec::new();
        for pair in boundaries.windows(2) {
            let range = UtcRange::new(pair[0], pair[1])?;
            let covering = segments
                .iter()
                .filter(|segment| segment.range.contains_range(&range))
                .collect::<Vec<_>>();
            let normalized = match covering.as_slice() {
                [] => CoverageSegment::missing(range),
                [segment] => segment.slice_for_query(range, supported),
                _ => {
                    let versions = covering
                        .iter()
                        .filter_map(|segment| segment.versions)
                        .collect::<BTreeSet<_>>();
                    for versions in &versions {
                        if supported.validate(*versions).is_none() {
                            diagnostics.push(CoverageDiagnostic::new(
                                CoverageDiagnosticKind::UnknownVersion,
                                Some(range),
                                Some(*versions),
                            ));
                        }
                    }
                    let shared_versions = (versions.len() == 1)
                        .then(|| versions.iter().next().copied())
                        .flatten();
                    CoverageSegment::overlap(range, shared_versions)
                }
            };
            if normalized.state == SynthesizedCoverageState::Missing {
                diagnostics.push(CoverageDiagnostic::new(
                    CoverageDiagnosticKind::MissingCoverage,
                    Some(range),
                    None,
                ));
            } else {
                push_segment_diagnostic(&mut diagnostics, &normalized);
            }
            ordered.push(normalized);
        }

        let usage_range_matches = match usage {
            UsageObservation::Complete { range, .. } if range == requested => true,
            UsageObservation::Complete { .. } => {
                diagnostics.push(CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UsageRangeMismatch,
                    Some(requested),
                    None,
                ));
                false
            }
            UsageObservation::Incomplete { range: None } => {
                diagnostics.push(CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UsageRangeMissing,
                    Some(requested),
                    None,
                ));
                false
            }
            UsageObservation::Incomplete { range: Some(range) } => {
                if range != requested {
                    diagnostics.push(CoverageDiagnostic::new(
                        CoverageDiagnosticKind::UsageRangeMismatch,
                        Some(requested),
                        None,
                    ));
                }
                false
            }
        };
        if matches!(usage, UsageObservation::Incomplete { .. }) {
            diagnostics.push(CoverageDiagnostic::new(
                CoverageDiagnosticKind::UsageQueryIncomplete,
                Some(requested),
                None,
            ));
        }

        let versions = segments
            .iter()
            .filter_map(CoverageSegment::versions)
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();

        let has_unknown = ordered.iter().any(|segment| {
            matches!(
                segment.state,
                SynthesizedCoverageState::Corrupt
                    | SynthesizedCoverageState::Overlap
                    | SynthesizedCoverageState::UnknownVersion
            )
        });
        let has_partial = ordered.iter().any(|segment| {
            segment.completeness == Completeness::Partial
                || matches!(
                    segment.state,
                    SynthesizedCoverageState::LegacyUnknown | SynthesizedCoverageState::Missing
                )
        }) || !usage_range_matches;
        let overall = if !had_source_segments || has_unknown {
            OverallCompleteness::Unknown
        } else if has_partial {
            OverallCompleteness::Partial
        } else {
            OverallCompleteness::Complete
        };

        let exact_trusted_active_cover = !ordered.is_empty()
            && ordered
                .first()
                .map(CoverageSegment::range)
                .map(|range| range.started_at())
                == Some(requested.started_at())
            && ordered
                .last()
                .map(CoverageSegment::range)
                .map(|range| range.ended_at())
                == Some(requested.ended_at())
            && ordered
                .windows(2)
                .all(|pair| pair[0].range.ended_at() == pair[1].range.started_at())
            && ordered
                .iter()
                .all(|segment| segment.is_trusted_complete_active(supported))
            && diagnostics.is_empty();

        let activity = match usage {
            UsageObservation::Complete { event_count: 0, .. }
                if usage_range_matches && exact_trusted_active_cover =>
            {
                ActivityAssertion::ConfirmedNoActivity
            }
            UsageObservation::Complete { event_count, .. }
                if usage_range_matches && event_count > 0 =>
            {
                ActivityAssertion::ObservedActivity
            }
            UsageObservation::Complete { .. } | UsageObservation::Incomplete { .. } => {
                ActivityAssertion::NotAssertable
            }
        };

        Ok(Self {
            requested,
            segments: ordered,
            overall,
            versions,
            diagnostics,
            activity,
        })
    }

    pub const fn requested(&self) -> UtcRange {
        self.requested
    }

    pub fn segments(&self) -> &[CoverageSegment] {
        &self.segments
    }

    pub const fn overall(&self) -> OverallCompleteness {
        self.overall
    }

    pub fn versions(&self) -> &[ContractVersions] {
        &self.versions
    }

    pub fn diagnostics(&self) -> &[CoverageDiagnostic] {
        &self.diagnostics
    }

    pub const fn activity(&self) -> ActivityAssertion {
        self.activity
    }

    fn has_valid_wire_shape(&self) -> bool {
        if self.segments.is_empty()
            || self.segments[0].range.started_at() != self.requested.started_at()
            || self.segments.last().unwrap().range.ended_at() != self.requested.ended_at()
            || self.segments.iter().any(|segment| {
                !segment.has_valid_wire_shape() || !self.requested.contains_range(&segment.range)
            })
            || !self
                .segments
                .windows(2)
                .all(|pair| pair[0].range.ended_at() == pair[1].range.started_at())
            || !self.versions.windows(2).all(|pair| pair[0] < pair[1])
        {
            return false;
        }

        let listed_versions = self.versions.iter().copied().collect::<BTreeSet<_>>();
        if self
            .segments
            .iter()
            .filter_map(CoverageSegment::versions)
            .chain(
                self.diagnostics
                    .iter()
                    .filter_map(CoverageDiagnostic::versions),
            )
            .any(|versions| !listed_versions.contains(&versions))
        {
            return false;
        }

        for diagnostic in &self.diagnostics {
            if !diagnostic.has_valid_wire_shape()
                || diagnostic
                    .range
                    .is_some_and(|range| !self.requested.contains_range(&range))
            {
                return false;
            }
            let matching_segment = |state, range| {
                self.segments
                    .iter()
                    .any(|segment| segment.state == state && segment.range == range)
            };
            let range = diagnostic.range.unwrap();
            let matches_partition = match diagnostic.kind {
                CoverageDiagnosticKind::LegacyBoundary => {
                    matching_segment(SynthesizedCoverageState::LegacyUnknown, range)
                }
                CoverageDiagnosticKind::MissingCoverage => {
                    matching_segment(SynthesizedCoverageState::Missing, range)
                }
                CoverageDiagnosticKind::CorruptInterval => {
                    matching_segment(SynthesizedCoverageState::Corrupt, range)
                }
                CoverageDiagnosticKind::Overlap => {
                    matching_segment(SynthesizedCoverageState::Overlap, range)
                }
                CoverageDiagnosticKind::UnknownVersion => self.segments.iter().any(|segment| {
                    segment.range == range
                        && ((segment.state == SynthesizedCoverageState::UnknownVersion
                            && segment.versions == diagnostic.versions)
                            || segment.state == SynthesizedCoverageState::Overlap)
                }),
                CoverageDiagnosticKind::UsageQueryIncomplete
                | CoverageDiagnosticKind::UsageRangeMissing
                | CoverageDiagnosticKind::UsageRangeMismatch => range == self.requested,
            };
            if !matches_partition {
                return false;
            }
        }

        let has_unknown = self.segments.iter().any(|segment| {
            matches!(
                segment.state,
                SynthesizedCoverageState::Corrupt
                    | SynthesizedCoverageState::Overlap
                    | SynthesizedCoverageState::UnknownVersion
            )
        }) || self
            .segments
            .iter()
            .all(|segment| segment.state == SynthesizedCoverageState::Missing);
        let has_partial = self.segments.iter().any(|segment| {
            segment.completeness == Completeness::Partial
                || matches!(
                    segment.state,
                    SynthesizedCoverageState::LegacyUnknown | SynthesizedCoverageState::Missing
                )
        }) || self.diagnostics.iter().any(|diagnostic| {
            matches!(
                diagnostic.kind,
                CoverageDiagnosticKind::UsageQueryIncomplete
                    | CoverageDiagnosticKind::UsageRangeMissing
                    | CoverageDiagnosticKind::UsageRangeMismatch
            )
        });
        let expected_overall = if has_unknown {
            OverallCompleteness::Unknown
        } else if has_partial {
            OverallCompleteness::Partial
        } else {
            OverallCompleteness::Complete
        };
        if self.overall != expected_overall {
            return false;
        }

        match self.activity {
            ActivityAssertion::ConfirmedNoActivity => {
                self.overall == OverallCompleteness::Complete
                    && self.diagnostics.is_empty()
                    && self.segments.iter().all(|segment| {
                        segment.state == SynthesizedCoverageState::Persisted(CoverageState::Active)
                            && segment.completeness == Completeness::Complete
                            && segment.versions.is_some()
                            && segment
                                .observed_through
                                .is_some_and(|observed| observed >= segment.range.ended_at())
                    })
            }
            ActivityAssertion::ObservedActivity | ActivityAssertion::NotAssertable => true,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCoverageEvidence {
    requested: UtcRange,
    segments: Vec<CoverageSegment>,
    overall: OverallCompleteness,
    versions: Vec<ContractVersions>,
    diagnostics: Vec<CoverageDiagnostic>,
    activity: ActivityAssertion,
}

impl<'de> Deserialize<'de> for CoverageEvidence {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawCoverageEvidence::deserialize(deserializer)?;
        let evidence = Self {
            requested: raw.requested,
            segments: raw.segments,
            overall: raw.overall,
            versions: raw.versions,
            diagnostics: raw.diagnostics,
            activity: raw.activity,
        };
        if !evidence.has_valid_wire_shape() {
            return Err(D::Error::custom(CoverageError::InvalidSerializedEvidence));
        }
        Ok(evidence)
    }
}

fn push_segment_diagnostic(diagnostics: &mut Vec<CoverageDiagnostic>, segment: &CoverageSegment) {
    let kind = match segment.state {
        SynthesizedCoverageState::Persisted(_) | SynthesizedCoverageState::Missing => return,
        SynthesizedCoverageState::LegacyUnknown => CoverageDiagnosticKind::LegacyBoundary,
        SynthesizedCoverageState::Corrupt => CoverageDiagnosticKind::CorruptInterval,
        SynthesizedCoverageState::Overlap => CoverageDiagnosticKind::Overlap,
        SynthesizedCoverageState::UnknownVersion => CoverageDiagnosticKind::UnknownVersion,
    };
    diagnostics.push(CoverageDiagnostic::new(
        kind,
        Some(segment.range),
        segment.versions,
    ));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::time::parse_utc_rfc3339;

    fn utc(value: &str) -> DateTime<Utc> {
        parse_utc_rfc3339(value).expect("fixed UTC timestamp")
    }

    fn range(started_at: &str, ended_at: &str) -> UtcRange {
        UtcRange::parse(started_at, ended_at).expect("fixed UTC range")
    }

    fn versions() -> ContractVersions {
        ContractVersions::new(1, 1).unwrap()
    }

    fn supported() -> SupportedVersionPolicy {
        SupportedVersionPolicy::exact(versions())
    }

    fn complete_usage(range: UtcRange, event_count: u64) -> UsageObservation {
        UsageObservation::Complete { range, event_count }
    }

    fn evaluate(
        requested: UtcRange,
        segments: Vec<CoverageSegment>,
        usage: UsageObservation,
    ) -> CoverageEvidence {
        CoverageEvidence::evaluate(requested, segments, usage, &supported()).unwrap()
    }

    fn closed_interval(
        state: CoverageState,
        coverage: UtcRange,
        reason: CoverageReason,
        completeness: Completeness,
    ) -> CoverageInterval {
        let observed = if completeness == Completeness::Complete {
            coverage.ended_at()
        } else {
            coverage.started_at()
        };
        CoverageInterval::closed(
            state,
            coverage,
            reason,
            completeness,
            versions(),
            observed,
            1,
        )
        .unwrap()
    }

    #[test]
    fn persisted_and_synthesized_states_are_disjoint() {
        let persisted = serde_json::to_value([
            CoverageState::Active,
            CoverageState::Paused,
            CoverageState::PrivacyExcluded,
            CoverageState::Idle,
            CoverageState::SystemGap,
        ])
        .unwrap();
        assert_eq!(
            persisted,
            serde_json::json!(["active", "paused", "privacy_excluded", "idle", "system_gap"])
        );
        assert!(serde_json::from_str::<CoverageState>("\"legacy_unknown\"").is_err());
        assert!(serde_json::from_str::<CoverageState>("\"missing\"").is_err());
    }

    #[test]
    fn interval_validation_enforces_time_reason_version_and_revision() {
        let coverage = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        assert!(matches!(
            CoverageInterval::closed(
                CoverageState::PrivacyExcluded,
                coverage,
                CoverageReason::NormalObservation,
                Completeness::Complete,
                versions(),
                coverage.ended_at(),
                1,
            ),
            Err(CoverageError::InvalidReason { .. })
        ));
        assert_eq!(
            CoverageInterval::closed(
                CoverageState::Active,
                coverage,
                CoverageReason::NormalObservation,
                Completeness::Complete,
                versions(),
                coverage.started_at(),
                1,
            )
            .unwrap_err(),
            CoverageError::IncompleteObservationForCompleteInterval
        );
        assert_eq!(
            CoverageInterval::open(
                CoverageState::Paused,
                coverage.started_at(),
                CoverageReason::UserPaused,
                Completeness::Complete,
                versions(),
                coverage.started_at() - chrono::Duration::seconds(1),
                1,
            )
            .unwrap_err(),
            CoverageError::ObservationBeforeStart
        );
        assert_eq!(
            CoverageInterval::open(
                CoverageState::Paused,
                coverage.started_at(),
                CoverageReason::UserPaused,
                Completeness::Complete,
                versions(),
                coverage.started_at(),
                0,
            )
            .unwrap_err(),
            CoverageError::ZeroRevision
        );
        assert_eq!(
            ContractVersions::new(0, 1).unwrap_err(),
            CoverageError::ZeroVersion
        );
    }

    #[test]
    fn privacy_excluded_serialization_has_only_non_sensitive_contract_fields() {
        let coverage = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let interval = closed_interval(
            CoverageState::PrivacyExcluded,
            coverage,
            CoverageReason::PrivacyPolicy,
            Completeness::Complete,
        );
        let serialized = serde_json::to_string(&interval).unwrap();
        for forbidden in [
            "app_name",
            "app_path",
            "window_title",
            "diary",
            "excluded_apps",
            "credential",
        ] {
            assert!(!serialized.contains(forbidden));
        }
        assert!(serialized.contains("privacy_excluded"));
        assert!(serialized.contains("privacy_policy"));
    }

    #[test]
    fn confirmed_no_activity_requires_exact_complete_active_coverage() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T02:00:00Z");
        let first_range = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let second_range = range("2024-01-01T01:00:00Z", "2024-01-01T02:00:00Z");
        let first = closed_interval(
            CoverageState::Active,
            first_range,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        let second = closed_interval(
            CoverageState::Active,
            second_range,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        let evidence = evaluate(
            requested,
            vec![
                CoverageSegment::persisted(first_range, &first).unwrap(),
                CoverageSegment::persisted(second_range, &second).unwrap(),
            ],
            complete_usage(requested, 0),
        );
        assert_eq!(evidence.overall(), OverallCompleteness::Complete);
        assert_eq!(evidence.activity(), ActivityAssertion::ConfirmedNoActivity);
        assert!(evidence.diagnostics().is_empty());
    }

    #[test]
    fn every_non_active_or_untrusted_intersection_blocks_confirmation() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let persisted_cases = [
            (
                CoverageState::Paused,
                CoverageReason::UserPaused,
                Completeness::Complete,
            ),
            (
                CoverageState::PrivacyExcluded,
                CoverageReason::PrivacyPolicy,
                Completeness::Complete,
            ),
            (
                CoverageState::Idle,
                CoverageReason::IdleThreshold,
                Completeness::Complete,
            ),
            (
                CoverageState::SystemGap,
                CoverageReason::SleepOrFreeze,
                Completeness::Partial,
            ),
            (
                CoverageState::Active,
                CoverageReason::NormalObservation,
                Completeness::Partial,
            ),
        ];
        for (state, reason, completeness) in persisted_cases {
            let interval = closed_interval(state, requested, reason, completeness);
            let evidence = evaluate(
                requested,
                vec![CoverageSegment::persisted(requested, &interval).unwrap()],
                complete_usage(requested, 0),
            );
            assert_eq!(evidence.activity(), ActivityAssertion::NotAssertable);
        }

        let synthesized_cases = [
            CoverageSegment::legacy_unknown(requested),
            CoverageSegment::missing(requested),
            CoverageSegment::corrupt(requested, Some(versions())),
            CoverageSegment::overlap(requested, Some(versions())),
            CoverageSegment::unknown_version(requested, ContractVersions::new(99, 99).unwrap()),
        ];
        for segment in synthesized_cases {
            let evidence = evaluate(requested, vec![segment], complete_usage(requested, 0));
            assert_eq!(evidence.activity(), ActivityAssertion::NotAssertable);
        }
    }

    #[test]
    fn gaps_empty_segments_and_incomplete_usage_never_confirm_absence() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T02:00:00Z");
        let active_range = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let active = closed_interval(
            CoverageState::Active,
            active_range,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        let with_gap = evaluate(
            requested,
            vec![CoverageSegment::persisted(active_range, &active).unwrap()],
            complete_usage(requested, 0),
        );
        assert_eq!(with_gap.activity(), ActivityAssertion::NotAssertable);
        assert_eq!(with_gap.overall(), OverallCompleteness::Partial);
        assert!(matches!(
            with_gap.segments().last().map(CoverageSegment::state),
            Some(SynthesizedCoverageState::Missing)
        ));

        let empty = evaluate(requested, Vec::new(), complete_usage(requested, 0));
        assert_eq!(empty.activity(), ActivityAssertion::NotAssertable);
        assert_eq!(empty.overall(), OverallCompleteness::Unknown);

        let incomplete_usage = evaluate(
            active_range,
            vec![CoverageSegment::persisted(active_range, &active).unwrap()],
            UsageObservation::Incomplete {
                range: Some(active_range),
            },
        );
        assert_eq!(
            incomplete_usage.activity(),
            ActivityAssertion::NotAssertable
        );
        assert!(incomplete_usage
            .diagnostics()
            .iter()
            .any(|diagnostic| diagnostic.kind() == CoverageDiagnosticKind::UsageQueryIncomplete));
    }

    #[test]
    fn positive_usage_is_observed_even_when_coverage_is_partial() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let evidence = evaluate(
            requested,
            vec![CoverageSegment::legacy_unknown(requested)],
            complete_usage(requested, 1),
        );
        assert_eq!(evidence.activity(), ActivityAssertion::ObservedActivity);
    }

    #[test]
    fn unsupported_complete_version_pairs_are_unknown_and_not_assertable() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        for unsupported in [
            ContractVersions::new(2, 1).unwrap(),
            ContractVersions::new(1, 2).unwrap(),
            ContractVersions::new(2, 2).unwrap(),
        ] {
            let interval = CoverageInterval::closed(
                CoverageState::Active,
                requested,
                CoverageReason::NormalObservation,
                Completeness::Complete,
                unsupported,
                requested.ended_at(),
                1,
            )
            .unwrap();
            let evidence = CoverageEvidence::evaluate(
                requested,
                vec![CoverageSegment::persisted(requested, &interval).unwrap()],
                complete_usage(requested, 0),
                &supported(),
            )
            .unwrap();

            assert_eq!(evidence.overall(), OverallCompleteness::Unknown);
            assert_eq!(evidence.activity(), ActivityAssertion::NotAssertable);
            assert_eq!(
                evidence.segments()[0].state(),
                SynthesizedCoverageState::UnknownVersion
            );
            assert!(evidence.diagnostics().iter().any(|diagnostic| {
                diagnostic.kind() == CoverageDiagnosticKind::UnknownVersion
                    && diagnostic.range() == Some(requested)
                    && diagnostic.versions() == Some(unsupported)
            }));
        }
        assert_eq!(
            SupportedVersionPolicy::from_pairs([]).unwrap_err(),
            CoverageError::EmptySupportedVersionPolicy
        );
        assert_eq!(
            supported()
                .validate(versions())
                .map(KnownContractVersions::get),
            Some(versions())
        );
    }

    #[test]
    fn usage_must_be_complete_for_the_exact_requested_range() {
        let requested = range("2024-01-01T01:00:00Z", "2024-01-01T03:00:00Z");
        let interval = closed_interval(
            CoverageState::Active,
            requested,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        let source = || vec![CoverageSegment::persisted(requested, &interval).unwrap()];

        assert_eq!(
            evaluate(requested, source(), complete_usage(requested, 0)).activity(),
            ActivityAssertion::ConfirmedNoActivity
        );
        let mismatches = [
            range("2024-01-01T01:30:00Z", "2024-01-01T02:30:00Z"),
            range("2024-01-01T00:00:00Z", "2024-01-01T04:00:00Z"),
            range("2024-01-01T02:00:00Z", "2024-01-01T04:00:00Z"),
        ];
        for usage_range in mismatches {
            let evidence = evaluate(requested, source(), complete_usage(usage_range, 0));
            assert_eq!(evidence.activity(), ActivityAssertion::NotAssertable);
            assert!(evidence.diagnostics().iter().any(|diagnostic| {
                diagnostic.kind() == CoverageDiagnosticKind::UsageRangeMismatch
            }));
        }

        let mismatched_positive = evaluate(requested, source(), complete_usage(mismatches[0], 1));
        assert_eq!(
            mismatched_positive.activity(),
            ActivityAssertion::NotAssertable
        );

        let missing = evaluate(
            requested,
            source(),
            UsageObservation::Incomplete { range: None },
        );
        assert_eq!(missing.activity(), ActivityAssertion::NotAssertable);
        assert!(
            missing.diagnostics().iter().any(|diagnostic| {
                diagnostic.kind() == CoverageDiagnosticKind::UsageRangeMissing
            })
        );
    }

    #[test]
    fn privacy_persistence_rejects_each_unknown_sensitive_field_and_round_trips() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let interval = closed_interval(
            CoverageState::PrivacyExcluded,
            requested,
            CoverageReason::PrivacyPolicy,
            Completeness::Complete,
        );
        let clean = serde_json::to_value(&interval).unwrap();
        assert_eq!(
            serde_json::from_value::<CoverageInterval>(clean.clone()).unwrap(),
            interval
        );

        for forbidden in [
            "app_name",
            "window_title",
            "path",
            "diary",
            "excluded_value",
            "credential",
        ] {
            let mut augmented = clean.clone();
            augmented
                .as_object_mut()
                .unwrap()
                .insert(forbidden.to_owned(), serde_json::json!("private"));
            assert!(
                serde_json::from_value::<CoverageInterval>(augmented).is_err(),
                "field {forbidden} must be rejected"
            );
        }
    }

    fn assert_partition(evidence: &CoverageEvidence, requested: UtcRange) {
        let segments = evidence.segments();
        assert!(!segments.is_empty());
        assert_eq!(segments[0].range().started_at(), requested.started_at());
        assert_eq!(
            segments.last().unwrap().range().ended_at(),
            requested.ended_at()
        );
        assert!(segments.windows(2).all(|pair| {
            pair[0].range().ended_at() == pair[1].range().started_at()
                && !pair[0].range().overlaps(&pair[1].range())
        }));
    }

    fn active_segment(coverage: UtcRange) -> CoverageSegment {
        let interval = closed_interval(
            CoverageState::Active,
            coverage,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        CoverageSegment::persisted(coverage, &interval).unwrap()
    }

    #[test]
    fn boundary_sweep_normalizes_every_overlap_shape() {
        let r0_1 = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let r0_2 = range("2024-01-01T00:00:00Z", "2024-01-01T02:00:00Z");
        let r0_3 = range("2024-01-01T00:00:00Z", "2024-01-01T03:00:00Z");
        let r0_4 = range("2024-01-01T00:00:00Z", "2024-01-01T04:00:00Z");
        let r1_2 = range("2024-01-01T01:00:00Z", "2024-01-01T02:00:00Z");
        let r1_3 = range("2024-01-01T01:00:00Z", "2024-01-01T03:00:00Z");
        let r1_4 = range("2024-01-01T01:00:00Z", "2024-01-01T04:00:00Z");
        let r2_3 = range("2024-01-01T02:00:00Z", "2024-01-01T03:00:00Z");
        let r2_4 = range("2024-01-01T02:00:00Z", "2024-01-01T04:00:00Z");

        let cases = [
            (r0_3, vec![active_segment(r0_2), active_segment(r1_3)], 1),
            (r0_4, vec![active_segment(r0_4), active_segment(r1_3)], 1),
            (r0_2, vec![active_segment(r0_2), active_segment(r0_2)], 1),
            (
                r0_4,
                vec![
                    active_segment(r0_4),
                    active_segment(r1_3),
                    active_segment(r2_4),
                ],
                3,
            ),
        ];
        for (requested, sources, overlap_count) in cases {
            let evidence = evaluate(requested, sources, complete_usage(requested, 0));
            assert_partition(&evidence, requested);
            assert_eq!(
                evidence
                    .segments()
                    .iter()
                    .filter(|segment| segment.state() == SynthesizedCoverageState::Overlap)
                    .count(),
                overlap_count
            );
            assert_eq!(
                evidence
                    .diagnostics()
                    .iter()
                    .filter(|diagnostic| diagnostic.kind() == CoverageDiagnosticKind::Overlap)
                    .count(),
                overlap_count
            );
            assert_eq!(evidence.activity(), ActivityAssertion::NotAssertable);
        }

        let adjacent = evaluate(
            r0_2,
            vec![active_segment(r0_1), active_segment(r1_2)],
            complete_usage(r0_2, 0),
        );
        assert_partition(&adjacent, r0_2);
        assert!(
            adjacent
                .segments()
                .iter()
                .all(|segment| segment.state() != SynthesizedCoverageState::Overlap)
        );
        assert_eq!(adjacent.activity(), ActivityAssertion::ConfirmedNoActivity);

        let three_way_center = evaluate(
            r0_4,
            vec![
                active_segment(r0_4),
                active_segment(r1_4),
                active_segment(r2_3),
            ],
            complete_usage(r0_4, 0),
        );
        assert_eq!(
            three_way_center
                .segments()
                .iter()
                .filter(|segment| segment.state() == SynthesizedCoverageState::Overlap)
                .count(),
            3
        );
    }

    #[test]
    fn boundary_sweep_handles_extreme_datetime_endpoints_without_arithmetic() {
        let split = utc("1970-01-01T00:00:00Z");
        let requested = UtcRange::new(DateTime::<Utc>::MIN_UTC, DateTime::<Utc>::MAX_UTC).unwrap();
        let left = UtcRange::new(DateTime::<Utc>::MIN_UTC, split).unwrap();
        let right = UtcRange::new(split, DateTime::<Utc>::MAX_UTC).unwrap();
        let evidence = evaluate(
            requested,
            vec![active_segment(left), active_segment(right)],
            complete_usage(requested, 0),
        );
        assert_partition(&evidence, requested);
        assert_eq!(evidence.activity(), ActivityAssertion::ConfirmedNoActivity);
    }

    #[test]
    fn coverage_interval_and_segment_serde_reject_non_utc_observation_text() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        let interval = closed_interval(
            CoverageState::Active,
            requested,
            CoverageReason::NormalObservation,
            Completeness::Complete,
        );
        let mut non_utc_interval = serde_json::to_value(&interval).unwrap();
        non_utc_interval["observed_through"] = serde_json::json!("2024-01-01T09:00:00+08:00");
        assert!(serde_json::from_value::<CoverageInterval>(non_utc_interval).is_err());

        let mut zero_offset_interval = serde_json::to_value(&interval).unwrap();
        zero_offset_interval["observed_through"] = serde_json::json!("2024-01-01T01:00:00+00:00");
        assert_eq!(
            serde_json::from_value::<CoverageInterval>(zero_offset_interval).unwrap(),
            interval
        );

        let segment = CoverageSegment::persisted(requested, &interval).unwrap();
        let mut non_utc_segment = serde_json::to_value(&segment).unwrap();
        non_utc_segment["observed_through"] = serde_json::json!("2024-01-01T09:00:00+08:00");
        assert!(serde_json::from_value::<CoverageSegment>(non_utc_segment).is_err());
    }

    fn open_active_segment(
        started_at: DateTime<Utc>,
        observed_through: DateTime<Utc>,
        requested: UtcRange,
    ) -> CoverageSegment {
        let interval = CoverageInterval::open(
            CoverageState::Active,
            started_at,
            CoverageReason::NormalObservation,
            Completeness::Complete,
            versions(),
            observed_through,
            1,
        )
        .unwrap();
        CoverageSegment::persisted(requested, &interval).unwrap()
    }

    #[test]
    fn open_complete_interval_is_bounded_split_and_downgraded_at_observed_through() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T02:00:00Z");
        let query_end_observed = evaluate(
            requested,
            vec![open_active_segment(
                requested.started_at(),
                requested.ended_at(),
                requested,
            )],
            complete_usage(requested, 0),
        );
        assert_eq!(query_end_observed.overall(), OverallCompleteness::Complete);
        assert_eq!(
            query_end_observed.activity(),
            ActivityAssertion::ConfirmedNoActivity
        );

        let observed = utc("2024-01-01T01:00:00Z");
        let split = evaluate(
            requested,
            vec![open_active_segment(
                requested.started_at(),
                observed,
                requested,
            )],
            complete_usage(requested, 0),
        );
        assert_partition(&split, requested);
        assert_eq!(split.segments().len(), 2);
        assert_eq!(split.segments()[0].range().ended_at(), observed);
        assert_eq!(split.segments()[0].completeness(), Completeness::Complete);
        assert_eq!(split.segments()[1].range().started_at(), observed);
        assert_eq!(split.segments()[1].completeness(), Completeness::Partial);
        assert_eq!(split.overall(), OverallCompleteness::Partial);
        assert_eq!(split.activity(), ActivityAssertion::NotAssertable);

        let after_observation = range("2024-01-01T01:30:00Z", "2024-01-01T02:00:00Z");
        let wholly_unobserved = evaluate(
            after_observation,
            vec![open_active_segment(
                requested.started_at(),
                observed,
                after_observation,
            )],
            complete_usage(after_observation, 0),
        );
        assert_eq!(
            wholly_unobserved.segments()[0].completeness(),
            Completeness::Partial
        );
        assert_eq!(wholly_unobserved.overall(), OverallCompleteness::Partial);
    }

    #[test]
    fn open_observation_normalization_handles_min_and_max_without_arithmetic() {
        let requested = UtcRange::new(DateTime::<Utc>::MIN_UTC, DateTime::<Utc>::MAX_UTC).unwrap();
        let through_max = evaluate(
            requested,
            vec![open_active_segment(
                DateTime::<Utc>::MIN_UTC,
                DateTime::<Utc>::MAX_UTC,
                requested,
            )],
            complete_usage(requested, 0),
        );
        assert_eq!(through_max.overall(), OverallCompleteness::Complete);
        assert_eq!(
            through_max.activity(),
            ActivityAssertion::ConfirmedNoActivity
        );

        let only_min_observed = evaluate(
            requested,
            vec![open_active_segment(
                DateTime::<Utc>::MIN_UTC,
                DateTime::<Utc>::MIN_UTC,
                requested,
            )],
            complete_usage(requested, 0),
        );
        assert_eq!(only_min_observed.overall(), OverallCompleteness::Partial);
        assert_eq!(
            only_min_observed.segments()[0].completeness(),
            Completeness::Partial
        );
        assert_eq!(
            only_min_observed.activity(),
            ActivityAssertion::NotAssertable
        );
    }

    #[test]
    fn query_wire_enums_and_partition_serialization_are_canonical() {
        assert_eq!(
            serde_json::to_string(&[
                SynthesizedCoverageState::Persisted(CoverageState::Active),
                SynthesizedCoverageState::LegacyUnknown,
                SynthesizedCoverageState::Missing,
                SynthesizedCoverageState::Corrupt,
                SynthesizedCoverageState::Overlap,
                SynthesizedCoverageState::UnknownVersion,
            ])
            .unwrap(),
            r#"[{"kind":"persisted","state":"active"},{"kind":"legacy_unknown"},{"kind":"missing"},{"kind":"corrupt"},{"kind":"overlap"},{"kind":"unknown_version"}]"#
        );
        assert_eq!(
            serde_json::to_string(&[
                CoverageDiagnosticKind::LegacyBoundary,
                CoverageDiagnosticKind::MissingCoverage,
                CoverageDiagnosticKind::CorruptInterval,
                CoverageDiagnosticKind::Overlap,
                CoverageDiagnosticKind::UnknownVersion,
                CoverageDiagnosticKind::UsageQueryIncomplete,
                CoverageDiagnosticKind::UsageRangeMissing,
                CoverageDiagnosticKind::UsageRangeMismatch,
            ])
            .unwrap(),
            r#"["legacy_boundary","missing_coverage","corrupt_interval","overlap","unknown_version","usage_query_incomplete","usage_range_missing","usage_range_mismatch"]"#
        );
        assert_eq!(
            serde_json::to_string(&[
                ActivityAssertion::ObservedActivity,
                ActivityAssertion::ConfirmedNoActivity,
                ActivityAssertion::NotAssertable,
            ])
            .unwrap(),
            r#"["observed_activity","confirmed_no_activity","not_assertable"]"#
        );

        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T03:00:00Z");
        let left = range("2024-01-01T00:00:00Z", "2024-01-01T02:00:00Z");
        let right = range("2024-01-01T01:00:00Z", "2024-01-01T03:00:00Z");
        let forward = evaluate(
            requested,
            vec![active_segment(left), active_segment(right)],
            complete_usage(requested, 0),
        );
        let reverse = evaluate(
            requested,
            vec![active_segment(right), active_segment(left)],
            complete_usage(requested, 0),
        );
        assert_eq!(
            serde_json::to_string(&forward).unwrap(),
            serde_json::to_string(&reverse).unwrap()
        );
        assert_eq!(forward.versions(), &[versions()]);
    }

    fn comprehensive_wire_evidence() -> CoverageEvidence {
        let ranges = [
            range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z"),
            range("2024-01-01T01:00:00Z", "2024-01-01T02:00:00Z"),
            range("2024-01-01T02:00:00Z", "2024-01-01T03:00:00Z"),
            range("2024-01-01T03:00:00Z", "2024-01-01T04:00:00Z"),
            range("2024-01-01T04:00:00Z", "2024-01-01T05:00:00Z"),
            range("2024-01-01T05:00:00Z", "2024-01-01T06:00:00Z"),
        ];
        let unsupported = ContractVersions::new(99, 99).unwrap();
        CoverageEvidence {
            requested: range("2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z"),
            segments: vec![
                active_segment(ranges[0]),
                CoverageSegment::legacy_unknown(ranges[1]),
                CoverageSegment::missing(ranges[2]),
                CoverageSegment::corrupt(ranges[3], Some(versions())),
                CoverageSegment::overlap(ranges[4], Some(versions())),
                CoverageSegment::unknown_version(ranges[5], unsupported),
            ],
            overall: OverallCompleteness::Unknown,
            versions: vec![versions(), unsupported],
            diagnostics: vec![
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::LegacyBoundary,
                    Some(ranges[1]),
                    None,
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::MissingCoverage,
                    Some(ranges[2]),
                    None,
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::CorruptInterval,
                    Some(ranges[3]),
                    Some(versions()),
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::Overlap,
                    Some(ranges[4]),
                    Some(versions()),
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UnknownVersion,
                    Some(ranges[5]),
                    Some(unsupported),
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UsageQueryIncomplete,
                    Some(range("2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z")),
                    None,
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UsageRangeMissing,
                    Some(range("2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z")),
                    None,
                ),
                CoverageDiagnostic::new(
                    CoverageDiagnosticKind::UsageRangeMismatch,
                    Some(range("2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z")),
                    None,
                ),
            ],
            activity: ActivityAssertion::NotAssertable,
        }
    }

    #[test]
    fn full_query_wire_contract_is_deserialize_owned_validated_and_round_trips() {
        fn assert_serde_owned<T: Serialize + serde::de::DeserializeOwned>() {}
        assert_serde_owned::<CoverageEvidence>();
        assert_serde_owned::<CoverageSegment>();
        assert_serde_owned::<CoverageDiagnostic>();

        let evidence = comprehensive_wire_evidence();
        assert!(evidence.has_valid_wire_shape());
        let canonical = serde_json::to_string(&evidence).unwrap();
        const GOLDEN: &str = r#"{"requested":{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"segments":[{"range":{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T01:00:00Z"},"state":{"kind":"persisted","state":"active"},"completeness":"complete","versions":{"policy_version":1,"schema_version":1},"observed_through":"2024-01-01T01:00:00Z"},{"range":{"started_at":"2024-01-01T01:00:00Z","ended_at":"2024-01-01T02:00:00Z"},"state":{"kind":"legacy_unknown"},"completeness":"partial","versions":null,"observed_through":null},{"range":{"started_at":"2024-01-01T02:00:00Z","ended_at":"2024-01-01T03:00:00Z"},"state":{"kind":"missing"},"completeness":"partial","versions":null,"observed_through":null},{"range":{"started_at":"2024-01-01T03:00:00Z","ended_at":"2024-01-01T04:00:00Z"},"state":{"kind":"corrupt"},"completeness":"partial","versions":{"policy_version":1,"schema_version":1},"observed_through":null},{"range":{"started_at":"2024-01-01T04:00:00Z","ended_at":"2024-01-01T05:00:00Z"},"state":{"kind":"overlap"},"completeness":"partial","versions":{"policy_version":1,"schema_version":1},"observed_through":null},{"range":{"started_at":"2024-01-01T05:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"state":{"kind":"unknown_version"},"completeness":"partial","versions":{"policy_version":99,"schema_version":99},"observed_through":null}],"overall":"unknown","versions":[{"policy_version":1,"schema_version":1},{"policy_version":99,"schema_version":99}],"diagnostics":[{"kind":"legacy_boundary","range":{"started_at":"2024-01-01T01:00:00Z","ended_at":"2024-01-01T02:00:00Z"},"versions":null},{"kind":"missing_coverage","range":{"started_at":"2024-01-01T02:00:00Z","ended_at":"2024-01-01T03:00:00Z"},"versions":null},{"kind":"corrupt_interval","range":{"started_at":"2024-01-01T03:00:00Z","ended_at":"2024-01-01T04:00:00Z"},"versions":{"policy_version":1,"schema_version":1}},{"kind":"overlap","range":{"started_at":"2024-01-01T04:00:00Z","ended_at":"2024-01-01T05:00:00Z"},"versions":{"policy_version":1,"schema_version":1}},{"kind":"unknown_version","range":{"started_at":"2024-01-01T05:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"versions":{"policy_version":99,"schema_version":99}},{"kind":"usage_query_incomplete","range":{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"versions":null},{"kind":"usage_range_missing","range":{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"versions":null},{"kind":"usage_range_mismatch","range":{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T06:00:00Z"},"versions":null}],"activity":"not_assertable"}"#;
        assert_eq!(canonical, GOLDEN);
        assert_eq!(
            serde_json::from_str::<CoverageEvidence>(&canonical).unwrap(),
            evidence
        );
        for segment in evidence.segments() {
            let wire = serde_json::to_string(segment).unwrap();
            assert_eq!(
                serde_json::from_str::<CoverageSegment>(&wire).unwrap(),
                segment.clone()
            );
        }
        for diagnostic in evidence.diagnostics() {
            let wire = serde_json::to_string(diagnostic).unwrap();
            assert_eq!(
                serde_json::from_str::<CoverageDiagnostic>(&wire).unwrap(),
                diagnostic.clone()
            );
        }

        for field in ["evidence", "segment", "diagnostic"] {
            let mut value = match field {
                "evidence" => serde_json::to_value(&evidence).unwrap(),
                "segment" => serde_json::to_value(&evidence.segments()[0]).unwrap(),
                "diagnostic" => serde_json::to_value(&evidence.diagnostics()[0]).unwrap(),
                _ => unreachable!(),
            };
            value
                .as_object_mut()
                .unwrap()
                .insert("unexpected".to_owned(), serde_json::json!(true));
            let rejected = match field {
                "evidence" => serde_json::from_value::<CoverageEvidence>(value).is_err(),
                "segment" => serde_json::from_value::<CoverageSegment>(value).is_err(),
                "diagnostic" => serde_json::from_value::<CoverageDiagnostic>(value).is_err(),
                _ => unreachable!(),
            };
            assert!(rejected, "{field} must deny unknown fields");
        }
    }

    #[test]
    fn deserialization_cannot_bypass_interval_invariants() {
        let invalid = serde_json::json!({
            "state": "privacy_excluded",
            "bounds": {
                "kind": "closed",
                "range": {
                    "started_at": "2024-01-01T00:00:00Z",
                    "ended_at": "2024-01-01T01:00:00Z"
                }
            },
            "reason": "normal_observation",
            "completeness": "complete",
            "versions": { "policy_version": 1, "schema_version": 1 },
            "observed_through": "2024-01-01T01:00:00Z",
            "revision": 1
        });
        assert!(serde_json::from_value::<CoverageInterval>(invalid).is_err());
    }

    #[test]
    fn fixed_clock_boundaries_do_not_read_local_timezone() {
        let requested = range("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z");
        assert_eq!(requested.started_at(), utc("2024-01-01T00:00:00Z"));
        assert_eq!(requested.ended_at(), utc("2024-01-01T01:00:00Z"));
    }
}
