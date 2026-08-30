import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/focus/presentation/focus_settings_section.dart';

void main() {
  testWidgets('defaults both capabilities to disabled', (tester) async {
    await _setSurface(tester, const Size(940, 620));
    await _pump(tester, const FocusSettingsSection());

    final pomodoro = tester.widget<SwitchListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('pomodoro-enabled-row')),
        matching: find.byType(SwitchListTile),
      ),
    );
    final appTimeout = tester.widget<SwitchListTile>(
      find.descendant(
        of: find.byKey(const ValueKey('app-timeout-enabled-row')),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(pomodoro.value, isFalse);
    expect(appTimeout.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('feature switches and test action invoke callbacks', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    bool? pomodoro;
    bool? appTimeout;
    var tested = 0;
    await _pump(
      tester,
      FocusSettingsSection(
        onPomodoroEnabledChanged: (value) => pomodoro = value,
        onAppTimeoutEnabledChanged: (value) => appTimeout = value,
        onTestNotification: () => tested++,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('pomodoro-enabled-row')));
    await tester.tap(find.byKey(const ValueKey('app-timeout-enabled-row')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('test-notification-button')),
    );
    await tester.tap(find.byKey(const ValueKey('test-notification-button')));
    expect(pomodoro, isTrue);
    expect(appTimeout, isTrue);
    expect(tested, 1);
  });

  testWidgets('default app cooldown exposes value and callback', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    int? cooldown;
    int? committedCooldown;
    await _pump(
      tester,
      FocusSettingsSection(
        appTimeoutEnabled: true,
        defaultAppCooldownMinutes: 30,
        onDefaultAppCooldownMinutesChanged: (value) => cooldown = value,
        onDefaultAppCooldownMinutesChangeEnd: (value) =>
            committedCooldown = value,
      ),
    );

    final slider = tester.widget<Slider>(
      find.descendant(
        of: find.byKey(const ValueKey('app-cooldown-setting')),
        matching: find.byType(Slider),
      ),
    );
    expect(slider.value, 30);
    slider.onChanged!(90);
    expect(cooldown, 90);
    expect(committedCooldown, isNull);
    slider.onChangeEnd!(90);
    expect(committedCooldown, 90);
  });

  testWidgets('wide and narrow settings layouts do not overflow', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    await _pump(
      tester,
      const FocusSettingsSection(
        pomodoroEnabled: true,
        appTimeoutEnabled: true,
        defaultAppCooldownMinutes: 30,
      ),
    );
    expect(
      find.byKey(const ValueKey('focus-settings-wide-grid')),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(420, 620);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('focus-settings-stacked-grid')),
      findsNWidgets(2),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders all reminder settings labels in English', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 900));
    await _pump(
      tester,
      const FocusSettingsSection(
        strings: ReminderL10n.en,
        pomodoroEnabled: true,
        appTimeoutEnabled: true,
        longBreakInterval: 1,
      ),
    );

    expect(find.text('Focus & usage reminders'), findsOneWidget);
    expect(find.text('Pomodoro'), findsOneWidget);
    expect(find.text('Application continuous-use reminders'), findsOneWidget);
    expect(find.text('Test notification'), findsOneWidget);
    expect(find.text('1 round'), findsOneWidget);
    expect(find.textContaining('番茄钟'), findsNothing);
  });
}

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: child,
        ),
      ),
    ),
  );
}
