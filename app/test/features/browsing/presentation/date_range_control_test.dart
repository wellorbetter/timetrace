import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/features/browsing/models/browsing_state.dart';
import 'package:timetrace_app/src/features/browsing/presentation/date_range_control.dart';

void main() {
  for (final iconOnly in [false, true]) {
    for (final width in [280.0, 360.0, 720.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'glass date overlays keep canonical callbacks $width scale$scale iconOnly:$iconOnly',
          (tester) async {
            tester.view.physicalSize = Size(width, 850);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final policy = MaterialPolicy.resolve(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              wallpaper: WallpaperLoadState.absent,
              signals: const MaterialSignals(
                highContrast: AccessibilitySignal.disabled,
                reduceTransparency: AccessibilitySignal.disabled,
              ),
            );
            var calls = 0;
            await tester.pumpWidget(
              MaterialApp(
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
                      child: DateRangeControl(
                        selection: DateRangeSelection(DateRange.today),
                        iconOnly: iconOnly,
                        onRange: (_) => calls++,
                        onDay: (_) => calls++,
                      ),
                    ),
                  ),
                ),
              ),
            );
            final trigger = find.ancestor(
              of: find.byIcon(Icons.calendar_month_outlined),
              matching: find.byType(iconOnly ? IconButton : TextButton),
            );
            if (iconOnly) {
              expect(tester.getSize(trigger), const Size(48, 48));
            } else {
              expect(tester.getSize(trigger).height, greaterThanOrEqualTo(48));
            }
            final controlBounds = tester.getRect(find.byType(DateRangeControl));
            expect(controlBounds.left, greaterThanOrEqualTo(0));
            expect(controlBounds.right, lessThanOrEqualTo(width));
            for (final action in tester.widgetList<IconButton>(
              find.byType(IconButton),
            )) {
              final target = find.byWidget(action);
              expect(tester.getSize(target).width, greaterThanOrEqualTo(48));
              expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
              expect(controlBounds.contains(tester.getCenter(target)), isTrue);
            }
            await tester.tap(trigger);
            await tester.pumpAndSettle();
            final panel = tester.widget<MaterialTransientPanel>(
              find.byType(MaterialTransientPanel),
            );
            expect(panel.capture!.scope!.policy, same(policy));
            expect(find.byType(MaterialCard), findsOneWidget);
            final viewport = Offset.zero & Size(width, 850);
            final bounds = tester.getRect(find.byType(MaterialCard));
            expect(bounds.width, greaterThan(0));
            expect(bounds.height, greaterThan(0));
            expect(viewport.contains(bounds.topLeft), isTrue);
            expect(bounds.right, lessThanOrEqualTo(viewport.right));
            expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom));
            await tester.tap(find.text('选择日期…'));
            await tester.pumpAndSettle();
            expect(find.byType(DatePickerDialog), findsOneWidget);
            expect(find.byType(MaterialCard), findsOneWidget);
            expect(find.byType(BackdropFilter), findsNothing);
            final cancel = find.widgetWithText(TextButton, '取消');
            final cancelBounds = tester.getRect(cancel);
            expect(cancelBounds.height, greaterThanOrEqualTo(48));
            expect(viewport.contains(cancelBounds.center), isTrue);
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(calls, 0);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  const presets = <DateRange, String>{
    DateRange.today: '今天',
    DateRange.yesterday: '昨天',
    DateRange.week: '近 7 天',
    DateRange.month: '近 30 天',
  };

  Widget harness({
    required DateRangeSelection selection,
    required ValueChanged<DateRange> onRange,
    required ValueChanged<DateTime> onDay,
    bool enabled = true,
    bool iconOnly = false,
    ThemeData? theme,
  }) => MaterialApp(
    theme: theme,
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: DateRangeControl(
          selection: selection,
          onRange: onRange,
          onDay: onDay,
          enabled: enabled,
          iconOnly: iconOnly,
        ),
      ),
    ),
  );

  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  Finder navigationButton(String tooltip) => find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == tooltip,
    description: 'IconButton with tooltip "$tooltip"',
  );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
  }

  for (final preset in presets.entries) {
    testWidgets('${preset.value} sends the existing range callback', (
      tester,
    ) async {
      final ranges = <DateRange>[];
      final days = <DateTime>[];
      await tester.pumpWidget(
        harness(
          selection: const DateRangeSelection(DateRange.today),
          onRange: ranges.add,
          onDay: days.add,
        ),
      );

      await openMenu(tester);
      final item = menuItem(preset.value);
      expect(item, findsOneWidget);
      expect(
        tester.getSize(item).height,
        greaterThanOrEqualTo(MaterialTokens.minimumTarget),
      );
      await tester.tap(item);
      await tester.pumpAndSettle();

      expect(ranges, [preset.key]);
      expect(days, isEmpty);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(
        tester
            .widget<DateRangeControl>(find.byType(DateRangeControl))
            .selection
            .range,
        DateRange.today,
      );
    });
  }

  for (final brightness in Brightness.values) {
    for (final preset in presets.entries) {
      testWidgets(
        '${brightness.name}: ${preset.value} has themed fill and trailing check',
        (tester) async {
          final scheme = ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          );
          await tester.pumpWidget(
            harness(
              selection: DateRangeSelection(preset.key),
              onRange: (_) {},
              onDay: (_) {},
              theme: ThemeData(useMaterial3: true, colorScheme: scheme),
            ),
          );

          await openMenu(tester);
          final anchor = tester.widget<MenuAnchor>(find.byType(MenuAnchor));
          final menuStyle = anchor.style!;
          expect(
            menuStyle.backgroundColor!.resolve(const <WidgetState>{}),
            Colors.transparent,
          );
          expect(
            menuStyle.shadowColor!.resolve(const <WidgetState>{}),
            Colors.transparent,
          );
          expect(menuStyle.elevation!.resolve(const <WidgetState>{}), 0);
          expect(find.byType(MaterialTransientPanel), findsOneWidget);
          expect(find.byType(MaterialCard), findsOneWidget);
          expect(
            tester.widget<Card>(find.byType(Card)).clipBehavior,
            Clip.antiAlias,
          );
          expect(find.byType(BackdropFilter), findsNothing);

          for (final other in presets.entries) {
            final item = tester.widget<MenuItemButton>(menuItem(other.value));
            final selected = other.key == preset.key;
            expect(
              item.style!.backgroundColor!.resolve(const <WidgetState>{}),
              selected
                  ? scheme.primary.withValues(alpha: 0.10)
                  : Colors.transparent,
            );
            expect(
              item.style!.foregroundColor!.resolve(const <WidgetState>{}),
              scheme.onSurface,
            );
            expect(item.leadingIcon, isNull);
            if (selected) {
              expect((item.trailingIcon! as Icon).icon, Icons.check_rounded);
            } else {
              expect(item.trailingIcon, isNull);
            }
          }
          expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        },
      );
    }
  }

  testWidgets('custom selection keeps the date picker accessible', (
    tester,
  ) async {
    final ranges = <DateRange>[];
    final days = <DateTime>[];
    final initialDay = DateTime(2024, 1, 10);
    await tester.pumpWidget(
      harness(
        selection: DateRangeSelection(DateRange.custom, day: initialDay),
        onRange: ranges.add,
        onDay: days.add,
      ),
    );

    await openMenu(tester);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    await tester.tap(menuItem('选择日期…'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('选择查看日期'), findsOneWidget);

    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(days, [initialDay]);
    expect(ranges, isEmpty);
    expect(find.byType(DatePickerDialog), findsNothing);
  });

  testWidgets('cancelling the date picker sends no callbacks', (tester) async {
    final ranges = <DateRange>[];
    final days = <DateTime>[];
    await tester.pumpWidget(
      harness(
        selection: const DateRangeSelection(DateRange.today),
        onRange: ranges.add,
        onDay: days.add,
      ),
    );

    await openMenu(tester);
    await tester.tap(menuItem('选择日期…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(ranges, isEmpty);
    expect(days, isEmpty);
  });

  for (final iconOnly in [false, true]) {
    testWidgets('disabled control cannot open (iconOnly: $iconOnly)', (
      tester,
    ) async {
      final ranges = <DateRange>[];
      final days = <DateTime>[];
      await tester.pumpWidget(
        harness(
          selection: const DateRangeSelection(DateRange.today),
          onRange: ranges.add,
          onDay: days.add,
          enabled: false,
          iconOnly: iconOnly,
        ),
      );

      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      )) {
        expect(button.onPressed, isNull);
      }
      for (final button in tester.widgetList<TextButton>(
        find.byType(TextButton),
      )) {
        expect(button.onPressed, isNull);
      }
      await tester.tap(find.byIcon(Icons.calendar_month_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(ranges, isEmpty);
      expect(days, isEmpty);
    });
  }

  testWidgets('icon-only control retains its tooltip and range action', (
    tester,
  ) async {
    DateRange? selectedRange;
    await tester.pumpWidget(
      harness(
        selection: const DateRangeSelection(DateRange.today),
        onRange: (value) => selectedRange = value,
        onDay: (_) {},
        iconOnly: true,
      ),
    );

    expect(find.byTooltip('前一天'), findsNothing);
    expect(find.byTooltip('后一天'), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).tooltip,
      startsWith('选择日期：今天'),
    );
    await openMenu(tester);
    await tester.tap(menuItem('昨天'));
    await tester.pumpAndSettle();
    expect(selectedRange, DateRange.yesterday);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final iconOnly in [false, true]) {
      testWidgets('${platform.name}: Escape dismisses after clicking open '
          'without callbacks (iconOnly: $iconOnly)', (tester) async {
        final previousPlatform = debugDefaultTargetPlatformOverride;
        debugDefaultTargetPlatformOverride = platform;
        try {
          final ranges = <DateRange>[];
          final days = <DateTime>[];
          await tester.pumpWidget(
            harness(
              selection: const DateRangeSelection(DateRange.today),
              onRange: ranges.add,
              onDay: days.add,
              iconOnly: iconOnly,
            ),
          );

          // Reopening also exercises the persistent trigger focus node.
          // Do not focus a menu item before sending Escape.
          for (var opening = 0; opening < 2; opening++) {
            await openMenu(tester);
            expect(find.byType(MenuItemButton), findsNWidgets(5));
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(find.byType(MenuItemButton), findsNothing);
            expect(ranges, isEmpty);
            expect(days, isEmpty);
          }
        } finally {
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      });
    }
  }

  testWidgets('moves a selected day without changing range locally', (
    tester,
  ) async {
    final days = <DateTime>[];
    final ranges = <DateRange>[];
    await tester.pumpWidget(
      harness(
        selection: DateRangeSelection(
          DateRange.custom,
          day: DateTime(2024, 1, 10),
        ),
        onRange: ranges.add,
        onDay: days.add,
      ),
    );

    await tester.tap(navigationButton('前一天'));
    await tester.pump();
    await tester.tap(navigationButton('后一天'));
    await tester.pump();
    expect(days, [DateTime(2024, 1, 9), DateTime(2024, 1, 11)]);
    expect(ranges, isEmpty);
  });

  testWidgets('today cannot move forward', (tester) async {
    await tester.pumpWidget(
      harness(
        selection: const DateRangeSelection(DateRange.today),
        onRange: (_) {},
        onDay: (_) {},
      ),
    );
    expect(
      tester.widget<IconButton>(navigationButton('后一天')).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(navigationButton('前一天')).onPressed,
      isNotNull,
    );
  });

  for (final range in [DateRange.week, DateRange.month]) {
    testWidgets('$range disables single-day navigation', (tester) async {
      await tester.pumpWidget(
        harness(
          selection: DateRangeSelection(range),
          onRange: (_) {},
          onDay: (_) {},
        ),
      );
      expect(
        tester.widget<IconButton>(navigationButton('前一天')).onPressed,
        isNull,
      );
      expect(
        tester.widget<IconButton>(navigationButton('后一天')).onPressed,
        isNull,
      );
    });
  }
}
