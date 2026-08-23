import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/plugins/service.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

void main() {
  testWidgets('canonical settings toggle mutates through ContributionSource', (
    tester,
  ) async {
    var mutations = 0;
    final source = _FakeContributionSource(
      onLoad: () async => _snapshot(enabled: false, revision: 1),
      onSetEnabled: (pluginId, enabled) async {
        expect(pluginId, 'private-flight');
        expect(enabled, isTrue);
        mutations++;
        return _snapshot(enabled: true, revision: 2);
      },
    );

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();
    expect(find.text('Private Flight'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(mutations, 1);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('source failure hides inventory and retry reloads it', (
    tester,
  ) async {
    var loads = 0;
    final source = _FakeContributionSource(
      onLoad: () async {
        loads++;
        if (loads == 1) {
          throw const ContributionSourceException('snapshot_unavailable');
        }
        return _snapshot(enabled: false, revision: 2);
      },
      onSetEnabled: (_, _) => throw StateError('unexpected mutation'),
    );

    await tester.pumpWidget(_app(source));
    await tester.pumpAndSettle();
    expect(find.text('Private Flight'), findsNothing);

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Private Flight'), findsOneWidget);
  });
}

Widget _app(ContributionSource source) {
  return ProviderScope(
    overrides: [contributionSourceProvider.overrideWithValue(source)],
    retry: (_, _) => null,
    child: const MaterialApp(home: Scaffold(body: PluginSettingsSection())),
  );
}

ContributionSnapshot _snapshot({required bool enabled, required int revision}) {
  final manifest = jsonEncode({
    'schema_version': 1,
    'id': 'private-flight',
    'publisher': 'wellorbetter',
    'display_name': 'Private Flight',
    'version': '1.0.0',
    'host_api': '>=1.0.0, <2.0.0',
    'platforms': ['windows_x64'],
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
      active: const [],
    ),
  );
}

final class _FakeContributionSource implements ContributionSource {
  const _FakeContributionSource({
    required this.onLoad,
    required this.onSetEnabled,
  });

  final Future<ContributionSnapshot> Function() onLoad;
  final Future<ContributionSnapshot> Function(String pluginId, bool enabled)
  onSetEnabled;

  @override
  Future<ContributionSnapshot> load() => onLoad();

  @override
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled) {
    return onSetEnabled(pluginId, enabled);
  }
}
