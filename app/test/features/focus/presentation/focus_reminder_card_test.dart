import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_reminder_card.dart';

void main() {
  testWidgets('uses two columns at desktop width without overflow', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    await _pumpCard(
      tester,
      state: const PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 18, seconds: 4),
        completedFocusCount: 2,
      ),
    );

    expect(
      find.byKey(const ValueKey('focus-card-two-column-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('focus-card-stacked-layout')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('stacks at narrow width without overflow', (tester) async {
    await _setSurface(tester, const Size(420, 620));
    await _pumpCard(
      tester,
      state: const PomodoroState(
        phase: PomodoroPhase.shortBreak,
        intent: PomodoroIntent.userPaused,
        remaining: Duration(minutes: 4),
        completedFocusCount: 1,
      ),
    );

    expect(
      find.byKey(const ValueKey('focus-card-stacked-layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('focus-card-two-column-layout')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('exposes context-valid callbacks', (tester) async {
    await _setSurface(tester, const Size(940, 620));
    var start = 0;
    var pause = 0;
    var resume = 0;
    var skip = 0;
    var stop = 0;

    await _pumpCard(
      tester,
      state: const PomodoroState.initial(),
      onStart: () => start++,
      onPause: () => pause++,
      onResume: () => resume++,
      onSkip: () => skip++,
      onStop: () => stop++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-start')));
    expect(start, 1);

    await _pumpCard(
      tester,
      state: const PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 20),
        completedFocusCount: 0,
      ),
      onStart: () => start++,
      onPause: () => pause++,
      onResume: () => resume++,
      onSkip: () => skip++,
      onStop: () => stop++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-pause')));
    await tester.tap(find.byKey(const ValueKey('focus-skip')));
    await tester.tap(find.byKey(const ValueKey('focus-stop')));
    expect((pause, skip, stop), (1, 1, 1));

    await _pumpCard(
      tester,
      state: const PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.userPaused,
        remaining: Duration(minutes: 20),
        completedFocusCount: 0,
      ),
      onResume: () => resume++,
    );
    await tester.tap(find.byKey(const ValueKey('focus-resume')));
    expect(resume, 1);
  });

  testWidgets('countdown semantics are useful but not a live region', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    final semantics = tester.ensureSemantics();
    await _pumpCard(
      tester,
      state: const PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 12),
        completedFocusCount: 3,
      ),
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey('focus-countdown-semantics')),
    );
    expect(node.label, contains('专注'));
    expect(node.label, contains('剩余'));
    expect(node.flagsCollection.isLiveRegion, isFalse);
    semantics.dispose();
  });

  testWidgets('shows only privacy-safe application status', (tester) async {
    await _setSurface(tester, const Size(940, 620));
    const privatePath = r'C:\Users\private\Secret App\secret.exe';
    await _pumpCard(
      tester,
      state: const PomodoroState.initial(),
      currentApplicationName: 'Secret App',
      currentApplicationElapsed: const Duration(minutes: 42),
      currentApplicationThreshold: const Duration(hours: 1),
    );

    expect(find.text('Secret App'), findsOneWidget);
    expect(find.textContaining('42 分钟'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('secret.exe'), findsNothing);
  });

  testWidgets('marks the page as real-time without relying on color', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    final semantics = tester.ensureSemantics();
    await _pumpCard(tester, state: const PomodoroState.initial());

    expect(find.byKey(const ValueKey('focus-realtime-label')), findsOneWidget);
    expect(find.text('实时'), findsOneWidget);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('focus-realtime-label')),
    );
    expect(node.label, contains('实时数据'));
    semantics.dispose();
  });

  testWidgets('redacts a path accidentally supplied as the display name', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    const privatePath = r'C:\Users\private\Secret App\secret.exe';
    await _pumpCard(
      tester,
      state: const PomodoroState.initial(),
      currentApplicationName: privatePath,
      currentApplicationElapsed: const Duration(minutes: 2),
    );

    expect(find.text('当前应用'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('secret.exe'), findsNothing);
  });

  testWidgets('renders complete English copy while preserving redaction', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    const privatePath = r'C:\Users\private\Secret App\secret.exe';
    await _pumpCard(
      tester,
      strings: ReminderL10n.en,
      state: const PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 12),
        completedFocusCount: 1,
      ),
      currentApplicationName: privatePath,
      currentApplicationElapsed: const Duration(minutes: 8),
    );

    expect(find.text('Focus & reminders'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Current application'), findsOneWidget);
    expect(
      find.textContaining('Used continuously for 8 minutes'),
      findsOneWidget,
    );
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('专注'), findsNothing);
  });
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required PomodoroState state,
  String? currentApplicationName,
  Duration? currentApplicationElapsed,
  Duration? currentApplicationThreshold,
  VoidCallback? onStart,
  VoidCallback? onPause,
  VoidCallback? onResume,
  VoidCallback? onSkip,
  VoidCallback? onStop,
  ReminderL10n strings = ReminderL10n.zh,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: FocusReminderCard(
            strings: strings,
            config: const PomodoroConfig(enabled: true),
            state: state,
            currentApplicationName: currentApplicationName,
            currentApplicationElapsed: currentApplicationElapsed,
            currentApplicationThreshold: currentApplicationThreshold,
            onStart: onStart,
            onPause: onPause,
            onResume: onResume,
            onSkip: onSkip,
            onStop: onStop,
          ),
        ),
      ),
    ),
  );
}
