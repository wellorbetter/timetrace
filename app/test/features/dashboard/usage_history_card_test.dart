import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/usage_history_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/usage_history_provider.dart';

void main() {
  test('history filters idle/zero/duplicates and merges nearby fragments', () {
    final date = DateTime(2026, 8, 30);
    final entries = compactUsageHistory([
      (date: date, session: _session('Edge', '10:00:00', 20)),
      (date: date, session: _session('Edge', '10:00:00', 20)),
      (date: date, session: _session('Edge', '10:00:30', 20)),
      (date: date, session: _session('无效', '10:01:00', 0)),
      (date: date, session: _session('Idle', '10:01:00', 60, idle: true)),
      (
        date: date,
        session: _session('TFTTencentClient-Win64-Shipping', '10:03:00', 7),
      ),
    ]);

    expect(entries, hasLength(2));
    expect(entries.first.appName, 'TFTTencentClient-Win64-Shipping');
    expect(entries.first.activeSeconds, 7);
    expect(entries.last.appName, 'Edge');
    expect(entries.last.activeSeconds, 40);
    expect(entries.last.sourceCount, 2);
  });

  test('history never merges adjacent fragments across local dates', () {
    final entries = compactUsageHistory([
      (date: DateTime(2026, 8, 30), session: _session('Edge', '23:59:30', 30)),
      (date: DateTime(2026, 8, 31), session: _session('Edge', '00:00:00', 20)),
    ]);

    expect(entries, hasLength(2));
    expect(entries.first.date, DateTime(2026, 8, 31));
    expect(entries.last.date, DateTime(2026, 8, 30));
  });

  test('week and month history are newest-first like diary entries', () {
    final entries = compactUsageHistory([
      (
        date: DateTime(2026, 8, 24),
        session: _session('Monday app', '18:00:00', 30),
      ),
      (
        date: DateTime(2026, 8, 30),
        session: _session('Sunday morning', '09:00:00', 30),
      ),
      (
        date: DateTime(2026, 8, 30),
        session: _session('Sunday evening', '20:00:00', 30),
      ),
    ]);

    expect(entries.map((entry) => entry.appName), [
      'Sunday evening',
      'Sunday morning',
      'Monday app',
    ]);
  });

  test('history does not merge overlapping fragments with a negative gap', () {
    final date = DateTime(2026, 8, 30);
    final entries = compactUsageHistory([
      (date: date, session: _session('Edge', '10:00:00', 120)),
      (date: date, session: _session('Edge', '10:00:30', 20)),
    ]);

    expect(entries, hasLength(2));
  });

  test(
    'ISO timestamps use local time while time-only values stay anchored',
    () {
      final date = DateTime(2026, 8, 30);
      const iso = '2026-08-30T10:00:00Z';
      final entries = compactUsageHistory([
        (date: date, session: _session('UTC app', iso, 20)),
        (date: date, session: _session('Local app', '12:34:56', 20)),
      ]);

      final utcEntry = entries.singleWhere(
        (entry) => entry.appName == 'UTC app',
      );
      final localEntry = entries.singleWhere(
        (entry) => entry.appName == 'Local app',
      );
      expect(utcEntry.start, DateTime.parse(iso).toLocal());
      expect(utcEntry.start.isUtc, isFalse);
      expect(
        localEntry.start,
        DateTime(date.year, date.month, date.day, 12, 34, 56),
      );
    },
  );

  test('history bounds follow the selected dashboard range', () {
    final now = DateTime(2026, 8, 30, 23, 10);
    expect(
      usageHistoryBounds(const DateRangeSelection(DateRange.today), now: now),
      (DateTime(2026, 8, 30), DateTime(2026, 8, 30)),
    );
    expect(
      usageHistoryBounds(const DateRangeSelection(DateRange.week), now: now),
      (DateTime(2026, 8, 24), DateTime(2026, 8, 30)),
    );
    expect(
      usageHistoryBounds(const DateRangeSelection(DateRange.month), now: now),
      (DateTime(2026, 8), DateTime(2026, 8, 30)),
    );
    expect(
      usageHistoryBounds(
        DateRangeSelection(DateRange.custom, day: DateTime(2026, 7, 9)),
        now: now,
      ),
      (DateTime(2026, 7, 9), DateTime(2026, 7, 9)),
    );
  });

  testWidgets(
    'history is lazy, internally scrollable and discloses long names',
    (tester) async {
      final entries = List.generate(
        30,
        (index) => UsageHistoryEntry(
          appName: index == 0 ? 'TFTTencentClient-Win64-Shipping' : '应用 $index',
          date: DateTime(2026, 8, 30),
          start: DateTime(2026, 8, 30, 9, index),
          end: DateTime(2026, 8, 30, 9, index, 7),
          activeSeconds: 7,
          sourceCount: 1,
          timeKnown: true,
          sourceIndex: index,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: TimetraceTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 620,
              height: 300,
              child: UsageHistoryList(entries: entries, showDate: false),
            ),
          ),
        ),
      );

      final list = find.byKey(const ValueKey('dashboard-usage-history-list'));
      expect(list, findsOneWidget);
      expect(tester.getSize(list).height, 300);
      expect(find.text('09:00:00–09:00:07'), findsOneWidget);
      expect(find.text('7s'), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              widget.message == 'TFTTencentClient-Win64-Shipping',
        ),
        findsOneWidget,
      );
      expect(find.text('应用 29'), findsNothing);

      await tester.scrollUntilVisible(
        find.text('应用 29'),
        240,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.text('应用 29'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

DaySessionDto _session(
  String appName,
  String startedAt,
  int duration, {
  bool idle = false,
}) => DaySessionDto(
  appName: appName,
  isIdle: idle,
  durationSecs: duration,
  startedAt: startedAt,
);
