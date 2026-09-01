import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/focus/application/focus_runtime_projection.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_quick_panel.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';

/// Dashboard app-bar status capsule backed by the process-wide reminder runtime.
///
/// This widget only observes the existing runtime. Opening the menu performs no
/// permission request, notification delivery, FFI read, or timer allocation.
class FocusAppBarAction extends ConsumerStatefulWidget {
  const FocusAppBarAction({
    required this.strings,
    required this.onOpenSettings,
    super.key,
  });

  final ReminderL10n strings;
  final VoidCallback onOpenSettings;

  /// Below this window width the app shell leaves too little horizontal room
  /// for a stable countdown capsule, so the trigger keeps only its status icon.
  static const double compactWindowBreakpoint = 1080;
  static const double expandedTriggerWidth = 208;

  @override
  ConsumerState<FocusAppBarAction> createState() => _FocusAppBarActionState();
}

class _FocusAppBarActionState extends ConsumerState<FocusAppBarAction> {
  final MenuController _menuController = MenuController();
  late final FocusNode _triggerFocusNode;
  bool _isOpen = false;

  @override
  void initState() {
    super.initState();
    _triggerFocusNode = FocusNode(debugLabel: 'Focus app bar action');
  }

  @override
  void dispose() {
    _triggerFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projection = ref.watch(
      reminderRuntimeProvider.select(FocusAppBarProjection.fromRuntime),
    );
    final compact =
        MediaQuery.sizeOf(context).width <
        FocusAppBarAction.compactWindowBreakpoint;
    final systemFrozen = isPomodoroSystemFrozen(
      pomodoro: _pomodoroLifecycle(projection),
      activityState: projection.activityState,
    );
    final status = _FocusActionStatus.fromProjection(
      projection,
      strings: widget.strings,
      systemFrozen: systemFrozen,
    );
    final scheme = Theme.of(context).colorScheme;

    return MenuAnchor(
      key: const ValueKey('focus-app-bar-menu'),
      controller: _menuController,
      childFocusNode: _triggerFocusNode,
      consumeOutsideTap: true,
      crossAxisUnconstrained: false,
      useRootOverlay: true,
      reservedPadding: const EdgeInsets.all(TimeTraceSpace.xs),
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        elevation: const WidgetStatePropertyAll(0),
        shadowColor: const WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: const WidgetStatePropertyAll(
          Size(FocusQuickPanel.preferredWidth, 0),
        ),
        maximumSize: const WidgetStatePropertyAll(
          Size(FocusQuickPanel.preferredWidth, FocusQuickPanel.maximumHeight),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      onOpen: () {
        if (!_isOpen) setState(() => _isOpen = true);
      },
      onClose: () {
        if (_isOpen) setState(() => _isOpen = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _triggerFocusNode.canRequestFocus) {
            _triggerFocusNode.requestFocus();
          }
        });
      },
      menuChildren: [
        _FocusQuickPanelRuntimeHost(
          strings: widget.strings,
          onOpenSettings: _openSettings,
        ),
      ],
      builder: (context, controller, child) {
        void toggleMenu() {
          _triggerFocusNode.requestFocus();
          controller.isOpen ? controller.close() : controller.open();
        }

        return Semantics(
          key: const ValueKey('focus-app-bar-semantics'),
          label: status.semanticLabel,
          button: true,
          expanded: _isOpen,
          liveRegion: false,
          onTap: toggleMenu,
          excludeSemantics: true,
          child: Tooltip(
            message: status.semanticLabel,
            child: compact
                ? IconButton.filledTonal(
                    key: const ValueKey('focus-app-bar-trigger'),
                    focusNode: _triggerFocusNode,
                    onPressed: toggleMenu,
                    icon: Icon(status.icon),
                  )
                : SizedBox(
                    width: FocusAppBarAction.expandedTriggerWidth,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('focus-app-bar-trigger'),
                      focusNode: _triggerFocusNode,
                      onPressed: toggleMenu,
                      icon: Icon(status.icon, size: 18),
                      label: Text(
                        status.visibleLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: TimeTraceSpace.sm,
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }

  void _openSettings() {
    _menuController.close();
    widget.onOpenSettings();
  }
}

/// Privacy-minimal, equality-stable state observed while the quick panel is
/// closed.
///
/// Application identity, continuous-use state, notification health and the
/// runtime tick counter are intentionally not retained. This keeps unrelated
/// one-second runtime publications from rebuilding app-bar hosts.
final class FocusAppBarProjection {
  const FocusAppBarProjection({
    required this.enabled,
    required this.phase,
    required this.intent,
    required this.remainingSeconds,
    required this.activityState,
  });

  factory FocusAppBarProjection.fromRuntime(ReminderRuntimeState runtime) {
    final pomodoro = runtime.pomodoro;
    return FocusAppBarProjection(
      enabled: runtime.configuration.pomodoro.enabled,
      phase: pomodoro.phase,
      intent: pomodoro.intent,
      remainingSeconds: pomodoro.remaining.inSeconds,
      activityState: runtime.activity?.state,
    );
  }

  final bool enabled;
  final PomodoroPhase phase;
  final PomodoroIntent intent;
  final int remainingSeconds;
  final ActivitySnapshotState? activityState;

  bool get isIdle => phase == PomodoroPhase.idle;

  @override
  bool operator ==(Object other) {
    return other is FocusAppBarProjection &&
        other.enabled == enabled &&
        other.phase == phase &&
        other.intent == intent &&
        other.remainingSeconds == remainingSeconds &&
        other.activityState == activityState;
  }

  @override
  int get hashCode =>
      Object.hash(enabled, phase, intent, remainingSeconds, activityState);
}

/// Overlay-only Consumer boundary for the complete runtime snapshot.
///
/// [MenuAnchor] does not mount menu children until the menu opens, so this
/// subscription cannot observe identity or other full-runtime fields while
/// the app-bar action is closed.
class _FocusQuickPanelRuntimeHost extends ConsumerWidget {
  const _FocusQuickPanelRuntimeHost({
    required this.strings,
    required this.onOpenSettings,
  });

  final ReminderL10n strings;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(reminderRuntimeProvider);
    final commands = ref.read(reminderRuntimeProvider.notifier);
    return FocusQuickPanel(
      strings: strings,
      config: runtime.configuration.pomodoro,
      state: runtime.pomodoro,
      systemFrozen: isPomodoroSystemFrozen(
        pomodoro: runtime.pomodoro,
        activityState: runtime.activity?.state,
      ),
      onStart: commands.startPomodoro,
      onPause: commands.pausePomodoro,
      onResume: commands.resumePomodoro,
      onSkip: commands.skipPomodoro,
      onStop: commands.stopPomodoro,
      onReset: commands.resetPomodoro,
      onOpenSettings: onOpenSettings,
    );
  }
}

final class _FocusActionStatus {
  const _FocusActionStatus({
    required this.visibleLabel,
    required this.semanticLabel,
    required this.icon,
  });

  factory _FocusActionStatus.fromProjection(
    FocusAppBarProjection projection, {
    required ReminderL10n strings,
    required bool systemFrozen,
  }) {
    if (!projection.enabled) {
      return _FocusActionStatus(
        visibleLabel: strings.disabled,
        semanticLabel: '${strings.pomodoro}: ${strings.disabled}',
        icon: Icons.timer_off_outlined,
      );
    }
    if (projection.isIdle) {
      return _FocusActionStatus(
        visibleLabel: strings.readyToFocus,
        semanticLabel: '${strings.pomodoro}: ${strings.readyToFocus}',
        icon: Icons.timer_outlined,
      );
    }

    final phase = _phaseLabel(projection.phase, strings);
    final remaining = _clock(Duration(seconds: projection.remainingSeconds));
    final status = systemFrozen
        ? strings.focusTimerFrozen
        : switch (projection.intent) {
            PomodoroIntent.running => phase,
            PomodoroIntent.ready => strings.waitingToStart,
            PomodoroIntent.userPaused => strings.paused,
          };
    final detail = strings.countdownSemantics(phase, remaining);
    return _FocusActionStatus(
      visibleLabel: '$status $remaining',
      semanticLabel: '${strings.pomodoro}: $status; $detail',
      icon: _phaseIcon(
        projection.phase,
        intent: projection.intent,
        systemFrozen: systemFrozen,
      ),
    );
  }

  final String visibleLabel;
  final String semanticLabel;
  final IconData icon;
}

PomodoroState _pomodoroLifecycle(FocusAppBarProjection projection) {
  return PomodoroState(
    phase: projection.phase,
    intent: projection.intent,
    remaining: Duration(seconds: projection.remainingSeconds),
    completedFocusCount: 0,
  );
}

String _phaseLabel(PomodoroPhase phase, ReminderL10n strings) =>
    switch (phase) {
      PomodoroPhase.idle => strings.readyToFocus,
      PomodoroPhase.focus => strings.focus,
      PomodoroPhase.shortBreak => strings.shortBreak,
      PomodoroPhase.longBreak => strings.longBreak,
    };

IconData _phaseIcon(
  PomodoroPhase phase, {
  required PomodoroIntent intent,
  required bool systemFrozen,
}) {
  if (systemFrozen || intent == PomodoroIntent.userPaused) {
    return Icons.pause_circle_outline_rounded;
  }
  return switch (phase) {
    PomodoroPhase.idle => Icons.timer_outlined,
    PomodoroPhase.focus => Icons.center_focus_strong_rounded,
    PomodoroPhase.shortBreak ||
    PomodoroPhase.longBreak => Icons.coffee_outlined,
  };
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
