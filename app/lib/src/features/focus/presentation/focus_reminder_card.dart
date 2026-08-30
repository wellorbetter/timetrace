import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

/// A compact, provider-agnostic overview card for focus and app reminders.
///
/// Only privacy-safe application display data is accepted. Executable paths
/// and window titles are deliberately absent from this public widget contract.
class FocusReminderCard extends StatelessWidget {
  const FocusReminderCard({
    required this.config,
    required this.state,
    this.strings = ReminderL10n.zh,
    this.phaseDuration,
    this.systemFrozen = false,
    this.currentApplicationName,
    this.currentApplicationElapsed,
    this.currentApplicationThreshold,
    this.onStart,
    this.onPause,
    this.onResume,
    this.onSkip,
    this.onStop,
    super.key,
  });

  final PomodoroConfig config;
  final PomodoroState state;
  final ReminderL10n strings;

  /// The duration captured when the current phase started.
  ///
  /// Supplying it keeps progress stable if settings change mid-phase. When it
  /// is omitted, the current configuration is used as a safe fallback.
  final Duration? phaseDuration;
  final bool systemFrozen;
  final String? currentApplicationName;
  final Duration? currentApplicationElapsed;
  final Duration? currentApplicationThreshold;

  final VoidCallback? onStart;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onSkip;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Card(
      key: const ValueKey('focus-reminder-card'),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SectionTitle(
                    icon: Icons.timer_outlined,
                    title: strings.focusCardTitle,
                  ),
                ),
                _RealtimeLabel(strings: strings),
                const SizedBox(width: TimeTraceSpace.xs),
                if (!config.enabled)
                  Text(
                    strings.disabled,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else if (systemFrozen)
                  _StatusPill(
                    icon: Icons.pause_circle_outline_rounded,
                    label: strings.activityPaused,
                  )
                else
                  _StatusPill(
                    icon: state.isRunning
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    label: _intentLabel(state, strings),
                  ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.sm),
            LayoutBuilder(
              builder: (context, constraints) {
                final timer = _TimerPane(
                  config: config,
                  state: state,
                  phaseDuration: phaseDuration,
                  systemFrozen: systemFrozen,
                  strings: strings,
                );
                final contextPane = _ContextPane(
                  config: config,
                  state: state,
                  currentApplicationName: currentApplicationName,
                  currentApplicationElapsed: currentApplicationElapsed,
                  currentApplicationThreshold: currentApplicationThreshold,
                  onStart: onStart,
                  onPause: onPause,
                  onResume: onResume,
                  onSkip: onSkip,
                  onStop: onStop,
                  strings: strings,
                );

                if (constraints.maxWidth < 480) {
                  return Column(
                    key: const ValueKey('focus-card-stacked-layout'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      timer,
                      const SizedBox(height: TimeTraceSpace.md),
                      contextPane,
                    ],
                  );
                }

                return Row(
                  key: const ValueKey('focus-card-two-column-layout'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: timer),
                    const SizedBox(width: TimeTraceSpace.lg),
                    Expanded(child: contextPane),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TimerPane extends StatelessWidget {
  const _TimerPane({
    required this.config,
    required this.state,
    required this.phaseDuration,
    required this.systemFrozen,
    required this.strings,
  });

  final PomodoroConfig config;
  final PomodoroState state;
  final Duration? phaseDuration;
  final bool systemFrozen;
  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = phaseDuration ?? _configuredDuration(state.phase, config);
    final progress = _progress(state, total);
    final remaining = state.isIdle ? config.focusDuration : state.remaining;
    final phaseLabel = state.isIdle
        ? strings.readyToFocus
        : _phaseLabel(state.phase, strings);

    return Semantics(
      key: const ValueKey('focus-countdown-semantics'),
      container: true,
      // Intentionally not a live region: a once-per-second announcement would
      // make the card unusable with a screen reader.
      label: strings.countdownSemantics(
        phaseLabel,
        strings.compactDuration(remaining),
      ),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              phaseLabel,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xxs),
            Text(
              _clock(remaining),
              key: const ValueKey('focus-countdown'),
              maxLines: 1,
              style: theme.textTheme.displaySmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: -0.8,
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            Semantics(
              label: strings.currentPhaseProgress,
              value: '${(progress * 100).round()}%',
              child: LinearProgressIndicator(
                key: const ValueKey('focus-progress'),
                value: progress,
                minHeight: 6,
                borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            Row(
              children: [
                Icon(
                  systemFrozen
                      ? Icons.pause_circle_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: TimeTraceSpace.xxs),
                Expanded(
                  child: Text(
                    systemFrozen
                        ? strings.waitForActivity
                        : strings.completedFocusRounds(
                            state.completedFocusCount,
                          ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ContextPane extends StatelessWidget {
  const _ContextPane({
    required this.config,
    required this.state,
    required this.currentApplicationName,
    required this.currentApplicationElapsed,
    required this.currentApplicationThreshold,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onSkip,
    required this.onStop,
    required this.strings,
  });

  final PomodoroConfig config;
  final PomodoroState state;
  final String? currentApplicationName;
  final Duration? currentApplicationElapsed;
  final Duration? currentApplicationThreshold;
  final VoidCallback? onStart;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onSkip;
  final VoidCallback? onStop;
  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rawAppName = currentApplicationName?.trim();
    final hasApplication = rawAppName != null && rawAppName.isNotEmpty;
    final appName = hasApplication
        ? strings.applicationName(
            rawAppName,
            fallback: strings.currentApplication,
          )
        : strings.currentApplication;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('focus-current-app'),
          padding: const EdgeInsets.all(TimeTraceSpace.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.36),
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.desktop_windows_outlined,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: TimeTraceSpace.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      appName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _applicationStatus(
                        elapsed: currentApplicationElapsed,
                        threshold: currentApplicationThreshold,
                        hasApplication: hasApplication,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        _Controls(
          enabled: config.enabled,
          state: state,
          onStart: onStart,
          onPause: onPause,
          onResume: onResume,
          onSkip: onSkip,
          onStop: onStop,
          strings: strings,
        ),
      ],
    );
  }

  String _applicationStatus({
    required Duration? elapsed,
    required Duration? threshold,
    required bool hasApplication,
  }) {
    if (!hasApplication) return strings.noApplicationStatus;
    final elapsedLabel = strings.compactDuration(elapsed ?? Duration.zero);
    if (threshold == null || threshold <= Duration.zero) {
      return strings.continuousUseWithoutRule(elapsedLabel);
    }
    return strings.continuousUseWithThreshold(
      elapsedLabel,
      strings.compactDuration(threshold),
    );
  }
}

class _RealtimeLabel extends StatelessWidget {
  const _RealtimeLabel({required this.strings});

  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: const ValueKey('focus-realtime-label'),
      label: strings.realtimeData,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TimeTraceSpace.xs,
          vertical: TimeTraceSpace.xxs,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        ),
        child: Text(
          strings.realtime,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.enabled,
    required this.state,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onSkip,
    required this.onStop,
    required this.strings,
  });

  final bool enabled;
  final PomodoroState state;
  final VoidCallback? onStart;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onSkip;
  final VoidCallback? onStop;
  final ReminderL10n strings;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return Text(
        strings.enablePomodoroHint,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }

    final mainAction = state.isIdle
        ? _ActionButton(
            key: const ValueKey('focus-start'),
            tooltip: strings.startFocusTooltip,
            icon: Icons.play_arrow_rounded,
            label: strings.start,
            onPressed: onStart,
            filled: true,
          )
        : state.isRunning
        ? _ActionButton(
            key: const ValueKey('focus-pause'),
            tooltip: strings.pauseFocusTooltip,
            icon: Icons.pause_rounded,
            label: strings.pause,
            onPressed: onPause,
            filled: true,
          )
        : _ActionButton(
            key: const ValueKey('focus-resume'),
            tooltip: strings.resumeFocusTooltip,
            icon: Icons.play_arrow_rounded,
            label: state.intent == PomodoroIntent.ready
                ? strings.start
                : strings.resume,
            onPressed: onResume,
            filled: true,
          );

    return Wrap(
      key: const ValueKey('focus-controls'),
      spacing: TimeTraceSpace.xs,
      runSpacing: TimeTraceSpace.xs,
      children: [
        mainAction,
        if (!state.isIdle)
          _ActionButton(
            key: const ValueKey('focus-skip'),
            tooltip: strings.skipPhaseTooltip,
            icon: Icons.skip_next_rounded,
            label: strings.skip,
            onPressed: onSkip,
          ),
        if (!state.isIdle)
          _ActionButton(
            key: const ValueKey('focus-stop'),
            tooltip: strings.stopFocusTooltip,
            icon: Icons.stop_rounded,
            label: strings.stop,
            onPressed: onStop,
          ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
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
  final VoidCallback? onPressed;
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

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.xs,
        vertical: TimeTraceSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.56),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.primary),
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

String _intentLabel(PomodoroState state, ReminderL10n strings) {
  if (state.isIdle) return strings.ready;
  return switch (state.intent) {
    PomodoroIntent.running => strings.running,
    PomodoroIntent.ready => strings.waitingToStart,
    PomodoroIntent.userPaused => strings.paused,
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
