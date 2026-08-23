//! Immutable, deterministic host projection of visible plugin contributions.

use std::{collections::BTreeMap, sync::Arc};

use thiserror::Error;
use timetrace_plugin_api::{ContributionDescriptor, ContributionId, LifecycleSnapshot, PluginId};

use crate::CatalogSnapshot;

/// One visible contribution backed by canonical catalog-owned data.
///
/// Cloning this value only clones `Arc` handles; descriptor trees are never
/// deep-copied while snapshots are rebuilt or split into host surfaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectedContribution {
    plugin_id: Arc<PluginId>,
    descriptor: Arc<ContributionDescriptor>,
    route: Option<Arc<str>>,
    resolved_page: Option<Arc<ContributionDescriptor>>,
}

impl ProjectedContribution {
    /// Returns the plugin that owns this contribution.
    #[must_use]
    pub fn plugin_id(&self) -> &PluginId {
        &self.plugin_id
    }

    /// Returns the canonical catalog descriptor without copying it.
    #[must_use]
    pub fn descriptor(&self) -> &ContributionDescriptor {
        &self.descriptor
    }

    /// Returns the host-generated page route, or navigation target route.
    #[must_use]
    pub fn route(&self) -> Option<&str> {
        self.route.as_deref()
    }

    /// Returns the resolved page descriptor for a navigation contribution.
    #[must_use]
    pub fn resolved_page(&self) -> Option<&ContributionDescriptor> {
        self.resolved_page.as_deref()
    }
}

/// Immutable contribution view partitioned by host-owned UI surface.
#[derive(Debug, Clone)]
pub struct ContributionSnapshot {
    revision: u64,
    navigation: Arc<[ProjectedContribution]>,
    pages: Arc<[ProjectedContribution]>,
    dashboard_cards: Arc<[ProjectedContribution]>,
    dashboard_carousels: Arc<[ProjectedContribution]>,
    settings: Arc<[ProjectedContribution]>,
    commands: Arc<[ProjectedContribution]>,
}

impl ContributionSnapshot {
    fn empty() -> Self {
        Self {
            revision: 0,
            navigation: Arc::from([]),
            pages: Arc::from([]),
            dashboard_cards: Arc::from([]),
            dashboard_carousels: Arc::from([]),
            settings: Arc::from([]),
            commands: Arc::from([]),
        }
    }

    /// Returns the monotonic content revision.
    #[must_use]
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Returns visible navigation destinations in deterministic order.
    #[must_use]
    pub fn navigation(&self) -> &[ProjectedContribution] {
        &self.navigation
    }

    /// Returns visible page routes in deterministic order.
    #[must_use]
    pub fn pages(&self) -> &[ProjectedContribution] {
        &self.pages
    }

    /// Returns visible dashboard cards in deterministic order.
    #[must_use]
    pub fn dashboard_cards(&self) -> &[ProjectedContribution] {
        &self.dashboard_cards
    }

    /// Returns visible dashboard carousels in deterministic order.
    #[must_use]
    pub fn dashboard_carousels(&self) -> &[ProjectedContribution] {
        &self.dashboard_carousels
    }

    /// Returns visible settings sections in deterministic order.
    #[must_use]
    pub fn settings(&self) -> &[ProjectedContribution] {
        &self.settings
    }

    /// Returns visible commands in deterministic order.
    #[must_use]
    pub fn commands(&self) -> &[ProjectedContribution] {
        &self.commands
    }

    /// Returns the total number of visible contributions across all surfaces.
    #[must_use]
    pub fn len(&self) -> usize {
        self.navigation.len()
            + self.pages.len()
            + self.dashboard_cards.len()
            + self.dashboard_carousels.len()
            + self.settings.len()
            + self.commands.len()
    }

    /// Returns whether every surface is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn same_content(&self, other: &Self) -> bool {
        same_surface(&self.navigation, &other.navigation)
            && same_surface(&self.pages, &other.pages)
            && same_surface(&self.dashboard_cards, &other.dashboard_cards)
            && same_surface(&self.dashboard_carousels, &other.dashboard_carousels)
            && same_surface(&self.settings, &other.settings)
            && same_surface(&self.commands, &other.commands)
    }
}

/// Stateful builder for immutable contribution snapshots.
///
/// Every update is a complete lifecycle view. Missing, duplicate, unknown, or
/// generation-regressed entries are fail-closed for the affected plugin.
pub struct ContributionProjector {
    indexed: BTreeMap<PluginId, IndexedPlugin>,
    latest_generations: BTreeMap<PluginId, u64>,
    latest_publication_revision: Option<u64>,
    current: ContributionSnapshot,
}

struct IndexedPlugin {
    catalog_compatible: bool,
    contributions: Arc<[ProjectedContribution]>,
}

impl ContributionProjector {
    /// Indexes canonical catalog contributions and resolves navigation targets.
    pub fn new(catalog: &CatalogSnapshot) -> Result<Self, ProjectionError> {
        let mut indexed = BTreeMap::new();
        for plugin in catalog.plugins() {
            let plugin_id = Arc::new(plugin.manifest().id.clone());
            let descriptors = plugin
                .contributions()
                .iter()
                .cloned()
                .map(Arc::new)
                .collect::<Vec<_>>();
            let pages = descriptors
                .iter()
                .filter_map(|descriptor| match descriptor.as_ref() {
                    ContributionDescriptor::Page(page) => {
                        Some((page.metadata.id.clone(), Arc::clone(descriptor)))
                    }
                    _ => None,
                })
                .collect::<BTreeMap<_, _>>();
            let mut projected = Vec::with_capacity(descriptors.len());
            for descriptor in descriptors {
                let (route, resolved_page) = match descriptor.as_ref() {
                    ContributionDescriptor::Page(page) => {
                        (Some(host_route(&plugin_id, &page.view_id)), None)
                    }
                    ContributionDescriptor::Navigation(navigation) => {
                        let page = pages.get(&navigation.page_id).ok_or_else(|| {
                            ProjectionError::UnresolvedNavigation {
                                plugin_id: (*plugin_id).clone(),
                                navigation_id: navigation.metadata.id.clone(),
                                page_id: navigation.page_id.clone(),
                            }
                        })?;
                        let ContributionDescriptor::Page(page_descriptor) = page.as_ref() else {
                            return Err(ProjectionError::UnresolvedNavigation {
                                plugin_id: (*plugin_id).clone(),
                                navigation_id: navigation.metadata.id.clone(),
                                page_id: navigation.page_id.clone(),
                            });
                        };
                        (
                            Some(host_route(&plugin_id, &page_descriptor.view_id)),
                            Some(Arc::clone(page)),
                        )
                    }
                    _ => (None, None),
                };
                projected.push(ProjectedContribution {
                    plugin_id: Arc::clone(&plugin_id),
                    descriptor,
                    route,
                    resolved_page,
                });
            }
            indexed.insert(
                (*plugin_id).clone(),
                IndexedPlugin {
                    catalog_compatible: plugin.is_compatible(),
                    contributions: projected.into(),
                },
            );
        }
        Ok(Self {
            indexed,
            latest_generations: BTreeMap::new(),
            latest_publication_revision: None,
            current: ContributionSnapshot::empty(),
        })
    }

    /// Returns the latest immutable snapshot without rebuilding it.
    #[must_use]
    pub fn snapshot(&self) -> ContributionSnapshot {
        self.current.clone()
    }

    /// Rebuilds visible surfaces from one complete lifecycle snapshot set.
    ///
    /// `publication_revision` is the host-owned monotonic revision for the
    /// complete batch, independent from each plugin lifecycle generation.
    /// Unknown entries are ignored. Duplicate known entries and entries older
    /// than the last accepted generation hide only their affected plugin.
    pub fn update(
        &mut self,
        publication_revision: u64,
        lifecycles: impl IntoIterator<Item = LifecycleSnapshot>,
    ) -> Result<ContributionSnapshot, ProjectionError> {
        if let Some(latest) = self.latest_publication_revision
            && publication_revision <= latest
        {
            return Err(ProjectionError::StalePublication {
                latest,
                received: publication_revision,
            });
        }
        let mut admitted = BTreeMap::new();
        let mut duplicates = BTreeMap::new();
        let mut observed_generations = BTreeMap::new();
        for lifecycle in lifecycles {
            if !self.indexed.contains_key(&lifecycle.plugin_id) {
                continue;
            }
            observed_generations
                .entry(lifecycle.plugin_id.clone())
                .and_modify(|generation: &mut u64| {
                    *generation = (*generation).max(lifecycle.generation);
                })
                .or_insert(lifecycle.generation);
            if admitted.contains_key(&lifecycle.plugin_id) {
                duplicates.insert(lifecycle.plugin_id.clone(), ());
                admitted.remove(&lifecycle.plugin_id);
            } else if !duplicates.contains_key(&lifecycle.plugin_id) {
                admitted.insert(lifecycle.plugin_id.clone(), lifecycle);
            }
        }

        let mut next_generations = self.latest_generations.clone();
        for (plugin_id, generation) in observed_generations {
            next_generations
                .entry(plugin_id)
                .and_modify(|current| *current = (*current).max(generation))
                .or_insert(generation);
        }
        let mut visible = Vec::new();
        for (plugin_id, lifecycle) in admitted {
            if self
                .latest_generations
                .get(&plugin_id)
                .is_some_and(|generation| lifecycle.generation < *generation)
            {
                continue;
            }
            if lifecycle.is_projectable()
                && let Some(indexed) = self.indexed.get(&plugin_id)
                && indexed.catalog_compatible
            {
                visible.extend(indexed.contributions.iter().cloned());
            }
        }

        let mut candidate = partition(visible);
        if candidate.same_content(&self.current) {
            self.latest_generations = next_generations;
            self.latest_publication_revision = Some(publication_revision);
            return Ok(self.current.clone());
        }
        candidate.revision = self
            .current
            .revision
            .checked_add(1)
            .ok_or(ProjectionError::RevisionExhausted)?;
        self.latest_generations = next_generations;
        self.latest_publication_revision = Some(publication_revision);
        self.current = candidate;
        Ok(self.current.clone())
    }
}

/// Stable failures that prevent a contribution projection from being built.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProjectionError {
    /// A navigation contribution points to a page absent from its plugin.
    #[error("navigation contribution does not resolve to a page in its plugin")]
    UnresolvedNavigation {
        /// Plugin containing the invalid navigation contribution.
        plugin_id: PluginId,
        /// Navigation contribution that failed resolution.
        navigation_id: ContributionId,
        /// Missing page contribution identifier.
        page_id: ContributionId,
    },
    /// The content revision can no longer advance safely.
    #[error("contribution snapshot revision is exhausted")]
    RevisionExhausted,
    /// A complete lifecycle publication was replayed or arrived out of order.
    #[error("lifecycle publication revision is not newer than the accepted revision")]
    StalePublication {
        /// Latest complete publication accepted by the projector.
        latest: u64,
        /// Replayed or out-of-order publication revision.
        received: u64,
    },
}

fn host_route(plugin_id: &PluginId, view_id: &str) -> Arc<str> {
    Arc::from(format!("/extensions/{}/{view_id}", plugin_id.as_str()))
}

fn same_surface(left: &[ProjectedContribution], right: &[ProjectedContribution]) -> bool {
    left.len() == right.len()
        && left.iter().zip(right).all(|(left, right)| {
            Arc::ptr_eq(&left.plugin_id, &right.plugin_id)
                && Arc::ptr_eq(&left.descriptor, &right.descriptor)
                && same_optional_arc(&left.route, &right.route)
                && same_optional_arc(&left.resolved_page, &right.resolved_page)
        })
}

fn same_optional_arc<T: ?Sized>(left: &Option<Arc<T>>, right: &Option<Arc<T>>) -> bool {
    match (left, right) {
        (Some(left), Some(right)) => Arc::ptr_eq(left, right),
        (None, None) => true,
        _ => false,
    }
}

fn partition(visible: Vec<ProjectedContribution>) -> ContributionSnapshot {
    let mut navigation = Vec::new();
    let mut pages = Vec::new();
    let mut dashboard_cards = Vec::new();
    let mut dashboard_carousels = Vec::new();
    let mut settings = Vec::new();
    let mut commands = Vec::new();
    for contribution in visible {
        match contribution.descriptor.as_ref() {
            ContributionDescriptor::Navigation(_) => navigation.push(contribution),
            ContributionDescriptor::Page(_) => pages.push(contribution),
            ContributionDescriptor::DashboardCard(_) => dashboard_cards.push(contribution),
            ContributionDescriptor::DashboardCarousel(_) => dashboard_carousels.push(contribution),
            ContributionDescriptor::Settings(_) => settings.push(contribution),
            ContributionDescriptor::Command(_) => commands.push(contribution),
        }
    }
    sort_surface(&mut navigation);
    sort_surface(&mut pages);
    sort_surface(&mut dashboard_cards);
    sort_surface(&mut dashboard_carousels);
    sort_surface(&mut settings);
    sort_surface(&mut commands);
    ContributionSnapshot {
        revision: 0,
        navigation: navigation.into(),
        pages: pages.into(),
        dashboard_cards: dashboard_cards.into(),
        dashboard_carousels: dashboard_carousels.into(),
        settings: settings.into(),
        commands: commands.into(),
    }
}

fn sort_surface(surface: &mut [ProjectedContribution]) {
    surface.sort_by(|left, right| {
        left.descriptor
            .metadata()
            .order
            .cmp(&right.descriptor.metadata().order)
            .then_with(|| left.descriptor.id().cmp(right.descriptor.id()))
    });
}

#[cfg(test)]
mod tests {
    use semver::Version;
    use timetrace_plugin_api::{
        CURRENT_MANIFEST_SCHEMA_VERSION, CardDescriptor, CarouselDescriptor, CommandDescriptor,
        ContributionMetadata, DashboardSize, DesiredPluginState, DisplayMetadata, HostApiRange,
        NavigationDescriptor, PageDescriptor, Platform, PluginManifest, PluginRuntimeState,
        PublisherId, RefreshPolicy, RendererRef, SettingFieldDescriptor, SettingValueKind,
        SettingsSectionDescriptor, TimestampMillis,
    };

    use super::*;
    use crate::PluginCatalog;

    fn id(value: &str) -> ContributionId {
        ContributionId::new(value).expect("valid contribution id")
    }

    fn metadata(value: &str, order: i32) -> ContributionMetadata {
        ContributionMetadata {
            id: id(value),
            display: DisplayMetadata {
                title: value.to_owned(),
                description: None,
                icon: None,
            },
            order,
            required_capabilities: Vec::new(),
        }
    }

    fn all_surface_manifest(plugin: &str) -> PluginManifest {
        let page_id = format!("{plugin}.page");
        PluginManifest {
            schema_version: CURRENT_MANIFEST_SCHEMA_VERSION,
            id: PluginId::new(plugin).expect("valid plugin"),
            publisher: PublisherId::new("timetrace-labs").expect("valid publisher"),
            display_name: plugin.to_owned(),
            description: None,
            version: Version::new(1, 0, 0),
            host_api: HostApiRange::parse(">=1.0.0, <2.0.0").expect("host range"),
            platforms: vec![Platform::WindowsX64],
            contributions: vec![
                ContributionDescriptor::Navigation(NavigationDescriptor {
                    metadata: metadata(&format!("{plugin}.navigation"), 5),
                    page_id: id(&page_id),
                }),
                ContributionDescriptor::Page(PageDescriptor {
                    metadata: metadata(&page_id, 4),
                    view_id: "overview".to_owned(),
                    renderer: RendererRef::DeclarativeV1,
                }),
                ContributionDescriptor::DashboardCard(CardDescriptor {
                    metadata: metadata(&format!("{plugin}.card"), 3),
                    renderer: RendererRef::DeclarativeV1,
                    size: DashboardSize::Small,
                    refresh: RefreshPolicy::OnDemand,
                }),
                ContributionDescriptor::DashboardCarousel(CarouselDescriptor {
                    metadata: metadata(&format!("{plugin}.carousel"), 2),
                    renderer: RendererRef::DeclarativeV1,
                    size: DashboardSize::Wide,
                    refresh: RefreshPolicy::DataRevision,
                }),
                ContributionDescriptor::Settings(SettingsSectionDescriptor {
                    metadata: metadata(&format!("{plugin}.settings"), 1),
                    schema_version: 1,
                    fields: vec![SettingFieldDescriptor {
                        key: "enabled".to_owned(),
                        label: "Enabled".to_owned(),
                        kind: SettingValueKind::Boolean,
                        required: false,
                        default_value: None,
                    }],
                }),
                ContributionDescriptor::Command(CommandDescriptor {
                    metadata: metadata(&format!("{plugin}.command"), 0),
                    input_schema_version: 1,
                    timeout_ms: 1_000,
                }),
            ],
            requested_capabilities: Vec::new(),
        }
    }

    fn card_manifest(plugin: &str, order: i32) -> PluginManifest {
        let mut manifest = all_surface_manifest(plugin);
        manifest.contributions = vec![ContributionDescriptor::DashboardCard(CardDescriptor {
            metadata: metadata(&format!("{plugin}.card"), order),
            renderer: RendererRef::DeclarativeV1,
            size: DashboardSize::Medium,
            refresh: RefreshPolicy::OnDemand,
        })];
        manifest
    }

    fn catalog(manifests: Vec<PluginManifest>) -> CatalogSnapshot {
        PluginCatalog::build(Version::new(1, 0, 0), Platform::WindowsX64, manifests)
            .expect("catalog")
            .snapshot()
    }

    fn lifecycle(plugin: &str, generation: u64, state: PluginRuntimeState) -> LifecycleSnapshot {
        LifecycleSnapshot {
            plugin_id: PluginId::new(plugin).expect("valid plugin"),
            desired_state: DesiredPluginState::Enabled,
            runtime_state: state,
            compatible: true,
            grants_satisfied: true,
            generation,
            updated_at: TimestampMillis(generation as i64),
            failure: None,
        }
    }

    #[test]
    fn projects_all_six_surfaces_and_host_owned_routes() {
        let catalog = catalog(vec![all_surface_manifest("sample-plugin")]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let snapshot = projector
            .update(
                1,
                [lifecycle("sample-plugin", 1, PluginRuntimeState::Ready)],
            )
            .expect("projection");

        assert_eq!(snapshot.len(), 6);
        assert_eq!(snapshot.navigation().len(), 1);
        assert_eq!(snapshot.pages().len(), 1);
        assert_eq!(snapshot.dashboard_cards().len(), 1);
        assert_eq!(snapshot.dashboard_carousels().len(), 1);
        assert_eq!(snapshot.settings().len(), 1);
        assert_eq!(snapshot.commands().len(), 1);
        let route = "/extensions/sample-plugin/overview";
        assert_eq!(snapshot.pages()[0].route(), Some(route));
        assert_eq!(snapshot.navigation()[0].route(), Some(route));
        assert!(matches!(
            snapshot.navigation()[0].resolved_page(),
            Some(ContributionDescriptor::Page(_))
        ));
    }

    #[test]
    fn surfaces_sort_globally_by_order_then_identifier_and_reuse_arcs() {
        let catalog = catalog(vec![
            card_manifest("plugin-z", -1),
            card_manifest("plugin-a", 5),
        ]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let first = projector
            .update(
                1,
                [
                    lifecycle("plugin-a", 1, PluginRuntimeState::Ready),
                    lifecycle("plugin-z", 1, PluginRuntimeState::Ready),
                ],
            )
            .expect("projection");
        assert_eq!(
            first
                .dashboard_cards()
                .iter()
                .map(|value| value.descriptor().id().as_str())
                .collect::<Vec<_>>(),
            ["plugin-z.card", "plugin-a.card"]
        );
        let first_descriptor = Arc::clone(&first.dashboard_cards()[0].descriptor);
        let stable = projector
            .update(
                2,
                [
                    lifecycle("plugin-z", 1, PluginRuntimeState::Ready),
                    lifecycle("plugin-a", 1, PluginRuntimeState::Ready),
                ],
            )
            .expect("same content");
        assert_eq!(stable.revision(), first.revision());
        assert!(Arc::ptr_eq(
            &first_descriptor,
            &stable.dashboard_cards()[0].descriptor
        ));
    }

    #[test]
    fn nonprojectable_state_is_removed_on_the_next_snapshot() {
        let catalog = catalog(vec![card_manifest("plugin-a", 0)]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let ready = projector
            .update(1, [lifecycle("plugin-a", 7, PluginRuntimeState::Ready)])
            .expect("ready");
        assert_eq!(ready.revision(), 1);
        assert_eq!(ready.dashboard_cards().len(), 1);

        for (publication_revision, (generation, state)) in [
            (8, PluginRuntimeState::Stopping),
            (9, PluginRuntimeState::Failed),
            (10, PluginRuntimeState::Disabled),
        ]
        .into_iter()
        .enumerate()
        {
            let hidden = projector
                .update(
                    publication_revision as u64 + 2,
                    [lifecycle("plugin-a", generation, state)],
                )
                .expect("hidden");
            assert!(hidden.is_empty());
        }
        assert_eq!(projector.snapshot().revision(), 2);
    }

    #[test]
    fn duplicate_unknown_missing_and_late_lifecycle_inputs_fail_closed_per_plugin() {
        let catalog = catalog(vec![
            card_manifest("plugin-a", 0),
            card_manifest("plugin-b", 1),
        ]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let both = projector
            .update(
                1,
                [
                    lifecycle("plugin-a", 5, PluginRuntimeState::Ready),
                    lifecycle("plugin-b", 5, PluginRuntimeState::Ready),
                ],
            )
            .expect("both");
        assert_eq!(both.dashboard_cards().len(), 2);

        let duplicate = projector
            .update(
                2,
                [
                    lifecycle("plugin-a", 6, PluginRuntimeState::Ready),
                    lifecycle("plugin-a", 6, PluginRuntimeState::Ready),
                    lifecycle("plugin-b", 5, PluginRuntimeState::Ready),
                    lifecycle("unknown-plugin", 99, PluginRuntimeState::Ready),
                ],
            )
            .expect("duplicate hidden");
        assert_eq!(duplicate.dashboard_cards().len(), 1);
        assert_eq!(
            duplicate.dashboard_cards()[0].plugin_id().as_str(),
            "plugin-b"
        );

        let late_and_missing = projector
            .update(3, [lifecycle("plugin-a", 5, PluginRuntimeState::Ready)])
            .expect("late and missing hidden");
        assert!(late_and_missing.is_empty());
        let unknown_only = projector
            .update(
                4,
                [lifecycle("unknown-plugin", 100, PluginRuntimeState::Ready)],
            )
            .expect("unknown hidden");
        assert!(unknown_only.is_empty());
        assert_eq!(unknown_only.revision(), late_and_missing.revision());
    }

    #[test]
    fn catalog_incompatibility_cannot_be_overridden_by_a_forged_lifecycle() {
        let mut incompatible = card_manifest("plugin-a", 0);
        incompatible.host_api =
            HostApiRange::parse(">=2.0.0, <3.0.0").expect("incompatible host range");
        let catalog = catalog(vec![incompatible]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");

        let forged = projector
            .update(1, [lifecycle("plugin-a", 1, PluginRuntimeState::Ready)])
            .expect("forged lifecycle is safely filtered");
        assert!(forged.is_empty());
    }

    #[test]
    fn revoked_equal_generation_cannot_be_reactivated_by_an_old_publication() {
        let catalog = catalog(vec![card_manifest("plugin-a", 0)]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let ready = lifecycle("plugin-a", 5, PluginRuntimeState::Ready);
        assert_eq!(
            projector
                .update(10, [ready.clone()])
                .expect("ready publication")
                .dashboard_cards()
                .len(),
            1
        );
        let mut revoked = ready.clone();
        revoked.grants_satisfied = false;
        assert!(
            projector
                .update(11, [revoked])
                .expect("revoked publication")
                .is_empty()
        );

        assert!(matches!(
            projector.update(10, [ready]),
            Err(ProjectionError::StalePublication {
                latest: 11,
                received: 10
            })
        ));
        assert!(projector.snapshot().is_empty());
    }

    #[test]
    fn missing_plugin_cannot_be_reactivated_by_replaying_its_old_batch() {
        let catalog = catalog(vec![card_manifest("plugin-a", 0)]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        let ready = lifecycle("plugin-a", 7, PluginRuntimeState::Ready);
        projector
            .update(20, [ready.clone()])
            .expect("ready publication");
        assert!(
            projector
                .update(21, std::iter::empty::<LifecycleSnapshot>())
                .expect("missing publication")
                .is_empty()
        );

        assert!(matches!(
            projector.update(20, [ready]),
            Err(ProjectionError::StalePublication {
                latest: 21,
                received: 20
            })
        ));
        assert!(projector.snapshot().is_empty());
    }

    #[test]
    fn revision_exhaustion_keeps_the_last_published_snapshot() {
        let catalog = catalog(vec![card_manifest("plugin-a", 0)]);
        let mut projector = ContributionProjector::new(&catalog).expect("projector");
        projector.current.revision = u64::MAX;
        assert!(matches!(
            projector.update(1, [lifecycle("plugin-a", 1, PluginRuntimeState::Ready)]),
            Err(ProjectionError::RevisionExhausted)
        ));
        assert!(projector.snapshot().is_empty());
        assert_eq!(projector.snapshot().revision(), u64::MAX);
    }
}
