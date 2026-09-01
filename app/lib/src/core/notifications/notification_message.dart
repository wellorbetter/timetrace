import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';

enum NotificationKind {
  pomodoroFocusComplete,
  pomodoroShortBreakComplete,
  pomodoroLongBreakComplete,
  appTimeout,
  test,
}

/// Presentation-safe message passed from reminder domain effects to the
/// desktop adapter. Callers must not put executable paths or window titles in
/// [title], [body], or [payload].
class NotificationMessage {
  const NotificationMessage({
    required this.kind,
    required this.title,
    required this.body,
    required this.sound,
    this.payload,
  });

  factory NotificationMessage.appTimeout({
    required String appName,
    required int activeMinutes,
    required bool sound,
    ReminderL10n strings = ReminderL10n.zh,
  }) => NotificationMessage(
    kind: NotificationKind.appTimeout,
    title: strings.appTimeoutNotificationTitle,
    body: strings.appTimeoutNotificationBody(
      strings.applicationName(appName),
      activeMinutes,
    ),
    sound: sound,
    payload: 'app-timeout',
  );

  factory NotificationMessage.test({
    bool sound = true,
    ReminderL10n strings = ReminderL10n.zh,
  }) => NotificationMessage(
    kind: NotificationKind.test,
    title: strings.testNotificationTitle,
    body: strings.testNotificationBody,
    sound: sound,
    payload: 'notification-test',
  );

  final NotificationKind kind;
  final String title;
  final String body;
  final bool sound;
  final String? payload;
}
