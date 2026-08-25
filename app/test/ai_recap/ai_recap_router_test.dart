import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_card.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

void main() {
  testWidgets('legacy report routes return to dashboard without generation', (
    tester,
  ) async {
    final port = _CountingPort();
    final router = createAppRouter(initialLocation: '/ai-recap');
    addTearDown(router.dispose);

    await _pumpRouter(tester, router, port);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(2));
    expect(rail.selectedIndex, 0);
    expect(port.generateCalls, 0);
  });

  testWidgets('dashboard report controls stay inline', (tester) async {
    final port = _CountingPort();
    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        ShellRoute(
          builder: (_, _, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/dashboard',
              builder: (_, _) => Scaffold(
                body: SingleChildScrollView(
                  child: AiRecapCard(
                    rangeKey: AiRecapRangeKey(
                      scope: AiRecapScope.daily,
                      startDate: DateTime(2026, 8, 26),
                      endDate: DateTime(2026, 8, 26),
                    ),
                    rangeLabel: '今日',
                  ),
                ),
              ),
            ),
            GoRoute(path: '/reports', redirect: (_, _) => '/dashboard'),
            GoRoute(path: '/ai-recap', redirect: (_, _) => '/dashboard'),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const Scaffold(body: Text('设置')),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await _pumpRouter(tester, router, port);
    expect(find.byKey(const Key('ai-recap-dashboard-section')), findsOneWidget);
    expect(find.byKey(const Key('ai-recap-range-selector')), findsNothing);
    expect(find.byKey(const Key('ai-report-previous-period')), findsNothing);
    expect(find.byKey(const Key('ai-report-next-period')), findsNothing);
    expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
    expect(port.generateCalls, 0);
  });
}

Future<void> _pumpRouter(
  WidgetTester tester,
  GoRouter router,
  AiRecapPort port,
) async {
  await tester.binding.setSurfaceSize(const Size(1100, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiRecapPortProvider.overrideWithValue(port)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

class _CountingPort implements AiRecapPort {
  int generateCalls = 0;

  @override
  AiRecapProviderStatus status() =>
      const AiRecapProviderStatus(configured: true);

  @override
  List<AiRecapResult> latestReports() => const [];

  @override
  Future<AiRecapResult> generate(AiRecapRangeKey key) {
    generateCalls++;
    throw StateError('Generation is not expected in this test');
  }
}
