import 'package:flutter/foundation.dart';

/// Date ranges available on the dashboard.
enum DateRange { today, yesterday, week, month, custom }

/// Selected range plus an optional concrete day (used for [DateRange.custom]).
@immutable
class DateRangeSelection {
  const DateRangeSelection(this.range, {this.day});

  final DateRange range;

  /// Concrete calendar day; non-null when [range] is [DateRange.custom].
  final DateTime? day;

  /// The single day all day-level views (hourly/summary/diary) should show.
  DateTime effectiveDayAt(DateTime now) {
    switch (range) {
      case DateRange.today:
        return now;
      case DateRange.yesterday:
        return DateTime(now.year, now.month, now.day - 1);
      case DateRange.custom:
        return day ?? now;
      case DateRange.week:
      case DateRange.month:
        return now;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DateRangeSelection && range == other.range && day == other.day;

  @override
  int get hashCode => Object.hash(range, day);
}

/// Resolved local-calendar boundaries shared by dashboard and AI recap.
@immutable
class DateRangeBounds {
  const DateRangeBounds({
    required this.start,
    required this.end,
    required this.label,
    required this.supportedByAiRecap,
  });

  final String start;
  final String end;
  final String label;
  final bool supportedByAiRecap;

  /// End calendar day used by day-level dashboard queries.
  DateTime get endDate {
    final parts = end.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// Stable key for range-scoped local caches.
  String get cacheKey => '$start|$end';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DateRangeBounds &&
          start == other.start &&
          end == other.end &&
          label == other.label &&
          supportedByAiRecap == other.supportedByAiRecap;

  @override
  int get hashCode => Object.hash(start, end, label, supportedByAiRecap);

  @override
  String toString() =>
      'DateRangeBounds(start: $start, end: $end, label: $label, '
      'supportedByAiRecap: $supportedByAiRecap)';
}

/// Resolves [selection] against one caller-captured local [now].
///
/// Keeping time outside this pure function prevents a single operation from
/// mixing two dates if the clock crosses midnight while bounds are calculated.
DateRangeBounds resolveDateRange(DateRangeSelection selection, DateTime now) {
  final today = _formatCalendarDate(now);

  switch (selection.range) {
    case DateRange.today:
      return DateRangeBounds(
        start: today,
        end: today,
        label: '今日',
        supportedByAiRecap: true,
      );
    case DateRange.yesterday:
      final yesterday = _formatCalendarDate(
        DateTime(now.year, now.month, now.day - 1),
      );
      return DateRangeBounds(
        start: yesterday,
        end: yesterday,
        label: '昨日',
        supportedByAiRecap: false,
      );
    case DateRange.week:
      final monday = DateTime(now.year, now.month, now.day - now.weekday + 1);
      return DateRangeBounds(
        start: _formatCalendarDate(monday),
        end: today,
        label: '本周（截至今日）',
        supportedByAiRecap: true,
      );
    case DateRange.month:
      return DateRangeBounds(
        start: _formatCalendarDate(DateTime(now.year, now.month)),
        end: today,
        label: '本月',
        supportedByAiRecap: false,
      );
    case DateRange.custom:
      final selectedDay = _formatCalendarDate(selection.day ?? now);
      return DateRangeBounds(
        start: selectedDay,
        end: selectedDay,
        label: '所选日期',
        supportedByAiRecap: false,
      );
  }
}

String _formatCalendarDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';
