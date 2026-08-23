import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/bridge/plugins/service.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

void main() {
  testWidgets('/flight redirects to the generic disabled plugin safe page', (
    tester,
  ) async {
    final source = _FakeContributionSource(
      onLoad: () async => _snapshot(enabled: false),
    );
    final harness = _RouterHarness(source, initialLocation: '/flight');
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(
      harness.router.routeInformationProvider.value.uri.path,
      '/extensions/private-flight/flight',
    );
    expect(find.text('起飞记录 已禁用'), findsOneWidget);
    expect(find.text('启用后才会显示它的导航和页面。'), findsOneWidget);
    expect(find.text('启用扩展'), findsOneWidget);
    expect(find.text('起飞记录'), findsNothing);
  });

  testWidgets('source error hides plugin surfaces and retry reloads safely', (
    tester,
  ) async {
    var loads = 0;
    final source = _FakeContributionSource(
      onLoad: () async {
        loads += 1;
        if (loads == 1) {
          throw const ContributionSourceException('snapshot_unavailable');
        }
        return _snapshot(enabled: false, revision: 2);
      },
    );
    final harness = _RouterHarness(source, initialLocation: '/flight');
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(find.text('扩展暂不可用'), findsOneWidget);
    expect(find.text('插件状态无法安全读取，相关页面已暂时隐藏。'), findsOneWidget);
    expect(find.text('起飞记录'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('起飞记录 已禁用'), findsOneWidget);
  });

  testWidgets('enabled canonical navigation appears in the real rail', (
    tester,
  ) async {
    final source = _FakeContributionSource(
      onLoad: () async => _snapshot(enabled: true),
    );
    final harness = _RouterHarness(source, initialLocation: '/extensions');
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('起飞记录'), findsWidgets);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('起飞记录'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('unknown extension view is a non-actionable safe page', (
    tester,
  ) async {
    final source = _FakeContributionSource(
      onLoad: () async => _snapshot(enabled: false),
    );
    final harness = _RouterHarness(
      source,
      initialLocation: '/extensions/private-flight/not-declared',
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();

    expect(find.text('Extension page not found'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
}

final class _RouterHarness {
  _RouterHarness(ContributionSource source, {required String initialLocation})
    : container = ProviderContainer(
        overrides: [contributionSourceProvider.overrideWithValue(source)],
        retry: (_, _) => null,
      ) {
    router = container.read(appRouterProvider)..go(initialLocation);
  }

  final ProviderContainer container;
  late final GoRouter router;

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );

  void dispose() {
    router.dispose();
    container.dispose();
  }
}

final class _FakeContributionSource implements ContributionSource {
  const _FakeContributionSource({required this.onLoad});

  final Future<ContributionSnapshot> Function() onLoad;

  @override
  Future<ContributionSnapshot> load() => onLoad();

  @override
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled) {
    throw StateError('unexpected mutation: $pluginId=$enabled');
  }
}

ContributionSnapshot _snapshot({required bool enabled, int revision = 1}) {
  final page = <String, Object?>{
    'kind': 'page',
    'descriptor': {
      'metadata': {
        'id': 'private-flight.page',
        'display': {'title': '起飞记录'},
        'order': 0,
      },
      'view_id': 'flight',
      'renderer': {
        'mode': 'bundled_typed',
        'contract_id': 'timetrace.private-flight.page.v1',
        'schema_version': 1,
      },
    },
  };
  final navigation = <String, Object?>{
    'kind': 'navigation',
    'descriptor': {
      'metadata': {
        'id': 'private-flight.navigation',
        'display': {'title': '起飞记录', 'icon': 'flight'},
        'order': 1,
      },
      'page_id': 'private-flight.page',
    },
  };
  final manifest = jsonEncode({
    'schema_version': 1,
    'id': 'private-flight',
    'publisher': 'wellorbetter',
    'display_name': '起飞记录',
    'description': '本地专注与私人飞行记录',
    'version': '1.0.0',
    'host_api': '>=1.0.0, <2.0.0',
    'platforms': ['windows_x64'],
    'contributions': [page, navigation],
  });
  return ContributionSnapshot.fromHostDto(
    HostContributionSnapshotDto(
      revision: BigInt.from(revision),
      plugins: [
        HostPluginUiStateDto(
          pluginId: 'private-flight',
          manifestJson: manifest,
          desiredState: enabled ? 'enabled' : 'disabled',
          runtimeState: enabled ? 'ready' : 'disabled',
          compatible: true,
          grantsSatisfied: true,
          generation: BigInt.one,
          failureRetryable: false,
        ),
      ],
      active: enabled
          ? [
              HostProjectedContributionDto(
                pluginId: 'private-flight',
                contributionJson: jsonEncode(page),
                route: '/extensions/private-flight/flight',
              ),
              HostProjectedContributionDto(
                pluginId: 'private-flight',
                contributionJson: jsonEncode(navigation),
                route: '/extensions/private-flight/flight',
              ),
            ]
          : const [],
    ),
  );
}
