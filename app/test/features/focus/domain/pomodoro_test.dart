import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

void main() {
  const engine = PomodoroEngine();

  test('configuration defaults are quiet and match the product contract', () {
    const config = PomodoroConfig();

    expect(config.enabled, isFalse);
    expect(config.focusDuration, const Duration(minutes: 25));
    expect(config.shortBreakDuration, const Duration(minutes: 5));
    expect(config.longBreakDuration, const Duration(minutes: 15));
    expect(config.longBreakInterval, 4);
    expect(config.autoStartNext, isFalse);
    expect(config.notificationsEnabled, isTrue);
    expect(config.soundEnabled, isTrue);
    expect(config.isValid, isTrue);
  });

  test('start enters focus and ready next phase can start or resume', () {
    final started = engine.reduce(
      const PomodoroState.initial(),
      const PomodoroStart(),
      _config,
    );

    expect(started.state.phase, PomodoroPhase.focus);
    expect(started.state.intent, PomodoroIntent.running);
    expect(started.state.remaining, const Duration(seconds: 2));
    expect(started.state.phaseDuration, const Duration(seconds: 2));

    final breakReady = engine.reduce(
      started.state,
      const PomodoroTick(elapsed: Duration(seconds: 2)),
      _config,
    );
    expect(breakReady.state.intent, PomodoroIntent.ready);
    expect(
      engine
          .reduce(breakReady.state, const PomodoroStart(), _config)
          .state
          .intent,
      PomodoroIntent.running,
    );
    expect(
      engine
          .reduce(breakReady.state, const PomodoroResume(), _config)
          .state
          .intent,
      PomodoroIntent.running,
    );
  });

  test('pause and resume preserve phase and remaining time', () {
    var state = engine
        .reduce(const PomodoroState.initial(), const PomodoroStart(), _config)
        .state;
    state = engine
        .reduce(
          state,
          const PomodoroTick(elapsed: Duration(seconds: 1)),
          _config,
        )
        .state;
    final paused = engine.reduce(state, const PomodoroPause(), _config).state;
    final ignoredTick = engine
        .reduce(
          paused,
          const PomodoroTick(elapsed: Duration(seconds: 1)),
          _config,
        )
        .state;

    expect(paused.intent, PomodoroIntent.userPaused);
    expect(ignoredTick.remaining, const Duration(seconds: 1));
    expect(
      engine.reduce(paused, const PomodoroResume(), _config).state.intent,
      PomodoroIntent.running,
    );
  });

  test('system gating freezes without overwriting a later user pause', () {
    final running = engine
        .reduce(const PomodoroState.initial(), const PomodoroStart(), _config)
        .state;
    final frozen = engine
        .reduce(
          running,
          const PomodoroTick(
            elapsed: Duration(seconds: 2),
            systemEligible: false,
          ),
          _config,
        )
        .state;
    final userPaused = engine
        .reduce(frozen, const PomodoroPause(), _config)
        .state;
    final activeAgain = engine
        .reduce(
          userPaused,
          const PomodoroTick(elapsed: Duration(seconds: 1)),
          _config,
        )
        .state;

    expect(frozen.intent, PomodoroIntent.running);
    expect(frozen.remaining, const Duration(seconds: 2));
    expect(activeAgain.intent, PomodoroIntent.userPaused);
    expect(activeAgain.remaining, const Duration(seconds: 2));
  });

  test('explicit and oversized callback gaps contribute zero', () {
    final running = engine
        .reduce(const PomodoroState.initial(), const PomodoroStart(), _config)
        .state;

    final explicitGap = engine
        .reduce(running, const PomodoroGap(), _config)
        .state;
    final flaggedTick = engine
        .reduce(
          explicitGap,
          const PomodoroTick(elapsed: Duration(seconds: 1), isGap: true),
          _config,
        )
        .state;
    final oversized = engine
        .reduce(
          flaggedTick,
          const PomodoroTick(elapsed: Duration(milliseconds: 2501)),
          _config,
        )
        .state;

    expect(explicitGap, running);
    expect(flaggedTick, running);
    expect(oversized, running);
  });

  test('four natural focus completions select the long break exactly once', () {
    var state = const PomodoroState.initial();

    for (var cycle = 1; cycle <= 4; cycle++) {
      state = engine.reduce(state, const PomodoroStart(), _config).state;
      final completed = engine.reduce(
        state,
        const PomodoroTick(elapsed: Duration(seconds: 2)),
        _config,
      );

      expect(completed.state.completedFocusCount, cycle);
      expect(
        completed.state.phase,
        cycle == 4 ? PomodoroPhase.longBreak : PomodoroPhase.shortBreak,
      );
      expect(completed.state.intent, PomodoroIntent.ready);
      expect(completed.effects, hasLength(1));
      final effect = completed.effects.single as PomodoroNotificationEffect;
      expect(effect.completedPhase, PomodoroPhase.focus);
      expect(effect.nextPhase, completed.state.phase);

      state = engine
          .reduce(completed.state, const PomodoroSkip(), _config)
          .state;
      expect(state.phase, PomodoroPhase.focus);
      expect(state.completedFocusCount, cycle);
    }
  });

  test('skipping focus selects short break without count or notification', () {
    final running = engine
        .reduce(const PomodoroState.initial(), const PomodoroStart(), _config)
        .state
        .copyWith(completedFocusCount: 3);
    final skipped = engine.reduce(running, const PomodoroSkip(), _config);

    expect(skipped.state.phase, PomodoroPhase.shortBreak);
    expect(skipped.state.completedFocusCount, 3);
    expect(skipped.effects, isEmpty);
  });

  test('break completion returns to focus without incrementing count', () {
    const autoConfig = PomodoroConfig(
      enabled: true,
      focusDuration: Duration(seconds: 1),
      shortBreakDuration: Duration(seconds: 1),
      longBreakDuration: Duration(seconds: 1),
      autoStartNext: true,
    );
    var state = engine
        .reduce(
          const PomodoroState.initial(),
          const PomodoroStart(),
          autoConfig,
        )
        .state;
    state = engine
        .reduce(
          state,
          const PomodoroTick(elapsed: Duration(seconds: 1)),
          autoConfig,
        )
        .state;
    expect(state.phase, PomodoroPhase.shortBreak);
    expect(state.intent, PomodoroIntent.running);

    final focus = engine.reduce(
      state,
      const PomodoroTick(elapsed: Duration(seconds: 1)),
      autoConfig,
    );
    expect(focus.state.phase, PomodoroPhase.focus);
    expect(focus.state.intent, PomodoroIntent.running);
    expect(focus.state.completedFocusCount, 1);
  });

  test('notification preference affects effects but not transitions', () {
    const silentConfig = PomodoroConfig(
      enabled: true,
      focusDuration: Duration(seconds: 1),
      shortBreakDuration: Duration(seconds: 2),
      longBreakDuration: Duration(seconds: 3),
      notificationsEnabled: false,
    );
    final running = engine
        .reduce(
          const PomodoroState.initial(),
          const PomodoroStart(),
          silentConfig,
        )
        .state;
    final completed = engine.reduce(
      running,
      const PomodoroTick(elapsed: Duration(seconds: 1)),
      silentConfig,
    );

    expect(completed.state.phase, PomodoroPhase.shortBreak);
    expect(completed.effects, isEmpty);
  });

  test('edited durations affect the next phase but not current countdown', () {
    final running = engine
        .reduce(const PomodoroState.initial(), const PomodoroStart(), _config)
        .state;
    const edited = PomodoroConfig(
      enabled: true,
      focusDuration: Duration(seconds: 40),
      shortBreakDuration: Duration(seconds: 9),
      longBreakDuration: Duration(seconds: 12),
    );
    final ticking = engine.reduce(
      running,
      const PomodoroTick(elapsed: Duration(seconds: 1)),
      edited,
    );

    expect(ticking.state.remaining, const Duration(seconds: 1));
    expect(ticking.state.phaseDuration, const Duration(seconds: 2));
    final completed = engine.reduce(
      ticking.state,
      const PomodoroTick(elapsed: Duration(seconds: 1)),
      edited,
    );
    expect(completed.state.remaining, const Duration(seconds: 9));
    expect(completed.state.phaseDuration, const Duration(seconds: 9));
  });

  test('stop retains cycle progress while reset clears it', () {
    const state = PomodoroState(
      phase: PomodoroPhase.focus,
      intent: PomodoroIntent.running,
      remaining: Duration(seconds: 3),
      completedFocusCount: 2,
    );

    final stopped = engine.reduce(state, const PomodoroStop(), _config).state;
    final reset = engine.reduce(state, const PomodoroReset(), _config).state;

    expect(stopped.phase, PomodoroPhase.idle);
    expect(stopped.completedFocusCount, 2);
    expect(reset, const PomodoroState.initial());
  });

  test('disabled configuration returns runtime to idle and retains count', () {
    const state = PomodoroState(
      phase: PomodoroPhase.longBreak,
      intent: PomodoroIntent.running,
      remaining: Duration(seconds: 2),
      completedFocusCount: 4,
    );

    final disabled = engine.reduce(
      state,
      const PomodoroTick(elapsed: Duration(seconds: 1)),
      const PomodoroConfig(),
    );

    expect(disabled.state.phase, PomodoroPhase.idle);
    expect(disabled.state.completedFocusCount, 4);
    expect(disabled.effects, isEmpty);
  });
}

const _config = PomodoroConfig(
  enabled: true,
  focusDuration: Duration(seconds: 2),
  shortBreakDuration: Duration(seconds: 1),
  longBreakDuration: Duration(seconds: 2),
);
