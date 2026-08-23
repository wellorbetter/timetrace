//! Strict, non-executable Marketplace P1 declarative document contract.
//!
//! Documents are signed archive resources, never remote UI payloads.  The
//! host resolves their path from the contribution identifier rather than from
//! a value supplied by the package.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::ContributionId;

/// Maximum bytes in one declarative document resource.
pub const MAX_DECLARATIVE_V1_DOCUMENT_BYTES: usize = 128 * 1024;
/// Maximum nodes in one document tree.
pub const MAX_DECLARATIVE_V1_NODES: usize = 256;
/// Maximum nesting depth of a document tree.
pub const MAX_DECLARATIVE_V1_DEPTH: usize = 16;
/// Maximum direct children/items in one container node.
pub const MAX_DECLARATIVE_V1_CHILDREN: usize = 64;
/// Maximum UTF-8 bytes in an individual rendered string.
pub const MAX_DECLARATIVE_V1_TEXT_BYTES: usize = 4 * 1024;

/// A signed host-rendered document for one page or dashboard card.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeclarativeV1Document {
    /// Frozen document schema version, currently exactly one.
    pub schema_version: u32,
    /// Contribution owning this resource.
    pub contribution_id: ContributionId,
    /// Root node rendered by the host-owned declarative renderer.
    pub root: DeclarativeV1Node,
}

/// The closed safe node set for Marketplace P1.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum DeclarativeV1Node {
    /// Plain untrusted text; the renderer never interprets it as markup.
    Text {
        /// Plain text rendered without markup interpretation.
        text: String,
    },
    /// A label/value pair rendered by the host without formatting instructions.
    Metric {
        /// Host-rendered metric label.
        label: String,
        /// Host-rendered metric value.
        value: String,
    },
    /// A vertical host layout containing child nodes.
    Stack {
        /// Child nodes in host-defined vertical order.
        children: Vec<DeclarativeV1Node>,
    },
    /// A bounded plain-text list.
    List {
        /// Plain text list items.
        items: Vec<String>,
    },
}

/// Stable parse or bounds failures at the signed declarative resource edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum DeclarativeV1Error {
    /// Resource byte size exceeds its fixed bound.
    #[error("declarative document exceeds its byte limit")]
    TooLarge,
    /// Resource is not a closed declarative v1 JSON document.
    #[error("declarative document is invalid")]
    Invalid,
    /// Schema version is unsupported.
    #[error("declarative document schema version is unsupported")]
    UnsupportedSchema,
    /// Signed document does not belong to the contribution whose fixed path was read.
    #[error("declarative document contribution identity differs from its path")]
    ContributionMismatch,
    /// Tree/collection/string bounds are exceeded.
    #[error("declarative document exceeds a structural limit")]
    LimitExceeded,
}

impl DeclarativeV1Document {
    /// Parses and bounds a signed `resources/declarative-v1/<id>.json` member.
    pub fn parse_for_contribution(
        bytes: &[u8],
        expected_contribution_id: &ContributionId,
    ) -> Result<Self, DeclarativeV1Error> {
        if bytes.len() > MAX_DECLARATIVE_V1_DOCUMENT_BYTES {
            return Err(DeclarativeV1Error::TooLarge);
        }
        let document: Self =
            serde_json::from_slice(bytes).map_err(|_| DeclarativeV1Error::Invalid)?;
        if document.schema_version != 1 {
            return Err(DeclarativeV1Error::UnsupportedSchema);
        }
        if &document.contribution_id != expected_contribution_id {
            return Err(DeclarativeV1Error::ContributionMismatch);
        }
        document.validate_bounds()?;
        Ok(document)
    }

    /// Returns the only archive resource path permitted for this contribution.
    #[must_use]
    pub fn resource_path(contribution_id: &ContributionId) -> String {
        format!("resources/declarative-v1/{}.json", contribution_id.as_str())
    }

    fn validate_bounds(&self) -> Result<(), DeclarativeV1Error> {
        let mut node_count = 0;
        validate_node(&self.root, 1, &mut node_count)
    }
}

fn validate_node(
    node: &DeclarativeV1Node,
    depth: usize,
    node_count: &mut usize,
) -> Result<(), DeclarativeV1Error> {
    if depth > MAX_DECLARATIVE_V1_DEPTH {
        return Err(DeclarativeV1Error::LimitExceeded);
    }
    *node_count += 1;
    if *node_count > MAX_DECLARATIVE_V1_NODES {
        return Err(DeclarativeV1Error::LimitExceeded);
    }
    match node {
        DeclarativeV1Node::Text { text } => validate_text(text),
        DeclarativeV1Node::Metric { label, value } => {
            validate_text(label)?;
            validate_text(value)
        }
        DeclarativeV1Node::Stack { children } => {
            if children.is_empty() || children.len() > MAX_DECLARATIVE_V1_CHILDREN {
                return Err(DeclarativeV1Error::LimitExceeded);
            }
            for child in children {
                validate_node(child, depth + 1, node_count)?;
            }
            Ok(())
        }
        DeclarativeV1Node::List { items } => {
            if items.is_empty() || items.len() > MAX_DECLARATIVE_V1_CHILDREN {
                return Err(DeclarativeV1Error::LimitExceeded);
            }
            for item in items {
                validate_text(item)?;
            }
            Ok(())
        }
    }
}

fn validate_text(value: &str) -> Result<(), DeclarativeV1Error> {
    (!value.is_empty() && value.len() <= MAX_DECLARATIVE_V1_TEXT_BYTES)
        .then_some(())
        .ok_or(DeclarativeV1Error::LimitExceeded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_fixture_with_fixed_resource_path() {
        let id = ContributionId::new("sample-insights.overview").expect("id");
        let document = DeclarativeV1Document::parse_for_contribution(
            include_bytes!("../../../contracts/fixtures/ttx-manifest-v1/resources/declarative-v1/sample-insights.overview.json"),
            &id,
        )
        .expect("fixture");
        assert_eq!(document.schema_version, 1);
        assert_eq!(
            DeclarativeV1Document::resource_path(&id),
            "resources/declarative-v1/sample-insights.overview.json"
        );
    }

    #[test]
    fn rejects_unknown_nodes_wrong_owner_and_unbounded_tree() {
        let id = ContributionId::new("sample-insights.overview").expect("id");
        assert_eq!(
            DeclarativeV1Document::parse_for_contribution(
                include_bytes!(
                    "../../../contracts/fixtures/ttx-manifest-v1/resources/declarative-v1/invalid-webview.rejected.json"
                ),
                &id,
            ),
            Err(DeclarativeV1Error::Invalid)
        );
        assert_eq!(
            DeclarativeV1Document::parse_for_contribution(
                br#"{"contribution_id":"sample-insights.other","root":{"kind":"text","text":"x"},"schema_version":1}"#,
                &id,
            ),
            Err(DeclarativeV1Error::ContributionMismatch)
        );
        let items = (0..=MAX_DECLARATIVE_V1_CHILDREN)
            .map(|_| "x")
            .collect::<Vec<_>>();
        let document = DeclarativeV1Document {
            schema_version: 1,
            contribution_id: id,
            root: DeclarativeV1Node::List {
                items: items.into_iter().map(str::to_owned).collect(),
            },
        };
        assert_eq!(
            document.validate_bounds(),
            Err(DeclarativeV1Error::LimitExceeded)
        );
    }
}
