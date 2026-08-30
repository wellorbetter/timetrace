import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/recap/application/ai_diary_service.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_settings_store.dart';
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';

class RecapAiSettingsNotifier extends AsyncNotifier<RecapAiSettings> {
  @override
  Future<RecapAiSettings> build() =>
      ref.watch(recapAiSettingsStoreProvider).load();

  void preview(RecapAiSettings value) => state = AsyncData(value);

  Future<void> save(RecapAiSettings value) async {
    await ref.read(recapAiSettingsStoreProvider).save(value);
    state = AsyncData(value);
  }
}

final recapAiSettingsStoreProvider = Provider<RecapAiSettingsStore>(
  (_) => const RecapAiSettingsStore(),
);

final recapAiSettingsProvider =
    AsyncNotifierProvider<RecapAiSettingsNotifier, RecapAiSettings>(
      RecapAiSettingsNotifier.new,
    );

/// Manual and scheduled AI diary generation share this one operation.
///
/// [generateForDate] returns only after a successful result has been
/// atomically published. A duplicate outcome is returned before calling the
/// model; callers may ask for confirmation and retry with
/// `allowDuplicate: true`.
class AiDiaryGenerationNotifier
    extends AsyncNotifier<AiDiaryGenerationOutcome?> {
  static final _coordinator = AiDiaryGenerationCoordinator();

  @override
  Future<AiDiaryGenerationOutcome?> build() async => null;

  Future<bool> hasAiDiaryForDate(DateTime date) async {
    final api = ref.read(apiProvider);
    final day = _date(DateTime(date.year, date.month, date.day));
    final entries = api.getDiaryEntriesDetailed(start: day, end: day);
    return hasPublishedAiDiary(entries);
  }

  Future<AiDiaryGenerationOutcome> generateForDate(
    DateTime date, {
    bool allowDuplicate = false,
  }) => _coordinator.runForDate(date, () async {
    // Loading/result publication is inside the same date lock as the service
    // call so a queued manual or scheduled request cannot appear finished
    // while its duplicate recheck is still running.
    state = const AsyncLoading();
    final settings =
        ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
    final outcome = await _coordinator.service.generateAndPublish(
      api: ref.read(apiProvider),
      date: date,
      settings: settings,
      allowDuplicate: allowDuplicate,
    );
    if (outcome.isSuccess) ref.invalidate(calendarDataProvider);
    state = AsyncData(outcome);
    return outcome;
  });

  void clearResult() => state = const AsyncData(null);
}

final aiDiaryGenerationProvider =
    AsyncNotifierProvider<AiDiaryGenerationNotifier, AiDiaryGenerationOutcome?>(
      AiDiaryGenerationNotifier.new,
    );

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
