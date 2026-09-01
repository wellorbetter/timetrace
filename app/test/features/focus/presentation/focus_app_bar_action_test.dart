import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_app_bar_action.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_quick_panel.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';

void main() {
  test(
    'closed projection ignores identity continuous-use health and tick updates',
    () {
      const firstApplication = ActivityApplication(
        executablePath: r'C:\Apps\first.exe',
        displayName: 'First',
      );
      const secondApplication = ActivityApplication(
        executablePath: r'C:\Apps\second.exe',
        displayName: 'Second',
      );
      final initial = _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
        ),
        activity: ActivitySnapshot.active(
          revision: 1,
          observedAt: DateTime(2026, 9),
          application: firstApplication,
        ),
      );
      final notifier = _FakeRuntimeNotifier(initial);
      final container = ProviderContainer(
        overrides: [reminderRuntimeProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      final selected = reminderRuntimeProvider.select(
        FocusAppBarProjection.fromRuntime,
      );
      var projectionChanges = 0;
      final subscription = container.listen(selected, (_, _) {
        projectionChanges++;
      });
      addTearDown(subscription.close);

      final first = subscription.read();
      expect(first.activityState, ActivitySnapshotState.active);
      expect(first.remainingSeconds, 1499);

      notifier.replaceRuntime(
        _runtime(
          pomodoro: initial.pomodoro,
          activity: ActivitySnapshot.active(
            revision: 2,
            observedAt: DateTime(2026, 9, 1, 0, 0, 1),
            application: secondApplication,
          ),
          continuousUse: const ContinuousUseState(
            application: secondApplication,
            elapsed: Duration(minutes: 42),
            rulesRevision: 7,
            matchedRule: null,
            lastNotificationElapsed: null,
          ),
          notificationHealth: const NotificationHealth(
            NotificationHealthStatus.denied,
            errorCode: 'denied',
          ),
          tickCount: 99,
        ),
      );

      expect(projectionChanges, 0);
      expect(subscription.read(), first);

      notifier.replaceRuntime(
        _runtime(
          pomodoro: initial.pomodoro.copyWith(
            remaining: const Duration(minutes: 24, seconds: 58),
          ),
          activity: initial.activity,
        ),
      );
      expect(projectionChanges, 1);
      expect(subscription.read().remainingSeconds, 1498);
    },
  );

  testWidgets('status capsule covers every product state in English', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1280, 800));

    await _pumpAction(
      tester,
      runtime: _runtime(enabled: false),
      strings: ReminderL10n.en,
    );
    expect(find.text('Disabled'), findsOneWidget);

    await _pumpAction(tester, runtime: _runtime(), strings: ReminderL10n.en);
    expect(find.text('Ready to focus'), findsOneWidget);

    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
        ),
      ),
      strings: ReminderL10n.en,
    );
    expect(find.text('Focus 24:59'), findsOneWidget);

    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.userPaused,
        ),
      ),
      strings: ReminderL10n.en,
    );
    expect(find.text('Paused 24:59'), findsOneWidget);

    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.shortBreak,
          intent: PomodoroIntent.running,
          remaining: const Duration(minutes: 4, seconds: 30),
          phaseDuration: const Duration(minutes: 5),
        ),
      ),
      strings: ReminderL10n.en,
    );
    expect(find.text('Short break 04:30'), findsOneWidget);

    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
        ),
        activity: ActivitySnapshot.idle(
          revision: 1,
          observedAt: DateTime(2026, 9),
        ),
      ),
      strings: ReminderL10n.en,
    );
    expect(find.text('Timer paused 24:59'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded trigger keeps a stable width across the hour boundary',
    (tester) async {
      await _setSurface(tester, const Size(1280, 800));
      final notifier = _FakeRuntimeNotifier(
        _runtime(
          pomodoro: _pomodoro(
            phase: PomodoroPhase.focus,
            intent: PomodoroIntent.running,
            remaining: const Duration(minutes: 60),
            phaseDuration: const Duration(minutes: 60),
          ),
        ),
      );
      await _pumpAction(tester, notifier: notifier, strings: ReminderL10n.en);

      final trigger = find.byKey(const ValueKey('focus-app-bar-trigger'));
      expect(find.text('Focus 01:00:00'), findsOneWidget);
      final widthAtSixtyMinutes = tester.getSize(trigger).width;

      notifier.replaceRuntime(
        _runtime(
          pomodoro: _pomodoro(
            phase: PomodoroPhase.focus,
            intent: PomodoroIntent.running,
            remaining: const Duration(minutes: 59, seconds: 59),
            phaseDuration: const Duration(minutes: 60),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Focus 59:59'), findsOneWidget);
      expect(tester.getSize(trigger).width, widthAtSixtyMinutes);
      expect(widthAtSixtyMinutes, FocusAppBarAction.expandedTriggerWidth);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user-paused trigger has a non-color pause icon', (tester) async {
    await _setSurface(tester, const Size(1280, 800));
    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.userPaused,
        ),
      ),
    );

    final trigger = find.byKey(const ValueKey('focus-app-bar-trigger'));
    expect(
      find.descendant(
        of: trigger,
        matching: find.byIcon(Icons.pause_circle_outline_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: trigger,
        matching: find.byIcon(Icons.center_focus_strong_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets('opens a 352px MenuAnchor panel with no opening side effect', (
    tester,
  ) async {
    await _setSurface(tester, const Size(1280, 800));
    final notifier = _FakeRuntimeNotifier(_runtime());
    await _pumpAction(tester, notifier: notifier);

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('focus-quick-panel')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('focus-quick-panel'))).width,
      FocusQuickPanel.preferredWidth,
    );
    expect(notifier.totalCommandCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape closes and restores focus to the trigger', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    await _pumpAction(tester, runtime: _runtime());

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-quick-panel')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('focus-quick-panel')), findsNothing);
    final trigger = tester.widget<IconButton>(
      find.byKey(const ValueKey('focus-app-bar-trigger')),
    );
    expect(trigger.focusNode?.hasFocus, isTrue);
  });

  testWidgets('outside click closes without activating content underneath', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    var outsideCalls = 0;
    await _pumpAction(
      tester,
      runtime: _runtime(),
      onOutsidePressed: () => outsideCalls++,
    );

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outside-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('focus-quick-panel')), findsNothing);
    expect(outsideCalls, 0);

    await tester.tap(find.byKey(const ValueKey('outside-action')));
    expect(outsideCalls, 1);
  });

  testWidgets('dispatches complete command set through the runtime provider', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    final notifier = _FakeRuntimeNotifier(_runtime());
    await _pumpAction(tester, notifier: notifier);

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('focus-quick-start')));
    await tester.pump();
    expect(notifier.startCalls, 1);
    expect(find.byKey(const ValueKey('focus-quick-pause')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('focus-quick-pause')));
    await tester.pump();
    expect(notifier.pauseCalls, 1);
    expect(find.byKey(const ValueKey('focus-quick-resume')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('focus-quick-resume')));
    await tester.pump();
    expect(notifier.resumeCalls, 1);

    await tester.tap(find.byKey(const ValueKey('focus-quick-skip')));
    await tester.pump();
    expect(notifier.skipCalls, 1);
    expect(find.text('短休息'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('focus-quick-stop')));
    await tester.pump();
    expect(notifier.stopCalls, 1);
    expect(find.byKey(const ValueKey('focus-quick-start')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('focus-quick-start')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('focus-quick-reset')));
    await tester.pump();
    expect(notifier.resetCalls, 1);
    expect(find.byKey(const ValueKey('focus-quick-start')), findsOneWidget);
  });

  testWidgets('settings closes the panel before invoking host navigation', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    var settingsCalls = 0;
    await _pumpAction(
      tester,
      runtime: _runtime(),
      onOpenSettings: () => settingsCalls++,
    );

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('focus-quick-settings')));
    await tester.pumpAndSettle();

    expect(settingsCalls, 1);
    expect(find.byKey(const ValueKey('focus-quick-panel')), findsNothing);
  });

  testWidgets('narrow window uses icon state with bilingual semantics', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    final semantics = tester.ensureSemantics();
    await _pumpAction(
      tester,
      runtime: _runtime(
        pomodoro: _pomodoro(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
        ),
      ),
      strings: ReminderL10n.en,
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('focus-app-bar-trigger')),
        matching: find.byType(Text),
      ),
      findsNothing,
    );
    final node = tester.getSemantics(
      find.byKey(const ValueKey('focus-app-bar-semantics')),
    );
    expect(node.label, contains('Pomodoro'));
    expect(node.label, contains('Focus'));
    expect(node.flagsCollection.isLiveRegion, isFalse);
    expect(node.flagsCollection.isExpanded, ui.Tristate.isFalse);

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    final expanded = tester.getSemantics(
      find.byKey(const ValueKey('focus-app-bar-semantics')),
    );
    expect(expanded.flagsCollection.isExpanded, ui.Tristate.isTrue);
    expect(find.text('Pomodoro'), findsOneWidget);
    expect(find.textContaining('番茄钟'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets(
    '940x620 at 2x text keeps menu in bounds and scrolls to end controls',
    (tester) async {
      await _setSurface(tester, const Size(940, 620));
      await _pumpAction(
        tester,
        runtime: _runtime(
          pomodoro: _pomodoro(
            phase: PomodoroPhase.focus,
            intent: PomodoroIntent.running,
          ),
        ),
        strings: ReminderL10n.en,
        textScaler: const TextScaler.linear(2),
      );

      await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final panel = find.byKey(const ValueKey('focus-quick-panel'));
      final scrollable = find.ancestor(
        of: panel,
        matching: find.byType(Scrollable),
      );
      expect(panel, findsOneWidget);
      expect(scrollable, findsOneWidget);

      final menuRect = tester.getRect(scrollable);
      const viewport = Rect.fromLTWH(0, 0, 940, 620);
      expect(menuRect.left, greaterThanOrEqualTo(viewport.left));
      expect(menuRect.top, greaterThanOrEqualTo(viewport.top));
      expect(menuRect.right, lessThanOrEqualTo(viewport.right));
      expect(menuRect.bottom, lessThanOrEqualTo(viewport.bottom));

      final settings = find.byKey(const ValueKey('focus-quick-settings'));
      final reset = find.byKey(const ValueKey('focus-quick-reset'));
      expect(settings.hitTestable(), findsOneWidget);
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));

      await tester.scrollUntilVisible(reset, 120, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(reset.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(settings, -120, scrollable: scrollable);
      await tester.pumpAndSettle();
      expect(settings.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('runtime path and display identity never enter the quick panel', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    const privatePath = r'C:\Users\private\Secret Browser\browser.exe';
    await _pumpAction(
      tester,
      runtime: _runtime(
        activity: ActivitySnapshot.active(
          revision: 1,
          observedAt: DateTime(2026, 9),
          application: const ActivityApplication(
            executablePath: privatePath,
            displayName: 'Secret Browser',
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('focus-app-bar-trigger')));
    await tester.pumpAndSettle();
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('browser.exe'), findsNothing);
    expect(find.text('Secret Browser'), findsNothing);
  });
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpAction(
  WidgetTester tester, {
  ReminderRuntimeState? runtime,
  _FakeRuntimeNotifier? notifier,
  ReminderL10n strings = ReminderL10n.zh,
  TextScaler textScaler = TextScaler.noScaling,
  VoidCallback? onOpenSettings,
  VoidCallback? onOutsidePressed,
}) async {
  final fake = notifier ?? _FakeRuntimeNotifier(runtime ?? _runtime());
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [reminderRuntimeProvider.overrideWith(() => fake)],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('TimeTrace'),
            actions: [
              FocusAppBarAction(
                strings: strings,
                onOpenSettings: onOpenSettings ?? () {},
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Center(
            child: FilledButton(
              key: const ValueKey('outside-action'),
              onPressed: onOutsidePressed ?? () {},
              child: const Text('Outside'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ReminderRuntimeState _runtime({
  bool enabled = true,
  PomodoroState pomodoro = const PomodoroState.initial(),
  ActivitySnapshot? activity,
  ContinuousUseState continuousUse = const ContinuousUseState.empty(),
  NotificationHealth notificationHealth =
      const NotificationHealth.uninitialized(),
  int tickCount = 0,
}) {
  return ReminderRuntimeState(
    pomodoro: pomodoro,
    continuousUse: continuousUse,
    activity: activity,
    configuration: ReminderConfigurationSnapshot(
      pomodoro: PomodoroConfig(enabled: enabled),
      appTimeoutEnabled: false,
      appTimeoutNotificationsEnabled: false,
      appTimeoutNotificationSound: false,
      rulesRevision: 0,
    ),
    notificationHealth: notificationHealth,
    tickCount: tickCount,
    lastCallbackWasGap: false,
  );
}

PomodoroState _pomodoro({
  required PomodoroPhase phase,
  required PomodoroIntent intent,
  Duration remaining = const Duration(minutes: 24, seconds: 59),
  Duration phaseDuration = const Duration(minutes: 25),
  int completedFocusCount = 1,
}) {
  return PomodoroState(
    phase: phase,
    intent: intent,
    remaining: remaining,
    phaseDuration: phaseDuration,
    completedFocusCount: completedFocusCount,
  );
}

final class _FakeRuntimeNotifier extends ReminderRuntimeNotifier {
  _FakeRuntimeNotifier(this.initial);

  final ReminderRuntimeState initial;
  int startCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int skipCalls = 0;
  int stopCalls = 0;
  int resetCalls = 0;

  int get totalCommandCalls =>
      startCalls +
      pauseCalls +
      resumeCalls +
      skipCalls +
      stopCalls +
      resetCalls;

  @override
  ReminderRuntimeState build() => initial;

  @override
  void startPomodoro() {
    startCalls++;
    _replacePomodoro(
      _pomodoro(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        completedFocusCount: state.pomodoro.completedFocusCount,
      ),
    );
  }

  @override
  void pausePomodoro() {
    pauseCalls++;
    _replacePomodoro(
      state.pomodoro.copyWith(intent: PomodoroIntent.userPaused),
    );
  }

  @override
  void resumePomodoro() {
    resumeCalls++;
    _replacePomodoro(state.pomodoro.copyWith(intent: PomodoroIntent.running));
  }

  @override
  void skipPomodoro() {
    skipCalls++;
    _replacePomodoro(
      _pomodoro(
        phase: PomodoroPhase.shortBreak,
        intent: PomodoroIntent.ready,
        remaining: const Duration(minutes: 5),
        phaseDuration: const Duration(minutes: 5),
        completedFocusCount: state.pomodoro.completedFocusCount,
      ),
    );
  }

  @override
  void stopPomodoro() {
    stopCalls++;
    _replacePomodoro(
      PomodoroState(
        phase: PomodoroPhase.idle,
        intent: PomodoroIntent.ready,
        remaining: Duration.zero,
        completedFocusCount: state.pomodoro.completedFocusCount,
      ),
    );
  }

  @override
  void resetPomodoro() {
    resetCalls++;
    _replacePomodoro(const PomodoroState.initial());
  }

  void replaceRuntime(ReminderRuntimeState next) => state = next;

  void _replacePomodoro(PomodoroState pomodoro) {
    final current = state;
    state = ReminderRuntimeState(
      pomodoro: pomodoro,
      continuousUse: current.continuousUse,
      activity: current.activity,
      configuration: current.configuration,
      notificationHealth: current.notificationHealth,
      tickCount: current.tickCount,
      lastCallbackWasGap: current.lastCallbackWasGap,
    );
  }
}
