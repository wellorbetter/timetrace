import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/app_limits/domain/continuous_use.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';

void main() {
  test('each deterministic tick reads each source exactly once', () {
    final activity = _FakeActivitySource(_active(_appA));
    final configuration = _FakeConfigurationSource(_configuration());
    final controller = _controller(
      activity: activity,
      configuration: configuration,
    );
    var published = 0;
    controller.addListener((_) => published++);

    controller.advance(const Duration(seconds: 1));

    expect(activity.reads, 1);
    expect(configuration.reads, 1);
    expect(controller.state.tickCount, 1);
    expect(published, 1);
  });

  test('configuration snapshots protect their rules from mutation', () {
    final rules = <AppTimeoutRule>[_ruleA];
    final snapshot = _configuration(rules: rules);
    rules.clear();

    expect(snapshot.appTimeoutRules, const [_ruleA]);
    expect(() => snapshot.appTimeoutRules.add(_ruleB), throwsUnsupportedError);
  });

  test('a callback over 2.5 seconds freezes Pomodoro and resets app use', () {
    final activity = _FakeActivitySource(_active(_appA));
    final controller = _controller(
      activity: activity,
      configuration: _FakeConfigurationSource(
        _configuration(focus: const Duration(seconds: 3)),
      ),
    );

    controller.startPomodoro();
    controller.advance(Duration.zero);
    controller.advance(const Duration(seconds: 1));
    expect(controller.state.pomodoro.remaining, const Duration(seconds: 2));
    expect(controller.state.continuousUse.elapsed, const Duration(seconds: 1));

    controller.advance(const Duration(milliseconds: 2501));

    expect(controller.state.lastCallbackWasGap, isTrue);
    expect(controller.state.pomodoro.remaining, const Duration(seconds: 2));
    expect(controller.state.continuousUse.elapsed, Duration.zero);
    expect(controller.state.continuousUse.application, _appA);
  });

  test(
    'Pomodoro freezes for idle paused and unavailable while excluded continues',
    () {
      final activity = _FakeActivitySource(_idle());
      final controller = _controller(
        activity: activity,
        configuration: _FakeConfigurationSource(
          _configuration(focus: const Duration(seconds: 4)),
        ),
      );

      controller.startPomodoro();
      controller.advance(const Duration(seconds: 1));
      expect(controller.state.pomodoro.remaining, const Duration(seconds: 4));

      activity.snapshot = _excluded();
      controller.advance(const Duration(seconds: 1));
      expect(controller.state.pomodoro.remaining, const Duration(seconds: 3));
      expect(controller.state.continuousUse.hasSegment, isFalse);

      controller.pausePomodoro();
      activity.snapshot = _active(_appA);
      controller.advance(const Duration(seconds: 1));
      expect(controller.state.pomodoro.intent, PomodoroIntent.userPaused);
      expect(controller.state.pomodoro.remaining, const Duration(seconds: 3));

      controller.resumePomodoro();
      activity.snapshot = _paused();
      controller.advance(const Duration(seconds: 1));
      expect(controller.state.pomodoro.intent, PomodoroIntent.running);
      expect(controller.state.pomodoro.remaining, const Duration(seconds: 3));

      activity.snapshot = _unavailable();
      controller.advance(const Duration(seconds: 1));
      expect(controller.state.pomodoro.remaining, const Duration(seconds: 3));
      expect(controller.state.continuousUse.hasSegment, isFalse);
    },
  );

  test('Pomodoro completion maps to one typed notification effect', () async {
    final notifications = _FakeNotificationPort();
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: _FakeConfigurationSource(
        _configuration(
          focus: const Duration(seconds: 1),
          appTimeoutEnabled: false,
        ),
      ),
      notifications: notifications,
    );

    controller.startPomodoro();
    controller.advance(const Duration(seconds: 1));
    controller.advance(const Duration(seconds: 1));
    await _flushAsync();

    expect(notifications.messages, hasLength(1));
    expect(
      notifications.messages.single.kind,
      NotificationKind.pomodoroFocusComplete,
    );
    expect(notifications.messages.single.title, '专注完成');
    expect(controller.state.pomodoro.phase, PomodoroPhase.shortBreak);
  });

  test(
    'English runtime configuration localizes notification effects',
    () async {
      final notifications = _FakeNotificationPort();
      final controller = _controller(
        activity: _FakeActivitySource(_active(_appA)),
        configuration: _FakeConfigurationSource(
          _configuration(
            focus: const Duration(seconds: 1),
            appTimeoutEnabled: false,
            locale: AppLocale.en,
          ),
        ),
        notifications: notifications,
      );

      controller.startPomodoro();
      controller.advance(const Duration(seconds: 1));
      controller.advance(const Duration(seconds: 1));
      await _flushAsync();

      expect(notifications.messages.single.title, 'Focus complete');
      expect(notifications.messages.single.body, contains('5-minute break'));
      expect(notifications.messages.single.body, isNot(contains('专注')));
    },
  );

  test('application threshold maps once without path disclosure', () async {
    final notifications = _FakeNotificationPort();
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: _FakeConfigurationSource(
        _configuration(pomodoroEnabled: false, rules: const [_ruleA]),
      ),
      notifications: notifications,
    );

    controller.advance(Duration.zero);
    controller.advance(const Duration(seconds: 1));
    controller.advance(const Duration(seconds: 1));
    await _flushAsync();

    expect(notifications.messages, hasLength(1));
    final message = notifications.messages.single;
    expect(message.kind, NotificationKind.appTimeout);
    expect(message.body, contains('Alpha'));
    expect(message.body, isNot(contains(_pathA)));
    expect(message.payload, 'app-timeout');
  });

  test(
    'notification failure is non-fatal and never rolls back state',
    () async {
      final notifications = _FakeNotificationPort()..throwOnShow = true;
      final controller = _controller(
        activity: _FakeActivitySource(_active(_appA)),
        configuration: _FakeConfigurationSource(
          _configuration(
            focus: const Duration(seconds: 1),
            appTimeoutEnabled: false,
          ),
        ),
        notifications: notifications,
      );

      controller.startPomodoro();
      controller.advance(const Duration(seconds: 1));
      await _flushAsync();

      expect(controller.state.pomodoro.phase, PomodoroPhase.shortBreak);
      expect(controller.state.pomodoro.completedFocusCount, 1);
      expect(
        controller.state.notificationHealth.status,
        NotificationHealthStatus.failed,
      );
      expect(controller.state.notificationHealth.errorCode, 'delivery_failed');
    },
  );

  test(
    'notification denial remains visible without rolling back state',
    () async {
      final notifications = _FakeNotificationPort()
        ..result = const NotificationDeliveryResult(
          NotificationDeliveryStatus.denied,
          errorCode: 'permission_not_granted',
        );
      final controller = _controller(
        activity: _FakeActivitySource(_active(_appA)),
        configuration: _FakeConfigurationSource(
          _configuration(
            focus: const Duration(seconds: 1),
            appTimeoutEnabled: false,
          ),
        ),
        notifications: notifications,
      );

      controller.startPomodoro();
      controller.advance(const Duration(seconds: 1));
      await _flushAsync();

      expect(controller.state.pomodoro.phase, PomodoroPhase.shortBreak);
      expect(controller.state.pomodoro.completedFocusCount, 1);
      expect(
        controller.state.notificationHealth.status,
        NotificationHealthStatus.denied,
      );
      expect(
        controller.state.notificationHealth.errorCode,
        'permission_not_granted',
      );
    },
  );

  test('late notification completion cannot overwrite newer health', () async {
    final firstDelivery = Completer<NotificationDeliveryResult>();
    final secondDelivery = Completer<NotificationDeliveryResult>();
    final notifications = _FakeNotificationPort()
      ..pendingResults.addAll([firstDelivery, secondDelivery]);
    final immediateRule = AppTimeoutRule(
      id: _ruleA.id,
      executablePath: _ruleA.executablePath,
      displayName: _ruleA.displayName,
      threshold: const Duration(seconds: 1),
      cooldown: _ruleA.cooldown,
      enabled: _ruleA.enabled,
      repeatEnabled: _ruleA.repeatEnabled,
    );
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: _FakeConfigurationSource(
        _configuration(
          focus: const Duration(seconds: 1),
          rules: [immediateRule],
        ),
      ),
      notifications: notifications,
    );

    controller.startPomodoro();
    controller.advance(Duration.zero);
    controller.advance(const Duration(seconds: 1));
    expect(notifications.messages, hasLength(2));

    secondDelivery.complete(
      const NotificationDeliveryResult(
        NotificationDeliveryStatus.denied,
        errorCode: 'permission_not_granted',
      ),
    );
    await _flushAsync();
    expect(
      controller.state.notificationHealth.status,
      NotificationHealthStatus.denied,
    );

    firstDelivery.complete(const NotificationDeliveryResult.delivered());
    await _flushAsync();
    expect(
      controller.state.notificationHealth.status,
      NotificationHealthStatus.denied,
    );
    expect(
      controller.state.notificationHealth.errorCode,
      'permission_not_granted',
    );
  });

  test(
    'port health protects a newer external denial from a stale delivery',
    () async {
      final staleDelivery = Completer<NotificationDeliveryResult>();
      final notifications = _FakeNotificationPort()
        ..pendingResults.add(staleDelivery);
      final controller = _controller(
        activity: _FakeActivitySource(_active(_appA)),
        configuration: _FakeConfigurationSource(
          _configuration(
            focus: const Duration(seconds: 1),
            appTimeoutEnabled: false,
          ),
        ),
        notifications: notifications,
      );

      controller.startPomodoro();
      controller.advance(const Duration(seconds: 1));
      expect(notifications.messages, hasLength(1));

      notifications.currentHealth = const NotificationHealth(
        NotificationHealthStatus.denied,
        errorCode: 'permission_denied',
      );
      staleDelivery.complete(const NotificationDeliveryResult.delivered());
      await _flushAsync();

      expect(
        controller.state.notificationHealth.status,
        NotificationHealthStatus.denied,
      );
      expect(
        controller.state.notificationHealth.errorCode,
        'permission_denied',
      );
    },
  );

  test('global switches reset transient state without notifications', () {
    final configuration = _FakeConfigurationSource(_configuration());
    final notifications = _FakeNotificationPort();
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: configuration,
      notifications: notifications,
    );

    controller.startPomodoro();
    controller.advance(Duration.zero);
    controller.advance(const Duration(seconds: 1));
    expect(controller.state.pomodoro.isIdle, isFalse);
    expect(controller.state.continuousUse.hasSegment, isTrue);

    configuration.snapshot = _configuration(
      pomodoroEnabled: false,
      appTimeoutEnabled: false,
      rulesRevision: 2,
    );
    controller.advance(const Duration(seconds: 1));

    expect(controller.state.pomodoro.isIdle, isTrue);
    expect(
      controller.state.continuousUse,
      const ContinuousUseState.empty(rulesRevision: 2),
    );
    expect(notifications.messages, isEmpty);
  });

  test(
    'fully disabled ticks skip activity reads and re-enable on the next tick',
    () {
      final activity = _FakeActivitySource(_active(_appA));
      final configuration = _FakeConfigurationSource(
        _configuration(pomodoroEnabled: false, appTimeoutEnabled: false),
      );
      final controller = _controller(
        activity: activity,
        configuration: configuration,
      );

      controller.advance(const Duration(seconds: 1));
      controller.advance(const Duration(seconds: 1));

      expect(configuration.reads, 2);
      expect(activity.reads, 0);
      expect(controller.state.tickCount, 2);
      expect(controller.state.activity, isNull);

      configuration.snapshot = _configuration(appTimeoutEnabled: false);
      controller.advance(const Duration(seconds: 1));

      expect(configuration.reads, 3);
      expect(activity.reads, 1);
      expect(controller.state.configuration.pomodoro.enabled, isTrue);
      expect(controller.state.activity?.state, ActivitySnapshotState.active);
    },
  );

  test(
    'notification preference suppresses delivery without stopping state',
    () {
      final notifications = _FakeNotificationPort();
      final controller = _controller(
        activity: _FakeActivitySource(_active(_appA)),
        configuration: _FakeConfigurationSource(
          _configuration(
            pomodoroEnabled: false,
            appTimeoutNotificationsEnabled: false,
            rules: const [_ruleA],
          ),
        ),
        notifications: notifications,
      );

      controller.advance(Duration.zero);
      controller.advance(const Duration(seconds: 2));

      expect(controller.state.continuousUse.lastNotificationElapsed, isNotNull);
      expect(notifications.messages, isEmpty);
    },
  );

  test('timer start and dispose are idempotent and own one callback', () {
    final clock = _FakeClock();
    final tasks = _FakePeriodicTaskFactory();
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: _FakeConfigurationSource(_configuration()),
      clock: clock,
      periodicTaskFactory: tasks.create,
    );
    var published = 0;
    controller.addListener((_) => published++);

    controller.start();
    controller.start();
    expect(tasks.created, 1);
    expect(tasks.interval, ReminderRuntimeController.tickInterval);

    clock.value = const Duration(seconds: 1);
    tasks.fire();
    expect(controller.state.tickCount, 1);
    expect(published, 1);

    controller.dispose();
    controller.dispose();
    expect(tasks.task.cancelCalls, 1);
    expect(controller.isDisposed, isTrue);
    expect(controller.isStarted, isFalse);

    clock.value = const Duration(seconds: 2);
    tasks.fire();
    controller.advance(const Duration(seconds: 1));
    controller.startPomodoro();
    expect(controller.state.tickCount, 1);
    expect(published, 1);
  });

  test('periodic callbacks use monotonic deltas and classify a late tick', () {
    final clock = _FakeClock();
    final tasks = _FakePeriodicTaskFactory();
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: _FakeConfigurationSource(_configuration()),
      clock: clock,
      periodicTaskFactory: tasks.create,
    );

    controller.start();
    clock.value = const Duration(seconds: 1);
    tasks.fire();
    expect(controller.state.lastCallbackWasGap, isFalse);

    clock.value = const Duration(milliseconds: 3600);
    tasks.fire();
    expect(controller.state.lastCallbackWasGap, isTrue);
  });

  test('failed configuration read retains the last successful snapshot', () {
    final configuration = _FakeConfigurationSource(
      _configuration(focus: const Duration(seconds: 3)),
    );
    final controller = _controller(
      activity: _FakeActivitySource(_active(_appA)),
      configuration: configuration,
    );

    controller.startPomodoro();
    configuration.throwOnRead = true;
    controller.advance(const Duration(seconds: 1));

    expect(controller.state.pomodoro.remaining, const Duration(seconds: 2));
    expect(configuration.reads, 2);
  });
}

ReminderRuntimeController _controller({
  required _FakeActivitySource activity,
  required _FakeConfigurationSource configuration,
  _FakeNotificationPort? notifications,
  ReminderMonotonicClock? clock,
  ReminderPeriodicTaskFactory? periodicTaskFactory,
}) {
  return ReminderRuntimeController(
    activitySource: activity,
    configurationSource: configuration,
    notificationPort: notifications ?? _FakeNotificationPort(),
    clock: clock,
    periodicTaskFactory: periodicTaskFactory,
  );
}

ReminderConfigurationSnapshot _configuration({
  bool pomodoroEnabled = true,
  Duration focus = const Duration(seconds: 5),
  bool appTimeoutEnabled = true,
  bool appTimeoutNotificationsEnabled = true,
  int rulesRevision = 1,
  List<AppTimeoutRule> rules = const [_ruleA],
  AppLocale locale = AppLocale.zh,
}) {
  return ReminderConfigurationSnapshot(
    pomodoro: PomodoroConfig(
      enabled: pomodoroEnabled,
      focusDuration: focus,
      shortBreakDuration: const Duration(minutes: 5),
      longBreakDuration: const Duration(minutes: 15),
    ),
    appTimeoutEnabled: appTimeoutEnabled,
    appTimeoutNotificationsEnabled: appTimeoutNotificationsEnabled,
    appTimeoutNotificationSound: true,
    rulesRevision: rulesRevision,
    appTimeoutRules: rules,
    locale: locale,
  );
}

ActivitySnapshot _active(ActivityApplication application) {
  return ActivitySnapshot.active(
    revision: 1,
    observedAt: _observedAt,
    application: application,
  );
}

ActivitySnapshot _idle() =>
    ActivitySnapshot.idle(revision: 2, observedAt: _observedAt);
ActivitySnapshot _excluded() =>
    ActivitySnapshot.excluded(revision: 3, observedAt: _observedAt);
ActivitySnapshot _paused() =>
    ActivitySnapshot.paused(revision: 4, observedAt: _observedAt);
ActivitySnapshot _unavailable() =>
    ActivitySnapshot.unavailable(revision: 5, observedAt: _observedAt);

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeActivitySource implements ActivitySnapshotSource {
  _FakeActivitySource(this.snapshot);

  ActivitySnapshot snapshot;
  int reads = 0;

  @override
  ActivitySnapshot readActivitySnapshot() {
    reads++;
    return snapshot;
  }
}

final class _FakeConfigurationSource implements ReminderConfigurationSource {
  _FakeConfigurationSource(this.snapshot);

  ReminderConfigurationSnapshot snapshot;
  int reads = 0;
  bool throwOnRead = false;

  @override
  ReminderConfigurationSnapshot readReminderConfiguration() {
    reads++;
    if (throwOnRead) {
      throw StateError('configuration unavailable');
    }
    return snapshot;
  }
}

final class _FakeNotificationPort implements NotificationPort {
  final List<NotificationMessage> messages = [];
  final List<Completer<NotificationDeliveryResult>> pendingResults = [];
  bool throwOnShow = false;
  NotificationDeliveryResult result =
      const NotificationDeliveryResult.delivered();
  NotificationHealth currentHealth = const NotificationHealth.uninitialized();

  @override
  NotificationHealth get health => currentHealth;

  @override
  Future<NotificationDeliveryResult> authorize({required bool sound}) async {
    return const NotificationDeliveryResult.ready();
  }

  @override
  Future<NotificationDeliveryResult> show(NotificationMessage message) async {
    messages.add(message);
    if (throwOnShow) {
      throw StateError('delivery failed');
    }
    if (pendingResults.isNotEmpty) {
      return pendingResults.removeAt(0).future;
    }
    return result;
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

final class _FakePeriodicTaskFactory {
  late void Function() callback;
  late _FakePeriodicTask task;
  Duration? interval;
  int created = 0;

  ReminderPeriodicTask create(Duration interval, void Function() callback) {
    created++;
    this.interval = interval;
    this.callback = callback;
    task = _FakePeriodicTask();
    return task;
  }

  void fire() => callback();
}

final class _FakePeriodicTask implements ReminderPeriodicTask {
  bool active = true;
  int cancelCalls = 0;

  @override
  bool get isActive => active;

  @override
  void cancel() {
    if (active) {
      cancelCalls++;
      active = false;
    }
  }
}

final _observedAt = DateTime.utc(2026, 8, 31);
const _pathA = r'c:\apps\alpha.exe';
const _pathB = r'c:\apps\beta.exe';
const _appA = ActivityApplication(executablePath: _pathA, displayName: 'Alpha');
const _ruleA = AppTimeoutRule(
  id: 1,
  executablePath: _pathA,
  displayName: 'Alpha',
  threshold: Duration(seconds: 2),
  cooldown: Duration(seconds: 3),
  enabled: true,
  repeatEnabled: false,
);
const _ruleB = AppTimeoutRule(
  id: 2,
  executablePath: _pathB,
  displayName: 'Beta',
  threshold: Duration(seconds: 2),
  cooldown: Duration(seconds: 3),
  enabled: true,
  repeatEnabled: false,
);
