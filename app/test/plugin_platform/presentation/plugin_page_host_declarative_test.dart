import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/plugins/service.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';
import 'package:timetrace_app/src/plugin_platform/presentation/plugin_page_host.dart';

void main() {
  testWidgets('renders only the host-projected declarative v1 document', (
    tester,
  ) async {
    final source = _Source(
      ContributionSnapshot.fromHostDto(
        _snapshot(
          document: const HostDeclarativeV1DocumentDto(
            contributionId: 'sample-insights.overview',
            root: HostDeclarativeV1NodeDto.stack(
              children: [
                HostDeclarativeV1NodeDto.text(text: 'Signed overview'),
                HostDeclarativeV1NodeDto.metric(label: 'Today', value: '3'),
                HostDeclarativeV1NodeDto.list(items: ['One', 'Two']),
              ],
            ),
          ),
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [contributionSourceProvider.overrideWithValue(source)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: PluginPageHost(pluginId: 'sample-insights', viewId: 'overview'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Signed overview'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  test('rejects a declarative document for the wrong contribution', () {
    expect(
      () => ContributionSnapshot.fromHostDto(
        _snapshot(
          document: const HostDeclarativeV1DocumentDto(
            contributionId: 'sample-insights.other',
            root: HostDeclarativeV1NodeDto.text(text: 'wrong owner'),
          ),
        ),
      ),
      throwsFormatException,
    );
  });

  test('rejects an active declarative page with no typed host projection', () {
    final wire = _snapshot(
      document: const HostDeclarativeV1DocumentDto(
        contributionId: 'sample-insights.overview',
        root: HostDeclarativeV1NodeDto.text(text: 'valid'),
      ),
    );
    final missing = HostContributionSnapshotDto(
      revision: wire.revision,
      plugins: wire.plugins,
      active: [
        HostProjectedContributionDto(
          pluginId: wire.active.single.pluginId,
          contributionJson: wire.active.single.contributionJson,
          route: wire.active.single.route,
        ),
      ],
    );

    expect(
      () => ContributionSnapshot.fromHostDto(missing),
      throwsFormatException,
    );
  });
}

final class _Source implements ContributionSource {
  const _Source(this.snapshot);

  final ContributionSnapshot snapshot;

  @override
  Future<ContributionSnapshot> load() async => snapshot;

  @override
  Future<ContributionSnapshot> setEnabled(
    String pluginId,
    bool enabled,
  ) async => snapshot;
}

HostContributionSnapshotDto _snapshot({
  required HostDeclarativeV1DocumentDto document,
}) {
  final page = <String, Object?>{
    'kind': 'page',
    'descriptor': {
      'metadata': {
        'id': 'sample-insights.overview',
        'display': {'title': 'Overview'},
        'order': 0,
      },
      'view_id': 'overview',
      'renderer': {'mode': 'declarative_v1'},
    },
  };
  return HostContributionSnapshotDto(
    revision: BigInt.one,
    plugins: [
      HostPluginUiStateDto(
        pluginId: 'sample-insights',
        manifestJson: jsonEncode({
          'schema_version': 1,
          'id': 'sample-insights',
          'publisher': 'timetrace-labs',
          'display_name': 'Sample Insights',
          'version': '1.0.0',
          'host_api': '>=1.0.0, <2.0.0',
          'platforms': ['windows_x64'],
          'contributions': [page],
        }),
        desiredState: 'enabled',
        runtimeState: 'ready',
        compatible: true,
        grantsSatisfied: true,
        generation: BigInt.one,
        failureRetryable: false,
      ),
    ],
    active: [
      HostProjectedContributionDto(
        pluginId: 'sample-insights',
        contributionJson: jsonEncode(page),
        route: '/extensions/sample-insights/overview',
        declarativeDocument: document,
      ),
    ],
  );
}
