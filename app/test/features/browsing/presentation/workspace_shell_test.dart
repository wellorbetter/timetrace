import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/features/feed/providers/feed_preferences_provider.dart';

class _Buckets extends FeedBucketMinutesNotifier {
  @override
  int build() => 10;
}

void main() {
  for (final origin in ['/feed', '/dashboard', '/settings']) {
    for (final push in [false, true]) {
      for (final mouseBack in [false, true]) {
        testWidgets('settings return $origin push=$push mouse=$mouseBack', (
          tester,
        ) async {
          final router = GoRouter(
            initialLocation: origin,
            routes: [
              ShellRoute(
                builder: (_, _, child) => AppShell(child: child),
                routes: [
                  for (final path in ['/feed', '/dashboard', '/settings'])
                    GoRoute(
                      path: path,
                      builder: (_, _) => Center(child: Text('fake $path')),
                    ),
                ],
              ),
            ],
          );
          addTearDown(router.dispose);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [feedBucketMinutesProvider.overrideWith(_Buckets.new)],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();
          if (origin != '/settings') {
            if (push) {
              router.push('/settings');
            } else {
              router.go('/settings');
            }
            await tester.pumpAndSettle();
          }
          expect(
            tester
                .widget<IconButton>(find.byKey(const Key('workspace_settings')))
                .onPressed,
            isNotNull,
          );
          if (mouseBack) {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
              buttons: kBackMouseButton,
            );
            await mouse.down(const Offset(300, 300));
            await mouse.up();
          } else {
            await tester.tap(find.byKey(const Key('workspace_settings')));
          }
          await tester.pumpAndSettle();
          final expected = origin == '/dashboard' ? '/dashboard' : '/feed';
          expect(router.routeInformationProvider.value.uri.path, expected);
          // Revisit settings without a stack; last-main memory remains safe.
          router.go('/settings?section=feed');
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('workspace_settings')));
          await tester.pumpAndSettle();
          expect(router.routeInformationProvider.value.uri.path, expected);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final width in [480.0, 1280.0]) {
    testWidgets('compact shell routes and settings at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final router = GoRouter(
        initialLocation: '/feed',
        routes: [
          ShellRoute(
            builder: (_, _, child) => AppShell(child: child),
            routes: [
              for (final path in ['/feed', '/dashboard', '/settings'])
                GoRoute(
                  path: path,
                  builder: (_, _) => Center(child: Text('page $path')),
                ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [feedBucketMinutesProvider.overrideWith(_Buckets.new)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.labelType, NavigationRailLabelType.none);
      expect(rail.destinations, hasLength(2));
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const Key('feed_interval_settings')), findsOneWidget);
      await tester.tap(find.byKey(const Key('feed_interval_settings')));
      await tester.pumpAndSettle();
      expect(router.canPop(), isTrue);
      expect(find.byKey(const Key('feed_interval_settings')), findsNothing);
      expect(find.text('page /settings'), findsOneWidget);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await mouse.down(const Offset(300, 300));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('page /feed'), findsOneWidget);
      router.go('/dashboard');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace_settings')));
      await tester.pumpAndSettle();
      expect(find.text('page /settings'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
