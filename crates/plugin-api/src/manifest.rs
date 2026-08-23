//! Canonical plugin manifest and compatibility version types.

use std::{collections::BTreeSet, fmt, str::FromStr};

use schemars::JsonSchema;
use semver::{Op, Version, VersionReq};
use serde::{Deserialize, Deserializer, Serialize, de::Error as _};
use serde_json::Value;
use thiserror::Error;

use crate::{
    AI_CLOUD, AI_LOCAL, CapabilityConstraints, CapabilityRequest, ContractError,
    ContributionDescriptor, PluginId, PublisherId, RendererRef, SettingValueKind,
    USAGE_AGGREGATE_READ, validate_description, validate_label,
};

/// Current canonical plugin manifest schema version.
pub const CURRENT_MANIFEST_SCHEMA_VERSION: u32 = 1;
/// Maximum contributions declared by one plugin manifest.
pub const MAX_CONTRIBUTIONS_PER_PLUGIN: usize = 256;
/// Maximum capabilities requested by one plugin manifest.
pub const MAX_CAPABILITIES_PER_PLUGIN: usize = 64;
/// Maximum exact `manifest.json` bytes accepted from a TTX v1 archive.
pub const MAX_TTX_MANIFEST_BYTES: usize = 64 * 1024;
/// Maximum Marketplace P1 activation contributions in one TTX manifest.
pub const MAX_TTX_P1_CONTRIBUTIONS: usize = 64;

/// A semantic-version requirement for the TimeTrace host API.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(transparent)]
pub struct HostApiRange(#[schemars(with = "String")] VersionReq);

/// Stable failures returned when parsing a canonical host API range.
#[derive(Debug, Error)]
pub enum HostApiRangeError {
    /// The input is not a semantic-version requirement.
    #[error(transparent)]
    InvalidSemver(#[from] semver::Error),
    /// Plugin manifests must use one explicit, half-open host-major range.
    #[error("host API range must use `>=M.m.p, <(M+1).0.0` for exactly one host major")]
    NonCanonical,
}

impl HostApiRange {
    /// Parses a canonical single-major range such as `>=1.2.0, <2.0.0`.
    pub fn parse(value: &str) -> Result<Self, HostApiRangeError> {
        let requirement = VersionReq::parse(value)?;
        canonical_host_major(&requirement).ok_or(HostApiRangeError::NonCanonical)?;
        Ok(Self(requirement))
    }

    /// Returns whether a concrete host API version satisfies the requirement.
    #[must_use]
    pub fn matches(&self, version: &Version) -> bool {
        canonical_host_major(&self.0)
            .is_some_and(|host_major| version.major == host_major && self.0.matches(version))
    }

    /// Returns the parsed semantic-version requirement.
    #[must_use]
    pub fn requirement(&self) -> &VersionReq {
        &self.0
    }
}

impl fmt::Display for HostApiRange {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

impl FromStr for HostApiRange {
    type Err = HostApiRangeError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::parse(value)
    }
}

impl<'de> Deserialize<'de> for HostApiRange {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value).map_err(D::Error::custom)
    }
}

fn canonical_host_major(requirement: &VersionReq) -> Option<u64> {
    if requirement.comparators.len() != 2 {
        return None;
    }
    let lower = requirement.comparators.iter().find(|comparator| {
        comparator.op == Op::GreaterEq
            && comparator.minor.is_some()
            && comparator.patch.is_some()
            && comparator.pre.is_empty()
    })?;
    let upper = requirement.comparators.iter().find(|comparator| {
        comparator.op == Op::Less
            && comparator.minor == Some(0)
            && comparator.patch == Some(0)
            && comparator.pre.is_empty()
    })?;
    (lower.major.checked_add(1) == Some(upper.major)).then_some(lower.major)
}

/// Host platforms a bundled plugin may explicitly support.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, JsonSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    /// Windows 10/11 on x86-64.
    WindowsX64,
    /// macOS on Apple Silicon.
    MacOsArm64,
    /// macOS on x86-64.
    MacOsX64,
    /// Linux on x86-64.
    LinuxX64,
}

/// The single authoritative description of a TimeTrace plugin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PluginManifest {
    /// Version of the manifest schema, independent from plugin and host API versions.
    pub schema_version: u32,
    /// Stable plugin identifier, unique within the host catalog.
    pub id: PluginId,
    /// Stable publisher namespace.
    pub publisher: PublisherId,
    /// User-visible plugin name.
    pub display_name: String,
    /// Optional non-sensitive plugin description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Plugin package version.
    pub version: Version,
    /// Compatible host API version range.
    pub host_api: HostApiRange,
    /// Explicitly supported host platforms.
    #[schemars(length(min = 1, max = 4))]
    pub platforms: Vec<Platform>,
    /// Declarative contributions exposed by the plugin.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 256))]
    pub contributions: Vec<ContributionDescriptor>,
    /// Capabilities requested for later explicit authorization.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 64))]
    pub requested_capabilities: Vec<CapabilityRequest>,
}

impl PluginManifest {
    /// Parses a TTX v1 `manifest.json` only when its original bytes use the
    /// frozen Marketplace v1 canonical JSON profile.
    ///
    /// This prevents a Worker from reviewing one semantic JSON form while the
    /// desktop host signs or verifies another. The profile permits only the
    /// closed [`PluginManifest`] object graph, lexicographically ordered object
    /// keys, UTF-8 JSON strings, and integer numbers; it is not a generic JCS
    /// implementation.
    pub fn parse_ttx_v1_canonical(bytes: &[u8]) -> Result<Self, TtxManifestError> {
        let manifest = Self::parse_ttx_v1_canonical_basic(bytes)?;
        manifest.validate_marketplace_ttx_v1_activation_profile()?;
        if manifest
            .requested_capabilities
            .iter()
            .any(|request| request.validate_marketplace_ttx_v1().is_err())
        {
            return Err(TtxManifestError::UnsupportedMarketplaceCapability);
        }
        Ok(manifest)
    }

    /// Parses the separate fixed First-Party Bundled v1 profile.
    ///
    /// This is deliberately not an extension of [`Self::parse_ttx_v1_canonical`]:
    /// Marketplace P1 continues to reject `bundled_typed`.  The accepted
    /// identity and contribution shape are the one host-audited entitlement
    /// binding, not publisher-selected renderer metadata.
    pub fn parse_ttx_marketplace_first_party_bundled_v1_canonical(
        bytes: &[u8],
    ) -> Result<Self, TtxManifestError> {
        let manifest = Self::parse_ttx_v1_canonical_basic(bytes)?;
        manifest.validate_marketplace_first_party_bundled_v1_profile()?;
        Ok(manifest)
    }

    fn parse_ttx_v1_canonical_basic(bytes: &[u8]) -> Result<Self, TtxManifestError> {
        if bytes.len() > MAX_TTX_MANIFEST_BYTES {
            return Err(TtxManifestError::TooLarge);
        }
        let value: Value =
            serde_json::from_slice(bytes).map_err(|_| TtxManifestError::InvalidJson)?;
        let canonical = canonical_ttx_json(&value)?;
        if canonical.as_bytes() != bytes {
            return Err(TtxManifestError::NonCanonical);
        }
        let manifest: Self =
            serde_json::from_value(value).map_err(|_| TtxManifestError::InvalidManifest)?;
        manifest
            .validate_basic()
            .map_err(|_| TtxManifestError::InvalidManifest)?;
        Ok(manifest)
    }

    /// Enforces one immutable First-Party Bundled v1 entitlement binding.
    ///
    /// The renderer is selected by a host compile-time allowlist.  This
    /// method only recognizes the small host-owned identity table that may
    /// claim a binding; it never makes bundled renderers available to P1
    /// packages.
    pub fn validate_marketplace_first_party_bundled_v1_profile(
        &self,
    ) -> Result<(), TtxManifestError> {
        if self.contributions.len() != 2 {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }

        match self.id.as_str() {
            "private-flight" => self.validate_private_flight_bundled_profile(),
            "ai-recap" => self.validate_ai_recap_bundled_profile(),
            _ => Err(TtxManifestError::UnsupportedMarketplaceContribution),
        }
    }

    fn validate_private_flight_bundled_profile(&self) -> Result<(), TtxManifestError> {
        if self.publisher.as_str() != "wellorbetter"
            || self.display_name != "起飞记录"
            || !self.requested_capabilities.is_empty()
        {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }
        self.validate_exact_bundled_page_and_navigation(
            "private-flight",
            "private-flight-v1",
            "起飞记录",
        )
    }

    fn validate_ai_recap_bundled_profile(&self) -> Result<(), TtxManifestError> {
        if self.publisher.as_str() != "wellorbetter" || self.display_name != "AI Recap" {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }
        let mut has_usage_aggregate = false;
        let mut has_ai_provider = false;
        let mut capabilities = BTreeSet::new();
        for request in &self.requested_capabilities {
            // An entitlement may ask to use a host-owned adapter but may never
            // select aggregate bounds, a cloud target, or any other runtime
            // policy from its archive.
            if request.constraints != CapabilityConstraints::default()
                || request.rationale.is_some()
                || !capabilities.insert(request.id.as_str())
            {
                return Err(TtxManifestError::UnsupportedMarketplaceContribution);
            }
            match request.id.as_str() {
                USAGE_AGGREGATE_READ => has_usage_aggregate = true,
                AI_LOCAL | AI_CLOUD => has_ai_provider = true,
                _ => return Err(TtxManifestError::UnsupportedMarketplaceContribution),
            }
        }
        if !has_usage_aggregate || !has_ai_provider {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }
        self.validate_exact_bundled_page_and_navigation("ai-recap", "ai-recap-v1", "AI Recap")
    }

    fn validate_exact_bundled_page_and_navigation(
        &self,
        view_id: &str,
        renderer_contract_id: &str,
        title: &str,
    ) -> Result<(), TtxManifestError> {
        let [page, navigation] = self.contributions.as_slice() else {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        };
        let ContributionDescriptor::Page(page) = page else {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        };
        let ContributionDescriptor::Navigation(navigation) = navigation else {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        };
        let RendererRef::BundledTyped {
            contract_id,
            schema_version,
        } = &page.renderer
        else {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        };
        let exact_metadata = |metadata: &crate::ContributionMetadata, id: &str| {
            metadata.id.as_str() == id
                && metadata.display.title == title
                && metadata.display.description.is_none()
                && metadata.display.icon.is_none()
                && metadata.order == 0
                && metadata.required_capabilities.is_empty()
        };
        let page_id = format!("{view_id}.page");
        let navigation_id = format!("{view_id}.navigation");
        if page.view_id != view_id
            || contract_id.as_str() != renderer_contract_id
            || *schema_version != 1
            || !exact_metadata(&page.metadata, &page_id)
            || navigation.page_id.as_str() != page_id
            || !exact_metadata(&navigation.metadata, &navigation_id)
        {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }
        Ok(())
    }

    /// Enforces the Marketplace P1 non-executable activation subset.
    ///
    /// A package can describe only host-owned navigation, pages, dashboard
    /// cards, and schema-driven settings.  It cannot introduce a command,
    /// carousel, bundled renderer, per-contribution capability demand, or a
    /// resource path selected by package data.  Page/card documents are
    /// therefore resolved solely as `resources/declarative-v1/<id>.json`.
    pub fn validate_marketplace_ttx_v1_activation_profile(&self) -> Result<(), TtxManifestError> {
        if self.contributions.len() > MAX_TTX_P1_CONTRIBUTIONS {
            return Err(TtxManifestError::UnsupportedMarketplaceContribution);
        }
        for contribution in &self.contributions {
            if !contribution.metadata().required_capabilities.is_empty() {
                return Err(TtxManifestError::UnsupportedMarketplaceContribution);
            }
            match contribution {
                ContributionDescriptor::Navigation(_) => {}
                ContributionDescriptor::Page(page) => {
                    if page.renderer != RendererRef::DeclarativeV1 {
                        return Err(TtxManifestError::UnsupportedMarketplaceContribution);
                    }
                }
                ContributionDescriptor::DashboardCard(card) => {
                    if card.renderer != RendererRef::DeclarativeV1 {
                        return Err(TtxManifestError::UnsupportedMarketplaceContribution);
                    }
                    // `wide` belongs to the excluded carousel layout.
                    if matches!(card.size, crate::DashboardSize::Wide) {
                        return Err(TtxManifestError::UnsupportedMarketplaceContribution);
                    }
                }
                ContributionDescriptor::Settings(settings) => {
                    if settings
                        .fields
                        .iter()
                        .any(|field| field.kind == SettingValueKind::SecretReference)
                    {
                        return Err(TtxManifestError::UnsupportedMarketplaceContribution);
                    }
                }
                ContributionDescriptor::DashboardCarousel(_)
                | ContributionDescriptor::Command(_) => {
                    return Err(TtxManifestError::UnsupportedMarketplaceContribution);
                }
            }
        }
        Ok(())
    }

    /// Performs transport-neutral structural validation.
    ///
    /// Catalog-wide uniqueness and host compatibility are intentionally owned
    /// by the host registration layer rather than this value object.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        if self.schema_version != CURRENT_MANIFEST_SCHEMA_VERSION {
            return Err(ContractError::UnsupportedSchemaVersion {
                version: self.schema_version,
            });
        }
        self.id.validate()?;
        self.publisher.validate()?;
        validate_label("plugin_display_name", &self.display_name)?;
        validate_description("plugin_description", self.description.as_deref())?;
        if self.platforms.is_empty() {
            return Err(ContractError::EmptyField { field: "platforms" });
        }
        if self.contributions.len() > MAX_CONTRIBUTIONS_PER_PLUGIN {
            return Err(ContractError::LimitExceeded {
                field: "contributions",
                limit: MAX_CONTRIBUTIONS_PER_PLUGIN as u64,
            });
        }
        if self.requested_capabilities.len() > MAX_CAPABILITIES_PER_PLUGIN {
            return Err(ContractError::LimitExceeded {
                field: "requested_capabilities",
                limit: MAX_CAPABILITIES_PER_PLUGIN as u64,
            });
        }

        let mut platforms = BTreeSet::new();
        for platform in &self.platforms {
            if !platforms.insert(platform) {
                return Err(ContractError::DuplicateIdentifier {
                    field: "platforms",
                    value: format!("{platform:?}"),
                });
            }
        }

        let mut capability_ids = BTreeSet::new();
        for capability in &self.requested_capabilities {
            capability.validate_basic()?;
            if !capability_ids.insert(capability.id.as_str()) {
                return Err(ContractError::DuplicateIdentifier {
                    field: "requested_capabilities",
                    value: capability.id.to_string(),
                });
            }
        }

        let namespace_prefix = format!("{}.", self.id.as_str());
        let mut contribution_ids = BTreeSet::new();
        let mut page_ids = BTreeSet::new();
        let mut page_view_ids = BTreeSet::new();
        for contribution in &self.contributions {
            contribution.validate_basic()?;
            if !contribution.id().as_str().starts_with(&namespace_prefix) {
                return Err(ContractError::InvalidNamespace {
                    field: "contribution_id",
                    expected_prefix: namespace_prefix.clone(),
                });
            }
            if !contribution_ids.insert(contribution.id().as_str()) {
                return Err(ContractError::DuplicateIdentifier {
                    field: "contributions",
                    value: contribution.id().to_string(),
                });
            }
            for required in &contribution.metadata().required_capabilities {
                if !capability_ids.contains(required.as_str()) {
                    return Err(ContractError::UnknownReference {
                        field: "required_capability",
                        value: required.to_string(),
                    });
                }
            }
            if let ContributionDescriptor::Page(page) = contribution {
                page_ids.insert(page.metadata.id.as_str());
                if !page_view_ids.insert(page.view_id.as_str()) {
                    return Err(ContractError::DuplicateIdentifier {
                        field: "page_view_id",
                        value: page.view_id.clone(),
                    });
                }
            }
        }

        for contribution in &self.contributions {
            if let ContributionDescriptor::Navigation(navigation) = contribution
                && !page_ids.contains(navigation.page_id.as_str())
            {
                return Err(ContractError::UnknownReference {
                    field: "navigation_page_id",
                    value: navigation.page_id.to_string(),
                });
            }
        }
        Ok(())
    }
}

/// Stable failures from the exact TTX v1 manifest boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum TtxManifestError {
    /// The untrusted archive member exceeded the TTX v1 byte ceiling.
    #[error("TTX manifest exceeds its byte limit")]
    TooLarge,
    /// The archive member was not valid JSON.
    #[error("TTX manifest is invalid JSON")]
    InvalidJson,
    /// The original bytes were not the frozen canonical representation.
    #[error("TTX manifest is not canonical")]
    NonCanonical,
    /// The JSON did not satisfy the closed canonical plugin manifest contract.
    #[error("TTX manifest violates the plugin manifest contract")]
    InvalidManifest,
    /// A syntactically valid capability has no Marketplace v1 enforcement path.
    #[error("TTX manifest requests an unsupported Marketplace capability")]
    UnsupportedMarketplaceCapability,
    /// A contribution falls outside the non-executable Marketplace P1 profile.
    #[error("TTX manifest declares an unsupported Marketplace contribution")]
    UnsupportedMarketplaceContribution,
}

fn canonical_ttx_json(value: &Value) -> Result<String, TtxManifestError> {
    match value {
        Value::Null | Value::Bool(_) | Value::String(_) => {
            serde_json::to_string(value).map_err(|_| TtxManifestError::InvalidJson)
        }
        Value::Number(number) if number.is_i64() || number.is_u64() => Ok(number.to_string()),
        Value::Number(_) => Err(TtxManifestError::NonCanonical),
        Value::Array(values) => values
            .iter()
            .map(canonical_ttx_json)
            .collect::<Result<Vec<_>, _>>()
            .map(|values| format!("[{}]", values.join(","))),
        Value::Object(values) => {
            let mut entries = values.iter().collect::<Vec<_>>();
            entries.sort_unstable_by_key(|(key, _)| *key);
            entries
                .into_iter()
                .map(|(key, value)| {
                    Ok(format!(
                        "{}:{}",
                        serde_json::to_string(key).map_err(|_| TtxManifestError::InvalidJson)?,
                        canonical_ttx_json(value)?
                    ))
                })
                .collect::<Result<Vec<_>, TtxManifestError>>()
                .map(|entries| format!("{{{}}}", entries.join(",")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AI_CLOUD, CapabilityConstraints, CapabilityId, CommandDescriptor, ContributionId,
        ContributionMetadata, DisplayMetadata, NavigationDescriptor, PageDescriptor, RendererRef,
        SettingFieldDescriptor, SettingValueKind, SettingsSectionDescriptor, USAGE_AGGREGATE_READ,
    };

    fn manifest() -> PluginManifest {
        PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: PluginId::new("sample-plugin").expect("valid plugin"),
            publisher: PublisherId::new("wellorbetter").expect("valid publisher"),
            display_name: "Sample plugin".to_owned(),
            description: Some("Exercises the public plugin contract".to_owned()),
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("valid range"),
            platforms: vec![Platform::WindowsX64],
            contributions: vec![ContributionDescriptor::Page(PageDescriptor {
                metadata: ContributionMetadata {
                    id: ContributionId::new("sample-plugin.page").expect("valid contribution"),
                    display: DisplayMetadata {
                        title: "Sample".to_owned(),
                        description: None,
                        icon: None,
                    },
                    order: 0,
                    required_capabilities: Vec::new(),
                },
                view_id: "overview".to_owned(),
                renderer: RendererRef::DeclarativeV1,
            })],
            requested_capabilities: vec![CapabilityRequest {
                id: CapabilityId::new(USAGE_AGGREGATE_READ).expect("valid capability"),
                constraints: CapabilityConstraints::default(),
                rationale: None,
            }],
        }
    }

    #[test]
    fn host_api_range_matches_only_declared_versions() {
        let range = HostApiRange::parse(">=1.2.0, <2.0.0").expect("valid range");
        assert!(range.matches(&Version::new(1, 5, 0)));
        assert!(!range.matches(&Version::new(2, 0, 0)));
        assert_eq!(range.requirement(), range.requirement());
        assert!(range.to_string().contains("1.2.0"));
    }

    #[test]
    fn host_api_range_rejects_unbounded_wildcard_and_cross_major_inputs() {
        for invalid in [
            "*",
            ">=1.0.0",
            ">=1.0.0, <3.0.0",
            ">=1.0.0, <2.0.0 || >=3.0.0, <4.0.0",
        ] {
            assert!(
                HostApiRange::parse(invalid).is_err(),
                "range should be rejected: {invalid}"
            );
        }
    }

    #[test]
    fn host_api_range_deserialization_enforces_the_canonical_form() {
        let valid: HostApiRange =
            serde_json::from_str(r#"">=1.2.3, <2.0.0""#).expect("canonical range");
        assert!(valid.matches(&Version::new(1, 9, 0)));
        assert!(!valid.matches(&Version::new(2, 0, 0)));
        assert!(serde_json::from_str::<HostApiRange>(r#""*""#).is_err());
    }

    #[test]
    fn valid_manifest_round_trips_and_validates() {
        let manifest = manifest();
        assert!(manifest.validate_basic().is_ok());
        let json = serde_json::to_string(&manifest).expect("serialize manifest");
        let decoded: PluginManifest = serde_json::from_str(&json).expect("deserialize manifest");
        assert_eq!(decoded, manifest);
    }

    #[test]
    fn manifest_rejects_duplicate_contributions_and_schema_drift() {
        let mut manifest = manifest();
        manifest
            .contributions
            .push(manifest.contributions[0].clone());
        assert!(manifest.validate_basic().is_err());
        manifest.contributions.pop();
        manifest.schema_version += 1;
        assert!(manifest.validate_basic().is_err());
    }

    #[test]
    fn manifest_rejects_foreign_namespace_and_undeclared_capability() {
        let mut foreign = manifest();
        let ContributionDescriptor::Page(page) = &mut foreign.contributions[0] else {
            panic!("fixture is a page");
        };
        page.metadata.id = ContributionId::new("other-plugin.page").expect("valid foreign id");
        assert!(foreign.validate_basic().is_err());

        let mut undeclared = manifest();
        let ContributionDescriptor::Page(page) = &mut undeclared.contributions[0] else {
            panic!("fixture is a page");
        };
        page.metadata.required_capabilities =
            vec![CapabilityId::new(AI_CLOUD).expect("valid capability identifier")];
        assert!(undeclared.validate_basic().is_err());
    }

    #[test]
    fn manifest_rejects_missing_navigation_page_and_duplicate_view_id() {
        let mut missing_page = manifest();
        missing_page
            .contributions
            .push(ContributionDescriptor::Navigation(NavigationDescriptor {
                metadata: ContributionMetadata {
                    id: ContributionId::new("sample-plugin.navigation")
                        .expect("valid contribution"),
                    display: DisplayMetadata {
                        title: "Navigation".to_owned(),
                        description: None,
                        icon: None,
                    },
                    order: 1,
                    required_capabilities: Vec::new(),
                },
                page_id: ContributionId::new("sample-plugin.missing")
                    .expect("valid missing reference"),
            }));
        assert!(missing_page.validate_basic().is_err());

        let mut duplicate_view = manifest();
        duplicate_view
            .contributions
            .push(ContributionDescriptor::Page(PageDescriptor {
                metadata: ContributionMetadata {
                    id: ContributionId::new("sample-plugin.second-page")
                        .expect("valid contribution"),
                    display: DisplayMetadata {
                        title: "Second page".to_owned(),
                        description: None,
                        icon: None,
                    },
                    order: 1,
                    required_capabilities: Vec::new(),
                },
                view_id: "overview".to_owned(),
                renderer: RendererRef::DeclarativeV1,
            }));
        assert!(duplicate_view.validate_basic().is_err());
    }

    #[test]
    fn manifest_deserialization_rejects_unknown_top_level_fields() {
        let manifest = manifest();
        let mut value = serde_json::to_value(manifest).expect("serialize manifest");
        value
            .as_object_mut()
            .expect("manifest is an object")
            .insert("future_behavior".to_owned(), serde_json::Value::Bool(true));
        assert!(serde_json::from_value::<PluginManifest>(value).is_err());
    }

    #[test]
    fn ttx_v1_gate_requires_exact_plugin_manifest_bytes_and_rejects_old_aliases() {
        let canonical = include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/manifest.json");
        let parsed = PluginManifest::parse_ttx_v1_canonical(
            canonical.strip_suffix(b"\n").expect("fixture terminal LF"),
        )
        .expect("canonical TTX fixture");
        assert_eq!(parsed.publisher.as_str(), "timetrace-labs");
        assert_eq!(parsed.id.as_str(), "sample-insights");

        let whitespace = b" {\"schema_version\":1}";
        assert_eq!(
            PluginManifest::parse_ttx_v1_canonical(whitespace),
            Err(TtxManifestError::NonCanonical)
        );

        let legacy_aliases = br#"{"permissions":[],"plugin_id":"sample-insights","publisher_id":"timetrace-labs","schema_version":1}"#;
        assert!(matches!(
            PluginManifest::parse_ttx_v1_canonical(legacy_aliases),
            Err(TtxManifestError::InvalidManifest)
        ));

        let contribution = include_bytes!(
            "../../../contracts/fixtures/ttx-manifest-v1/nonempty-contributions.rejected.json"
        )
        .strip_suffix(b"\n")
        .expect("fixture terminal LF");
        assert!(PluginManifest::parse_ttx_v1_canonical(contribution).is_ok());
    }

    #[test]
    fn ttx_p1_allows_only_safe_declarative_contribution_profile() {
        let manifest = PluginManifest::parse_ttx_v1_canonical(
            include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/manifest-p1.json")
                .strip_suffix(b"\n")
                .expect("fixture terminal LF"),
        )
        .expect("P1 fixture");
        assert_eq!(manifest.contributions.len(), 4);

        let mut bundled = manifest.clone();
        let ContributionDescriptor::Page(page) = &mut bundled.contributions[0] else {
            panic!("fixture page")
        };
        page.renderer = RendererRef::BundledTyped {
            contract_id: crate::RendererContractId::new("first-party").expect("id"),
            schema_version: 1,
        };
        assert_eq!(
            bundled.validate_marketplace_ttx_v1_activation_profile(),
            Err(TtxManifestError::UnsupportedMarketplaceContribution)
        );

        let mut required_capability = manifest.clone();
        let ContributionDescriptor::Page(page) = &mut required_capability.contributions[0] else {
            panic!("fixture page")
        };
        page.metadata.required_capabilities = vec![CapabilityId::new(AI_CLOUD).expect("id")];
        assert!(
            required_capability
                .validate_marketplace_ttx_v1_activation_profile()
                .is_err()
        );

        let settings = ContributionDescriptor::Settings(SettingsSectionDescriptor {
            metadata: ContributionMetadata {
                id: ContributionId::new("sample-insights.secrets").expect("id"),
                display: DisplayMetadata {
                    title: "Secrets".into(),
                    description: None,
                    icon: None,
                },
                order: 10,
                required_capabilities: vec![],
            },
            schema_version: 1,
            fields: vec![SettingFieldDescriptor {
                key: "token".into(),
                label: "Token".into(),
                kind: SettingValueKind::SecretReference,
                required: false,
                default_value: None,
            }],
        });
        let mut secret = manifest;
        secret.contributions.push(settings);
        assert!(
            secret
                .validate_marketplace_ttx_v1_activation_profile()
                .is_err()
        );
    }

    #[test]
    fn first_party_bundled_profile_is_exact_and_p1_remains_closed() {
        let fixture = include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json"
        )
        .strip_suffix(b"\n")
        .unwrap_or(include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/manifest.json"
        ));
        let bundled =
            PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(fixture)
                .expect("fixed bundled fixture");
        assert_eq!(
            PluginManifest::parse_ttx_v1_canonical(fixture),
            Err(TtxManifestError::UnsupportedMarketplaceContribution)
        );

        let mut wrong_renderer = bundled.clone();
        let ContributionDescriptor::Page(page) = &mut wrong_renderer.contributions[0] else {
            panic!("fixture page")
        };
        page.renderer = RendererRef::BundledTyped {
            contract_id: crate::RendererContractId::new("private-flight-v2").expect("id"),
            schema_version: 1,
        };
        assert_eq!(
            wrong_renderer.validate_marketplace_first_party_bundled_v1_profile(),
            Err(TtxManifestError::UnsupportedMarketplaceContribution)
        );

        let mut extra_contribution = bundled;
        extra_contribution
            .contributions
            .push(ContributionDescriptor::Command(CommandDescriptor {
                metadata: ContributionMetadata {
                    id: ContributionId::new("private-flight.command").expect("id"),
                    display: DisplayMetadata {
                        title: "起飞记录".into(),
                        description: None,
                        icon: None,
                    },
                    order: 0,
                    required_capabilities: vec![],
                },
                input_schema_version: 1,
                timeout_ms: 1,
            }));
        assert!(
            extra_contribution
                .validate_marketplace_first_party_bundled_v1_profile()
                .is_err()
        );
    }

    #[test]
    fn ai_recap_bundled_profile_is_exact_and_cannot_cross_bind() {
        let fixture = include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/ai-recap.manifest.json"
        )
        .strip_suffix(b"\n")
        .unwrap_or(include_bytes!(
            "../../../contracts/fixtures/ttx-marketplace-first-party-bundled-v1/ai-recap.manifest.json"
        ));
        let ai_recap =
            PluginManifest::parse_ttx_marketplace_first_party_bundled_v1_canonical(fixture)
                .expect("AI Recap P2 fixture");
        assert_eq!(
            PluginManifest::parse_ttx_v1_canonical(fixture),
            Err(TtxManifestError::UnsupportedMarketplaceContribution)
        );

        let mut missing_usage = ai_recap.clone();
        missing_usage
            .requested_capabilities
            .retain(|request| request.id.as_str() != USAGE_AGGREGATE_READ);
        assert!(
            missing_usage
                .validate_marketplace_first_party_bundled_v1_profile()
                .is_err()
        );

        let mut cross_bound = ai_recap.clone();
        let ContributionDescriptor::Page(page) = &mut cross_bound.contributions[0] else {
            panic!("fixture page")
        };
        page.renderer = RendererRef::BundledTyped {
            contract_id: crate::RendererContractId::new("private-flight-v1").expect("id"),
            schema_version: 1,
        };
        assert_eq!(
            cross_bound.validate_marketplace_first_party_bundled_v1_profile(),
            Err(TtxManifestError::UnsupportedMarketplaceContribution)
        );

        let mut unexpected_capability = ai_recap;
        unexpected_capability
            .requested_capabilities
            .push(CapabilityRequest {
                id: CapabilityId::new("journal.read").expect("id"),
                constraints: CapabilityConstraints::default(),
                rationale: None,
            });
        assert!(
            unexpected_capability
                .validate_marketplace_first_party_bundled_v1_profile()
                .is_err()
        );
    }

    #[test]
    fn manifest_rejects_oversized_contribution_and_capability_sets() {
        let mut contributions = manifest();
        contributions.contributions = (0..=MAX_CONTRIBUTIONS_PER_PLUGIN)
            .map(|index| {
                ContributionDescriptor::Page(PageDescriptor {
                    metadata: ContributionMetadata {
                        id: ContributionId::new(format!("sample-plugin.page-{index}"))
                            .expect("valid contribution"),
                        display: DisplayMetadata {
                            title: "Page".to_owned(),
                            description: None,
                            icon: None,
                        },
                        order: index as i32,
                        required_capabilities: Vec::new(),
                    },
                    view_id: format!("page-{index}"),
                    renderer: RendererRef::DeclarativeV1,
                })
            })
            .collect();
        assert!(matches!(
            contributions.validate_basic(),
            Err(ContractError::LimitExceeded {
                field: "contributions",
                ..
            })
        ));

        let mut capabilities = manifest();
        capabilities.requested_capabilities = (0..=MAX_CAPABILITIES_PER_PLUGIN)
            .map(|index| CapabilityRequest {
                id: CapabilityId::new(format!("capability-{index}")).expect("valid capability"),
                constraints: CapabilityConstraints::default(),
                rationale: None,
            })
            .collect();
        assert!(matches!(
            capabilities.validate_basic(),
            Err(ContractError::LimitExceeded {
                field: "requested_capabilities",
                ..
            })
        ));
    }
}
