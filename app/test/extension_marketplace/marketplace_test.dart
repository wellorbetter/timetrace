import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/bridge/marketplace.dart';
import 'package:timetrace_app/src/features/extensions/marketplace/marketplace.dart';

void main() {
  final plugin = MarketplacePluginSummary(
    id: const MarketplacePluginId('dev.timetrace.focus'),
    displayName: 'Focus',
    version: '1.0.0',
    summary: 'Focus helper',
    compatibility: MarketplaceCompatibility.compatible,
    risk: MarketplaceRiskLevel.low,
    publisherId: const MarketplacePublisherId('publisher.timetrace'),
  );

  test('unknown compatibility and risk are fail-closed', () {
    expect(
      plugin
          .copyWithCompatibility(MarketplaceCompatibility.unknown)
          .isInstallable,
      isFalse,
    );
    expect(
      plugin.copyWithRisk(MarketplaceRiskLevel.unknown).isInstallable,
      isFalse,
    );
  });

  test('native capability permission mapping preserves execution impact', () {
    final usage = marketplacePermissionFromWire(
      const MarketplacePermissionReviewDto(
        capability: MarketplaceCapabilityDto.usageAggregateRead,
        summary: 'usage',
      ),
    );
    final cloud = marketplacePermissionFromWire(
      const MarketplacePermissionReviewDto(
        capability: MarketplaceCapabilityDto.aiCloud,
        summary: 'cloud',
      ),
    );
    final local = marketplacePermissionFromWire(
      const MarketplacePermissionReviewDto(
        capability: MarketplaceCapabilityDto.aiLocal,
        summary: 'local',
      ),
    );
    expect(usage.kind, MarketplacePermissionKind.activityRead);
    expect(usage.risk, MarketplaceRiskLevel.low);
    expect(cloud.kind, MarketplacePermissionKind.cloudAi);
    expect(cloud.risk, MarketplaceRiskLevel.high);
    expect(local.kind, MarketplacePermissionKind.localAi);
    expect(local.risk, MarketplaceRiskLevel.low);
  });

  test('controller blocks installation before calling its port', () async {
    final port = _FakePort(detail: _detail(plugin, unknownPermission: true));
    final controller = MarketplaceDetailController(
      port,
      plugin.publisherId,
      plugin.id,
    );
    await controller.load();
    await controller.install(const [
      MarketplaceConsentCapability.usageAggregateRead,
    ]);
    expect(controller.installState, MarketplaceInstallState.blocked);
    expect(port.installCalls, 0);
  });

  test('controller requires the exact explicit consent set', () async {
    final port = _FakePort(detail: _detail(plugin));
    final controller = MarketplaceDetailController(
      port,
      plugin.publisherId,
      plugin.id,
    );
    await controller.load();
    await controller.install(const []);
    expect(controller.installState, MarketplaceInstallState.blocked);
    expect(
      controller.installFailureCode,
      MarketplaceInstallErrorCode.permissionChanged,
    );
    expect(port.installCalls, 0);
  });

  test(
    'same plugin id from another publisher keeps its reviewed release',
    () async {
      final otherPublisherPlugin = MarketplacePluginSummary(
        id: plugin.id,
        displayName: plugin.displayName,
        version: plugin.version,
        summary: plugin.summary,
        compatibility: plugin.compatibility,
        risk: plugin.risk,
        publisherId: const MarketplacePublisherId('publisher.other'),
      );
      final port = _FakePort(detail: _detail(otherPublisherPlugin));
      final controller = MarketplaceDetailController(
        port,
        otherPublisherPlugin.publisherId,
        plugin.id,
      );
      await controller.load();
      await controller.install(const [
        MarketplaceConsentCapability.usageAggregateRead,
      ]);
      expect(
        port.installedRelease!.publisherId,
        otherPublisherPlugin.publisherId,
      );
      expect(port.installedRelease!.pluginId, plugin.id);
    },
  );

  test('installation stays bound to reviewed release and digest', () async {
    final port = _FakePort(
      detail: _detail(plugin, releaseId: 'release-reviewed'),
    );
    final controller = MarketplaceDetailController(
      port,
      plugin.publisherId,
      plugin.id,
    );
    await controller.load();
    // A later catalog revision cannot replace the immutable detail release.
    port.detail = _detail(plugin, releaseId: 'release-newer');
    await controller.install(const [
      MarketplaceConsentCapability.usageAggregateRead,
    ]);
    expect(port.installedRelease!.releaseId, 'release-reviewed');
    expect(port.installedRelease!.packageDigest, 'digest-release-reviewed');
  });

  test(
    'revoked, suspended, and signature failures remain explicit and closed',
    () async {
      for (final entry in <(MarketplaceReleaseState, MarketplaceInstallState)>[
        (MarketplaceReleaseState.revoked, MarketplaceInstallState.revoked),
        (
          MarketplaceReleaseState.publisherSuspended,
          MarketplaceInstallState.publisherSuspended,
        ),
        (
          MarketplaceReleaseState.signatureInvalid,
          MarketplaceInstallState.signatureInvalid,
        ),
      ]) {
        final port = _FakePort(detail: _detail(plugin, releaseState: entry.$1));
        final controller = MarketplaceDetailController(
          port,
          plugin.publisherId,
          plugin.id,
        );
        await controller.load();
        await controller.install(const [
          MarketplaceConsentCapability.usageAggregateRead,
        ]);
        expect(controller.installState, entry.$2);
        expect(port.installCalls, 0);
      }
    },
  );

  test('stable failure code closes install state', () async {
    final port = _FakePort(
      detail: _detail(plugin),
      result: const MarketplaceInstallResult.failed(
        MarketplaceInstallErrorCode.digestMismatch,
      ),
    );
    final controller = MarketplaceDetailController(
      port,
      plugin.publisherId,
      plugin.id,
    );
    await controller.load();
    await controller.install(const [
      MarketplaceConsentCapability.usageAggregateRead,
    ]);
    expect(controller.installState, MarketplaceInstallState.signatureInvalid);
    expect(
      controller.installFailureCode,
      MarketplaceInstallErrorCode.digestMismatch,
    );
  });

  testWidgets('catalog opens only typed local plugin detail', (tester) async {
    final port = _FakePort(detail: _detail(plugin));
    final router = GoRouter(
      initialLocation: '/extensions/marketplace',
      routes: [
        GoRoute(
          path: '/extensions/marketplace',
          builder: (_, _) => MarketplaceScreen(port: port),
        ),
        GoRoute(
          name: 'marketplace-detail',
          path: '/extensions/marketplace/:publisherId/:pluginId',
          builder: (_, state) => MarketplaceDetailScreen(
            port: port,
            publisherId: MarketplacePublisherId(
              state.pathParameters['publisherId']!,
            ),
            pluginId: MarketplacePluginId(state.pathParameters['pluginId']!),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Focus'), findsOneWidget);
    await tester.tap(find.text('Focus'));
    await tester.pumpAndSettle();
    expect(find.text('权限变更'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
  });

  test(
    'controller preserves an opaque cursor and appends the 51st item',
    () async {
      final firstPage = List.generate(50, (index) => _summary('plugin-$index'));
      final item51 = _summary('plugin-50');
      final port = _PagedFakePort(
        pages: {
          null: MarketplaceCatalogSnapshot(
            plugins: firstPage,
            nextCursor: 'opaque:cursor/+not-an-offset',
          ),
          'opaque:cursor/+not-an-offset': MarketplaceCatalogSnapshot(
            plugins: [firstPage.last, item51],
          ),
        },
        detail: _detail(plugin),
      );
      final controller = MarketplaceCatalogController(port);

      await controller.load();
      await controller.loadMore();

      expect(port.cursors, [null, 'opaque:cursor/+not-an-offset']);
      expect(controller.snapshot!.plugins, hasLength(51));
      expect(controller.snapshot!.plugins.last.id.value, 'plugin-50');
      expect(controller.canLoadMore, isFalse);
      expect(port.installCalls, 0);
    },
  );

  testWidgets('catalog exposes an explicit load-more action for later pages', (
    tester,
  ) async {
    final port = _PagedFakePort(
      pages: {
        null: MarketplaceCatalogSnapshot(
          plugins: [_summary('plugin-0')],
          nextCursor: 'opaque-next',
        ),
        'opaque-next': MarketplaceCatalogSnapshot(
          plugins: [_summary('plugin-50')],
        ),
      },
      detail: _detail(plugin),
    );
    await tester.pumpWidget(MaterialApp(home: MarketplaceScreen(port: port)));
    await tester.pumpAndSettle();

    expect(find.text('加载更多'), findsOneWidget);
    expect(find.text('plugin-50'), findsNothing);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(find.text('plugin-50'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(port.cursors, [null, 'opaque-next']);
    expect(port.installCalls, 0);
  });
}

MarketplacePluginSummary _summary(String id) => MarketplacePluginSummary(
  id: MarketplacePluginId(id),
  displayName: id,
  version: '1.0.0',
  summary: 'summary',
  compatibility: MarketplaceCompatibility.compatible,
  risk: MarketplaceRiskLevel.low,
  publisherId: const MarketplacePublisherId('publisher.timetrace'),
);

extension on MarketplacePluginSummary {
  MarketplacePluginSummary copyWithCompatibility(
    MarketplaceCompatibility value,
  ) => MarketplacePluginSummary(
    id: id,
    displayName: displayName,
    version: version,
    summary: summary,
    compatibility: value,
    risk: risk,
    publisherId: publisherId,
  );
  MarketplacePluginSummary copyWithRisk(MarketplaceRiskLevel value) =>
      MarketplacePluginSummary(
        id: id,
        displayName: displayName,
        version: version,
        summary: summary,
        compatibility: compatibility,
        risk: value,
        publisherId: publisherId,
      );
}

MarketplacePluginDetail _detail(
  MarketplacePluginSummary plugin, {
  bool unknownPermission = false,
  String releaseId = 'release-current',
  MarketplaceReleaseState releaseState = MarketplaceReleaseState.available,
}) => MarketplacePluginDetail(
  summary: plugin,
  description: 'A typed plugin description.',
  publisherName: 'TimeTrace',
  release: MarketplaceReleaseRef(
    releaseId: releaseId,
    publisherId: plugin.publisherId,
    pluginId: plugin.id,
    version: '1.0.0',
    packageDigest: 'digest-$releaseId',
  ),
  releaseState: releaseState,
  permissionDiff: MarketplacePermissionDiff(
    requested: [
      MarketplacePermission(
        kind: unknownPermission
            ? MarketplacePermissionKind.unknown
            : MarketplacePermissionKind.activityRead,
        risk: MarketplaceRiskLevel.low,
        consentCapability: MarketplaceConsentCapability.usageAggregateRead,
        summary: 'Read aggregated activity totals',
      ),
    ],
  ),
);

class _FakePort implements MarketplaceCatalogPort {
  _FakePort({
    required this.detail,
    this.result = const MarketplaceInstallResult.installed(),
  });

  MarketplacePluginDetail detail;
  final MarketplaceInstallResult result;
  int installCalls = 0;
  MarketplaceReleaseRef? installedRelease;

  @override
  Future<MarketplacePluginDetail?> getPlugin(
    MarketplacePublisherId publisherId,
    MarketplacePluginId id,
  ) async => detail;

  @override
  Future<MarketplaceInstallResult> install(
    MarketplaceReleaseRef release,
    List<MarketplaceConsentCapability> consentCapabilityIds,
  ) async {
    installCalls++;
    installedRelease = release;
    return result;
  }

  @override
  Future<MarketplaceCatalogSnapshot> listPlugins({String? cursor}) async =>
      MarketplaceCatalogSnapshot(plugins: [detail.summary]);
}

final class _PagedFakePort extends _FakePort {
  _PagedFakePort({required this.pages, required super.detail});

  final Map<String?, MarketplaceCatalogSnapshot> pages;
  final List<String?> cursors = [];

  @override
  Future<MarketplaceCatalogSnapshot> listPlugins({String? cursor}) async {
    cursors.add(cursor);
    return pages[cursor]!;
  }
}
