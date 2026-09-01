import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

/// Compact, provider-free Pomodoro controls for the dashboard app bar menu.
///
/// Application identity is deliberately absent from this Pomodoro-only
/// surface, so executable paths and window titles cannot enter its contract.
class FocusQuickPanel extends StatelessWidget {
  const FocusQuickPanel({
    required this.strings,
    required this.config,
    required this.state,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onSkip,
    required this.onStop,
    required this.onReset,
    required this.onOpenSettings,
    this.systemFrozen = false,
    super.key,
  });

  static const double preferredWidth = 352;
  static const double minimumWidth = 336;
  static const double maximumWidth = 360;
  static const double maximumHeight = 420;

  final ReminderL10n strings;
  final PomodoroConfig config;
  final PomodoroState state;
  final bool systemFrozen;

  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onSkip;
  final VoidCallback onStop;
  final VoidCallback onReset;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      key: const ValueKey('focus-quick-panel'),
      width: preferredWidth,
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.timer_outlined, size: 19, color: scheme.primary),
                const SizedBox(width: TimeTraceSpace.xs),
                Expanded(
                  child: Text(
                    strings.pomodoro,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                IconButton(
                  key: const ValueKey('focus-quick-settings'),
                  tooltip: strings.pomodoroSettings,
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const Divider(height: TimeTraceSpace.md),
            if (!config.enabled)
              _DisabledContent(strings: strings, onOpenSettings: onOpenSettings)
            else
              _EnabledContent(
                strings: strings,
                config: config,
                state: state,
                systemFrozen: systemFrozen,
                onStart: onStart,
                onPause: onPause,
                onResume: onResume,
                onSkip: onSkip,
                onStop: onStop,
                onReset: onReset,
              ),
          ],
        ),
      ),
    );
  }
}

class _DisabledContent extends StatelessWidget {
  const _DisabledContent({required this.strings, required this.onOpenSettings});

  final ReminderL10n strings;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      key: const ValueKey('focus-quick-disabled'),
      label: '${strings.pomodoro}: ${strings.disabled}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.timer_off_outlined, size: 20, color: scheme.outline),
              const SizedBox(width: TimeTraceSpace.xs),
              Expanded(
                child: Text(
                  strings.enablePomodoroHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          FilledButton.tonalIcon(
            key: const ValueKey('focus-quick-disabled-settings'),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined, size: 17),
            label: Text(strings.pomodoroSettings),
          ),
        ],
      ),
    );
  }
}

class _EnabledContent extends StatelessWidget {
  const _EnabledContent({
    required this.strings,
    required this.config,
    required this.state,
    required this.systemFrozen,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onSkip,
    required this.onStop,
    required this.onReset,
  });

  final ReminderL10n strings;
  final PomodoroConfig config;
  final PomodoroState state;
  final bool systemFrozen;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onSkip;
  final VoidCallback onStop;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final phase = _phaseLabel(state.phase, strings);
    final status = _statusLabel(state, systemFrozen, strings);
    final countdown = state.isIdle ? config.focusDuration : state.remaining;
    final remaining = _clock(countdown);
    final total = state.phaseDuration > Duration.zero
        ? state.phaseDuration
        : _configuredDuration(state.phase, config);
    final progress = _progress(state, total);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              _phaseIcon(state.phase, systemFrozen: systemFrozen),
              size: 18,
              color: scheme.primary,
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(
              child: Text(
                phase,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            _StatusLabel(label: status, systemFrozen: systemFrozen),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        Semantics(
          key: const ValueKey('focus-quick-countdown-semantics'),
          label: strings.countdownSemantics(phase, remaining),
          liveRegion: false,
          child: ExcludeSemantics(
            child: Text(
              remaining,
              key: const ValueKey('focus-quick-countdown'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(height: TimeTraceSpace.xs),
        Semantics(
          label: strings.currentPhaseProgress,
          value: '${(progress * 100).round()}%',
          liveRegion: false,
          child: LinearProgressIndicator(
            key: const ValueKey('focus-quick-progress'),
            value: progress,
            minHeight: 5,
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: TimeTraceSpace.xs),
        Text(
          systemFrozen
              ? strings.waitForActivity
              : strings.completedFocusRounds(state.completedFocusCount),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: TimeTraceSpace.md),
        _QuickControls(
          strings: strings,
          state: state,
          onStart: onStart,
          onPause: onPause,
          onResume: onResume,
          onSkip: onSkip,
          onStop: onStop,
        ),
        if (!state.isIdle || state.completedFocusCount > 0)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              key: const ValueKey('focus-quick-reset'),
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt_rounded, size: 17),
              label: Text(strings.resetRounds),
            ),
          ),
      ],
    );
  }
}

class _QuickControls extends StatelessWidget {
  const _QuickControls({
    required this.strings,
    required this.state,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onSkip,
    required this.onStop,
  });

  final ReminderL10n strings;
  final PomodoroState state;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onSkip;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final mainAction = state.isIdle
        ? _QuickAction(
            key: const ValueKey('focus-quick-start'),
            tooltip: strings.startFocusTooltip,
            icon: Icons.play_arrow_rounded,
            label: strings.start,
            onPressed: onStart,
            filled: true,
          )
        : state.isRunning
        ? _QuickAction(
            key: const ValueKey('focus-quick-pause'),
            tooltip: strings.pauseFocusTooltip,
            icon: Icons.pause_rounded,
            label: strings.pause,
            onPressed: onPause,
            filled: true,
          )
        : _QuickAction(
            key: const ValueKey('focus-quick-resume'),
            tooltip: strings.resumeFocusTooltip,
            icon: Icons.play_arrow_rounded,
            label: state.intent == PomodoroIntent.ready
                ? strings.start
                : strings.resume,
            onPressed: onResume,
            filled: true,
          );

    return Wrap(
      key: const ValueKey('focus-quick-controls'),
      spacing: TimeTraceSpace.xs,
      runSpacing: TimeTraceSpace.xs,
      children: [
        mainAction,
        if (!state.isIdle)
          _QuickAction(
            key: const ValueKey('focus-quick-skip'),
            tooltip: strings.skipPhaseTooltip,
            icon: Icons.skip_next_rounded,
            label: strings.skip,
            onPressed: onSkip,
          ),
        if (!state.isIdle)
          _QuickAction(
            key: const ValueKey('focus-quick-stop'),
            tooltip: strings.stopFocusTooltip,
            icon: Icons.stop_rounded,
            label: strings.stop,
            onPressed: onStop,
          ),
      ],
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.tooltip,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = filled
        ? FilledButton.tonalIcon(
            onPressed: onPressed,
            icon: Icon(icon, size: 17),
            label: Text(label),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 17),
            label: Text(label),
          );
    return Tooltip(message: tooltip, child: child);
  }
}

class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.label, required this.systemFrozen});

  final String label;
  final bool systemFrozen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('focus-quick-status'),
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: systemFrozen
            ? scheme.errorContainer.withValues(alpha: 0.72)
            : scheme.primaryContainer.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            systemFrozen ? Icons.pause_circle_outline_rounded : Icons.circle,
            size: systemFrozen ? 14 : 7,
            color: systemFrozen ? scheme.onErrorContainer : scheme.primary,
          ),
          const SizedBox(width: TimeTraceSpace.xxs),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

String _phaseLabel(PomodoroPhase phase, ReminderL10n strings) =>
    switch (phase) {
      PomodoroPhase.idle => strings.readyToFocus,
      PomodoroPhase.focus => strings.focus,
      PomodoroPhase.shortBreak => strings.shortBreak,
      PomodoroPhase.longBreak => strings.longBreak,
    };

String _statusLabel(
  PomodoroState state,
  bool systemFrozen,
  ReminderL10n strings,
) {
  if (systemFrozen) return strings.focusTimerFrozen;
  if (state.isIdle) return strings.ready;
  return switch (state.intent) {
    PomodoroIntent.running => strings.running,
    PomodoroIntent.ready => strings.waitingToStart,
    PomodoroIntent.userPaused => strings.paused,
  };
}

IconData _phaseIcon(PomodoroPhase phase, {required bool systemFrozen}) {
  if (systemFrozen) return Icons.pause_circle_outline_rounded;
  return switch (phase) {
    PomodoroPhase.idle => Icons.timer_outlined,
    PomodoroPhase.focus => Icons.center_focus_strong_rounded,
    PomodoroPhase.shortBreak ||
    PomodoroPhase.longBreak => Icons.coffee_outlined,
  };
}

Duration _configuredDuration(PomodoroPhase phase, PomodoroConfig config) {
  return switch (phase) {
    PomodoroPhase.idle || PomodoroPhase.focus => config.focusDuration,
    PomodoroPhase.shortBreak => config.shortBreakDuration,
    PomodoroPhase.longBreak => config.longBreakDuration,
  };
}

double _progress(PomodoroState state, Duration total) {
  if (state.isIdle || total <= Duration.zero) return 0;
  final elapsed = total.inMilliseconds - state.remaining.inMilliseconds;
  return (elapsed / total.inMilliseconds).clamp(0.0, 1.0);
}

String _clock(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${rest.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${rest.toString().padLeft(2, '0')}';
}
