import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

@immutable
class UsageHistoryEntry {
  const UsageHistoryEntry({
    required this.appName,
    required this.date,
    required this.start,
    required this.end,
    required this.activeSeconds,
    required this.sourceCount,
    required this.timeKnown,
    required this.sourceIndex,
  });

  final String appName;
  final DateTime date;
  final DateTime start;
  final DateTime end;
  final int activeSeconds;
  final int sourceCount;
  final bool timeKnown;
  final int sourceIndex;

  UsageHistoryEntry copyWith({
    DateTime? end,
    int? activeSeconds,
    int? sourceCount,
  }) => UsageHistoryEntry(
    appName: appName,
    date: date,
    start: start,
    end: end ?? this.end,
    activeSeconds: activeSeconds ?? this.activeSeconds,
    sourceCount: sourceCount ?? this.sourceCount,
    timeKnown: timeKnown,
    sourceIndex: sourceIndex,
  );
}

/// Detailed history follows the same range selection as every other Overview
/// page. The provider is instantiated lazily when the history carousel page is
/// built, so the extra day-detail calls do not delay the initial dashboard.
final dashboardUsageHistoryProvider =
    FutureProvider.autoDispose<List<UsageHistoryEntry>>((ref) async {
      final selection = ref.watch(dashboardRangeProvider);
      final api = ref.read(apiProvider);
      final (start, end) = usageHistoryBounds(selection);

      // Yield one frame before the synchronous local-DB bridge calls. This
      // lets the carousel paint its loading state immediately.
      await Future<void>.delayed(Duration.zero);

      final raw = <_RawHistoryEntry>[];
      var sourceIndex = 0;
      for (
        var day = start;
        !day.isAfter(end);
        day = day.add(const Duration(days: 1))
      ) {
        final detail = api.getDayDetail(date: _formatDate(day));
        for (final session in detail.sessions) {
          raw.add(
            _RawHistoryEntry(
              date: day,
              session: session,
              sourceIndex: sourceIndex++,
            ),
          );
        }
      }
      return _compactUsageHistory(raw);
    });

@visibleForTesting
(DateTime, DateTime) usageHistoryBounds(
  DateRangeSelection selection, {
  DateTime? now,
}) {
  final today = _dateOnly(now ?? DateTime.now());
  switch (selection.range) {
    case DateRange.today:
      return (today, today);
    case DateRange.yesterday:
      final yesterday = today.subtract(const Duration(days: 1));
      return (yesterday, yesterday);
    case DateRange.custom:
      final selected = _dateOnly(selection.day ?? today);
      return (selected, selected);
    case DateRange.week:
      return (today.subtract(Duration(days: today.weekday - 1)), today);
    case DateRange.month:
      return (DateTime(today.year, today.month), today);
  }
}

@immutable
class _RawHistoryEntry {
  const _RawHistoryEntry({
    required this.date,
    required this.session,
    required this.sourceIndex,
  });

  final DateTime date;
  final DaySessionDto session;
  final int sourceIndex;
}

/// Turns raw monitor fragments into a readable history while preserving every
/// positive active second. Non-overlapping fragments from the same app and
/// local date are merged if the recorded gap is at most 90 seconds; exact
/// duplicate rows are discarded.
@visibleForTesting
List<UsageHistoryEntry> compactUsageHistory(
  Iterable<({DateTime date, DaySessionDto session})> sessions,
) {
  var sourceIndex = 0;
  return _compactUsageHistory([
    for (final item in sessions)
      _RawHistoryEntry(
        date: item.date,
        session: item.session,
        sourceIndex: sourceIndex++,
      ),
  ]);
}

List<UsageHistoryEntry> _compactUsageHistory(
  Iterable<_RawHistoryEntry> sessions,
) {
  final parsed = <UsageHistoryEntry>[];
  final exactRows = <String>{};

  for (final item in sessions) {
    final session = item.session;
    final appName = session.appName.trim();
    final activeSeconds = session.durationSecs.toInt();
    if (session.isIdle || appName.isEmpty || activeSeconds <= 0) continue;

    final start = _parseStartedAt(item.date, session.startedAt);
    final duplicateKey =
        '${_formatDate(item.date)}|$appName|${session.startedAt}|$activeSeconds';
    if (!exactRows.add(duplicateKey)) continue;

    final fallbackStart = _dateOnly(
      item.date,
    ).add(Duration(microseconds: item.sourceIndex));
    final effectiveStart = start ?? fallbackStart;
    parsed.add(
      UsageHistoryEntry(
        appName: appName,
        date: _dateOnly(effectiveStart),
        start: effectiveStart,
        end: effectiveStart.add(Duration(seconds: activeSeconds)),
        activeSeconds: activeSeconds,
        sourceCount: 1,
        timeKnown: start != null,
        sourceIndex: item.sourceIndex,
      ),
    );
  }

  parsed.sort((left, right) {
    final byDate = left.date.compareTo(right.date);
    if (byDate != 0) return byDate;
    if (left.timeKnown != right.timeKnown) return left.timeKnown ? -1 : 1;
    final byStart = left.start.compareTo(right.start);
    return byStart != 0
        ? byStart
        : left.sourceIndex.compareTo(right.sourceIndex);
  });

  final compacted = <UsageHistoryEntry>[];
  for (final next in parsed) {
    if (compacted.isNotEmpty) {
      final current = compacted.last;
      final gap = next.start.difference(current.end).inSeconds;
      if (_isSameDate(current.date, next.date) &&
          current.timeKnown &&
          next.timeKnown &&
          current.appName == next.appName &&
          gap >= 0 &&
          gap <= 90) {
        compacted[compacted.length - 1] = current.copyWith(
          end: next.end.isAfter(current.end) ? next.end : current.end,
          activeSeconds: current.activeSeconds + next.activeSeconds,
          sourceCount: current.sourceCount + 1,
        );
        continue;
      }
    }
    compacted.add(next);
  }

  // Diary entries are shown newest-first; history follows the same scanning
  // direction. Keep rows without a trustworthy clock value after known-time
  // rows for that day rather than presenting a synthetic fallback as "latest".
  compacted.sort((left, right) {
    final byDate = right.date.compareTo(left.date);
    if (byDate != 0) return byDate;
    if (left.timeKnown != right.timeKnown) return left.timeKnown ? -1 : 1;
    final byStart = right.start.compareTo(left.start);
    return byStart != 0
        ? byStart
        : right.sourceIndex.compareTo(left.sourceIndex);
  });

  return List<UsageHistoryEntry>.unmodifiable(compacted);
}

DateTime? _parseStartedAt(DateTime date, String value) {
  final raw = value.trim();
  if (raw.isEmpty) return null;

  final iso = DateTime.tryParse(raw);
  if (iso != null && (raw.contains('-') || raw.contains('T'))) {
    return iso.toLocal();
  }

  final match = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2}))?').firstMatch(raw);
  if (match == null) return null;
  final hour = int.tryParse(match.group(1)!);
  final minute = int.tryParse(match.group(2)!);
  final second = int.tryParse(match.group(3) ?? '0');
  if (hour == null ||
      minute == null ||
      second == null ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  return DateTime(date.year, date.month, date.day, hour, minute, second);
}

String _formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool _isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
