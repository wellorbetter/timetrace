import 'package:flutter/foundation.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// A user-selected report period. Resolving it is deterministic and local;
/// changing the period never performs network I/O.
@immutable
class AiReportPeriod {
  AiReportPeriod({
    required this.scope,
    required DateTime anchor,
    required DateTime today,
  }) : anchor = _date(anchor),
       today = _date(today);

  factory AiReportPeriod.current(AiRecapScope scope, {DateTime? now}) {
    final today = _date(now ?? DateTime.now());
    return AiReportPeriod(scope: scope, anchor: today, today: today);
  }

  final AiRecapScope scope;
  final DateTime anchor;
  final DateTime today;

  AiRecapRangeKey get range => _resolve(scope, anchor, today);

  bool get canGoNext {
    final next = _shiftAnchor(scope, anchor, 1);
    return !next.isAfter(today);
  }

  AiReportPeriod previous() => AiReportPeriod(
    scope: scope,
    anchor: _shiftAnchor(scope, anchor, -1),
    today: today,
  );

  AiReportPeriod next() => canGoNext
      ? AiReportPeriod(
          scope: scope,
          anchor: _shiftAnchor(scope, anchor, 1),
          today: today,
        )
      : this;

  AiReportPeriod select(AiRecapScope value) =>
      AiReportPeriod(scope: value, anchor: today, today: today);

  /// Keeps the selected period while advancing the local calendar boundary.
  AiReportPeriod withToday(DateTime value) =>
      AiReportPeriod(scope: scope, anchor: anchor, today: value);

  bool get isCurrent {
    final current = AiReportPeriod.current(scope, now: today).range;
    return range == current;
  }

  String get label {
    final value = range;
    final suffix =
        isCurrent && value.endDate == today && scope != AiRecapScope.daily
        ? '（截至今天）'
        : '';
    return switch (scope) {
      AiRecapScope.daily => _formatDate(value.startDate),
      AiRecapScope.weekly || AiRecapScope.monthly =>
        '${_formatDate(value.startDate)}—${_formatDate(value.endDate)}$suffix',
      AiRecapScope.unsupported => '不支持的周期',
    };
  }
}

AiRecapRangeKey _resolve(AiRecapScope scope, DateTime anchor, DateTime today) {
  if (anchor.isAfter(today)) anchor = today;
  return switch (scope) {
    AiRecapScope.daily => AiRecapRangeKey(
      scope: scope,
      startDate: anchor,
      endDate: anchor,
    ),
    AiRecapScope.weekly => _weekly(anchor, today),
    AiRecapScope.monthly => _monthly(anchor, today),
    AiRecapScope.unsupported => AiRecapRangeKey(
      scope: scope,
      startDate: anchor,
      endDate: anchor,
    ),
  };
}

AiRecapRangeKey _weekly(DateTime anchor, DateTime today) {
  final start = DateTime(
    anchor.year,
    anchor.month,
    anchor.day - (anchor.weekday - DateTime.monday),
  );
  final naturalEnd = DateTime(start.year, start.month, start.day + 6);
  return AiRecapRangeKey(
    scope: AiRecapScope.weekly,
    startDate: start,
    endDate: naturalEnd.isAfter(today) ? today : naturalEnd,
  );
}

AiRecapRangeKey _monthly(DateTime anchor, DateTime today) {
  final start = DateTime(anchor.year, anchor.month);
  final naturalEnd = DateTime(anchor.year, anchor.month + 1, 0);
  return AiRecapRangeKey(
    scope: AiRecapScope.monthly,
    startDate: start,
    endDate: naturalEnd.isAfter(today) ? today : naturalEnd,
  );
}

DateTime _shiftAnchor(AiRecapScope scope, DateTime anchor, int amount) =>
    switch (scope) {
      AiRecapScope.daily => DateTime(
        anchor.year,
        anchor.month,
        anchor.day + amount,
      ),
      AiRecapScope.weekly => DateTime(
        anchor.year,
        anchor.month,
        anchor.day + amount * 7,
      ),
      AiRecapScope.monthly => DateTime(anchor.year, anchor.month + amount, 1),
      AiRecapScope.unsupported => anchor,
    };

DateTime _date(DateTime value) => DateTime(value.year, value.month, value.day);

String _formatDate(DateTime value) =>
    '${value.year}年${value.month}月${value.day}日';
