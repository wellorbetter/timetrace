//! UTC-only time primitives for coverage persistence and queries.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use thiserror::Error;

/// Validation failures for UTC coverage boundaries.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum TimeRangeError {
    #[error("invalid RFC3339 timestamp: {0}")]
    InvalidRfc3339(String),
    #[error("timestamp must use UTC offset Z or +00:00: {0}")]
    NonUtcOffset(String),
    #[error("UTC half-open range must satisfy started_at < ended_at")]
    EmptyOrReversed,
}

/// Parse an RFC3339 timestamp while rejecting non-UTC offsets.
pub fn parse_utc_rfc3339(value: &str) -> Result<DateTime<Utc>, TimeRangeError> {
    let parsed = DateTime::parse_from_rfc3339(value)
        .map_err(|_| TimeRangeError::InvalidRfc3339(value.to_string()))?;
    if parsed.offset().local_minus_utc() != 0
        || !(value.ends_with('Z') || value.ends_with("+00:00"))
    {
        return Err(TimeRangeError::NonUtcOffset(value.to_string()));
    }
    Ok(parsed.with_timezone(&Utc))
}

/// A validated UTC half-open range `[started_at, ended_at)`.
///
/// The fields are private and deserialization reuses [`UtcRange::new`], so an
/// empty or reversed range cannot enter the domain through JSON.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
pub struct UtcRange {
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
}

impl UtcRange {
    pub fn new(started_at: DateTime<Utc>, ended_at: DateTime<Utc>) -> Result<Self, TimeRangeError> {
        if started_at >= ended_at {
            return Err(TimeRangeError::EmptyOrReversed);
        }
        Ok(Self {
            started_at,
            ended_at,
        })
    }

    pub fn parse(started_at: &str, ended_at: &str) -> Result<Self, TimeRangeError> {
        Self::new(parse_utc_rfc3339(started_at)?, parse_utc_rfc3339(ended_at)?)
    }

    pub const fn started_at(&self) -> DateTime<Utc> {
        self.started_at
    }

    pub const fn ended_at(&self) -> DateTime<Utc> {
        self.ended_at
    }

    pub fn contains_instant(&self, instant: DateTime<Utc>) -> bool {
        instant >= self.started_at && instant < self.ended_at
    }

    pub fn contains_range(&self, other: &Self) -> bool {
        other.started_at >= self.started_at && other.ended_at <= self.ended_at
    }

    pub fn overlaps(&self, other: &Self) -> bool {
        self.started_at < other.ended_at && other.started_at < self.ended_at
    }

    pub fn is_adjacent_to(&self, other: &Self) -> bool {
        self.ended_at == other.started_at || other.ended_at == self.started_at
    }

    pub fn intersection(&self, other: &Self) -> Option<Self> {
        let started_at = self.started_at.max(other.started_at);
        let ended_at = self.ended_at.min(other.ended_at);
        Self::new(started_at, ended_at).ok()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawUtcRange {
    started_at: String,
    ended_at: String,
}

impl<'de> Deserialize<'de> for UtcRange {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = RawUtcRange::deserialize(deserializer)?;
        Self::parse(&raw.started_at, &raw.ended_at).map_err(D::Error::custom)
    }
}

/// Validated bounds for a persisted interval. Open intervals have no end yet.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum UtcIntervalBounds {
    Closed { range: UtcRange },
    Open { started_at: DateTime<Utc> },
}

impl UtcIntervalBounds {
    pub fn closed(range: UtcRange) -> Self {
        Self::Closed { range }
    }

    pub fn open(started_at: DateTime<Utc>) -> Self {
        Self::Open { started_at }
    }

    pub const fn started_at(&self) -> DateTime<Utc> {
        match self {
            Self::Closed { range } => range.started_at(),
            Self::Open { started_at } => *started_at,
        }
    }

    pub const fn ended_at(&self) -> Option<DateTime<Utc>> {
        match self {
            Self::Closed { range } => Some(range.ended_at()),
            Self::Open { .. } => None,
        }
    }

    pub const fn closed_range(&self) -> Option<UtcRange> {
        match self {
            Self::Closed { range } => Some(*range),
            Self::Open { .. } => None,
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[serde(deny_unknown_fields)]
enum RawUtcIntervalBounds {
    Closed { range: UtcRange },
    Open { started_at: String },
}

impl<'de> Deserialize<'de> for UtcIntervalBounds {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(match RawUtcIntervalBounds::deserialize(deserializer)? {
            RawUtcIntervalBounds::Closed { range } => Self::closed(range),
            RawUtcIntervalBounds::Open { started_at } => {
                Self::open(parse_utc_rfc3339(&started_at).map_err(D::Error::custom)?)
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(value: &str) -> DateTime<Utc> {
        parse_utc_rfc3339(value).expect("fixed UTC timestamp")
    }

    #[test]
    fn rejects_non_utc_empty_and_reversed_ranges() {
        assert!(matches!(
            parse_utc_rfc3339("2024-01-01T08:00:00+08:00"),
            Err(TimeRangeError::NonUtcOffset(_))
        ));
        let start = utc("2024-01-01T00:00:00Z");
        assert_eq!(
            UtcRange::new(start, start),
            Err(TimeRangeError::EmptyOrReversed)
        );
        assert_eq!(
            UtcRange::new(start, start - chrono::Duration::seconds(1)),
            Err(TimeRangeError::EmptyOrReversed)
        );
    }

    #[test]
    fn half_open_range_operations_are_deterministic() {
        let first = UtcRange::parse("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z").unwrap();
        let second = UtcRange::parse("2024-01-01T01:00:00Z", "2024-01-01T02:00:00Z").unwrap();
        assert!(first.contains_instant(utc("2024-01-01T00:00:00Z")));
        assert!(!first.contains_instant(utc("2024-01-01T01:00:00Z")));
        assert!(first.is_adjacent_to(&second));
        assert!(!first.overlaps(&second));
        assert_eq!(first.intersection(&second), None);
    }

    #[test]
    fn deserialization_reuses_range_validation() {
        let invalid = r#"{
            "started_at":"2024-01-01T01:00:00Z",
            "ended_at":"2024-01-01T00:00:00Z"
        }"#;
        assert!(serde_json::from_str::<UtcRange>(invalid).is_err());
    }

    #[test]
    fn persistence_time_bounds_reject_unknown_fields_and_round_trip() {
        let range = UtcRange::parse("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z").unwrap();
        let clean = serde_json::to_value(range).unwrap();
        assert_eq!(
            serde_json::from_value::<UtcRange>(clean.clone()).unwrap(),
            range
        );

        let mut augmented_range = clean;
        augmented_range
            .as_object_mut()
            .unwrap()
            .insert("window_title".to_owned(), serde_json::json!("private"));
        assert!(serde_json::from_value::<UtcRange>(augmented_range).is_err());

        let bounds = UtcIntervalBounds::closed(range);
        let mut augmented_bounds = serde_json::to_value(bounds).unwrap();
        augmented_bounds
            .as_object_mut()
            .unwrap()
            .insert("path".to_owned(), serde_json::json!("private"));
        assert!(serde_json::from_value::<UtcIntervalBounds>(augmented_bounds).is_err());
        assert_eq!(
            serde_json::from_value::<UtcIntervalBounds>(serde_json::to_value(bounds).unwrap())
                .unwrap(),
            bounds
        );
    }

    #[test]
    fn serde_requires_utc_text_at_every_time_boundary() {
        let non_utc_start = serde_json::json!({
            "started_at": "2024-01-01T08:00:00+08:00",
            "ended_at": "2024-01-01T01:00:00Z"
        });
        let non_utc_end = serde_json::json!({
            "started_at": "2024-01-01T00:00:00Z",
            "ended_at": "2024-01-01T09:00:00+08:00"
        });
        let non_utc_open = serde_json::json!({
            "kind": "open",
            "started_at": "2024-01-01T08:00:00+08:00"
        });
        assert!(serde_json::from_value::<UtcRange>(non_utc_start).is_err());
        assert!(serde_json::from_value::<UtcRange>(non_utc_end).is_err());
        assert!(serde_json::from_value::<UtcIntervalBounds>(non_utc_open).is_err());
        assert!(parse_utc_rfc3339("2024-01-01T00:00:00-00:00").is_err());

        let zero_offset = serde_json::json!({
            "started_at": "2024-01-01T00:00:00+00:00",
            "ended_at": "2024-01-01T01:00:00+00:00"
        });
        let parsed = serde_json::from_value::<UtcRange>(zero_offset).unwrap();
        assert_eq!(
            parsed,
            UtcRange::parse("2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z").unwrap()
        );
        assert_eq!(
            serde_json::to_string(&parsed).unwrap(),
            r#"{"started_at":"2024-01-01T00:00:00Z","ended_at":"2024-01-01T01:00:00Z"}"#
        );
        assert!(
            serde_json::from_value::<UtcIntervalBounds>(serde_json::json!({
                "kind": "open",
                "started_at": "2024-01-01T00:00:00+00:00"
            }))
            .is_ok()
        );
    }
}
