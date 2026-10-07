import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/time_tools_store.dart';
import '../domain/time_tool_state.dart';

final timeToolsStoreProvider = Provider<TimeToolsStore>(
  (ref) => FileTimeToolsStore(),
);
final timeToolsClockProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now().toUtc(),
);
final timeToolsIdProvider = Provider<String Function()>((ref) => newTimeToolId);
final timeToolsMonotonicProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  ref.onDispose(watch.stop);
  return () => watch.elapsed;
});

class _Segment {
  const _Segment(this.utc, this.elapsed, this.limit);
  final DateTime utc;
  final Duration elapsed;
  final Duration limit;
}

class TimeToolsViewState {
  TimeToolsViewState({
    TimeToolsState? data,
    this.loaded = false,
    this.loading = false,
    this.blocked = false,
    this.dirty = false,
    this.error,
  }) : data = data ?? TimeToolsState();
  final TimeToolsState data;
  final bool loaded, loading, blocked, dirty;
  final String? error;
  bool get canEdit => loaded && !loading && !blocked;
  TimeToolsViewState copyWith({
    TimeToolsState? data,
    bool? loaded,
    bool? loading,
    bool? blocked,
    bool? dirty,
    String? error,
    bool clearError = false,
  }) => TimeToolsViewState(
    data: data ?? this.data,
    loaded: loaded ?? this.loaded,
    loading: loading ?? this.loading,
    blocked: blocked ?? this.blocked,
    dirty: dirty ?? this.dirty,
    error: clearError ? null : error ?? this.error,
  );
}

final timeToolsProvider =
    NotifierProvider<TimeToolsNotifier, TimeToolsViewState>(
      TimeToolsNotifier.new,
    );

class TimeToolsNotifier extends Notifier<TimeToolsViewState> {
  Future<void>? _load;
  Future<void> _writes = Future.value();
  TimeToolsState? _ackBase;
  final _intentBases = <int, TimeToolsState?>{};
  // A diagnostic of retained CAS bookkeeping, not a heap-size estimate.
  @visibleForTesting
  int get retainedIntentBaseCount => _intentBases.length;
  final _segments = <String, _Segment>{};
  int _sessionSequence = 0;
  @override
  TimeToolsViewState build() {
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(ensureLoaded());
    });
    return TimeToolsViewState();
  }

  Future<void> ensureLoaded() => state.loaded ? Future.value() : reload();
  Future<void> reload() {
    if (_load != null) return _load!;
    return _load = Future<void>.microtask(() async {
      try {
        if (!ref.mounted) return;
        state = state.copyWith(loading: true, clearError: true);
        final result = await ref.read(timeToolsStoreProvider).load();
        if (!ref.mounted) return;
        final incoming = result.value;
        var next = state.data;
        if (!state.dirty &&
            incoming != null &&
            incoming.revision >= next.revision) {
          _ackBase = incoming;
          _segments.removeWhere(
            (id, _) => !incoming.sessions.any(
              (s) => s.id == id && s.status == TimeSessionStatus.active,
            ),
          );
          // A restart cannot prove the uncheckpointed running interval.
          next = incoming.copyWith(
            sessions: [
              for (final s in incoming.sessions)
                s.status == TimeSessionStatus.active &&
                        !_segments.containsKey(s.id)
                    ? s.copyWith(elapsedKnown: false)
                    : s,
            ],
          );
        }
        final conflict =
            state.dirty &&
            incoming != null &&
            incoming.revision > next.revision;
        state = state.copyWith(
          data: next,
          loaded: true,
          loading: false,
          blocked: result.blocked || conflict,
          error: conflict ? '历史已改变，本次未保存修改仍在；请核对后重试' : result.message,
          clearError: !result.blocked && !conflict,
        );
        reconcile();
      } catch (_) {
        if (ref.mounted)
          state = state.copyWith(
            loading: false,
            blocked: true,
            error: '暂时无法读取时间组件，修改已保留；请重试读取',
          );
      } finally {
        _load = null;
      }
    });
  }

  bool _change(TimeToolsState next) {
    if (!ref.mounted || !state.canEdit) return false;
    state = state.copyWith(
      data: next.copyWith(revision: state.data.revision + 1),
      dirty: true,
      clearError: true,
    );
    unawaited(_persist(state.data));
    return true;
  }

  Future<void> _persist(TimeToolsState snapshot) {
    final operation = _writes.then((_) async {
      if (!ref.mounted || !state.loaded || state.blocked) return;
      try {
        // Serial writes need only this in-flight operation and the latest
        // already-attempted intent. Never refresh an existing retry's base.
        _intentBases.removeWhere(
          (revision, _) =>
              revision != snapshot.revision && revision != state.data.revision,
        );
        if (!_intentBases.containsKey(snapshot.revision))
          _intentBases[snapshot.revision] = _ackBase;
        await ref
            .read(timeToolsStoreProvider)
            .put(
              snapshot,
              expectedBase: _intentBases[snapshot.revision],
              checkBase: true,
            );
        _ackBase = snapshot;
        if (ref.mounted && state.data.revision == snapshot.revision)
          state = state.copyWith(dirty: false, clearError: true);
      } catch (_) {
        if (ref.mounted)
          state = state.copyWith(dirty: true, error: '尚未保存到本机，修改仍在本次会话');
      } finally {
        // Obsolete failed intents are just as obsolete as acknowledged ones.
        // Current failed intent keeps its first base; queued operations have
        // not attempted a write yet and capture their base when they start.
        if (ref.mounted) {
          _intentBases.removeWhere(
            (revision, _) => revision != state.data.revision || !state.dirty,
          );
        } else {
          _intentBases.clear();
        }
      }
    });
    _writes = operation;
    return operation;
  }

  Future<void> retrySave() async {
    if (ref.mounted && state.canEdit && state.dirty) await _persist(state.data);
  }

  Future<void> flush() => _writes;
  TimeSession _checkpoint(
    TimeSession session,
    DateTime now,
    TimeSessionStatus status,
  ) {
    var known = session.elapsedKnown, micros = session.knownMicroseconds;
    final segment = _segments.remove(session.id);
    if (session.status == TimeSessionStatus.active) {
      if (segment == null) {
        known = false;
      } else {
        final delta = ref.read(timeToolsMonotonicProvider)() - segment.elapsed;
        final wall = now.difference(segment.utc);
        if (delta.isNegative ||
            (wall.inMicroseconds - delta.inMicroseconds).abs() > 2000000) {
          known = false;
        } else {
          micros += delta.inMicroseconds.clamp(0, segment.limit.inMicroseconds);
        }
      }
    }
    return session.copyWith(
      status: status,
      knownMicroseconds: micros,
      elapsedKnown: known,
      endUtc:
          status == TimeSessionStatus.active ||
              status == TimeSessionStatus.paused
          ? null
          : now,
    );
  }

  List<TimeSession> _replaceSession(TimeSession session) => [
    for (final s in state.data.sessions) s.id == session.id ? session : s,
  ];
  TimeSession? _newSession(
    TimeSessionKind kind,
    DateTime now, {
    PomodoroPhase? phase,
  }) {
    if (state.data.sessions.length >= maxTimeSessions) {
      state = state.copyWith(error: '记录已达到10000条，现有计时仍可结束；未创建新计时');
      return null;
    }
    final seed = ref.read(timeToolsIdProvider)();
    var id = 'session-${seed}-${++_sessionSequence}';
    while (state.data.sessions.any((s) => s.id == id)) {
      id = 'session-${seed}-${++_sessionSequence}';
    }
    if (!validTimeToolId(id)) {
      state = state.copyWith(error: '无法创建唯一计时记录');
      return null;
    }
    return TimeSession(id: id, kind: kind, phase: phase, startUtc: now);
  }

  void _beginSegment(TimeSession session, DateTime now, Duration limit) {
    _segments[session.id] = _Segment(
      now,
      ref.read(timeToolsMonotonicProvider)(),
      limit,
    );
  }

  void reconcile() {
    if (!ref.mounted || !state.canEdit) return;
    final p = state.data.pomodoro;
    final countdown = state.data.countdown;
    final countdownSession = state.data.activeSession(
      TimeSessionKind.countdown,
    );
    if (!p.running && countdownSession == null) return;
    final now = ref.read(timeToolsClockProvider)().toUtc();
    if (p.running && p.remaining(now) == 0) {
      final session = state.data.activeSession(TimeSessionKind.pomodoro);
      _change(
        state.data.copyWith(
          sessions: session == null
              ? null
              : _replaceSession(
                  _checkpoint(session, now, TimeSessionStatus.completed),
                ),
          pomodoro: p.copyWith(
            running: false,
            completed: true,
            remainingSeconds: 0,
            clearDeadline: true,
          ),
        ),
      );
    }
    if (countdown != null &&
        countdownSession != null &&
        countdown.expired(now)) {
      _change(
        state.data.copyWith(
          sessions: _replaceSession(
            _checkpoint(countdownSession, now, TimeSessionStatus.completed),
          ),
        ),
      );
    }
  }

  bool startPomodoro() {
    if (!state.canEdit) return false;
    reconcile();
    var p = state.data.pomodoro;
    if (p.running) return false;
    final now = ref.read(timeToolsClockProvider)().toUtc();
    if (p.completed) {
      final phase = p.phase == PomodoroPhase.focus
          ? PomodoroPhase.rest
          : PomodoroPhase.focus;
      p = p.copyWith(
        phase: phase,
        completed: false,
        remainingSeconds: phase == PomodoroPhase.focus
            ? p.focusSeconds
            : p.restSeconds,
      );
    }
    final existing = state.data.activeSession(TimeSessionKind.pomodoro);
    final session =
        existing ?? _newSession(TimeSessionKind.pomodoro, now, phase: p.phase);
    if (session == null) return false;
    final resumed = session.copyWith(status: TimeSessionStatus.active);
    _beginSegment(resumed, now, Duration(seconds: p.remainingSeconds));
    return _change(
      state.data.copyWith(
        sessions: existing == null
            ? [...state.data.sessions, resumed]
            : _replaceSession(resumed),
        pomodoro: p.copyWith(
          running: true,
          deadlineUtc: now.add(Duration(seconds: p.remainingSeconds)),
        ),
      ),
    );
  }

  bool pausePomodoro() {
    if (!state.canEdit) return false;
    final p = state.data.pomodoro;
    if (!p.running) return false;
    final now = ref.read(timeToolsClockProvider)().toUtc();
    final remaining = p.remaining(now);
    final session = state.data.activeSession(TimeSessionKind.pomodoro);
    return _change(
      state.data.copyWith(
        sessions: session == null
            ? null
            : _replaceSession(
                _checkpoint(
                  session,
                  now,
                  remaining == 0
                      ? TimeSessionStatus.completed
                      : TimeSessionStatus.paused,
                ),
              ),
        pomodoro: p.copyWith(
          running: false,
          completed: remaining == 0,
          remainingSeconds: remaining,
          clearDeadline: true,
        ),
      ),
    );
  }

  bool resetPomodoro() {
    if (!state.canEdit) return false;
    final p = state.data.pomodoro;
    final session = state.data.activeSession(TimeSessionKind.pomodoro);
    return _change(
      state.data.copyWith(
        sessions: session == null
            ? null
            : _replaceSession(
                _checkpoint(
                  session,
                  ref.read(timeToolsClockProvider)().toUtc(),
                  TimeSessionStatus.cancelled,
                ),
              ),
        pomodoro: PomodoroState(
          remainingSeconds: p.focusSeconds,
          focusSeconds: p.focusSeconds,
          restSeconds: p.restSeconds,
        ),
      ),
    );
  }

  bool configurePomodoro(int focusMinutes, int restMinutes) {
    if (!state.canEdit ||
        focusMinutes < 1 ||
        focusMinutes > maxPomodoroSeconds ~/ 60 ||
        restMinutes < 1 ||
        restMinutes > maxPomodoroSeconds ~/ 60 ||
        state.data.pomodoro.running)
      return false;
    return configurePomodoroSeconds(focusMinutes * 60, restMinutes * 60);
  }

  bool configurePomodoroSeconds(
    int focusSeconds,
    int restSeconds, {
    PomodoroPhase phase = PomodoroPhase.focus,
  }) {
    if (!state.canEdit ||
        focusSeconds < 60 ||
        focusSeconds > maxPomodoroSeconds ||
        restSeconds < 60 ||
        restSeconds > maxPomodoroSeconds)
      return false;
    final session = state.data.activeSession(TimeSessionKind.pomodoro);
    return _change(
      state.data.copyWith(
        sessions: session == null
            ? null
            : _replaceSession(
                _checkpoint(
                  session,
                  ref.read(timeToolsClockProvider)().toUtc(),
                  TimeSessionStatus.interrupted,
                ),
              ),
        pomodoro: PomodoroState(
          phase: phase,
          focusSeconds: focusSeconds,
          restSeconds: restSeconds,
          remainingSeconds: phase == PomodoroPhase.focus
              ? focusSeconds
              : restSeconds,
        ),
      ),
    );
  }

  bool configurePomodoroEnd(DateTime localTarget) {
    if (!state.canEdit) return false;
    final p = state.data.pomodoro;
    final seconds = localTarget
        .toUtc()
        .difference(ref.read(timeToolsClockProvider)().toUtc())
        .inSeconds;
    if (!state.canEdit || seconds < 60 || seconds > maxPomodoroSeconds)
      return false;
    return configurePomodoroSeconds(
      p.phase == PomodoroPhase.focus ? seconds : p.focusSeconds,
      p.phase == PomodoroPhase.rest ? seconds : p.restSeconds,
      phase: p.phase,
    );
  }

  bool addTask(String text, {DateTime? dueAtUtc}) {
    if (!state.canEdit ||
        !validTimeToolText(text) ||
        state.data.tasks.length >= 10000)
      return false;
    final id = ref.read(timeToolsIdProvider)();
    if (!validTimeToolId(id) || state.data.tasks.any((task) => task.id == id))
      return false;
    return _change(
      state.data.copyWith(
        tasks: [
          ...state.data.tasks,
          TimeTask(
            id: id,
            text: text.trim(),
            createdAtUtc: ref.read(timeToolsClockProvider)().toUtc(),
            dueAtUtc: dueAtUtc?.toUtc(),
          ),
        ],
      ),
    );
  }

  bool editTask(
    String id,
    String text, {
    DateTime? dueAtUtc,
    bool clearDue = false,
  }) {
    if (!validTimeToolText(text) || !state.data.tasks.any((t) => t.id == id))
      return false;
    return _change(
      state.data.copyWith(
        tasks: [
          for (final t in state.data.tasks)
            t.id == id
                ? t.copyWith(
                    text: text.trim(),
                    dueAtUtc: dueAtUtc?.toUtc(),
                    clearDue: clearDue,
                  )
                : t,
        ],
      ),
    );
  }

  bool toggleTask(String id) {
    if (!state.data.tasks.any((t) => t.id == id)) return false;
    return _change(
      state.data.copyWith(
        tasks: [
          for (final t in state.data.tasks)
            t.id == id ? t.copyWith(done: !t.done) : t,
        ],
      ),
    );
  }

  bool deleteTask(String id) {
    if (!ref.mounted ||
        !state.canEdit ||
        !state.data.tasks.any((task) => task.id == id))
      return false;
    return _change(
      state.data.copyWith(
        tasks: [
          for (final task in state.data.tasks)
            if (task.id != id) task,
        ],
      ),
    );
  }

  bool setCountdown(String title, DateTime localTarget) {
    if (!state.canEdit || !validTimeToolText(title)) return false;
    final target = localTarget.toUtc();
    final old = state.data.countdown;
    final existing = state.data.activeSession(TimeSessionKind.countdown);
    var sessions = state.data.sessions;
    // Title-only edits do not allocate an ID or touch a monotonic checkpoint.
    if (old == null || old.targetUtc != target) {
      final now = ref.read(timeToolsClockProvider)().toUtc();
      final next = _newSession(TimeSessionKind.countdown, now);
      if (next == null) return false;
      if (existing != null)
        sessions = _replaceSession(
          _checkpoint(existing, now, TimeSessionStatus.interrupted),
        );
      final session = target.isAfter(now)
          ? next
          : next.copyWith(status: TimeSessionStatus.completed, endUtc: now);
      sessions = [...sessions, session];
      if (session.ongoing) _beginSegment(session, now, target.difference(now));
    }
    return _change(
      state.data.copyWith(
        sessions: sessions,
        countdown: CountdownState(title: title.trim(), targetUtc: target),
      ),
    );
  }
}
