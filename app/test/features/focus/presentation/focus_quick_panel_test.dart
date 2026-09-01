import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_quick_panel.dart';

void main() {
  testWidgets('is a compact fixed-width Pomodoro-only panel', (tester) async {
    await _setSurface(tester, const Size(420, 620));
    await _pumpPanel(tester, state: const PomodoroState.initial());

    final size = tester.getSize(
      find.byKey(const ValueKey('focus-quick-panel')),
    );
    expect(size.width, FocusQuickPanel.preferredWidth);
    expect(size.width, inInclusiveRange(336, 360));
    expect(find.text('番茄钟'), findsOneWidget);
    expect(find.text('当前应用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled state offers a settings call to action', (
    tester,
  ) async {
    await _setSurface(tester, const Size(420, 620));
    var settingsCalls = 0;
    await _pumpPanel(
      tester,
      config: const PomodoroConfig(),
      state: const PomodoroState.initial(),
      onOpenSettings: () => settingsCalls++,
    );

    expect(find.text('在设置中启用番茄钟后即可开始。'), findsOneWidget);
    expect(find.byKey(const ValueKey('focus-quick-start')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('focus-quick-disabled-settings')),
    );
    expect(settingsCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders idle running paused break and frozen states', (
    tester,
  ) async {
    await _setSurface(tester, const Size(420, 620));

    await _pumpPanel(tester, state: const PomodoroState.initial());
    expect(find.text('准备专注'), findsOneWidget);
    expect(find.text('开始'), findsOneWidget);

    await _pumpPanel(
      tester,
      state: _state(phase: PomodoroPhase.focus, intent: PomodoroIntent.running),
    );
    expect(find.text('专注'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('24:59'), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);

    await _pumpPanel(
      tester,
      state: _state(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.userPaused,
      ),
    );
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);

    await _pumpPanel(
      tester,
      state: _state(
        phase: PomodoroPhase.shortBreak,
        intent: PomodoroIntent.running,
        remaining: const Duration(minutes: 4, seconds: 30),
        phaseDuration: const Duration(minutes: 5),
      ),
    );
    expect(find.text('短休息'), findsOneWidget);
    expect(find.text('04:30'), findsOneWidget);

    await _pumpPanel(
      tester,
      state: _state(
        phase: PomodoroPhase.longBreak,
        intent: PomodoroIntent.ready,
        remaining: const Duration(minutes: 15),
        phaseDuration: const Duration(minutes: 15),
      ),
    );
    expect(find.text('长休息'), findsOneWidget);
    expect(find.text('等待开始'), findsOneWidget);

    await _pumpPanel(
      tester,
      state: _state(phase: PomodoroPhase.focus, intent: PomodoroIntent.running),
      systemFrozen: true,
    );
    expect(find.text('计时暂停'), findsOneWidget);
    expect(find.textContaining('等待活动恢复'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispatches every contextual Pomodoro command', (tester) async {
    await _setSurface(tester, const Size(420, 620));
    var start = 0;
    var pause = 0;
    var resume = 0;
    var skip = 0;
    var stop = 0;
    var reset = 0;

    await _pumpPanel(
      tester,
      state: const PomodoroState.initial(),
      onStart: () => start++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-quick-start')));
    expect(start, 1);

    await _pumpPanel(
      tester,
      state: _state(phase: PomodoroPhase.focus, intent: PomodoroIntent.running),
      onPause: () => pause++,
      onSkip: () => skip++,
      onStop: () => stop++,
      onReset: () => reset++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-quick-pause')));
    await tester.tap(find.byKey(const ValueKey('focus-quick-skip')));
    await tester.tap(find.byKey(const ValueKey('focus-quick-stop')));
    await tester.tap(find.byKey(const ValueKey('focus-quick-reset')));
    expect((pause, skip, stop, reset), (1, 1, 1, 1));

    await _pumpPanel(
      tester,
      state: _state(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.userPaused,
      ),
      onResume: () => resume++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-quick-resume')));
    expect(resume, 1);
  });

  testWidgets('English countdown semantics are not a live region', (
    tester,
  ) async {
    await _setSurface(tester, const Size(420, 620));
    final semantics = tester.ensureSemantics();
    await _pumpPanel(
      tester,
      strings: ReminderL10n.en,
      state: _state(phase: PomodoroPhase.focus, intent: PomodoroIntent.running),
    );

    expect(find.text('Pomodoro'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('专注'), findsNothing);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('focus-quick-countdown-semantics')),
    );
    expect(node.label, contains('Focus'));
    expect(node.label, contains('remaining'));
    expect(node.flagsCollection.isLiveRegion, isFalse);

    await _pumpPanel(
      tester,
      strings: ReminderL10n.en,
      state: const PomodoroState.initial(),
    );
    final idleNode = tester.getSemantics(
      find.byKey(const ValueKey('focus-quick-countdown-semantics')),
    );
    expect(idleNode.label, contains('25:00'));
    expect(idleNode.flagsCollection.isLiveRegion, isFalse);
    semantics.dispose();
  });
}

PomodoroState _state({
  required PomodoroPhase phase,
  required PomodoroIntent intent,
  Duration remaining = const Duration(minutes: 24, seconds: 59),
  Duration phaseDuration = const Duration(minutes: 25),
}) {
  return PomodoroState(
    phase: phase,
    intent: intent,
    remaining: remaining,
    phaseDuration: phaseDuration,
    completedFocusCount: 2,
  );
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  required PomodoroState state,
  PomodoroConfig config = const PomodoroConfig(enabled: true),
  ReminderL10n strings = ReminderL10n.zh,
  bool systemFrozen = false,
  VoidCallback? onStart,
  VoidCallback? onPause,
  VoidCallback? onResume,
  VoidCallback? onSkip,
  VoidCallback? onStop,
  VoidCallback? onReset,
  VoidCallback? onOpenSettings,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: FocusQuickPanel(
            strings: strings,
            config: config,
            state: state,
            systemFrozen: systemFrozen,
            onStart: onStart ?? () {},
            onPause: onPause ?? () {},
            onResume: onResume ?? () {},
            onSkip: onSkip ?? () {},
            onStop: onStop ?? () {},
            onReset: onReset ?? () {},
            onOpenSettings: onOpenSettings ?? () {},
          ),
        ),
      ),
    ),
  );
}
