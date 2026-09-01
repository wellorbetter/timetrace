import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';

void main() {
  const evaluator = ContinuousUseEvaluator();

  test('rules match normalized executable identity and validate inputs', () {
    expect(_ruleA.isValid, isTrue);
    expect(_ruleA.matches(_appA), isTrue);
    expect(_ruleA.matches(_appB), isFalse);
    expect(
      const AppTimeoutRule(
        id: 0,
        executablePath: '',
        displayName: '',
        threshold: Duration.zero,
        cooldown: Duration.zero,
        enabled: true,
        repeatEnabled: false,
      ).isValid,
      isFalse,
    );
  });

  test('first sample starts at zero and threshold emits exactly once', () {
    var transition = evaluator.advance(
      state: const ContinuousUseState.empty(),
      snapshot: _active(_appA),
      rules: const [_ruleA],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
    );
    expect(transition.state.elapsed, Duration.zero);
    expect(transition.effects, isEmpty);

    transition = _advance(
      evaluator,
      transition.state,
      elapsed: const Duration(seconds: 1),
    );
    expect(transition.state.elapsed, const Duration(seconds: 1));
    expect(transition.effects, isEmpty);

    transition = _advance(
      evaluator,
      transition.state,
      elapsed: const Duration(seconds: 1),
    );
    expect(transition.state.elapsed, const Duration(seconds: 2));
    expect(transition.effects, const [
      AppTimeoutNotificationEffect(applicationName: 'Alpha', roundedMinutes: 1),
    ]);

    transition = _advance(
      evaluator,
      transition.state,
      elapsed: const Duration(seconds: 2),
    );
    expect(transition.state.elapsed, const Duration(seconds: 4));
    expect(transition.effects, isEmpty);
  });

  test('repeating rules wait for the full active-time cooldown', () {
    const repeating = AppTimeoutRule(
      id: 1,
      executablePath: _pathA,
      displayName: 'Alpha',
      threshold: Duration(seconds: 2),
      cooldown: Duration(seconds: 3),
      enabled: true,
      repeatEnabled: true,
    );
    var state = evaluator
        .advance(
          state: const ContinuousUseState.empty(),
          snapshot: _active(_appA),
          rules: const [repeating],
          elapsed: Duration.zero,
          rulesRevision: 1,
        )
        .state;

    var transition = _advance(
      evaluator,
      state,
      elapsed: const Duration(seconds: 2),
      rules: const [repeating],
    );
    expect(transition.effects, hasLength(1));
    state = transition.state;

    transition = _advance(
      evaluator,
      state,
      elapsed: const Duration(seconds: 2),
      rules: const [repeating],
    );
    expect(transition.state.elapsed, const Duration(seconds: 4));
    expect(transition.effects, isEmpty);

    transition = _advance(
      evaluator,
      transition.state,
      elapsed: const Duration(seconds: 1),
      rules: const [repeating],
    );
    expect(transition.state.elapsed, const Duration(seconds: 5));
    expect(transition.effects, hasLength(1));
  });

  test('path switches and returning to an app start new strict segments', () {
    var transition = evaluator.advance(
      state: const ContinuousUseState.empty(),
      snapshot: _active(_appA),
      rules: const [_ruleA, _ruleB],
      elapsed: Duration.zero,
      rulesRevision: 1,
    );
    transition = _advance(
      evaluator,
      transition.state,
      elapsed: const Duration(seconds: 2),
      rules: const [_ruleA, _ruleB],
    );
    expect(transition.state.elapsed, const Duration(seconds: 2));

    transition = evaluator.advance(
      state: transition.state,
      snapshot: _active(_appB),
      rules: const [_ruleA, _ruleB],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
    );
    expect(transition.state.application, _appB);
    expect(transition.state.elapsed, Duration.zero);
    expect(transition.effects, isEmpty);

    transition = evaluator.advance(
      state: transition.state,
      snapshot: _active(_appA),
      rules: const [_ruleA, _ruleB],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
    );
    expect(transition.state.application, _appA);
    expect(transition.state.elapsed, Duration.zero);
    expect(transition.state.lastNotificationElapsed, isNull);
  });

  test('display-name changes preserve a path-based segment', () {
    final initial = evaluator.advance(
      state: const ContinuousUseState.empty(),
      snapshot: _active(_appA),
      rules: const [_ruleA],
      elapsed: Duration.zero,
      rulesRevision: 1,
    );
    const renamed = ActivityApplication(
      executablePath: _pathA,
      displayName: 'Alpha renamed',
    );
    final next = evaluator.advance(
      state: initial.state,
      snapshot: _active(renamed),
      rules: const [_ruleA],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
    );

    expect(next.state.elapsed, const Duration(seconds: 1));
    expect(next.state.application, renamed);
  });

  test('idle excluded paused and unavailable snapshots clear the segment', () {
    final seeded = ContinuousUseState(
      application: _appA,
      elapsed: const Duration(minutes: 4),
      rulesRevision: 1,
      matchedRule: _ruleA,
      lastNotificationElapsed: const Duration(minutes: 2),
    );
    final observedAt = DateTime.utc(2026, 8, 31);
    final invalidSnapshots = [
      ActivitySnapshot.idle(revision: 2, observedAt: observedAt),
      ActivitySnapshot.excluded(revision: 3, observedAt: observedAt),
      ActivitySnapshot.paused(revision: 4, observedAt: observedAt),
      ActivitySnapshot.unavailable(revision: 5, observedAt: observedAt),
    ];

    for (final snapshot in invalidSnapshots) {
      final transition = evaluator.advance(
        state: seeded,
        snapshot: snapshot,
        rules: const [_ruleA],
        elapsed: const Duration(seconds: 1),
        rulesRevision: 8,
      );
      expect(
        transition.state,
        const ContinuousUseState.empty(rulesRevision: 8),
      );
      expect(transition.effects, isEmpty);
    }
  });

  test('explicit and oversized gaps reset the segment without catch-up', () {
    final seeded = ContinuousUseState(
      application: _appA,
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
      matchedRule: _ruleA,
      lastNotificationElapsed: null,
    );
    final explicit = evaluator.advance(
      state: seeded,
      snapshot: _active(_appA),
      rules: const [_ruleA],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 1,
      isGap: true,
    );
    final oversized = evaluator.advance(
      state: seeded,
      snapshot: _active(_appA),
      rules: const [_ruleA],
      elapsed: const Duration(milliseconds: 2501),
      rulesRevision: 1,
    );

    expect(explicit.state.elapsed, Duration.zero);
    expect(explicit.effects, isEmpty);
    expect(oversized.state.elapsed, Duration.zero);
    expect(oversized.effects, isEmpty);
  });

  test(
    'matching rule edits invalidate markers while unrelated edits do not',
    () {
      const repeating = AppTimeoutRule(
        id: 1,
        executablePath: _pathA,
        displayName: 'Alpha',
        threshold: Duration(seconds: 2),
        cooldown: Duration(seconds: 10),
        enabled: true,
        repeatEnabled: true,
      );
      var transition = evaluator.advance(
        state: const ContinuousUseState.empty(),
        snapshot: _active(_appA),
        rules: const [repeating],
        elapsed: Duration.zero,
        rulesRevision: 1,
      );
      transition = _advance(
        evaluator,
        transition.state,
        elapsed: const Duration(seconds: 2),
        rules: const [repeating],
      );
      expect(transition.effects, hasLength(1));

      final unrelatedEdit = evaluator.advance(
        state: transition.state,
        snapshot: _active(_appA),
        rules: const [repeating, _ruleB],
        elapsed: const Duration(seconds: 1),
        rulesRevision: 2,
      );
      expect(unrelatedEdit.effects, isEmpty);
      expect(
        unrelatedEdit.state.lastNotificationElapsed,
        const Duration(seconds: 2),
      );

      const raisedThreshold = AppTimeoutRule(
        id: 1,
        executablePath: _pathA,
        displayName: 'Alpha',
        threshold: Duration(seconds: 10),
        cooldown: Duration(seconds: 10),
        enabled: true,
        repeatEnabled: true,
      );
      final matchingEdit = evaluator.advance(
        state: unrelatedEdit.state,
        snapshot: _active(_appA),
        rules: const [raisedThreshold, _ruleB],
        elapsed: const Duration(seconds: 1),
        rulesRevision: 3,
      );
      expect(matchingEdit.state.elapsed, const Duration(seconds: 4));
      expect(matchingEdit.state.lastNotificationElapsed, isNull);
      expect(matchingEdit.effects, isEmpty);
    },
  );

  test('lowered threshold takes effect on the next evaluation', () {
    var transition = evaluator.advance(
      state: const ContinuousUseState.empty(),
      snapshot: _active(_appA),
      rules: const [],
      elapsed: Duration.zero,
      rulesRevision: 1,
    );
    transition = evaluator.advance(
      state: transition.state,
      snapshot: _active(_appA),
      rules: const [],
      elapsed: const Duration(seconds: 2),
      rulesRevision: 1,
    );
    expect(transition.state.elapsed, const Duration(seconds: 2));

    final added = evaluator.advance(
      state: transition.state,
      snapshot: _active(_appA),
      rules: const [_ruleA],
      elapsed: Duration.zero,
      rulesRevision: 2,
    );
    expect(added.effects, hasLength(1));
    expect(added.state.lastNotificationElapsed, const Duration(seconds: 2));
  });

  test('deleting or disabling a matching rule discards its marker', () {
    final seeded = ContinuousUseState(
      application: _appA,
      elapsed: const Duration(seconds: 4),
      rulesRevision: 1,
      matchedRule: _ruleA,
      lastNotificationElapsed: const Duration(seconds: 2),
    );
    final deleted = evaluator.advance(
      state: seeded,
      snapshot: _active(_appA),
      rules: const [],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 2,
    );
    const disabledRule = AppTimeoutRule(
      id: 1,
      executablePath: _pathA,
      displayName: 'Alpha',
      threshold: Duration(seconds: 2),
      cooldown: Duration(seconds: 3),
      enabled: false,
      repeatEnabled: false,
    );
    final disabled = evaluator.advance(
      state: seeded,
      snapshot: _active(_appA),
      rules: const [disabledRule],
      elapsed: const Duration(seconds: 1),
      rulesRevision: 2,
    );

    for (final transition in [deleted, disabled]) {
      expect(transition.state.elapsed, const Duration(seconds: 5));
      expect(transition.state.matchedRule, isNull);
      expect(transition.state.lastNotificationElapsed, isNull);
      expect(transition.effects, isEmpty);
    }
  });

  test(
    'notification effect contains only display name and rounded duration',
    () {
      const minuteRule = AppTimeoutRule(
        id: 3,
        executablePath: _pathA,
        displayName: 'Safe name',
        threshold: Duration(seconds: 30),
        cooldown: Duration(minutes: 1),
        enabled: true,
        repeatEnabled: false,
      );
      final seeded = ContinuousUseState(
        application: _appA,
        elapsed: const Duration(seconds: 29),
        rulesRevision: 1,
        matchedRule: minuteRule,
        lastNotificationElapsed: null,
      );
      final transition = evaluator.advance(
        state: seeded,
        snapshot: _active(_appA),
        rules: const [minuteRule],
        elapsed: const Duration(seconds: 1),
        rulesRevision: 1,
      );
      final effect = transition.effects.single as AppTimeoutNotificationEffect;

      expect(effect.applicationName, 'Safe name');
      expect(effect.roundedMinutes, 1);
      expect(effect.toString(), isNot(contains(_pathA)));
    },
  );
}

ContinuousUseTransition _advance(
  ContinuousUseEvaluator evaluator,
  ContinuousUseState state, {
  required Duration elapsed,
  Iterable<AppTimeoutRule> rules = const [_ruleA],
}) {
  return evaluator.advance(
    state: state,
    snapshot: _active(_appA),
    rules: rules,
    elapsed: elapsed,
    rulesRevision: state.rulesRevision,
  );
}

ActivitySnapshot _active(ActivityApplication application) {
  return ActivitySnapshot.active(
    revision: 1,
    observedAt: DateTime.utc(2026, 8, 31),
    application: application,
  );
}

const _pathA = r'c:\apps\alpha.exe';
const _pathB = r'c:\apps\beta.exe';
const _appA = ActivityApplication(executablePath: _pathA, displayName: 'Alpha');
const _appB = ActivityApplication(executablePath: _pathB, displayName: 'Beta');
const _ruleA = AppTimeoutRule(
  id: 1,
  executablePath: _pathA,
  displayName: 'Alpha',
  threshold: Duration(seconds: 2),
  cooldown: Duration(seconds: 3),
  enabled: true,
  repeatEnabled: false,
);
const _ruleB = AppTimeoutRule(
  id: 2,
  executablePath: _pathB,
  displayName: 'Beta',
  threshold: Duration(seconds: 5),
  cooldown: Duration(seconds: 3),
  enabled: true,
  repeatEnabled: false,
);
