//! Stable plugin error envelopes and contract-validation errors.

use std::collections::BTreeMap;

use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};
use thiserror::Error;

use crate::schema::{ContributionId, CorrelationId, PluginId, ScalarValue, validate_safe_token};

const MAX_SAFE_DETAILS: usize = 12;
const MAX_SAFE_DETAIL_BYTES: usize = 4_096;

/// Stable machine-readable plugin error codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PluginErrorCode {
    /// Contract input failed validation.
    ValidationFailed,
    /// A requested plugin or contribution was not found.
    NotFound,
    /// A stable identifier was registered more than once.
    DuplicateId,
    /// The plugin does not support the current host API.
    IncompatibleHost,
    /// The plugin does not support the current platform.
    UnsupportedPlatform,
    /// A required capability is absent or revoked.
    PermissionDenied,
    /// A bounded resource limit was exceeded.
    LimitExceeded,
    /// The requested lifecycle transition is invalid.
    InvalidState,
    /// Plugin activation failed.
    StartFailed,
    /// Plugin shutdown failed.
    StopFailed,
    /// The operation exceeded its deadline.
    Timeout,
    /// The operation was cancelled.
    Cancelled,
    /// A model request failed.
    ModelFailed,
    /// A required host service is temporarily unavailable.
    Unavailable,
    /// An unexpected host error occurred.
    Internal,
}

/// A stable, privacy-safe error envelope returned across plugin boundaries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
pub struct PluginErrorDto {
    /// Stable machine-readable error code.
    pub code: PluginErrorCode,
    /// Whether retrying the same operation may succeed.
    pub retryable: bool,
    /// Host-trusted plugin identity, when the failure is plugin-specific.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plugin_id: Option<PluginId>,
    /// Host-trusted contribution identity, when applicable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contribution_id: Option<ContributionId>,
    /// Correlation identifier shared by all events in the operation.
    pub correlation_id: CorrelationId,
    /// Bounded machine-readable details that contain no user content.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub safe_details: BTreeMap<String, ScalarValue>,
}

impl PluginErrorDto {
    /// Creates an error envelope without optional attribution or details.
    #[must_use]
    pub fn new(code: PluginErrorCode, retryable: bool, correlation_id: CorrelationId) -> Self {
        Self {
            code,
            retryable,
            plugin_id: None,
            contribution_id: None,
            correlation_id,
            safe_details: BTreeMap::new(),
        }
    }

    /// Attaches host-trusted plugin attribution.
    #[must_use]
    pub fn with_plugin(mut self, plugin_id: PluginId) -> Self {
        self.plugin_id = Some(plugin_id);
        self
    }

    /// Attaches host-trusted contribution attribution.
    #[must_use]
    pub fn with_contribution(mut self, contribution_id: ContributionId) -> Self {
        self.contribution_id = Some(contribution_id);
        self
    }

    /// Inserts a bounded, non-sensitive detail.
    pub fn insert_safe_detail(
        &mut self,
        key: impl Into<String>,
        value: ScalarValue,
    ) -> Result<(), ContractError> {
        let key = key.into();
        let previous = self.safe_details.insert(key.clone(), value);
        if let Err(error) = self.validate_basic() {
            match previous {
                Some(previous_value) => {
                    self.safe_details.insert(key, previous_value);
                }
                None => {
                    self.safe_details.remove(&key);
                }
            }
            return Err(error);
        }
        Ok(())
    }

    /// Validates all identities and privacy-safe detail bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.correlation_id.validate()?;
        if let Some(plugin_id) = &self.plugin_id {
            plugin_id.validate()?;
        }
        if let Some(contribution_id) = &self.contribution_id {
            contribution_id.validate()?;
        }
        if self.safe_details.len() > MAX_SAFE_DETAILS {
            return Err(ContractError::LimitExceeded {
                field: "safe_details",
                limit: MAX_SAFE_DETAILS as u64,
            });
        }

        let mut estimated_bytes = 0usize;
        for (key, value) in &self.safe_details {
            validate_safe_detail_key(key)?;
            validate_safe_detail_value(value)?;
            estimated_bytes = estimated_bytes
                .saturating_add(key.len())
                .saturating_add(value.estimated_size_bytes());
        }
        if estimated_bytes > MAX_SAFE_DETAIL_BYTES {
            return Err(ContractError::LimitExceeded {
                field: "safe_detail_bytes",
                limit: MAX_SAFE_DETAIL_BYTES as u64,
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
struct PluginErrorDtoWire {
    code: PluginErrorCode,
    retryable: bool,
    #[serde(default)]
    plugin_id: Option<PluginId>,
    #[serde(default)]
    contribution_id: Option<ContributionId>,
    correlation_id: CorrelationId,
    #[serde(default)]
    safe_details: BTreeMap<String, ScalarValue>,
}

impl<'de> Deserialize<'de> for PluginErrorDto {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = PluginErrorDtoWire::deserialize(deserializer)?;
        let value = Self {
            code: wire.code,
            retryable: wire.retryable,
            plugin_id: wire.plugin_id,
            contribution_id: wire.contribution_id,
            correlation_id: wire.correlation_id,
            safe_details: wire.safe_details,
        };
        value
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(value)
    }
}

/// Errors produced while validating canonical contract values.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ContractError {
    /// A required field was empty.
    #[error("{field} must not be empty")]
    EmptyField {
        /// Stable field name.
        field: &'static str,
    },
    /// A string field exceeded its byte budget.
    #[error("{field} exceeds the maximum length of {max_bytes} bytes")]
    FieldTooLong {
        /// Stable field name.
        field: &'static str,
        /// Maximum accepted UTF-8 byte count.
        max_bytes: usize,
    },
    /// An identifier violated canonical syntax.
    #[error("{field} contains an invalid identifier: {value}")]
    InvalidIdentifier {
        /// Stable field name.
        field: &'static str,
        /// Rejected non-sensitive identifier.
        value: String,
    },
    /// A manifest schema version is not supported.
    #[error("unsupported manifest schema version: {version}")]
    UnsupportedSchemaVersion {
        /// Rejected schema version.
        version: u32,
    },
    /// A collection contains a duplicate stable identifier.
    #[error("duplicate {field}: {value}")]
    DuplicateIdentifier {
        /// Collection field containing the duplicate.
        field: &'static str,
        /// Duplicate identifier.
        value: String,
    },
    /// A numeric or collection bound was exceeded.
    #[error("{field} exceeds limit {limit}")]
    LimitExceeded {
        /// Stable field name.
        field: &'static str,
        /// Maximum accepted value.
        limit: u64,
    },
    /// A range has invalid or reversed bounds.
    #[error("invalid range for {field}")]
    InvalidRange {
        /// Stable range field name.
        field: &'static str,
    },
    /// A domain constraint is malformed.
    #[error("invalid domain constraint: {domain}")]
    InvalidDomain {
        /// Rejected domain string.
        domain: String,
    },
    /// A diagnostic field is not safe for persistence.
    #[error("diagnostic field is forbidden: {field}")]
    ForbiddenDiagnosticField {
        /// Rejected field name.
        field: String,
    },
    /// A contribution descriptor has an invalid combination of settings.
    #[error("invalid contribution field: {field}")]
    InvalidContribution {
        /// Stable invalid field name.
        field: &'static str,
    },
    /// A value intended for diagnostics was free-form or credential-like.
    #[error("{field} must be a bounded, non-sensitive machine-readable token")]
    UnsafeStringValue {
        /// Stable field name; the rejected value is deliberately omitted.
        field: &'static str,
    },
    /// A reference did not resolve within its owning manifest.
    #[error("unknown {field} reference: {value}")]
    UnknownReference {
        /// Stable reference field name.
        field: &'static str,
        /// Rejected non-sensitive identifier.
        value: String,
    },
    /// An identifier was outside its required plugin namespace.
    #[error("{field} must begin with namespace {expected_prefix}")]
    InvalidNamespace {
        /// Stable identifier field name.
        field: &'static str,
        /// Required namespace prefix.
        expected_prefix: String,
    },
}

fn validate_safe_detail_key(key: &str) -> Result<(), ContractError> {
    const FORBIDDEN: [&str; 12] = [
        "api_key",
        "authorization",
        "secret",
        "prompt",
        "response",
        "window_title",
        "journal",
        "image_path",
        "exe_path",
        "database_path",
        "payload",
        "body",
    ];
    if key.is_empty() {
        return Err(ContractError::EmptyField {
            field: "detail_key",
        });
    }
    let normalized = key.to_ascii_lowercase();
    if FORBIDDEN
        .iter()
        .any(|candidate| normalized.contains(candidate))
    {
        return Err(ContractError::ForbiddenDiagnosticField {
            field: key.to_owned(),
        });
    }
    validate_safe_token("detail_key", &normalized)?;
    Ok(())
}

fn validate_safe_detail_value(value: &ScalarValue) -> Result<(), ContractError> {
    if let ScalarValue::String(value) = value {
        validate_safe_token("safe_detail_value", value)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_builder_preserves_stable_attribution() {
        let error = PluginErrorDto::new(
            PluginErrorCode::PermissionDenied,
            false,
            CorrelationId::new("corr-1").expect("valid correlation"),
        )
        .with_plugin(PluginId::new("sample-plugin").expect("valid plugin"))
        .with_contribution(
            ContributionId::new("sample-plugin.command").expect("valid contribution"),
        );
        assert_eq!(
            error.plugin_id.as_ref().map(PluginId::as_str),
            Some("sample-plugin")
        );
        assert_eq!(
            error.contribution_id.as_ref().map(ContributionId::as_str),
            Some("sample-plugin.command")
        );
        let json = serde_json::to_string(&error).expect("serialize safe error");
        let decoded =
            serde_json::from_str::<PluginErrorDto>(&json).expect("deserialize safe error");
        assert_eq!(decoded, error);
    }

    #[test]
    fn safe_details_reject_sensitive_and_unbounded_fields() {
        let mut error = PluginErrorDto::new(
            PluginErrorCode::Internal,
            false,
            CorrelationId::new("corr-2").expect("valid correlation"),
        );
        assert!(
            error
                .insert_safe_detail("authorization_header", ScalarValue::Boolean(true))
                .is_err()
        );
        for index in 0..12 {
            error
                .insert_safe_detail(format!("count_{index}"), ScalarValue::Unsigned(index))
                .expect("bounded detail");
        }
        assert!(
            error
                .insert_safe_detail("extra", ScalarValue::Unsigned(1))
                .is_err()
        );
    }

    #[test]
    fn deserialization_rejects_invalid_identity_and_sensitive_values() {
        let invalid_identity = r#"{
            "code":"internal",
            "retryable":false,
            "correlation_id":"INVALID",
            "safe_details":{}
        }"#;
        assert!(serde_json::from_str::<PluginErrorDto>(invalid_identity).is_err());

        let sensitive_value = r#"{
            "code":"internal",
            "retryable":false,
            "correlation_id":"corr-1",
            "safe_details":{"status":{"type":"string","value":"bearer-private"}}
        }"#;
        assert!(serde_json::from_str::<PluginErrorDto>(sensitive_value).is_err());
    }
}
