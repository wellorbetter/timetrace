import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/features/recap/data/recap_schedule_store.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_schedule.dart';

class RecapScheduleNotifier extends AsyncNotifier<RecapScheduleSettings> {
  static const _store = RecapScheduleStore();

  @override
  Future<RecapScheduleSettings> build() => _store.load();

  Future<void> save(RecapScheduleSettings value) async {
    state = AsyncData(value);
    await _store.save(value);
  }

  Future<void> markRun(String runKey) async {
    final current = state.value ?? await _store.load();
    final updated = current.copyWith(lastRunKey: runKey);
    state = AsyncData(updated);
    await _store.save(updated);
  }
}

final recapScheduleProvider =
    AsyncNotifierProvider<RecapScheduleNotifier, RecapScheduleSettings>(
  RecapScheduleNotifier.new,
);
