import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/flight/domain/flight_state.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';

/// Manages the active flight session lifecycle: start / complete / discard.
///
/// The controller keeps a 1-second timer running while a flight is active so
/// the UI can show a live elapsed-time counter without polling the backend.
class FlightControllerNotifier extends Notifier<FlightControllerState> {
  Timer? _tick;

  @override
  FlightControllerState build() {
    // Prime the state from the backend so a restart while a flight is active
    // resumes the UI correctly.
    Future.microtask(_refresh);
    ref.onDispose(() => _tick?.cancel());
    return const FlightControllerState(activeSession: null);
  }

  /// Re-read the active session from the backend (idempotent).
  Future<void> _refresh() async {
    try {
      final api = ref.read(apiProvider);
      final current = await api.flightGetCurrent();
      _setActive(current == null ? null : _sessionFromDto(current));
    } catch (e) {
      state = state.copyWith(error: '读取进行中的起飞失败: $e');
    }
  }

  void _setActive(PrivateFlightSession? session) {
    if (session == null) {
      _tick?.cancel();
      _tick = null;
      state = state.copyWith(clearSession: true, clearError: true);
    } else {
      state = state.copyWith(activeSession: session, clearError: true);
      _ensureTick();
    }
  }

  /// Start a new flight. Returns the new session id, or null on error.
  Future<int?> start() async {
    if (state.activeSession != null) {
      state = state.copyWith(error: '已有进行中的起飞，请先降落后再开始新的起飞。');
      return null;
    }
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final api = ref.read(apiProvider);
      final id = await api.flightStart();
      // Re-fetch to get the full DTO (startedAt etc.).
      final session = await api.flightGetCurrent();
      state = state.copyWith(
        activeSession: session == null ? null : _sessionFromDto(session),
        isLoading: false,
      );
      return id.toInt();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '起飞失败: $e');
      return null;
    }
  }

  /// Complete the active flight with an optional satisfaction and note.
  Future<bool> complete({int? satisfaction, required String note}) async {
    return completeWithMaterial(
      satisfaction: satisfaction,
      note: note,
      material: null,
    );
  }

  /// Atomically completes the active flight and optional linked material.
  Future<bool> completeWithMaterial({
    int? satisfaction,
    required String note,
    required FlightCompletionMaterialDto? material,
  }) async {
    final active = state.activeSession;
    if (active == null) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final api = ref.read(apiProvider);
      await api.flightCompleteWithMaterial(
        satisfaction: satisfaction,
        note: note,
        material: material,
      );
      _setActive(null);
      // Invalidate dependents so the today stats / recent list refresh.
      ref.invalidate(flightTodayStatsProvider);
      ref.invalidate(flightRecentProvider);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '降落失败: $e');
      return false;
    }
  }

  /// Discard the active flight without saving.
  Future<bool> discard() async {
    if (state.activeSession == null) return false;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final api = ref.read(apiProvider);
      await api.flightDiscard();
      _setActive(null);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '丢弃失败: $e');
      return false;
    }
  }

  /// Link a material to a specific flight session.
  Future<void> linkMaterial({
    required int flightId,
    required int materialId,
  }) async {
    try {
      final api = ref.read(apiProvider);
      await api.flightAddMaterial(flightId: flightId, materialId: materialId);
    } catch (e) {
      state = state.copyWith(error: '关联材料失败: $e');
    }
  }

  /// 1Hz tick: rebuild listeners so the live elapsed label updates.
  void _ensureTick() {
    if (_tick != null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      // Touch state to trigger rebuilds; the session object itself is stable.
      state = state.copyWith();
    });
  }
}

final flightControllerProvider =
    NotifierProvider.autoDispose<
      FlightControllerNotifier,
      FlightControllerState
    >(FlightControllerNotifier.new);

// Re-exported here so dependents can import a single providers file.
final flightTodayStatsProvider =
    AsyncNotifierProvider.autoDispose<
      FlightTodayStatsNotifier,
      FlightTodayStats
    >(FlightTodayStatsNotifier.new);

final flightRecentProvider =
    AsyncNotifierProvider.autoDispose<
      FlightRecentNotifier,
      List<PrivateFlightSession>
    >(FlightRecentNotifier.new);

/// Loads today's completed flight count and total duration.
class FlightTodayStatsNotifier extends AsyncNotifier<FlightTodayStats> {
  @override
  Future<FlightTodayStats> build() async {
    return _load();
  }

  Future<FlightTodayStats> _load() async {
    final api = ref.read(apiProvider);
    final now = DateTime.now();
    final today = _fmtDate(now);
    try {
      final sessions = await api.flightRange(start: today, end: today);
      final completed = sessions.where((s) => s.status != 'active').toList();
      final total = completed.fold<int>(
        0,
        (sum, s) => sum + (s.durationSecs?.toInt() ?? 0),
      );
      return FlightTodayStats(count: completed.length, totalSeconds: total);
    } catch (e) {
      throw Exception('加载今日起飞统计失败: $e');
    }
  }
}

/// Loads the most recent completed flight sessions.
class FlightRecentNotifier extends AsyncNotifier<List<PrivateFlightSession>> {
  @override
  Future<List<PrivateFlightSession>> build() async {
    return _load();
  }

  Future<List<PrivateFlightSession>> _load() async {
    final api = ref.read(apiProvider);
    try {
      return (await api.flightRecent(
        limit: 20,
      )).map(_sessionFromDto).toList(growable: false);
    } catch (e) {
      throw Exception('加载最近起飞记录失败: $e');
    }
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

PrivateFlightSession _sessionFromDto(FlightSessionDto value) {
  return PrivateFlightSession(
    id: value.id,
    startedAt: value.startedAt,
    endedAt: value.endedAt,
    durationSecs: value.durationSecs,
    status: value.status,
    satisfaction: value.satisfaction,
    note: value.note,
    date: value.date,
  );
}
