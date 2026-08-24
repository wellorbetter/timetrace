import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_report_period.dart';

void main() {
  final today = DateTime(2026, 8, 24); // Monday

  test(
    'current daily, weekly and monthly periods are exact and independent',
    () {
      final daily = AiReportPeriod.current(AiRecapScope.daily, now: today);
      final weekly = AiReportPeriod.current(AiRecapScope.weekly, now: today);
      final monthly = AiReportPeriod.current(AiRecapScope.monthly, now: today);

      expect(daily.range.startDate, DateTime(2026, 8, 24));
      expect(daily.range.endDate, DateTime(2026, 8, 24));
      expect(weekly.range.startDate, DateTime(2026, 8, 24));
      expect(weekly.range.endDate, DateTime(2026, 8, 24));
      expect(monthly.range.startDate, DateTime(2026, 8, 1));
      expect(monthly.range.endDate, DateTime(2026, 8, 24));
      expect(daily.range, isNot(weekly.range));
      expect(weekly.label, contains('截至今天'));
      expect(monthly.label, contains('截至今天'));
    },
  );

  test(
    'previous weekly and monthly periods resolve to complete natural periods',
    () {
      final weekly = AiReportPeriod.current(
        AiRecapScope.weekly,
        now: today,
      ).previous();
      final monthly = AiReportPeriod.current(
        AiRecapScope.monthly,
        now: today,
      ).previous();

      expect(weekly.range.startDate, DateTime(2026, 8, 17));
      expect(weekly.range.endDate, DateTime(2026, 8, 23));
      expect(weekly.label, isNot(contains('截至今天')));
      expect(monthly.range.startDate, DateTime(2026, 7, 1));
      expect(monthly.range.endDate, DateTime(2026, 7, 31));
      expect(monthly.label, isNot(contains('截至今天')));
    },
  );

  test('future periods are unavailable', () {
    for (final scope in AiRecapScope.values.where(
      (value) => value.isSupported,
    )) {
      final current = AiReportPeriod.current(scope, now: today);
      expect(current.canGoNext, isFalse);
      expect(current.next().range, current.range);
    }
  });

  test('daily navigation and scope changes reset to the current period', () {
    final previousDay = AiReportPeriod.current(
      AiRecapScope.daily,
      now: today,
    ).previous();
    expect(previousDay.range.startDate, DateTime(2026, 8, 23));
    expect(previousDay.canGoNext, isTrue);
    expect(previousDay.next().range.startDate, today);

    final reset = previousDay.select(AiRecapScope.monthly);
    expect(reset.range.startDate, DateTime(2026, 8, 1));
    expect(reset.range.endDate, today);
  });

  test(
    'period navigation is calendar-safe across month and year boundaries',
    () {
      final january = AiReportPeriod.current(
        AiRecapScope.monthly,
        now: DateTime(2026, 1, 2),
      ).previous();
      expect(january.range.startDate, DateTime(2025, 12, 1));
      expect(january.range.endDate, DateTime(2025, 12, 31));

      final monday = AiReportPeriod.current(
        AiRecapScope.weekly,
        now: DateTime(2026, 3, 1),
      );
      expect(monday.range.startDate.weekday, DateTime.monday);
      expect(monday.range.isValid, isTrue);
    },
  );
}
