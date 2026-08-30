import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_reminder_card.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';

/// Small Consumer boundary so the one-second runtime refreshes only this page,
/// never the dashboard workspace or root MaterialApp.
class FocusDashboardControllerCard extends ConsumerWidget {
  const FocusDashboardControllerCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(reminderRuntimeProvider);
    final commands = ref.read(reminderRuntimeProvider.notifier);
    final pomodoro = runtime.pomodoro;
    final continuous = runtime.continuousUse;
    final strings = ReminderL10n(ref.watch(localeProvider));

    return SingleChildScrollView(
      key: const ValueKey('dashboard-focus-page'),
      primary: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FocusReminderCard(
            strings: strings,
            config: runtime.configuration.pomodoro,
            state: pomodoro,
            phaseDuration: _phaseDuration(runtime),
            systemFrozen: isPomodoroSystemFrozen(runtime),
            currentApplicationName: continuous.application?.displayName,
            currentApplicationElapsed: continuous.hasSegment
                ? continuous.elapsed
                : null,
            currentApplicationThreshold: continuous.matchedRule?.threshold,
            onStart: commands.startPomodoro,
            onPause: commands.pausePomodoro,
            onResume: commands.resumePomodoro,
            onSkip: commands.skipPomodoro,
            onStop: commands.stopPomodoro,
          ),
          if (runtime.configuration.pomodoro.enabled &&
              (!pomodoro.isIdle || pomodoro.completedFocusCount > 0))
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('focus-reset'),
                onPressed: commands.resetPomodoro,
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: Text(strings.resetRounds),
              ),
            ),
        ],
      ),
    );
  }
}

/// Whether the running Pomodoro is frozen by an invalid activity lifecycle.
bool isPomodoroSystemFrozen(ReminderRuntimeState runtime) {
  if (!runtime.pomodoro.isRunning) return false;
  return switch (runtime.activity?.state) {
    ActivitySnapshotState.idle ||
    ActivitySnapshotState.paused ||
    ActivitySnapshotState.unavailable => true,
    ActivitySnapshotState.active ||
    ActivitySnapshotState.excluded ||
    null => false,
  };
}

Duration? _phaseDuration(ReminderRuntimeState runtime) {
  final state = runtime.pomodoro;
  if (state.isIdle) return null;
  if (state.phaseDuration > Duration.zero) return state.phaseDuration;

  // Compatibility fallback for hand-built/test states created before phase
  // duration became part of the runtime snapshot. Production transitions
  // always capture a positive duration on phase entry.
  final config = runtime.configuration.pomodoro;
  return switch (state.phase) {
    PomodoroPhase.idle => null,
    PomodoroPhase.focus => config.focusDuration,
    PomodoroPhase.shortBreak => config.shortBreakDuration,
    PomodoroPhase.longBreak => config.longBreakDuration,
  };
}
