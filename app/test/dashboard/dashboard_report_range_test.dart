import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/dashboard/domain/date_range_selection.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';

void main() {
  final now = DateTime(2026, 8, 26, 9);

  test('top dashboard ranges map to one exact report key', () {
    final cases = <(DateRangeSelection, AiRecapScope)>[
      (const DateRangeSelection(DateRange.today), AiRecapScope.daily),
      (const DateRangeSelection(DateRange.yesterday), AiRecapScope.daily),
      (const DateRangeSelection(DateRange.week), AiRecapScope.weekly),
      (const DateRangeSelection(DateRange.month), AiRecapScope.monthly),
      (
        DateRangeSelection(DateRange.custom, day: DateTime(2026, 8, 20)),
        AiRecapScope.daily,
      ),
    ];

    for (final (selection, expectedScope) in cases) {
      final bounds = resolveDateRange(selection, now);
      final key = dashboardReportRangeKey(selection, bounds);

      expect(key.scope, expectedScope);
      expect(key.isValid, isTrue);
      expect(_iso(key.startDate), bounds.start);
      expect(_iso(key.endDate), bounds.end);
    }
  });

  test('future calendar selection maps to a disabled report key', () {
    final selection = DateRangeSelection(
      DateRange.custom,
      day: DateTime(2026, 8, 27),
    );
    final key = dashboardReportRangeKey(
      selection,
      resolveDateRange(selection, now),
    );

    expect(key.scope, AiRecapScope.unsupported);
    expect(key.isValid, isFalse);
  });
}

String _iso(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
