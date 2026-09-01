import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Current non-prompting authorization state reported by the platform.
///
/// The Darwin plugin exposes whether notifications are enabled, but does not
/// distinguish an explicit denial from a permission that has never been
/// requested. Both cases are therefore represented by [notGranted].
enum NotificationAuthorizationStatus {
  notRequired,
  authorized,
  notGranted,
  unavailable,
}

abstract interface class DesktopNotificationGateway {
  bool get requiresAuthorization;

  Future<bool> initialize({required void Function(String? payload) onTap});

  /// Reads the current permission state without displaying a system prompt.
  Future<NotificationAuthorizationStatus> checkAuthorizationStatus();

  Future<bool> requestAuthorization({required bool sound});

  Future<void> show({
    required int id,
    required String title,
    required String body,
    required bool sound,
    String? payload,
  });
}

class FlutterLocalNotificationsGateway implements DesktopNotificationGateway {
  FlutterLocalNotificationsGateway({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const windowsAppName = 'TimeTrace';
  static const windowsAppUserModelId = 'com.wellorbetter.timetrace';
  static const windowsActivatorGuid = 'b8ca2dd0-8f0f-4d98-a54e-0f57e5944c8e';

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  bool get requiresAuthorization => Platform.isMacOS;

  @override
  Future<NotificationAuthorizationStatus> checkAuthorizationStatus() async {
    if (!Platform.isMacOS) {
      return NotificationAuthorizationStatus.notRequired;
    }
    final implementation = _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >();
    if (implementation == null) {
      return NotificationAuthorizationStatus.unavailable;
    }
    final permissions = await implementation.checkPermissions();
    if (permissions == null) {
      return NotificationAuthorizationStatus.unavailable;
    }
    if (permissions.isEnabled || permissions.isProvisionalEnabled) {
      return NotificationAuthorizationStatus.authorized;
    }
    return NotificationAuthorizationStatus.notGranted;
  }

  @override
  Future<bool> initialize({
    required void Function(String? payload) onTap,
  }) async {
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentAlert: true,
      defaultPresentBadge: false,
      defaultPresentSound: true,
      defaultPresentBanner: true,
      defaultPresentList: true,
    );
    final result = await _plugin.initialize(
      settings: const InitializationSettings(
        macOS: darwin,
        windows: WindowsInitializationSettings(
          appName: windowsAppName,
          appUserModelId: windowsAppUserModelId,
          guid: windowsActivatorGuid,
        ),
      ),
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
    return result ?? false;
  }

  @override
  Future<bool> requestAuthorization({required bool sound}) async {
    if (!Platform.isMacOS) return true;
    final result = await _plugin
        .resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: sound);
    return result ?? false;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required bool sound,
    String? payload,
  }) => _plugin.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentBadge: false,
        presentSound: sound,
      ),
      windows: WindowsNotificationDetails(
        audio: sound ? null : WindowsNotificationAudio.silent(),
      ),
    ),
    payload: payload,
  );
}
