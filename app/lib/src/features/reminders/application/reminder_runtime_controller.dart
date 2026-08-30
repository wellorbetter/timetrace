import 'dart:async';
import 'dart:developer' as developer;

import '../../../core/i18n/reminder_l10n.dart';
import '../../../core/notifications/notification_message.dart';
import '../../../core/notifications/notification_port.dart';
import '../../app_limits/domain/activity_snapshot.dart';
import '../../app_limits/domain/continuous_use.dart';
import '../../focus/domain/pomodoro.dart';
import '../domain/reminder_timing.dart';
import 'reminder_sources.dart';

/// Monotonic clock used to classify delayed callbacks without wall-clock jumps.
abstract interface class ReminderMonotonicClock {
  Duration get elapsed;
}

/// A cancellable periodic callback owned by [ReminderRuntimeController].
abstract interface class ReminderPeriodicTask {
  bool get isActive;

  void cancel();
}

typedef ReminderPeriodicTaskFactory =
    ReminderPeriodicTask Function(Duration interval, void Function() callback);

typedef ReminderRuntimeListener = void Function(ReminderRuntimeState state);

/// Immutable public projection of the reminder runtime.
final class ReminderRuntimeState {
  const ReminderRuntimeState({
    required this.pomodoro,
    required this.continuousUse,
    required this.activity,
    required this.configuration,
    required this.notificationHealth,
    required this.tickCount,
    required this.lastCallbackWasGap,
  });

  final PomodoroState pomodoro;
  final ContinuousUseState continuousUse;
  final ActivitySnapshot? activity;
  final ReminderConfigurationSnapshot configuration;
  final NotificationHealth notificationHealth;
  final int tickCount;
  final bool lastCallbackWasGap;
}

/// The process-wide coordinator for real-time reminder features.
///
/// It owns one periodic callback, reads configuration once per tick and
/// activity at most once when a reminder capability needs it, advances the
/// pure engines, publishes state synchronously, and delivers notification
/// effects without coupling domain transitions to plugin success.
final class ReminderRuntimeController {
  ReminderRuntimeController({
    required ActivitySnapshotSource activitySource,
    required ReminderConfigurationSource configurationSource,
    required NotificationPort notificationPort,
    ReminderMonotonicClock? clock,
    ReminderPeriodicTaskFactory? periodicTaskFactory,
    PomodoroEngine pomodoroEngine = const PomodoroEngine(),
    ContinuousUseEvaluator continuousUseEvaluator =
        const ContinuousUseEvaluator(),
  }) : _activitySource = activitySource,
       _configurationSource = configurationSource,
       _notificationPort = notificationPort,
       _clock = clock ?? _StopwatchReminderClock(),
       _periodicTaskFactory =
           periodicTaskFactory ?? _DartReminderPeriodicTask.new,
       _pomodoroEngine = pomodoroEngine,
       _continuousUseEvaluator = continuousUseEvaluator,
       _configuration = ReminderConfigurationSnapshot.disabled(),
       _state = ReminderRuntimeState(
         pomodoro: const PomodoroState.initial(),
         continuousUse: const ContinuousUseState.empty(),
         activity: null,
         configuration: ReminderConfigurationSnapshot.disabled(),
         notificationHealth: notificationPort.health,
         tickCount: 0,
         lastCallbackWasGap: false,
       );

  static const tickInterval = Duration(seconds: 1);

  final ActivitySnapshotSource _activitySource;
  final ReminderConfigurationSource _configurationSource;
  final NotificationPort _notificationPort;
  final ReminderMonotonicClock _clock;
  final ReminderPeriodicTaskFactory _periodicTaskFactory;
  final PomodoroEngine _pomodoroEngine;
  final ContinuousUseEvaluator _continuousUseEvaluator;
  final List<ReminderRuntimeListener> _listeners = [];

  late ReminderConfigurationSnapshot _configuration;
  late ReminderRuntimeState _state;
  ReminderPeriodicTask? _periodicTask;
  Duration? _lastCallbackAt;
  int _notificationDeliveryGeneration = 0;
  bool _disposed = false;

  ReminderRuntimeState get state => _state;
  bool get isStarted => _periodicTask?.isActive ?? false;
  bool get isDisposed => _disposed;

  /// Starts the sole one-second periodic callback. Repeated calls are no-ops.
  void start() {
    if (_disposed || isStarted) {
      return;
    }
    _lastCallbackAt = _clock.elapsed;
    _periodicTask = _periodicTaskFactory(tickInterval, _onPeriodicCallback);
  }

  /// Adds a synchronous state listener if it has not already been registered.
  void addListener(ReminderRuntimeListener listener) {
    if (!_disposed && !_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// Removes a previously registered state listener.
  void removeListener(ReminderRuntimeListener listener) {
    _listeners.remove(listener);
  }

  /// Deterministically advances both reminder engines by one callback delta.
  ///
  /// Tests and non-timer integrations may call this directly. Configuration is
  /// read exactly once; activity is read exactly once unless both capabilities
  /// are disabled. Deltas over 2.5 seconds are gap boundaries.
  void advance(Duration elapsed) {
    if (_disposed) {
      return;
    }

    final configuration = _readConfiguration();
    final callbackGap =
        elapsed.isNegative || elapsed > reminderCallbackGapTolerance;
    if (!configuration.pomodoro.enabled && !configuration.appTimeoutEnabled) {
      _advanceFullyDisabled(configuration, callbackGap: callbackGap);
      return;
    }

    final activity = _readActivitySnapshot();
    final pomodoroEligible =
        activity.state == ActivitySnapshotState.active ||
        activity.state == ActivitySnapshotState.excluded;

    final pomodoroTransition = _pomodoroEngine.reduce(
      _state.pomodoro,
      PomodoroTick(
        elapsed: elapsed,
        systemEligible: pomodoroEligible,
        isGap: callbackGap,
      ),
      configuration.pomodoro,
    );

    final ContinuousUseTransition continuousTransition;
    if (configuration.appTimeoutEnabled) {
      continuousTransition = _continuousUseEvaluator.advance(
        state: _state.continuousUse,
        snapshot: activity,
        rules: configuration.appTimeoutRules,
        elapsed: elapsed,
        rulesRevision: configuration.rulesRevision,
        isGap: callbackGap,
      );
    } else {
      continuousTransition = ContinuousUseTransition(
        state: ContinuousUseState.empty(
          rulesRevision: configuration.rulesRevision,
        ),
      );
    }

    _state = ReminderRuntimeState(
      pomodoro: pomodoroTransition.state,
      continuousUse: continuousTransition.state,
      activity: activity,
      configuration: configuration,
      notificationHealth: _notificationPort.health,
      tickCount: _state.tickCount + 1,
      lastCallbackWasGap: callbackGap,
    );
    _publish();
    final strings = ReminderL10n(configuration.locale);
    _deliverPomodoroEffects(pomodoroTransition.effects, strings: strings);
    if (configuration.appTimeoutNotificationsEnabled) {
      _deliverContinuousUseEffects(
        continuousTransition.effects,
        sound: configuration.appTimeoutNotificationSound,
        strings: strings,
      );
    }
  }

  void _advanceFullyDisabled(
    ReminderConfigurationSnapshot configuration, {
    required bool callbackGap,
  }) {
    final currentPomodoro = _state.pomodoro;
    final pomodoro = currentPomodoro.isIdle
        ? currentPomodoro
        : _pomodoroEngine
              .reduce(
                currentPomodoro,
                const PomodoroTick(elapsed: Duration.zero),
                configuration.pomodoro,
              )
              .state;
    final currentContinuousUse = _state.continuousUse;
    final continuousUse =
        !currentContinuousUse.hasSegment &&
            currentContinuousUse.rulesRevision == configuration.rulesRevision
        ? currentContinuousUse
        : ContinuousUseState.empty(rulesRevision: configuration.rulesRevision);

    _state = ReminderRuntimeState(
      pomodoro: pomodoro,
      continuousUse: continuousUse,
      activity: null,
      configuration: configuration,
      notificationHealth: _notificationPort.health,
      tickCount: _state.tickCount + 1,
      lastCallbackWasGap: callbackGap,
    );
    _publish();
  }

  void startPomodoro() => _dispatchPomodoro(const PomodoroStart());
  void pausePomodoro() => _dispatchPomodoro(const PomodoroPause());
  void resumePomodoro() => _dispatchPomodoro(const PomodoroResume());
  void skipPomodoro() => _dispatchPomodoro(const PomodoroSkip());
  void stopPomodoro() => _dispatchPomodoro(const PomodoroStop());
  void resetPomodoro() => _dispatchPomodoro(const PomodoroReset());

  /// Cancels the sole periodic callback and detaches listeners exactly once.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _periodicTask?.cancel();
    _periodicTask = null;
    _lastCallbackAt = null;
    _listeners.clear();
  }

  void _onPeriodicCallback() {
    if (_disposed) {
      return;
    }
    final now = _clock.elapsed;
    final previous = _lastCallbackAt;
    _lastCallbackAt = now;
    advance(previous == null ? Duration.zero : now - previous);
  }

  void _dispatchPomodoro(PomodoroEvent event) {
    if (_disposed) {
      return;
    }
    final configuration = _readConfiguration();
    final transition = _pomodoroEngine.reduce(
      _state.pomodoro,
      event,
      configuration.pomodoro,
    );
    _state = ReminderRuntimeState(
      pomodoro: transition.state,
      continuousUse: _state.continuousUse,
      activity: _state.activity,
      configuration: configuration,
      notificationHealth: _notificationPort.health,
      tickCount: _state.tickCount,
      lastCallbackWasGap: _state.lastCallbackWasGap,
    );
    _publish();
    _deliverPomodoroEffects(
      transition.effects,
      strings: ReminderL10n(configuration.locale),
    );
  }

  ReminderConfigurationSnapshot _readConfiguration() {
    try {
      _configuration = _configurationSource.readReminderConfiguration();
    } catch (_) {
      developer.log(
        'Reminder configuration read failed; retaining last snapshot.',
        name: 'TimeTrace.reminders',
        level: 900,
      );
    }
    return _configuration;
  }

  ActivitySnapshot _readActivitySnapshot() {
    try {
      return _activitySource.readActivitySnapshot();
    } catch (_) {
      developer.log(
        'Activity snapshot read failed; treating activity as unavailable.',
        name: 'TimeTrace.reminders',
        level: 900,
      );
      final previous = _state.activity;
      return ActivitySnapshot.unavailable(
        revision: (previous?.revision ?? 0) + 1,
        observedAt:
            previous?.observedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
  }

  void _deliverPomodoroEffects(
    List<PomodoroEffect> effects, {
    required ReminderL10n strings,
  }) {
    for (final effect in effects) {
      if (effect is PomodoroNotificationEffect) {
        _queueNotification(_pomodoroMessage(effect, strings));
      }
    }
  }

  void _deliverContinuousUseEffects(
    List<ContinuousUseEffect> effects, {
    required bool sound,
    required ReminderL10n strings,
  }) {
    for (final effect in effects) {
      if (effect is AppTimeoutNotificationEffect) {
        _queueNotification(
          NotificationMessage.appTimeout(
            appName: effect.applicationName,
            activeMinutes: effect.roundedMinutes,
            sound: sound,
            strings: strings,
          ),
        );
      }
    }
  }

  NotificationMessage _pomodoroMessage(
    PomodoroNotificationEffect effect,
    ReminderL10n strings,
  ) {
    final nextMinutes = _roundedMinutes(effect.nextPhaseDuration);
    return switch (effect.completedPhase) {
      PomodoroPhase.focus => NotificationMessage(
        kind: NotificationKind.pomodoroFocusComplete,
        title: strings.focusCompleteTitle,
        body: strings.focusCompleteBody(nextMinutes),
        sound: effect.soundEnabled,
        payload: 'pomodoro-focus-complete',
      ),
      PomodoroPhase.shortBreak => NotificationMessage(
        kind: NotificationKind.pomodoroShortBreakComplete,
        title: strings.shortBreakCompleteTitle,
        body: strings.shortBreakCompleteBody(nextMinutes),
        sound: effect.soundEnabled,
        payload: 'pomodoro-short-break-complete',
      ),
      PomodoroPhase.longBreak => NotificationMessage(
        kind: NotificationKind.pomodoroLongBreakComplete,
        title: strings.longBreakCompleteTitle,
        body: strings.longBreakCompleteBody(nextMinutes),
        sound: effect.soundEnabled,
        payload: 'pomodoro-long-break-complete',
      ),
      PomodoroPhase.idle => NotificationMessage(
        kind: NotificationKind.pomodoroFocusComplete,
        title: strings.pomodoroUpdatedTitle,
        body: strings.pomodoroUpdatedBody,
        sound: effect.soundEnabled,
        payload: 'pomodoro-transition',
      ),
    };
  }

  int _roundedMinutes(Duration duration) {
    final rounded = (duration.inSeconds / Duration.secondsPerMinute).round();
    return rounded < 1 ? 1 : rounded;
  }

  void _queueNotification(NotificationMessage message) {
    final generation = ++_notificationDeliveryGeneration;
    unawaited(_deliverNotification(message, generation));
  }

  Future<void> _deliverNotification(
    NotificationMessage message,
    int generation,
  ) async {
    try {
      final result = await _notificationPort.show(message);
      if (!_disposed && generation == _notificationDeliveryGeneration) {
        _updateNotificationHealth(
          _authoritativeNotificationHealth(_healthFor(result)),
        );
      }
    } catch (_) {
      developer.log(
        'Reminder notification delivery failed.',
        name: 'TimeTrace.reminders',
        level: 900,
      );
      if (!_disposed && generation == _notificationDeliveryGeneration) {
        _updateNotificationHealth(
          _authoritativeNotificationHealth(
            const NotificationHealth(
              NotificationHealthStatus.failed,
              errorCode: 'delivery_failed',
            ),
          ),
        );
      }
    }
  }

  NotificationHealth _healthFor(NotificationDeliveryResult result) {
    return switch (result.status) {
      NotificationDeliveryStatus.delivered ||
      NotificationDeliveryStatus.ready => const NotificationHealth(
        NotificationHealthStatus.ready,
      ),
      NotificationDeliveryStatus.denied => NotificationHealth(
        NotificationHealthStatus.denied,
        errorCode: result.errorCode,
      ),
      NotificationDeliveryStatus.unavailable ||
      NotificationDeliveryStatus.failed => NotificationHealth(
        NotificationHealthStatus.failed,
        errorCode: result.errorCode,
      ),
    };
  }

  NotificationHealth _authoritativeNotificationHealth(
    NotificationHealth fallback,
  ) {
    final current = _notificationPort.health;
    return current.status == NotificationHealthStatus.uninitialized
        ? fallback
        : current;
  }

  void _updateNotificationHealth(NotificationHealth health) {
    _state = ReminderRuntimeState(
      pomodoro: _state.pomodoro,
      continuousUse: _state.continuousUse,
      activity: _state.activity,
      configuration: _state.configuration,
      notificationHealth: health,
      tickCount: _state.tickCount,
      lastCallbackWasGap: _state.lastCallbackWasGap,
    );
    _publish();
  }

  void _publish() {
    for (final listener in List<ReminderRuntimeListener>.of(_listeners)) {
      try {
        listener(_state);
      } catch (_) {
        developer.log(
          'Reminder runtime listener failed.',
          name: 'TimeTrace.reminders',
          level: 900,
        );
      }
    }
  }
}

final class _StopwatchReminderClock implements ReminderMonotonicClock {
  _StopwatchReminderClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get elapsed => _stopwatch.elapsed;
}

final class _DartReminderPeriodicTask implements ReminderPeriodicTask {
  _DartReminderPeriodicTask(Duration interval, void Function() callback)
    : _timer = Timer.periodic(interval, (_) => callback());

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}
