import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_rule_dialog.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_rules_section.dart';
import 'package:timetrace_app/src/features/app_limits/presentation/app_timeout_view_models.dart';

void main() {
  const privatePath = r'C:\Users\private\Games\game.exe';
  const rule = AppTimeoutRuleViewModel(
    id: 7,
    applicationKey: privatePath,
    displayName: 'Game',
    thresholdMinutes: 60,
    cooldownMinutes: 30,
    enabled: true,
    repeatEnabled: true,
  );

  testWidgets('rule list stays responsive and never renders executable paths', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    await _pump(
      tester,
      const AppTimeoutRulesSection(remindersEnabled: true, rules: [rule]),
    );
    expect(find.text('Game'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('game.exe'), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(420, 620);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rule list redacts a path accidentally supplied as display name',
    (tester) async {
      await _setSurface(tester, const Size(940, 620));
      await _pump(
        tester,
        const AppTimeoutRulesSection(
          remindersEnabled: true,
          rules: [
            AppTimeoutRuleViewModel(
              id: 8,
              applicationKey: 'private-key',
              displayName: privatePath,
              thresholdMinutes: 60,
              cooldownMinutes: 30,
              enabled: true,
              repeatEnabled: false,
            ),
          ],
        ),
      );

      expect(find.text('未命名应用'), findsOneWidget);
      expect(find.textContaining(privatePath), findsNothing);
      expect(find.textContaining('game.exe'), findsNothing);
    },
  );

  testWidgets('rule list actions and semantics are connected', (tester) async {
    await _setSurface(tester, const Size(940, 620));
    final semantics = tester.ensureSemantics();
    var added = 0;
    AppTimeoutRuleViewModel? edited;
    AppTimeoutRuleViewModel? deleted;
    bool? toggled;
    await _pump(
      tester,
      AppTimeoutRulesSection(
        remindersEnabled: true,
        rules: const [rule],
        onAdd: () => added++,
        onEdit: (value) => edited = value,
        onDelete: (value) => deleted = value,
        onEnabledChanged: (_, value) => toggled = value,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('add-app-timeout-rule')));
    await tester.tap(find.byKey(const ValueKey('app-timeout-rule-edit-7')));
    await tester.tap(find.byKey(const ValueKey('app-timeout-rule-delete-7')));
    await tester.tap(find.byKey(const ValueKey('app-timeout-rule-toggle-7')));
    expect(added, 1);
    expect(edited, same(rule));
    expect(deleted, same(rule));
    expect(toggled, isFalse);

    final node = tester.getSemantics(
      find.byKey(const ValueKey('app-timeout-rule-toggle-7')),
    );
    expect(node.label, contains('Game'));
    expect(node.label, isNot(contains(privatePath)));
    semantics.dispose();
  });

  testWidgets('dialog searches safe labels and submits bounded values', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    AppTimeoutRuleDraftViewModel? submitted;
    await _pump(
      tester,
      AppTimeoutRuleDialog(
        runningApplications: const [
          RunningApplicationViewModel(
            applicationKey: privatePath,
            displayName: 'Game',
            safeQualifier: privatePath,
          ),
          RunningApplicationViewModel(
            applicationKey: 'edge-key',
            displayName: 'Edge',
            safeQualifier: 'msedge.exe',
          ),
        ],
        onSubmit: (value) => submitted = value,
      ),
    );

    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining(r'C:\Users'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('app-rule-search')),
      'edge',
    );
    await tester.pump();
    expect(find.text('Edge'), findsOneWidget);
    expect(find.text('Game'), findsNothing);

    await tester.tap(find.text('Edge'));
    await tester.ensureVisible(find.byKey(const ValueKey('app-rule-repeat')));
    await tester.tap(find.byKey(const ValueKey('app-rule-repeat')));
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-app-timeout-rule')),
    );
    await tester.tap(find.byKey(const ValueKey('save-app-timeout-rule')));

    expect(submitted, isNotNull);
    expect(submitted!.applicationKey, 'edge-key');
    expect(submitted!.displayName, 'Edge');
    expect(submitted!.thresholdMinutes, 60);
    expect(submitted!.cooldownMinutes, 30);
    expect(submitted!.repeatEnabled, isTrue);
  });

  testWidgets('dialog redacts a path-shaped display name before rendering', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 620));
    await _pump(
      tester,
      const AppTimeoutRuleDialog(
        runningApplications: [
          RunningApplicationViewModel(
            applicationKey: 'private-key',
            displayName: privatePath,
          ),
        ],
      ),
    );

    expect(find.text('未命名应用'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('game.exe'), findsNothing);
  });

  testWidgets('dialog validates the 1 to 1440 minute boundary', (tester) async {
    await _setSurface(tester, const Size(940, 620));
    AppTimeoutRuleDraftViewModel? submitted;
    await _pump(
      tester,
      AppTimeoutRuleDialog(
        runningApplications: const [
          RunningApplicationViewModel(
            applicationKey: 'edge-key',
            displayName: 'Edge',
          ),
        ],
        onSubmit: (value) => submitted = value,
      ),
    );

    await tester.tap(find.text('Edge'));
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('app-rule-threshold')),
        matching: find.byType(TextFormField),
      ),
      '1441',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('save-app-timeout-rule')),
    );
    await tester.tap(find.byKey(const ValueKey('save-app-timeout-rule')));
    await tester.pump();

    expect(find.text('请输入 1–1440 分钟'), findsOneWidget);
    expect(submitted, isNull);
  });

  testWidgets('English rule list and editor contain no Chinese fallback', (
    tester,
  ) async {
    await _setSurface(tester, const Size(940, 700));
    await _pump(
      tester,
      const AppTimeoutRulesSection(
        strings: ReminderL10n.en,
        remindersEnabled: true,
        rules: [rule],
      ),
    );
    expect(find.text('Application reminder rules'), findsOneWidget);
    expect(find.textContaining('Remind after 60 min'), findsOneWidget);
    expect(find.textContaining('提醒'), findsNothing);

    await _pump(
      tester,
      const AppTimeoutRuleDialog(
        strings: ReminderL10n.en,
        runningApplications: [
          RunningApplicationViewModel(
            applicationKey: 'private-key',
            displayName: privatePath,
          ),
        ],
      ),
    );
    expect(find.text('Add application reminder'), findsOneWidget);
    expect(find.text('Unnamed application'), findsOneWidget);
    expect(find.textContaining(privatePath), findsNothing);
    expect(find.textContaining('应用提醒'), findsNothing);
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
