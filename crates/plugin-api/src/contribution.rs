//! Declarative plugin contribution descriptors.

use std::collections::BTreeSet;

use schemars::JsonSchema;
use serde::{Deserialize, Deserializer, Serialize};

use crate::{
    CapabilityId, ContractError, ContributionId, RendererContractId, ScalarValue,
    validate_description, validate_label,
};

/// Maximum UTF-8 byte length accepted for a plain string setting default.
pub const MAX_SETTING_STRING_BYTES: usize = 2_048;
/// Maximum settings fields declared by one settings contribution.
pub const MAX_SETTINGS_FIELDS: usize = 128;
/// Maximum capabilities required by one contribution invocation.
pub const MAX_REQUIRED_CAPABILITIES_PER_CONTRIBUTION: usize = 32;

/// Human-readable metadata shared by contribution descriptors.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DisplayMetadata {
    /// Localized or user-facing contribution title.
    pub title: String,
    /// Optional short, non-sensitive description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Optional host-recognized icon token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

impl DisplayMetadata {
    /// Validates display string limits without interpreting presentation.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        validate_label("contribution_title", &self.title)?;
        validate_description("contribution_description", self.description.as_deref())?;
        if let Some(icon) = &self.icon {
            validate_label("contribution_icon", icon)?;
        }
        Ok(())
    }
}

/// Metadata and authorization shared by every contribution kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ContributionMetadata {
    /// Globally stable, plugin-namespaced contribution identifier.
    pub id: ContributionId,
    /// User-visible metadata.
    pub display: DisplayMetadata,
    /// Stable projection order; ties are resolved by identifier.
    pub order: i32,
    /// Capabilities rechecked each time this contribution is invoked.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[schemars(length(max = 32))]
    pub required_capabilities: Vec<CapabilityId>,
}

impl ContributionMetadata {
    /// Validates identity, display metadata, and duplicate capability requests.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.id.validate()?;
        self.display.validate_basic()?;
        if self.required_capabilities.len() > MAX_REQUIRED_CAPABILITIES_PER_CONTRIBUTION {
            return Err(ContractError::LimitExceeded {
                field: "required_capabilities",
                limit: MAX_REQUIRED_CAPABILITIES_PER_CONTRIBUTION as u64,
            });
        }
        let mut seen = BTreeSet::new();
        for capability in &self.required_capabilities {
            capability.validate()?;
            if !seen.insert(capability.as_str()) {
                return Err(ContractError::DuplicateIdentifier {
                    field: "required_capabilities",
                    value: capability.to_string(),
                });
            }
        }
        Ok(())
    }
}

/// A host-owned renderer selected by contract, never by plugin identifier.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, JsonSchema)]
#[serde(tag = "mode", rename_all = "snake_case", deny_unknown_fields)]
pub enum RendererRef {
    /// A first-party renderer compiled into the host.
    BundledTyped {
        /// Renderer contract identifier.
        contract_id: RendererContractId,
        /// Renderer payload schema version.
        schema_version: u32,
    },
    /// Version one of the safe declarative node renderer.
    DeclarativeV1,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum BundledRendererModeWire {
    BundledTyped,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum DeclarativeRendererModeWire {
    DeclarativeV1,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BundledRendererRefWire {
    mode: BundledRendererModeWire,
    contract_id: RendererContractId,
    schema_version: u32,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeclarativeRendererRefWire {
    mode: DeclarativeRendererModeWire,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum RendererRefWire {
    Bundled(BundledRendererRefWire),
    Declarative(DeclarativeRendererRefWire),
}

impl<'de> Deserialize<'de> for RendererRef {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = RendererRefWire::deserialize(deserializer)?;
        match wire {
            RendererRefWire::Bundled(value) => {
                let BundledRendererModeWire::BundledTyped = value.mode;
                Ok(Self::BundledTyped {
                    contract_id: value.contract_id,
                    schema_version: value.schema_version,
                })
            }
            RendererRefWire::Declarative(value) => {
                let DeclarativeRendererModeWire::DeclarativeV1 = value.mode;
                Ok(Self::DeclarativeV1)
            }
        }
    }
}

impl RendererRef {
    /// Validates renderer identifiers and schema versions.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        match self {
            Self::BundledTyped {
                contract_id,
                schema_version,
            } => {
                contract_id.validate()?;
                if *schema_version == 0 {
                    return Err(ContractError::InvalidContribution {
                        field: "renderer_schema_version",
                    });
                }
                Ok(())
            }
            Self::DeclarativeV1 => Ok(()),
        }
    }
}

/// A navigation destination pointing to a page contribution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct NavigationDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Page contribution opened by the destination.
    pub page_id: ContributionId,
}

/// A host-namespaced page route contribution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PageDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Stable view segment used under `/extensions/{pluginId}/`.
    pub view_id: String,
    /// Renderer used for the page body.
    pub renderer: RendererRef,
}

/// Host-recognized dashboard layout sizes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum DashboardSize {
    /// A compact one-column card.
    Small,
    /// A standard medium card.
    Medium,
    /// A large card spanning the primary grid width.
    Large,
    /// A wide carousel item.
    Wide,
}

/// Host-controlled refresh policies for dashboard contributions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum RefreshPolicy {
    /// Refresh only after an explicit host or user action.
    OnDemand,
    /// Refresh after the relevant immutable data revision changes.
    DataRevision,
}

/// A dashboard carousel contribution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CarouselDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Renderer used for the carousel item.
    pub renderer: RendererRef,
    /// Host-recognized layout size.
    pub size: DashboardSize,
    /// Host-controlled refresh behavior.
    pub refresh: RefreshPolicy,
}

/// A dashboard card contribution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CardDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Renderer used for the card body.
    pub renderer: RendererRef,
    /// Host-recognized layout size.
    pub size: DashboardSize,
    /// Host-controlled refresh behavior.
    pub refresh: RefreshPolicy,
}

/// Supported schema-driven setting value kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SettingValueKind {
    /// Boolean toggle.
    Boolean,
    /// Signed integer input.
    Integer,
    /// Bounded single-line string input.
    String,
    /// Host-owned opaque secret-reference picker.
    SecretReference,
}

/// A single schema-driven setting field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SettingFieldDescriptor {
    /// Plugin-local lowercase field key.
    pub key: String,
    /// User-visible label.
    pub label: String,
    /// Expected value kind.
    pub kind: SettingValueKind,
    /// Whether a configured value is required.
    pub required: bool,
    /// Optional non-secret default value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_value: Option<ScalarValue>,
}

impl SettingFieldDescriptor {
    /// Validates field names, labels, and secret default restrictions.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        crate::ContributionId::new(self.key.clone())?;
        validate_label("setting_label", &self.label)?;
        match (self.kind, &self.default_value) {
            (_, None)
            | (SettingValueKind::Boolean, Some(ScalarValue::Boolean(_)))
            | (SettingValueKind::Integer, Some(ScalarValue::Integer(_))) => {}
            (SettingValueKind::String, Some(ScalarValue::String(value))) => {
                if value.len() > MAX_SETTING_STRING_BYTES {
                    return Err(ContractError::FieldTooLong {
                        field: "setting_default_string",
                        max_bytes: MAX_SETTING_STRING_BYTES,
                    });
                }
            }
            (SettingValueKind::SecretReference, Some(_)) => {
                return Err(ContractError::InvalidContribution {
                    field: "secret_default_value",
                });
            }
            _ => {
                return Err(ContractError::InvalidContribution {
                    field: "setting_default_type",
                });
            }
        }
        Ok(())
    }
}

/// A schema-driven settings section contribution.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SettingsSectionDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Settings schema version owned by this plugin.
    pub schema_version: u32,
    /// Ordered fields rendered and persisted by the host.
    #[schemars(length(max = 128))]
    pub fields: Vec<SettingFieldDescriptor>,
}

/// A command contribution executed through the host command bus.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct CommandDescriptor {
    /// Shared contribution metadata.
    pub metadata: ContributionMetadata,
    /// Version of the command input payload schema.
    pub input_schema_version: u32,
    /// Hard command deadline in milliseconds.
    pub timeout_ms: u32,
}

/// All contribution kinds supported by the P0 host.
///
/// Every nested contribution object rejects unknown fields. An untrusted RPC
/// transport must still enforce a bounded frame size before serde begins,
/// because schema validation cannot prevent allocation of an oversized frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(
    tag = "kind",
    content = "descriptor",
    rename_all = "snake_case",
    deny_unknown_fields
)]
pub enum ContributionDescriptor {
    /// Navigation destination contribution.
    Navigation(NavigationDescriptor),
    /// Page route contribution.
    Page(PageDescriptor),
    /// Dashboard carousel contribution.
    DashboardCarousel(CarouselDescriptor),
    /// Dashboard card contribution.
    DashboardCard(CardDescriptor),
    /// Settings section contribution.
    Settings(SettingsSectionDescriptor),
    /// Host command contribution.
    Command(CommandDescriptor),
}

impl ContributionDescriptor {
    /// Returns the stable identifier shared by all descriptor variants.
    #[must_use]
    pub fn id(&self) -> &ContributionId {
        &self.metadata().id
    }

    /// Returns shared metadata for deterministic projection.
    #[must_use]
    pub fn metadata(&self) -> &ContributionMetadata {
        match self {
            Self::Navigation(value) => &value.metadata,
            Self::Page(value) => &value.metadata,
            Self::DashboardCarousel(value) => &value.metadata,
            Self::DashboardCard(value) => &value.metadata,
            Self::Settings(value) => &value.metadata,
            Self::Command(value) => &value.metadata,
        }
    }

    /// Validates common metadata and variant-specific bounded settings.
    pub fn validate_basic(&self) -> Result<(), ContractError> {
        self.metadata().validate_basic()?;
        match self {
            Self::Navigation(value) => value.page_id.validate(),
            Self::Page(value) => {
                crate::ContributionId::new(value.view_id.clone())?;
                value.renderer.validate_basic()
            }
            Self::DashboardCarousel(value) => value.renderer.validate_basic(),
            Self::DashboardCard(value) => value.renderer.validate_basic(),
            Self::Settings(value) => {
                if value.schema_version == 0 || value.fields.is_empty() {
                    return Err(ContractError::InvalidContribution {
                        field: "settings_schema",
                    });
                }
                if value.fields.len() > MAX_SETTINGS_FIELDS {
                    return Err(ContractError::LimitExceeded {
                        field: "settings_fields",
                        limit: MAX_SETTINGS_FIELDS as u64,
                    });
                }
                let mut keys = BTreeSet::new();
                for field in &value.fields {
                    field.validate_basic()?;
                    if !keys.insert(field.key.as_str()) {
                        return Err(ContractError::DuplicateIdentifier {
                            field: "settings_fields",
                            value: field.key.clone(),
                        });
                    }
                }
                Ok(())
            }
            Self::Command(value) => {
                if value.input_schema_version == 0 || !(1..=5_000).contains(&value.timeout_ms) {
                    return Err(ContractError::InvalidContribution {
                        field: "command_budget",
                    });
                }
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata(id: &str) -> ContributionMetadata {
        ContributionMetadata {
            id: ContributionId::new(id).expect("valid contribution"),
            display: DisplayMetadata {
                title: "Sample".to_owned(),
                description: None,
                icon: Some("dashboard".to_owned()),
            },
            order: 10,
            required_capabilities: Vec::new(),
        }
    }

    #[test]
    fn page_exposes_common_metadata_and_validates_renderer() {
        let descriptor = ContributionDescriptor::Page(PageDescriptor {
            metadata: metadata("sample.page"),
            view_id: "overview".to_owned(),
            renderer: RendererRef::DeclarativeV1,
        });
        assert_eq!(descriptor.id().as_str(), "sample.page");
        assert_eq!(descriptor.metadata().order, 10);
        assert!(descriptor.validate_basic().is_ok());
    }

    #[test]
    fn contribution_rejects_oversized_required_capability_sets() {
        let mut metadata = metadata("sample.page");
        metadata.required_capabilities = (0..=MAX_REQUIRED_CAPABILITIES_PER_CONTRIBUTION)
            .map(|index| {
                CapabilityId::new(format!("capability-{index}"))
                    .expect("valid capability identifier")
            })
            .collect();
        assert!(matches!(
            metadata.validate_basic(),
            Err(ContractError::LimitExceeded {
                field: "required_capabilities",
                ..
            })
        ));
    }

    #[test]
    fn settings_reject_secret_defaults_and_duplicate_keys() {
        let descriptor = ContributionDescriptor::Settings(SettingsSectionDescriptor {
            metadata: metadata("sample.settings"),
            schema_version: 1,
            fields: vec![SettingFieldDescriptor {
                key: "api-key".to_owned(),
                label: "API key".to_owned(),
                kind: SettingValueKind::SecretReference,
                required: true,
                default_value: Some(ScalarValue::String("plaintext".to_owned())),
            }],
        });
        assert!(descriptor.validate_basic().is_err());
    }

    #[test]
    fn settings_validate_default_types_and_string_bounds() {
        let mismatched = SettingFieldDescriptor {
            key: "enabled".to_owned(),
            label: "Enabled".to_owned(),
            kind: SettingValueKind::Boolean,
            required: false,
            default_value: Some(ScalarValue::String("true".to_owned())),
        };
        assert!(mismatched.validate_basic().is_err());

        let oversized = SettingFieldDescriptor {
            key: "summary".to_owned(),
            label: "Summary".to_owned(),
            kind: SettingValueKind::String,
            required: false,
            default_value: Some(ScalarValue::String(
                "x".repeat(MAX_SETTING_STRING_BYTES + 1),
            )),
        };
        assert!(oversized.validate_basic().is_err());

        let valid = SettingFieldDescriptor {
            key: "retries".to_owned(),
            label: "Retries".to_owned(),
            kind: SettingValueKind::Integer,
            required: false,
            default_value: Some(ScalarValue::Integer(3)),
        };
        assert!(valid.validate_basic().is_ok());
    }

    #[test]
    fn command_requires_a_bounded_deadline() {
        let descriptor = ContributionDescriptor::Command(CommandDescriptor {
            metadata: metadata("sample.command"),
            input_schema_version: 1,
            timeout_ms: 5_001,
        });
        assert!(descriptor.validate_basic().is_err());
    }

    #[test]
    fn settings_reject_oversized_field_collections() {
        let fields = (0..=MAX_SETTINGS_FIELDS)
            .map(|index| SettingFieldDescriptor {
                key: format!("field-{index}"),
                label: "Field".to_owned(),
                kind: SettingValueKind::Boolean,
                required: false,
                default_value: None,
            })
            .collect();
        let descriptor = ContributionDescriptor::Settings(SettingsSectionDescriptor {
            metadata: metadata("sample.settings"),
            schema_version: 1,
            fields,
        });
        assert!(matches!(
            descriptor.validate_basic(),
            Err(ContractError::LimitExceeded {
                field: "settings_fields",
                ..
            })
        ));
    }

    #[test]
    fn contribution_wire_rejects_unknown_fields_at_every_object_layer() {
        let fixtures = [
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample"},
                        "order":0
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1"}
                },
                "outer_unknown":true
            }"#,
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample"},
                        "order":0
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1"},
                    "descriptor_unknown":true
                }
            }"#,
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample"},
                        "order":0,
                        "metadata_unknown":true
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1"}
                }
            }"#,
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample","display_unknown":true},
                        "order":0
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1"}
                }
            }"#,
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample"},
                        "order":0
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1","renderer_unknown":true}
                }
            }"#,
            r#"{
                "kind":"page",
                "descriptor":{
                    "metadata":{
                        "id":"sample.page",
                        "display":{"title":"Sample"},
                        "order":0
                    },
                    "view_id":"overview",
                    "renderer":{"mode":"declarative_v1","contract_id":null}
                }
            }"#,
            r#"{
                "kind":"settings",
                "descriptor":{
                    "metadata":{
                        "id":"sample.settings",
                        "display":{"title":"Settings"},
                        "order":0
                    },
                    "schema_version":1,
                    "fields":[{
                        "key":"enabled",
                        "label":"Enabled",
                        "kind":"boolean",
                        "required":false,
                        "field_unknown":true
                    }]
                }
            }"#,
            r#"{
                "kind":"settings",
                "descriptor":{
                    "metadata":{
                        "id":"sample.settings",
                        "display":{"title":"Settings"},
                        "order":0
                    },
                    "schema_version":1,
                    "fields":[{
                        "key":"enabled",
                        "label":"Enabled",
                        "kind":"boolean",
                        "required":false,
                        "default_value":{
                            "type":"boolean",
                            "value":true,
                            "scalar_unknown":true
                        }
                    }]
                }
            }"#,
        ];
        for (index, fixture) in fixtures.into_iter().enumerate() {
            assert!(
                serde_json::from_str::<ContributionDescriptor>(fixture).is_err(),
                "unknown-field fixture {index} was accepted"
            );
        }
    }

    #[test]
    fn contribution_schema_closes_nested_object_shapes() {
        let schema = serde_json::to_value(schemars::schema_for!(ContributionDescriptor))
            .expect("serialize contribution schema");
        let serialized = serde_json::to_string(&schema).expect("encode schema");
        let closed_objects = serialized
            .matches(r#""additionalProperties":false"#)
            .count();
        assert!(
            closed_objects >= 8,
            "nested contribution objects must be closed"
        );
    }
}
