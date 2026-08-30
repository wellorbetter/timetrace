import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/application/local_recap_engine.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_settings_store.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

class RecapAiSettingsNotifier extends AsyncNotifier<RecapAiSettings> {
  final RecapAiSettingsStore _store = const RecapAiSettingsStore();

  @override
  Future<RecapAiSettings> build() => _store.load();

  void preview(RecapAiSettings value) => state = AsyncData(value);

  Future<void> save(RecapAiSettings value) async {
    state = AsyncData(value);
    await _store.save(value);
    ref.invalidate(recapProvider);
  }
}

final recapAiSettingsProvider =
    AsyncNotifierProvider<RecapAiSettingsNotifier, RecapAiSettings>(
      RecapAiSettingsNotifier.new,
    );

class RecapState {
  const RecapState({
    required this.result,
    required this.generatedAt,
    this.aiError,
  });

  final RecapResult result;
  final DateTime generatedAt;
  final String? aiError;
}

class RecapNotifier extends AsyncNotifier<RecapState> {
  static const _local = LocalRecapEngine();
  static const _ai = RecapAiClient();

  @override
  Future<RecapState> build() async {
    final selection = ref.watch(dashboardRangeProvider);
    final settings =
        ref.watch(recapAiSettingsProvider).value ?? const RecapAiSettings();
    return _load(selection, settings);
  }

  Future<void> refresh() async {
    final selection = ref.read(dashboardRangeProvider);
    final settings =
        ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => _load(selection, settings));
  }

  Future<RecapState> _load(
    DateRangeSelection selection,
    RecapAiSettings settings,
  ) async {
    final api = ref.read(apiProvider);
    final bounds = _rangeBounds(selection);
    final previous = _previousBounds(bounds.$1, bounds.$2);
    final snapshot = _buildSnapshot(
      api: api,
      label: _label(selection),
      start: bounds.$1,
      end: bounds.$2,
      previousStart: previous.$1,
      previousEnd: previous.$2,
    );
    final local = _local.generate(snapshot);
    if (!settings.enabled) {
      return RecapState(result: local, generatedAt: DateTime.now());
    }
    final attempt = await _ai.enhance(local: local, settings: settings);
    return RecapState(
      result: attempt.result,
      generatedAt: DateTime.now(),
      aiError: attempt.error,
    );
  }

  RecapSnapshot _buildSnapshot({
    required TimeTraceApi api,
    required String label,
    required DateTime start,
    required DateTime end,
    required DateTime previousStart,
    required DateTime previousEnd,
  }) {
    final startText = _date(start);
    final endText = _date(end);
    final stats = api.getStats(start: startText, end: endText);
    final previousStats = api.getStats(
      start: _date(previousStart),
      end: _date(previousEnd),
    );
    final apps = api.getUsageSplit(start: startText, end: endText).toList()
      ..sort(
        (a, b) =>
            b.activeSeconds.toInt().compareTo(a.activeSeconds.toInt()),
      );
    final topApps = apps
        .where((app) => app.activeSeconds.toInt() > 0)
        .take(5)
        .map(
          (app) => RecapAppFact(
            name: app.appName,
            activeSeconds: app.activeSeconds.toInt(),
            idleSeconds: app.idleSeconds.toInt(),
          ),
        )
        .toList(growable: false);

    final diary = api
        .getDiaryEntriesDetailed(start: startText, end: endText)
        .where(
          (entry) =>
              entry.status == 'published' && entry.content.trim().isNotEmpty,
        )
        .take(8)
        .map((entry) => _truncate(entry.content.trim(), 600))
        .toList(growable: false);

    final dayCount = end.difference(start).inDays + 1;
    var sessionCount = 0;
    var contextSwitches = 0;
    var longestStreak = 0;
    int? peakHour;
    var peakHourSeconds = 0;

    // Full behavior metrics for a day/week. A month intentionally stays on
    // range-level aggregate calls until Rust exposes a batched recap query.
    if (dayCount <= 7) {
      final hourly = List<int>.filled(24, 0);
      for (var offset = 0; offset < dayCount; offset++) {
        final day = start.add(Duration(days: offset));
        final dayText = _date(day);
        final detail = api.getDayDetail(date: dayText);
        final metrics = _sessionMetrics(detail.sessions);
        sessionCount += metrics.$1;
        contextSwitches += metrics.$2;
        if (metrics.$3 > longestStreak) longestStreak = metrics.$3;

        final buckets = api.getDayHourly(date: dayText);
        for (var hour = 0; hour < 24 && hour < buckets.length; hour++) {
          hourly[hour] += buckets[hour].toInt();
        }
      }
      for (var hour = 0; hour < hourly.length; hour++) {
        if (hourly[hour] > peakHourSeconds) {
          peakHourSeconds = hourly[hour];
          peakHour = hour;
        }
      }
    }

    return RecapSnapshot(
      label: label,
      start: start,
      end: end,
      activeSeconds: stats.activeSeconds.toInt(),
      idleSeconds: stats.idleSeconds.toInt(),
      previousActiveSeconds: previousStats.activeSeconds.toInt(),
      topApps: topApps,
      sessionCount: sessionCount,
      contextSwitches: contextSwitches,
      longestActiveStreakSeconds: longestStreak,
      peakHour: peakHour,
      peakHourActiveSeconds: peakHourSeconds,
      diaryEntries: diary,
    );
  }
}

// Keep the latest recap alive across Overview ↔ Recap navigation so the same
// range does not trigger a second paid model request merely because a route
// changed. Range/settings changes still rebuild it, and Refresh forces a new run.
final recapProvider = AsyncNotifierProvider<RecapNotifier, RecapState>(
  RecapNotifier.new,
);

(int, int, int) _sessionMetrics(List<DaySessionDto> sessions) {
  var activeSessions = 0;
  var switches = 0;
  var currentStreak = 0;
  var longestStreak = 0;
  String? previousApp;

  for (final session in sessions) {
    final duration = session.durationSecs.toInt().clamp(0, 24 * 3600).toInt();
    if (session.isIdle) {
      if (currentStreak > longestStreak) longestStreak = currentStreak;
      currentStreak = 0;
      previousApp = null;
      continue;
    }
    activeSessions++;
    currentStreak += duration;
    if (previousApp != null && previousApp != session.appName) switches++;
    previousApp = session.appName;
  }
  if (currentStreak > longestStreak) longestStreak = currentStreak;
  return (activeSessions, switches, longestStreak);
}

(DateTime, DateTime) _rangeBounds(DateRangeSelection selection) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (selection.range) {
    case DateRange.today:
      return (today, today);
    case DateRange.yesterday:
      final yesterday = today.subtract(const Duration(days: 1));
      return (yesterday, yesterday);
    case DateRange.custom:
      final value = selection.day ?? today;
      final day = DateTime(value.year, value.month, value.day);
      return (day, day);
    case DateRange.week:
      return (today.subtract(Duration(days: today.weekday - 1)), today);
    case DateRange.month:
      return (DateTime(today.year, today.month), today);
  }
}

(DateTime, DateTime) _previousBounds(DateTime start, DateTime end) {
  final days = end.difference(start).inDays + 1;
  final previousEnd = start.subtract(const Duration(days: 1));
  return (previousEnd.subtract(Duration(days: days - 1)), previousEnd);
}

String _label(DateRangeSelection selection) => switch (selection.range) {
  DateRange.today => '今天',
  DateRange.yesterday => '昨天',
  DateRange.week => '本周',
  DateRange.month => '本月',
  DateRange.custom => '所选日期',
};

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _truncate(String value, int maxChars) =>
    value.length <= maxChars ? value : '${value.substring(0, maxChars)}…';
