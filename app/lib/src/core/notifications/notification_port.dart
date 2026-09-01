import 'package:timetrace_app/src/core/notifications/notification_message.dart';

enum NotificationDeliveryStatus {
  delivered,
  ready,
  denied,
  unavailable,
  failed,
}

class NotificationDeliveryResult {
  const NotificationDeliveryResult(this.status, {this.errorCode});

  const NotificationDeliveryResult.delivered()
    : status = NotificationDeliveryStatus.delivered,
      errorCode = null;

  const NotificationDeliveryResult.ready()
    : status = NotificationDeliveryStatus.ready,
      errorCode = null;

  final NotificationDeliveryStatus status;
  final String? errorCode;

  bool get isSuccess =>
      status == NotificationDeliveryStatus.delivered ||
      status == NotificationDeliveryStatus.ready;
}

enum NotificationHealthStatus { uninitialized, ready, denied, failed }

class NotificationHealth {
  const NotificationHealth(this.status, {this.errorCode});

  const NotificationHealth.uninitialized()
    : status = NotificationHealthStatus.uninitialized,
      errorCode = null;

  final NotificationHealthStatus status;
  final String? errorCode;
}

abstract interface class NotificationPort {
  NotificationHealth get health;

  /// Initializes the adapter and requests permission only on platforms that
  /// require it. This must be called from an explicit user action.
  Future<NotificationDeliveryResult> authorize({required bool sound});

  /// Delivers without implicitly requesting permission.
  Future<NotificationDeliveryResult> show(NotificationMessage message);

  /// Explicit user-triggered authorization plus one test notification.
  Future<NotificationDeliveryResult> test({
    required bool sound,
    required NotificationMessage message,
  });
}
