import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/notifications/desktop_notification_service.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';

/// Lazily constructs the adapter. The platform plugin remains uninitialized
/// until an explicit test/authorization action or a real reminder delivery.
final notificationPortProvider = Provider<NotificationPort>((ref) {
  return DesktopNotificationService();
});
