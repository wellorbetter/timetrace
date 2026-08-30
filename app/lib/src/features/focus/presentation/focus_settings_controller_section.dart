import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/notifications/notification_message.dart';
import 'package:timetrace_app/src/core/notifications/notification_port.dart';
import 'package:timetrace_app/src/core/notifications/notification_provider.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_settings_section.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

/// Connects persisted reminder settings and explicit notification actions to
/// the provider-free [FocusSettingsSection].
class FocusSettingsControllerSection extends ConsumerStatefulWidget {
  const FocusSettingsControllerSection({required this.settings, super.key});

  final AppSettings settings;

  @override
  ConsumerState<FocusSettingsControllerSection> createState() =>
      _FocusSettingsControllerSectionState();
}

class _FocusSettingsControllerSectionState
    extends ConsumerState<FocusSettingsControllerSection> {
  _NotificationStatus? _notificationStatus;
  Timer? _notificationStatusTimer;

  AppSettings get _settings => widget.settings;

  @override
  Widget build(BuildContext context) {
    final runtimeNotificationHealth = ref.watch(
      reminderRuntimeProvider.select((state) => state.notificationHealth),
    );
    final pomodoro = _settings.pomodoro;
    final appTimeout = _settings.appTimeout;
    final strings = ReminderL10n(ref.watch(localeProvider));

    return FocusSettingsSection(
      strings: strings,
      pomodoroEnabled: pomodoro.enabled,
      focusMinutes: pomodoro.focusMinutes,
      shortBreakMinutes: pomodoro.shortBreakMinutes,
      longBreakMinutes: pomodoro.longBreakMinutes,
      longBreakInterval: pomodoro.longBreakInterval,
      autoStartNext: pomodoro.autoStartNext,
      pomodoroNotificationsEnabled: pomodoro.notificationsEnabled,
      pomodoroSoundEnabled: pomodoro.notificationSound,
      appTimeoutEnabled: appTimeout.enabled,
      defaultAppThresholdMinutes: appTimeout.defaultThresholdMinutes,
      defaultAppCooldownMinutes: appTimeout.defaultCooldownMinutes,
      appTimeoutNotificationsEnabled: appTimeout.notificationsEnabled,
      appTimeoutSoundEnabled: appTimeout.notificationSound,
      onPomodoroEnabledChanged: (value) {
        _persist(
          _settings.copyWith(pomodoro: pomodoro.copyWith(enabled: value)),
        );
        if (value && !pomodoro.enabled && pomodoro.notificationsEnabled) {
          unawaited(_authorizeNotifications(sound: pomodoro.notificationSound));
        }
      },
      onFocusMinutesChanged: (value) => _preview(
        _settings.copyWith(pomodoro: pomodoro.copyWith(focusMinutes: value)),
      ),
      onFocusMinutesChangeEnd: (value) => _persist(
        _settings.copyWith(pomodoro: pomodoro.copyWith(focusMinutes: value)),
      ),
      onShortBreakMinutesChanged: (value) => _preview(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(shortBreakMinutes: value),
        ),
      ),
      onShortBreakMinutesChangeEnd: (value) => _persist(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(shortBreakMinutes: value),
        ),
      ),
      onLongBreakMinutesChanged: (value) => _preview(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(longBreakMinutes: value),
        ),
      ),
      onLongBreakMinutesChangeEnd: (value) => _persist(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(longBreakMinutes: value),
        ),
      ),
      onLongBreakIntervalChanged: (value) => _preview(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(longBreakInterval: value),
        ),
      ),
      onLongBreakIntervalChangeEnd: (value) => _persist(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(longBreakInterval: value),
        ),
      ),
      onAutoStartNextChanged: (value) => _persist(
        _settings.copyWith(pomodoro: pomodoro.copyWith(autoStartNext: value)),
      ),
      onPomodoroNotificationsChanged: (value) {
        _persist(
          _settings.copyWith(
            pomodoro: pomodoro.copyWith(notificationsEnabled: value),
          ),
        );
        if (value) {
          unawaited(_authorizeNotifications(sound: pomodoro.notificationSound));
        }
      },
      onPomodoroSoundChanged: (value) => _persist(
        _settings.copyWith(
          pomodoro: pomodoro.copyWith(notificationSound: value),
        ),
      ),
      onAppTimeoutEnabledChanged: (value) {
        _persist(
          _settings.copyWith(appTimeout: appTimeout.copyWith(enabled: value)),
        );
        if (value && !appTimeout.enabled && appTimeout.notificationsEnabled) {
          unawaited(
            _authorizeNotifications(sound: appTimeout.notificationSound),
          );
        }
      },
      onDefaultAppThresholdMinutesChanged: (value) => _preview(
        _settings.copyWith(
          appTimeout: appTimeout.copyWith(defaultThresholdMinutes: value),
        ),
      ),
      onDefaultAppThresholdMinutesChangeEnd: (value) => _persist(
        _settings.copyWith(
          appTimeout: appTimeout.copyWith(defaultThresholdMinutes: value),
        ),
      ),
      onDefaultAppCooldownMinutesChanged: (value) => _preview(
        _settings.copyWith(
          appTimeout: appTimeout.copyWith(defaultCooldownMinutes: value),
        ),
      ),
      onDefaultAppCooldownMinutesChangeEnd: (value) => _persist(
        _settings.copyWith(
          appTimeout: appTimeout.copyWith(defaultCooldownMinutes: value),
        ),
      ),
      onAppTimeoutNotificationsChanged: (value) {
        _persist(
          _settings.copyWith(
            appTimeout: appTimeout.copyWith(notificationsEnabled: value),
          ),
        );
        if (value) {
          unawaited(
            _authorizeNotifications(sound: appTimeout.notificationSound),
          );
        }
      },
      onAppTimeoutSoundChanged: (value) => _persist(
        _settings.copyWith(
          appTimeout: appTimeout.copyWith(notificationSound: value),
        ),
      ),
      onTestNotification: () => unawaited(_testNotification()),
      notificationStatus:
          _notificationStatus?.text(strings) ??
          _notificationHealthText(runtimeNotificationHealth, strings),
    );
  }

  @override
  void dispose() {
    _notificationStatusTimer?.cancel();
    super.dispose();
  }

  void _preview(AppSettings next) {
    ref.read(settingsProvider.notifier).preview(next);
  }

  void _persist(AppSettings next) {
    unawaited(_persistAsync(next));
  }

  Future<void> _persistAsync(AppSettings next) async {
    try {
      await ref.read(settingsProvider.notifier).previewAndSave(next);
    } catch (error, stackTrace) {
      AppLogger.log('Saving reminder settings failed: $error\n$stackTrace');
      _setNotificationStatus(_NotificationStatus.settingsSaveFailed);
    }
  }

  Future<void> _authorizeNotifications({required bool sound}) async {
    _setNotificationStatus(
      _NotificationStatus.requestingPermission,
      transient: false,
    );
    try {
      final result = await ref
          .read(notificationPortProvider)
          .authorize(sound: sound);
      _setNotificationStatus(_resultStatus(result, testing: false));
    } catch (error, stackTrace) {
      AppLogger.log('Notification authorization failed: $error\n$stackTrace');
      _setNotificationStatus(_NotificationStatus.permissionRequestFailed);
    }
  }

  Future<void> _testNotification() async {
    _setNotificationStatus(_NotificationStatus.sendingTest, transient: false);
    final pomodoro = _settings.pomodoro;
    final appTimeout = _settings.appTimeout;
    final sound = pomodoro.notificationSound || appTimeout.notificationSound;
    final strings = ReminderL10n(ref.read(localeProvider));
    try {
      final result = await ref
          .read(notificationPortProvider)
          .test(
            sound: sound,
            message: NotificationMessage.test(sound: sound, strings: strings),
          );
      _setNotificationStatus(_resultStatus(result, testing: true));
    } catch (error, stackTrace) {
      AppLogger.log('Test notification failed: $error\n$stackTrace');
      _setNotificationStatus(_NotificationStatus.testFailed);
    }
  }

  void _setNotificationStatus(
    _NotificationStatus value, {
    bool transient = true,
  }) {
    _notificationStatusTimer?.cancel();
    if (!mounted) return;
    setState(() => _notificationStatus = value);
    if (transient) {
      _notificationStatusTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _notificationStatus = null);
      });
    }
  }
}

String? _notificationHealthText(
  NotificationHealth health,
  ReminderL10n strings,
) {
  return switch (health.status) {
    NotificationHealthStatus.uninitialized => null,
    NotificationHealthStatus.ready => strings.notificationReady,
    NotificationHealthStatus.denied => strings.notificationDenied,
    NotificationHealthStatus.failed => strings.notificationFailed,
  };
}

_NotificationStatus _resultStatus(
  NotificationDeliveryResult result, {
  required bool testing,
}) {
  return switch (result.status) {
    NotificationDeliveryStatus.delivered =>
      testing ? _NotificationStatus.testSent : _NotificationStatus.ready,
    NotificationDeliveryStatus.ready => _NotificationStatus.ready,
    NotificationDeliveryStatus.denied => _NotificationStatus.denied,
    NotificationDeliveryStatus.unavailable => _NotificationStatus.unsupported,
    NotificationDeliveryStatus.failed =>
      testing
          ? _NotificationStatus.testFailed
          : _NotificationStatus.permissionRequestFailed,
  };
}

enum _NotificationStatus {
  settingsSaveFailed,
  requestingPermission,
  permissionRequestFailed,
  sendingTest,
  testFailed,
  testSent,
  ready,
  denied,
  unsupported;

  String text(ReminderL10n strings) => switch (this) {
    settingsSaveFailed => strings.settingsSaveFailed,
    requestingPermission => strings.requestingPermission,
    permissionRequestFailed => strings.permissionRequestFailed,
    sendingTest => strings.sendingTestNotification,
    testFailed => strings.testNotificationFailed,
    testSent => strings.testNotificationSent,
    ready => strings.notificationReady,
    denied => strings.notificationDenied,
    unsupported => strings.notificationUnsupported,
  };
}
