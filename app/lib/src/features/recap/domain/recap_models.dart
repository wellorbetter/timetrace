import 'dart:convert';

class RecapAppFact {
  const RecapAppFact({required this.name, required this.activeSeconds, required this.idleSeconds});
  final String name;
  final int activeSeconds;
  final int idleSeconds;
  Map<String, Object> toJson() => {'name': name, 'active_seconds': activeSeconds, 'idle_seconds': idleSeconds};
}

class RecapSnapshot {
  const RecapSnapshot({required this.label, required this.start, required this.end, required this.activeSeconds, required this.idleSeconds, required this.previousActiveSeconds, required this.topApps, required this.sessionCount, required this.contextSwitches, required this.longestActiveStreakSeconds, required this.peakHour, required this.peakHourActiveSeconds, required this.diaryEntries});
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
  int get totalObservedSeconds => activeSeconds + idleSeconds;
  double get focusRatio => totalObservedSeconds <= 0 ? 0 : activeSeconds / totalObservedSeconds;
  double? get activeChangeRatio => previousActiveSeconds <= 0 ? null : (activeSeconds - previousActiveSeconds) / previousActiveSeconds;
  int get topAppSeconds => topApps.isEmpty ? 0 : topApps.first.activeSeconds;
  double get topAppShare => activeSeconds <= 0 ? 0 : topAppSeconds / activeSeconds;
  Map<String, Object?> toJson({bool includeDiaryEntries = true}) => {
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
    'diary_entry_count': diaryEntries.length,
    if (includeDiaryEntries) 'diary_entries': diaryEntries,
  };
  String toPrettyJson({bool includeDiaryEntries = true}) => const JsonEncoder.withIndent('  ').convert(toJson(includeDiaryEntries: includeDiaryEntries));
  static String _date(DateTime value) => '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
}

enum RecapOrigin { local, ai }

class RecapResult {
  const RecapResult({required this.headline, required this.summary, required this.insights, required this.recommendations, required this.snapshot, required this.origin, this.model});
  final String headline;
  final String summary;
  final List<String> insights;
  final List<String> recommendations;
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
