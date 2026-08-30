import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_ai_settings_dialog.dart';

void main() {
  test('old settings cannot become an implicit AI opt-in', () {
    final migrated = RecapAiSettings.fromJson({
      'enabled': true,
      'model': 'deepseek-v4-flash',
    });
    expect(migrated.enabled, isFalse);

    final explicit = RecapAiSettings.fromJson(
      const RecapAiSettings(enabled: true).toJson(),
    );
    expect(explicit.enabled, isTrue);
  });

  testWidgets('defaults to local recap and hides cloud setup', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpDialog(tester, environment: const {});

    expect(find.text('回顾设置'), findsOneWidget);
    expect(find.text('使用 AI 增强'), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-ai-mode-local')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recap-ai-credential-section')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling AI reveals model, credential and privacy controls', (
    tester,
  ) async {
    await _pumpDialog(tester, environment: const {});

    await tester.tap(find.byKey(const ValueKey('recap-ai-enabled-switch')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('recap-ai-credential-section')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('recap-ai-diary-toggle')), findsOneWidget);
    expect(find.byKey(const ValueKey('recap-ai-key-guide')), findsOneWidget);
    final setupCommand = Platform.isWindows
        ? 'setx DEEPSEEK_API_KEY'
        : 'export DEEPSEEK_API_KEY';
    expect(find.textContaining(setupCommand), findsOneWidget);
  });

  testWidgets('connected state exposes a no-usage-data connection check', (
    tester,
  ) async {
    var calls = 0;
    await _pumpDialog(
      tester,
      environment: const {'DEEPSEEK_API_KEY': 'never-render-this-value'},
      initial: const RecapAiSettings(enabled: true),
      onTestConnection: (_) async {
        calls++;
        return null;
      },
    );

    expect(find.text('环境变量'), findsOneWidget);
    expect(find.textContaining('never-render-this-value'), findsNothing);
    expect(find.textContaining('不发送任何 TimeTrace 使用数据'), findsOneWidget);
    final testButton = find.byKey(const ValueKey('recap-ai-test-connection'));
    await tester.ensureVisible(testButton);
    await tester.tap(testButton);
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('连接成功，可以生成 AI 回顾。'), findsOneWidget);
  });

  testWidgets('saving preserves the explicit diary privacy opt-in', (
    tester,
  ) async {
    RecapAiSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: TimetraceTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  saved = await showDialog<RecapAiSettings>(
                    context: context,
                    builder: (_) => RecapAiSettingsDialog(
                      initial: const RecapAiSettings(),
                      environment: const {},
                      onTestConnection: (_) async => null,
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('recap-ai-enabled-switch')));
    await tester.pumpAndSettle();
    final diarySwitch = find.byKey(const ValueKey('recap-ai-diary-toggle'));
    await tester.ensureVisible(diarySwitch);
    await tester.tap(diarySwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recap-ai-save-settings')));
    await tester.pumpAndSettle();

    expect(saved?.enabled, isTrue);
    expect(saved?.includeDiaryEntries, isTrue);
    expect(saved?.model, 'deepseek-v4-flash');
  });
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required Map<String, String> environment,
  RecapAiSettings initial = const RecapAiSettings(),
  Future<String?> Function(RecapAiSettings)? onTestConnection,
}) => tester.pumpWidget(
  MaterialApp(
    theme: TimetraceTheme.dark(),
    home: Scaffold(
      body: Center(
        child: RecapAiSettingsDialog(
          initial: initial,
          environment: environment,
          onTestConnection: onTestConnection ?? (_) async => null,
        ),
      ),
    ),
  ),
);
