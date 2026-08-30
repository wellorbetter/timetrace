import 'dart:async';

import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';

/// Serializes the complete duplicate-check -> generate -> publish transaction
/// per local date. Manual and scheduled entry points must share one instance.
class AiDiaryGenerationCoordinator {
  AiDiaryGenerationCoordinator({this.service = const AiDiaryService()});

  final AiDiaryService service;
  final Map<String, Future<void>> _dateTails = {};

  Future<AiDiaryGenerationOutcome> generateAndPublish({
    required TimeTraceApi api,
    required DateTime date,
    required RecapAiSettings settings,
    bool allowDuplicate = false,
  }) {
    final day = DateTime(date.year, date.month, date.day);
    return runForDate(day, () {
      // The entire service call intentionally lives inside the lock. A waiter
      // therefore performs duplicate detection again after the preceding
      // publication has completed instead of relying on stale preflight data.
      return service.generateAndPublish(
        api: api,
        date: day,
        settings: settings,
        allowDuplicate: allowDuplicate,
      );
    });
  }

  /// Runs any generation lifecycle work exclusively for a local date.
  /// Provider state changes can be placed inside this boundary as well as the
  /// duplicate-check/generate/publish service operation.
  Future<T> runForDate<T>(DateTime date, Future<T> Function() operation) async {
    final day = DateTime(date.year, date.month, date.day);
    final key = _date(day);
    final previous = _dateTails[key] ?? Future<void>.value();
    final turn = Completer<void>();
    final tail = turn.future;
    _dateTails[key] = tail;

    try {
      try {
        await previous;
      } catch (_) {
        // A failed predecessor must not permanently poison this date's queue.
      }
      return await operation();
    } finally {
      if (!turn.isCompleted) turn.complete();
      if (identical(_dateTails[key], tail)) _dateTails.remove(key);
    }
  }
}

class AiDiaryService {
  const AiDiaryService({this.client = const RecapAiClient()});

  final AiDiaryClient client;

  /// Generates and atomically publishes one AI diary for [date].
  ///
  /// Duplicate detection happens before the model request. Every non-success
  /// outcome guarantees that this method did not publish a fallback entry.
  Future<AiDiaryGenerationOutcome> generateAndPublish({
    required TimeTraceApi api,
    required DateTime date,
    required RecapAiSettings settings,
    bool allowDuplicate = false,
  }) async {
    if (!settings.enabled) {
      return const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.disabled,
        message: '请先在设置中开启 AI 日记。',
      );
    }
    if (!settings.hasProviderConfiguration) {
      return const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.notConfigured,
        message: '请先在设置中完成模型与 Endpoint 配置。',
      );
    }

    final day = DateTime(date.year, date.month, date.day);
    final dateText = _date(day);
    try {
      final entries = api.getDiaryEntriesDetailed(
        start: dateText,
        end: dateText,
      );
      if (!allowDuplicate && hasPublishedAiDiary(entries)) {
        return const AiDiaryGenerationOutcome(
          status: AiDiaryGenerationStatus.duplicate,
          message: '这一天已有 AI 生成或 AI 辅助日记。',
        );
      }

      final snapshot = buildAiDiarySnapshot(api: api, date: day);
      if (!hasMeaningfulActivity(snapshot)) {
        return const AiDiaryGenerationOutcome(
          status: AiDiaryGenerationStatus.noActivity,
          message: '当天暂无足够的有效使用记录，未生成日记。',
        );
      }

      final attempt = await client.generateDiary(
        snapshot: snapshot,
        settings: settings,
      );
      if (!attempt.isSuccess) return _failureOutcome(attempt);

      final draft = attempt.draft!;
      final entryId = api.publishAiDiary(
        date: dateText,
        content: draft.content,
        sourceModel: draft.model,
      );
      return AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.success,
        entryId: entryId.toInt(),
        content: draft.content,
        model: draft.model,
      );
    } catch (_) {
      return const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.failed,
        message: 'AI 日记未能生成或发布，现有日记未受影响。',
      );
    }
  }

  AiDiaryGenerationOutcome _failureOutcome(AiDiaryAttempt attempt) {
    final status = switch (attempt.failure) {
      AiDiaryFailureKind.disabled => AiDiaryGenerationStatus.disabled,
      AiDiaryFailureKind.notConfigured => AiDiaryGenerationStatus.notConfigured,
      AiDiaryFailureKind.missingCredentials =>
        AiDiaryGenerationStatus.missingCredentials,
      AiDiaryFailureKind.timeout ||
      AiDiaryFailureKind.provider ||
      AiDiaryFailureKind.invalidResponse ||
      null => AiDiaryGenerationStatus.failed,
    };
    return AiDiaryGenerationOutcome(status: status, message: attempt.error);
  }
}

bool hasPublishedAiDiary(Iterable<DiaryEntryDto> entries) => entries.any(
  (entry) =>
      entry.status == 'published' &&
      (entry.source == 'ai_generated' || entry.source == 'ai_assisted'),
);

bool hasMeaningfulActivity(RecapSnapshot snapshot) =>
    snapshot.activeSeconds > 0 ||
    snapshot.activityFacts.any((fact) => fact.durationSeconds > 0);

RecapSnapshot buildAiDiarySnapshot({
  required TimeTraceApi api,
  required DateTime date,
}) {
  final day = DateTime(date.year, date.month, date.day);
  final dateText = _date(day);
  final previousText = _date(day.subtract(const Duration(days: 1)));
  final stats = api.getStats(start: dateText, end: dateText);
  final previousStats = api.getStats(start: previousText, end: previousText);
  final apps = api.getUsageSplit(start: dateText, end: dateText).toList()
    ..sort(
      (a, b) => b.activeSeconds.toInt().compareTo(a.activeSeconds.toInt()),
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

  final diaryEntries = api
      .getDiaryEntriesDetailed(start: dateText, end: dateText)
      .where(
        (entry) =>
            entry.status == 'published' && entry.content.trim().isNotEmpty,
      )
      .take(8)
      .map((entry) => _truncate(entry.content.trim(), 600))
      .toList(growable: false);

  final detail = api.getDayDetail(date: dateText);
  final activeSessions = detail.sessions
      .where(
        (session) =>
            !session.isIdle &&
            session.durationSecs.toInt() > 0 &&
            session.appName.trim().isNotEmpty,
      )
      .toList(growable: false);
  final metrics = _sessionMetrics(detail.sessions);
  final activityFacts = activeSessions
      .map(
        (session) => RecapActivityFact(
          date: day,
          startedAt: _localizeExplicitIsoTimestamp(session.startedAt),
          appName: session.appName.trim(),
          durationSeconds: session.durationSecs.toInt(),
        ),
      )
      .toList(growable: false);

  final hourly = api.getDayHourly(date: dateText);
  int? peakHour;
  var peakHourSeconds = 0;
  for (var hour = 0; hour < hourly.length && hour < 24; hour++) {
    final seconds = hourly[hour].toInt();
    if (seconds > peakHourSeconds) {
      peakHour = hour;
      peakHourSeconds = seconds;
    }
  }

  return RecapSnapshot(
    label: '所选日期',
    start: day,
    end: day,
    activeSeconds: stats.activeSeconds.toInt(),
    idleSeconds: stats.idleSeconds.toInt(),
    previousActiveSeconds: previousStats.activeSeconds.toInt(),
    topApps: topApps,
    sessionCount: metrics.$1,
    contextSwitches: metrics.$2,
    longestActiveStreakSeconds: metrics.$3,
    peakHour: peakHour,
    peakHourActiveSeconds: peakHourSeconds,
    diaryEntries: diaryEntries,
    activityFacts: activityFacts,
  );
}

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

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _truncate(String value, int maxChars) =>
    value.length <= maxChars ? value : '${value.substring(0, maxChars)}…';

String _localizeExplicitIsoTimestamp(String value) {
  final raw = value.trim();
  if (raw.isEmpty || !RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$').hasMatch(raw)) {
    return value;
  }
  final parsed = DateTime.tryParse(raw);
  return parsed == null ? value : parsed.toLocal().toIso8601String();
}
