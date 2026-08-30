import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';
import 'package:timetrace_app/src/features/settings/application/ai_diary_daily_scheduler.dart';
import 'package:timetrace_app/src/features/settings/data/ai_diary_schedule_state_store.dart';

final aiDiaryScheduleStateStoreProvider = Provider<AiDiaryScheduleStateStore>(
  (_) => const FileAiDiaryScheduleStateStore(),
);

final aiDiarySchedulerClockProvider = Provider<AiDiaryClock>(
  (_) => DateTime.now,
);

final aiDiarySchedulePreferencesLoaderProvider =
    Provider<AiDiarySchedulePreferencesLoader>((ref) {
      return () async {
        final settings = await ref.read(recapAiSettingsProvider.future);
        return AiDiarySchedulePreferences(
          aiEnabled: settings.enabled,
          automaticGenerationEnabled: settings.automaticGenerationEnabled,
          generationTimeMinutes:
              settings.normalizedAutomaticGenerationTimeMinutes,
        );
      };
    });

final aiDiaryScheduledGeneratorProvider = Provider<AiDiaryScheduledGenerator>((
  ref,
) {
  return (date) async {
    final outcome = await ref
        .read(aiDiaryGenerationProvider.notifier)
        .generateForDate(date, allowDuplicate: false);
    AppLogger.log(
      'scheduled AI diary ${outcome.status.name} for ${_date(date)}',
    );
    return switch (outcome.status) {
      AiDiaryGenerationStatus.success => AiDiaryScheduledAttempt.published,
      AiDiaryGenerationStatus.duplicate =>
        AiDiaryScheduledAttempt.alreadyExists,
      AiDiaryGenerationStatus.noActivity => AiDiaryScheduledAttempt.noActivity,
      _ => AiDiaryScheduledAttempt.retryableFailure,
    };
  };
});

final aiDiaryDailySchedulerProvider = Provider<DailyAiDiaryScheduler>((ref) {
  final scheduler = DailyAiDiaryScheduler(
    loadPreferences: ref.read(aiDiarySchedulePreferencesLoaderProvider),
    generate: ref.read(aiDiaryScheduledGeneratorProvider),
    stateStore: ref.read(aiDiaryScheduleStateStoreProvider),
    clock: ref.read(aiDiarySchedulerClockProvider),
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
