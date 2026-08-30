import 'dart:convert';

class RecapAppFact {
  const RecapAppFact({
    required this.name,
    required this.activeSeconds,
    required this.idleSeconds,
  });

  final String name;
  final int activeSeconds;
  final int idleSeconds;

  Map<String, Object> toJson() => {
    'name': name,
    'active_seconds': activeSeconds,
    'idle_seconds': idleSeconds,
  };
}

class RecapActivityFact {
  const RecapActivityFact({
    required this.date,
    required this.startedAt,
    required this.appName,
    required this.durationSeconds,
  });

  final DateTime date;
  final String startedAt;
  final String appName;
  final int durationSeconds;

  Map<String, Object> toJson() => {
    'date': RecapSnapshot._date(date),
    'started_at': startedAt,
    'app_name': appName,
    'duration_seconds': durationSeconds,
  };
}

class RecapSnapshot {
  const RecapSnapshot({
    required this.label,
    required this.start,
    required this.end,
    required this.activeSeconds,
    required this.idleSeconds,
    required this.previousActiveSeconds,
    required this.topApps,
    required this.sessionCount,
    required this.contextSwitches,
    required this.longestActiveStreakSeconds,
    required this.peakHour,
    required this.peakHourActiveSeconds,
    required this.diaryEntries,
    this.activityFacts = const [],
  });

  final String label;
  final DateTime start;
  final DateTime end;
  final int activeSeconds;
  final int idleSeconds;
  final int previousActiveSeconds;
  final List<RecapAppFact> topApps;
  final int sessionCount;
  final int contextSwitches;
  final int longestActiveStreakSeconds;
  final int? peakHour;
  final int peakHourActiveSeconds;
  final List<String> diaryEntries;
  final List<RecapActivityFact> activityFacts;

  int get totalObservedSeconds => activeSeconds + idleSeconds;

  double get focusRatio =>
      totalObservedSeconds <= 0 ? 0 : activeSeconds / totalObservedSeconds;

  double? get activeChangeRatio {
    if (previousActiveSeconds <= 0) return null;
    return (activeSeconds - previousActiveSeconds) / previousActiveSeconds;
  }

  int get topAppSeconds => topApps.isEmpty ? 0 : topApps.first.activeSeconds;

  double get topAppShare =>
      activeSeconds <= 0 ? 0 : topAppSeconds / activeSeconds;

  Map<String, Object?> toJson({bool includeDiaryEntries = true}) {
    const maxTimelineFacts = 24;
    final timelineStart = activityFacts.length > maxTimelineFacts
        ? activityFacts.length - maxTimelineFacts
        : 0;
    final timelineSample = activityFacts.skip(timelineStart);

    return {
      'range': {'label': label, 'start': _date(start), 'end': _date(end)},
      'active_seconds': activeSeconds,
      'idle_seconds': idleSeconds,
      'focus_ratio': focusRatio,
      'previous_active_seconds': previousActiveSeconds,
      'active_change_ratio': activeChangeRatio,
      'session_count': sessionCount,
      'context_switches': contextSwitches,
      'longest_active_streak_seconds': longestActiveStreakSeconds,
      'peak_hour': peakHour,
      'peak_hour_active_seconds': peakHourActiveSeconds,
      'top_apps': topApps.map((e) => e.toJson()).toList(),
      'usage_history_count': activityFacts.length,
      'usage_history': timelineSample.map((e) => e.toJson()).toList(),
      'usage_history_truncated': activityFacts.length > maxTimelineFacts,
      'diary_entry_count': diaryEntries.length,
      if (includeDiaryEntries) 'diary_entries': diaryEntries,
    };
  }

  String toPrettyJson({bool includeDiaryEntries = true}) =>
      const JsonEncoder.withIndent(
        '  ',
      ).convert(toJson(includeDiaryEntries: includeDiaryEntries));

  static String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

enum RecapOrigin { local, ai }

class RecapResult {
  const RecapResult({
    required this.headline,
    required this.summary,
    required this.insights,
    required this.snapshot,
    required this.origin,
    this.model,
  });

  final String headline;
  final String summary;
  final List<String> insights;
  final RecapSnapshot snapshot;
  final RecapOrigin origin;
  final String? model;

  bool get isAiEnhanced => origin == RecapOrigin.ai;
}

String formatRecapDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  if (hours == 0) return '${minutes}m';
  if (minutes == 0) return '${hours}h';
  return '${hours}h ${minutes}m';
}
