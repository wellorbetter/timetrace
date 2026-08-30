import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/settings/application/ai_diary_daily_scheduler.dart';
import 'package:timetrace_app/src/features/settings/providers/ai_diary_scheduler_provider.dart';

void main() {
  AiDiarySchedulePreferences enabledAt(int minutes) =>
      AiDiarySchedulePreferences(
        aiEnabled: true,
        automaticGenerationEnabled: true,
        generationTimeMinutes: minutes,
      );

  test('stays disabled when AI or automatic generation is off', () async {
    final attempts = <DateTime>[];
    final store = _MemoryScheduleStore();
    final scheduler = DailyAiDiaryScheduler(
      clock: () => DateTime(2026, 8, 30, 23),
      loadPreferences: () async => const AiDiarySchedulePreferences(
        aiEnabled: true,
        automaticGenerationEnabled: false,
        generationTimeMinutes: 22 * 60 + 30,
      ),
      generate: (date) async {
        attempts.add(date);
        return AiDiaryScheduledAttempt.published;
      },
      stateStore: store,
    );

    expect(await scheduler.checkNow(), AiDiaryScheduleResult.disabled);
    expect(attempts, isEmpty);
    expect(store.lastCompleted, isNull);
  });

  test('waits until the configured local minute', () async {
    var now = DateTime(2026, 8, 30, 22, 29);
    var attempts = 0;
    final scheduler = DailyAiDiaryScheduler(
      clock: () => now,
      loadPreferences: () async => enabledAt(22 * 60 + 30),
      generate: (_) async {
        attempts++;
        return AiDiaryScheduledAttempt.published;
      },
      stateStore: _MemoryScheduleStore(),
    );

    expect(
      await scheduler.checkNow(),
      AiDiaryScheduleResult.beforeScheduledTime,
    );
    now = DateTime(2026, 8, 30, 22, 30);
    expect(await scheduler.checkNow(), AiDiaryScheduleResult.published);
    expect(attempts, 1);
  });

  test('startup or resume after the time catches up only for today', () async {
    final generatedDates = <DateTime>[];
    final store = _MemoryScheduleStore(lastCompleted: DateTime(2026, 8, 29));
    final scheduler = DailyAiDiaryScheduler(
      clock: () => DateTime(2026, 8, 30, 23, 45),
      loadPreferences: () async => enabledAt(22 * 60 + 30),
      generate: (date) async {
        generatedDates.add(date);
        return AiDiaryScheduledAttempt.published;
      },
      stateStore: store,
    );

    expect(await scheduler.checkNow(), AiDiaryScheduleResult.published);
    expect(generatedDates, [DateTime(2026, 8, 30)]);
    expect(store.lastCompleted, DateTime(2026, 8, 30));
  });

  test('published and duplicate outcomes close the local day', () async {
    var attempts = 0;
    final store = _MemoryScheduleStore();
    final scheduler = DailyAiDiaryScheduler(
      clock: () => DateTime(2026, 8, 30, 23),
      loadPreferences: () async => enabledAt(0),
      generate: (_) async {
        attempts++;
        return AiDiaryScheduledAttempt.alreadyExists;
      },
      stateStore: store,
    );

    expect(await scheduler.checkNow(), AiDiaryScheduleResult.alreadyExists);
    expect(await scheduler.checkNow(), AiDiaryScheduleResult.alreadyCompleted);
    expect(attempts, 1);
    expect(store.lastCompleted, DateTime(2026, 8, 30));
  });

  test('no activity and failures remain retryable', () async {
    var attempt = AiDiaryScheduledAttempt.noActivity;
    var calls = 0;
    final store = _MemoryScheduleStore();
    final scheduler = DailyAiDiaryScheduler(
      clock: () => DateTime(2026, 8, 30, 23),
      loadPreferences: () async => enabledAt(0),
      generate: (_) async {
        calls++;
        return attempt;
      },
      stateStore: store,
    );

    expect(await scheduler.checkNow(), AiDiaryScheduleResult.noActivity);
    attempt = AiDiaryScheduledAttempt.retryableFailure;
    expect(await scheduler.checkNow(), AiDiaryScheduleResult.retryableFailure);
    attempt = AiDiaryScheduledAttempt.published;
    expect(await scheduler.checkNow(), AiDiaryScheduleResult.published);
    expect(calls, 3);
    expect(store.lastCompleted, DateTime(2026, 8, 30));
  });

  test('overlapping checks cannot publish twice', () async {
    final pending = Completer<AiDiaryScheduledAttempt>();
    var calls = 0;
    final scheduler = DailyAiDiaryScheduler(
      clock: () => DateTime(2026, 8, 30, 23),
      loadPreferences: () async => enabledAt(0),
      generate: (_) {
        calls++;
        return pending.future;
      },
      stateStore: _MemoryScheduleStore(),
    );

    final first = scheduler.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(await scheduler.checkNow(), AiDiaryScheduleResult.busy);
    pending.complete(AiDiaryScheduledAttempt.published);
    expect(await first, AiDiaryScheduleResult.published);
    expect(calls, 1);
  });

  test(
    'runtime provider exposes injectable clock and generation callback',
    () async {
      final generatedDates = <DateTime>[];
      final store = _MemoryScheduleStore();
      final container = ProviderContainer(
        overrides: [
          aiDiarySchedulerClockProvider.overrideWithValue(
            () => DateTime(2026, 8, 30, 22, 30),
          ),
          aiDiarySchedulePreferencesLoaderProvider.overrideWithValue(
            () async => enabledAt(22 * 60 + 30),
          ),
          aiDiaryScheduledGeneratorProvider.overrideWithValue((date) async {
            generatedDates.add(date);
            return AiDiaryScheduledAttempt.published;
          }),
          aiDiaryScheduleStateStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);

      final scheduler = container.read(aiDiaryDailySchedulerProvider);
      expect(await scheduler.checkNow(), AiDiaryScheduleResult.published);
      expect(generatedDates, [DateTime(2026, 8, 30)]);
      expect(store.lastCompleted, DateTime(2026, 8, 30));
    },
  );
}

class _MemoryScheduleStore implements AiDiaryScheduleStateStore {
  _MemoryScheduleStore({this.lastCompleted});

  DateTime? lastCompleted;

  @override
  Future<DateTime?> readLastCompletedLocalDate() async => lastCompleted;

  @override
  Future<void> writeLastCompletedLocalDate(DateTime localDate) async {
    lastCompleted = localDate;
  }
}
