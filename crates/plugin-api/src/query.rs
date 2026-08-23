//! Aggregate-only, bounded usage query and result DTOs.

use std::{fmt, marker::PhantomData};

use chrono::NaiveDate;
use schemars::JsonSchema;
use serde::de::{IgnoredAny, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer, Serialize};

use crate::{
    ContractError, DurationMillis, MAX_QUERY_BYTES, MAX_QUERY_RANGE_DAYS, MAX_QUERY_ROWS,
    UsageGranularity, validate_label,
};

/// An inclusive calendar-date range.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DateRange {
    /// First included local calendar date.
    pub start: NaiveDate,
    /// Last included local calendar date.
    pub end: NaiveDate,
}

impl DateRange {
    /// Validates ordering and an inclusive maximum range.
    pub fn validate(&self, max_days: u16) -> Result<(), ContractError> {
        let day_span = self.end.signed_duration_since(self.start).num_days();
        if day_span < 0 {
            return Err(ContractError::InvalidRange {
                field: "date_range",
            });
        }
        let inclusive_days = u64::try_from(day_span).map_or(u64::MAX, |days| days + 1);
        if inclusive_days > u64::from(max_days) {
            return Err(ContractError::LimitExceeded {
                field: "date_range_days",
                limit: u64::from(max_days),
            });
        }
        Ok(())
    }
}

/// Hard execution and response limits for an aggregate query.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct QueryBudget {
    /// Maximum returned rows across all aggregate collections.
    #[schemars(range(min = 1, max = 10000))]
    pub max_rows: u32,
    /// Maximum serialized response bytes.
    #[schemars(range(min = 1, max = 1048576))]
    pub max_bytes: u64,
    /// Hard host deadline in milliseconds.
    #[schemars(range(min = 1))]
    pub deadline_ms: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct QueryBudgetWire {
    max_rows: u32,
    max_bytes: u64,
    deadline_ms: u32,
}

impl<'de> Deserialize<'de> for QueryBudget {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = QueryBudgetWire::deserialize(deserializer)?;
        let value = Self {
            max_rows: wire.max_rows,
            max_bytes: wire.max_bytes,
            deadline_ms: wire.deadline_ms,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

impl QueryBudget {
    /// Validates canonical query limits and a nonzero deadline.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.max_rows == 0 || self.max_rows > MAX_QUERY_ROWS {
            return Err(ContractError::LimitExceeded {
                field: "max_rows",
                limit: u64::from(MAX_QUERY_ROWS),
            });
        }
        if self.max_bytes == 0 || self.max_bytes > MAX_QUERY_BYTES {
            return Err(ContractError::LimitExceeded {
                field: "max_bytes",
                limit: MAX_QUERY_BYTES,
            });
        }
        if self.deadline_ms == 0 {
            return Err(ContractError::InvalidRange {
                field: "deadline_ms",
            });
        }
        Ok(())
    }
}

/// A bounded aggregate-only usage query.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BoundedUsageQuery {
    /// Inclusive requested date range.
    pub range: DateRange,
    /// Requested aggregate granularities.
    #[schemars(length(min = 1, max = 3))]
    pub granularities: Vec<UsageGranularity>,
    /// Hard execution and result budget.
    pub budget: QueryBudget,
    /// Opaque host-issued continuation cursor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(length(min = 1, max = 512))]
    pub cursor: Option<String>,
}

impl BoundedUsageQuery {
    /// Validates date, result, deadline, granularity, and cursor bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.range.validate(MAX_QUERY_RANGE_DAYS)?;
        self.budget.validate_basic()?;
        if self.granularities.is_empty() {
            return Err(ContractError::EmptyField {
                field: "granularities",
            });
        }
        if self.granularities.len() > 3 {
            return Err(ContractError::LimitExceeded {
                field: "granularities",
                limit: 3,
            });
        }
        if self.cursor.as_ref().is_some_and(String::is_empty) {
            return Err(ContractError::EmptyField { field: "cursor" });
        }
        if self
            .cursor
            .as_ref()
            .is_some_and(|cursor| cursor.len() > 512)
        {
            return Err(ContractError::FieldTooLong {
                field: "cursor",
                max_bytes: 512,
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BoundedUsageQueryWire {
    range: DateRange,
    #[serde(deserialize_with = "deserialize_granularities")]
    granularities: Vec<UsageGranularity>,
    budget: QueryBudget,
    #[serde(default)]
    cursor: Option<BoundedString<512>>,
}

impl<'de> Deserialize<'de> for BoundedUsageQuery {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = BoundedUsageQueryWire::deserialize(deserializer)?;
        let value = Self {
            range: wire.range,
            granularities: wire.granularities,
            budget: wire.budget,
            cursor: wire.cursor.map(BoundedString::into_inner),
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

/// A normalized application identity safe for aggregate plugin access.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AggregateApplication {
    /// Host-normalized display identifier, not an executable path.
    #[schemars(length(min = 1, max = 256))]
    pub display_id: String,
    /// Host-normalized application display name.
    #[schemars(length(min = 1, max = 256))]
    pub display_name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AggregateApplicationWire {
    display_id: BoundedString<256>,
    display_name: BoundedString<256>,
}

impl<'de> Deserialize<'de> for AggregateApplication {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = AggregateApplicationWire::deserialize(deserializer)?;
        let value = Self {
            display_id: wire.display_id.into_inner(),
            display_name: wire.display_name.into_inner(),
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

impl AggregateApplication {
    /// Validates normalized display fields.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        validate_label("app_display_id", &self.display_id)?;
        validate_label("app_display_name", &self.display_name)
    }
}

/// Total usage for one calendar day.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DailyUsageAggregate {
    /// Calendar date represented by the aggregate.
    pub date: NaiveDate,
    /// Total tracked duration for the date.
    pub duration: DurationMillis,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DailyUsageAggregateWire {
    date: NaiveDate,
    duration: DurationMillis,
}

impl<'de> Deserialize<'de> for DailyUsageAggregate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = DailyUsageAggregateWire::deserialize(deserializer)?;
        Ok(Self {
            date: wire.date,
            duration: wire.duration,
        })
    }
}

/// Total usage for one normalized application.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ApplicationUsageAggregate {
    /// Normalized application identity.
    pub application: AggregateApplication,
    /// Total tracked duration for the requested range.
    pub duration: DurationMillis,
}

impl ApplicationUsageAggregate {
    fn validate_basic(&self) -> Result<(), ContractError> {
        self.application.validate_basic()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApplicationUsageAggregateWire {
    application: AggregateApplication,
    duration: DurationMillis,
}

impl<'de> Deserialize<'de> for ApplicationUsageAggregate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = ApplicationUsageAggregateWire::deserialize(deserializer)?;
        let value = Self {
            application: wire.application,
            duration: wire.duration,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

/// Aggregate usage in one hour-of-day bucket.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HourlyUsageAggregate {
    /// Hour of day in the inclusive range 0 through 23.
    #[schemars(range(max = 23))]
    pub hour: u8,
    /// Total tracked duration in the hour bucket.
    pub duration: DurationMillis,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HourlyUsageAggregateWire {
    hour: u8,
    duration: DurationMillis,
}

impl<'de> Deserialize<'de> for HourlyUsageAggregate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = HourlyUsageAggregateWire::deserialize(deserializer)?;
        let value = Self {
            hour: wire.hour,
            duration: wire.duration,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

impl HourlyUsageAggregate {
    /// Validates the hour-of-day bound.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.hour > 23 {
            return Err(ContractError::InvalidRange { field: "hour" });
        }
        Ok(())
    }
}

/// One bounded page of aggregate-only usage data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct UsageAggregatePage {
    /// Date range represented by this page.
    pub range: DateRange,
    /// Daily totals when requested.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 10000))]
    pub daily: Vec<DailyUsageAggregate>,
    /// Per-application totals when requested.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 10000))]
    pub applications: Vec<ApplicationUsageAggregate>,
    /// Hour-of-day totals when requested.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 10000))]
    pub hourly: Vec<HourlyUsageAggregate>,
    /// Opaque continuation cursor, absent on the last page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(length(min = 1, max = 512))]
    pub next_cursor: Option<String>,
}

impl UsageAggregatePage {
    /// Returns the total number of aggregate rows in this page.
    #[must_use]
    pub fn row_count(&self) -> usize {
        self.daily.len() + self.applications.len() + self.hourly.len()
    }

    /// Validates safe aggregate fields and canonical row bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.range.validate(MAX_QUERY_RANGE_DAYS)?;
        if self.row_count() > MAX_QUERY_ROWS as usize {
            return Err(ContractError::LimitExceeded {
                field: "aggregate_rows",
                limit: u64::from(MAX_QUERY_ROWS),
            });
        }
        for aggregate in &self.applications {
            aggregate.validate_basic()?;
        }
        for aggregate in &self.hourly {
            aggregate.validate_basic()?;
        }
        if self.next_cursor.as_ref().is_some_and(String::is_empty) {
            return Err(ContractError::EmptyField {
                field: "next_cursor",
            });
        }
        if self
            .next_cursor
            .as_ref()
            .is_some_and(|cursor| cursor.len() > 512)
        {
            return Err(ContractError::FieldTooLong {
                field: "next_cursor",
                max_bytes: 512,
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UsageAggregatePageWire {
    range: DateRange,
    #[serde(default, deserialize_with = "deserialize_aggregate_rows")]
    daily: Vec<DailyUsageAggregate>,
    #[serde(default, deserialize_with = "deserialize_aggregate_rows")]
    applications: Vec<ApplicationUsageAggregate>,
    #[serde(default, deserialize_with = "deserialize_aggregate_rows")]
    hourly: Vec<HourlyUsageAggregate>,
    #[serde(default)]
    next_cursor: Option<BoundedString<512>>,
}

fn deserialize_granularities<'de, D>(deserializer: D) -> Result<Vec<UsageGranularity>, D::Error>
where
    D: Deserializer<'de>,
{
    deserialize_bounded_vec::<D, UsageGranularity, 3>(deserializer)
}

fn deserialize_aggregate_rows<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    deserialize_bounded_vec::<D, T, { MAX_QUERY_ROWS as usize }>(deserializer)
}

fn deserialize_bounded_vec<'de, D, T, const MAX: usize>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    deserializer.deserialize_seq(BoundedVecVisitor::<T, MAX>(PhantomData))
}

struct BoundedVecVisitor<T, const MAX: usize>(PhantomData<T>);

struct BoundedString<const MAX: usize>(String);

impl<const MAX: usize> BoundedString<MAX> {
    fn checked(value: String) -> Result<Self, &'static str> {
        if value.len() > MAX {
            return Err("string exceeds its canonical byte limit");
        }
        Ok(Self(value))
    }

    fn into_inner(self) -> String {
        self.0
    }
}

impl<'de, const MAX: usize> Deserialize<'de> for BoundedString<MAX> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct BoundedStringVisitor<const MAX: usize>;

        impl<const MAX: usize> Visitor<'_> for BoundedStringVisitor<MAX> {
            type Value = BoundedString<MAX>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "a string containing at most {MAX} UTF-8 bytes")
            }

            fn visit_borrowed_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if value.len() > MAX {
                    return Err(E::invalid_length(value.len(), &self));
                }
                Ok(BoundedString(value.to_owned()))
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                self.visit_borrowed_str(value)
            }

            fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                BoundedString::checked(value).map_err(E::custom)
            }
        }

        deserializer.deserialize_str(BoundedStringVisitor::<MAX>)
    }
}

impl<'de, T, const MAX: usize> Visitor<'de> for BoundedVecVisitor<T, MAX>
where
    T: Deserialize<'de>,
{
    type Value = Vec<T>;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "an array containing at most {MAX} items")
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: SeqAccess<'de>,
    {
        let capacity = sequence.size_hint().unwrap_or(0).min(MAX);
        let mut values = Vec::with_capacity(capacity);
        while values.len() < MAX {
            let Some(value) = sequence.next_element()? else {
                return Ok(values);
            };
            values.push(value);
        }
        if sequence.next_element::<IgnoredAny>()?.is_some() {
            return Err(serde::de::Error::invalid_length(MAX + 1, &self));
        }
        Ok(values)
    }
}

impl<'de> Deserialize<'de> for UsageAggregatePage {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = UsageAggregatePageWire::deserialize(deserializer)?;
        let value = Self {
            range: wire.range,
            daily: wire.daily,
            applications: wire.applications,
            hourly: wire.hourly,
            next_cursor: wire.next_cursor.map(BoundedString::into_inner),
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).expect("valid date")
    }

    #[test]
    fn query_rejects_reversed_and_oversized_ranges() {
        let reversed = DateRange {
            start: date(2026, 8, 2),
            end: date(2026, 8, 1),
        };
        assert!(reversed.validate(90).is_err());
        let long = DateRange {
            start: date(2026, 1, 1),
            end: date(2026, 8, 1),
        };
        assert!(long.validate(90).is_err());
        assert!(
            serde_json::from_str::<DateRange>(
                r#"{"start":"2026-08-01","end":"2026-08-02","extra":true}"#,
            )
            .is_err()
        );
    }

    #[test]
    fn bounded_query_and_budget_validate() {
        let query = BoundedUsageQuery {
            range: DateRange {
                start: date(2026, 8, 1),
                end: date(2026, 8, 7),
            },
            granularities: vec![UsageGranularity::Day],
            budget: QueryBudget {
                max_rows: 100,
                max_bytes: 64 * 1_024,
                deadline_ms: 2_000,
            },
            cursor: None,
        };
        assert!(query.budget.validate_basic().is_ok());
        assert!(query.validate_basic().is_ok());
    }

    #[test]
    fn aggregate_page_counts_and_validates_safe_rows() {
        let page = UsageAggregatePage {
            range: DateRange {
                start: date(2026, 8, 1),
                end: date(2026, 8, 1),
            },
            daily: vec![DailyUsageAggregate {
                date: date(2026, 8, 1),
                duration: DurationMillis(1_000),
            }],
            applications: vec![ApplicationUsageAggregate {
                application: AggregateApplication {
                    display_id: "visual-studio-code".to_owned(),
                    display_name: "Visual Studio Code".to_owned(),
                },
                duration: DurationMillis(1_000),
            }],
            hourly: vec![HourlyUsageAggregate {
                hour: 9,
                duration: DurationMillis(1_000),
            }],
            next_cursor: None,
        };
        assert_eq!(page.row_count(), 3);
        assert!(page.validate_basic().is_ok());
    }

    #[test]
    fn every_query_layer_rejects_unknown_fields() {
        assert!(
            serde_json::from_str::<QueryBudget>(
                r#"{"max_rows":1,"max_bytes":1,"deadline_ms":1,"extra":true}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<BoundedUsageQuery>(
                r#"{"range":{"start":"2026-08-01","end":"2026-08-01"},"granularities":["day"],"budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1},"extra":true}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<AggregateApplication>(
                r#"{"display_id":"app-id","display_name":"App","extra":true}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<DailyUsageAggregate>(
                r#"{"date":"2026-08-01","duration":1,"extra":true}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<ApplicationUsageAggregate>(
                r#"{"application":{"display_id":"app-id","display_name":"App"},"duration":1,"extra":true}"#
            )
            .is_err()
        );
        assert!(
            serde_json::from_str::<HourlyUsageAggregate>(r#"{"hour":1,"duration":1,"extra":true}"#)
                .is_err()
        );
        assert!(
            serde_json::from_str::<UsageAggregatePage>(
                r#"{"range":{"start":"2026-08-01","end":"2026-08-01"},"extra":true}"#
            )
            .is_err()
        );

        let nested_date = r#"{
            "range":{"start":"2026-08-01","end":"2026-08-01","extra":true},
            "granularities":["day"],
            "budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1}
        }"#;
        assert!(serde_json::from_str::<BoundedUsageQuery>(nested_date).is_err());
    }

    #[test]
    fn deserialization_rejects_invalid_budget_range_hour_and_cursor() {
        let invalid_budget = r#"{"max_rows":0,"max_bytes":1,"deadline_ms":1}"#;
        assert!(serde_json::from_str::<QueryBudget>(invalid_budget).is_err());

        let reversed = r#"{
            "range":{"start":"2026-08-02","end":"2026-08-01"},
            "granularities":["day"],
            "budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1}
        }"#;
        assert!(serde_json::from_str::<BoundedUsageQuery>(reversed).is_err());

        let excessive_range = r#"{
            "range":{"start":"2026-01-01","end":"2026-08-01"},
            "granularities":["day"],
            "budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1}
        }"#;
        assert!(serde_json::from_str::<BoundedUsageQuery>(excessive_range).is_err());

        assert!(
            serde_json::from_str::<HourlyUsageAggregate>(r#"{"hour":24,"duration":1}"#).is_err()
        );

        let empty_cursor = r#"{
            "range":{"start":"2026-08-01","end":"2026-08-01"},
            "granularities":["day"],
            "budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1},
            "cursor":""
        }"#;
        assert!(serde_json::from_str::<BoundedUsageQuery>(empty_cursor).is_err());

        let long_cursor = serde_json::json!({
            "range":{"start":"2026-08-01","end":"2026-08-01"},
            "granularities":["day"],
            "budget":{"max_rows":1,"max_bytes":1,"deadline_ms":1},
            "cursor":"x".repeat(513),
        });
        assert!(serde_json::from_value::<BoundedUsageQuery>(long_cursor).is_err());
    }

    #[test]
    fn response_deserialization_rejects_oversize_strings_cursors_and_rows() {
        let long_application = serde_json::json!({
            "display_id": "x".repeat(257),
            "display_name": "App",
        });
        assert!(serde_json::from_value::<AggregateApplication>(long_application).is_err());

        let long_cursor = serde_json::json!({
            "range":{"start":"2026-08-01","end":"2026-08-01"},
            "next_cursor":"x".repeat(513),
        });
        assert!(serde_json::from_value::<UsageAggregatePage>(long_cursor).is_err());

        let rows = (0..=MAX_QUERY_ROWS)
            .map(|_| serde_json::json!({"date":"2026-08-01","duration":1}))
            .collect::<Vec<_>>();
        let oversized_page = serde_json::json!({
            "range":{"start":"2026-08-01","end":"2026-08-01"},
            "daily": rows,
        });
        assert!(serde_json::from_value::<UsageAggregatePage>(oversized_page).is_err());
    }

    #[test]
    fn json_string_visitors_reject_oversize_values_at_the_field_boundary() {
        let long_cursor = "x".repeat(513);
        let query = format!(
            r#"{{
                "range":{{"start":"2026-08-01","end":"2026-08-01"}},
                "granularities":["day"],
                "budget":{{"max_rows":1,"max_bytes":1,"deadline_ms":1}},
                "cursor":"{long_cursor}"
            }}"#
        );
        assert!(serde_json::from_str::<BoundedUsageQuery>(&query).is_err());

        let long_label = "x".repeat(257);
        let display_id = format!(r#"{{"display_id":"{long_label}","display_name":"Application"}}"#);
        assert!(serde_json::from_str::<AggregateApplication>(&display_id).is_err());
        let display_name = format!(r#"{{"display_id":"app-id","display_name":"{long_label}"}}"#);
        assert!(serde_json::from_str::<AggregateApplication>(&display_name).is_err());

        let page = format!(
            r#"{{
                "range":{{"start":"2026-08-01","end":"2026-08-01"}},
                "next_cursor":"{long_cursor}"
            }}"#
        );
        assert!(serde_json::from_str::<UsageAggregatePage>(&page).is_err());
    }
}
