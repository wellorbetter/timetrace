import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

void main() {
  test('app router exposes only overview and settings destinations', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    addTearDown(router.dispose);
    final shell = router.configuration.routes.single as ShellRoute;
    final paths = shell.routes
        .whereType<GoRoute>()
        .map((route) => route.path)
        .toList();

    expect(paths, ['/dashboard', '/settings']);
    expect(paths, isNot(contains('/recap')));
  });

  testWidgets('desktop shell stays compact, opaque and bottom-anchored', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(960, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _testRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(router));
    await tester.pumpAndSettle();

    expect(find.text('TimeTrace'), findsOneWidget);
    expect(find.text('概览'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('回顾'), findsNothing);
    expect(find.text(Platform.isMacOS ? '⌘1' : 'Ctrl+1'), findsOneWidget);
    expect(find.text(Platform.isMacOS ? '⌘,' : 'Ctrl+,'), findsOneWidget);

    final sidebarFinder = find.byKey(const ValueKey('app-sidebar'));
    final sidebar = tester.widget<ColoredBox>(sidebarFinder);
    final sidebarRect = tester.getRect(sidebarFinder);
    expect(sidebar.color.a, 1);
    expect(sidebarRect.width, TimeTraceLayout.sidebarWidth);

    final overview = find.byKey(const ValueKey('sidebar-destination-概览'));
    final settings = find.byKey(const ValueKey('sidebar-destination-设置'));
    expect(tester.getSize(overview), tester.getSize(settings));
    expect(tester.getSize(overview).height, 40);
    expect(tester.getSize(overview).width, TimeTraceLayout.sidebarWidth - 24);
    final overviewSurface = tester.widget<AnimatedContainer>(overview);
    final overviewDecoration = overviewSurface.decoration! as BoxDecoration;
    expect(
      overviewDecoration.color,
      TimetraceTheme.light().colorScheme.primaryContainer,
    );

    final statusFinder = find.byKey(const ValueKey('local-recording-status'));
    final status = tester.widget<Container>(statusFinder);
    final statusDecoration = status.decoration! as BoxDecoration;
    expect(statusDecoration.color?.a, 1);
    expect(
      sidebarRect.bottom - tester.getRect(statusFinder).bottom,
      TimeTraceSpace.sm,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the approved desktop shortcuts navigate', (tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = _testRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(_testApp(router));
    await tester.pumpAndSettle();

    final shortcuts = tester.widget<CallbackShortcuts>(
      find.byType(CallbackShortcuts),
    );
    final activators = shortcuts.bindings.keys.whereType<SingleActivator>();
    expect(
      activators.any(
        (activator) => activator.trigger == LogicalKeyboardKey.digit2,
      ),
      isFalse,
    );
    expect(
      activators.any(
        (activator) => activator.trigger == LogicalKeyboardKey.digit3,
      ),
      isFalse,
    );

    await _sendPlatformShortcut(tester, LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-content')), findsOneWidget);

    await _sendPlatformShortcut(tester, LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dashboard-content')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

GoRouter _testRouter() => GoRouter(
  initialLocation: '/dashboard',
  routes: [
    ShellRoute(
      builder: (_, _, child) => AppShell(child: child),
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (_, _) => const ColoredBox(
            key: ValueKey('dashboard-content'),
            color: Colors.white,
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const ColoredBox(
            key: ValueKey('settings-content'),
            color: Colors.white,
          ),
        ),
      ],
    ),
  ],
);

Widget _testApp(GoRouter router) => ProviderScope(
  child: MaterialApp.router(
    theme: TimetraceTheme.light(),
    routerConfig: router,
  ),
);

Future<void> _sendPlatformShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  final modifier = Platform.isMacOS
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
}
