import '../../reminders/domain/reminder_timing.dart';

/// A Pomodoro phase. [idle] has no active countdown.
enum PomodoroPhase { idle, focus, shortBreak, longBreak }

/// The user's explicit countdown intent.
///
/// System eligibility is deliberately not stored here. Idle/lock/tracking
/// pause is a tick gate, so it can never erase a user's manual pause.
enum PomodoroIntent { ready, running, userPaused }

/// Persisted Pomodoro configuration consumed by the pure engine.
final class PomodoroConfig {
  const PomodoroConfig({
    this.enabled = false,
    this.focusDuration = const Duration(minutes: 25),
    this.shortBreakDuration = const Duration(minutes: 5),
    this.longBreakDuration = const Duration(minutes: 15),
    this.longBreakInterval = 4,
    this.autoStartNext = false,
    this.notificationsEnabled = true,
    this.soundEnabled = true,
  });

  final bool enabled;
  final Duration focusDuration;
  final Duration shortBreakDuration;
  final Duration longBreakDuration;
  final int longBreakInterval;
  final bool autoStartNext;
  final bool notificationsEnabled;
  final bool soundEnabled;

  /// Whether every persisted numeric setting is valid.
  bool get isValid =>
      focusDuration > Duration.zero &&
      shortBreakDuration > Duration.zero &&
      longBreakDuration > Duration.zero &&
      longBreakInterval > 0;

  @override
  bool operator ==(Object other) {
    return other is PomodoroConfig &&
        other.enabled == enabled &&
        other.focusDuration == focusDuration &&
        other.shortBreakDuration == shortBreakDuration &&
        other.longBreakDuration == longBreakDuration &&
        other.longBreakInterval == longBreakInterval &&
        other.autoStartNext == autoStartNext &&
        other.notificationsEnabled == notificationsEnabled &&
        other.soundEnabled == soundEnabled;
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    focusDuration,
    shortBreakDuration,
    longBreakDuration,
    longBreakInterval,
    autoStartNext,
    notificationsEnabled,
    soundEnabled,
  );
}

/// Immutable transient Pomodoro runtime state.
final class PomodoroState {
  const PomodoroState({
    required this.phase,
    required this.intent,
    required this.remaining,
    required this.completedFocusCount,
    this.phaseDuration = Duration.zero,
  });

  const PomodoroState.initial()
    : phase = PomodoroPhase.idle,
      intent = PomodoroIntent.ready,
      remaining = Duration.zero,
      phaseDuration = Duration.zero,
      completedFocusCount = 0;

  final PomodoroPhase phase;
  final PomodoroIntent intent;
  final Duration remaining;

  /// Total duration captured when the current phase was entered.
  ///
  /// This is runtime state rather than a live configuration lookup, so edits
  /// cannot change the progress denominator of an in-flight phase.
  final Duration phaseDuration;
  final int completedFocusCount;

  bool get isIdle => phase == PomodoroPhase.idle;
  bool get isRunning => !isIdle && intent == PomodoroIntent.running;

  PomodoroState copyWith({
    PomodoroPhase? phase,
    PomodoroIntent? intent,
    Duration? remaining,
    Duration? phaseDuration,
    int? completedFocusCount,
  }) {
    return PomodoroState(
      phase: phase ?? this.phase,
      intent: intent ?? this.intent,
      remaining: remaining ?? this.remaining,
      phaseDuration: phaseDuration ?? this.phaseDuration,
      completedFocusCount: completedFocusCount ?? this.completedFocusCount,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PomodoroState &&
        other.phase == phase &&
        other.intent == intent &&
        other.remaining == remaining &&
        other.phaseDuration == phaseDuration &&
        other.completedFocusCount == completedFocusCount;
  }

  @override
  int get hashCode =>
      Object.hash(phase, intent, remaining, phaseDuration, completedFocusCount);
}

/// A command or observation accepted by [PomodoroEngine].
sealed class PomodoroEvent {
  const PomodoroEvent();
}

final class PomodoroStart extends PomodoroEvent {
  const PomodoroStart();
}

final class PomodoroPause extends PomodoroEvent {
  const PomodoroPause();
}

final class PomodoroResume extends PomodoroEvent {
  const PomodoroResume();
}

final class PomodoroSkip extends PomodoroEvent {
  const PomodoroSkip();
}

final class PomodoroStop extends PomodoroEvent {
  const PomodoroStop();
}

final class PomodoroReset extends PomodoroEvent {
  const PomodoroReset();
}

/// A callback carrying monotonic elapsed time and current system eligibility.
final class PomodoroTick extends PomodoroEvent {
  const PomodoroTick({
    required this.elapsed,
    this.systemEligible = true,
    this.isGap = false,
  });

  final Duration elapsed;
  final bool systemEligible;
  final bool isGap;
}

/// An explicit sleep/freeze boundary which contributes no countdown time.
final class PomodoroGap extends PomodoroEvent {
  const PomodoroGap();
}

/// A side effect requested by a pure Pomodoro transition.
sealed class PomodoroEffect {
  const PomodoroEffect();
}

/// Requests one privacy-safe phase transition notification.
final class PomodoroNotificationEffect extends PomodoroEffect {
  const PomodoroNotificationEffect({
    required this.completedPhase,
    required this.nextPhase,
    required this.nextPhaseDuration,
    required this.soundEnabled,
  });

  final PomodoroPhase completedPhase;
  final PomodoroPhase nextPhase;
  final Duration nextPhaseDuration;
  final bool soundEnabled;

  @override
  bool operator ==(Object other) {
    return other is PomodoroNotificationEffect &&
        other.completedPhase == completedPhase &&
        other.nextPhase == nextPhase &&
        other.nextPhaseDuration == nextPhaseDuration &&
        other.soundEnabled == soundEnabled;
  }

  @override
  int get hashCode =>
      Object.hash(completedPhase, nextPhase, nextPhaseDuration, soundEnabled);
}

/// The immutable result of reducing one [PomodoroEvent].
final class PomodoroTransition {
  PomodoroTransition({
    required this.state,
    List<PomodoroEffect> effects = const [],
  }) : effects = List.unmodifiable(effects);

  final PomodoroState state;
  final List<PomodoroEffect> effects;
}

/// Pure deterministic Pomodoro state machine.
final class PomodoroEngine {
  const PomodoroEngine();

  PomodoroTransition reduce(
    PomodoroState state,
    PomodoroEvent event,
    PomodoroConfig config,
  ) {
    if (event is PomodoroReset) {
      return _transition(_idle(completedFocusCount: 0));
    }
    if (event is PomodoroStop) {
      return _transition(_idle(completedFocusCount: state.completedFocusCount));
    }

    // Disabling the feature clears transient phase state while preserving the
    // in-process completed count, matching Stop rather than Reset semantics.
    if (!config.enabled) {
      return _transition(_idle(completedFocusCount: state.completedFocusCount));
    }

    if (event is PomodoroStart) {
      return _start(state, config);
    }
    if (event is PomodoroPause) {
      return state.isRunning
          ? _transition(state.copyWith(intent: PomodoroIntent.userPaused))
          : _transition(state);
    }
    if (event is PomodoroResume) {
      final canResume =
          !state.isIdle &&
          (state.intent == PomodoroIntent.userPaused ||
              state.intent == PomodoroIntent.ready);
      return canResume
          ? _transition(state.copyWith(intent: PomodoroIntent.running))
          : _transition(state);
    }
    if (event is PomodoroSkip) {
      return state.isIdle
          ? _transition(state)
          : _advancePhase(state, config, naturallyCompleted: false);
    }
    if (event is PomodoroGap) {
      return _transition(state);
    }
    if (event is PomodoroTick) {
      return _tick(state, event, config);
    }

    return _transition(state);
  }

  PomodoroTransition _start(PomodoroState state, PomodoroConfig config) {
    if (state.isIdle) {
      return _transition(
        PomodoroState(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
          remaining: _positive(config.focusDuration),
          phaseDuration: _positive(config.focusDuration),
          completedFocusCount: state.completedFocusCount,
        ),
      );
    }
    if (state.intent == PomodoroIntent.ready) {
      return _transition(state.copyWith(intent: PomodoroIntent.running));
    }
    return _transition(state);
  }

  PomodoroTransition _tick(
    PomodoroState state,
    PomodoroTick event,
    PomodoroConfig config,
  ) {
    final contributes =
        state.isRunning &&
        event.systemEligible &&
        reminderDeltaContributes(event.elapsed, isGap: event.isGap);
    if (!contributes) {
      return _transition(state);
    }

    if (event.elapsed < state.remaining) {
      return _transition(
        state.copyWith(remaining: state.remaining - event.elapsed),
      );
    }

    return _advancePhase(state, config, naturallyCompleted: true);
  }

  PomodoroTransition _advancePhase(
    PomodoroState state,
    PomodoroConfig config, {
    required bool naturallyCompleted,
  }) {
    final completedPhase = state.phase;
    var completedFocusCount = state.completedFocusCount;
    late final PomodoroPhase nextPhase;

    if (completedPhase == PomodoroPhase.focus) {
      if (naturallyCompleted) {
        completedFocusCount++;
        final interval = config.longBreakInterval > 0
            ? config.longBreakInterval
            : 1;
        nextPhase = completedFocusCount % interval == 0
            ? PomodoroPhase.longBreak
            : PomodoroPhase.shortBreak;
      } else {
        // A skipped focus is never counted and always selects a short break.
        nextPhase = PomodoroPhase.shortBreak;
      }
    } else {
      nextPhase = PomodoroPhase.focus;
    }

    final nextDuration = _durationFor(nextPhase, config);
    final nextState = PomodoroState(
      phase: nextPhase,
      intent: config.autoStartNext
          ? PomodoroIntent.running
          : PomodoroIntent.ready,
      remaining: nextDuration,
      phaseDuration: nextDuration,
      completedFocusCount: completedFocusCount,
    );
    final effects = naturallyCompleted && config.notificationsEnabled
        ? <PomodoroEffect>[
            PomodoroNotificationEffect(
              completedPhase: completedPhase,
              nextPhase: nextPhase,
              nextPhaseDuration: nextDuration,
              soundEnabled: config.soundEnabled,
            ),
          ]
        : const <PomodoroEffect>[];
    return PomodoroTransition(state: nextState, effects: effects);
  }

  Duration _durationFor(PomodoroPhase phase, PomodoroConfig config) {
    return switch (phase) {
      PomodoroPhase.focus => _positive(config.focusDuration),
      PomodoroPhase.shortBreak => _positive(config.shortBreakDuration),
      PomodoroPhase.longBreak => _positive(config.longBreakDuration),
      PomodoroPhase.idle => Duration.zero,
    };
  }

  Duration _positive(Duration value) {
    return value > Duration.zero ? value : const Duration(seconds: 1);
  }

  PomodoroState _idle({required int completedFocusCount}) {
    return PomodoroState(
      phase: PomodoroPhase.idle,
      intent: PomodoroIntent.ready,
      remaining: Duration.zero,
      phaseDuration: Duration.zero,
      completedFocusCount: completedFocusCount,
    );
  }

  PomodoroTransition _transition(PomodoroState state) {
    return PomodoroTransition(state: state);
  }
}
