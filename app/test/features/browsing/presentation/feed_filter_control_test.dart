import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/browsing/models/feed_fragment.dart';
import 'package:timetrace_app/src/features/feed/presentation/feed_filter_control.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/core/widgets/terminal_app_icon.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

void main() {
  for (final width in [280.0, 360.0, 720.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'canonical grouped choices $width scale$scale $brightness',
          (tester) async {
            tester.view.physicalSize = Size(width, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final policy = MaterialPolicy.resolve(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.teal,
                brightness: brightness,
              ),
              wallpaper: WallpaperLoadState.absent,
              signals: const MaterialSignals(
                highContrast: AccessibilitySignal.disabled,
                reduceTransparency: AccessibilitySignal.disabled,
              ),
            );
            FeedFilter chosen = const FeedFilter(
              windowId: '相同标题',
              windowAppId: 'msedge',
            );
            var callbacks = 0;
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(colorScheme: policy.colorScheme),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(width),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: FeedFilterControl(
                        filter: chosen,
                        apps: const [
                          'msedge',
                          'edge',
                          'LeagueClient',
                          'LeagueClientUx',
                        ],
                        windows: const [
                          FeedFilter(windowId: '相同标题', windowAppId: 'msedge'),
                          FeedFilter(windowId: '相同标题', windowAppId: 'edge'),
                          FeedFilter(windowId: '未知窗口'),
                          FeedFilter(
                            windowId: '同一中文标题',
                            windowAppId: 'LeagueClient',
                          ),
                          FeedFilter(
                            windowId: '同一中文标题',
                            windowAppId: 'LeagueClientUx',
                          ),
                        ],
                        onChanged: (value) {
                          chosen = value;
                          callbacks++;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            );
            final trigger = find.byKey(const Key('feed_global_filter'));
            expect(tester.getSize(trigger), const Size(48, 48));
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('feed_process_group:msedge')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('feed_process_group:edge')),
              findsOneWidget,
            );
            final panel = tester.widget<MaterialTransientPanel>(
              find.byType(MaterialTransientPanel),
            );
            expect(panel.capture!.scope!.policy, same(policy));
            expect(find.byType(MaterialCard), findsOneWidget);
            expect(find.byType(BackdropFilter), findsNothing);
            final viewport = Offset.zero & Size(width, 800);
            final panelBounds = tester.getRect(find.byType(MaterialCard));
            expect(panelBounds.width, greaterThan(0));
            expect(panelBounds.height, greaterThan(0));
            expect(viewport.contains(panelBounds.topLeft), isTrue);
            expect(panelBounds.right, lessThanOrEqualTo(viewport.right));
            expect(panelBounds.bottom, lessThanOrEqualTo(viewport.bottom));
            final second = find.byKey(
              const ValueKey<FeedFilter>(
                FeedFilter(windowId: '相同标题', windowAppId: 'edge'),
              ),
            );
            final scrollable = find.descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            );
            await tester.scrollUntilVisible(second, 60, scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(tester.getSize(second).height, greaterThanOrEqualTo(48));
            expect(tester.getRect(second).overlaps(panelBounds), isTrue);
            await tester.tap(second);
            await tester.pumpAndSettle();
            expect(
              chosen,
              const FeedFilter(windowId: '相同标题', windowAppId: 'edge'),
            );
            expect(callbacks, 1);
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            final unknown = find.byKey(
              const ValueKey<FeedFilter>(FeedFilter(windowId: '未知窗口')),
            );
            await tester.scrollUntilVisible(
              unknown,
              60,
              scrollable: scrollable,
            );
            await tester.pumpAndSettle();
            expect(find.text('未知进程'), findsOneWidget);
            await tester.tap(unknown);
            await tester.pumpAndSettle();
            expect(chosen, const FeedFilter(windowId: '未知窗口'));
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            final firstChinesePair = find.byKey(
              const ValueKey<FeedFilter>(
                FeedFilter(windowId: '同一中文标题', windowAppId: 'LeagueClient'),
              ),
            );
            await tester.scrollUntilVisible(
              firstChinesePair,
              60,
              scrollable: scrollable,
            );
            await tester.pumpAndSettle();
            await tester.tap(firstChinesePair);
            await tester.pumpAndSettle();
            expect(
              chosen,
              const FeedFilter(windowId: '同一中文标题', windowAppId: 'LeagueClient'),
            );
            expect(callbacks, 3);
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            final chinesePair = find.byKey(
              const ValueKey<FeedFilter>(
                FeedFilter(windowId: '同一中文标题', windowAppId: 'LeagueClientUx'),
              ),
            );
            await tester.scrollUntilVisible(
              chinesePair,
              60,
              scrollable: scrollable,
            );
            await tester.pumpAndSettle();
            expect(
              tester.getRect(chinesePair).center.dy,
              lessThan(tester.getRect(find.byType(MaterialCard)).bottom),
            );
            expect(
              find.byKey(const ValueKey('feed_process_group:LeagueClient')),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('feed_process_group:LeagueClientUx')),
              findsOneWidget,
            );
            await tester.tap(chinesePair);
            await tester.pumpAndSettle();
            expect(
              chosen,
              const FeedFilter(
                windowId: '同一中文标题',
                windowAppId: 'LeagueClientUx',
              ),
            );
            expect(callbacks, 4);
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            await tester.tap(find.text('全部活动'));
            await tester.pumpAndSettle();
            expect(chosen, const FeedFilter());
            expect(callbacks, 5);
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(MaterialTransientPanel), findsNothing);
            expect(callbacks, 5);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets(
    'global filter shows selection and allows clearing and switching',
    (tester) async {
      FeedFilter chosen = const FeedFilter(appId: 'WindowsTerminal');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeedFilterControl(
              filter: chosen,
              apps: const ['WindowsTerminal', 'msedge'],
              windows: const [
                FeedFilter(windowId: 'cmd.exe', windowAppId: 'WindowsTerminal'),
              ],
              onChanged: (value) => chosen = value,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('feed_global_filter')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.tap(find.text('Windows Terminal').first);
      await tester.pumpAndSettle();
      expect(chosen, const FeedFilter());
      await tester.tap(find.byKey(const Key('feed_global_filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('窗口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cmd.exe'));
      await tester.pumpAndSettle();
      expect(
        chosen,
        const FeedFilter(windowId: 'cmd.exe', windowAppId: 'WindowsTerminal'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('terminal fallback paints without an executable or icon font', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: AppIcon(exePath: '', appName: 'WindowsTerminal'),
        ),
      ),
    );
    expect(find.byType(TerminalAppIcon), findsOneWidget);
    expect(find.text('W'), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('leaf controls never request the injected forbidden API', (
    tester,
  ) async {
    var apiReads = 0;
    final chosen = <FeedFilter>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWith((ref) {
            apiReads++;
            throw StateError('Forbidden default/native API');
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: FeedFilterControl(
              filter: const FeedFilter(),
              apps: const ['LeagueClient', 'LeagueClientUx'],
              windows: const [],
              onChanged: chosen.add,
            ),
          ),
        ),
      ),
    );
    final trigger = find.byKey(const Key('feed_global_filter'));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey<FeedFilter>(FeedFilter(appId: 'LeagueClientUx')),
      ),
    );
    await tester.pumpAndSettle();
    expect(chosen, [const FeedFilter(appId: 'LeagueClientUx')]);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(chosen, hasLength(1));
    expect(apiReads, 0);
    expect(tester.takeException(), isNull);
  });
}
