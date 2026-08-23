import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/plugins/service.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

void main() {
  test('valid host publication decodes and partitions every surface once', () {
    final snapshot = ContributionSnapshot.fromHostDto(_validWireSnapshot(7));

    expect(snapshot.revision, BigInt.from(7));
    expect(snapshot.plugins.single.pluginId, 'private-flight');
    expect(snapshot.plugins.single.manifest.displayName, 'Private Flight');
    expect(snapshot.active, hasLength(6));
    expect(snapshot.navigation, hasLength(1));
    expect(snapshot.pages, hasLength(1));
    expect(snapshot.dashboardCards, hasLength(1));
    expect(snapshot.dashboardCarousels, hasLength(1));
    expect(snapshot.settings, hasLength(1));
    expect(snapshot.commands, hasLength(1));
    expect(snapshot.pages.single.route, '/extensions/private-flight/flight');
    expect(snapshot.pages.single.contributionId, 'private-flight.page');
  });

  test('malformed wire publication fails closed without a partial model', () {
    final valid = _validWireSnapshot(1);
    final malformed = HostContributionSnapshotDto(
      revision: valid.revision,
      plugins: valid.plugins,
      active: [
        const HostProjectedContributionDto(
          pluginId: 'private-flight',
          contributionJson: '{not-json',
          route: '/extensions/private-flight/flight',
        ),
      ],
    );

    expect(
      () => ContributionSnapshot.fromHostDto(malformed),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'active descriptor cannot replace a bundled renderer under the same id',
    () {
      final valid = _validWireSnapshot(2);
      final page =
          jsonDecode(valid.active.first.contributionJson)
              as Map<String, Object?>;
      final descriptor = page['descriptor']! as Map<String, Object?>;
      descriptor['renderer'] = {
        'mode': 'bundled_typed',
        'contract_id': 'timetrace.private-flight.replaced.v1',
        'schema_version': 1,
      };
      final malformed = HostContributionSnapshotDto(
        revision: valid.revision,
        plugins: valid.plugins,
        active: [
          HostProjectedContributionDto(
            pluginId: 'private-flight',
            contributionJson: jsonEncode(page),
            route: '/extensions/private-flight/flight',
          ),
          ...valid.active.skip(1),
        ],
      );

      expect(
        () => ContributionSnapshot.fromHostDto(malformed),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('navigation cannot retarget a different page under the same id', () {
    final valid = _validWireSnapshot(3);
    final navigation =
        jsonDecode(valid.active[1].contributionJson) as Map<String, Object?>;
    final descriptor = navigation['descriptor']! as Map<String, Object?>;
    descriptor['page_id'] = 'private-flight.other-page';
    final malformed = HostContributionSnapshotDto(
      revision: valid.revision,
      plugins: valid.plugins,
      active: [
        valid.active.first,
        HostProjectedContributionDto(
          pluginId: 'private-flight',
          contributionJson: jsonEncode(navigation),
          route: '/extensions/private-flight/flight',
        ),
        ...valid.active.skip(2),
      ],
    );

    expect(
      () => ContributionSnapshot.fromHostDto(malformed),
      throwsA(isA<FormatException>()),
    );
  });

  test('host route must equal the route derived from the manifest', () {
    final valid = _validWireSnapshot(4);
    final malformed = HostContributionSnapshotDto(
      revision: valid.revision,
      plugins: valid.plugins,
      active: [
        HostProjectedContributionDto(
          pluginId: 'private-flight',
          contributionJson: valid.active.first.contributionJson,
          route: '/settings',
        ),
        ...valid.active.skip(1),
      ],
    );

    expect(
      () => ContributionSnapshot.fromHostDto(malformed),
      throwsA(isA<FormatException>()),
    );
  });
}

HostContributionSnapshotDto _validWireSnapshot(int revision) {
  final contributions = _contributions();
  final manifest = <String, Object?>{
    'schema_version': 1,
    'id': 'private-flight',
    'publisher': 'timetrace',
    'display_name': 'Private Flight',
    'version': '1.0.0',
    'host_api': '>=1.0.0, <2.0.0',
    'platforms': ['windows_x64'],
    'contributions': contributions,
  };
  return HostContributionSnapshotDto(
    revision: BigInt.from(revision),
    plugins: [
      HostPluginUiStateDto(
        pluginId: 'private-flight',
        manifestJson: jsonEncode(manifest),
        desiredState: 'enabled',
        runtimeState: 'ready',
        compatible: true,
        grantsSatisfied: true,
        generation: BigInt.one,
        failureRetryable: false,
      ),
    ],
    active: [
      for (final contribution in contributions)
        HostProjectedContributionDto(
          pluginId: 'private-flight',
          contributionJson: jsonEncode(contribution),
          route:
              contribution['kind'] == 'page' ||
                  contribution['kind'] == 'navigation'
              ? '/extensions/private-flight/flight'
              : null,
          declarativeDocument: contribution['kind'] == 'dashboard_card'
              ? const HostDeclarativeV1DocumentDto(
                  contributionId: 'private-flight.card',
                  root: HostDeclarativeV1NodeDto.text(text: 'Card content'),
                )
              : null,
        ),
    ],
  );
}

List<Map<String, Object?>> _contributions() {
  Map<String, Object?> metadata(String id, int order) => {
    'id': id,
    'display': {'title': id},
    'order': order,
  };

  return [
    {
      'kind': 'page',
      'descriptor': {
        'metadata': metadata('private-flight.page', 0),
        'view_id': 'flight',
        'renderer': {
          'mode': 'bundled_typed',
          'contract_id': 'timetrace.private-flight.page.v1',
          'schema_version': 1,
        },
      },
    },
    {
      'kind': 'navigation',
      'descriptor': {
        'metadata': metadata('private-flight.navigation', 1),
        'page_id': 'private-flight.page',
      },
    },
    {
      'kind': 'dashboard_card',
      'descriptor': {
        'metadata': metadata('private-flight.card', 2),
        'renderer': {'mode': 'declarative_v1'},
        'size': 'medium',
        'refresh': 'on_demand',
      },
    },
    {
      'kind': 'dashboard_carousel',
      'descriptor': {
        'metadata': metadata('private-flight.carousel', 3),
        'renderer': {'mode': 'declarative_v1'},
        'size': 'wide',
        'refresh': 'data_revision',
      },
    },
    {
      'kind': 'settings',
      'descriptor': {
        'metadata': metadata('private-flight.settings', 4),
        'schema_version': 1,
        'fields': <Object?>[],
      },
    },
    {
      'kind': 'command',
      'descriptor': {
        'metadata': metadata('private-flight.command', 5),
        'input_schema_version': 1,
        'timeout_ms': 1000,
      },
    },
  ];
}
