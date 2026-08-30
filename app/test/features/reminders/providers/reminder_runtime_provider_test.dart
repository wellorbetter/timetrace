import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/core/notifications/notification_provider.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';

void main() {
  test('root watches share one controller and start exactly one timer', () {
    final clock = _FakeClock();
    final tasks = _FakeTaskFactory();
    final notifications = _FakeNotificationPort();
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(_FakeApi()),
        activitySnapshotSourceProvider.overrideWithValue(_FakeActivitySource()),
        reminderConfigurationSourceProvider.overrideWithValue(
          _DisabledConfigurationSource(),
        ),
        notificationPortProvider.overrideWithValue(notifications),
        reminderMonotonicClockProvider.overrideWithValue(clock),
        reminderPeriodicTaskFactoryProvider.overrideWithValue(tasks.create),
      ],
    );
    addTearDown(container.dispose);

    expect(tasks.created, 0);
    final first = container.listen(reminderRuntimeProvider, (_, _) {});
    final second = container.listen(reminderRuntimeProvider, (_, _) {});
    addTearDown(first.close);
    addTearDown(second.close);

    expect(tasks.created, 1);
    expect(container.read(reminderRuntimeControllerProvider).isStarted, isTrue);
    expect(notifications.authorizeCalls, 0);
    expect(notifications.showCalls, 0);

    clock.value = const Duration(seconds: 1);
    tasks.fire();
    expect(container.read(reminderRuntimeProvider).tickCount, 1);

    container.dispose();
    expect(tasks.task.cancelCalls, 1);
  });
}

final class _FakeActivitySource implements ActivitySnapshotSource {
  @override
  ActivitySnapshot readActivitySnapshot() {
    return ActivitySnapshot.unavailable(
      revision: 1,
      observedAt: DateTime.utc(2026, 8, 31),
    );
  }
}

final class _DisabledConfigurationSource
    implements ReminderConfigurationSource {
  @override
  ReminderConfigurationSnapshot readReminderConfiguration() {
    return ReminderConfigurationSnapshot.disabled();
  }
}

final class _FakeNotificationPort implements NotificationPort {
  int authorizeCalls = 0;
  int showCalls = 0;

  @override
  NotificationHealth get health => const NotificationHealth.uninitialized();

  @override
  Future<NotificationDeliveryResult> authorize({required bool sound}) async {
    authorizeCalls++;
    return const NotificationDeliveryResult.ready();
  }

  @override
  Future<NotificationDeliveryResult> show(NotificationMessage message) async {
    showCalls++;
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
  int created = 0;
  late void Function() callback;
  late _FakeTask task;

  ReminderPeriodicTask create(Duration interval, void Function() callback) {
    expect(interval, ReminderRuntimeController.tickInterval);
    created++;
    this.callback = callback;
    task = _FakeTask();
    return task;
  }

  void fire() => callback();
}

final class _FakeTask implements ReminderPeriodicTask {
  bool active = true;
  int cancelCalls = 0;

  @override
  bool get isActive => active;

  @override
  void cancel() {
    if (!active) return;
    active = false;
    cancelCalls++;
  }
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
      enabled: false,
      focusMinutes: BigInt.from(25),
      shortBreakMinutes: BigInt.from(5),
      longBreakMinutes: BigInt.from(15),
      longBreakInterval: BigInt.from(4),
      autoStartNext: false,
      notificationsEnabled: true,
      notificationSound: true,
    ),
    appTimeout: AppTimeoutConfigDto(
      enabled: false,
      defaultThresholdMinutes: BigInt.from(60),
      defaultCooldownMinutes: BigInt.from(30),
      notificationsEnabled: true,
      notificationSound: true,
    ),
  );

  @override
  List<AppTimeoutRuleDto> listAppTimeoutRules() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
