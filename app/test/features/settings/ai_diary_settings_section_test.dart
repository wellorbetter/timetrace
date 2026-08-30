import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/settings/presentation/widgets/ai_diary_settings_section.dart';

void main() {
  testWidgets(
    'disabled state stays compact and explains the privacy boundary',
    (tester) async {
      await _pumpSection(tester, initial: const RecapAiSettings());

      expect(
        find.byKey(const ValueKey('ai-diary-settings-inline')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-diary-disabled-notice')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ai-diary-endpoint')), findsNothing);
      expect(find.textContaining('不会向模型服务发送'), findsOneWidget);
    },
  );

  testWidgets('enabling expands all inline configuration without a dialog', (
    tester,
  ) async {
    await _pumpSection(tester, initial: const RecapAiSettings());

    await tester.tap(find.byKey(const ValueKey('ai-diary-enabled-switch')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('ai-diary-endpoint')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-diary-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-diary-key-guide')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-diary-custom-prompt')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-diary-habit-reflection')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-diary-improvement-suggestion')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('ai-diary-auto-generation')),
      findsOneWidget,
    );
  });

  testWidgets('saves prompt, privacy and automatic schedule controls', (
    tester,
  ) async {
    RecapAiSettings? saved;
    await _pumpSection(
      tester,
      initial: const RecapAiSettings(enabled: true),
      onSave: (value) async => saved = value,
    );

    await tester.enterText(
      find.byKey(const ValueKey('ai-diary-custom-prompt')),
      '写成一段简短的睡前日记。',
    );
    final reflection = find.byKey(const ValueKey('ai-diary-habit-reflection'));
    await tester.ensureVisible(reflection);
    await tester.tap(reflection);
    final suggestion = find.byKey(
      const ValueKey('ai-diary-improvement-suggestion'),
    );
    await tester.ensureVisible(suggestion);
    await tester.tap(suggestion);
    final existing = find.byKey(const ValueKey('ai-diary-include-existing'));
    await tester.ensureVisible(existing);
    await tester.tap(existing);
    final automatic = find.byKey(const ValueKey('ai-diary-auto-generation'));
    await tester.ensureVisible(automatic);
    await tester.tap(automatic);
    await tester.pumpAndSettle();

    final save = find.byKey(const ValueKey('ai-diary-save-settings'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.customPrompt, '写成一段简短的睡前日记。');
    expect(saved!.includeHabitReflection, isFalse);
    expect(saved!.includeImprovementSuggestion, isFalse);
    expect(saved!.includeDiaryEntries, isTrue);
    expect(saved!.automaticGenerationEnabled, isTrue);
    expect(saved!.automaticGenerationTimeMinutes, 22 * 60 + 30);
  });

  testWidgets('restores the default prompt and tests without usage payload', (
    tester,
  ) async {
    RecapAiSettings? tested;
    RecapAiSettings? saved;
    await _pumpSection(
      tester,
      initial: const RecapAiSettings(enabled: true, customPrompt: '旧的自定义要求'),
      environment: const {'DEEPSEEK_API_KEY': 'secret'},
      onTestConnection: (value) async {
        tested = value;
        return null;
      },
      onSave: (value) async => saved = value,
    );

    final reset = find.byKey(const ValueKey('ai-diary-reset-prompt'));
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pump();

    final testConnection = find.byKey(
      const ValueKey('ai-diary-test-connection'),
    );
    await tester.ensureVisible(testConnection);
    await tester.tap(testConnection);
    await tester.pumpAndSettle();
    expect(tested, isNotNull);
    expect(find.text('连接成功，可以生成 AI 日记。'), findsOneWidget);

    final save = find.byKey(const ValueKey('ai-diary-save-settings'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved!.customPrompt, kDefaultAiDiaryCustomPrompt.trim());
  });

  testWidgets('uses a stacked field layout at compact desktop width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpSection(
      tester,
      initial: const RecapAiSettings(enabled: true),
      width: 440,
    );

    expect(tester.takeException(), isNull);
    final endpointTop = tester.getTopLeft(
      find.byKey(const ValueKey('ai-diary-endpoint')),
    );
    final modelTop = tester.getTopLeft(
      find.byKey(const ValueKey('ai-diary-model')),
    );
    expect(modelTop.dy, greaterThan(endpointTop.dy));
  });
}

Future<void> _pumpSection(
  WidgetTester tester, {
  required RecapAiSettings initial,
  double width = 820,
  Map<String, String>? environment,
  Future<String?> Function(RecapAiSettings)? onTestConnection,
  Future<void> Function(RecapAiSettings)? onSave,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: AiDiarySettingsSection(
              initial: initial,
              defaultPrompt: kDefaultAiDiaryCustomPrompt,
              environment: environment,
              platform: 'windows',
              onTestConnection: onTestConnection ?? (_) async => null,
              onSave: onSave ?? (_) async {},
            ),
          ),
        ),
      ),
    ),
  ),
);
