//! Shared scalar values, identifiers, and wire-format primitives.

use std::fmt;

use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize, de::Visitor};

use crate::error::ContractError;

/// Maximum UTF-8 byte length accepted for a contract identifier.
pub const MAX_IDENTIFIER_BYTES: usize = 128;

/// Maximum UTF-8 byte length accepted for a short display label.
pub const MAX_LABEL_BYTES: usize = 256;

/// Maximum UTF-8 byte length accepted for a non-sensitive description.
pub const MAX_DESCRIPTION_BYTES: usize = 2_048;

/// Maximum UTF-8 byte length accepted for a machine-readable safe token.
pub const MAX_SAFE_TOKEN_BYTES: usize = 128;

/// A transport-safe scalar value used by settings and safe diagnostics.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(
    tag = "type",
    content = "value",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum ScalarValue {
    /// A Boolean value.
    Boolean(bool),
    /// A signed integer value.
    Integer(i64),
    /// An unsigned integer value.
    Unsigned(u64),
    /// A bounded UTF-8 string value.
    String(String),
}

impl ScalarValue {
    /// Returns the number of bytes the value contributes to a conservative
    /// diagnostic-size estimate.
    #[must_use]
    pub fn estimated_size_bytes(&self) -> usize {
        match self {
            Self::Boolean(_) => 1,
            Self::Integer(_) | Self::Unsigned(_) => 20,
            Self::String(value) => value.len(),
        }
    }
}

/// A UTC Unix timestamp expressed in milliseconds.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(transparent)]
pub struct TimestampMillis(pub i64);

/// A duration expressed in milliseconds.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(transparent)]
pub struct DurationMillis(pub u64);

macro_rules! define_identifier {
    ($name:ident, $doc:literal, $field:literal) => {
        #[doc = $doc]
        #[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, JsonSchema)]
        #[serde(transparent)]
        pub struct $name(
            #[schemars(
                length(min = 1, max = 128),
                regex(pattern = r"^[a-z0-9]+(?:[-._:][a-z0-9]+)*$")
            )]
            String,
        );

        impl $name {
            #[doc = concat!("Creates a validated `", stringify!($name), "`.")]
            pub fn new(value: impl Into<String>) -> Result<Self, ContractError> {
                let value = value.into();
                validate_identifier($field, &value)?;
                Ok(Self(value))
            }

            /// Returns the identifier as a string slice.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consumes the identifier and returns its owned string.
            #[must_use]
            pub fn into_string(self) -> String {
                self.0
            }

            /// Revalidates an identifier obtained through deserialization.
            pub fn validate(&self) -> Result<(), ContractError> {
                validate_identifier($field, &self.0)
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: Deserializer<'de>,
            {
                deserialize_identifier(deserializer, $field).map(Self)
            }
        }
    };
}

define_identifier!(PluginId, "A stable plugin identifier.", "plugin_id");
define_identifier!(
    PublisherId,
    "A stable plugin publisher identifier.",
    "publisher_id"
);
define_identifier!(
    ContributionId,
    "A stable namespaced contribution identifier.",
    "contribution_id"
);
define_identifier!(
    RendererContractId,
    "A stable renderer contract identifier.",
    "renderer_contract_id"
);
define_identifier!(
    CapabilityId,
    "A stable capability identifier.",
    "capability_id"
);
define_identifier!(
    CorrelationId,
    "A host-issued request correlation identifier.",
    "correlation_id"
);
define_identifier!(
    OperationId,
    "A host-issued cancellable operation identifier.",
    "operation_id"
);
define_identifier!(
    GrantId,
    "A host-issued revocable grant identifier.",
    "grant_id"
);
define_identifier!(
    SecretRef,
    "An opaque host-owned secret reference.",
    "secret_ref"
);
define_identifier!(
    ProviderId,
    "A stable model provider identifier.",
    "provider_id"
);

/// A provider-specific model identifier whose ASCII spelling is preserved.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, JsonSchema)]
#[serde(transparent)]
pub struct ModelId(
    #[schemars(length(min = 1, max = 128), regex(pattern = r"^[A-Za-z0-9._:/-]+$"))] String,
);

impl ModelId {
    /// Creates a validated, case-preserving model identifier.
    pub fn new(value: impl Into<String>) -> Result<Self, ContractError> {
        let value = value.into();
        validate_model_id(&value)?;
        Ok(Self(value))
    }

    /// Returns the exact provider-specific identifier spelling.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consumes the identifier and returns its exact spelling.
    #[must_use]
    pub fn into_string(self) -> String {
        self.0
    }

    /// Revalidates a model identifier obtained from a trusted in-memory source.
    pub fn validate(&self) -> Result<(), ContractError> {
        validate_model_id(&self.0)
    }
}

impl<'de> Deserialize<'de> for ModelId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct ModelIdVisitor;

        impl Visitor<'_> for ModelIdVisitor {
            type Value = ModelId;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a bounded canonical model identifier")
            }

            fn visit_borrowed_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                validate_model_id(value).map_err(E::custom)?;
                Ok(ModelId(value.to_owned()))
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
                validate_model_id(&value).map_err(E::custom)?;
                Ok(ModelId(value))
            }
        }

        deserializer.deserialize_string(ModelIdVisitor)
    }
}

impl fmt::Display for ModelId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

fn validate_model_id(value: &str) -> Result<(), ContractError> {
    if value.is_empty() {
        return Err(ContractError::EmptyField { field: "model_id" });
    }
    if value.len() > MAX_IDENTIFIER_BYTES {
        return Err(ContractError::FieldTooLong {
            field: "model_id",
            max_bytes: MAX_IDENTIFIER_BYTES,
        });
    }
    if !value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'/' | b'-')
    }) {
        return Err(ContractError::InvalidIdentifier {
            field: "model_id",
            value: value.to_owned(),
        });
    }
    Ok(())
}

/// Validates a short, non-sensitive display label.
pub fn validate_label(field: &'static str, value: &str) -> Result<(), ContractError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(ContractError::EmptyField { field });
    }
    if trimmed.len() > MAX_LABEL_BYTES {
        return Err(ContractError::FieldTooLong {
            field,
            max_bytes: MAX_LABEL_BYTES,
        });
    }
    Ok(())
}

/// Validates an optional non-sensitive description.
pub fn validate_description(field: &'static str, value: Option<&str>) -> Result<(), ContractError> {
    if value.is_some_and(|description| description.len() > MAX_DESCRIPTION_BYTES) {
        return Err(ContractError::FieldTooLong {
            field,
            max_bytes: MAX_DESCRIPTION_BYTES,
        });
    }
    Ok(())
}

/// Validates a bounded machine-readable token suitable for diagnostics.
///
/// Safe tokens intentionally exclude whitespace, free-form prose, paths, and
/// common credential markers. Rejected values are never echoed in the error.
pub fn validate_safe_token(field: &'static str, value: &str) -> Result<(), ContractError> {
    const SENSITIVE_MARKERS: [&str; 12] = [
        "api-key",
        "api_key",
        "authorization",
        "bearer",
        "credential",
        "password",
        "payload",
        "prompt",
        "response",
        "secret",
        "token",
        "body",
    ];

    let valid_shape = !value.is_empty()
        && value.len() <= MAX_SAFE_TOKEN_BYTES
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '-' | '.' | '_' | ':')
        });
    let sensitive = SENSITIVE_MARKERS
        .iter()
        .any(|marker| value.contains(marker))
        || value.starts_with("sk-")
        || value.starts_with("ghp_")
        || value.starts_with("github_pat_")
        || value.starts_with("eyj");
    if !valid_shape || sensitive {
        return Err(ContractError::UnsafeStringValue { field });
    }
    Ok(())
}

fn validate_identifier(field: &'static str, value: &str) -> Result<(), ContractError> {
    if value.is_empty() {
        return Err(ContractError::EmptyField { field });
    }
    if value.len() > MAX_IDENTIFIER_BYTES {
        return Err(ContractError::FieldTooLong {
            field,
            max_bytes: MAX_IDENTIFIER_BYTES,
        });
    }

    let mut previous_was_separator = false;
    for (index, character) in value.chars().enumerate() {
        let separator = matches!(character, '-' | '.' | '_' | ':');
        let valid = character.is_ascii_lowercase() || character.is_ascii_digit() || separator;
        if !valid || (separator && (index == 0 || previous_was_separator)) {
            return Err(ContractError::InvalidIdentifier {
                field,
                value: value.to_owned(),
            });
        }
        previous_was_separator = separator;
    }
    if previous_was_separator {
        return Err(ContractError::InvalidIdentifier {
            field,
            value: value.to_owned(),
        });
    }
    Ok(())
}

fn deserialize_identifier<'de, D>(deserializer: D, field: &'static str) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    struct IdentifierVisitor {
        field: &'static str,
    }

    impl Visitor<'_> for IdentifierVisitor {
        type Value = String;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("a bounded canonical lowercase identifier")
        }

        fn visit_borrowed_str<E>(self, value: &str) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            validate_identifier(self.field, value).map_err(E::custom)?;
            Ok(value.to_owned())
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
            validate_identifier(self.field, &value).map_err(E::custom)?;
            Ok(value)
        }
    }

    deserializer.deserialize_string(IdentifierVisitor { field })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifier_constructor_and_accessors_work() {
        let id = PluginId::new("wellorbetter.timetrace").expect("valid id");
        assert_eq!(id.as_str(), "wellorbetter.timetrace");
        assert_eq!(id.clone().into_string(), "wellorbetter.timetrace");
        assert!(id.validate().is_ok());
    }

    #[test]
    fn identifier_rejects_bad_separators_and_case() {
        assert!(PluginId::new("Bad.Plugin").is_err());
        assert!(PluginId::new("bad..plugin").is_err());
        assert!(PluginId::new("bad-").is_err());
        assert!(serde_json::from_str::<PluginId>(r#""Bad.Plugin""#).is_err());
        assert!(serde_json::from_str::<PluginId>(r#""bad..plugin""#).is_err());
        assert!(serde_json::from_str::<ProviderId>(r#""""#).is_err());
        assert!(serde_json::from_value::<OperationId>(serde_json::json!("x".repeat(129))).is_err());
        let huge = format!("\"{}\"", "x".repeat(10 * 1_024 * 1_024));
        assert!(serde_json::from_str::<ProviderId>(&huge).is_err());
    }

    #[test]
    fn model_id_preserves_case_and_rejects_non_ascii_or_unsafe_characters() {
        let id = ModelId::new("OpenAI/gpt-4.1:Latest").expect("valid model id");
        assert_eq!(id.as_str(), "OpenAI/gpt-4.1:Latest");
        assert!(ModelId::new("model?query=true").is_err());
        assert!(ModelId::new("模型").is_err());
        assert!(ModelId::new("x".repeat(MAX_IDENTIFIER_BYTES + 1)).is_err());
        assert!(serde_json::from_str::<ModelId>(r#""bad model""#).is_err());
    }

    #[test]
    fn scalar_size_estimate_is_bounded_and_deterministic() {
        assert_eq!(ScalarValue::Boolean(true).estimated_size_bytes(), 1);
        assert_eq!(ScalarValue::Integer(-1).estimated_size_bytes(), 20);
        assert_eq!(
            ScalarValue::String("abc".to_owned()).estimated_size_bytes(),
            3
        );
    }

    #[test]
    fn label_and_description_validation_enforce_limits() {
        assert!(validate_label("title", "TimeTrace").is_ok());
        assert!(validate_label("title", " ").is_err());
        assert!(validate_description("description", Some("safe")).is_ok());
        assert!(validate_description("description", Some(&"x".repeat(2_049))).is_err());
    }

    #[test]
    fn safe_tokens_reject_prose_and_credential_markers() {
        assert!(validate_safe_token("status", "request-failed").is_ok());
        assert!(validate_safe_token("status", "request failed").is_err());
        assert!(validate_safe_token("status", "sk-privatevalue").is_err());
        assert!(validate_safe_token("status", "provider-response").is_err());
    }
}
