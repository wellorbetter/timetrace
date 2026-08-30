import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/nowline/application/nowline_semanticizer.dart';
import 'package:timetrace_app/src/features/nowline/application/today_nowline_builder.dart';
import 'package:timetrace_app/src/features/nowline/data/live_activity_port.dart';
import 'package:timetrace_app/src/features/nowline/data/native_live_activity_port.dart';
import 'package:timetrace_app/src/features/nowline/data/nowline_preferences_store.dart';
import 'package:timetrace_app/src/features/nowline/domain/live_activity_models.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

final liveActivityPortProvider = Provider<LiveActivityPort>(
  (ref) => NativeLiveActivityPort(),
);

class NowlinePreferencesNotifier extends AsyncNotifier<NowlinePreferences> {
  static const _store = NowlinePreferencesStore();

  @override
  Future<NowlinePreferences> build() => _store.load();

  void preview(NowlinePreferences value) => state = AsyncData(value);

  Future<void> save(NowlinePreferences value) async {
    state = AsyncData(value);
    await _store.save(value);
  }
}

final nowlinePreferencesProvider =
    AsyncNotifierProvider<NowlinePreferencesNotifier, NowlinePreferences>(
      NowlinePreferencesNotifier.new,
    );

final nowlineTimelineProvider = StreamProvider.autoDispose<NowlineTimeline>((
  ref,
) {
  final port = ref.watch(liveActivityPortProvider);
  final preferences =
      ref.watch(nowlinePreferencesProvider).value ?? const NowlinePreferences();
  return _pollTimeline(port, preferences);
});

final todayNowlineProvider = FutureProvider.autoDispose<NowlineTimeline>((ref) {
  final api = ref.watch(apiProvider);
  final preferences =
      ref.watch(nowlinePreferencesProvider).value ?? const NowlinePreferences();
  final now = DateTime.now();
  final date =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final detail = api.getDayDetail(date: date);
  return const TodayNowlineBuilder().build(
    sessions: detail.sessions,
    preferences: preferences,
    now: now,
  );
});

Stream<NowlineTimeline> _pollTimeline(
  LiveActivityPort port,
  NowlinePreferences preferences,
) async* {
  const semanticizer = NowlineSemanticizer();
  while (true) {
    final snapshot = port.read();
    yield semanticizer.build(
      snapshot: snapshot,
      preferences: preferences,
      now: DateTime.now(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 750));
  }
}
