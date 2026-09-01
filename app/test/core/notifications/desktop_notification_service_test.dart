import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/notifications/desktop_notification_gateway.dart';
import 'package:timetrace_app/src/core/notifications/desktop_notification_service.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';

void main() {
  test(
    'construction is quiet and first show initializes lazily once',
    () async {
      final gateway = _FakeGateway();
      final service = DesktopNotificationService(gateway: gateway);

      expect(gateway.initializeCalls, 0);
      expect(gateway.showCalls, 0);

      final first = await service.show(NotificationMessage.test());
      final second = await service.show(NotificationMessage.test(sound: false));

      expect(first.status, NotificationDeliveryStatus.delivered);
      expect(second.status, NotificationDeliveryStatus.delivered);
      expect(gateway.initializeCalls, 1);
      expect(gateway.authorizationCheckCalls, 0);
      expect(gateway.showCalls, 2);
      expect(gateway.lastSound, isFalse);
    },
  );

  test('explicit test requests authorization once then shows once', () async {
    final gateway = _FakeGateway(
      requiresAuthorization: true,
      authorizationStatus: NotificationAuthorizationStatus.notGranted,
    );
    final service = DesktopNotificationService(gateway: gateway);

    final result = await service.test(
      sound: true,
      message: NotificationMessage.test(sound: true),
    );

    expect(result.isSuccess, isTrue);
    expect(gateway.initializeCalls, 1);
    expect(gateway.authorizationCalls, 1);
    expect(gateway.authorizationCheckCalls, 2);
    expect(gateway.showCalls, 1);
    expect(gateway.lastTitle, 'TimeTrace 测试通知');
  });

  test('known authorization denial prevents show and remains denied', () async {
    final gateway = _FakeGateway(
      requiresAuthorization: true,
      authorizationStatus: NotificationAuthorizationStatus.notGranted,
      authorizationGranted: false,
    );
    final service = DesktopNotificationService(gateway: gateway);

    final authorization = await service.authorize(sound: true);
    final delivery = await service.show(NotificationMessage.test());

    expect(authorization.status, NotificationDeliveryStatus.denied);
    expect(delivery.status, NotificationDeliveryStatus.denied);
    expect(service.health.status, NotificationHealthStatus.denied);
    expect(service.health.errorCode, 'permission_denied');
    expect(gateway.showCalls, 0);
    expect(gateway.authorizationCheckCalls, 2);
  });

  test(
    'existing denial after restart is discovered before first show',
    () async {
      final gateway = _FakeGateway(
        requiresAuthorization: true,
        authorizationStatus: NotificationAuthorizationStatus.notGranted,
      );
      final service = DesktopNotificationService(gateway: gateway);

      final delivery = await service.show(NotificationMessage.test());

      expect(delivery.status, NotificationDeliveryStatus.denied);
      expect(delivery.errorCode, 'permission_not_granted');
      expect(service.health.status, NotificationHealthStatus.denied);
      expect(service.health.errorCode, 'permission_not_granted');
      expect(gateway.authorizationCalls, 0);
      expect(gateway.showCalls, 0);
      expect(gateway.authorizationCheckCalls, 2);
    },
  );

  test('unavailable authorization status never claims delivery', () async {
    final gateway = _FakeGateway(
      requiresAuthorization: true,
      authorizationStatus: NotificationAuthorizationStatus.unavailable,
    );
    final service = DesktopNotificationService(gateway: gateway);

    final delivery = await service.show(NotificationMessage.test());

    expect(delivery.status, NotificationDeliveryStatus.failed);
    expect(delivery.errorCode, 'authorization_status_unavailable');
    expect(service.health.status, NotificationHealthStatus.failed);
    expect(service.health.errorCode, 'authorization_status_unavailable');
    expect(gateway.showCalls, 0);
  });

  test('delivery failure is non-fatal and returns stable error', () async {
    final gateway = _FakeGateway(throwOnShow: true);
    final service = DesktopNotificationService(gateway: gateway);

    final result = await service.show(NotificationMessage.test());

    expect(result.status, NotificationDeliveryStatus.failed);
    expect(result.errorCode, 'delivery_failed');
    expect(service.health.errorCode, 'delivery_failed');
  });

  test(
    'concurrent callers share initialization and its initial status query',
    () async {
      final initialStatus = Completer<NotificationAuthorizationStatus>();
      final gateway = _FakeGateway(
        requiresAuthorization: true,
        authorizationStatus: NotificationAuthorizationStatus.authorized,
      )..authorizationStatusFutures.add(initialStatus.future);
      final service = DesktopNotificationService(gateway: gateway);

      final first = service.show(NotificationMessage.test());
      await _flushAsync();
      expect(gateway.initializeCalls, 1);
      expect(gateway.authorizationCheckCalls, 1);

      final second = service.show(NotificationMessage.test(sound: false));
      await _flushAsync();

      expect(gateway.initializeCalls, 1);
      expect(
        gateway.authorizationCheckCalls,
        1,
        reason: 'the initial status query is part of initialization',
      );

      initialStatus.complete(NotificationAuthorizationStatus.authorized);
      expect((await first).status, NotificationDeliveryStatus.delivered);
      expect((await second).status, NotificationDeliveryStatus.delivered);
      expect(gateway.authorizationCheckCalls, 3);
      expect(gateway.showCalls, 2);
    },
  );

  test('late show success cannot overwrite a newer denial', () async {
    final lateShow = Completer<void>();
    final gateway = _FakeGateway(
      requiresAuthorization: true,
      authorizationStatus: NotificationAuthorizationStatus.authorized,
      authorizationGranted: false,
    );
    final service = DesktopNotificationService(gateway: gateway);
    await service.show(NotificationMessage.test());

    gateway.showFutures.add(lateShow.future);
    final staleDelivery = service.show(NotificationMessage.test());
    await _flushAsync();
    expect(gateway.showCalls, 2);

    final denial = await service.authorize(sound: true);
    expect(denial.status, NotificationDeliveryStatus.denied);
    expect(service.health.status, NotificationHealthStatus.denied);

    lateShow.complete();
    expect((await staleDelivery).status, NotificationDeliveryStatus.delivered);
    expect(service.health.status, NotificationHealthStatus.denied);
    expect(service.health.errorCode, 'permission_denied');
  });

  test(
    'late authorization denial cannot overwrite newer unavailable health',
    () async {
      final lateAuthorization = Completer<bool>();
      final gateway = _FakeGateway(
        requiresAuthorization: true,
        authorizationStatus: NotificationAuthorizationStatus.authorized,
      );
      final service = DesktopNotificationService(gateway: gateway);
      await service.show(NotificationMessage.test());

      gateway.authorizationFutures.add(lateAuthorization.future);
      final staleAuthorization = service.authorize(sound: true);
      await _flushAsync();
      expect(gateway.authorizationCalls, 1);

      gateway.authorizationStatus = NotificationAuthorizationStatus.unavailable;
      final unavailable = await service.show(NotificationMessage.test());
      expect(unavailable.status, NotificationDeliveryStatus.failed);
      expect(unavailable.errorCode, 'authorization_status_unavailable');

      lateAuthorization.complete(false);
      expect(
        (await staleAuthorization).status,
        NotificationDeliveryStatus.denied,
      );
      expect(service.health.status, NotificationHealthStatus.failed);
      expect(service.health.errorCode, 'authorization_status_unavailable');
    },
  );

  test('application timeout factory omits executable and window content', () {
    final message = NotificationMessage.appTimeout(
      appName: 'Microsoft Edge',
      activeMinutes: 60,
      sound: false,
    );

    expect(message.title, '连续使用提醒');
    expect(message.body, contains('Microsoft Edge'));
    expect(message.body, contains('60 分钟'));
    expect(message.body, isNot(contains(r'C:\')));
    expect(message.payload, 'app-timeout');
    expect(message.sound, isFalse);
  });

  test('application timeout factory redacts a path-shaped app name', () {
    final message = NotificationMessage.appTimeout(
      appName: r'C:\Users\private\Secret\secret.exe',
      activeMinutes: 60,
      sound: false,
    );

    expect(message.body, contains('未命名应用'));
    expect(message.body, isNot(contains(r'C:\Users')));
    expect(message.body, isNot(contains('secret.exe')));
  });

  test('English factories localize copy and preserve path redaction', () {
    final timeout = NotificationMessage.appTimeout(
      appName: r'C:\Users\private\Secret\secret.exe',
      activeMinutes: 1,
      sound: false,
      strings: ReminderL10n.en,
    );
    final testMessage = NotificationMessage.test(
      sound: false,
      strings: ReminderL10n.en,
    );

    expect(timeout.title, 'Continuous-use reminder');
    expect(timeout.body, contains('Unnamed application'));
    expect(timeout.body, contains('1 minute'));
    expect(timeout.body, isNot(contains(r'C:\Users')));
    expect(testMessage.title, 'TimeTrace test notification');
    expect(testMessage.body, isNot(contains('通知已连接')));
  });
}

class _FakeGateway implements DesktopNotificationGateway {
  _FakeGateway({
    this.requiresAuthorization = false,
    this.throwOnShow = false,
    this.authorizationStatus = NotificationAuthorizationStatus.notRequired,
    this.authorizationGranted = true,
  });

  @override
  final bool requiresAuthorization;
  final bool throwOnShow;
  NotificationAuthorizationStatus authorizationStatus;
  final bool authorizationGranted;
  final List<Future<NotificationAuthorizationStatus>>
  authorizationStatusFutures = [];
  final List<Future<bool>> authorizationFutures = [];
  final List<Future<void>> showFutures = [];

  int initializeCalls = 0;
  int authorizationCheckCalls = 0;
  int authorizationCalls = 0;
  int showCalls = 0;
  bool? lastSound;
  String? lastTitle;

  @override
  Future<NotificationAuthorizationStatus> checkAuthorizationStatus() {
    authorizationCheckCalls++;
    if (authorizationStatusFutures.isNotEmpty) {
      return authorizationStatusFutures.removeAt(0);
    }
    return Future<NotificationAuthorizationStatus>.value(authorizationStatus);
  }

  @override
  Future<bool> initialize({
    required void Function(String? payload) onTap,
  }) async {
    initializeCalls++;
    return true;
  }

  @override
  Future<bool> requestAuthorization({required bool sound}) async {
    authorizationCalls++;
    final granted = authorizationFutures.isNotEmpty
        ? await authorizationFutures.removeAt(0)
        : authorizationGranted;
    if (granted) {
      authorizationStatus = NotificationAuthorizationStatus.authorized;
    }
    return granted;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required bool sound,
    String? payload,
  }) async {
    showCalls++;
    lastSound = sound;
    lastTitle = title;
    if (throwOnShow) throw StateError('synthetic failure');
    if (showFutures.isNotEmpty) {
      await showFutures.removeAt(0);
    }
  }
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
