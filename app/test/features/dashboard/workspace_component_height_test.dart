import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    for (final month in [2, 4, 8]) {
      testWidgets(
        'bounded whole 4/5/6 week month $month scale $scale custom row',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                calendarDataProvider.overrideWith(
                  (ref) async => const CalendarData(
                    images: {},
                    entryImages: {},
                    diaryDays: {},
                    entries: [],
                  ),
                ),
              ],
              child: MaterialApp(
                home: Scaffold(
                  body: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: SizedBox(
                      key: const Key('whole_month'),
                      width: 280,
                      height: 320,
                      child: CalendarGrid(
                        selected: DateTime(2026, month, 1),
                        rowHeight: 60,
                        boundedFit: true,
                        onSelected: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final box = tester.getRect(find.byKey(const Key('whole_month')));
          final table = tester.widget<TableCalendar>(
            find.byType(TableCalendar),
          );
          expect(table.rowHeight, 60 * scale);
          expect(table.sixWeekMonthsEnforced, isTrue);
          expect(table.headerVisible, isFalse);
          expect(
            table.enabledDayPredicate!(
              DateTime.now().add(const Duration(days: 1)),
            ),
            isFalse,
          );
          final last = DateTime(2026, month + 1, 0).day.toString();
          for (final day in ['1', last]) {
            final rect = tester.getRect(find.text(day).first);
            expect(rect.left, greaterThanOrEqualTo(box.left));
            expect(rect.right, lessThanOrEqualTo(box.right));
            expect(rect.bottom, lessThanOrEqualTo(box.bottom));
            expect(rect.top, greaterThanOrEqualTo(box.top));
          }
          expect(find.byType(SingleChildScrollView), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final height in [320.0, 360.0, 560.0]) {
    testWidgets('calendar fills bounded cell and six-week month at $height', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            calendarDataProvider.overrideWith(
              (ref) async => const CalendarData(
                images: {},
                entryImages: {},
                diaryDays: {},
                entries: [],
              ),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 440,
                height: height,
                child: CalendarGrid(
                  selected: DateTime(2026, 10, 3),
                  onSelected: (_) {},
                  fillHeight: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<TableCalendar>(find.byType(TableCalendar));
      expect(table.shouldFillViewport, isTrue);
      expect(table.sixWeekMonthsEnforced, isTrue);
      expect(tester.getSize(find.byType(TableCalendar)).height, height);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TableCalendar)).height, height);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('long application list keeps card height and scrolls last row', (
    tester,
  ) async {
    final apps = [
      for (var i = 0; i < 30; i++)
        AppUsageItem(appName: 'test_app_$i', activeSeconds: 60, idleSeconds: 0),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 440,
            height: 360,
            child: AppListSection(
              apps: apps,
              selected: null,
              windows: null,
              onSelect: (_) {},
              rowKeys: [for (final _ in apps) GlobalKey()],
            ),
          ),
        ),
      ),
    );
    final initial = tester.getRect(find.byType(Card));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1600),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(Card)), initial);
    expect(
      tester.getRect(find.text('test_app_29')).bottom,
      lessThanOrEqualTo(initial.bottom),
    );
    expect(
      tester.getRect(find.text('test_app_29')).top,
      greaterThan(initial.top),
    );
    expect(tester.takeException(), isNull);
  });
}
