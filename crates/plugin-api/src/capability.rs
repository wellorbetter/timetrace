//! Capability requests and least-privilege constraint DTOs.

use std::{collections::BTreeSet, fmt};

use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};
use thiserror::Error;

use crate::{CapabilityId, ContractError, GrantId, PluginId, validate_description};

/// Capability identifier for aggregate-only usage statistics.
pub const USAGE_AGGREGATE_READ: &str = "usage.aggregate.read";
/// Capability identifier for exact usage sessions.
pub const USAGE_SESSION_READ: &str = "usage.session.read";
/// Capability identifier for window-title data.
pub const WINDOW_TITLE_READ: &str = "window-title.read";
/// Capability identifier for journal body reads.
pub const JOURNAL_READ: &str = "journal.read";
/// Capability identifier for journal writes.
pub const JOURNAL_WRITE: &str = "journal.write";
/// Capability identifier for journal image reads.
pub const JOURNAL_IMAGE_READ: &str = "journal-image.read";
/// Capability identifier for user notifications.
pub const NOTIFICATION_SEND: &str = "notification.send";
/// Capability identifier for local model inference.
pub const AI_LOCAL: &str = "ai.local";
/// Capability identifier for external model inference.
pub const AI_CLOUD: &str = "ai.cloud";
/// Capability identifier for plugin-scoped key-value storage.
pub const PLUGIN_STORAGE: &str = "plugin-storage.read-write";
/// Capability identifier for structured diagnostic emission.
pub const DIAGNOSTICS_EMIT: &str = "diagnostics.emit";

/// Maximum date range allowed by the canonical aggregate-data contract.
pub const MAX_QUERY_RANGE_DAYS: u16 = 90;
/// Maximum row count allowed by the canonical aggregate-data contract.
pub const MAX_QUERY_ROWS: u32 = 10_000;
/// Maximum response bytes allowed by the canonical aggregate-data contract.
pub const MAX_QUERY_BYTES: u64 = 1_048_576;
/// Maximum exact endpoint domains in one capability declaration or grant.
pub const MAX_CAPABILITY_DOMAINS: usize = 32;
/// Number of bytes in an opaque capability bearer proof.
pub const CAPABILITY_PROOF_BYTES: usize = 32;

/// Supported aggregate-data granularities.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum UsageGranularity {
    /// One bucket per calendar day.
    Day,
    /// One bucket per normalized application.
    Application,
    /// One bucket per hour of day.
    Hour,
}

/// Parameter constraints attached to a capability request or grant.
///
/// A missing numeric limit means the corresponding canonical hard maximum.
/// Empty allowlist collections uniformly mean "allow none". Host code
/// normalizes numeric limits before comparing or enforcing grants.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CapabilityConstraints {
    /// Maximum inclusive query range in calendar days.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1, max = 90))]
    pub max_range_days: Option<u16>,
    /// Aggregate granularities the plugin may request; empty denies all.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    #[schemars(length(max = 3))]
    pub allowed_granularities: BTreeSet<UsageGranularity>,
    /// Maximum result rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1, max = 10000))]
    pub max_rows: Option<u32>,
    /// Maximum serialized response bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schemars(range(min = 1, max = 1048576))]
    pub max_bytes: Option<u64>,
    /// Exact endpoint domains authorized for external calls; empty denies all.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    #[schemars(length(max = 32))]
    pub allowed_domains: BTreeSet<String>,
}

impl CapabilityConstraints {
    /// Validates canonical hard limits and exact-domain syntax.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.allowed_domains.len() > MAX_CAPABILITY_DOMAINS {
            return Err(ContractError::LimitExceeded {
                field: "allowed_domains",
                limit: MAX_CAPABILITY_DOMAINS as u64,
            });
        }
        if self
            .max_range_days
            .is_some_and(|value| value == 0 || value > MAX_QUERY_RANGE_DAYS)
        {
            return Err(ContractError::LimitExceeded {
                field: "max_range_days",
                limit: u64::from(MAX_QUERY_RANGE_DAYS),
            });
        }
        if self
            .max_rows
            .is_some_and(|value| value == 0 || value > MAX_QUERY_ROWS)
        {
            return Err(ContractError::LimitExceeded {
                field: "max_rows",
                limit: u64::from(MAX_QUERY_ROWS),
            });
        }
        if self
            .max_bytes
            .is_some_and(|value| value == 0 || value > MAX_QUERY_BYTES)
        {
            return Err(ContractError::LimitExceeded {
                field: "max_bytes",
                limit: MAX_QUERY_BYTES,
            });
        }
        for domain in &self.allowed_domains {
            validate_exact_domain(domain)?;
        }
        Ok(())
    }
}

/// A capability declaration in a plugin manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CapabilityRequest {
    /// Requested capability identifier.
    pub id: CapabilityId,
    /// Least-privilege parameter constraints requested by the plugin.
    #[serde(default)]
    pub constraints: CapabilityConstraints,
    /// Optional non-sensitive explanation shown in permission UI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rationale: Option<String>,
}

/// Fail-closed capability policy for packages admitted by Marketplace TTX v1.
///
/// The general plugin contract intentionally permits future capability IDs. A
/// marketplace publisher must instead use only capabilities whose runtime
/// enforcement is implemented by the current desktop host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum MarketplaceCapabilityError {
    /// The declaration violates the base plugin capability contract.
    #[error("marketplace capability violates the base plugin contract")]
    InvalidBaseContract,
    /// The capability has no Marketplace v1 runtime enforcement.
    #[error("capability is not supported by Marketplace TTX v1")]
    UnsupportedCapability,
    /// The capability declares a constraint that has no P0 enforcement path.
    #[error("capability constraint is not supported by Marketplace TTX v1")]
    UnsupportedConstraint,
}

/// An explicit user- or host-policy grant for one declared plugin capability.
///
/// A grant contains authorization metadata only. It never carries credentials,
/// user data, database handles, or service instances.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CapabilityGrant {
    /// Stable host-issued identifier used for later revocation.
    pub id: GrantId,
    /// Plugin receiving the grant.
    pub plugin_id: PluginId,
    /// Manifest-declared capability being granted.
    pub capability_id: CapabilityId,
    /// Effective constraints, which the host must verify are no broader than
    /// the manifest declaration.
    #[serde(default)]
    pub constraints: CapabilityConstraints,
}

impl CapabilityGrant {
    /// Validates grant identifiers and canonical constraint bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.id.validate()?;
        self.plugin_id.validate()?;
        self.capability_id.validate()?;
        self.constraints.validate_basic()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CapabilityGrantWire {
    id: GrantId,
    plugin_id: PluginId,
    capability_id: CapabilityId,
    #[serde(default)]
    constraints: CapabilityConstraints,
}

impl<'de> Deserialize<'de> for CapabilityGrant {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = CapabilityGrantWire::deserialize(deserializer)?;
        let grant = Self {
            id: wire.id,
            plugin_id: wire.plugin_id,
            capability_id: wire.capability_id,
            constraints: wire.constraints,
        };
        grant
            .validate_basic()
            .map_err(<D::Error as serde::de::Error>::custom)?;
        Ok(grant)
    }
}

/// An opaque, revocable reference to a host-side capability grant.
///
/// The handle contains no user data or service reference, but its random proof
/// is a bearer credential. Constructing or deserializing a syntactically valid
/// handle never grants authority by itself; the host must match its grant
/// identifier, generation, and proof hash.
#[derive(Clone, PartialEq, Eq, Hash, Serialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CapabilityHandle {
    grant_id: GrantId,
    generation: u64,
    bearer_proof: [u8; CAPABILITY_PROOF_BYTES],
}

impl CapabilityHandle {
    /// Creates a host-issued handle from a grant identifier, non-zero
    /// generation, and CSPRNG bearer proof.
    ///
    /// Construction alone does not confer authority; the authorizer stores and
    /// matches only the proof hash. Callers must treat the proof as a bearer
    /// credential and must not log it.
    pub fn from_host_parts(
        grant_id: GrantId,
        generation: u64,
        bearer_proof: [u8; CAPABILITY_PROOF_BYTES],
    ) -> Result<Self, ContractError> {
        let handle = Self {
            grant_id,
            generation,
            bearer_proof,
        };
        handle.validate_basic()?;
        Ok(handle)
    }

    /// Returns the revocable grant identifier without exposing grant contents.
    #[must_use]
    pub fn grant_id(&self) -> &GrantId {
        &self.grant_id
    }

    /// Returns the generation used to reject handles issued before revocation.
    #[must_use]
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Returns the bearer proof for host-side hashing and transport only.
    ///
    /// This value is credential material. It must never be persisted in logs,
    /// diagnostics, crash reports, or plugin data stores.
    #[must_use]
    pub fn bearer_proof(&self) -> &[u8; CAPABILITY_PROOF_BYTES] {
        &self.bearer_proof
    }

    /// Validates the opaque handle's wire representation.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.grant_id.validate()?;
        if self.generation == 0 {
            return Err(ContractError::InvalidRange {
                field: "capability_handle_generation",
            });
        }
        if self.bearer_proof.iter().all(|byte| *byte == 0) {
            return Err(ContractError::InvalidRange {
                field: "capability_handle_proof",
            });
        }
        Ok(())
    }
}

impl fmt::Debug for CapabilityHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CapabilityHandle")
            .field("grant_id", &self.grant_id)
            .field("generation", &self.generation)
            .field("bearer_proof", &"[REDACTED]")
            .finish()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CapabilityHandleWire {
    grant_id: GrantId,
    generation: u64,
    bearer_proof: [u8; CAPABILITY_PROOF_BYTES],
}

impl<'de> Deserialize<'de> for CapabilityHandle {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = CapabilityHandleWire::deserialize(deserializer)?;
        Self::from_host_parts(wire.grant_id, wire.generation, wire.bearer_proof)
            .map_err(<D::Error as serde::de::Error>::custom)
    }
}

impl CapabilityRequest {
    /// Validates identifier, rationale, and constraint bounds.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.id.validate()?;
        validate_description("capability_rationale", self.rationale.as_deref())?;
        self.constraints.validate_basic()
    }

    /// Validates the narrower fail-closed Marketplace TTX v1 capability set.
    ///
    /// `usage.aggregate.read` may use query bounds and granularities but not
    /// endpoint domains. `ai.cloud` may use exact endpoint domains only.
    /// `ai.local` has no effective P0 constraints. Every other base-contract
    /// capability is rejected until a runtime enforcement path is shipped.
    pub fn validate_marketplace_ttx_v1(&self) -> Result<(), MarketplaceCapabilityError> {
        self.validate_basic()
            .map_err(|_| MarketplaceCapabilityError::InvalidBaseContract)?;
        let constraints = &self.constraints;
        match self.id.as_str() {
            USAGE_AGGREGATE_READ if constraints.allowed_domains.is_empty() => Ok(()),
            USAGE_AGGREGATE_READ => Err(MarketplaceCapabilityError::UnsupportedConstraint),
            AI_CLOUD
                if constraints.max_range_days.is_none()
                    && constraints.allowed_granularities.is_empty()
                    && constraints.max_rows.is_none()
                    && constraints.max_bytes.is_none() =>
            {
                Ok(())
            }
            AI_CLOUD => Err(MarketplaceCapabilityError::UnsupportedConstraint),
            AI_LOCAL if constraints == &CapabilityConstraints::default() => Ok(()),
            AI_LOCAL => Err(MarketplaceCapabilityError::UnsupportedConstraint),
            _ => Err(MarketplaceCapabilityError::UnsupportedCapability),
        }
    }
}

/// Validates an exact hostname without a scheme, path, port, or wildcard.
pub fn validate_exact_domain(domain: &str) -> Result<(), ContractError> {
    let canonical = canonicalize_exact_domain(domain)?;
    if canonical != domain {
        return Err(ContractError::InvalidDomain {
            domain: domain.to_owned(),
        });
    }
    Ok(())
}

/// Validates a hostname and returns its canonical ASCII lowercase form.
///
/// The result contains no scheme, port, path, wildcard, trailing dot, or
/// empty/overlong DNS labels and is suitable for exact authorization matching.
pub fn canonicalize_exact_domain(domain: &str) -> Result<String, ContractError> {
    let canonical = domain.to_ascii_lowercase();
    let valid = !canonical.is_empty()
        && canonical.len() <= 253
        && canonical.is_ascii()
        && canonical.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .bytes()
                    .all(|character| character.is_ascii_alphanumeric() || character == b'-')
        });
    if !valid {
        return Err(ContractError::InvalidDomain {
            domain: domain.to_owned(),
        });
    }
    Ok(canonical)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_constraints_accept_safe_aggregate_scope() {
        let constraints = CapabilityConstraints {
            max_range_days: Some(7),
            allowed_granularities: BTreeSet::from([
                UsageGranularity::Day,
                UsageGranularity::Application,
            ]),
            max_rows: Some(1_000),
            max_bytes: Some(64 * 1_024),
            allowed_domains: BTreeSet::new(),
        };
        assert!(constraints.validate_basic().is_ok());
    }

    #[test]
    fn constraints_reject_unbounded_limits_and_non_exact_domains() {
        let constraints = CapabilityConstraints {
            max_rows: Some(MAX_QUERY_ROWS + 1),
            allowed_domains: BTreeSet::from(["*.example.com".to_owned()]),
            ..CapabilityConstraints::default()
        };
        assert!(constraints.validate_basic().is_err());

        let domains = CapabilityConstraints {
            allowed_domains: BTreeSet::from(["https://example.com".to_owned()]),
            ..CapabilityConstraints::default()
        };
        assert!(domains.validate_basic().is_err());
        assert!(validate_exact_domain("api.example.com").is_ok());

        let oversized_domains = CapabilityConstraints {
            allowed_domains: (0..=MAX_CAPABILITY_DOMAINS)
                .map(|index| format!("api-{index}.example.com"))
                .collect(),
            ..CapabilityConstraints::default()
        };
        assert!(matches!(
            oversized_domains.validate_basic(),
            Err(ContractError::LimitExceeded {
                field: "allowed_domains",
                ..
            })
        ));
    }

    #[test]
    fn domains_require_valid_canonical_dns_labels() {
        assert_eq!(
            canonicalize_exact_domain("API.Example.COM").expect("canonical domain"),
            "api.example.com"
        );
        assert!(validate_exact_domain("API.Example.COM").is_err());
        assert!(validate_exact_domain("a..example.com").is_err());
        assert!(validate_exact_domain("-api.example.com").is_err());
        assert!(validate_exact_domain("api-.example.com").is_err());
        assert!(validate_exact_domain("api.example.com.").is_err());
    }

    #[test]
    fn marketplace_ttx_v1_rejects_unenforced_capabilities_and_constraint_shapes() {
        let usage = CapabilityRequest {
            id: CapabilityId::new(USAGE_AGGREGATE_READ).expect("id"),
            constraints: CapabilityConstraints {
                max_range_days: Some(7),
                ..CapabilityConstraints::default()
            },
            rationale: None,
        };
        assert!(usage.validate_marketplace_ttx_v1().is_ok());

        let cloud = CapabilityRequest {
            id: CapabilityId::new(AI_CLOUD).expect("id"),
            constraints: CapabilityConstraints {
                allowed_domains: BTreeSet::from(["api.openai.com".to_owned()]),
                ..CapabilityConstraints::default()
            },
            rationale: None,
        };
        assert!(cloud.validate_marketplace_ttx_v1().is_ok());

        let unsupported = CapabilityRequest {
            id: CapabilityId::new(NOTIFICATION_SEND).expect("id"),
            constraints: CapabilityConstraints::default(),
            rationale: None,
        };
        assert_eq!(
            unsupported.validate_marketplace_ttx_v1(),
            Err(MarketplaceCapabilityError::UnsupportedCapability)
        );
        let cloud_with_query_limit = CapabilityRequest {
            constraints: CapabilityConstraints {
                max_rows: Some(1),
                ..cloud.constraints.clone()
            },
            ..cloud
        };
        assert_eq!(
            cloud_with_query_limit.validate_marketplace_ttx_v1(),
            Err(MarketplaceCapabilityError::UnsupportedConstraint)
        );
    }

    #[test]
    fn capability_request_validates_all_parts() {
        let request = CapabilityRequest {
            id: CapabilityId::new(USAGE_AGGREGATE_READ).expect("valid capability"),
            constraints: CapabilityConstraints::default(),
            rationale: Some("Build a weekly aggregate report".to_owned()),
        };
        assert!(request.validate_basic().is_ok());
    }

    #[test]
    fn grant_and_bearer_handle_round_trip_with_redacted_debug() {
        let grant = CapabilityGrant {
            id: GrantId::new("grant-1").expect("valid grant"),
            plugin_id: PluginId::new("sample-plugin").expect("valid plugin"),
            capability_id: CapabilityId::new(USAGE_AGGREGATE_READ).expect("valid capability"),
            constraints: CapabilityConstraints {
                max_range_days: Some(7),
                max_rows: Some(500),
                ..CapabilityConstraints::default()
            },
        };
        let encoded = serde_json::to_string(&grant).expect("serialize grant");
        assert!(!encoded.contains("secret"));
        let decoded: CapabilityGrant = serde_json::from_str(&encoded).expect("deserialize grant");
        assert_eq!(decoded, grant);

        let proof = [7; CAPABILITY_PROOF_BYTES];
        let handle =
            CapabilityHandle::from_host_parts(grant.id.clone(), 3, proof).expect("valid handle");
        let encoded = serde_json::to_string(&handle).expect("serialize handle");
        assert_eq!(
            serde_json::from_str::<CapabilityHandle>(&encoded).expect("deserialize handle"),
            handle
        );
        assert_eq!(handle.grant_id().as_str(), "grant-1");
        assert_eq!(handle.generation(), 3);
        assert_eq!(handle.bearer_proof(), &proof);
        assert!(!format!("{handle:?}").contains("7, 7"));
        assert!(format!("{handle:?}").contains("REDACTED"));
    }

    #[test]
    fn external_capability_dtos_fail_closed() {
        let unknown_constraint = r#"{"max_rows":10,"future_scope":true}"#;
        assert!(serde_json::from_str::<CapabilityConstraints>(unknown_constraint).is_err());

        let unknown_request = r#"{
            "id":"usage.aggregate.read",
            "constraints":{},
            "future_scope":true
        }"#;
        assert!(serde_json::from_str::<CapabilityRequest>(unknown_request).is_err());

        let unknown_grant = r#"{
            "id":"grant-1",
            "plugin_id":"sample-plugin",
            "capability_id":"usage.aggregate.read",
            "constraints":{},
            "future_scope":true
        }"#;
        assert!(serde_json::from_str::<CapabilityGrant>(unknown_grant).is_err());

        let invalid_generation = format!(
            r#"{{"grant_id":"grant-1","generation":0,"bearer_proof":{:?}}}"#,
            [1; CAPABILITY_PROOF_BYTES]
        );
        assert!(serde_json::from_str::<CapabilityHandle>(&invalid_generation).is_err());
        let unknown_handle = format!(
            r#"{{"grant_id":"grant-1","generation":1,"bearer_proof":{:?},"secret":"not-allowed"}}"#,
            [1; CAPABILITY_PROOF_BYTES]
        );
        assert!(serde_json::from_str::<CapabilityHandle>(&unknown_handle).is_err());

        let zero_proof = format!(
            r#"{{"grant_id":"grant-1","generation":1,"bearer_proof":{:?}}}"#,
            [0; CAPABILITY_PROOF_BYTES]
        );
        assert!(serde_json::from_str::<CapabilityHandle>(&zero_proof).is_err());
    }
}
