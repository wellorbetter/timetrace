import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

/// Whether a running Pomodoro is currently frozen by system activity.
///
/// This projection deliberately accepts only the activity lifecycle state, so
/// application names, executable paths, and window identity cannot enter UI or
/// tray status derivation.
bool isPomodoroSystemFrozen({
  required PomodoroState pomodoro,
  required ActivitySnapshotState? activityState,
}) {
  if (!pomodoro.isRunning) return false;
  return switch (activityState) {
    ActivitySnapshotState.idle ||
    ActivitySnapshotState.paused ||
    ActivitySnapshotState.unavailable => true,
    ActivitySnapshotState.active ||
    ActivitySnapshotState.excluded ||
    null => false,
  };
}
