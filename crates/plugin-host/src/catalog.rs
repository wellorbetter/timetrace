//! Deterministic validation and immutable catalog snapshots.

use std::{collections::HashSet, sync::Arc};

use semver::Version;
use thiserror::Error;
use timetrace_plugin_api::{
    ContractError, ContributionDescriptor, ContributionId, Platform, PluginId, PluginManifest,
};

/// Maximum plugin descriptors admitted into one catalog snapshot.
pub const MAX_CATALOG_PLUGINS: usize = 256;

/// The result of checking a manifest against the running host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginCompatibility {
    /// The host API and current platform are both supported.
    Compatible,
    /// The manifest's host API range does not include the running host.
    IncompatibleHostApi,
    /// The manifest does not list the current host platform.
    UnsupportedPlatform,
    /// Neither the host API nor current platform is supported.
    IncompatibleHostApiAndPlatform,
}

impl PluginCompatibility {
    /// Returns whether plugin code and contributions may become active.
    #[must_use]
    pub fn is_compatible(self) -> bool {
        self == Self::Compatible
    }
}

/// A validated, read-only plugin descriptor in deterministic contribution order.
#[derive(Debug, Clone)]
pub struct PluginDescriptor {
    manifest: Arc<PluginManifest>,
    ordered_contributions: Arc<[ContributionDescriptor]>,
    compatibility: PluginCompatibility,
}

impl PluginDescriptor {
    fn new(manifest: PluginManifest, host_api: &Version, platform: Platform) -> Self {
        let host_compatible = manifest.host_api.matches(host_api);
        let platform_compatible = manifest.platforms.contains(&platform);
        let compatibility = match (host_compatible, platform_compatible) {
            (true, true) => PluginCompatibility::Compatible,
            (false, true) => PluginCompatibility::IncompatibleHostApi,
            (true, false) => PluginCompatibility::UnsupportedPlatform,
            (false, false) => PluginCompatibility::IncompatibleHostApiAndPlatform,
        };

        let mut ordered_contributions = manifest.contributions.clone();
        ordered_contributions.sort_by(|left, right| {
            left.metadata()
                .order
                .cmp(&right.metadata().order)
                .then_with(|| left.id().cmp(right.id()))
        });
        Self {
            manifest: Arc::new(manifest),
            ordered_contributions: ordered_contributions.into(),
            compatibility,
        }
    }

    /// Returns the canonical validated manifest exactly as registered.
    #[must_use]
    pub fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    /// Returns contributions sorted by `(order, contribution_id)`.
    #[must_use]
    pub fn contributions(&self) -> &[ContributionDescriptor] {
        &self.ordered_contributions
    }

    /// Returns the compatibility classification for the running host.
    #[must_use]
    pub fn compatibility(&self) -> PluginCompatibility {
        self.compatibility
    }

    /// Returns whether this descriptor may later be activated.
    #[must_use]
    pub fn is_compatible(&self) -> bool {
        self.compatibility.is_compatible()
    }
}

/// An immutable, cheaply cloned catalog view.
#[derive(Debug, Clone)]
pub struct CatalogSnapshot {
    host_api: Version,
    platform: Platform,
    plugins: Arc<[PluginDescriptor]>,
}

impl CatalogSnapshot {
    /// Returns the host API version used for compatibility classification.
    #[must_use]
    pub fn host_api(&self) -> &Version {
        &self.host_api
    }

    /// Returns the platform used for compatibility classification.
    #[must_use]
    pub fn platform(&self) -> Platform {
        self.platform
    }

    /// Returns descriptors sorted by plugin identifier.
    #[must_use]
    pub fn plugins(&self) -> &[PluginDescriptor] {
        &self.plugins
    }

    /// Finds a descriptor by plugin identifier using the snapshot's sorted index.
    #[must_use]
    pub fn find(&self, plugin_id: &PluginId) -> Option<&PluginDescriptor> {
        self.plugins
            .binary_search_by(|descriptor| descriptor.manifest.id.cmp(plugin_id))
            .ok()
            .and_then(|index| self.plugins.get(index))
    }

    /// Returns the number of registered descriptors.
    #[must_use]
    pub fn len(&self) -> usize {
        self.plugins.len()
    }

    /// Returns whether the snapshot contains no descriptors.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.plugins.is_empty()
    }
}

/// A validated catalog that publishes immutable deterministic snapshots.
#[derive(Debug, Clone)]
pub struct PluginCatalog {
    snapshot: CatalogSnapshot,
}

impl PluginCatalog {
    /// Validates all manifests and builds an immutable catalog.
    ///
    /// Incompatible manifests remain visible with a non-compatible status so
    /// management UI can explain why they are inert. Malformed or duplicate
    /// identities reject the complete build without publishing a partial view.
    pub fn build(
        host_api: Version,
        platform: Platform,
        manifests: impl IntoIterator<Item = PluginManifest>,
    ) -> Result<Self, CatalogError> {
        let mut plugin_ids = HashSet::new();
        let mut contribution_ids = HashSet::new();
        let mut descriptors = Vec::new();

        for manifest in manifests {
            if descriptors.len() >= MAX_CATALOG_PLUGINS {
                return Err(CatalogError::CatalogLimitExceeded {
                    limit: MAX_CATALOG_PLUGINS,
                });
            }
            manifest
                .validate_basic()
                .map_err(|source| CatalogError::InvalidManifest { source })?;

            for contribution in &manifest.contributions {
                if !contribution_ids.insert(contribution.id().clone()) {
                    return Err(CatalogError::DuplicateContributionId {
                        contribution_id: contribution.id().clone(),
                    });
                }
            }
            if !plugin_ids.insert(manifest.id.clone()) {
                return Err(CatalogError::DuplicatePluginId {
                    plugin_id: manifest.id,
                });
            }
            descriptors.push(PluginDescriptor::new(manifest, &host_api, platform));
        }

        descriptors.sort_by(|left, right| left.manifest.id.cmp(&right.manifest.id));
        Ok(Self {
            snapshot: CatalogSnapshot {
                host_api,
                platform,
                plugins: descriptors.into(),
            },
        })
    }

    /// Returns a cheaply cloned immutable snapshot.
    #[must_use]
    pub fn snapshot(&self) -> CatalogSnapshot {
        self.snapshot.clone()
    }
}

/// Errors that prevent a catalog snapshot from being published.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CatalogError {
    /// A manifest failed canonical structural validation.
    #[error("plugin manifest failed canonical validation")]
    InvalidManifest {
        /// Underlying canonical validation failure.
        #[source]
        source: ContractError,
    },
    /// A plugin identifier was registered more than once.
    #[error("duplicate plugin identifier")]
    DuplicatePluginId {
        /// Duplicate non-sensitive plugin identifier.
        plugin_id: PluginId,
    },
    /// A contribution identifier was registered more than once globally.
    #[error("duplicate contribution identifier")]
    DuplicateContributionId {
        /// Duplicate non-sensitive contribution identifier.
        contribution_id: ContributionId,
    },
    /// The catalog exceeded its bounded plugin count.
    #[error("plugin catalog exceeds its descriptor limit")]
    CatalogLimitExceeded {
        /// Maximum number of admitted plugins.
        limit: usize,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use timetrace_plugin_api::{
        CURRENT_MANIFEST_SCHEMA_VERSION, CapabilityConstraints, CapabilityId, CapabilityRequest,
        CardDescriptor, ContributionMetadata, DashboardSize, DisplayMetadata, HostApiRange,
        PublisherId, RefreshPolicy, USAGE_AGGREGATE_READ,
    };

    fn manifest(id: &str, host_api: &str, platforms: Vec<Platform>) -> PluginManifest {
        PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: PluginId::new(id).expect("valid plugin id"),
            publisher: PublisherId::new("wellorbetter").expect("valid publisher"),
            display_name: id.to_owned(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(host_api).expect("valid host requirement"),
            platforms,
            contributions: Vec::new(),
            requested_capabilities: vec![CapabilityRequest {
                id: CapabilityId::new(USAGE_AGGREGATE_READ).expect("valid capability"),
                constraints: CapabilityConstraints::default(),
                rationale: None,
            }],
        }
    }

    fn card(plugin_id: &str, suffix: &str, order: i32) -> ContributionDescriptor {
        ContributionDescriptor::DashboardCard(CardDescriptor {
            metadata: ContributionMetadata {
                id: ContributionId::new(format!("{plugin_id}.{suffix}"))
                    .expect("valid contribution"),
                display: DisplayMetadata {
                    title: suffix.to_owned(),
                    description: None,
                    icon: None,
                },
                order,
                required_capabilities: Vec::new(),
            },
            renderer: timetrace_plugin_api::RendererRef::DeclarativeV1,
            size: DashboardSize::Small,
            refresh: RefreshPolicy::OnDemand,
        })
    }

    #[test]
    fn catalog_snapshot_has_deterministic_plugin_and_contribution_order() {
        let mut second = manifest("plugin-b", ">=1.0.0, <2.0.0", vec![Platform::WindowsX64]);
        second.contributions = vec![
            card("plugin-b", "z-card", 10),
            card("plugin-b", "a-card", 10),
            card("plugin-b", "first", -1),
        ];
        let first = manifest("plugin-a", ">=1.0.0, <2.0.0", vec![Platform::WindowsX64]);

        let catalog =
            PluginCatalog::build(Version::new(1, 2, 0), Platform::WindowsX64, [second, first])
                .expect("valid catalog");
        let snapshot = catalog.snapshot();
        assert_eq!(snapshot.len(), 2);
        assert!(!snapshot.is_empty());
        assert_eq!(snapshot.host_api(), &Version::new(1, 2, 0));
        assert_eq!(snapshot.platform(), Platform::WindowsX64);
        assert_eq!(snapshot.plugins()[0].manifest().id.as_str(), "plugin-a");
        let plugin_b = snapshot
            .find(&PluginId::new("plugin-b").expect("valid plugin id"))
            .expect("plugin b exists");
        let ids: Vec<_> = plugin_b
            .contributions()
            .iter()
            .map(|contribution| contribution.id().as_str())
            .collect();
        assert_eq!(
            ids,
            ["plugin-b.first", "plugin-b.a-card", "plugin-b.z-card"]
        );
    }

    #[test]
    fn incompatible_plugins_remain_inert_but_visible() {
        let host_mismatch = manifest(
            "host-mismatch",
            ">=2.0.0, <3.0.0",
            vec![Platform::WindowsX64],
        );
        let platform_mismatch = manifest(
            "platform-mismatch",
            ">=1.0.0, <2.0.0",
            vec![Platform::LinuxX64],
        );
        let both = manifest("both-mismatch", ">=2.0.0, <3.0.0", vec![Platform::LinuxX64]);
        let catalog = PluginCatalog::build(
            Version::new(1, 4, 0),
            Platform::WindowsX64,
            [host_mismatch, platform_mismatch, both],
        )
        .expect("incompatible descriptors are still catalogued");
        let snapshot = catalog.snapshot();
        let status = |id: &str| {
            snapshot
                .find(&PluginId::new(id).expect("valid plugin id"))
                .expect("descriptor exists")
                .compatibility()
        };
        assert_eq!(
            status("host-mismatch"),
            PluginCompatibility::IncompatibleHostApi
        );
        assert_eq!(
            status("platform-mismatch"),
            PluginCompatibility::UnsupportedPlatform
        );
        assert_eq!(
            status("both-mismatch"),
            PluginCompatibility::IncompatibleHostApiAndPlatform
        );
        assert!(
            snapshot
                .plugins()
                .iter()
                .all(|plugin| !plugin.is_compatible())
        );
    }

    #[test]
    fn malformed_or_duplicate_catalog_input_publishes_nothing() {
        let mut malformed = manifest("malformed", ">=1.0.0, <2.0.0", vec![Platform::WindowsX64]);
        malformed.schema_version = 99;
        assert!(matches!(
            PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, [malformed]),
            Err(CatalogError::InvalidManifest { .. })
        ));

        let first = manifest("duplicate", ">=1.0.0, <2.0.0", vec![Platform::WindowsX64]);
        let second = first.clone();
        assert!(matches!(
            PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, [first, second]),
            Err(CatalogError::DuplicatePluginId { .. })
        ));

        let mut first = manifest(
            "duplicate-with-contribution",
            ">=1.0.0, <2.0.0",
            vec![Platform::WindowsX64],
        );
        first.contributions = vec![card("duplicate-with-contribution", "same-card", 0)];
        let second = first.clone();
        assert!(matches!(
            PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, [first, second]),
            Err(CatalogError::DuplicateContributionId { .. })
        ));
    }

    #[test]
    fn catalog_rejects_oversized_plugin_sets() {
        let manifests = (0..=MAX_CATALOG_PLUGINS).map(|index| {
            manifest(
                &format!("plugin-{index}"),
                ">=1.0.0, <2.0.0",
                vec![Platform::WindowsX64],
            )
        });
        assert!(matches!(
            PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, manifests),
            Err(CatalogError::CatalogLimitExceeded {
                limit: MAX_CATALOG_PLUGINS
            })
        ));
    }
}
