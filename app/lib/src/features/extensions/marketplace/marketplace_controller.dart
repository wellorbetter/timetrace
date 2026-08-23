library;

import 'package:flutter/foundation.dart';

import 'marketplace_models.dart';
import 'marketplace_port.dart';

class MarketplaceCatalogController extends ChangeNotifier {
  MarketplaceCatalogController(this._port);

  final MarketplaceCatalogPort _port;
  MarketplaceListState state = MarketplaceListState.initial;
  MarketplaceCatalogSnapshot? snapshot;
  Object? error;

  /// True only while a continuation request is in flight.
  bool isLoadingMore = false;

  bool get canLoadMore => snapshot?.nextCursor != null;

  Future<void> load() async {
    state = MarketplaceListState.loading;
    error = null;
    notifyListeners();
    try {
      snapshot = await _port.listPlugins();
      state = MarketplaceListState.ready;
    } catch (caught) {
      error = caught;
      state = MarketplaceListState.failed;
    }
    notifyListeners();
  }

  /// Appends the next verified host page without interpreting its cursor.
  Future<void> loadMore() async {
    final current = snapshot;
    final cursor = current?.nextCursor;
    if (state != MarketplaceListState.ready ||
        current == null ||
        cursor == null ||
        isLoadingMore) {
      return;
    }
    isLoadingMore = true;
    error = null;
    notifyListeners();
    try {
      final next = await _port.listPlugins(cursor: cursor);
      snapshot = MarketplaceCatalogSnapshot(
        plugins: _appendUnique(current.plugins, next.plugins),
        nextCursor: next.nextCursor,
      );
    } catch (caught) {
      // Preserve the already verified page rather than hiding it because a
      // later page is temporarily unavailable.
      error = caught;
    } finally {
      isLoadingMore = false;
      notifyListeners();
    }
  }

  List<MarketplacePluginSummary> _appendUnique(
    List<MarketplacePluginSummary> existing,
    List<MarketplacePluginSummary> next,
  ) {
    final known = <String>{for (final plugin in existing) _catalogKey(plugin)};
    return [
      ...existing,
      for (final plugin in next)
        if (known.add(_catalogKey(plugin))) plugin,
    ];
  }

  String _catalogKey(MarketplacePluginSummary plugin) =>
      '${plugin.publisherId.value}\u0000${plugin.id.value}';
}

class MarketplaceDetailController extends ChangeNotifier {
  MarketplaceDetailController(this._port, this.publisherId, this.pluginId);

  final MarketplaceCatalogPort _port;
  final MarketplacePublisherId publisherId;
  final MarketplacePluginId pluginId;
  MarketplaceDetailState state = MarketplaceDetailState.initial;
  MarketplaceInstallState installState = MarketplaceInstallState.idle;
  MarketplacePluginDetail? detail;
  Object? error;
  MarketplaceInstallErrorCode? installFailureCode;

  Future<void> load() async {
    state = MarketplaceDetailState.loading;
    error = null;
    notifyListeners();
    try {
      detail = await _port.getPlugin(publisherId, pluginId);
      state = detail == null
          ? MarketplaceDetailState.unavailable
          : MarketplaceDetailState.ready;
    } catch (caught) {
      error = caught;
      state = MarketplaceDetailState.failed;
    }
    notifyListeners();
  }

  Future<void> install(List<MarketplaceConsentCapability> consentIds) async {
    final current = detail;
    if (current == null || !current.isInstallable) {
      installState = switch (current?.releaseState) {
        MarketplaceReleaseState.publisherSuspended =>
          MarketplaceInstallState.publisherSuspended,
        MarketplaceReleaseState.revoked => MarketplaceInstallState.revoked,
        MarketplaceReleaseState.signatureInvalid =>
          MarketplaceInstallState.signatureInvalid,
        _ => MarketplaceInstallState.blocked,
      };
      notifyListeners();
      return;
    }
    installState = MarketplaceInstallState.installing;
    installFailureCode = null;
    notifyListeners();
    try {
      final required = current.permissionDiff.requested
          .map((permission) => permission.consentCapability)
          .toList(growable: false);
      if (!_sameCapabilitySet(required, consentIds)) {
        installState = MarketplaceInstallState.blocked;
        installFailureCode = MarketplaceInstallErrorCode.permissionChanged;
        notifyListeners();
        return;
      }
      final result = await _port.install(current.release, required);
      installFailureCode = result.failureCode;
      installState = result.isSuccess
          ? MarketplaceInstallState.installed
          : switch (result.failureCode) {
              MarketplaceInstallErrorCode.releaseRevoked =>
                MarketplaceInstallState.revoked,
              MarketplaceInstallErrorCode.publisherSuspended =>
                MarketplaceInstallState.publisherSuspended,
              MarketplaceInstallErrorCode.signatureInvalid ||
              MarketplaceInstallErrorCode.digestMismatch =>
                MarketplaceInstallState.signatureInvalid,
              _ => MarketplaceInstallState.failed,
            };
    } catch (caught) {
      installState = MarketplaceInstallState.failed;
      installFailureCode = MarketplaceInstallErrorCode.unknown;
      error = caught;
    }
    notifyListeners();
  }

  bool _sameCapabilitySet(
    List<MarketplaceConsentCapability> required,
    List<MarketplaceConsentCapability> submitted,
  ) {
    if (required.length != submitted.length) return false;
    final expected = required.toSet();
    final actual = submitted.toSet();
    return expected.length == required.length &&
        actual.length == submitted.length &&
        expected.containsAll(actual);
  }
}
