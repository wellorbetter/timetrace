import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  for (final legacyPath in ['/ai-recap', '/reports']) {
    testWidgets(
      '$legacyPath redirects to the dashboard recap without duplicate controls',
      (tester) async {
        final port = _CountingPort();
        final router = createAppRouter(initialLocation: legacyPath);
        addTearDown(router.dispose);

        await _pumpRouter(tester, router, port);

        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          '/dashboard',
        );
        final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
        expect(rail.destinations, hasLength(2));
        expect(rail.selectedIndex, 0);
        expect(
          find.byKey(const Key('ai-recap-dashboard-section')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
        expect(
          find.byKey(const Key('ai-report-previous-period')),
          findsNothing,
        );
        expect(find.byKey(const Key('ai-report-next-period')), findsNothing);
        expect(port.generateCalls, 0);
      },
    );
  }
}

Future<void> _pumpRouter(
  WidgetTester tester,
  GoRouter router,
  AiRecapPort port,
) async {
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
            AiDiaryPreferences.enabledKey: true,
            AiDiaryPreferences.coverSourceKey: 'none',
          }),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

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
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() => const AiRecapProviderStatus(
    ready: true,
    serviceAvailable: true,
    selectedProvider: AiRecapProviderId.localSummary,
    selectedModel: AiRecapModel.localSummary,
  );

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
