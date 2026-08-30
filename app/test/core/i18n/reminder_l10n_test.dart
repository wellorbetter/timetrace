import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';

void main() {
  test('AppLocale selects complete reminder copy without changing values', () {
    const zh = ReminderL10n(AppLocale.zh);
    const en = ReminderL10n(AppLocale.en);

    expect(zh.focusCarouselLabel, '专注提醒');
    expect(en.focusCarouselLabel, 'Focus reminders');
    expect(en.completedFocusRounds(1), '1 focus round completed');
    expect(en.completedFocusRounds(3), '3 focus rounds completed');
    expect(en.compactDuration(const Duration(minutes: 61)), '1 hour 1 minute');
    expect(dashboardViewLabel('focus', en), 'Focus reminders');
    expect(en.roundsShort(1), 'round');
    expect(en.roundsShort(4), 'rounds');
    expect(
      en.shortBreakCompleteBody(1),
      'The short break is complete. Get ready for 1 minute of focus.',
    );
    expect(
      en.longBreakCompleteBody(2),
      'The long break is complete. Get ready for 2 minutes of focus.',
    );
  });

  test('English privacy fallback redacts paths and legacy fallback text', () {
    const strings = ReminderL10n.en;

    expect(
      strings.applicationName(r'C:\Users\private\secret.exe'),
      'Unnamed application',
    );
    expect(strings.applicationName('未命名应用'), 'Unnamed application');
    expect(strings.applicationName('未知应用'), 'Unnamed application');
    expect(strings.applicationName('Edge'), 'Edge');
  });

  test('generic Overview controls follow AppLocale.en', () {
    const strings = L10n(AppLocale.en);

    expect(strings.shown, 'Shown');
    expect(strings.hidden, 'Hidden');
    expect(strings.moveUp, 'Move up');
    expect(strings.moveDown, 'Move down');
    expect(strings.previousView, 'Previous view');
    expect(strings.nextView, 'Next view');
  });
}
