import 'dart:async';

typedef AiDiaryClock = DateTime Function();
typedef AiDiarySchedulePreferencesLoader =
    Future<AiDiarySchedulePreferences> Function();
typedef AiDiaryScheduledGenerator =
    Future<AiDiaryScheduledAttempt> Function(DateTime localDate);

class AiDiarySchedulePreferences {
  const AiDiarySchedulePreferences({
    required this.aiEnabled,
    required this.automaticGenerationEnabled,
    required this.generationTimeMinutes,
  });

  final bool aiEnabled;
  final bool automaticGenerationEnabled;
  final int generationTimeMinutes;

  int get normalizedGenerationTimeMinutes =>
      generationTimeMinutes.clamp(0, 23 * 60 + 59);
}

/// The scheduler only needs to know whether a generation attempt should close
/// the current local day. The AI feature keeps the richer UI-facing outcome.
enum AiDiaryScheduledAttempt {
  published,
  alreadyExists,
  noActivity,
  retryableFailure,
}

enum AiDiaryScheduleResult {
  disabled,
  beforeScheduledTime,
  alreadyCompleted,
  published,
  alreadyExists,
  noActivity,
  retryableFailure,
  busy,
}

abstract interface class AiDiaryScheduleStateStore {
  Future<DateTime?> readLastCompletedLocalDate();

  Future<void> writeLastCompletedLocalDate(DateTime localDate);
}

/// Runs one bounded, local-day AI diary job while the desktop process is alive.
///
/// It deliberately never accepts a date from persisted state: every check uses
/// today's local date, so waking the computer cannot backfill yesterday. A
/// published diary or a duplicate closes the day; no activity and failures stay
/// retryable.
class DailyAiDiaryScheduler {
  DailyAiDiaryScheduler({
    required AiDiarySchedulePreferencesLoader loadPreferences,
    required AiDiaryScheduledGenerator generate,
    required AiDiaryScheduleStateStore stateStore,
    AiDiaryClock? clock,
    this.pollInterval = const Duration(minutes: 1),
  }) : _loadPreferences = loadPreferences,
       _generate = generate,
       _stateStore = stateStore,
       _clock = clock ?? DateTime.now;

  final AiDiarySchedulePreferencesLoader _loadPreferences;
  final AiDiaryScheduledGenerator _generate;
  final AiDiaryScheduleStateStore _stateStore;
  final AiDiaryClock _clock;
  final Duration pollInterval;

  Timer? _timer;
  bool _checking = false;
  bool _disposed = false;

  bool get isRunning => _timer != null;

  Future<AiDiaryScheduleResult> start() async {
    if (_disposed) return AiDiaryScheduleResult.disabled;
    _timer ??= Timer.periodic(pollInterval, (_) {
      unawaited(checkNow());
    });
    return checkNow();
  }

  Future<AiDiaryScheduleResult> checkNow() async {
    if (_disposed) return AiDiaryScheduleResult.disabled;
    if (_checking) return AiDiaryScheduleResult.busy;
    _checking = true;
    try {
      final preferences = await _loadPreferences();
      if (!preferences.aiEnabled || !preferences.automaticGenerationEnabled) {
        return AiDiaryScheduleResult.disabled;
      }

      final now = _clock();
      final minutesSinceMidnight = now.hour * 60 + now.minute;
      if (minutesSinceMidnight < preferences.normalizedGenerationTimeMinutes) {
        return AiDiaryScheduleResult.beforeScheduledTime;
      }

      final today = DateTime(now.year, now.month, now.day);
      final completed = await _stateStore.readLastCompletedLocalDate();
      if (_isSameLocalDate(completed, today)) {
        return AiDiaryScheduleResult.alreadyCompleted;
      }

      final attempt = await _generate(today);
      switch (attempt) {
        case AiDiaryScheduledAttempt.published:
          await _stateStore.writeLastCompletedLocalDate(today);
          return AiDiaryScheduleResult.published;
        case AiDiaryScheduledAttempt.alreadyExists:
          await _stateStore.writeLastCompletedLocalDate(today);
          return AiDiaryScheduleResult.alreadyExists;
        case AiDiaryScheduledAttempt.noActivity:
          return AiDiaryScheduleResult.noActivity;
        case AiDiaryScheduledAttempt.retryableFailure:
          return AiDiaryScheduleResult.retryableFailure;
      }
    } catch (_) {
      return AiDiaryScheduleResult.retryableFailure;
    } finally {
      _checking = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

bool _isSameLocalDate(DateTime? a, DateTime b) =>
    a != null && a.year == b.year && a.month == b.month && a.day == b.day;
