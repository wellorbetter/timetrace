import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/features/extensions/marketplace/marketplace.dart';
import 'package:timetrace_app/src/plugin_platform/host/contribution_models.dart';
import 'package:timetrace_app/src/plugin_platform/host/contribution_source.dart';
import 'package:timetrace_app/src/plugin_platform/host/frb_contribution_source.dart';

void main() {
  testWidgets('shell exposes Marketplace as a first-class destination', (
    tester,
  ) async {
    final port = _FakeMarketplacePort();
    final container = _container(port);
    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.storefront_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.storefront_outlined));
    await tester.pumpAndSettle();

    expect(find.byType(MarketplaceScreen), findsOneWidget);
    expect(port.listCalls, 1);
    expect(port.installCalls, 0);
  });

  testWidgets('marketplace route uses only the typed port and never installs', (
    tester,
  ) async {
    final port = _FakeMarketplacePort();
    final container = ProviderContainer(
      overrides: [
        marketplaceCatalogPortProvider.overrideWithValue(port),
        contributionSourceProvider.overrideWithValue(const _EmptySource()),
      ],
      retry: (_, _) => null,
    );
    final router = container.read(appRouterProvider)
      ..go('/extensions/marketplace');
    addTearDown(router.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('插件商店'), findsWidgets);
    expect(find.text('暂无可用插件'), findsOneWidget);
    expect(port.listCalls, 1);
    expect(port.installCalls, 0);
  });

  testWidgets('detail deep link resolves by typed identity without install', (
    tester,
  ) async {
    final port = _FakeMarketplacePort(detail: _detail());
    final container = _container(port);
    final router = container.read(appRouterProvider)
      ..go('/extensions/marketplace/publisher.timetrace/dev.timetrace.focus');
    addTearDown(router.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Focus'), findsOneWidget);
    expect(port.detailRequests, ['publisher.timetrace/dev.timetrace.focus']);
    expect(port.installCalls, 0);
  });

  testWidgets('invalid marketplace detail deep link fails closed', (
    tester,
  ) async {
    final port = _FakeMarketplacePort(detail: _detail());
    final container = _container(port);
    final router = container.read(appRouterProvider)
      ..go('/extensions/marketplace/BadPublisher/dev.timetrace.focus');
    addTearDown(router.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('此插件当前不可用'), findsOneWidget);
    expect(port.detailRequests, isEmpty);
    expect(port.installCalls, 0);
  });

  testWidgets('missing marketplace detail deep link fails closed', (
    tester,
  ) async {
    final port = _FakeMarketplacePort();
    final container = _container(port);
    final router = container.read(appRouterProvider)
      ..go('/extensions/marketplace/publisher.timetrace/dev.timetrace.missing');
    addTearDown(router.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('此插件当前不可用'), findsOneWidget);
    expect(port.detailRequests, ['publisher.timetrace/dev.timetrace.missing']);
    expect(port.installCalls, 0);
  });
}

ProviderContainer _container(_FakeMarketplacePort port) => ProviderContainer(
  overrides: [
    marketplaceCatalogPortProvider.overrideWithValue(port),
    contributionSourceProvider.overrideWithValue(const _EmptySource()),
  ],
  retry: (_, _) => null,
);

MarketplacePluginDetail _detail() {
  const publisherId = MarketplacePublisherId('publisher.timetrace');
  const pluginId = MarketplacePluginId('dev.timetrace.focus');
  const summary = MarketplacePluginSummary(
    id: pluginId,
    displayName: 'Focus',
    version: '1.0.0',
    summary: 'Typed detail',
    compatibility: MarketplaceCompatibility.compatible,
    risk: MarketplaceRiskLevel.low,
    publisherId: publisherId,
  );
  return const MarketplacePluginDetail(
    summary: summary,
    description: 'Typed detail',
    publisherName: 'TimeTrace',
    release: MarketplaceReleaseRef(
      releaseId: 'release-1',
      publisherId: publisherId,
      pluginId: pluginId,
      version: '1.0.0',
      packageDigest: 'digest-1',
    ),
    releaseState: MarketplaceReleaseState.available,
    permissionDiff: MarketplacePermissionDiff(requested: []),
  );
}

final class _EmptySource implements ContributionSource {
  const _EmptySource();

  @override
  Future<ContributionSnapshot> load() async =>
      ContributionSnapshot.empty(revision: BigInt.one);

  @override
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled) {
    throw StateError('unexpected plugin mutation');
  }
}

final class _FakeMarketplacePort implements MarketplaceCatalogPort {
  _FakeMarketplacePort({this.detail});

  int listCalls = 0;
  int installCalls = 0;
  final MarketplacePluginDetail? detail;
  final List<String> detailRequests = [];

  @override
  Future<MarketplaceCatalogSnapshot> listPlugins({String? cursor}) async {
    listCalls += 1;
    return const MarketplaceCatalogSnapshot(plugins: []);
  }

  @override
  Future<MarketplacePluginDetail?> getPlugin(
    MarketplacePublisherId publisherId,
    MarketplacePluginId pluginId,
  ) async {
    detailRequests.add('${publisherId.value}/${pluginId.value}');
    return detail;
  }

  @override
  Future<MarketplaceInstallResult> install(
    MarketplaceReleaseRef release,
    List<MarketplaceConsentCapability> consentCapabilityIds,
  ) async {
    installCalls += 1;
    return const MarketplaceInstallResult.installed();
  }
}
