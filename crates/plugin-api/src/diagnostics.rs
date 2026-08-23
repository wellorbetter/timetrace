//! Privacy-safe structured diagnostic event DTOs.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};

use crate::{
    ContractError, CorrelationId, DurationMillis, PluginId, ScalarValue, TimestampMillis,
    validate_safe_token,
};

/// Maximum number of structured fields accepted on one event.
pub const MAX_DIAGNOSTIC_FIELDS: usize = 12;
/// Maximum conservative encoded size accepted for event fields.
pub const MAX_DIAGNOSTIC_FIELD_BYTES: usize = 4_096;

/// Stable diagnostic severity levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticLevel {
    /// Very detailed development-only information.
    Trace,
    /// Development diagnostics disabled in normal production filters.
    Debug,
    /// Normal lifecycle or operation information.
    Info,
    /// Recoverable degradation requiring attention.
    Warn,
    /// Operation failure requiring diagnosis.
    Error,
}

/// Stable diagnostic subsystem targets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticTarget {
    /// Core tracking and storage.
    Core,
    /// Flutter/Rust bridge adapters.
    Bridge,
    /// Plugin catalog, lifecycle, and projection host.
    PluginHost,
    /// Host-owned data, model, secret, and settings services.
    PluginServices,
    /// A bundled or future sandboxed plugin operation.
    Plugin,
}

/// Allowlisted structured diagnostic field names.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticField {
    /// Stable operation name.
    Operation,
    /// Stable status token.
    Status,
    /// Stable error code.
    ErrorCode,
    /// Stable provider identifier.
    ProviderId,
    /// Stable lifecycle state.
    State,
    /// Stable non-sensitive reason code.
    ReasonCode,
    /// Returned row count.
    Rows,
    /// Returned byte count.
    Bytes,
    /// Generic bounded count.
    Count,
    /// Number of dropped diagnostic events.
    DroppedEvents,
    /// Retry attempt number.
    Attempt,
    /// Monotonic operation generation.
    Generation,
}

/// Plugin-supplied diagnostic payload before host attribution is applied.
///
/// The draft deliberately excludes the plugin identity, subsystem target,
/// timestamp, and correlation identifier. Those fields belong to the host's
/// authenticated session context and must never be accepted from plugin input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub struct PluginDiagnosticDraft {
    /// Event severity requested by the plugin.
    pub level: DiagnosticLevel,
    /// Stable machine-readable event code.
    pub event_code: String,
    /// Optional measured operation duration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<DurationMillis>,
    /// Allowlisted bounded fields containing no user content.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub fields: BTreeMap<DiagnosticField, ScalarValue>,
}

impl PluginDiagnosticDraft {
    /// Validates the event code and structured-field privacy budgets.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        validate_diagnostic_payload(&self.event_code, &self.fields)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PluginDiagnosticDraftWire {
    level: DiagnosticLevel,
    event_code: String,
    #[serde(default)]
    duration: Option<DurationMillis>,
    #[serde(default)]
    fields: BTreeMap<DiagnosticField, ScalarValue>,
}

impl<'de> Deserialize<'de> for PluginDiagnosticDraft {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = PluginDiagnosticDraftWire::deserialize(deserializer)?;
        let value = Self {
            level: wire.level,
            event_code: wire.event_code,
            duration: wire.duration,
            fields: wire.fields,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

/// One immutable, local-only structured diagnostic event.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub struct DiagnosticEvent {
    /// UTC event timestamp.
    pub timestamp: TimestampMillis,
    /// Event severity.
    pub level: DiagnosticLevel,
    /// Host subsystem target.
    pub target: DiagnosticTarget,
    /// Stable machine-readable event code.
    pub event_code: String,
    /// Host-injected plugin identity, absent for non-plugin events.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<PluginId>,
    /// Correlation identifier shared across one operation.
    pub correlation_id: CorrelationId,
    /// Optional measured operation duration.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<DurationMillis>,
    /// Allowlisted bounded fields containing no user content.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub fields: BTreeMap<DiagnosticField, ScalarValue>,
}

impl DiagnosticEvent {
    /// Validates identity, event code, field count, and encoded-size budget.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.correlation_id.validate()?;
        if let Some(plugin_id) = &self.plugin_id {
            plugin_id.validate()?;
        }
        validate_diagnostic_payload(&self.event_code, &self.fields)
    }

    /// Adds or replaces an allowlisted field while preserving event budgets.
    pub fn insert_field(
        &mut self,
        field: DiagnosticField,
        value: ScalarValue,
    ) -> Result<(), ContractError> {
        let previous = self.fields.insert(field, value);
        if let Err(error) = self.validate_basic() {
            match previous {
                Some(previous_value) => {
                    self.fields.insert(field, previous_value);
                }
                None => {
                    self.fields.remove(&field);
                }
            }
            return Err(error);
        }
        Ok(())
    }
}

fn validate_diagnostic_payload(
    event_code: &str,
    fields: &BTreeMap<DiagnosticField, ScalarValue>,
) -> Result<(), ContractError> {
    validate_safe_token("diagnostic_event_code", event_code)?;
    crate::ContributionId::new(event_code.to_owned())?;
    if fields.len() > MAX_DIAGNOSTIC_FIELDS {
        return Err(ContractError::LimitExceeded {
            field: "diagnostic_fields",
            limit: MAX_DIAGNOSTIC_FIELDS as u64,
        });
    }
    let estimated_bytes = fields.values().try_fold(0usize, |total, value| {
        validate_diagnostic_value(value)?;
        Ok::<usize, ContractError>(total.saturating_add(value.estimated_size_bytes()))
    })?;
    if estimated_bytes > MAX_DIAGNOSTIC_FIELD_BYTES {
        return Err(ContractError::LimitExceeded {
            field: "diagnostic_field_bytes",
            limit: MAX_DIAGNOSTIC_FIELD_BYTES as u64,
        });
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiagnosticEventWire {
    timestamp: TimestampMillis,
    level: DiagnosticLevel,
    target: DiagnosticTarget,
    event_code: String,
    #[serde(default)]
    plugin_id: Option<PluginId>,
    correlation_id: CorrelationId,
    #[serde(default)]
    duration: Option<DurationMillis>,
    #[serde(default)]
    fields: BTreeMap<DiagnosticField, ScalarValue>,
}

impl<'de> Deserialize<'de> for DiagnosticEvent {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = DiagnosticEventWire::deserialize(deserializer)?;
        let value = Self {
            timestamp: wire.timestamp,
            level: wire.level,
            target: wire.target,
            event_code: wire.event_code,
            plugin_id: wire.plugin_id,
            correlation_id: wire.correlation_id,
            duration: wire.duration,
            fields: wire.fields,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

fn validate_diagnostic_value(value: &ScalarValue) -> Result<(), ContractError> {
    if let ScalarValue::String(value) = value {
        validate_safe_token("diagnostic_string_value", value)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event() -> DiagnosticEvent {
        DiagnosticEvent {
            timestamp: TimestampMillis(1_723_708_800_000),
            level: DiagnosticLevel::Info,
            target: DiagnosticTarget::PluginHost,
            event_code: "plugin.start.completed".to_owned(),
            plugin_id: Some(PluginId::new("sample-plugin").expect("valid plugin")),
            correlation_id: CorrelationId::new("corr-1").expect("valid correlation"),
            duration: Some(DurationMillis(20)),
            fields: BTreeMap::new(),
        }
    }

    #[test]
    fn allowlisted_event_validates_and_round_trips() {
        let mut event = event();
        event
            .insert_field(DiagnosticField::Rows, ScalarValue::Unsigned(10))
            .expect("bounded field");
        assert!(event.validate_basic().is_ok());
        let json = serde_json::to_string(&event).expect("serialize event");
        let decoded: DiagnosticEvent = serde_json::from_str(&json).expect("deserialize event");
        assert_eq!(decoded, event);
    }

    #[test]
    fn oversized_field_is_rejected_without_mutating_event() {
        let mut event = event();
        let result = event.insert_field(
            DiagnosticField::Status,
            ScalarValue::String("x".repeat(MAX_DIAGNOSTIC_FIELD_BYTES + 1)),
        );
        assert!(result.is_err());
        assert!(event.fields.is_empty());
    }

    #[test]
    fn deserialization_rejects_sensitive_free_text_and_invalid_attribution() {
        let sensitive = r#"{
            "timestamp":1723708800000,
            "level":"error",
            "target":"plugin",
            "event_code":"plugin.request.failed",
            "plugin_id":"sample-plugin",
            "correlation_id":"corr-1",
            "fields":{"status":{"type":"string","value":"provider response body"}}
        }"#;
        assert!(serde_json::from_str::<DiagnosticEvent>(sensitive).is_err());

        let invalid_attribution = sensitive.replace("sample-plugin", "OTHER-PLUGIN");
        assert!(serde_json::from_str::<DiagnosticEvent>(&invalid_attribution).is_err());
    }

    #[test]
    fn plugin_draft_rejects_host_attribution_fields_and_sensitive_codes() {
        let forged = r#"{
            "level":"info",
            "event_code":"plugin.operation.completed",
            "plugin_id":"other-plugin",
            "target":"plugin_host",
            "timestamp":1723708800000,
            "correlation_id":"forged-correlation"
        }"#;
        assert!(serde_json::from_str::<PluginDiagnosticDraft>(forged).is_err());

        let sensitive = r#"{
            "level":"error",
            "event_code":"plugin.secret_token",
            "fields":{}
        }"#;
        assert!(serde_json::from_str::<PluginDiagnosticDraft>(sensitive).is_err());
    }
}
