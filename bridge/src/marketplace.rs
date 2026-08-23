//! Typed, presentation-safe Marketplace projection for the Flutter bridge.
//!
//! This module is deliberately the only Marketplace FRB surface.  It accepts
//! identifiers and explicit consent only, and projects data only after an
//! application service has returned a verified catalog.  It never accepts or
//! emits URLs, archive bytes, manifests, keys, signatures, or local paths.

use std::sync::Arc;

use semver::Version;
use timetrace_plugin_api::{
    CapabilityId, MarketplaceBlockReason, MarketplaceChannel, MarketplaceCompatibilityInput,
    MarketplaceIncompatibility, MarketplaceInstallDisposition, MarketplaceReleaseState,
    MarketplaceReleaseSummary, VerifiedMarketplaceCatalogPage, plan_marketplace_install,
};

const MAX_CURSOR_BYTES: usize = 512;
const MAX_IDENTIFIER_BYTES: usize = 128;
const MAX_CONSENT_IDS: usize = 3;

/// Closed marketplace error code safe to display after local translation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceErrorCodeDto {
    CatalogUnavailable,
    CatalogInvalid,
    NotFound,
    InvalidRequest,
    PackageUnavailable,
    PackageTooLarge,
    DigestMismatch,
    ArchiveInvalid,
    ReleaseIdentityMismatch,
    ConsentMismatch,
    StorageUnavailable,
    Cancelled,
    Internal,
}

/// A host-issued, privacy-safe Marketplace error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceErrorDto {
    /// Stable closed error code.
    pub code: MarketplaceErrorCodeDto,
    /// Whether the same request may be retried later.
    pub retryable: bool,
    /// Optional host correlation token; never a transport payload.
    pub correlation_id: Option<String>,
}

/// A bounded catalog request.  No URL, filters, or offsets cross FFI.
#[derive(Debug, Clone)]
pub struct MarketplaceCatalogQueryDto {
    /// `stable` or `beta`; empty selects the host default (`stable`).
    pub channel: String,
    /// Opaque cursor from an earlier verified page.
    pub cursor: Option<String>,
    /// Requested page size, 1 through 50.
    pub limit: u8,
}

/// A publisher/plugin identity for a detail lookup.
#[derive(Debug, Clone)]
pub struct MarketplacePluginRefDto {
    /// Canonical publisher identifier.
    pub publisher_id: String,
    /// Canonical plugin identifier.
    pub plugin_id: String,
}

/// The immutable release the user reviewed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceReleaseRefDto {
    /// Marketplace UUID release identifier.
    pub release_id: String,
    /// Canonical publisher identifier.
    pub publisher_id: String,
    /// Canonical plugin identifier.
    pub plugin_id: String,
    /// Exact reviewed semantic version.
    pub version: String,
    /// Exact lowercase SHA-256 package digest.
    pub package_digest: String,
}

/// A closed consent capability accepted for the exact release only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MarketplaceCapabilityDto {
    UsageAggregateRead,
    AiCloud,
    AiLocal,
}

/// An exact immutable install request.
#[derive(Debug, Clone)]
pub struct MarketplaceInstallRequestDto {
    /// Reviewed immutable release identity.
    pub release: MarketplaceReleaseRefDto,
    /// Unique closed capability ids selected by the user. The host canonicalizes order.
    pub consent_capability_ids: Vec<MarketplaceCapabilityDto>,
}

/// Presentation-safe reviewed permission data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplacePermissionReviewDto {
    /// Closed capability identifier.
    pub capability: MarketplaceCapabilityDto,
    /// Host-generated constrained summary.
    pub summary: String,
    /// Host-generated optional rationale.
    pub rationale: Option<String>,
}

/// Closed release availability state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceReleaseStateDto {
    Published,
    Suspended,
    Revoked,
}
/// Closed catalog channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceChannelDto {
    Stable,
    Beta,
}
/// Closed native badge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceBadgeDto {
    Official,
    VerifiedPublisher,
    Beta,
    Suspended,
    Revoked,
}
/// Closed install disposition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceDispositionDto {
    Installable,
    UpdateAvailable,
    AlreadyInstalled,
    DowngradeBlocked,
    IncompatibleHostApi,
    IncompatiblePlatform,
    PackageTooLarge,
    PermissionRequired,
    BlockedLocalPolicy,
    BlockedSuspended,
    Revoked,
}

/// A verified, display-safe catalog release projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceCatalogItemDto {
    /// Exact release identity.
    pub release: MarketplaceReleaseRefDto,
    /// Plain text display label.
    pub display_name: String,
    /// Plain text description.
    pub description: Option<String>,
    /// Closed channel.
    pub channel: MarketplaceChannelDto,
    /// Closed release state.
    pub state: MarketplaceReleaseStateDto,
    /// Closed badges.
    pub badges: Vec<MarketplaceBadgeDto>,
    /// Locally recomputed compatibility.
    pub compatibility: MarketplaceDispositionDto,
    /// Host-rendered permission review.
    pub permissions: Vec<MarketplacePermissionReviewDto>,
    /// Exact bounded package size.
    pub package_bytes: u64,
    /// Exact verified UTC millisecond spelling.
    pub published_at: String,
}

/// A verified catalog page projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceCatalogPageDto {
    /// Marketplace schema version.
    pub schema_version: u32,
    /// Opaque catalog revision.
    pub catalog_revision: String,
    /// Exact verified UTC millisecond spelling.
    pub generated_at: String,
    /// At most fifty verified catalog items.
    pub items: Vec<MarketplaceCatalogItemDto>,
    /// Opaque next cursor.
    pub next_cursor: Option<String>,
}

/// A verified plugin detail projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplacePluginDetailDto {
    /// Lookup identity.
    pub publisher_id: String,
    /// Lookup identity.
    pub plugin_id: String,
    /// Selected exact release.
    pub selected_release: MarketplaceCatalogItemDto,
    /// Other verified releases for the same identity.
    pub versions: Vec<MarketplaceCatalogItemDto>,
    /// Locally recomputed install plan.
    pub install_plan: MarketplaceInstallPlanDto,
}

/// The exact plan to which consent is bound.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceInstallPlanDto {
    /// Exact selected release.
    pub release: MarketplaceReleaseRefDto,
    /// Closed local disposition.
    pub disposition: MarketplaceDispositionDto,
    /// Only permissions requiring fresh user consent.
    pub required_consent: Vec<MarketplacePermissionReviewDto>,
    /// Bounded local disk estimate.
    pub disk_bytes: u64,
}

/// Host-produced operation phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarketplaceOperationPhaseDto {
    Idle,
    Checking,
    Downloading,
    Verifying,
    Installing,
    Enabled,
    Blocked,
    Failed,
}
/// Final safe operation snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarketplaceOperationStateDto {
    /// Closed operation phase.
    pub phase: MarketplaceOperationPhaseDto,
    /// Closed stable error when the phase is failed.
    pub error: Option<MarketplaceErrorDto>,
}

/// Service boundary owned by the native desktop composition root.
pub trait MarketplaceBridgeService: Send + Sync {
    /// Returns only a catalog that already passed pinned-root verification.
    fn verified_catalog(
        &self,
        query: &MarketplaceCatalogQueryDto,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceErrorDto>;
    /// Resolves all versions for one plugin from the root-signed detail
    /// endpoint.  Detail must not depend on the first catalog page.
    fn verified_plugin(
        &self,
        _: &MarketplacePluginRefDto,
    ) -> Result<Vec<MarketplaceReleaseSummary>, MarketplaceErrorDto> {
        Err(unavailable())
    }
    /// Resolves one exact release from its root-signed endpoint, binding all
    /// four immutable fields in the caller's release reference.
    fn verified_release(
        &self,
        _: &MarketplaceReleaseRefDto,
    ) -> Result<MarketplaceReleaseSummary, MarketplaceErrorDto> {
        Err(unavailable())
    }
    /// Returns host facts used to recompute an installation plan.
    fn compatibility(
        &self,
        release: &MarketplaceReleaseSummary,
    ) -> Result<MarketplaceCompatibilityInput, MarketplaceErrorDto>;
    /// Downloads, verifies, and atomically installs this exact re-resolved release.
    fn install(
        &self,
        release: &MarketplaceReleaseSummary,
        compatibility: &MarketplaceCompatibilityInput,
        consent: &[CapabilityId],
    ) -> Result<(), MarketplaceErrorDto>;
    /// Persists a Marketplace package's desired state and reloads it. Returns
    /// false only when this is not a Marketplace-installed package, allowing
    /// the API layer to retain the bundled-plugin path.
    fn set_installed_enabled(&self, _: &str, _: bool) -> Result<bool, MarketplaceErrorDto> {
        Ok(false)
    }
}

/// Private lifecycle hook owned by the native composition root.  It is kept
/// separate from the FRB-facing service contract so Marketplace background
/// work cannot be started, stopped, or influenced by Dart.
pub(crate) trait MarketplaceBridgeLifecycle: Send + Sync {
    /// Wakes a host-owned policy scheduler after the installed set changes.
    fn wake_policy_watchdog(&self);
    /// Requests a prompt, non-blocking scheduler shutdown during bridge drop.
    fn shutdown_policy_watchdog(&self);
}

struct UnavailableMarketplaceBridgeService {}
impl MarketplaceBridgeService for UnavailableMarketplaceBridgeService {
    fn verified_catalog(
        &self,
        _: &MarketplaceCatalogQueryDto,
    ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceErrorDto> {
        Err(unavailable())
    }
    fn compatibility(
        &self,
        _: &MarketplaceReleaseSummary,
    ) -> Result<MarketplaceCompatibilityInput, MarketplaceErrorDto> {
        Err(unavailable())
    }
    fn install(
        &self,
        _: &MarketplaceReleaseSummary,
        _: &MarketplaceCompatibilityInput,
        _: &[CapabilityId],
    ) -> Result<(), MarketplaceErrorDto> {
        Err(unavailable())
    }
}

/// Native owner of all Marketplace operations exposed through FRB.
pub struct MarketplaceBridgeProvider {
    service: Arc<dyn MarketplaceBridgeService>,
    lifecycle: Option<Arc<dyn MarketplaceBridgeLifecycle>>,
}
impl MarketplaceBridgeProvider {
    /// Creates a safe provider that exposes Marketplace as temporarily unavailable.
    pub fn unavailable() -> Self {
        Self {
            service: Arc::new(UnavailableMarketplaceBridgeService {}),
            lifecycle: None,
        }
    }
    /// Creates a provider around the desktop-owned verified Marketplace service.
    pub fn new(service: Arc<dyn MarketplaceBridgeService>) -> Self {
        Self {
            service,
            lifecycle: None,
        }
    }

    /// Creates a provider with a private native lifecycle owner.  This is not
    /// an FFI capability and is used only by the desktop composition root.
    pub(crate) fn new_with_lifecycle(
        service: Arc<dyn MarketplaceBridgeService>,
        lifecycle: Arc<dyn MarketplaceBridgeLifecycle>,
    ) -> Self {
        Self {
            service,
            lifecycle: Some(lifecycle),
        }
    }

    /// Stops private native background work before the plugin service enters
    /// its shutdown fence. This is intentionally absent from FRB.
    pub(crate) fn shutdown_lifecycle(&self) {
        if let Some(lifecycle) = &self.lifecycle {
            lifecycle.shutdown_policy_watchdog();
        }
    }
    /// Lists verified presentation-safe catalog releases.
    pub fn list(
        &self,
        query: MarketplaceCatalogQueryDto,
    ) -> Result<MarketplaceCatalogPageDto, MarketplaceErrorDto> {
        validate_query(&query)?;
        let catalog = self.service.verified_catalog(&query)?;
        project_catalog(&catalog, |release| self.service.compatibility(release))
    }
    /// Resolves a typed publisher/plugin detail from a verified catalog only.
    pub fn detail(
        &self,
        reference: MarketplacePluginRefDto,
    ) -> Result<MarketplacePluginDetailDto, MarketplaceErrorDto> {
        validate_identifier(&reference.publisher_id)?;
        validate_identifier(&reference.plugin_id)?;
        let mut matches = self.service.verified_plugin(&reference)?;
        let selected = matches.first().cloned().ok_or_else(not_found)?;
        let compatibility = self.service.compatibility(&selected)?;
        let plan = plan_marketplace_install(selected.clone(), &compatibility);
        let selected_release = project_item(&selected, &compatibility)?;
        let versions = matches
            .drain(..)
            .map(|release| {
                self.service
                    .compatibility(&release)
                    .and_then(|facts| project_item(&release, &facts))
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(MarketplacePluginDetailDto {
            publisher_id: reference.publisher_id,
            plugin_id: reference.plugin_id,
            selected_release,
            versions,
            install_plan: project_plan(plan)?,
        })
    }
    /// Re-resolves and installs only the exact reviewed release after exact consent validation.
    pub fn install(&self, request: MarketplaceInstallRequestDto) -> MarketplaceOperationStateDto {
        match self.install_inner(request) {
            Ok(()) => operation(MarketplaceOperationPhaseDto::Enabled, None),
            Err(error) => operation(
                if matches!(error.code, MarketplaceErrorCodeDto::ConsentMismatch) {
                    MarketplaceOperationPhaseDto::Blocked
                } else {
                    MarketplaceOperationPhaseDto::Failed
                },
                Some(error),
            ),
        }
    }
    /// Changes only an installed Marketplace record's durable desired state.
    pub fn set_installed_enabled(
        &self,
        plugin_id: &str,
        enabled: bool,
    ) -> Result<bool, MarketplaceErrorDto> {
        validate_identifier(plugin_id)?;
        self.service.set_installed_enabled(plugin_id, enabled)
    }
    fn install_inner(
        &self,
        request: MarketplaceInstallRequestDto,
    ) -> Result<(), MarketplaceErrorDto> {
        validate_release_ref(&request.release)?;
        let submitted_consent = canonicalize_consent(&request.consent_capability_ids)?;
        let release = self.service.verified_release(&request.release)?;
        if !same_release(&release, &request.release) {
            return Err(error(
                MarketplaceErrorCodeDto::ReleaseIdentityMismatch,
                false,
            ));
        }
        let baseline_facts = self.service.compatibility(&release)?;
        let baseline_plan = plan_marketplace_install(release.clone(), &baseline_facts);
        let expected = canonicalize_consent(
            &baseline_plan
                .required_consent
                .iter()
                .map(capability_dto)
                .collect::<Result<Vec<_>, _>>()?,
        )?;
        if expected != submitted_consent {
            return Err(error(MarketplaceErrorCodeDto::ConsentMismatch, false));
        }
        let consent = submitted_consent
            .iter()
            .map(dto_capability)
            .collect::<Result<Vec<_>, _>>()?;
        let mut approved_facts = baseline_facts;
        approved_facts
            .approved_permissions
            .extend(consent.iter().cloned());
        let approved_plan = plan_marketplace_install(release.clone(), &approved_facts);
        if !matches!(
            approved_plan.disposition,
            MarketplaceInstallDisposition::Installable
                | MarketplaceInstallDisposition::UpdateAvailable
        ) {
            return Err(error(MarketplaceErrorCodeDto::InvalidRequest, false));
        }
        self.service.install(&release, &approved_facts, &consent)?;
        if let Some(lifecycle) = &self.lifecycle {
            lifecycle.wake_policy_watchdog();
        }
        Ok(())
    }
}

impl Drop for MarketplaceBridgeProvider {
    fn drop(&mut self) {
        if let Some(lifecycle) = &self.lifecycle {
            lifecycle.shutdown_policy_watchdog();
        }
    }
}

fn project_catalog(
    catalog: &VerifiedMarketplaceCatalogPage,
    facts: impl Fn(
        &MarketplaceReleaseSummary,
    ) -> Result<MarketplaceCompatibilityInput, MarketplaceErrorDto>,
) -> Result<MarketplaceCatalogPageDto, MarketplaceErrorDto> {
    let page = catalog.as_page();
    let items = page
        .items
        .iter()
        .map(|r| facts(r).and_then(|f| project_item(r, &f)))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(MarketplaceCatalogPageDto {
        schema_version: page.schema_version,
        catalog_revision: page.catalog_revision.clone(),
        generated_at: page.generated_at.as_str().into(),
        items,
        next_cursor: page.next_cursor.clone(),
    })
}
fn project_item(
    release: &MarketplaceReleaseSummary,
    facts: &MarketplaceCompatibilityInput,
) -> Result<MarketplaceCatalogItemDto, MarketplaceErrorDto> {
    let plan = plan_marketplace_install(release.clone(), facts);
    Ok(MarketplaceCatalogItemDto {
        release: release_ref(release),
        display_name: release.display_name.clone(),
        description: release.description.clone(),
        channel: channel(release.channel),
        state: state(release.state),
        badges: release.badges.iter().copied().map(badge).collect(),
        compatibility: disposition(&plan.disposition),
        permissions: release
            .permissions
            .iter()
            .map(permission)
            .collect::<Result<Vec<_>, _>>()?,
        package_bytes: release.package_bytes,
        published_at: release.published_at.as_str().into(),
    })
}
fn project_plan(
    plan: timetrace_plugin_api::MarketplaceInstallPlan,
) -> Result<MarketplaceInstallPlanDto, MarketplaceErrorDto> {
    Ok(MarketplaceInstallPlanDto {
        release: release_ref(&plan.release),
        disposition: disposition(&plan.disposition),
        required_consent: plan
            .required_consent
            .iter()
            .map(permission)
            .collect::<Result<Vec<_>, _>>()?,
        disk_bytes: plan.disk_bytes,
    })
}
fn release_ref(r: &MarketplaceReleaseSummary) -> MarketplaceReleaseRefDto {
    MarketplaceReleaseRefDto {
        release_id: r.release_id.clone(),
        publisher_id: r.identity.publisher_id.as_str().into(),
        plugin_id: r.identity.plugin_id.as_str().into(),
        version: r.version.to_string(),
        package_digest: r.package_digest.clone(),
    }
}
fn same_release(r: &MarketplaceReleaseSummary, d: &MarketplaceReleaseRefDto) -> bool {
    r.release_id == d.release_id
        && r.identity.publisher_id.as_str() == d.publisher_id
        && r.identity.plugin_id.as_str() == d.plugin_id
        && r.version.to_string() == d.version
        && r.package_digest == d.package_digest
}
fn channel(v: MarketplaceChannel) -> MarketplaceChannelDto {
    match v {
        MarketplaceChannel::Stable => MarketplaceChannelDto::Stable,
        MarketplaceChannel::Beta => MarketplaceChannelDto::Beta,
    }
}
fn state(v: MarketplaceReleaseState) -> MarketplaceReleaseStateDto {
    match v {
        MarketplaceReleaseState::Published => MarketplaceReleaseStateDto::Published,
        MarketplaceReleaseState::Suspended => MarketplaceReleaseStateDto::Suspended,
        MarketplaceReleaseState::Revoked => MarketplaceReleaseStateDto::Revoked,
    }
}
fn badge(v: timetrace_plugin_api::MarketplaceBadge) -> MarketplaceBadgeDto {
    match v {
        timetrace_plugin_api::MarketplaceBadge::Official => MarketplaceBadgeDto::Official,
        timetrace_plugin_api::MarketplaceBadge::VerifiedPublisher => {
            MarketplaceBadgeDto::VerifiedPublisher
        }
        timetrace_plugin_api::MarketplaceBadge::Beta => MarketplaceBadgeDto::Beta,
        timetrace_plugin_api::MarketplaceBadge::Suspended => MarketplaceBadgeDto::Suspended,
        timetrace_plugin_api::MarketplaceBadge::Revoked => MarketplaceBadgeDto::Revoked,
    }
}
fn disposition(v: &MarketplaceInstallDisposition) -> MarketplaceDispositionDto {
    match v {
        MarketplaceInstallDisposition::Installable => MarketplaceDispositionDto::Installable,
        MarketplaceInstallDisposition::UpdateAvailable => {
            MarketplaceDispositionDto::UpdateAvailable
        }
        MarketplaceInstallDisposition::AlreadyInstalled => {
            MarketplaceDispositionDto::AlreadyInstalled
        }
        MarketplaceInstallDisposition::DowngradeBlocked => {
            MarketplaceDispositionDto::DowngradeBlocked
        }
        MarketplaceInstallDisposition::Incompatible(MarketplaceIncompatibility::HostApi) => {
            MarketplaceDispositionDto::IncompatibleHostApi
        }
        MarketplaceInstallDisposition::Incompatible(MarketplaceIncompatibility::Platform) => {
            MarketplaceDispositionDto::IncompatiblePlatform
        }
        MarketplaceInstallDisposition::Incompatible(
            MarketplaceIncompatibility::PackageTooLarge,
        ) => MarketplaceDispositionDto::PackageTooLarge,
        MarketplaceInstallDisposition::PermissionRequired => {
            MarketplaceDispositionDto::PermissionRequired
        }
        MarketplaceInstallDisposition::Blocked(MarketplaceBlockReason::LocalPolicy) => {
            MarketplaceDispositionDto::BlockedLocalPolicy
        }
        MarketplaceInstallDisposition::Blocked(MarketplaceBlockReason::Suspended) => {
            MarketplaceDispositionDto::BlockedSuspended
        }
        MarketplaceInstallDisposition::Revoked => MarketplaceDispositionDto::Revoked,
    }
}
fn capability_dto(v: &CapabilityId) -> Result<MarketplaceCapabilityDto, MarketplaceErrorDto> {
    match v.as_str() {
        "usage.aggregate.read" => Ok(MarketplaceCapabilityDto::UsageAggregateRead),
        "ai.cloud" => Ok(MarketplaceCapabilityDto::AiCloud),
        "ai.local" => Ok(MarketplaceCapabilityDto::AiLocal),
        _ => Err(error(MarketplaceErrorCodeDto::Internal, false)),
    }
}
fn dto_capability(v: &MarketplaceCapabilityDto) -> Result<CapabilityId, MarketplaceErrorDto> {
    CapabilityId::new(match v {
        MarketplaceCapabilityDto::UsageAggregateRead => "usage.aggregate.read",
        MarketplaceCapabilityDto::AiCloud => "ai.cloud",
        MarketplaceCapabilityDto::AiLocal => "ai.local",
    })
    .map_err(|_| error(MarketplaceErrorCodeDto::InvalidRequest, false))
}
fn permission(v: &CapabilityId) -> Result<MarketplacePermissionReviewDto, MarketplaceErrorDto> {
    let capability = capability_dto(v)?;
    let (summary, rationale) = match capability {
        MarketplaceCapabilityDto::UsageAggregateRead => (
            "Read aggregated activity totals".into(),
            Some("Used only for approved local extension features".into()),
        ),
        MarketplaceCapabilityDto::AiCloud => (
            "Send approved content to a cloud AI provider".into(),
            Some("Network transfer may occur after installation".into()),
        ),
        MarketplaceCapabilityDto::AiLocal => ("Use the local AI provider".into(), None),
    };
    Ok(MarketplacePermissionReviewDto {
        capability,
        summary,
        rationale,
    })
}
fn validate_query(q: &MarketplaceCatalogQueryDto) -> Result<(), MarketplaceErrorDto> {
    if !matches!(q.channel.as_str(), "" | "stable" | "beta")
        || q.limit == 0
        || q.limit > 50
        || q.cursor
            .as_ref()
            .is_some_and(|v| v.is_empty() || v.len() > MAX_CURSOR_BYTES)
    {
        Err(error(MarketplaceErrorCodeDto::InvalidRequest, false))
    } else {
        Ok(())
    }
}
fn validate_identifier(v: &str) -> Result<(), MarketplaceErrorDto> {
    let valid = !v.is_empty()
        && v.len() <= MAX_IDENTIFIER_BYTES
        && v.bytes().enumerate().all(|(i, b)| {
            (b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'.' | b'_' | b':'))
                && !(i == 0 && matches!(b, b'-' | b'.' | b'_' | b':'))
        });
    if valid {
        Ok(())
    } else {
        Err(error(MarketplaceErrorCodeDto::InvalidRequest, false))
    }
}
fn validate_release_ref(r: &MarketplaceReleaseRefDto) -> Result<(), MarketplaceErrorDto> {
    validate_identifier(&r.publisher_id)?;
    validate_identifier(&r.plugin_id)?;
    if r.release_id.len() != 36
        || Version::parse(&r.version).is_err()
        || r.package_digest.len() != 64
        || !r
            .package_digest
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        Err(error(MarketplaceErrorCodeDto::InvalidRequest, false))
    } else {
        Ok(())
    }
}
fn canonicalize_consent(
    consent: &[MarketplaceCapabilityDto],
) -> Result<Vec<MarketplaceCapabilityDto>, MarketplaceErrorDto> {
    if consent.len() > MAX_CONSENT_IDS {
        Err(error(MarketplaceErrorCodeDto::InvalidRequest, false))
    } else {
        let mut canonical = consent.to_vec();
        canonical.sort_unstable();
        if canonical.windows(2).any(|pair| pair[0] == pair[1]) {
            Err(error(MarketplaceErrorCodeDto::InvalidRequest, false))
        } else {
            Ok(canonical)
        }
    }
}
fn operation(
    phase: MarketplaceOperationPhaseDto,
    error: Option<MarketplaceErrorDto>,
) -> MarketplaceOperationStateDto {
    MarketplaceOperationStateDto { phase, error }
}
pub(crate) fn error(code: MarketplaceErrorCodeDto, retryable: bool) -> MarketplaceErrorDto {
    MarketplaceErrorDto {
        code,
        retryable,
        correlation_id: None,
    }
}
pub(crate) fn unavailable() -> MarketplaceErrorDto {
    error(MarketplaceErrorCodeDto::CatalogUnavailable, true)
}
fn not_found() -> MarketplaceErrorDto {
    error(MarketplaceErrorCodeDto::NotFound, false)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::sync::Mutex;

    use super::*;
    use semver::Version;
    use timetrace_plugin_api::{
        MarketplaceCatalogPage, MarketplaceError as ContractError, MarketplaceSignatureVerifier,
        Platform,
    };

    #[test]
    fn marketplace_capability_wire_ids_are_exact_dot_contract_ids() {
        for (dto, wire) in [
            (
                MarketplaceCapabilityDto::UsageAggregateRead,
                "usage.aggregate.read",
            ),
            (MarketplaceCapabilityDto::AiCloud, "ai.cloud"),
            (MarketplaceCapabilityDto::AiLocal, "ai.local"),
        ] {
            let parsed = dto_capability(&dto).expect("contract capability parses");
            assert_eq!(parsed.as_str(), wire);
            assert_eq!(capability_dto(&parsed), Ok(dto));
        }
        for legacy in ["usage-aggregate-read", "ai-cloud", "ai-local"] {
            let parsed = CapabilityId::new(legacy).expect("syntactically valid id");
            assert_eq!(
                capability_dto(&parsed),
                Err(error(MarketplaceErrorCodeDto::Internal, false))
            );
        }
    }

    #[derive(Clone)]
    struct TestVerifier;
    impl MarketplaceSignatureVerifier for TestVerifier {
        fn verify_ed25519(&self, _: &str, _: &[u8], _: &[u8; 64]) -> Result<(), ContractError> {
            Ok(())
        }
    }

    struct RecordingService {
        catalog: VerifiedMarketplaceCatalogPage,
        release: MarketplaceReleaseSummary,
        installed_version: Option<Version>,
        install: Mutex<Option<(BTreeSet<CapabilityId>, Vec<CapabilityId>)>>,
        install_calls: Mutex<u32>,
    }
    impl MarketplaceBridgeService for RecordingService {
        fn verified_catalog(
            &self,
            _: &MarketplaceCatalogQueryDto,
        ) -> Result<VerifiedMarketplaceCatalogPage, MarketplaceErrorDto> {
            Ok(self.catalog.clone())
        }
        fn verified_release(
            &self,
            reference: &MarketplaceReleaseRefDto,
        ) -> Result<MarketplaceReleaseSummary, MarketplaceErrorDto> {
            same_release(&self.release, reference)
                .then(|| self.release.clone())
                .ok_or_else(not_found)
        }
        fn compatibility(
            &self,
            _: &MarketplaceReleaseSummary,
        ) -> Result<MarketplaceCompatibilityInput, MarketplaceErrorDto> {
            Ok(MarketplaceCompatibilityInput {
                host_api: Version::new(1, 0, 0),
                platform: Platform::WindowsX64,
                max_package_bytes: 16 * 1024 * 1024,
                approved_permissions: BTreeSet::new(),
                installed_version: self.installed_version.clone(),
                locally_blocked: false,
            })
        }
        fn install(
            &self,
            _: &MarketplaceReleaseSummary,
            compatibility: &MarketplaceCompatibilityInput,
            consent: &[CapabilityId],
        ) -> Result<(), MarketplaceErrorDto> {
            *self.install_calls.lock().expect("recording lock") += 1;
            *self.install.lock().expect("recording lock") =
                Some((compatibility.approved_permissions.clone(), consent.to_vec()));
            Ok(())
        }
    }

    fn recording_service() -> Arc<RecordingService> {
        recording_service_with_installed_version(None)
    }

    fn recording_service_with_installed_version(
        installed_version: Option<Version>,
    ) -> Arc<RecordingService> {
        recording_service_with(installed_version, None)
    }

    fn recording_service_with(
        installed_version: Option<Version>,
        permissions: Option<Vec<CapabilityId>>,
    ) -> Arc<RecordingService> {
        let page = MarketplaceCatalogPage::parse_bounded(include_bytes!(
            "../../contracts/fixtures/marketplace-catalog-v1/catalog.json"
        ))
        .expect("fixture catalog")
        .verify(&TestVerifier)
        .expect("fixture verification");
        let mut release = page.as_page().items[0].clone();
        if let Some(permissions) = permissions {
            release.permissions = permissions;
        }
        Arc::new(RecordingService {
            catalog: page,
            release,
            installed_version,
            install: Mutex::new(None),
            install_calls: Mutex::new(0),
        })
    }

    fn install_request(consent: Vec<MarketplaceCapabilityDto>) -> MarketplaceInstallRequestDto {
        MarketplaceInstallRequestDto {
            release: MarketplaceReleaseRefDto {
                release_id: "123e4567-e89b-12d3-a456-426614174000".into(),
                publisher_id: "wellorbetter".into(),
                plugin_id: "unicode-demo".into(),
                version: "1.2.3".into(),
                package_digest: "a".repeat(64),
            },
            consent_capability_ids: consent,
        }
    }

    #[test]
    fn exact_consent_is_projected_into_installer_compatibility() {
        let service = recording_service();
        let provider = MarketplaceBridgeProvider::new(service.clone());
        let state = provider.install(install_request(vec![
            MarketplaceCapabilityDto::UsageAggregateRead,
        ]));
        assert_eq!(state.phase, MarketplaceOperationPhaseDto::Enabled);
        let (approved, consent) = service
            .install
            .lock()
            .expect("recording lock")
            .clone()
            .expect("installer called");
        let expected = CapabilityId::new("usage.aggregate.read").expect("capability");
        assert_eq!(approved, BTreeSet::from([expected.clone()]));
        assert_eq!(consent, vec![expected]);
    }

    #[test]
    fn unsorted_release_permissions_are_canonicalized_before_consent_and_install() {
        let usage = CapabilityId::new("usage.aggregate.read").expect("capability");
        let cloud = CapabilityId::new("ai.cloud").expect("capability");
        let service = recording_service_with(None, Some(vec![cloud.clone(), usage.clone()]));
        let provider = MarketplaceBridgeProvider::new(service.clone());
        let state = provider.install(install_request(vec![
            MarketplaceCapabilityDto::AiCloud,
            MarketplaceCapabilityDto::UsageAggregateRead,
        ]));
        assert_eq!(state.phase, MarketplaceOperationPhaseDto::Enabled);
        let (_, consent) = service
            .install
            .lock()
            .expect("recording lock")
            .clone()
            .expect("installer called");
        assert_eq!(consent, vec![usage, cloud]);
    }

    #[test]
    fn missing_or_extra_consent_never_reaches_installer() {
        for consent in [
            vec![],
            vec![
                MarketplaceCapabilityDto::UsageAggregateRead,
                MarketplaceCapabilityDto::AiCloud,
            ],
        ] {
            let service = recording_service();
            let provider = MarketplaceBridgeProvider::new(service.clone());
            let state = provider.install(install_request(consent));
            assert_eq!(state.phase, MarketplaceOperationPhaseDto::Blocked);
            assert_eq!(
                state.error.map(|error| error.code),
                Some(MarketplaceErrorCodeDto::ConsentMismatch)
            );
            assert!(service.install.lock().expect("recording lock").is_none());
        }
    }

    #[test]
    fn downgrade_blocked_never_reaches_installer_download_boundary() {
        let service = recording_service_with_installed_version(Some(Version::new(2, 0, 0)));
        let provider = MarketplaceBridgeProvider::new(service.clone());
        let state = provider.install(install_request(vec![
            MarketplaceCapabilityDto::UsageAggregateRead,
        ]));
        assert_eq!(state.phase, MarketplaceOperationPhaseDto::Failed);
        assert_eq!(
            state.error.map(|error| error.code),
            Some(MarketplaceErrorCodeDto::InvalidRequest)
        );
        assert_eq!(
            *service.install_calls.lock().expect("recording lock"),
            0,
            "DowngradeBlocked must not cross the installer/download boundary"
        );
    }
}
