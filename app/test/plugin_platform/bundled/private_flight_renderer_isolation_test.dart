import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_state.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';
import 'package:timetrace_app/src/features/flight/presentation/flight_screen.dart';
import 'package:timetrace_app/src/features/flight/presentation/private_flight_contract.dart';

void main() {
  testWidgets('pure flight view renders and acts without a ProviderScope', (
    tester,
  ) async {
    final actions = _FakePrivateFlightActions();
    final model = PrivateFlightViewModel(
      controller: const FlightControllerState(activeSession: null),
      today: const PrivateFlightLoad.data(
        FlightTodayStats(count: 2, totalSeconds: 900),
      ),
      recent: const PrivateFlightLoad.data(<PrivateFlightSession>[]),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FlightScreen(model: model, actions: actions),
      ),
    );
    await tester.ensureVisible(find.text('开始起飞'));
    await tester.tap(find.text('开始起飞'));
    await tester.pump();

    expect(actions.startCalls, 1);
    expect(find.text('今日次数'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  test('pure renderer files contain no Riverpod or raw bridge access', () {
    const paths = [
      'lib/src/features/flight/presentation/flight_screen.dart',
      'lib/src/features/flight/presentation/private_flight_contract.dart',
      'lib/src/features/flight/presentation/widgets/flight_recent_list.dart',
      'lib/src/features/flight/presentation/widgets/flight_detail_sheet.dart',
      'lib/src/features/flight/presentation/widgets/flight_complete_sheet.dart',
      'lib/src/plugin_platform/bundled/private_flight_renderer.dart',
    ];
    const forbidden = [
      'flutter_riverpod',
      'apiProvider',
      'TimeTraceApi',
      'WidgetRef',
      'ConsumerWidget',
      'ConsumerState',
      'bridge/api.dart',
      'FlightSessionDto',
      'ref.read',
      'ref.watch',
    ];

    for (final path in paths) {
      final source = File(path).readAsStringSync();
      for (final token in forbidden) {
        expect(
          source,
          isNot(contains(token)),
          reason: '$path must not depend on $token',
        );
      }
    }
  });

  test('recent records exposed to the view are immutable', () {
    final model = PrivateFlightViewModel(
      controller: const FlightControllerState(activeSession: null),
      today: const PrivateFlightLoad.data(FlightTodayStats.zero),
      recent: const PrivateFlightLoad.data(<PrivateFlightSession>[]),
    );

    expect(() => model.recent.value!.add(_session), throwsUnsupportedError);
  });
}

const _session = PrivateFlightSession(
  id: 7,
  startedAt: '2026-08-16T08:00:00Z',
  endedAt: '2026-08-16T08:10:00Z',
  durationSecs: 600,
  status: 'completed',
  satisfaction: null,
  note: '',
  date: '2026-08-16',
);

final class _FakePrivateFlightActions implements PrivateFlightActions {
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> discard() async {}

  @override
  Future<bool> complete(
    PrivateFlightSession session,
    FlightCompletionDraft draft,
  ) async => true;

  @override
  Future<List<PrivateFlightMaterialLink>> loadMaterials(
    PrivateFlightSession session,
  ) async => const [];

  @override
  void refreshRecent() {}

  @override
  void refreshToday() {}
}
