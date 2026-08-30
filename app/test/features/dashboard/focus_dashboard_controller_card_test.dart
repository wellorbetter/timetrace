import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/core/notifications/notification_provider.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/focus_dashboard_controller_card.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';

void main() {
  test('system freeze is limited to running invalid activity states', () {
    for (final state in [
      ActivitySnapshotState.idle,
      ActivitySnapshotState.paused,
      ActivitySnapshotState.unavailable,
    ]) {
      expect(
        isPomodoroSystemFrozen(_runtimeState(activityState: state)),
        isTrue,
        reason: '$state must freeze a running Pomodoro',
      );
    }

    for (final state in [
      ActivitySnapshotState.active,
      ActivitySnapshotState.excluded,
    ]) {
      expect(
        isPomodoroSystemFrozen(_runtimeState(activityState: state)),
        isFalse,
        reason: '$state remains eligible',
      );
    }

    expect(isPomodoroSystemFrozen(_runtimeState()), isFalse);
    expect(
      isPomodoroSystemFrozen(
        _runtimeState(
          activityState: ActivitySnapshotState.idle,
          intent: PomodoroIntent.userPaused,
        ),
      ),
      isFalse,
      reason: 'a user pause is not presented as a system freeze',
    );
  });

  testWidgets(
    'controller card exposes all six commands and excluded advances',
    (tester) async {
      final activity = _FakeActivitySource(
        ActivitySnapshot.idle(revision: 1, observedAt: _observedAt),
      );
      final clock = _FakeClock();
      final tasks = _FakeTaskFactory();
      await _pumpCard(tester, activity: activity, clock: clock, tasks: tasks);

      clock.value = const Duration(seconds: 1);
      tasks.fire();
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-start')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-pause')), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-reset')), findsOneWidget);
      expect(find.text('活动暂停中'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-pause')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-resume')), findsOneWidget);
      expect(find.text('活动暂停中'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('focus-resume')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-pause')), findsOneWidget);

      activity.snapshot = ActivitySnapshot.excluded(
        revision: 2,
        observedAt: _observedAt.add(const Duration(seconds: 1)),
      );
      clock.value = const Duration(seconds: 2);
      tasks.fire();
      await tester.pump();
      expect(find.text('活动暂停中'), findsNothing);
      expect(find.text('24:59'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-skip')));
      await tester.pump();
      expect(find.text('短休息'), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-resume')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-stop')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('focus-start')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('focus-reset')));
      await tester.tap(find.byKey(const ValueKey('focus-reset')));
      await tester.pump();
      expect(find.byKey(const ValueKey('focus-start')), findsOneWidget);
      expect(find.byKey(const ValueKey('focus-reset')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('maps only privacy-safe continuous application context', (
    tester,
  ) async {
    const privatePath = r'C:\Users\private\Browser\browser.exe';
    final activity = _FakeActivitySource(
      ActivitySnapshot.active(
        revision: 1,
        observedAt: _observedAt,
        application: const ActivityApplication(
          executablePath: privatePath,
          displayName: 'Browser',
        ),
      ),
    );
    final clock = _FakeClock();
    final tasks = _FakeTaskFactory();
    await _pumpCard(
      tester,
      activity: activity,
      clock: clock,
      tasks: tasks,
      appRule: const AppTimeoutRule(
        id: 1,
        executablePath: privatePath,
        displayName: 'Browser',
        threshold: Duration(minutes: 1),
        cooldown: Duration(minutes: 5),
        enabled: true,
        repeatEnabled: false,
      ),
    );

    clock.value = const Duration(seconds: 1);
    tasks.fire();
    clock.value = const Duration(seconds: 2);
    tasks.fire();
    await tester.pump();

    expect(find.text('Browser'), findsOneWidget);
    expect(find.textContaining('阈值 1 分钟'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('browser.exe'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps in-flight progress on its captured phase duration', (
    tester,
  ) async {
    final activity = _FakeActivitySource(
      ActivitySnapshot.active(
        revision: 1,
        observedAt: _observedAt,
        application: const ActivityApplication(
          executablePath: r'C:\Apps\editor.exe',
          displayName: 'Editor',
        ),
      ),
    );
    final configuration = _FakeConfigurationSource(
      _configuration(focus: const Duration(minutes: 25)),
    );
    final clock = _FakeClock();
    final tasks = _FakeTaskFactory();
    await _pumpCard(
      tester,
      activity: activity,
      configuration: configuration,
      clock: clock,
      tasks: tasks,
    );

    clock.value = const Duration(seconds: 1);
    tasks.fire();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('focus-start')));
    await tester.pump();

    configuration.configuration = _configuration(
      focus: const Duration(minutes: 50),
    );
    clock.value = const Duration(seconds: 2);
    tasks.fire();
    await tester.pump();

    final progress = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('focus-progress')),
    );
    expect(progress.value, closeTo(1 / 1500, 0.0000001));
    expect(find.text('24:59'), findsOneWidget);
  });

  testWidgets('real dashboard host watches English locale', (tester) async {
    final activity = _FakeActivitySource(
      ActivitySnapshot.idle(revision: 1, observedAt: _observedAt),
    );
    final clock = _FakeClock();
    final tasks = _FakeTaskFactory();
    await _pumpCard(
      tester,
      activity: activity,
      clock: clock,
      tasks: tasks,
      englishLocale: true,
    );
    clock.value = const Duration(seconds: 1);
    tasks.fire();
    await tester.pump();

    expect(find.text('Focus & reminders'), findsOneWidget);
    expect(find.text('Ready to focus'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.textContaining('专注'), findsNothing);
  });
}

final _observedAt = DateTime(2026, 8, 31, 12);

ReminderRuntimeState _runtimeState({
  ActivitySnapshotState? activityState,
  PomodoroIntent intent = PomodoroIntent.running,
}) {
  return ReminderRuntimeState(
    pomodoro: PomodoroState(
      phase: PomodoroPhase.focus,
      intent: intent,
      remaining: const Duration(minutes: 25),
      completedFocusCount: 0,
    ),
    continuousUse: const ContinuousUseState.empty(),
    activity: activityState == null ? null : _snapshot(activityState),
    configuration: _configuration(),
    notificationHealth: const NotificationHealth.uninitialized(),
    tickCount: 1,
    lastCallbackWasGap: false,
  );
}

ActivitySnapshot _snapshot(ActivitySnapshotState state) {
  return switch (state) {
    ActivitySnapshotState.active => ActivitySnapshot.active(
      revision: 1,
      observedAt: _observedAt,
      application: const ActivityApplication(
        executablePath: r'C:\Apps\editor.exe',
        displayName: 'Editor',
      ),
    ),
    ActivitySnapshotState.idle => ActivitySnapshot.idle(
      revision: 1,
      observedAt: _observedAt,
    ),
    ActivitySnapshotState.excluded => ActivitySnapshot.excluded(
      revision: 1,
      observedAt: _observedAt,
    ),
    ActivitySnapshotState.paused => ActivitySnapshot.paused(
      revision: 1,
      observedAt: _observedAt,
    ),
    ActivitySnapshotState.unavailable => ActivitySnapshot.unavailable(
      revision: 1,
      observedAt: _observedAt,
    ),
  };
}

ReminderConfigurationSnapshot _configuration({
  AppTimeoutRule? appRule,
  Duration focus = const Duration(minutes: 25),
}) {
  return ReminderConfigurationSnapshot(
    pomodoro: PomodoroConfig(enabled: true, focusDuration: focus),
    appTimeoutEnabled: appRule != null,
    appTimeoutNotificationsEnabled: true,
    appTimeoutNotificationSound: false,
    rulesRevision: appRule == null ? 0 : 1,
    appTimeoutRules: appRule == null ? const [] : [appRule],
  );
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required _FakeActivitySource activity,
  required _FakeClock clock,
  required _FakeTaskFactory tasks,
  AppTimeoutRule? appRule,
  _FakeConfigurationSource? configuration,
  bool englishLocale = false,
}) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (englishLocale)
          localeProvider.overrideWith(_EnglishLocaleNotifier.new),
        apiProvider.overrideWithValue(_FakeApi()),
        activitySnapshotSourceProvider.overrideWithValue(activity),
        reminderConfigurationSourceProvider.overrideWithValue(
          configuration ??
              _FakeConfigurationSource(_configuration(appRule: appRule)),
        ),
        notificationPortProvider.overrideWithValue(_FakeNotificationPort()),
        reminderMonotonicClockProvider.overrideWithValue(clock),
        reminderPeriodicTaskFactoryProvider.overrideWithValue(tasks.create),
      ],
      child: const MaterialApp(
        home: Scaffold(body: FocusDashboardControllerCard()),
      ),
    ),
  );
  await tester.pump();
}

final class _EnglishLocaleNotifier extends LocaleNotifier {
  @override
  AppLocale build() => AppLocale.en;
}

final class _FakeActivitySource implements ActivitySnapshotSource {
  _FakeActivitySource(this.snapshot);

  ActivitySnapshot snapshot;

  @override
  ActivitySnapshot readActivitySnapshot() => snapshot;
}

final class _FakeConfigurationSource implements ReminderConfigurationSource {
  _FakeConfigurationSource(this.configuration);

  ReminderConfigurationSnapshot configuration;

  @override
  ReminderConfigurationSnapshot readReminderConfiguration() => configuration;
}

final class _FakeNotificationPort implements NotificationPort {
  @override
  NotificationHealth get health => const NotificationHealth.uninitialized();

  @override
  Future<NotificationDeliveryResult> authorize({required bool sound}) async {
    return const NotificationDeliveryResult.ready();
  }

  @override
  Future<NotificationDeliveryResult> show(NotificationMessage message) async {
    return const NotificationDeliveryResult.delivered();
  }

  @override
  Future<NotificationDeliveryResult> test({
    required bool sound,
    required NotificationMessage message,
  }) async {
    return const NotificationDeliveryResult.delivered();
  }
}

final class _FakeClock implements ReminderMonotonicClock {
  Duration value = Duration.zero;

  @override
  Duration get elapsed => value;
}

final class _FakeTaskFactory {
  late void Function() callback;

  ReminderPeriodicTask create(Duration interval, void Function() callback) {
    expect(interval, ReminderRuntimeController.tickInterval);
    this.callback = callback;
    return _FakeTask();
  }

  void fire() => callback();
}

final class _FakeTask implements ReminderPeriodicTask {
  bool active = true;

  @override
  bool get isActive => active;

  @override
  void cancel() => active = false;
}

final class _FakeApi implements TimeTraceApi {
  @override
  ConfigDto getConfig() => ConfigDto(
    pollIntervalMs: BigInt.from(1000),
    idleThresholdMinutes: BigInt.from(5),
    minimizeToTray: true,
    startMinimized: false,
    autoStartTracking: true,
    excludedApps: const [],
    dbPath: '',
    pomodoro: PomodoroConfigDto(
      enabled: true,
      focusMinutes: BigInt.from(25),
      shortBreakMinutes: BigInt.from(5),
      longBreakMinutes: BigInt.from(15),
      longBreakInterval: BigInt.from(4),
      autoStartNext: false,
      notificationsEnabled: true,
      notificationSound: false,
    ),
    appTimeout: AppTimeoutConfigDto(
      enabled: false,
      defaultThresholdMinutes: BigInt.from(60),
      defaultCooldownMinutes: BigInt.from(30),
      notificationsEnabled: true,
      notificationSound: false,
    ),
  );

  @override
  List<AppTimeoutRuleDto> listAppTimeoutRules() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
