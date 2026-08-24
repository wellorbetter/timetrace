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

void main() {
  testWidgets('legacy /ai-recap redirects to /reports without generation', (
    tester,
  ) async {
    final port = _CountingPort();
    final router = createAppRouter(initialLocation: '/ai-recap');
    addTearDown(router.dispose);

    await _pumpRouter(tester, router, port);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/reports');
    expect(find.text('AI 时间报告'), findsOneWidget);
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.destinations, hasLength(2));
    expect(rail.selectedIndex, 0);
    expect(port.generateCalls, 0);
  });

  testWidgets('dashboard card opens reports and back returns to dashboard', (
    tester,
  ) async {
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
            GoRoute(path: '/reports', builder: (_, _) => const AiRecapScreen()),
            GoRoute(path: '/ai-recap', redirect: (_, _) => '/reports'),
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
    expect(find.byKey(const Key('ai-recap-dashboard-card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ai-recap-open-detail')));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/reports');
    expect(find.text('AI 时间报告'), findsOneWidget);
    expect(port.generateCalls, 0);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/dashboard');
    expect(find.byKey(const Key('ai-recap-dashboard-card')), findsOneWidget);
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
