import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_card.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_screen.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

void main() {
  testWidgets(
    'detail stays under dashboard rail and never generates on route',
    (tester) async {
      final port = _CountingPort();
      final router = GoRouter(
        initialLocation: '/dashboard',
        routes: [
          ShellRoute(
            builder: (_, _, child) => AppShell(child: child),
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (_, _) => const Scaffold(body: AiRecapCard()),
              ),
              GoRoute(
                path: '/ai-recap',
                builder: (_, _) => const AiRecapScreen(),
              ),
              GoRoute(
                path: '/settings',
                builder: (_, _) => const Scaffold(body: Text('设置')),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.binding.setSurfaceSize(const Size(1100, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRecapPortProvider.overrideWithValue(port),
            dashboardRangeBoundsProvider.overrideWithValue(_todayBounds),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      var rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(2));
      expect(port.generateCalls, 0);

      await tester.tap(find.byKey(const Key('ai-recap-open-detail')));
      await tester.pumpAndSettle();

      expect(find.text('AI 使用回顾'), findsWidgets);
      rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(2));
      expect(rail.selectedIndex, 0);
      expect(port.generateCalls, 0);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai-recap-dashboard-card')), findsOneWidget);
    },
  );
}

const DateRangeBounds _todayBounds = DateRangeBounds(
  start: '2026-08-24',
  end: '2026-08-24',
  label: '今日',
  supportedByAiRecap: true,
);

class _CountingPort implements AiRecapPort {
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() =>
      const AiRecapProviderStatus(configured: true);

  @override
  AiRecapResult? latest(AiRecapRangeKey key) => null;

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key, AiRecapModel model) {
    generateCalls++;
    throw StateError('Generation is not expected in this test');
  }
}
