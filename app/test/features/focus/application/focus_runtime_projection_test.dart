import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/focus/application/focus_runtime_projection.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

void main() {
  group('isPomodoroSystemFrozen', () {
    const running = PomodoroState(
      phase: PomodoroPhase.focus,
      intent: PomodoroIntent.running,
      remaining: Duration(minutes: 25),
      phaseDuration: Duration(minutes: 25),
      completedFocusCount: 0,
    );

    test('freezes running phases for every ineligible activity state', () {
      for (final activityState in const [
        ActivitySnapshotState.idle,
        ActivitySnapshotState.paused,
        ActivitySnapshotState.unavailable,
      ]) {
        expect(
          isPomodoroSystemFrozen(
            pomodoro: running,
            activityState: activityState,
          ),
          isTrue,
          reason: '$activityState must freeze a running Pomodoro',
        );
      }
    });

    test('keeps running phases eligible for active and excluded activity', () {
      for (final activityState in const [
        ActivitySnapshotState.active,
        ActivitySnapshotState.excluded,
      ]) {
        expect(
          isPomodoroSystemFrozen(
            pomodoro: running,
            activityState: activityState,
          ),
          isFalse,
          reason: '$activityState must remain eligible',
        );
      }
    });

    test('does not invent a freeze before the first activity observation', () {
      expect(
        isPomodoroSystemFrozen(pomodoro: running, activityState: null),
        isFalse,
      );
    });

    test('system state never overrides explicit non-running intent', () {
      for (final pomodoro in [
        const PomodoroState.initial(),
        running.copyWith(intent: PomodoroIntent.userPaused),
        running.copyWith(intent: PomodoroIntent.ready),
      ]) {
        expect(
          isPomodoroSystemFrozen(
            pomodoro: pomodoro,
            activityState: ActivitySnapshotState.idle,
          ),
          isFalse,
        );
      }
    });
  });
}
