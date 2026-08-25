import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';

void main() {
  group('resolveDateRange', () {
    test('today resolves one local calendar day and supports AI recap', () {
      final bounds = resolveDateRange(
        const DateRangeSelection(DateRange.today),
        DateTime(2026, 8, 24, 18, 30),
      );

      expect(
        bounds,
        const DateRangeBounds(
          start: '2026-08-24',
          end: '2026-08-24',
          label: '今日',
          supportedByAiRecap: true,
        ),
      );
    });

    test('week starts on Monday and ends on the supplied day', () {
      final bounds = resolveDateRange(
        const DateRangeSelection(DateRange.week),
        DateTime(2026, 8, 27, 9),
      );

      expect(bounds.start, '2026-08-24');
      expect(bounds.end, '2026-08-27');
      expect(bounds.label, '本周（截至今日）');
      expect(bounds.supportedByAiRecap, isTrue);
    });

    test('yesterday, month, and custom are stable report ranges', () {
      final now = DateTime(2026, 3, 1, 12);
      final cases = <(DateRangeSelection, String, String, String)>[
        (
          const DateRangeSelection(DateRange.yesterday),
          '2026-02-28',
          '2026-02-28',
          '昨日',
        ),
        (
          const DateRangeSelection(DateRange.month),
          '2026-03-01',
          '2026-03-01',
          '本月',
        ),
        (
          DateRangeSelection(DateRange.custom, day: DateTime(2024, 2, 29)),
          '2024-02-29',
          '2024-02-29',
          '所选日期',
        ),
      ];

      for (final (selection, expectedStart, expectedEnd, expectedLabel)
          in cases) {
        final bounds = resolveDateRange(selection, now);

        expect(bounds.start, expectedStart);
        expect(bounds.end, expectedEnd);
        expect(bounds.label, expectedLabel);
        expect(bounds.supportedByAiRecap, isTrue);
      }
    });

    test('one supplied instant keeps boundaries coherent across midnight', () {
      const selection = DateRangeSelection(DateRange.week);

      final beforeMidnight = resolveDateRange(
        selection,
        DateTime(2026, 8, 23, 23, 59, 59, 999),
      );
      final afterMidnight = resolveDateRange(selection, DateTime(2026, 8, 24));

      expect(beforeMidnight.start, '2026-08-17');
      expect(beforeMidnight.end, '2026-08-23');
      expect(afterMidnight.start, '2026-08-24');
      expect(afterMidnight.end, '2026-08-24');
    });

    test('a future calendar day cannot generate a linked report', () {
      final bounds = resolveDateRange(
        DateRangeSelection(DateRange.custom, day: DateTime(2026, 8, 27)),
        DateTime(2026, 8, 26, 9),
      );

      expect(bounds.start, '2026-08-27');
      expect(bounds.end, '2026-08-27');
      expect(bounds.supportedByAiRecap, isFalse);
    });
  });
}
