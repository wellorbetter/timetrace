import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/privacy/safe_display_label.dart';

/// Reminder-specific strings shared by widgets, tray models and notifications.
///
/// The app intentionally uses this lightweight table instead of ARB files.
/// Provider-free widgets default to [zh] for source compatibility; production
/// hosts construct the table from `localeProvider`.
final class ReminderL10n {
  const ReminderL10n(this.locale);

  static const zh = ReminderL10n(AppLocale.zh);
  static const en = ReminderL10n(AppLocale.en);

  final AppLocale locale;

  bool get isZh => locale == AppLocale.zh;

  String _pick(String zhValue, String enValue) => isZh ? zhValue : enValue;

  // App-bar timer entry and quick panel.
  String get dataView => _pick('数据视图', 'Data view');
  String get disabled => _pick('未启用', 'Disabled');
  String get activityPaused => _pick('活动暂停中', 'Activity paused');
  String get focusTimerFrozen => _pick('计时暂停', 'Timer paused');
  String get readyToFocus => _pick('准备专注', 'Ready to focus');
  String get focus => _pick('专注', 'Focus');
  String get shortBreak => _pick('短休息', 'Short break');
  String get longBreak => _pick('长休息', 'Long break');
  String get ready => _pick('准备就绪', 'Ready');
  String get running => _pick('进行中', 'Running');
  String get waitingToStart => _pick('等待开始', 'Waiting to start');
  String get paused => _pick('已暂停', 'Paused');
  String get currentPhaseProgress => _pick('当前阶段进度', 'Current phase progress');
  String get waitForActivity => _pick(
    '等待活动恢复，不会补算暂停时间',
    'Waiting for activity to resume; paused time will not be added',
  );
  String completedFocusRounds(int count) => isZh
      ? '已完成 $count 轮专注'
      : '$count focus ${count == 1 ? 'round' : 'rounds'} completed';
  String get unnamedApplication => _pick('未命名应用', 'Unnamed application');
  String get enablePomodoroHint =>
      _pick('在设置中启用番茄钟后即可开始。', 'Enable Pomodoro in Settings to get started.');
  String get pomodoroSettings => _pick('番茄钟设置', 'Pomodoro settings');
  String get start => _pick('开始', 'Start');
  String get pause => _pick('暂停', 'Pause');
  String get resume => _pick('继续', 'Resume');
  String get skip => _pick('跳过', 'Skip');
  String get stop => _pick('停止', 'Stop');
  String get startFocusTooltip => _pick('开始专注计时', 'Start focus timer');
  String get pauseFocusTooltip => _pick('暂停专注计时', 'Pause focus timer');
  String get resumeFocusTooltip => _pick('继续专注计时', 'Resume focus timer');
  String get skipPhaseTooltip => _pick('跳过当前阶段', 'Skip current phase');
  String get stopFocusTooltip => _pick('停止专注计时', 'Stop focus timer');
  String get resetRounds => _pick('重置轮次', 'Reset rounds');
  String countdownSemantics(String phase, String remaining) =>
      _pick('$phase，剩余 $remaining', '$phase, $remaining remaining');
  String currentCarouselView(String label, int index, int total) => _pick(
    '当前轮播视图：$label，$index/$total',
    'Current carousel view: $label, $index of $total',
  );
  String switchToView(String label) => _pick('切换到$label', 'Switch to $label');

  // Settings.
  String get settingsSectionTitle =>
      _pick('专注与使用提醒', 'Focus & usage reminders');
  String get settingsPrivacySummary => _pick(
    '两个能力彼此独立，默认关闭；所有设置和规则都只保存在本机。',
    'Both features are independent and off by default; all settings and rules stay on this device.',
  );
  String get pomodoro => _pick('番茄钟', 'Pomodoro');
  String pomodoroCapabilitySubtitle(bool enabled) => enabled
      ? _pick(
          '按专注、短休息和长休息循环。',
          'Cycles through focus, short break, and long break.',
        )
      : _pick(
          '关闭时不会开始计时或请求阶段通知。',
          'While off, no timer starts and no phase notification is requested.',
        );
  String get focusDuration => _pick('专注时长', 'Focus duration');
  String get shortBreakDuration => _pick('短休息', 'Short break');
  String get longBreakDuration => _pick('长休息', 'Long break');
  String get longBreakInterval => _pick('长休息间隔', 'Long-break interval');
  String get minutesShort => _pick('分钟', 'min');
  String roundsShort(int count) => _pick('轮', count == 1 ? 'round' : 'rounds');
  String get autoStartNext =>
      _pick('自动开始下一阶段', 'Start next phase automatically');
  String get autoStartNextSubtitle => _pick(
    '关闭时，阶段切换后会等待你手动继续。',
    'When off, each new phase waits for you to continue.',
  );
  String get phaseNotifications => _pick('阶段通知', 'Phase notifications');
  String get phaseNotificationsSubtitle => _pick(
    '专注或休息结束时发送一次桌面通知。',
    'Send one desktop notification when a focus or break phase ends.',
  );
  String get notificationSound => _pick('通知声音', 'Notification sound');
  String get notificationSoundSubtitle => _pick(
    '遵循系统勿扰模式和通知权限。',
    'Respects system Do Not Disturb and notification permission.',
  );
  String get continuousUseReminders =>
      _pick('应用连续使用提醒', 'Application continuous-use reminders');
  String appTimeoutCapabilitySubtitle(bool enabled) => enabled
      ? _pick(
          '只计算同一应用持续位于前台的有效时间。',
          'Counts only valid foreground time in the same application.',
        )
      : _pick(
          '关闭时不会累计连续使用或发送提醒。',
          'While off, continuous use is not counted and no reminder is sent.',
        );
  String get defaultRuleThreshold =>
      _pick('新规则默认阈值', 'Default new-rule threshold');
  String get defaultRuleCooldown =>
      _pick('新规则默认冷却', 'Default new-rule cooldown');
  String get timeoutNotifications => _pick('超时通知', 'Timeout notifications');
  String get timeoutNotificationsSubtitle => _pick(
    '通知只显示应用名称和取整后的持续时间。',
    'Notifications show only the application name and rounded duration.',
  );
  String get timeoutSoundSubtitle =>
      _pick('不会绕过系统勿扰模式。', 'Does not bypass system Do Not Disturb.');
  String get testNotification => _pick('测试通知', 'Test notification');
  String get testNotificationPrivacy => _pick(
    '测试只验证通知服务，不会发送使用记录。',
    'The test checks only the notification service and sends no usage records.',
  );

  // Notification health and actions.
  String get settingsSaveFailed =>
      _pick('设置保存失败，请重试。', 'Could not save settings. Please try again.');
  String get requestingPermission =>
      _pick('正在请求系统通知权限…', 'Requesting system notification permission…');
  String get permissionRequestFailed => _pick(
    '通知权限请求失败，请检查系统设置。',
    'Could not request notification permission. Check system settings.',
  );
  String get sendingTestNotification =>
      _pick('正在发送测试通知…', 'Sending test notification…');
  String get testNotificationFailed => _pick(
    '测试通知发送失败，请检查系统设置。',
    'Could not send the test notification. Check system settings.',
  );
  String get testNotificationSent =>
      _pick('测试通知已发送。', 'Test notification sent.');
  String get notificationReady =>
      _pick('通知服务已准备就绪。', 'Notification service is ready.');
  String get notificationDenied => _pick(
    '通知权限未获允许，请在系统设置中检查。',
    'Notification permission is not granted. Check system settings.',
  );
  String get notificationFailed => _pick(
    '通知服务暂不可用，请检查系统设置或重试。',
    'Notification service is unavailable. Check system settings or try again.',
  );
  String get notificationUnsupported => _pick(
    '当前平台暂不支持桌面通知。',
    'Desktop notifications are not supported on this platform.',
  );

  // Rule list and editor.
  String get rulesTitle => _pick('应用提醒规则', 'Application reminder rules');
  String get globalSwitchOff => _pick('总开关已关闭', 'Global switch is off');
  String get addRuleTooltip =>
      _pick('添加应用提醒规则', 'Add application reminder rule');
  String get add => _pick('添加', 'Add');
  String get retry => _pick('重试', 'Retry');
  String get noRules => _pick('还没有应用提醒规则', 'No application reminder rules yet');
  String get noRulesSubtitle => _pick(
    '添加规则后，只会计算该应用连续位于前台的有效时间。',
    'A rule counts only valid time while that application remains in the foreground.',
  );
  String repeatingRuleDetails(int threshold, int cooldown) => _pick(
    '$threshold 分钟后提醒 · 每 $cooldown 分钟可重复',
    'Remind after $threshold min · Repeat every $cooldown min',
  );
  String singleRuleDetails(int threshold) => _pick(
    '$threshold 分钟后提醒 · 每次连续使用只提醒一次',
    'Remind after $threshold min · Once per continuous-use segment',
  );
  String ruleToggleSemantics(String name, bool enabled) => isZh
      ? '${enabled ? '停用' : '启用'} $name 的提醒规则'
      : '${enabled ? 'Disable' : 'Enable'} the reminder rule for $name';
  String editRuleTooltip(String name) => _pick('编辑 $name', 'Edit $name');
  String deleteRuleTooltip(String name) => _pick('删除 $name', 'Delete $name');
  String get duplicateRule =>
      _pick('这个应用已经有提醒规则。', 'This application already has a reminder rule.');
  String dialogTitle(bool editing) => editing
      ? _pick('编辑应用提醒', 'Edit application reminder')
      : _pick('添加应用提醒', 'Add application reminder');
  String get searchRunningApps =>
      _pick('搜索正在运行的应用', 'Search running applications');
  String get refreshRunningApps =>
      _pick('刷新正在运行的应用', 'Refresh running applications');
  String get noRunningApps => _pick(
    '没有可选择的应用。请先启动目标应用，然后刷新列表。',
    'No applications are available. Start the target application, then refresh the list.',
  );
  String get threshold => _pick('连续使用阈值', 'Continuous-use threshold');
  String get repeatCooldown => _pick('重复提醒冷却', 'Repeat-reminder cooldown');
  String get allowRepeats => _pick('允许重复提醒', 'Allow repeated reminders');
  String get allowRepeatsSubtitle => _pick(
    '同一连续使用段内，仍需经过完整冷却时间。',
    'The full cooldown must elapse within the same continuous-use segment.',
  );
  String get enableRule => _pick('启用这条规则', 'Enable this rule');
  String get enableRuleSubtitle => _pick(
    '关闭后会立即结束这条规则的连续计时。',
    'Turning it off immediately ends this rule\'s continuous timer.',
  );
  String get cancel => _pick('取消', 'Cancel');
  String get save => _pick('保存', 'Save');
  String get delete => _pick('删除', 'Delete');
  String get selectRunningApp =>
      _pick('请选择一个正在运行的应用。', 'Select a running application.');
  String get ruleAvailable => _pick('可创建提醒规则', 'Available for a reminder rule');
  String get invalidMinutes => _pick('请输入 1–1440 分钟', 'Enter 1–1440 minutes');
  String get ruleOperationFailed => _pick(
    '应用提醒规则操作失败，请重试。',
    'Application reminder rule operation failed. Please try again.',
  );
  String get runningAppsRefreshFailed => _pick(
    '无法刷新应用列表，请重试。',
    'Could not refresh the application list. Please try again.',
  );
  String get ruleSaveFailed => _pick(
    '应用提醒规则保存失败，请重试。',
    'Could not save the application reminder rule. Please try again.',
  );
  String get deleteRuleTitle =>
      _pick('删除应用提醒规则？', 'Delete application reminder rule?');
  String deleteRuleConfirmation(String name) =>
      _pick('确定删除“$name”的提醒规则吗？', 'Delete the reminder rule for “$name”?');

  // Tray.
  String get trackingPaused => _pick('已暂停追踪', 'Tracking paused');
  String get trackingActive => _pick('正在追踪使用时间', 'Tracking usage time');
  String get trackingTooltip => _pick('应用使用追踪', 'Application usage tracking');
  String get resumeTracking => _pick('恢复追踪', 'Resume tracking');
  String get pauseTracking => _pick('暂停追踪', 'Pause tracking');
  String get pomodoroDisabled => _pick('番茄钟未启用', 'Pomodoro is disabled');
  String get pomodoroReady => _pick('番茄钟 · 准备开始', 'Pomodoro · Ready to start');
  String get startPomodoro => _pick('开始番茄钟', 'Start Pomodoro');
  String get pausePomodoro => _pick('暂停番茄钟', 'Pause Pomodoro');
  String get resumePomodoro => _pick('继续番茄钟', 'Resume Pomodoro');
  String get startCurrentPhase => _pick('开始当前阶段', 'Start current phase');
  String get skipCurrentPhase => _pick('跳过当前阶段', 'Skip current phase');
  String get stopPomodoro => _pick('停止番茄钟', 'Stop Pomodoro');
  String get showTimeTrace => _pick('显示 TimeTrace', 'Show TimeTrace');
  String get quitTimeTrace => _pick('退出 TimeTrace', 'Quit TimeTrace');

  // Desktop notification content.
  String get appTimeoutNotificationTitle =>
      _pick('连续使用提醒', 'Continuous-use reminder');
  String appTimeoutNotificationBody(String appName, int minutes) => isZh
      ? '$appName 已连续使用 $minutes 分钟，建议休息一下。'
      : '$appName has been used continuously for $minutes ${minutes == 1 ? 'minute' : 'minutes'}. Consider taking a break.';
  String get testNotificationTitle =>
      _pick('TimeTrace 测试通知', 'TimeTrace test notification');
  String get testNotificationBody => _pick(
    '通知已连接。之后的专注与使用提醒会显示在这里。',
    'Notifications are connected. Focus and usage reminders will appear here.',
  );
  String get focusCompleteTitle => _pick('专注完成', 'Focus complete');
  String focusCompleteBody(int minutes) => isZh
      ? '专注阶段已结束，接下来休息 $minutes 分钟。'
      : 'The focus phase is complete. Take a $minutes-minute break next.';
  String get shortBreakCompleteTitle => _pick('短休息完成', 'Short break complete');
  String shortBreakCompleteBody(int minutes) => isZh
      ? '短休息已结束，准备开始 $minutes 分钟专注。'
      : 'The short break is complete. Get ready for $minutes '
            '${minutes == 1 ? 'minute' : 'minutes'} of focus.';
  String get longBreakCompleteTitle => _pick('长休息完成', 'Long break complete');
  String longBreakCompleteBody(int minutes) => isZh
      ? '长休息已结束，准备开始 $minutes 分钟专注。'
      : 'The long break is complete. Get ready for $minutes '
            '${minutes == 1 ? 'minute' : 'minutes'} of focus.';
  String get pomodoroUpdatedTitle => _pick('专注计时', 'Focus timer');
  String get pomodoroUpdatedBody =>
      _pick('计时阶段已更新。', 'The timer phase was updated.');

  /// Redacts path-shaped values and localizes both new and legacy fallbacks.
  String applicationName(String value, {String? fallback}) {
    final localizedFallback = fallback ?? unnamedApplication;
    final trimmed = value.trim();
    if (trimmed == defaultSafeDisplayLabelFallback ||
        trimmed == '未知应用' ||
        trimmed == ReminderL10n.en.unnamedApplication) {
      return localizedFallback;
    }
    return safeDisplayLabel(trimmed, fallback: localizedFallback);
  }

  String compactDuration(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final remainder = minutes % 60;
      if (isZh) {
        return remainder == 0 ? '$hours 小时' : '$hours 小时 $remainder 分钟';
      }
      final hourLabel = hours == 1 ? 'hour' : 'hours';
      if (remainder == 0) return '$hours $hourLabel';
      return '$hours $hourLabel $remainder ${remainder == 1 ? 'minute' : 'minutes'}';
    }
    if (minutes > 0) {
      return isZh
          ? '$minutes 分钟'
          : '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    }
    final seconds = duration.inSeconds.clamp(0, 59);
    return isZh
        ? '$seconds 秒'
        : '$seconds ${seconds == 1 ? 'second' : 'seconds'}';
  }
}
