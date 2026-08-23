/// Verified-only Flutter adapter for the host Marketplace bridge.
library;

import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/bridge/marketplace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

import 'marketplace_models.dart';
import 'marketplace_port.dart';

/// The only production composition point for Marketplace presentation.
///
/// This deliberately exposes the typed port rather than a transport client so
/// routes and widgets cannot access package URLs, bytes, signatures, or keys.
final marketplaceCatalogPortProvider = Provider<MarketplaceCatalogPort>((ref) {
  return FrbMarketplaceCatalogPort(ref.watch(apiProvider));
});

/// Production port: Flutter can express intent, while Rust owns all I/O,
/// signature verification, archive validation, storage, and policy checks.
final class FrbMarketplaceCatalogPort implements MarketplaceCatalogPort {
  const FrbMarketplaceCatalogPort(this._api);

  final TimeTraceApi _api;

  @override
  Future<MarketplaceCatalogSnapshot> listPlugins({String? cursor}) async {
    final page = await _api.marketplaceList(
      query: MarketplaceCatalogQueryDto(
        channel: 'stable',
        cursor: cursor,
        limit: 50,
      ),
    );
    return MarketplaceCatalogSnapshot(
      plugins: page.items.map(_summary).toList(growable: false),
      nextCursor: page.nextCursor,
    );
  }

  @override
  Future<MarketplacePluginDetail?> getPlugin(
    MarketplacePublisherId publisherId,
    MarketplacePluginId pluginId,
  ) async {
    try {
      final detail = await _api.marketplaceDetail(
        reference: MarketplacePluginRefDto(
          publisherId: publisherId.value,
          pluginId: pluginId.value,
        ),
      );
      final selected = detail.selectedRelease;
      if (selected.release.publisherId != publisherId.value ||
          selected.release.pluginId != pluginId.value) {
        return null;
      }
      return MarketplacePluginDetail(
        summary: _summary(selected),
        description: selected.description ?? '',
        publisherName: publisherId.value,
        release: _release(selected.release),
        releaseState: _releaseState(selected.state),
        permissionDiff: MarketplacePermissionDiff(
          requested: detail.installPlan.requiredConsent
              .map(marketplacePermissionFromWire)
              .toList(growable: false),
        ),
      );
    } catch (_) {
      // A host `not_found` and a temporarily unavailable verified catalog are
      // intentionally indistinguishable to this presentation port.
      return null;
    }
  }

  @override
  Future<MarketplaceInstallResult> install(
    MarketplaceReleaseRef release,
    List<MarketplaceConsentCapability> consentCapabilityIds,
  ) async {
    final state = await _api.marketplaceInstall(
      request: MarketplaceInstallRequestDto(
        release: MarketplaceReleaseRefDto(
          releaseId: release.releaseId,
          publisherId: release.publisherId.value,
          pluginId: release.pluginId.value,
          version: release.version,
          packageDigest: release.packageDigest,
        ),
        consentCapabilityIds: consentCapabilityIds.map(_capability).toList(),
      ),
    );
    return switch (state.phase) {
      MarketplaceOperationPhaseDto.enabled =>
        const MarketplaceInstallResult.installed(),
      _ => MarketplaceInstallResult.failed(_error(state.error?.code)),
    };
  }
}

MarketplacePluginSummary _summary(MarketplaceCatalogItemDto item) =>
    MarketplacePluginSummary(
      id: MarketplacePluginId(item.release.pluginId),
      displayName: item.displayName,
      version: item.release.version,
      summary: item.description ?? '',
      compatibility: switch (item.compatibility) {
        MarketplaceDispositionDto.installable ||
        MarketplaceDispositionDto.updateAvailable =>
          MarketplaceCompatibility.compatible,
        MarketplaceDispositionDto.downgradeBlocked =>
          MarketplaceCompatibility.downgradeBlocked,
        MarketplaceDispositionDto.incompatibleHostApi =>
          MarketplaceCompatibility.hostTooOld,
        MarketplaceDispositionDto.incompatiblePlatform =>
          MarketplaceCompatibility.platformUnsupported,
        _ => MarketplaceCompatibility.unknown,
      },
      risk: MarketplaceRiskLevel.low,
      publisherId: MarketplacePublisherId(item.release.publisherId),
    );

MarketplaceReleaseRef _release(MarketplaceReleaseRefDto dto) =>
    MarketplaceReleaseRef(
      releaseId: dto.releaseId,
      publisherId: MarketplacePublisherId(dto.publisherId),
      pluginId: MarketplacePluginId(dto.pluginId),
      version: dto.version,
      packageDigest: dto.packageDigest,
    );

/// Converts the closed native capability enum into a closed UI permission.
MarketplacePermission marketplacePermissionFromWire(
  MarketplacePermissionReviewDto dto,
) => MarketplacePermission(
  kind: switch (dto.capability) {
    MarketplaceCapabilityDto.usageAggregateRead =>
      MarketplacePermissionKind.activityRead,
    MarketplaceCapabilityDto.aiCloud => MarketplacePermissionKind.cloudAi,
    MarketplaceCapabilityDto.aiLocal => MarketplacePermissionKind.localAi,
  },
  risk: switch (dto.capability) {
    MarketplaceCapabilityDto.usageAggregateRead => MarketplaceRiskLevel.low,
    MarketplaceCapabilityDto.aiCloud => MarketplaceRiskLevel.high,
    MarketplaceCapabilityDto.aiLocal => MarketplaceRiskLevel.low,
  },
  consentCapability: switch (dto.capability) {
    MarketplaceCapabilityDto.usageAggregateRead =>
      MarketplaceConsentCapability.usageAggregateRead,
    MarketplaceCapabilityDto.aiCloud => MarketplaceConsentCapability.aiCloud,
    MarketplaceCapabilityDto.aiLocal => MarketplaceConsentCapability.aiLocal,
  },
  summary: dto.summary,
  rationale: dto.rationale,
);

MarketplaceReleaseState _releaseState(MarketplaceReleaseStateDto state) =>
    switch (state) {
      MarketplaceReleaseStateDto.published => MarketplaceReleaseState.available,
      MarketplaceReleaseStateDto.suspended =>
        MarketplaceReleaseState.publisherSuspended,
      MarketplaceReleaseStateDto.revoked => MarketplaceReleaseState.revoked,
    };

MarketplaceCapabilityDto _capability(MarketplaceConsentCapability capability) =>
    switch (capability) {
      MarketplaceConsentCapability.usageAggregateRead =>
        MarketplaceCapabilityDto.usageAggregateRead,
      MarketplaceConsentCapability.aiCloud => MarketplaceCapabilityDto.aiCloud,
      MarketplaceConsentCapability.aiLocal => MarketplaceCapabilityDto.aiLocal,
    };

MarketplaceInstallErrorCode _error(MarketplaceErrorCodeDto? code) =>
    switch (code) {
      MarketplaceErrorCodeDto.packageUnavailable =>
        MarketplaceInstallErrorCode.packageUnavailable,
      MarketplaceErrorCodeDto.digestMismatch =>
        MarketplaceInstallErrorCode.digestMismatch,
      MarketplaceErrorCodeDto.storageUnavailable =>
        MarketplaceInstallErrorCode.storageUnavailable,
      MarketplaceErrorCodeDto.archiveInvalid ||
      MarketplaceErrorCodeDto.catalogInvalid =>
        MarketplaceInstallErrorCode.verificationFailed,
      MarketplaceErrorCodeDto.consentMismatch =>
        MarketplaceInstallErrorCode.permissionChanged,
      MarketplaceErrorCodeDto.releaseIdentityMismatch =>
        MarketplaceInstallErrorCode.compatibilityChanged,
      _ => MarketplaceInstallErrorCode.unknown,
    };
