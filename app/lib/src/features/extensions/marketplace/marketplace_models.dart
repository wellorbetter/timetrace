/// Strongly typed, presentation-safe models for the extension marketplace.
///
/// These types deliberately contain no HTML, scripts, package bytes, or remote
/// executable references. Package verification and installation remain an
/// application-service responsibility behind [MarketplaceCatalogPort].
library;

import 'package:flutter/foundation.dart';

@immutable
class MarketplacePluginId {
  const MarketplacePluginId(this.value) : assert(value.length > 0);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is MarketplacePluginId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

@immutable
class MarketplacePublisherId {
  const MarketplacePublisherId(this.value) : assert(value.length > 0);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is MarketplacePublisherId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// The exact reviewed release that an install operation is permitted to use.
///
/// It is immutable and deliberately contains no download location. A service
/// adapter must resolve it and verify its digest before installation.
@immutable
class MarketplaceReleaseRef {
  const MarketplaceReleaseRef({
    required this.releaseId,
    required this.publisherId,
    required this.pluginId,
    required this.version,
    required this.packageDigest,
  }) : assert(releaseId.length > 0),
       assert(packageDigest.length > 0);

  final String releaseId;
  final MarketplacePublisherId publisherId;
  final MarketplacePluginId pluginId;
  final String version;
  final String packageDigest;
}

/// The only capabilities Flutter may submit as explicit marketplace consent.
/// Values map one-to-one to the closed native bridge enum.
enum MarketplaceConsentCapability { usageAggregateRead, aiCloud, aiLocal }

/// A catalog-provided compatibility result. Unknown is intentionally not
/// installable: a client must understand a compatibility claim before acting.
enum MarketplaceCompatibility {
  compatible,
  downgradeBlocked,
  hostTooOld,
  platformUnsupported,
  unknown;

  bool get allowsInstall => this == MarketplaceCompatibility.compatible;
}

/// The reviewed risk tier of a permission. Unknown is fail-closed.
enum MarketplaceRiskLevel {
  none,
  low,
  elevated,
  high,
  unknown;

  bool get isKnown => this != MarketplaceRiskLevel.unknown;
}

/// A display-safe permission declaration. The backend must map package claims
/// to this closed set; the UI never interprets arbitrary permission strings.
enum MarketplacePermissionKind {
  activityRead,
  activityWrite,
  network,
  cloudAi,
  localAi,
  localFiles,
  notifications,
  unknown,
}

@immutable
class MarketplacePermission {
  const MarketplacePermission({
    required this.kind,
    required this.risk,
    required this.consentCapability,
    required this.summary,
    this.rationale,
  });

  final MarketplacePermissionKind kind;
  final MarketplaceRiskLevel risk;
  final MarketplaceConsentCapability consentCapability;
  final String summary;
  final String? rationale;

  bool get isKnown => kind != MarketplacePermissionKind.unknown && risk.isKnown;
}

@immutable
class MarketplacePermissionDiff {
  const MarketplacePermissionDiff({
    required this.requested,
    this.removed = const <MarketplacePermission>[],
  });

  final List<MarketplacePermission> requested;
  final List<MarketplacePermission> removed;

  /// An unknown permission or risk can never be accepted from this UI.
  bool get isReviewable => requested.every((permission) => permission.isKnown);
}

@immutable
class MarketplacePluginSummary {
  const MarketplacePluginSummary({
    required this.id,
    required this.displayName,
    required this.version,
    required this.summary,
    required this.compatibility,
    required this.risk,
    required this.publisherId,
  });

  final MarketplacePluginId id;
  final String displayName;
  final String version;
  final String summary;
  final MarketplaceCompatibility compatibility;
  final MarketplaceRiskLevel risk;
  final MarketplacePublisherId publisherId;

  bool get isInstallable => compatibility.allowsInstall && risk.isKnown;
}

@immutable
class MarketplacePluginDetail {
  const MarketplacePluginDetail({
    required this.summary,
    required this.description,
    required this.permissionDiff,
    required this.publisherName,
    required this.release,
    required this.releaseState,
  });

  final MarketplacePluginSummary summary;
  final String description;
  final MarketplacePermissionDiff permissionDiff;
  final String publisherName;
  final MarketplaceReleaseRef release;
  final MarketplaceReleaseState releaseState;

  bool get isInstallable =>
      summary.isInstallable &&
      permissionDiff.isReviewable &&
      releaseState.allowsInstall &&
      release.publisherId == summary.publisherId &&
      release.pluginId == summary.id;
}

@immutable
class MarketplaceCatalogSnapshot {
  const MarketplaceCatalogSnapshot({required this.plugins, this.nextCursor});

  /// Every item in this verified page sequence, in host catalog order.
  final List<MarketplacePluginSummary> plugins;

  /// Exact opaque continuation token supplied by the verified host page.
  ///
  /// Flutter neither parses nor synthesizes this value. `null` alone means
  /// that the sequence has ended.
  final String? nextCursor;
}

enum MarketplaceListState { initial, loading, ready, failed }

enum MarketplaceDetailState { initial, loading, ready, failed, unavailable }

/// Server/catalog status of a release. Each non-available status is closed.
enum MarketplaceReleaseState {
  available,
  publisherSuspended,
  revoked,
  signatureInvalid,
  unknown;

  bool get allowsInstall => this == MarketplaceReleaseState.available;
}

enum MarketplaceInstallState {
  idle,
  installing,
  installed,
  blocked,
  publisherSuspended,
  revoked,
  signatureInvalid,
  failed,
}

/// Stable presentation-safe result codes; never render raw transport errors.
enum MarketplaceInstallErrorCode {
  packageUnavailable,
  releaseRevoked,
  publisherSuspended,
  signatureInvalid,
  digestMismatch,
  compatibilityChanged,
  permissionChanged,
  verificationFailed,
  storageUnavailable,
  unknown,
}

@immutable
class MarketplaceInstallResult {
  const MarketplaceInstallResult.installed() : failureCode = null;
  const MarketplaceInstallResult.failed(this.failureCode)
    : assert(failureCode != null);

  final MarketplaceInstallErrorCode? failureCode;
  bool get isSuccess => failureCode == null;
}
