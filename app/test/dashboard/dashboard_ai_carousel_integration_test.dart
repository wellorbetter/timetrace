import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  testWidgets(
    'ready AI diary is outside the carousel and follows the top range controls',
    (tester) async {
      final port = _CountingPort(statusValue: _readyStatus);
      await _pumpDashboard(tester, port: port, preferencesEnabled: true);

      final recap = find.byKey(const Key('ai-recap-dashboard-section'));
      expect(recap, findsOneWidget);
      expect(
        find.ancestor(of: recap, matching: find.byType(PageView)),
        findsNothing,
      );
      expect(
        tester.getTopLeft(recap).dy,
        lessThan(tester.getTopLeft(find.byType(DiarySection)).dy),
      );
      expect(find.text('智能日记'), findsOneWidget);
      expect(find.textContaining('今日 ·'), findsOneWidget);
      expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
      expect(port.generateCalls, 0);

      await tester.tap(find.widgetWithText(ChoiceChip, '本周'));
      await tester.pumpAndSettle();

      expect(find.text('智能周记'), findsOneWidget);
      expect(find.textContaining('本周（截至今日） ·'), findsOneWidget);
      expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
      expect(port.generateCalls, 0);

      await tester.tap(find.widgetWithText(ChoiceChip, '本月'));
      await tester.pumpAndSettle();

      expect(find.text('智能月记'), findsOneWidget);
      expect(find.textContaining('本月 ·'), findsOneWidget);
      expect(port.generateCalls, 0);
    },
  );

  testWidgets('AI diary is completely hidden until enabled and ready', (
    tester,
  ) async {
    final cases = <({bool enabled, AiRecapProviderStatus status})>[
      (enabled: false, status: _readyStatus),
      (enabled: true, status: const AiRecapProviderStatus.unconfigured()),
      (enabled: true, status: const AiRecapProviderStatus.unavailable()),
    ];

    for (final testCase in cases) {
      final port = _CountingPort(statusValue: testCase.status);
      await _pumpDashboard(
        tester,
        port: port,
        preferencesEnabled: testCase.enabled,
      );

      expect(find.byKey(const Key('ai-recap-dashboard-section')), findsNothing);
      expect(find.byKey(const Key('ai-diary-content')), findsNothing);
      expect(find.byType(DiarySection), findsOneWidget);
      expect(port.generateCalls, 0);
    }
  });
}

Future<void> _pumpDashboard(
  WidgetTester tester, {
  required _CountingPort port,
  required bool preferencesEnabled,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardProvider.overrideWith(_StaticDashboardNotifier.new),
        dashboardOrderProvider.overrideWith(_StaticOrderNotifier.new),
        aiRecapPortProvider.overrideWithValue(port),
        aiDiaryPreferencesStorageProvider.overrideWithValue(
          _MemoryPreferencesStorage({
            AiDiaryPreferences.enabledKey: preferencesEnabled,
            AiDiaryPreferences.coverSourceKey: 'none',
          }),
        ),
      ],
      child: const MaterialApp(home: DashboardScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

const _readyStatus = AiRecapProviderStatus(
  ready: true,
  serviceAvailable: true,
  selectedProvider: AiRecapProviderId.localSummary,
  selectedModel: AiRecapModel.localSummary,
);

class _StaticDashboardNotifier extends DashboardNotifier {
  @override
  Future<DashboardState> build() async => const DashboardState(
    apps: [],
    totalActiveSeconds: 0,
    totalIdleSeconds: 0,
    lifetimeSeconds: 0,
  );
}

class _StaticOrderNotifier extends DashboardOrderNotifier {
  @override
  List<String> build() => List.of(kDefaultOrder);
}

class _CountingPort implements AiRecapPort {
  _CountingPort({required this.statusValue});

  final AiRecapProviderStatus statusValue;
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() => statusValue;

  @override
  List<AiRecapResult> latestReports() => const [];

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) {
    generateCalls++;
    throw StateError('Generation is not expected in this test');
  }
}

class _MemoryPreferencesStorage implements AiDiaryPreferencesStorage {
  _MemoryPreferencesStorage(Map<String, dynamic> initial)
    : values = Map<String, dynamic>.from(initial);

  final Map<String, dynamic> values;

  @override
  Map<String, dynamic> read() => Map<String, dynamic>.from(values);

  @override
  void update(Map<String, dynamic> values) {
    this.values.addAll(values);
  }
}
