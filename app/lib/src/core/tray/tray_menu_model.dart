import 'dart:async';

import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

/// Stable native-menu keys shared by the model and [TrayService].
abstract final class TrayMenuKeys {
  static const pomodoroStatus = 'pomodoro_status';
  static const pomodoroStart = 'pomodoro_start';
  static const pomodoroPause = 'pomodoro_pause';
  static const pomodoroResume = 'pomodoro_resume';
  static const pomodoroSkip = 'pomodoro_skip';
  static const pomodoroStop = 'pomodoro_stop';
  static const trackingStatus = 'tracking_status';
  static const show = 'show';

  // Retained for compatibility with the existing tray action.
  static const trackingPause = 'pause';
  static const quit = 'quit';
}

/// One context-valid Pomodoro command shown in the native tray menu.
final class TrayPomodoroAction {
  const TrayPomodoroAction({required this.key, required this.label});

  final String key;
  final String label;

  @override
  bool operator ==(Object other) {
    return other is TrayPomodoroAction &&
        other.key == key &&
        other.label == label;
  }

  @override
  int get hashCode => Object.hash(key, label);
}

/// Privacy-minimal value model applied to the native tray.
///
/// It deliberately has no application identity, executable path, or window
/// title input, so none of those values can reach the tooltip or menu labels.
final class TrayMenuModel {
  TrayMenuModel._({
    required this.tooltip,
    required this.pomodoroStatusLabel,
    required List<TrayPomodoroAction> pomodoroActions,
    required this.trackingStatusLabel,
    required this.trackingActionLabel,
    required this.showActionLabel,
    required this.quitActionLabel,
  }) : pomodoroActions = List.unmodifiable(pomodoroActions);

  factory TrayMenuModel.fromPomodoro({
    required bool enabled,
    required PomodoroState state,
    required bool trackingPaused,
    bool systemFrozen = false,
    ReminderL10n strings = ReminderL10n.zh,
  }) {
    final pomodoroStatus = _pomodoroStatus(
      enabled: enabled,
      state: state,
      systemFrozen: systemFrozen,
      strings: strings,
    );
    final actions = _pomodoroActions(
      enabled: enabled,
      state: state,
      strings: strings,
    );
    final tooltip = !enabled
        ? trackingPaused
              ? 'TimeTrace — ${strings.trackingPaused}'
              : 'TimeTrace — ${strings.trackingTooltip}'
        : trackingPaused
        ? 'TimeTrace — ${strings.trackingPaused} · $pomodoroStatus'
        : 'TimeTrace — $pomodoroStatus';

    return TrayMenuModel._(
      tooltip: tooltip,
      pomodoroStatusLabel: pomodoroStatus,
      pomodoroActions: actions,
      trackingStatusLabel: trackingPaused
          ? strings.trackingPaused
          : strings.trackingActive,
      trackingActionLabel: trackingPaused
          ? strings.resumeTracking
          : strings.pauseTracking,
      showActionLabel: strings.showTimeTrace,
      quitActionLabel: strings.quitTimeTrace,
    );
  }

  final String tooltip;
  final String pomodoroStatusLabel;
  final List<TrayPomodoroAction> pomodoroActions;
  final String trackingStatusLabel;
  final String trackingActionLabel;
  final String showActionLabel;
  final String quitActionLabel;

  @override
  bool operator ==(Object other) {
    return other is TrayMenuModel &&
        other.tooltip == tooltip &&
        other.pomodoroStatusLabel == pomodoroStatusLabel &&
        _actionsEqual(other.pomodoroActions, pomodoroActions) &&
        other.trackingStatusLabel == trackingStatusLabel &&
        other.trackingActionLabel == trackingActionLabel &&
        other.showActionLabel == showActionLabel &&
        other.quitActionLabel == quitActionLabel;
  }

  @override
  int get hashCode => Object.hash(
    tooltip,
    pomodoroStatusLabel,
    Object.hashAll(pomodoroActions),
    trackingStatusLabel,
    trackingActionLabel,
    showActionLabel,
    quitActionLabel,
  );
}

typedef TrayMenuModelResolver = TrayMenuModel Function();
typedef TrayMenuModelWriter = Future<void> Function(TrayMenuModel model);
typedef TrayMenuSyncErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// State edges which must bypass the background tray refresh cadence.
///
/// Remaining countdown time is deliberately excluded: while the app stays in
/// the background it is refreshed by [TrayMenuSyncGate] at most once per ten
/// one-second runtime publications. User-visible phase and pause boundaries
/// still reach the native menu immediately.
final class TrayMenuSyncBoundary {
  const TrayMenuSyncBoundary({
    required this.config,
    required this.phase,
    required this.intent,
    required this.activityPaused,
    required this.systemFrozen,
    this.locale = AppLocale.zh,
  });

  factory TrayMenuSyncBoundary.fromPomodoro({
    required PomodoroConfig config,
    required PomodoroState state,
    required bool activityPaused,
    required bool systemFrozen,
    AppLocale locale = AppLocale.zh,
  }) {
    return TrayMenuSyncBoundary(
      config: config,
      phase: state.phase,
      intent: state.intent,
      activityPaused: activityPaused,
      systemFrozen: systemFrozen,
      locale: locale,
    );
  }

  final PomodoroConfig config;
  final PomodoroPhase phase;
  final PomodoroIntent intent;
  final bool activityPaused;
  final bool systemFrozen;
  final AppLocale locale;

  @override
  bool operator ==(Object other) {
    return other is TrayMenuSyncBoundary &&
        other.config == config &&
        other.phase == phase &&
        other.intent == intent &&
        other.activityPaused == activityPaused &&
        other.systemFrozen == systemFrozen &&
        other.locale == locale;
  }

  @override
  int get hashCode =>
      Object.hash(config, phase, intent, activityPaused, systemFrozen, locale);
}

/// Pure admission gate for expensive tray synchronization requests.
///
/// Runtime [tickCount] is the cadence clock. It advances once per periodic
/// callback, including when the countdown is frozen or disabled, so the tray
/// can still discover an external tracking-pause change without polling FFI
/// every second. Forced requests are used immediately before opening a menu.
final class TrayMenuSyncGate {
  static const backgroundTickInterval = 10;

  TrayMenuSyncBoundary? _lastBoundary;
  int? _lastAcceptedTick;

  bool shouldRequest({
    required int tickCount,
    required TrayMenuSyncBoundary boundary,
    bool precise = false,
  }) {
    final normalizedTick = tickCount < 0 ? 0 : tickCount;
    final previousTick = _lastAcceptedTick;
    final cadenceElapsed =
        previousTick == null ||
        normalizedTick < previousTick ||
        normalizedTick - previousTick >= backgroundTickInterval;
    final boundaryChanged = boundary != _lastBoundary;
    if (!precise && !cadenceElapsed && !boundaryChanged) {
      return false;
    }

    _lastBoundary = boundary;
    _lastAcceptedTick = normalizedTick;
    return true;
  }
}

/// Serializes native tray writes, keeps only the latest queued state, and
/// skips a native update when the derived model has not changed.
///
/// The model resolver runs only when its request reaches the head of the
/// queue. This lets callers read volatile state such as tracking pause at the
/// last responsible moment instead of capturing a value that may go stale
/// while a previous native update is still in flight.
final class SerializedTrayMenuUpdater {
  SerializedTrayMenuUpdater({
    required TrayMenuModelWriter write,
    TrayMenuSyncErrorHandler? onError,
  }) : _write = write,
       _onError = onError;

  final TrayMenuModelWriter _write;
  final TrayMenuSyncErrorHandler? _onError;

  TrayMenuModelResolver? _pending;
  TrayMenuModel? _applied;
  Completer<void>? _idleCompleter;
  bool _draining = false;
  bool _disposed = false;

  TrayMenuModel? get appliedModel => _applied;
  bool get isDisposed => _disposed;

  /// Queues a model resolver and completes after all work queued in the same
  /// drain has settled. A newer pending request replaces an older pending one.
  Future<void> request(TrayMenuModelResolver resolve) {
    if (_disposed) {
      return Future<void>.value();
    }
    _pending = resolve;
    final idle = _idleCompleter ??= Completer<void>();
    _startDrain();
    return idle.future;
  }

  /// Stops accepting work and waits for the single in-flight native write.
  Future<void> dispose() {
    if (_disposed) {
      return _idleCompleter?.future ?? Future<void>.value();
    }
    _disposed = true;
    _pending = null;
    if (!_draining) {
      _completeIdle();
    }
    return _idleCompleter?.future ?? Future<void>.value();
  }

  void _startDrain() {
    if (_draining || _disposed) {
      return;
    }
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_disposed) {
        final resolve = _pending;
        if (resolve == null) {
          break;
        }
        _pending = null;
        try {
          final model = resolve();
          if (model != _applied) {
            await _write(model);
            if (!_disposed) {
              _applied = model;
            }
          }
        } catch (error, stackTrace) {
          try {
            _onError?.call(error, stackTrace);
          } catch (_) {
            // A diagnostics callback must never deadlock future tray updates.
          }
        }
      }
    } finally {
      _draining = false;
      if (!_disposed && _pending != null) {
        _startDrain();
      } else {
        _completeIdle();
      }
    }
  }

  void _completeIdle() {
    final idle = _idleCompleter;
    _idleCompleter = null;
    if (idle != null && !idle.isCompleted) {
      idle.complete();
    }
  }
}

String _pomodoroStatus({
  required bool enabled,
  required PomodoroState state,
  required bool systemFrozen,
  required ReminderL10n strings,
}) {
  if (!enabled) {
    return strings.pomodoroDisabled;
  }
  if (state.isIdle) {
    return strings.pomodoroReady;
  }

  final phase = switch (state.phase) {
    PomodoroPhase.idle => strings.pomodoro,
    PomodoroPhase.focus => strings.focus,
    PomodoroPhase.shortBreak => strings.shortBreak,
    PomodoroPhase.longBreak => strings.longBreak,
  };
  final intent = systemFrozen
      ? ' · ${strings.focusTimerFrozen}'
      : switch (state.intent) {
          PomodoroIntent.running => '',
          PomodoroIntent.ready => ' · ${strings.waitingToStart}',
          PomodoroIntent.userPaused => ' · ${strings.paused}',
        };
  return '$phase · ${_clock(state.remaining)}$intent';
}

List<TrayPomodoroAction> _pomodoroActions({
  required bool enabled,
  required PomodoroState state,
  required ReminderL10n strings,
}) {
  if (!enabled) {
    return const [];
  }
  if (state.isIdle) {
    return [
      TrayPomodoroAction(
        key: TrayMenuKeys.pomodoroStart,
        label: strings.startPomodoro,
      ),
    ];
  }

  final primary = state.isRunning
      ? TrayPomodoroAction(
          key: TrayMenuKeys.pomodoroPause,
          label: strings.pausePomodoro,
        )
      : TrayPomodoroAction(
          key: TrayMenuKeys.pomodoroResume,
          label: state.intent == PomodoroIntent.ready
              ? strings.startCurrentPhase
              : strings.resumePomodoro,
        );
  return [
    primary,
    TrayPomodoroAction(
      key: TrayMenuKeys.pomodoroSkip,
      label: strings.skipCurrentPhase,
    ),
    TrayPomodoroAction(
      key: TrayMenuKeys.pomodoroStop,
      label: strings.stopPomodoro,
    ),
  ];
}

String _clock(Duration duration) {
  var seconds = duration.inSeconds;
  if (seconds < 0) {
    seconds = 0;
  }
  final hours = seconds ~/ Duration.secondsPerHour;
  final minutes =
      (seconds % Duration.secondsPerHour) ~/ Duration.secondsPerMinute;
  final remainder = seconds % Duration.secondsPerMinute;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

bool _actionsEqual(
  List<TrayPomodoroAction> first,
  List<TrayPomodoroAction> second,
) {
  if (identical(first, second)) {
    return true;
  }
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}
