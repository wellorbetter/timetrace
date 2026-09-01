import 'dart:async';

import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/notifications/desktop_notification_gateway.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';

class DesktopNotificationService implements NotificationPort {
  DesktopNotificationService({
    DesktopNotificationGateway? gateway,
    FutureOr<void> Function(String? payload)? onOpen,
  }) : _gateway = gateway ?? FlutterLocalNotificationsGateway(),
       _onOpen = onOpen;

  final DesktopNotificationGateway _gateway;
  final FutureOr<void> Function(String? payload)? _onOpen;

  bool _initialized = false;
  Future<bool>? _initializing;
  int _nextId = 1000;
  int _operationGeneration = 0;
  NotificationHealth _health = const NotificationHealth.uninitialized();

  @override
  NotificationHealth get health => _health;

  Future<bool> _ensureInitialized() {
    final pending = _initializing;
    if (pending != null) return pending;
    if (_initialized) return Future<bool>.value(true);

    final transaction = _initializeTransaction();
    _initializing = transaction;
    return transaction;
  }

  Future<bool> _initializeTransaction() async {
    try {
      final initialized = await _gateway.initialize(
        onTap: (payload) {
          final callback = _onOpen;
          if (callback != null) {
            unawaited(Future.sync(() => callback(payload)));
          }
        },
      );
      if (!initialized) {
        _health = const NotificationHealth(
          NotificationHealthStatus.failed,
          errorCode: 'initialization_rejected',
        );
        return false;
      } else if (_gateway.requiresAuthorization) {
        final status = await _readAuthorizationStatus();
        _health = _healthForAuthorization(status);
      } else {
        _health = const NotificationHealth(NotificationHealthStatus.ready);
      }
      _initialized = true;
      return true;
    } catch (error) {
      _health = const NotificationHealth(
        NotificationHealthStatus.failed,
        errorCode: 'initialization_failed',
      );
      AppLogger.log(
        'notification initialization failed (${error.runtimeType})',
      );
      return false;
    } finally {
      _initializing = null;
    }
  }

  @override
  Future<NotificationDeliveryResult> authorize({required bool sound}) async {
    final generation = ++_operationGeneration;
    if (!await _ensureInitialized()) {
      return const NotificationDeliveryResult(
        NotificationDeliveryStatus.failed,
        errorCode: 'initialization_failed',
      );
    }
    if (!_gateway.requiresAuthorization) {
      return const NotificationDeliveryResult.ready();
    }
    try {
      final granted = await _gateway.requestAuthorization(sound: sound);
      if (!granted) {
        _updateHealth(
          generation,
          const NotificationHealth(
            NotificationHealthStatus.denied,
            errorCode: 'permission_denied',
          ),
        );
        return const NotificationDeliveryResult(
          NotificationDeliveryStatus.denied,
          errorCode: 'permission_denied',
        );
      }
      _updateHealth(
        generation,
        const NotificationHealth(NotificationHealthStatus.ready),
      );
      return const NotificationDeliveryResult.ready();
    } catch (error) {
      _updateHealth(
        generation,
        const NotificationHealth(
          NotificationHealthStatus.failed,
          errorCode: 'authorization_failed',
        ),
      );
      AppLogger.log('notification authorization failed (${error.runtimeType})');
      return const NotificationDeliveryResult(
        NotificationDeliveryStatus.failed,
        errorCode: 'authorization_failed',
      );
    }
  }

  @override
  Future<NotificationDeliveryResult> show(NotificationMessage message) async {
    final generation = ++_operationGeneration;
    if (!await _ensureInitialized()) {
      return const NotificationDeliveryResult(
        NotificationDeliveryStatus.failed,
        errorCode: 'initialization_failed',
      );
    }
    if (_gateway.requiresAuthorization) {
      final previousHealth = _health;
      final status = await _readAuthorizationStatus();
      switch (status) {
        case NotificationAuthorizationStatus.notGranted:
          final errorCode =
              previousHealth.status == NotificationHealthStatus.denied
              ? previousHealth.errorCode ?? 'permission_not_granted'
              : 'permission_not_granted';
          _updateHealth(
            generation,
            NotificationHealth(
              NotificationHealthStatus.denied,
              errorCode: errorCode,
            ),
          );
          return NotificationDeliveryResult(
            NotificationDeliveryStatus.denied,
            errorCode: errorCode,
          );
        case NotificationAuthorizationStatus.unavailable:
          if (previousHealth.status == NotificationHealthStatus.denied) {
            _updateHealth(generation, previousHealth);
            return NotificationDeliveryResult(
              NotificationDeliveryStatus.denied,
              errorCode: previousHealth.errorCode ?? 'permission_not_granted',
            );
          }
          _updateHealth(
            generation,
            const NotificationHealth(
              NotificationHealthStatus.failed,
              errorCode: 'authorization_status_unavailable',
            ),
          );
          return const NotificationDeliveryResult(
            NotificationDeliveryStatus.failed,
            errorCode: 'authorization_status_unavailable',
          );
        case NotificationAuthorizationStatus.authorized:
        case NotificationAuthorizationStatus.notRequired:
          break;
      }
    }
    try {
      await _gateway.show(
        id: _nextId++,
        title: message.title,
        body: message.body,
        sound: message.sound,
        payload: message.payload,
      );
      _updateHealth(
        generation,
        const NotificationHealth(NotificationHealthStatus.ready),
      );
      return const NotificationDeliveryResult.delivered();
    } catch (error) {
      _updateHealth(
        generation,
        const NotificationHealth(
          NotificationHealthStatus.failed,
          errorCode: 'delivery_failed',
        ),
      );
      AppLogger.log('notification delivery failed (${error.runtimeType})');
      return const NotificationDeliveryResult(
        NotificationDeliveryStatus.failed,
        errorCode: 'delivery_failed',
      );
    }
  }

  @override
  Future<NotificationDeliveryResult> test({
    required bool sound,
    required NotificationMessage message,
  }) async {
    final authorization = await authorize(sound: sound);
    if (!authorization.isSuccess) return authorization;
    return show(message);
  }

  Future<NotificationAuthorizationStatus> _readAuthorizationStatus() async {
    try {
      return await _gateway.checkAuthorizationStatus();
    } catch (error) {
      AppLogger.log(
        'notification authorization status check failed '
        '(${error.runtimeType})',
      );
      return NotificationAuthorizationStatus.unavailable;
    }
  }

  NotificationHealth _healthForAuthorization(
    NotificationAuthorizationStatus status,
  ) {
    return switch (status) {
      NotificationAuthorizationStatus.notRequired ||
      NotificationAuthorizationStatus.authorized => const NotificationHealth(
        NotificationHealthStatus.ready,
      ),
      NotificationAuthorizationStatus.notGranted => const NotificationHealth(
        NotificationHealthStatus.denied,
        errorCode: 'permission_not_granted',
      ),
      NotificationAuthorizationStatus.unavailable => const NotificationHealth(
        NotificationHealthStatus.failed,
        errorCode: 'authorization_status_unavailable',
      ),
    };
  }

  void _updateHealth(int generation, NotificationHealth health) {
    if (generation == _operationGeneration) {
      _health = health;
    }
  }
}
