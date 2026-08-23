//! Pure, bounded contracts for the signed TimeTrace extension marketplace.
//!
//! This module deliberately does not download archives, select URLs, persist
//! state, or contain an Ed25519 implementation.  Callers first decode and
//! verify a catalog, then use the compatibility planner to produce values that
//! are safe to project into a native UI.

use std::collections::BTreeSet;

use chrono::DateTime;
use schemars::JsonSchema;
use semver::Version;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use thiserror::Error;

use crate::{CapabilityId, HostApiRange, Platform, PluginId, PublisherId};

/// Schema version understood by this marketplace contract.
pub const MARKETPLACE_CATALOG_SCHEMA_VERSION: u32 = 1;
/// Maximum catalog wire bytes accepted before parsing.
pub const MAX_CATALOG_BYTES: usize = 128 * 1024;
/// Maximum releases in a catalog page.
pub const MAX_CATALOG_ITEMS: usize = 50;
/// Maximum package bytes a Marketplace TTX v1 release may advertise (16 MiB).
pub const MAX_PACKAGE_BYTES: u64 = 16 * 1024 * 1024;

/// Stable privacy-safe codes returned by marketplace validation and planning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceErrorCode {
    /// The catalog did not obey its bounded v1 wire contract.
    InvalidCatalog,
    /// The catalog uses a schema version this host does not understand.
    UnsupportedSchema,
    /// Canonical envelope bytes could not be produced.
    NonCanonicalEnvelope,
    /// The pinned marketplace signature did not verify.
    SignatureInvalid,
    /// A package or release digest had an invalid shape.
    InvalidDigest,
    /// A record contains a value whose execution meaning is unknown to v1.
    UnsupportedExecutionValue,
    /// The requested package cannot run on this host.
    Incompatible,
    /// User consent is needed before installation.
    PermissionRequired,
    /// Marketplace policy blocks the release.
    Blocked,
    /// The release has been revoked.
    Revoked,
}

/// A marketplace contract failure with a stable code and no remote payload.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("marketplace contract failed: {code:?}")]
pub struct MarketplaceError {
    /// Stable machine-readable reason.
    pub code: MarketplaceErrorCode,
}

impl MarketplaceError {
    fn new(code: MarketplaceErrorCode) -> Self {
        Self { code }
    }
}

/// A signed, bounded page of immutable release summaries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MarketplaceCatalogPage {
    /// Contract schema version.
    pub schema_version: u32,
    /// Opaque cache revision; clients must not infer ordering from it.
    pub catalog_revision: String,
    /// Marketplace generation time.
    pub generated_at: MarketplaceTimestamp,
    /// Release summaries selected by the marketplace query.
    pub items: Vec<MarketplaceReleaseSummary>,
    /// Opaque cursor for a subsequent page.
    #[serde(default)]
    pub next_cursor: Option<String>,
    /// Signature over [`Self::canonical_signed_bytes`].
    pub signature: MarketplaceSignature,
}

impl MarketplaceCatalogPage {
    /// Parses one bounded UTF-8 catalog page and validates every v1 value.
    pub fn parse_bounded(bytes: &[u8]) -> Result<Self, MarketplaceError> {
        if bytes.len() > MAX_CATALOG_BYTES {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        let page: Self = serde_json::from_slice(bytes)
            .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))?;
        page.validate()?;
        Ok(page)
    }

    /// Validates a page that may have come from a trusted in-memory source.
    pub fn validate(&self) -> Result<(), MarketplaceError> {
        if self.schema_version != MARKETPLACE_CATALOG_SCHEMA_VERSION {
            return Err(MarketplaceError::new(
                MarketplaceErrorCode::UnsupportedSchema,
            ));
        }
        if self.catalog_revision.is_empty() || self.catalog_revision.len() > 128 {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        if self
            .next_cursor
            .as_ref()
            .is_some_and(|value| value.is_empty() || value.len() > 512)
        {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        if self.items.len() > MAX_CATALOG_ITEMS {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        let mut releases = BTreeSet::new();
        let mut versions = BTreeSet::new();
        for item in &self.items {
            item.validate()?;
            if !releases.insert(item.release_id.as_str())
                || !versions.insert((
                    item.identity.publisher_id.as_str(),
                    item.identity.plugin_id.as_str(),
                    &item.version,
                ))
            {
                return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
            }
        }
        self.signature.validate()?;
        Ok(())
    }

    /// Returns Marketplace v1 profile bytes with the `signature` member omitted.
    ///
    /// This is not a general RFC 8785 implementation. Marketplace v1 rejects
    /// undeclared object members, so all signed object keys are the fixed ASCII
    /// keys in the v1 schema. They are ordered lexicographically; strings are
    /// UTF-8 JSON strings and numeric values are bounded integers only.
    pub fn canonical_signed_bytes(&self) -> Result<Vec<u8>, MarketplaceError> {
        self.validate()?;
        let mut value = serde_json::to_value(self)
            .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::NonCanonicalEnvelope))?;
        let object = value
            .as_object_mut()
            .ok_or_else(|| MarketplaceError::new(MarketplaceErrorCode::NonCanonicalEnvelope))?;
        object.remove("signature");
        let mut result = String::new();
        write_canonical_json(&value, &mut result)?;
        Ok(result.into_bytes())
    }

    /// Verifies this page with a caller-owned pinned-key adapter and marks it
    /// safe for a production UI or installation boundary.
    pub fn verify<V: MarketplaceSignatureVerifier>(
        &self,
        verifier: &V,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceError> {
        let bytes = self.canonical_signed_bytes()?;
        let signature = self.signature.decoded_value()?;
        verifier.verify_ed25519(&self.signature.key_id, &bytes, &signature)?;
        Ok(VerifiedMarketplaceCatalogPage(self.clone()))
    }
}

/// A catalog that passed bounded decoding and pinned-root signature verification.
///
/// A production UI adapter must obtain catalog display data from this type, not
/// from a network-deserialized [`MarketplaceCatalogPage`] directly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedMarketplaceCatalogPage(MarketplaceCatalogPage);

impl VerifiedMarketplaceCatalogPage {
    /// Returns the verified catalog data for host-owned DTO projection.
    #[must_use]
    pub fn as_page(&self) -> &MarketplaceCatalogPage {
        &self.0
    }

    /// Consumes this validation marker and returns the catalog for a trusted
    /// in-process owner such as a verified catalog cache.
    #[must_use]
    pub fn into_page(self) -> MarketplaceCatalogPage {
        self.0
    }
}

/// Stable publisher/plugin identity of a marketplace package.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MarketplaceIdentity {
    /// Approved publisher namespace.
    pub publisher_id: PublisherId,
    /// Existing TimeTrace extension identifier.
    pub plugin_id: PluginId,
}

/// Immutable marketplace release data safe to render in native UI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MarketplaceReleaseSummary {
    /// Opaque canonical UUID assigned by the marketplace.
    pub release_id: String,
    /// Immutable package identity.
    pub identity: MarketplaceIdentity,
    /// Exact package version.
    pub version: Version,
    /// Publication channel.
    pub channel: MarketplaceChannel,
    /// Current availability observation.
    pub state: MarketplaceReleaseState,
    /// Native display label, never markup.
    pub display_name: String,
    /// Optional bounded text description, never markup.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Closed v1 presentation badges.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub badges: Vec<MarketplaceBadge>,
    /// Lowercase SHA-256 of exact package bytes.
    pub package_digest: String,
    /// Exact `.ttx` byte length.
    pub package_bytes: u64,
    /// Canonical supported host API range.
    pub host_api: HostApiRange,
    /// Explicit supported desktop targets.
    pub platforms: Vec<Platform>,
    /// Requested permissions, presented by the local host before installation.
    pub permissions: Vec<CapabilityId>,
    /// Publication observation time.
    pub published_at: MarketplaceTimestamp,
}

/// Exact UTC millisecond timestamp spelling carried by a signed wire envelope.
///
/// The original string is retained because parsing then re-serializing an ISO
/// timestamp may otherwise change the signed bytes across implementations.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, JsonSchema)]
#[serde(transparent)]
pub struct MarketplaceTimestamp(#[schemars(with = "String")] String);

impl MarketplaceTimestamp {
    /// Parses only the v1 `YYYY-MM-DDTHH:mm:ss.sssZ` UTC representation.
    pub fn parse(value: impl Into<String>) -> Result<Self, MarketplaceError> {
        let value = value.into();
        if !is_wire_timestamp(&value) || DateTime::parse_from_rfc3339(&value).is_err() {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        Ok(Self(value))
    }

    /// Returns the exact verified wire spelling used for canonical signatures.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for MarketplaceTimestamp {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Self::parse(String::deserialize(deserializer)?)
            .map_err(<D::Error as serde::de::Error>::custom)
    }
}

impl MarketplaceReleaseSummary {
    fn validate(&self) -> Result<(), MarketplaceError> {
        if !is_uuid(&self.release_id)
            || self.display_name.trim().is_empty()
            || self.display_name.len() > 128
            || self
                .description
                .as_ref()
                .is_some_and(|value| value.len() > 4096)
            || !is_sha256_hex(&self.package_digest)
            || self.package_bytes == 0
            || self.package_bytes > MAX_PACKAGE_BYTES
            || self.platforms.is_empty()
            || self.platforms.len() > 4
            || self.permissions.len() > 64
            || self.badges.len() > 4
        {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        self.identity
            .publisher_id
            .validate()
            .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))?;
        self.identity
            .plugin_id
            .validate()
            .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))?;
        let mut platforms = BTreeSet::new();
        if self.platforms.iter().any(|item| !platforms.insert(item)) {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        let mut permissions = BTreeSet::new();
        for permission in &self.permissions {
            permission
                .validate()
                .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))?;
            if !permissions.insert(permission.as_str()) {
                return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
            }
        }
        let mut badges = BTreeSet::new();
        if self.badges.iter().any(|item| !badges.insert(item)) {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        Ok(())
    }
}

/// Closed v1 publication channels; unknown values are unavailable, never coerced.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceChannel {
    /// Stable reviewed releases.
    Stable,
    /// Opt-in prerelease channel.
    Beta,
}

/// Closed v1 release availability states with installation impact.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceReleaseState {
    /// Review-approved immutable release available for installation.
    Published,
    /// Temporarily unavailable for new installations.
    Suspended,
    /// Irreversibly unavailable for new installations.
    Revoked,
}

/// Closed v1 native badges.  They carry no rendering instructions.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum MarketplaceBadge {
    /// Published by the TimeTrace organization.
    Official,
    /// Publisher identity has passed marketplace verification.
    VerifiedPublisher,
    /// A beta-channel presentation marker.
    Beta,
    /// A native availability marker for suspended packages.
    Suspended,
    /// A native availability marker for revoked packages.
    Revoked,
}

/// Ed25519 envelope metadata.  The value is base64url without padding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MarketplaceSignature {
    /// Required algorithm spelling in catalog v1.
    pub algorithm: MarketplaceSignatureAlgorithm,
    /// Pinned marketplace root-key identifier.
    pub key_id: String,
    /// Exactly 64 signature bytes, base64url encoded without padding.
    pub value: String,
}

impl MarketplaceSignature {
    fn validate(&self) -> Result<(), MarketplaceError> {
        if self.key_id.is_empty() || self.key_id.len() > 128 || !is_identifier(&self.key_id) {
            return Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog));
        }
        self.decoded_value().map(|_| ())
    }

    /// Decodes a v1 signature to its exact Ed25519 byte representation.
    pub fn decoded_value(&self) -> Result<[u8; 64], MarketplaceError> {
        decode_base64url_64(&self.value)
            .ok_or_else(|| MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))
    }
}

/// The only signature algorithm supported by catalog v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub enum MarketplaceSignatureAlgorithm {
    #[serde(rename = "ed25519")]
    /// Edwards-curve Digital Signature Algorithm over Curve25519.
    Ed25519,
}

/// Narrow seam supplied by a platform-owned Ed25519 verifier.
pub trait MarketplaceSignatureVerifier {
    /// Verifies one exact canonical message using the pinned key selected by id.
    fn verify_ed25519(
        &self,
        key_id: &str,
        message: &[u8],
        signature: &[u8; 64],
    ) -> Result<(), MarketplaceError>;
}

/// Host facts used to recompute a release's installation disposition locally.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceCompatibilityInput {
    /// Current host API version.
    pub host_api: Version,
    /// Current OS and architecture.
    pub platform: Platform,
    /// Max package bytes allowed by local policy.
    pub max_package_bytes: u64,
    /// Permissions previously approved for this exact plugin identity.
    pub approved_permissions: BTreeSet<CapabilityId>,
    /// Current locally installed version, if any.
    pub installed_version: Option<Version>,
    /// Local policy can block an otherwise compatible publisher/release.
    pub locally_blocked: bool,
}

/// A host-produced plan; it never contains a network URL or remote renderer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceInstallPlan {
    /// Exact immutable release selected by the host.
    pub release: MarketplaceReleaseSummary,
    /// Local compatibility and consent outcome.
    pub disposition: MarketplaceInstallDisposition,
    /// Permissions that must be shown for explicit consent.
    pub required_consent: Vec<CapabilityId>,
    /// Conservative disk estimate for the package alone.
    pub disk_bytes: u64,
}

/// Closed installation outcomes understood by the native v1 store UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarketplaceInstallDisposition {
    /// The release may be downloaded and independently verified.
    Installable,
    /// A newer compatible release is available.
    UpdateAvailable,
    /// The exact version is already installed.
    AlreadyInstalled,
    /// The selected release is older than the locally installed version.
    DowngradeBlocked,
    /// A host/platform/package-budget requirement was not met.
    Incompatible(MarketplaceIncompatibility),
    /// Explicit user consent is missing.
    PermissionRequired,
    /// Local or marketplace policy prevents new installation.
    Blocked(MarketplaceBlockReason),
    /// A revoked release is never installable.
    Revoked,
}

/// Closed compatibility reasons, intentionally excluding arbitrary remote text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceIncompatibility {
    /// The current host API version is outside the signed range.
    HostApi,
    /// The current OS/architecture is absent from the signed targets.
    Platform,
    /// The signed package size exceeds local policy.
    PackageTooLarge,
}

/// Closed availability blocks with execution or consent impact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceBlockReason {
    /// Marketplace review has temporarily suspended the release.
    Suspended,
    /// A host-owned local policy blocks the release.
    LocalPolicy,
}

/// Plans one immutable release against local facts without performing I/O.
#[must_use]
pub fn plan_marketplace_install(
    release: MarketplaceReleaseSummary,
    input: &MarketplaceCompatibilityInput,
) -> MarketplaceInstallPlan {
    let required_consent = release
        .permissions
        .iter()
        .filter(|permission| !input.approved_permissions.contains(*permission))
        .cloned()
        .collect::<Vec<_>>();
    let disposition = if release.state == MarketplaceReleaseState::Revoked {
        MarketplaceInstallDisposition::Revoked
    } else if release.state == MarketplaceReleaseState::Suspended {
        MarketplaceInstallDisposition::Blocked(MarketplaceBlockReason::Suspended)
    } else if input.locally_blocked {
        MarketplaceInstallDisposition::Blocked(MarketplaceBlockReason::LocalPolicy)
    } else if !release.host_api.matches(&input.host_api) {
        MarketplaceInstallDisposition::Incompatible(MarketplaceIncompatibility::HostApi)
    } else if !release.platforms.contains(&input.platform) {
        MarketplaceInstallDisposition::Incompatible(MarketplaceIncompatibility::Platform)
    } else if release.package_bytes > input.max_package_bytes {
        MarketplaceInstallDisposition::Incompatible(MarketplaceIncompatibility::PackageTooLarge)
    } else if !required_consent.is_empty() {
        MarketplaceInstallDisposition::PermissionRequired
    } else {
        match &input.installed_version {
            Some(version) if version == &release.version => {
                MarketplaceInstallDisposition::AlreadyInstalled
            }
            Some(version) if version < &release.version => {
                MarketplaceInstallDisposition::UpdateAvailable
            }
            Some(_) => MarketplaceInstallDisposition::DowngradeBlocked,
            None => MarketplaceInstallDisposition::Installable,
        }
    };
    MarketplaceInstallPlan {
        disk_bytes: release.package_bytes,
        release,
        disposition,
        required_consent,
    }
}

fn write_canonical_json(value: &Value, output: &mut String) -> Result<(), MarketplaceError> {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        Value::Number(number) if number.is_i64() || number.is_u64() => {
            output.push_str(&number.to_string())
        }
        Value::Number(_) => {
            return Err(MarketplaceError::new(
                MarketplaceErrorCode::NonCanonicalEnvelope,
            ));
        }
        Value::String(value) => output.push_str(
            &serde_json::to_string(value)
                .map_err(|_| MarketplaceError::new(MarketplaceErrorCode::NonCanonicalEnvelope))?,
        ),
        Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(']');
        }
        Value::Object(values) => {
            output.push('{');
            let mut entries = values.iter().collect::<Vec<_>>();
            entries.sort_unstable_by_key(|(key, _)| *key);
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                output.push_str(&serde_json::to_string(key).map_err(|_| {
                    MarketplaceError::new(MarketplaceErrorCode::NonCanonicalEnvelope)
                })?);
                output.push(':');
                write_canonical_json(value, output)?;
            }
            output.push('}');
        }
    }
    Ok(())
}

fn is_identifier(value: &str) -> bool {
    if value.is_empty() || value.len() > 128 {
        return false;
    }
    let mut previous_separator = false;
    for (index, byte) in value.bytes().enumerate() {
        let separator = matches!(byte, b'-' | b'.' | b'_' | b':');
        if !(byte.is_ascii_lowercase() || byte.is_ascii_digit() || separator)
            || (separator && (index == 0 || previous_separator))
        {
            return false;
        }
        previous_separator = separator;
    }
    !previous_separator
}
fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn is_uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn is_wire_timestamp(value: &str) -> bool {
    value.len() == 24
        && value.bytes().enumerate().all(|(index, byte)| match index {
            4 | 7 => byte == b'-',
            10 => byte == b'T',
            13 | 16 => byte == b':',
            19 => byte == b'.',
            23 => byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
}

fn decode_base64url_64(value: &str) -> Option<[u8; 64]> {
    if value.len() != 86
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    let mut output = [0_u8; 64];
    let mut accumulator = 0_u32;
    let mut bits = 0_u8;
    let mut written = 0_usize;
    for byte in value.bytes() {
        let six = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'-' => 62,
            b'_' => 63,
            _ => return None,
        };
        accumulator = (accumulator << 6) | u32::from(six);
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            if written == output.len() {
                return None;
            }
            output[written] = ((accumulator >> bits) & 0xff) as u8;
            written += 1;
        }
    }
    (written == 64 && bits == 4 && (accumulator & ((1 << bits) - 1)) == 0).then_some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn signature() -> MarketplaceSignature {
        MarketplaceSignature { algorithm: MarketplaceSignatureAlgorithm::Ed25519, key_id: "marketplace-root-v1".to_owned(), value: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".to_owned() }
    }
    fn release() -> MarketplaceReleaseSummary {
        MarketplaceReleaseSummary {
            release_id: "123e4567-e89b-12d3-a456-426614174000".to_owned(),
            identity: MarketplaceIdentity {
                publisher_id: PublisherId::new("wellorbetter").expect("publisher"),
                plugin_id: PluginId::new("sample-plugin").expect("plugin"),
            },
            version: Version::new(1, 2, 0),
            channel: MarketplaceChannel::Stable,
            state: MarketplaceReleaseState::Published,
            display_name: "Sample plugin".to_owned(),
            description: None,
            badges: vec![MarketplaceBadge::Official],
            package_digest: "a".repeat(64),
            package_bytes: 1024,
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("range"),
            platforms: vec![Platform::WindowsX64],
            permissions: vec![CapabilityId::new("usage.aggregate.read").expect("capability")],
            published_at: MarketplaceTimestamp::parse("2026-08-23T00:00:00.000Z").expect("date"),
        }
    }
    fn page() -> MarketplaceCatalogPage {
        MarketplaceCatalogPage {
            schema_version: 1,
            catalog_revision: "rev-1".to_owned(),
            generated_at: MarketplaceTimestamp::parse("2026-08-23T00:00:00.000Z").expect("date"),
            items: vec![release()],
            next_cursor: None,
            signature: signature(),
        }
    }

    #[test]
    fn bounded_catalog_round_trips_and_has_stable_signature_bytes() {
        let page = page();
        let bytes = serde_json::to_vec(&page).expect("json");
        let parsed = MarketplaceCatalogPage::parse_bounded(&bytes).expect("parse");
        assert_eq!(parsed, page);
        let signed = parsed.canonical_signed_bytes().expect("canonical");
        assert!(!signed.windows(11).any(|window| window == b"signature"));
        assert_eq!(
            signed,
            parsed.canonical_signed_bytes().expect("canonical again")
        );
    }
    #[test]
    fn parser_rejects_unknown_execution_values_and_unbounded_input() {
        let mut value = serde_json::to_value(page()).expect("value");
        value["items"][0]["state"] = Value::String("remote_execute".to_owned());
        assert!(
            MarketplaceCatalogPage::parse_bounded(&serde_json::to_vec(&value).expect("json"))
                .is_err()
        );
        assert!(MarketplaceCatalogPage::parse_bounded(&vec![b' '; MAX_CATALOG_BYTES + 1]).is_err());
    }

    #[test]
    fn signed_profile_rejects_dynamic_bmp_and_astral_object_keys() {
        for key in ["é", "🧭"] {
            let mut value = serde_json::to_value(page()).expect("value");
            value[key] = Value::String("future-execution-value".to_owned());
            assert!(
                MarketplaceCatalogPage::parse_bounded(&serde_json::to_vec(&value).expect("json"))
                    .is_err(),
                "dynamic signed key must fail closed: {key}"
            );
        }
    }

    #[test]
    fn signed_timestamps_preserve_exact_utc_millisecond_wire_spelling() {
        let mut catalog = page();
        catalog.generated_at =
            MarketplaceTimestamp::parse("2026-08-23T00:00:00.120Z").expect("millisecond timestamp");
        let parsed = MarketplaceCatalogPage::parse_bounded(
            &serde_json::to_vec(&catalog).expect("catalog JSON"),
        )
        .expect("catalog parses");
        assert_eq!(parsed.generated_at.as_str(), "2026-08-23T00:00:00.120Z");
        let canonical =
            String::from_utf8(parsed.canonical_signed_bytes().expect("canonical")).expect("UTF-8");
        assert!(canonical.contains("2026-08-23T00:00:00.120Z"));
        for invalid in [
            "2026-08-23T00:00:00Z",
            "2026-08-23T00:00:00.12Z",
            "2026-08-23T00:00:00.120+00:00",
        ] {
            assert!(MarketplaceTimestamp::parse(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn shared_jcs_fixture_matches_canonical_signed_bytes_byte_for_byte() {
        let catalog = MarketplaceCatalogPage::parse_bounded(include_bytes!(
            "../../../contracts/fixtures/marketplace-catalog-v1/catalog.json"
        ))
        .expect("shared catalog fixture parses");
        assert_eq!(
            catalog.items[0].permissions[0].as_str(),
            "usage.aggregate.read",
            "shared catalog permissions must retain the TTX/Worker dot-form capability ID"
        );
        let expected = include_bytes!(
            "../../../contracts/fixtures/marketplace-catalog-v1/canonical-signed.json"
        )
        .strip_suffix(b"\n")
        .expect("fixture source has one non-payload terminal LF");
        assert_eq!(
            catalog.canonical_signed_bytes().expect("canonical"),
            expected
        );
    }
    #[test]
    fn signature_encoding_requires_exact_non_malleable_64_bytes() {
        assert!(signature().decoded_value().is_ok());
        let mut invalid = signature();
        invalid.value.pop();
        assert!(invalid.decoded_value().is_err());
    }
    #[test]
    fn planner_is_fail_closed_before_installability() {
        let base = MarketplaceCompatibilityInput {
            host_api: Version::new(1, 2, 0),
            platform: Platform::WindowsX64,
            max_package_bytes: 4096,
            approved_permissions: BTreeSet::new(),
            installed_version: None,
            locally_blocked: false,
        };
        assert_eq!(
            plan_marketplace_install(release(), &base).disposition,
            MarketplaceInstallDisposition::PermissionRequired
        );
        let mut approved = base.clone();
        approved
            .approved_permissions
            .insert(CapabilityId::new("usage.aggregate.read").expect("capability"));
        assert_eq!(
            plan_marketplace_install(release(), &approved).disposition,
            MarketplaceInstallDisposition::Installable
        );
        let mut revoked = release();
        revoked.state = MarketplaceReleaseState::Revoked;
        assert_eq!(
            plan_marketplace_install(revoked, &approved).disposition,
            MarketplaceInstallDisposition::Revoked
        );
        let mut installed_newer = approved;
        installed_newer.installed_version = Some(Version::new(2, 0, 0));
        assert_eq!(
            plan_marketplace_install(release(), &installed_newer).disposition,
            MarketplaceInstallDisposition::DowngradeBlocked
        );
    }

    #[test]
    fn catalog_enforces_the_shared_sixteen_mib_package_ceiling() {
        let mut boundary = page();
        boundary.items[0].package_bytes = MAX_PACKAGE_BYTES;
        assert!(boundary.validate().is_ok());

        boundary.items[0].package_bytes = MAX_PACKAGE_BYTES + 1;
        assert_eq!(
            boundary.validate(),
            Err(MarketplaceError::new(MarketplaceErrorCode::InvalidCatalog))
        );
    }
}
