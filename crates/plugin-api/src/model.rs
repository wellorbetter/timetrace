//! Canonical host-owned model broker request, preview, and event DTOs.

use std::{collections::BTreeSet, fmt, net::IpAddr};

use schemars::JsonSchema;
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{DeserializeOwned, SeqAccess, Visitor},
};

use crate::{
    ContractError, DateRange, DurationMillis, ModelId, OperationId, ProviderId,
    validate_exact_domain,
};

/// Maximum inclusive date range accepted by a model request.
pub const MAX_MODEL_RANGE_DAYS: u16 = 7;
/// Maximum aggregate fields accepted by a model request.
pub const MAX_TRANSFER_FIELDS: usize = 6;
/// Maximum aggregate rows represented by a transfer preview.
pub const MAX_TRANSFER_ROWS: u32 = 10_000;
/// Maximum exact serialized payload size represented by a preview.
pub const MAX_MODEL_PAYLOAD_BYTES: u32 = 256 * 1_024;
/// Maximum model identifier byte length.
pub const MAX_MODEL_ID_BYTES: usize = 128;
/// Maximum endpoint base-path byte length.
pub const MAX_MODEL_BASE_PATH_BYTES: usize = 256;
/// Maximum UTF-8 bytes in one streamed model delta.
pub const MAX_MODEL_DELTA_BYTES: usize = 8_192;
/// Maximum input-token usage reported by a completed model operation.
pub const MAX_MODEL_INPUT_TOKENS: u32 = 262_144;
/// Maximum output-token usage reported by a completed model operation.
pub const MAX_MODEL_OUTPUT_TOKENS: u32 = 4_096;
/// Maximum upper bound accepted in a preview token estimate.
pub const MAX_TOKEN_ESTIMATE: u32 = 262_144;
/// Maximum untrusted JSON bytes accepted for one model request draft.
pub const MAX_MODEL_DRAFT_JSON_BYTES: usize = 4 * 1_024;
/// Maximum untrusted JSON bytes accepted for one transfer preview.
pub const MAX_MODEL_PREVIEW_JSON_BYTES: usize = 16 * 1_024;
/// Maximum untrusted JSON bytes accepted for one streamed model event.
pub const MAX_MODEL_EVENT_JSON_BYTES: usize = 16 * 1_024;
/// Maximum cumulative UTF-8 output bytes accepted for one model stream.
pub const MAX_MODEL_OUTPUT_BYTES: usize = 512 * 1_024;
/// Maximum number of events accepted for one model stream.
pub const MAX_MODEL_STREAM_EVENTS: usize = 1_024;

/// Privacy-safe failure returned by bounded model JSON codecs.
#[derive(Debug, thiserror::Error)]
pub enum ModelJsonError {
    /// The raw frame exceeded its cap before JSON deserialization began.
    #[error("model JSON frame exceeds its {limit}-byte limit")]
    FrameTooLarge {
        /// Maximum accepted raw UTF-8 bytes.
        limit: usize,
    },
    /// JSON syntax or canonical model validation failed.
    #[error("invalid model JSON contract")]
    InvalidContract(#[source] serde_json::Error),
    /// Canonical JSON decoded but violated a semantic model invariant.
    #[error("invalid model JSON contract")]
    InvalidValue(#[source] ContractError),
}

/// Whether a model endpoint is local to the device or external.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ModelLocality {
    /// A loopback endpoint that does not transfer data off the device.
    Local,
    /// An external TLS endpoint requiring explicit transfer confirmation.
    Cloud,
}

/// Aggregate-only fields eligible for model transfer in P0.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum TransferField {
    /// Inclusive aggregate date range.
    DateRange,
    /// Aggregate calendar date.
    UsageDate,
    /// Normalized application display identifier.
    AppDisplayId,
    /// Normalized application display name.
    AppDisplayName,
    /// Aggregate tracked duration.
    Duration,
    /// Hour-of-day aggregate bucket.
    HourBucket,
}

/// A plugin's transport-neutral request for host-owned model inference.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ModelRequestDraft {
    provider_id: ProviderId,
    date_range: DateRange,
    #[schemars(with = "BTreeSet<TransferField>", length(min = 1, max = 6))]
    fields: Vec<TransferField>,
}

impl ModelRequestDraft {
    /// Creates a validated model request draft.
    pub fn new(
        provider_id: ProviderId,
        date_range: DateRange,
        fields: Vec<TransferField>,
    ) -> Result<Self, ContractError> {
        let value = Self {
            provider_id,
            date_range,
            fields,
        };
        value.validate_basic()?;
        Ok(value)
    }

    /// Decodes a draft only after enforcing the raw 4 KiB frame cap.
    pub fn from_json_bytes(input: &[u8]) -> Result<Self, ModelJsonError> {
        let wire: ModelRequestDraftWire = decode_bounded_json(input, MAX_MODEL_DRAFT_JSON_BYTES)?;
        wire.into_validated().map_err(ModelJsonError::InvalidValue)
    }

    /// Returns the configured provider identifier.
    #[must_use]
    pub fn provider_id(&self) -> &ProviderId {
        &self.provider_id
    }

    /// Returns the requested inclusive aggregate date range.
    #[must_use]
    pub fn date_range(&self) -> DateRange {
        self.date_range
    }

    /// Returns the exact ordered aggregate field selection.
    #[must_use]
    pub fn fields(&self) -> &[TransferField] {
        &self.fields
    }

    /// Validates provider identity, date range, and transfer field shape.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.provider_id.validate()?;
        self.date_range.validate(MAX_MODEL_RANGE_DAYS)?;
        validate_transfer_fields(&self.fields)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelRequestDraftWire {
    provider_id: ProviderId,
    date_range: DateRange,
    fields: BoundedTransferFields,
}

impl ModelRequestDraftWire {
    fn into_validated(self) -> Result<ModelRequestDraft, ContractError> {
        ModelRequestDraft::new(self.provider_id, self.date_range, self.fields.into_inner())
    }
}

/// An estimated token-count interval shown before transfer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TokenEstimate {
    #[schemars(range(max = 262144))]
    minimum: u32,
    #[schemars(range(max = 262144))]
    maximum: u32,
}

impl TokenEstimate {
    /// Creates an ordered, bounded token estimate.
    pub fn new(minimum: u32, maximum: u32) -> Result<Self, ContractError> {
        let value = Self { minimum, maximum };
        value.validate_basic()?;
        Ok(value)
    }

    /// Returns the lower token estimate.
    #[must_use]
    pub fn minimum(&self) -> u32 {
        self.minimum
    }

    /// Returns the conservative upper token estimate.
    #[must_use]
    pub fn maximum(&self) -> u32 {
        self.maximum
    }

    /// Validates estimate ordering and the canonical upper bound.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.maximum < self.minimum {
            return Err(ContractError::InvalidRange {
                field: "token_estimate",
            });
        }
        if self.maximum > MAX_TOKEN_ESTIMATE {
            return Err(ContractError::LimitExceeded {
                field: "token_estimate",
                limit: u64::from(MAX_TOKEN_ESTIMATE),
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TokenEstimateWire {
    minimum: u32,
    maximum: u32,
}

impl<'de> Deserialize<'de> for TokenEstimate {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = TokenEstimateWire::deserialize(deserializer)?;
        Self::new(wire.minimum, wire.maximum).map_err(<D::Error as serde::de::Error>::custom)
    }
}

/// Exact aggregate-shape summary displayed before model transfer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AggregateTransferSummary {
    #[schemars(range(max = 10000))]
    daily_rows: u32,
    #[schemars(range(max = 10000))]
    application_rows: u32,
    #[schemars(range(max = 10000))]
    hourly_rows: u32,
    tracked_duration: DurationMillis,
}

impl AggregateTransferSummary {
    /// Creates a summary whose combined aggregate row count is bounded.
    pub fn new(
        daily_rows: u32,
        application_rows: u32,
        hourly_rows: u32,
        tracked_duration: DurationMillis,
    ) -> Result<Self, ContractError> {
        let value = Self {
            daily_rows,
            application_rows,
            hourly_rows,
            tracked_duration,
        };
        value.validate_basic()?;
        Ok(value)
    }

    /// Returns the number of daily aggregate rows.
    #[must_use]
    pub fn daily_rows(&self) -> u32 {
        self.daily_rows
    }

    /// Returns the number of application aggregate rows.
    #[must_use]
    pub fn application_rows(&self) -> u32 {
        self.application_rows
    }

    /// Returns the number of hourly aggregate rows.
    #[must_use]
    pub fn hourly_rows(&self) -> u32 {
        self.hourly_rows
    }

    /// Returns the total tracked duration represented by the payload.
    #[must_use]
    pub fn tracked_duration(&self) -> DurationMillis {
        self.tracked_duration
    }

    /// Returns the combined number of aggregate rows.
    #[must_use]
    pub fn total_rows(&self) -> u32 {
        self.daily_rows
            .saturating_add(self.application_rows)
            .saturating_add(self.hourly_rows)
    }

    /// Validates the combined canonical aggregate-row bound.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.total_rows() > MAX_TRANSFER_ROWS {
            return Err(ContractError::LimitExceeded {
                field: "transfer_summary_rows",
                limit: u64::from(MAX_TRANSFER_ROWS),
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AggregateTransferSummaryWire {
    daily_rows: u32,
    application_rows: u32,
    hourly_rows: u32,
    tracked_duration: DurationMillis,
}

impl<'de> Deserialize<'de> for AggregateTransferSummary {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = AggregateTransferSummaryWire::deserialize(deserializer)?;
        Self::new(
            wire.daily_rows,
            wire.application_rows,
            wire.hourly_rows,
            wire.tracked_duration,
        )
        .map_err(<D::Error as serde::de::Error>::custom)
    }
}

/// Exact, privacy-facing transfer preview produced by the host.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TransferPreview {
    operation_id: OperationId,
    provider_id: ProviderId,
    model_id: ModelId,
    #[schemars(length(min = 1, max = 253))]
    endpoint_domain: String,
    #[schemars(range(min = 1, max = 65535))]
    endpoint_port: u16,
    #[schemars(length(min = 1, max = 256))]
    endpoint_base_path: String,
    locality: ModelLocality,
    date_range: DateRange,
    #[schemars(with = "BTreeSet<TransferField>", length(min = 1, max = 6))]
    fields: Vec<TransferField>,
    summary: AggregateTransferSummary,
    #[schemars(range(min = 1, max = 262144))]
    payload_bytes: u32,
    estimated_tokens: TokenEstimate,
}

impl TransferPreview {
    /// Creates an exact, validated host transfer preview.
    #[allow(
        clippy::too_many_arguments,
        reason = "mirrors the frozen wire contract"
    )]
    pub fn new(
        operation_id: OperationId,
        provider_id: ProviderId,
        model_id: ModelId,
        endpoint_domain: impl Into<String>,
        endpoint_port: u16,
        endpoint_base_path: impl Into<String>,
        locality: ModelLocality,
        date_range: DateRange,
        fields: Vec<TransferField>,
        summary: AggregateTransferSummary,
        payload_bytes: u32,
        estimated_tokens: TokenEstimate,
    ) -> Result<Self, ContractError> {
        let value = Self {
            operation_id,
            provider_id,
            model_id,
            endpoint_domain: endpoint_domain.into(),
            endpoint_port,
            endpoint_base_path: endpoint_base_path.into(),
            locality,
            date_range,
            fields,
            summary,
            payload_bytes,
            estimated_tokens,
        };
        value.validate_basic()?;
        Ok(value)
    }

    /// Decodes a preview only after enforcing the raw 16 KiB frame cap.
    pub fn from_json_bytes(input: &[u8]) -> Result<Self, ModelJsonError> {
        let wire: TransferPreviewWire = decode_bounded_json(input, MAX_MODEL_PREVIEW_JSON_BYTES)?;
        wire.into_validated().map_err(ModelJsonError::InvalidValue)
    }

    /// Encodes a preview and rechecks the 16 KiB publication cap.
    pub fn to_json(&self) -> Result<String, ModelJsonError> {
        let json = serde_json::to_string(self).map_err(ModelJsonError::InvalidContract)?;
        if json.len() > MAX_MODEL_PREVIEW_JSON_BYTES {
            return Err(ModelJsonError::FrameTooLarge {
                limit: MAX_MODEL_PREVIEW_JSON_BYTES,
            });
        }
        Ok(json)
    }

    /// Returns the host-issued operation identifier.
    #[must_use]
    pub fn operation_id(&self) -> &OperationId {
        &self.operation_id
    }

    /// Returns the configured provider identifier.
    #[must_use]
    pub fn provider_id(&self) -> &ProviderId {
        &self.provider_id
    }

    /// Returns the exact provider-specific model identifier.
    #[must_use]
    pub fn model_id(&self) -> &ModelId {
        &self.model_id
    }

    /// Returns the exact endpoint domain or loopback literal.
    #[must_use]
    pub fn endpoint_domain(&self) -> &str {
        &self.endpoint_domain
    }

    /// Returns the endpoint TCP port.
    #[must_use]
    pub fn endpoint_port(&self) -> u16 {
        self.endpoint_port
    }

    /// Returns the endpoint base path without query or fragment data.
    #[must_use]
    pub fn endpoint_base_path(&self) -> &str {
        &self.endpoint_base_path
    }

    /// Returns the endpoint locality classification.
    #[must_use]
    pub fn locality(&self) -> ModelLocality {
        self.locality
    }

    /// Returns the inclusive aggregate date range represented by the payload.
    #[must_use]
    pub fn date_range(&self) -> DateRange {
        self.date_range
    }

    /// Returns the exact ordered aggregate field selection.
    #[must_use]
    pub fn fields(&self) -> &[TransferField] {
        &self.fields
    }

    /// Returns the exact aggregate-shape summary.
    #[must_use]
    pub fn summary(&self) -> AggregateTransferSummary {
        self.summary
    }

    /// Returns the exact serialized payload byte count.
    #[must_use]
    pub fn payload_bytes(&self) -> u32 {
        self.payload_bytes
    }

    /// Returns the bounded token estimate.
    #[must_use]
    pub fn estimated_tokens(&self) -> TokenEstimate {
        self.estimated_tokens
    }

    /// Validates all identities, endpoint fields, aggregate shape, and bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.operation_id.validate()?;
        self.provider_id.validate()?;
        self.model_id.validate()?;
        validate_model_endpoint(&self.endpoint_domain, self.endpoint_port, self.locality)?;
        validate_base_path(&self.endpoint_base_path)?;
        self.date_range.validate(MAX_MODEL_RANGE_DAYS)?;
        validate_transfer_fields(&self.fields)?;
        self.summary.validate_basic()?;
        self.estimated_tokens.validate_basic()?;
        if self.payload_bytes == 0 || self.payload_bytes > MAX_MODEL_PAYLOAD_BYTES {
            return Err(ContractError::LimitExceeded {
                field: "model_payload_bytes",
                limit: u64::from(MAX_MODEL_PAYLOAD_BYTES),
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TransferPreviewWire {
    operation_id: OperationId,
    provider_id: ProviderId,
    model_id: ModelId,
    endpoint_domain: String,
    endpoint_port: u16,
    endpoint_base_path: String,
    locality: ModelLocality,
    date_range: DateRange,
    fields: BoundedTransferFields,
    summary: AggregateTransferSummary,
    payload_bytes: u32,
    estimated_tokens: TokenEstimate,
}

impl TransferPreviewWire {
    fn into_validated(self) -> Result<TransferPreview, ContractError> {
        TransferPreview::new(
            self.operation_id,
            self.provider_id,
            self.model_id,
            self.endpoint_domain,
            self.endpoint_port,
            self.endpoint_base_path,
            self.locality,
            self.date_range,
            self.fields.into_inner(),
            self.summary,
            self.payload_bytes,
            self.estimated_tokens,
        )
    }
}

/// Bounded provider usage returned after inference.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ModelUsage {
    #[schemars(range(max = 262144))]
    input_tokens: u32,
    #[schemars(range(max = 4096))]
    output_tokens: u32,
}

impl ModelUsage {
    /// Creates bounded completed-operation usage.
    pub fn new(input_tokens: u32, output_tokens: u32) -> Result<Self, ContractError> {
        let value = Self {
            input_tokens,
            output_tokens,
        };
        value.validate_basic()?;
        Ok(value)
    }

    /// Returns input-token usage.
    #[must_use]
    pub fn input_tokens(&self) -> u32 {
        self.input_tokens
    }

    /// Returns output-token usage.
    #[must_use]
    pub fn output_tokens(&self) -> u32 {
        self.output_tokens
    }

    /// Validates canonical completed-operation usage bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.input_tokens > MAX_MODEL_INPUT_TOKENS {
            return Err(ContractError::LimitExceeded {
                field: "model_input_tokens",
                limit: u64::from(MAX_MODEL_INPUT_TOKENS),
            });
        }
        if self.output_tokens > MAX_MODEL_OUTPUT_TOKENS {
            return Err(ContractError::LimitExceeded {
                field: "model_output_tokens",
                limit: u64::from(MAX_MODEL_OUTPUT_TOKENS),
            });
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelUsageWire {
    input_tokens: u32,
    output_tokens: u32,
}

impl<'de> Deserialize<'de> for ModelUsage {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = ModelUsageWire::deserialize(deserializer)?;
        Self::new(wire.input_tokens, wire.output_tokens)
            .map_err(<D::Error as serde::de::Error>::custom)
    }
}

/// Stable privacy-safe model failure classes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ModelFailureCode {
    /// The host rejected the canonical model request.
    InvalidRequest,
    /// Provider credentials were absent or rejected.
    AuthenticationFailed,
    /// The provider rate-limited the operation.
    RateLimited,
    /// The provider endpoint was unavailable.
    ProviderUnavailable,
    /// The provider exceeded the host deadline.
    Timeout,
    /// The operation was cancelled by the host or caller.
    Cancelled,
    /// The provider returned an invalid bounded response.
    InvalidResponse,
    /// A non-provider host failure ended the operation.
    Internal,
}

/// Streaming model events delivered to the requesting plugin surface.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
pub enum ModelEvent {
    /// The provider request has started.
    Started,
    /// A bounded response text fragment; this value must never enter diagnostics.
    Delta {
        /// Incremental model response text.
        #[schemars(length(min = 1, max = 8192))]
        text: String,
    },
    /// The provider stream completed successfully.
    Completed {
        /// Bounded provider usage.
        usage: ModelUsage,
    },
    /// The provider stream ended with a stable safe error class.
    Failed {
        /// Stable failure code without provider response bodies.
        code: ModelFailureCode,
        /// Whether retrying may succeed without changing the draft.
        retryable: bool,
    },
}

impl ModelEvent {
    /// Creates a started event.
    #[must_use]
    pub fn started() -> Self {
        Self::Started
    }

    /// Decodes one event only after enforcing the raw 16 KiB frame cap.
    pub fn from_json_bytes(input: &[u8]) -> Result<Self, ModelJsonError> {
        let wire: ModelEventWire = decode_bounded_json(input, MAX_MODEL_EVENT_JSON_BYTES)?;
        wire.into_validated().map_err(ModelJsonError::InvalidValue)
    }

    /// Creates a validated bounded delta event.
    pub fn delta(text: impl Into<String>) -> Result<Self, ContractError> {
        let value = Self::Delta { text: text.into() };
        value.validate_basic()?;
        Ok(value)
    }

    /// Creates a validated completion event.
    pub fn completed(usage: ModelUsage) -> Result<Self, ContractError> {
        let value = Self::Completed { usage };
        value.validate_basic()?;
        Ok(value)
    }

    /// Creates a privacy-safe failure event.
    #[must_use]
    pub fn failed(code: ModelFailureCode, retryable: bool) -> Self {
        Self::Failed { code, retryable }
    }

    /// Returns delta text only for a delta event.
    #[must_use]
    pub fn delta_text(&self) -> Option<&str> {
        match self {
            Self::Delta { text } => Some(text),
            _ => None,
        }
    }

    /// Returns usage only for a completed event.
    #[must_use]
    pub fn usage(&self) -> Option<ModelUsage> {
        match self {
            Self::Completed { usage } => Some(*usage),
            _ => None,
        }
    }

    /// Returns failure metadata only for a failed event.
    #[must_use]
    pub fn failure(&self) -> Option<(ModelFailureCode, bool)> {
        match self {
            Self::Failed { code, retryable } => Some((*code, *retryable)),
            _ => None,
        }
    }

    /// Validates event-specific payload bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        match self {
            Self::Started | Self::Failed { .. } => Ok(()),
            Self::Delta { text } => {
                if text.is_empty() {
                    return Err(ContractError::EmptyField {
                        field: "model_delta",
                    });
                }
                if text.len() > MAX_MODEL_DELTA_BYTES {
                    return Err(ContractError::FieldTooLong {
                        field: "model_delta",
                        max_bytes: MAX_MODEL_DELTA_BYTES,
                    });
                }
                Ok(())
            }
            Self::Completed { usage } => usage.validate_basic(),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "event", rename_all = "snake_case", deny_unknown_fields)]
enum ModelEventWire {
    Started {},
    Delta {
        text: BoundedDelta,
    },
    Completed {
        usage: ModelUsage,
    },
    Failed {
        code: ModelFailureCode,
        retryable: bool,
    },
}

impl ModelEventWire {
    fn into_validated(self) -> Result<ModelEvent, ContractError> {
        match self {
            Self::Started {} => Ok(ModelEvent::started()),
            Self::Delta { text } => ModelEvent::delta(text.into_inner()),
            Self::Completed { usage } => ModelEvent::completed(usage),
            Self::Failed { code, retryable } => Ok(ModelEvent::failed(code, retryable)),
        }
    }
}

struct BoundedTransferFields(Vec<TransferField>);

impl BoundedTransferFields {
    fn into_inner(self) -> Vec<TransferField> {
        self.0
    }
}

impl<'de> Deserialize<'de> for BoundedTransferFields {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct FieldsVisitor;

        impl<'de> Visitor<'de> for FieldsVisitor {
            type Value = BoundedTransferFields;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("at most six canonical transfer fields")
            }

            fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
            where
                A: SeqAccess<'de>,
            {
                let mut fields =
                    Vec::with_capacity(sequence.size_hint().unwrap_or(0).min(MAX_TRANSFER_FIELDS));
                while let Some(field) = sequence.next_element()? {
                    if fields.len() == MAX_TRANSFER_FIELDS {
                        return Err(<A::Error as serde::de::Error>::invalid_length(
                            MAX_TRANSFER_FIELDS + 1,
                            &self,
                        ));
                    }
                    fields.push(field);
                }
                Ok(BoundedTransferFields(fields))
            }
        }

        deserializer.deserialize_seq(FieldsVisitor)
    }
}

struct BoundedDelta(String);

impl BoundedDelta {
    fn checked(value: String) -> Result<Self, &'static str> {
        if value.is_empty() {
            return Err("model delta must not be empty");
        }
        if value.len() > MAX_MODEL_DELTA_BYTES {
            return Err("model delta exceeds its byte limit");
        }
        Ok(Self(value))
    }

    fn into_inner(self) -> String {
        self.0
    }
}

impl<'de> Deserialize<'de> for BoundedDelta {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct DeltaVisitor;

        impl Visitor<'_> for DeltaVisitor {
            type Value = BoundedDelta;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a non-empty model delta of at most 8192 UTF-8 bytes")
            }

            fn visit_borrowed_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                if value.is_empty() || value.len() > MAX_MODEL_DELTA_BYTES {
                    return Err(E::invalid_length(value.len(), &self));
                }
                Ok(BoundedDelta(value.to_owned()))
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
                BoundedDelta::checked(value).map_err(E::custom)
            }
        }

        deserializer.deserialize_string(DeltaVisitor)
    }
}

fn decode_bounded_json<T>(input: &[u8], limit: usize) -> Result<T, ModelJsonError>
where
    T: DeserializeOwned,
{
    if input.len() > limit {
        return Err(ModelJsonError::FrameTooLarge { limit });
    }
    serde_json::from_slice(input).map_err(ModelJsonError::InvalidContract)
}

fn validate_transfer_fields(fields: &[TransferField]) -> Result<(), ContractError> {
    if fields.is_empty() {
        return Err(ContractError::EmptyField {
            field: "transfer_fields",
        });
    }
    if fields.len() > MAX_TRANSFER_FIELDS {
        return Err(ContractError::LimitExceeded {
            field: "transfer_fields",
            limit: MAX_TRANSFER_FIELDS as u64,
        });
    }
    let unique = fields.iter().copied().collect::<BTreeSet<_>>();
    if unique.len() != fields.len() {
        return Err(ContractError::DuplicateIdentifier {
            field: "transfer_fields",
            value: "duplicate".to_owned(),
        });
    }
    if !unique.contains(&TransferField::DateRange) || !unique.contains(&TransferField::Duration) {
        return Err(ContractError::InvalidContribution {
            field: "required_transfer_fields",
        });
    }
    let has_aggregate_dimension = unique.contains(&TransferField::UsageDate)
        || unique.contains(&TransferField::AppDisplayId)
        || unique.contains(&TransferField::AppDisplayName)
        || unique.contains(&TransferField::HourBucket);
    if !has_aggregate_dimension {
        return Err(ContractError::InvalidContribution {
            field: "transfer_dimension",
        });
    }
    Ok(())
}

fn validate_model_endpoint(
    domain: &str,
    port: u16,
    locality: ModelLocality,
) -> Result<(), ContractError> {
    if port == 0 {
        return Err(ContractError::InvalidRange {
            field: "model_port",
        });
    }
    let parsed_address = domain.parse::<IpAddr>().ok();
    let canonical_loopback = domain == "localhost"
        || parsed_address
            .as_ref()
            .is_some_and(|address| address.is_loopback() && address.to_string() == domain);
    match locality {
        ModelLocality::Local if canonical_loopback => Ok(()),
        ModelLocality::Local => Err(ContractError::InvalidDomain {
            domain: domain.to_owned(),
        }),
        ModelLocality::Cloud
            if parsed_address.is_some() || domain == "localhost" || port != 443 =>
        {
            Err(ContractError::InvalidContribution {
                field: "cloud_endpoint",
            })
        }
        ModelLocality::Cloud => validate_exact_domain(domain),
    }
}

fn validate_base_path(base_path: &str) -> Result<(), ContractError> {
    if base_path.is_empty() {
        return Err(ContractError::EmptyField {
            field: "model_base_path",
        });
    }
    if base_path.len() > MAX_MODEL_BASE_PATH_BYTES {
        return Err(ContractError::FieldTooLong {
            field: "model_base_path",
            max_bytes: MAX_MODEL_BASE_PATH_BYTES,
        });
    }
    let valid_ascii = base_path.bytes().all(|byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'~' | b'/' | b'-')
    });
    if !base_path.starts_with('/')
        || !valid_ascii
        || base_path.contains("//")
        || base_path.split('/').any(is_dot_segment)
        || (base_path != "/" && base_path.ends_with('/'))
    {
        return Err(ContractError::InvalidContribution {
            field: "model_base_path",
        });
    }
    Ok(())
}

fn is_dot_segment(segment: &str) -> bool {
    matches!(segment, "." | "..")
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;

    use super::*;

    fn range(days: u32) -> DateRange {
        DateRange {
            start: NaiveDate::from_ymd_opt(2026, 8, 1).expect("valid date"),
            end: NaiveDate::from_ymd_opt(2026, 8, days).expect("valid date"),
        }
    }

    fn fields() -> Vec<TransferField> {
        vec![
            TransferField::DateRange,
            TransferField::UsageDate,
            TransferField::Duration,
        ]
    }

    fn summary() -> AggregateTransferSummary {
        AggregateTransferSummary::new(7, 0, 0, DurationMillis(60_000)).expect("valid summary")
    }

    fn preview(locality: ModelLocality, domain: &str, port: u16) -> TransferPreview {
        TransferPreview::new(
            OperationId::new("operation-1").expect("operation"),
            ProviderId::new("openai-compatible").expect("provider"),
            ModelId::new("OpenAI/gpt-4.1").expect("model"),
            domain,
            port,
            "/v1/responses",
            locality,
            range(7),
            fields(),
            summary(),
            1_024,
            TokenEstimate::new(100, 200).expect("estimate"),
        )
        .expect("valid preview")
    }

    #[test]
    fn draft_has_only_plugin_selectable_fields_and_strict_validated_wire() {
        let draft = ModelRequestDraft::new(
            ProviderId::new("openai-compatible").expect("provider"),
            range(7),
            fields(),
        )
        .expect("draft");
        let value = serde_json::to_value(&draft).expect("serialize");
        assert_eq!(value.as_object().expect("object").len(), 3);
        assert!(value.get("operation_id").is_none());
        assert_eq!(draft.date_range(), range(7));

        let mut unknown = value.clone();
        unknown["secret_ref"] = serde_json::json!("vault-secret");
        assert!(
            ModelRequestDraft::from_json_bytes(
                &serde_json::to_vec(&unknown).expect("unknown draft JSON")
            )
            .is_err()
        );
        assert!(
            ModelRequestDraft::new(
                ProviderId::new("openai-compatible").expect("provider"),
                range(8),
                fields(),
            )
            .is_err()
        );

        let seventh_field = br#"{
            "provider_id":"local-model",
            "date_range":{"start":"2026-08-01","end":"2026-08-01"},
            "fields":["date_range","usage_date","app_display_id","app_display_name","duration","hour_bucket","duration"]
        }"#;
        assert!(matches!(
            ModelRequestDraft::from_json_bytes(seventh_field),
            Err(ModelJsonError::InvalidContract(_))
        ));
    }

    #[test]
    fn fields_require_shape_fields_and_reject_duplicates() {
        let provider = ProviderId::new("local-model").expect("provider");
        assert!(
            ModelRequestDraft::new(
                provider.clone(),
                range(1),
                vec![TransferField::UsageDate, TransferField::Duration],
            )
            .is_err()
        );
        assert!(
            ModelRequestDraft::new(
                provider.clone(),
                range(1),
                vec![TransferField::DateRange, TransferField::Duration],
            )
            .is_err()
        );
        assert!(
            ModelRequestDraft::new(
                provider,
                range(1),
                vec![
                    TransferField::DateRange,
                    TransferField::UsageDate,
                    TransferField::Duration,
                    TransferField::Duration,
                ],
            )
            .is_err()
        );
    }

    #[test]
    fn preview_validates_endpoint_path_and_privacy_shape() {
        let cloud = preview(ModelLocality::Cloud, "api.example.com", 443);
        assert_eq!(cloud.model_id().as_str(), "OpenAI/gpt-4.1");
        assert_eq!(cloud.payload_bytes(), 1_024);
        assert!(
            serde_json::to_string(&cloud)
                .expect("json")
                .contains("payload_bytes")
        );
        assert!(
            !serde_json::to_string(&cloud)
                .expect("json")
                .contains("digest")
        );
        assert!(
            preview(ModelLocality::Local, "127.0.0.2", 11434)
                .validate_basic()
                .is_ok()
        );

        assert!(validate_model_endpoint("localhost", 443, ModelLocality::Cloud).is_err());
        assert!(validate_model_endpoint("api.example.com", 443, ModelLocality::Local).is_err());
        assert!(validate_model_endpoint("api.example.com", 80, ModelLocality::Cloud).is_err());
        for invalid_cloud in ["8.8.8.8", "2001:db8::1", "::1", "localhost"] {
            assert!(
                validate_model_endpoint(invalid_cloud, 443, ModelLocality::Cloud).is_err(),
                "accepted cloud address {invalid_cloud}"
            );
        }
        for invalid_local in ["LOCALHOST", "127.000.0.1", "0:0:0:0:0:0:0:1", "192.168.1.1"] {
            assert!(
                validate_model_endpoint(invalid_local, 11434, ModelLocality::Local).is_err(),
                "accepted local address {invalid_local}"
            );
        }
        for invalid in [
            "v1",
            "/v1/",
            "/v 1/chat",
            "/v1/\u{6a21}\u{578b}",
            "/v1?key=x",
            "/v1#fragment",
            "/user@host",
            "/v1//chat",
            "/v1/../chat",
            "/v1/%2e/chat",
            "/v1/%252e/chat",
        ] {
            assert!(validate_base_path(invalid).is_err(), "accepted {invalid}");
        }
    }

    #[test]
    fn preview_nested_bounds_fail_during_deserialization() {
        assert!(AggregateTransferSummary::new(5_000, 5_000, 1, DurationMillis(1)).is_err());
        assert!(TokenEstimate::new(10, MAX_TOKEN_ESTIMATE + 1).is_err());
        assert!(ModelUsage::new(MAX_MODEL_INPUT_TOKENS + 1, 0).is_err());

        let mut value = serde_json::to_value(preview(ModelLocality::Cloud, "api.example.com", 443))
            .expect("preview JSON");
        value["summary"]["extra"] = serde_json::json!(true);
        assert!(
            TransferPreview::from_json_bytes(&serde_json::to_vec(&value).expect("preview JSON"))
                .is_err()
        );
    }

    #[test]
    fn model_events_are_strict_tagged_and_bounded() {
        let events = [
            ModelEvent::started(),
            ModelEvent::delta("hello").expect("delta"),
            ModelEvent::completed(ModelUsage::new(100, 20).expect("usage")).expect("completed"),
            ModelEvent::failed(ModelFailureCode::RateLimited, true),
        ];
        for event in events {
            let json = serde_json::to_string(&event).expect("serialize");
            let decoded = ModelEvent::from_json_bytes(json.as_bytes()).expect("decode");
            assert_eq!(decoded, event);
        }
        assert!(ModelEvent::delta("").is_err());
        assert!(ModelEvent::delta("\u{00e9}".repeat((MAX_MODEL_DELTA_BYTES / 2) + 1)).is_err());
        assert!(
            ModelEvent::from_json_bytes(
                br#"{"event":"delta","text":"safe","prompt":"forbidden"}"#,
            )
            .is_err()
        );
        assert!(ModelEvent::from_json_bytes(br#"{"event":"started","text":"x"}"#).is_err());
        assert!(
            ModelEvent::from_json_bytes(
                br#"{"event":"completed","usage":{"input_tokens":1,"output_tokens":1,"extra":true}}"#,
            )
            .is_err()
        );
        let oversized_delta = serde_json::json!({
            "event": "delta",
            "text": "x".repeat(MAX_MODEL_DELTA_BYTES + 1),
        });
        assert!(
            ModelEvent::from_json_bytes(
                &serde_json::to_vec(&oversized_delta).expect("oversized delta JSON")
            )
            .is_err()
        );
    }

    #[test]
    fn raw_json_caps_are_checked_before_deserialization_and_on_preview_output() {
        let draft = ModelRequestDraft::new(
            ProviderId::new("local-model").expect("provider"),
            range(1),
            fields(),
        )
        .expect("draft");
        let mut draft_json = serde_json::to_vec(&draft).expect("draft JSON");
        draft_json.resize(MAX_MODEL_DRAFT_JSON_BYTES, b' ');
        assert!(ModelRequestDraft::from_json_bytes(&draft_json).is_ok());
        draft_json.push(b' ');
        assert!(matches!(
            ModelRequestDraft::from_json_bytes(&draft_json),
            Err(ModelJsonError::FrameTooLarge {
                limit: MAX_MODEL_DRAFT_JSON_BYTES
            })
        ));

        let preview = preview(ModelLocality::Cloud, "api.example.com", 443);
        let encoded = preview.to_json().expect("bounded preview output");
        assert!(encoded.len() <= MAX_MODEL_PREVIEW_JSON_BYTES);
        let mut padded = encoded.into_bytes();
        padded.resize(MAX_MODEL_PREVIEW_JSON_BYTES, b' ');
        assert!(TransferPreview::from_json_bytes(&padded).is_ok());
        padded.push(b' ');
        assert!(matches!(
            TransferPreview::from_json_bytes(&padded),
            Err(ModelJsonError::FrameTooLarge {
                limit: MAX_MODEL_PREVIEW_JSON_BYTES
            })
        ));

        let oversized_event = vec![b'{'; MAX_MODEL_EVENT_JSON_BYTES + 1];
        assert!(matches!(
            ModelEvent::from_json_bytes(&oversized_event),
            Err(ModelJsonError::FrameTooLarge {
                limit: MAX_MODEL_EVENT_JSON_BYTES
            })
        ));
    }
}
