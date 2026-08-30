import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';

/// Provider-free settings surface for Pomodoro and application reminders.
///
/// The feature switches default to off so merely adding this widget to an
/// upgraded installation cannot opt the user into notifications.
class FocusSettingsSection extends StatelessWidget {
  const FocusSettingsSection({
    this.strings = ReminderL10n.zh,
    this.pomodoroEnabled = false,
    this.focusMinutes = 25,
    this.shortBreakMinutes = 5,
    this.longBreakMinutes = 15,
    this.longBreakInterval = 4,
    this.autoStartNext = false,
    this.pomodoroNotificationsEnabled = true,
    this.pomodoroSoundEnabled = true,
    this.appTimeoutEnabled = false,
    this.defaultAppThresholdMinutes = 60,
    this.defaultAppCooldownMinutes = 30,
    this.appTimeoutNotificationsEnabled = true,
    this.appTimeoutSoundEnabled = true,
    this.onPomodoroEnabledChanged,
    this.onFocusMinutesChanged,
    this.onFocusMinutesChangeEnd,
    this.onShortBreakMinutesChanged,
    this.onShortBreakMinutesChangeEnd,
    this.onLongBreakMinutesChanged,
    this.onLongBreakMinutesChangeEnd,
    this.onLongBreakIntervalChanged,
    this.onLongBreakIntervalChangeEnd,
    this.onAutoStartNextChanged,
    this.onPomodoroNotificationsChanged,
    this.onPomodoroSoundChanged,
    this.onAppTimeoutEnabledChanged,
    this.onDefaultAppThresholdMinutesChanged,
    this.onDefaultAppThresholdMinutesChangeEnd,
    this.onDefaultAppCooldownMinutesChanged,
    this.onDefaultAppCooldownMinutesChangeEnd,
    this.onAppTimeoutNotificationsChanged,
    this.onAppTimeoutSoundChanged,
    this.onTestNotification,
    this.notificationStatus,
    super.key,
  });

  final ReminderL10n strings;

  final bool pomodoroEnabled;
  final int focusMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;
  final int longBreakInterval;
  final bool autoStartNext;
  final bool pomodoroNotificationsEnabled;
  final bool pomodoroSoundEnabled;

  final bool appTimeoutEnabled;
  final int defaultAppThresholdMinutes;
  final int defaultAppCooldownMinutes;
  final bool appTimeoutNotificationsEnabled;
  final bool appTimeoutSoundEnabled;

  final ValueChanged<bool>? onPomodoroEnabledChanged;
  final ValueChanged<int>? onFocusMinutesChanged;
  final ValueChanged<int>? onFocusMinutesChangeEnd;
  final ValueChanged<int>? onShortBreakMinutesChanged;
  final ValueChanged<int>? onShortBreakMinutesChangeEnd;
  final ValueChanged<int>? onLongBreakMinutesChanged;
  final ValueChanged<int>? onLongBreakMinutesChangeEnd;
  final ValueChanged<int>? onLongBreakIntervalChanged;
  final ValueChanged<int>? onLongBreakIntervalChangeEnd;
  final ValueChanged<bool>? onAutoStartNextChanged;
  final ValueChanged<bool>? onPomodoroNotificationsChanged;
  final ValueChanged<bool>? onPomodoroSoundChanged;

  final ValueChanged<bool>? onAppTimeoutEnabledChanged;
  final ValueChanged<int>? onDefaultAppThresholdMinutesChanged;
  final ValueChanged<int>? onDefaultAppThresholdMinutesChangeEnd;
  final ValueChanged<int>? onDefaultAppCooldownMinutesChanged;
  final ValueChanged<int>? onDefaultAppCooldownMinutesChangeEnd;
  final ValueChanged<bool>? onAppTimeoutNotificationsChanged;
  final ValueChanged<bool>? onAppTimeoutSoundChanged;

  final VoidCallback? onTestNotification;
  final String? notificationStatus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey('focus-settings-section'),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.md,
              TimeTraceSpace.md,
              TimeTraceSpace.md,
              TimeTraceSpace.xs,
            ),
            child: SectionTitle(
              icon: Icons.timer_outlined,
              title: strings.settingsSectionTitle,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.md,
              0,
              TimeTraceSpace.md,
              TimeTraceSpace.sm,
            ),
            child: Text(
              strings.settingsPrivacySummary,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          _CapabilityHeader(
            key: const ValueKey('pomodoro-enabled-row'),
            icon: Icons.av_timer_rounded,
            title: strings.pomodoro,
            subtitle: strings.pomodoroCapabilitySubtitle(pomodoroEnabled),
            value: pomodoroEnabled,
            onChanged: onPomodoroEnabledChanged,
          ),
          _EnabledArea(
            enabled: pomodoroEnabled,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                TimeTraceSpace.md,
                0,
                TimeTraceSpace.md,
                TimeTraceSpace.md,
              ),
              child: Column(
                children: [
                  _ResponsiveSettingsGrid(
                    children: [
                      _IntSliderSetting(
                        key: const ValueKey('focus-minutes-setting'),
                        label: strings.focusDuration,
                        value: focusMinutes,
                        min: 1,
                        max: 120,
                        suffix: strings.minutesShort,
                        onChanged: onFocusMinutesChanged,
                        onChangeEnd: onFocusMinutesChangeEnd,
                      ),
                      _IntSliderSetting(
                        key: const ValueKey('short-break-minutes-setting'),
                        label: strings.shortBreakDuration,
                        value: shortBreakMinutes,
                        min: 1,
                        max: 60,
                        suffix: strings.minutesShort,
                        onChanged: onShortBreakMinutesChanged,
                        onChangeEnd: onShortBreakMinutesChangeEnd,
                      ),
                      _IntSliderSetting(
                        key: const ValueKey('long-break-minutes-setting'),
                        label: strings.longBreakDuration,
                        value: longBreakMinutes,
                        min: 1,
                        max: 120,
                        suffix: strings.minutesShort,
                        onChanged: onLongBreakMinutesChanged,
                        onChangeEnd: onLongBreakMinutesChangeEnd,
                      ),
                      _IntSliderSetting(
                        key: const ValueKey('long-break-interval-setting'),
                        label: strings.longBreakInterval,
                        value: longBreakInterval,
                        min: 1,
                        max: 12,
                        suffix: strings.roundsShort(longBreakInterval),
                        onChanged: onLongBreakIntervalChanged,
                        onChangeEnd: onLongBreakIntervalChangeEnd,
                      ),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  _ToggleSetting(
                    key: const ValueKey('focus-auto-next-setting'),
                    title: strings.autoStartNext,
                    subtitle: strings.autoStartNextSubtitle,
                    value: autoStartNext,
                    onChanged: onAutoStartNextChanged,
                  ),
                  _ToggleSetting(
                    key: const ValueKey('focus-notifications-setting'),
                    title: strings.phaseNotifications,
                    subtitle: strings.phaseNotificationsSubtitle,
                    value: pomodoroNotificationsEnabled,
                    onChanged: onPomodoroNotificationsChanged,
                  ),
                  _ToggleSetting(
                    key: const ValueKey('focus-sound-setting'),
                    title: strings.notificationSound,
                    subtitle: strings.notificationSoundSubtitle,
                    value: pomodoroSoundEnabled,
                    enabled: pomodoroNotificationsEnabled,
                    onChanged: onPomodoroSoundChanged,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          _CapabilityHeader(
            key: const ValueKey('app-timeout-enabled-row'),
            icon: Icons.notifications_active_outlined,
            title: strings.continuousUseReminders,
            subtitle: strings.appTimeoutCapabilitySubtitle(appTimeoutEnabled),
            value: appTimeoutEnabled,
            onChanged: onAppTimeoutEnabledChanged,
          ),
          _EnabledArea(
            enabled: appTimeoutEnabled,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                TimeTraceSpace.md,
                0,
                TimeTraceSpace.md,
                TimeTraceSpace.md,
              ),
              child: Column(
                children: [
                  _ResponsiveSettingsGrid(
                    children: [
                      _IntSliderSetting(
                        key: const ValueKey('app-threshold-setting'),
                        label: strings.defaultRuleThreshold,
                        value: defaultAppThresholdMinutes,
                        min: 1,
                        max: 1440,
                        suffix: strings.minutesShort,
                        onChanged: onDefaultAppThresholdMinutesChanged,
                        onChangeEnd: onDefaultAppThresholdMinutesChangeEnd,
                      ),
                      _IntSliderSetting(
                        key: const ValueKey('app-cooldown-setting'),
                        label: strings.defaultRuleCooldown,
                        value: defaultAppCooldownMinutes,
                        min: 1,
                        max: 1440,
                        suffix: strings.minutesShort,
                        onChanged: onDefaultAppCooldownMinutesChanged,
                        onChangeEnd: onDefaultAppCooldownMinutesChangeEnd,
                      ),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  _ToggleSetting(
                    key: const ValueKey('app-notifications-setting'),
                    title: strings.timeoutNotifications,
                    subtitle: strings.timeoutNotificationsSubtitle,
                    value: appTimeoutNotificationsEnabled,
                    onChanged: onAppTimeoutNotificationsChanged,
                  ),
                  _ToggleSetting(
                    key: const ValueKey('app-sound-setting'),
                    title: strings.notificationSound,
                    subtitle: strings.timeoutSoundSubtitle,
                    value: appTimeoutSoundEnabled,
                    enabled: appTimeoutNotificationsEnabled,
                    onChanged: onAppTimeoutSoundChanged,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.md),
            child: Wrap(
              spacing: TimeTraceSpace.sm,
              runSpacing: TimeTraceSpace.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('test-notification-button'),
                  onPressed: onTestNotification,
                  icon: const Icon(Icons.notifications_none_rounded, size: 17),
                  label: Text(strings.testNotification),
                ),
                if (notificationStatus?.trim().isNotEmpty ?? false)
                  Text(
                    notificationStatus!,
                    key: const ValueKey('notification-status'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else
                  Text(
                    strings.testNotificationPrivacy,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CapabilityHeader extends StatelessWidget {
  const _CapabilityHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _EnabledArea extends StatelessWidget {
  const _EnabledArea({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.48,
      duration: TimeTraceMotion.fast,
      child: IgnorePointer(ignoring: !enabled, child: child),
    );
  }
}

class _ResponsiveSettingsGrid extends StatelessWidget {
  const _ResponsiveSettingsGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            key: const ValueKey('focus-settings-stacked-grid'),
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  const SizedBox(height: TimeTraceSpace.xs),
              ],
            ],
          );
        }
        return Wrap(
          key: const ValueKey('focus-settings-wide-grid'),
          spacing: TimeTraceSpace.md,
          runSpacing: TimeTraceSpace.xs,
          children: [
            for (final child in children)
              SizedBox(
                width: (constraints.maxWidth - TimeTraceSpace.md) / 2,
                child: child,
              ),
          ],
        );
      },
    );
  }
}

class _IntSliderSetting extends StatelessWidget {
  const _IntSliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
    required this.onChangeEnd,
    super.key,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final String suffix;
  final ValueChanged<int>? onChanged;
  final ValueChanged<int>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final safeValue = value.clamp(min, max);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: label,
      value: '$safeValue $suffix',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(
                '$safeValue $suffix',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: safeValue.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: max - min,
            label: '$safeValue $suffix',
            onChanged: onChanged == null
                ? null
                : (next) => onChanged!(next.round()),
            onChangeEnd: onChangeEnd == null
                ? null
                : (next) => onChangeEnd!(next.round()),
          ),
        ],
      ),
    );
  }
}

class _ToggleSetting extends StatelessWidget {
  const _ToggleSetting({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}
