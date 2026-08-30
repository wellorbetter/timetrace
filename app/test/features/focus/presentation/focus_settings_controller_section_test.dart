import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/core/notifications/notification_provider.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_settings_controller_section.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

void main() {
  testWidgets(
    'notification enable persists and authorizes without sending a toast',
    (tester) async {
      final initial = AppSettings.defaults().copyWith(
        pomodoro: PomodoroSettings.defaults().copyWith(
          enabled: true,
          notificationsEnabled: false,
        ),
      );
      final api = _FakeApi(appSettingsToDto(initial));
      final notifications = _FakeNotificationPort();
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          notificationPortProvider.overrideWithValue(notifications),
          reminderPeriodicTaskFactoryProvider.overrideWithValue(
            _noopPeriodicTaskFactory,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await _pump(tester, container, initial);

      final notificationToggle = find.byKey(
        const ValueKey('focus-notifications-setting'),
      );
      await tester.ensureVisible(notificationToggle);
      await tester.tap(notificationToggle);
      await tester.pumpAndSettle();

      expect(api.setCalls, 1);
      expect(api.savedConfig!.pomodoro.notificationsEnabled, isTrue);
      expect(notifications.authorizeCalls, 1);
      expect(notifications.testCalls, 0);
      expect(notifications.showCalls, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('通知服务已准备就绪。'), findsOneWidget);

      final testButton = find.byKey(const ValueKey('test-notification-button'));
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pumpAndSettle();

      expect(notifications.authorizeCalls, 1);
      expect(notifications.testCalls, 1);
      expect(notifications.showCalls, 0);
      expect(find.text('测试通知已发送。'), findsOneWidget);
    },
  );

  testWidgets(
    'slider previews while dragging and persists once on change end',
    (tester) async {
      final initial = AppSettings.defaults().copyWith(
        appTimeout: AppTimeoutSettings.defaults().copyWith(enabled: true),
      );
      final api = _FakeApi(appSettingsToDto(initial));
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          reminderPeriodicTaskFactoryProvider.overrideWithValue(
            _noopPeriodicTaskFactory,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await _pump(tester, container, initial);

      final cooldownSlider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(const ValueKey('app-cooldown-setting')),
          matching: find.byType(Slider),
        ),
      );
      cooldownSlider.onChanged!(90);
      await tester.pump();

      expect(api.setCalls, 0);
      expect(
        container
            .read(settingsProvider)
            .requireValue
            .appTimeout
            .defaultCooldownMinutes,
        90,
      );

      cooldownSlider.onChangeEnd!(90);
      await tester.pumpAndSettle();

      expect(api.setCalls, 1);
      expect(
        api.savedConfig!.appTimeout.defaultCooldownMinutes,
        BigInt.from(90),
      );
      expect(
        container
            .read(settingsProvider)
            .requireValue
            .appTimeout
            .defaultCooldownMinutes,
        90,
      );
    },
  );

  testWidgets(
    'enabling Pomodoro with default notifications authorizes without toast',
    (tester) async {
      final initial = AppSettings.defaults();
      final api = _FakeApi(appSettingsToDto(initial));
      final notifications = _FakeNotificationPort();
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          notificationPortProvider.overrideWithValue(notifications),
          reminderPeriodicTaskFactoryProvider.overrideWithValue(
            _noopPeriodicTaskFactory,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await _pump(tester, container, initial);

      await tester.tap(find.byKey(const ValueKey('pomodoro-enabled-row')));
      await tester.pumpAndSettle();

      expect(api.setCalls, 1);
      expect(api.savedConfig!.pomodoro.enabled, isTrue);
      expect(notifications.authorizeCalls, 1);
      expect(notifications.testCalls, 0);
      expect(notifications.showCalls, 0);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'enabling app timeout with default notifications authorizes without toast',
    (tester) async {
      final initial = AppSettings.defaults();
      final api = _FakeApi(appSettingsToDto(initial));
      final notifications = _FakeNotificationPort();
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          notificationPortProvider.overrideWithValue(notifications),
          reminderPeriodicTaskFactoryProvider.overrideWithValue(
            _noopPeriodicTaskFactory,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await _pump(tester, container, initial);

      await tester.tap(find.byKey(const ValueKey('app-timeout-enabled-row')));
      await tester.pumpAndSettle();

      expect(api.setCalls, 1);
      expect(api.savedConfig!.appTimeout.enabled, isTrue);
      expect(notifications.authorizeCalls, 1);
      expect(notifications.testCalls, 0);
      expect(notifications.showCalls, 0);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'runtime notification health is visible when no action overrides',
    (tester) async {
      final initial = AppSettings.defaults();
      final api = _FakeApi(appSettingsToDto(initial));
      final notifications = _FakeNotificationPort(
        health: const NotificationHealth(
          NotificationHealthStatus.failed,
          errorCode: 'delivery_failed',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          notificationPortProvider.overrideWithValue(notifications),
          reminderPeriodicTaskFactoryProvider.overrideWithValue(
            _noopPeriodicTaskFactory,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsProvider.future);
      await _pump(tester, container, initial);

      expect(find.text('通知服务暂不可用，请检查系统设置或重试。'), findsOneWidget);
    },
  );

  testWidgets('real host follows English locale for UI and test message', (
    tester,
  ) async {
    final initial = AppSettings.defaults();
    final notifications = _FakeNotificationPort();
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(_FakeApi(appSettingsToDto(initial))),
        localeProvider.overrideWith(_EnglishLocaleNotifier.new),
        notificationPortProvider.overrideWithValue(notifications),
        reminderPeriodicTaskFactoryProvider.overrideWithValue(
          _noopPeriodicTaskFactory,
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsProvider.future);
    await _pump(tester, container, initial);

    expect(find.text('Focus & usage reminders'), findsOneWidget);
    final testButton = find.byKey(const ValueKey('test-notification-button'));
    await tester.ensureVisible(testButton);
    await tester.tap(testButton);
    await tester.pumpAndSettle();

    expect(find.text('Test notification sent.'), findsOneWidget);
    expect(notifications.lastTestMessage?.title, 'TimeTrace test notification');
    expect(notifications.lastTestMessage?.body, isNot(contains('通知')));
  });
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  AppSettings settings,
) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FocusSettingsControllerSection(settings: settings),
          ),
        ),
      ),
    ),
  );
}

final class _FakeApi implements TimeTraceApi {
  _FakeApi(this.config);

  final ConfigDto config;
  ConfigDto? savedConfig;
  int setCalls = 0;

  @override
  ConfigDto getConfig() => config;

  @override
  void setConfig({required ConfigDto config}) {
    setCalls++;
    savedConfig = config;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeNotificationPort implements NotificationPort {
  _FakeNotificationPort({
    this.health = const NotificationHealth.uninitialized(),
  });

  int authorizeCalls = 0;
  int showCalls = 0;
  int testCalls = 0;
  NotificationMessage? lastTestMessage;

  @override
  final NotificationHealth health;

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
    testCalls++;
    lastTestMessage = message;
    return const NotificationDeliveryResult.delivered();
  }
}

final class _EnglishLocaleNotifier extends LocaleNotifier {
  @override
  AppLocale build() => AppLocale.en;
}

ReminderPeriodicTask _noopPeriodicTaskFactory(
  Duration interval,
  void Function() callback,
) => _NoopPeriodicTask();

final class _NoopPeriodicTask implements ReminderPeriodicTask {
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;
}
