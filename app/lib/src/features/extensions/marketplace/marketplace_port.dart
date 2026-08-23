/// A local DTO boundary for marketplace presentation.
///
/// Production transport, signature verification and package download are not
/// part of Flutter UI. They can be adapted to this port without exposing a
/// remote URL, HTML, script, widget, or package payload to presentation code.
library;

import 'marketplace_models.dart';

abstract interface class MarketplaceCatalogPort {
  /// Lists one host-verified catalog page.
  ///
  /// [cursor] is an opaque value received from an earlier response; it is not
  /// a page number, offset, URL, or client-generated token.
  Future<MarketplaceCatalogSnapshot> listPlugins({String? cursor});

  Future<MarketplacePluginDetail?> getPlugin(
    MarketplacePublisherId publisherId,
    MarketplacePluginId pluginId,
  );

  /// Installs exactly the release the user reviewed, not an id-selected latest.
  Future<MarketplaceInstallResult> install(
    MarketplaceReleaseRef release,
    List<MarketplaceConsentCapability> consentCapabilityIds,
  );
}
