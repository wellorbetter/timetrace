import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_settings_store.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';

void main() {
  test('safe defaults keep AI and automatic generation disabled', () {
    const settings = RecapAiSettings();
    expect(settings.enabled, isFalse);
    expect(settings.automaticGenerationEnabled, isFalse);
    expect(settings.automaticGenerationTimeMinutes, 22 * 60 + 30);
    expect(settings.includeHabitReflection, isTrue);
    expect(settings.includeImprovementSuggestion, isTrue);
    expect(settings.customPrompt, kDefaultAiDiaryCustomPrompt);
  });

  test('old settings cannot silently opt in and gain new defaults', () {
    final migrated = RecapAiSettings.fromJson({
      'enabled': true,
      'model': 'legacy-model',
    });
    expect(migrated.enabled, isFalse);
    expect(migrated.customPrompt, kDefaultAiDiaryCustomPrompt);
    expect(migrated.includeHabitReflection, isTrue);
    expect(migrated.includeImprovementSuggestion, isTrue);
    expect(migrated.automaticGenerationEnabled, isFalse);
  });

  test('round-trip preserves prompt, preferences, privacy and schedule', () {
    const original = RecapAiSettings(
      enabled: true,
      endpoint: 'https://example.test/chat',
      model: 'diary-model',
      apiKeyEnv: 'DIARY_KEY',
      includeDiaryEntries: true,
      customPrompt: '像睡前随手记一样简短地写。',
      includeHabitReflection: false,
      includeImprovementSuggestion: false,
      automaticGenerationEnabled: true,
      automaticGenerationTimeMinutes: 23 * 60 + 15,
    );

    final restored = RecapAiSettings.fromJson(original.toJson());
    expect(restored.enabled, isTrue);
    expect(restored.endpoint, original.endpoint);
    expect(restored.model, original.model);
    expect(restored.apiKeyEnv, original.apiKeyEnv);
    expect(restored.includeDiaryEntries, isTrue);
    expect(restored.customPrompt, original.customPrompt);
    expect(restored.includeHabitReflection, isFalse);
    expect(restored.includeImprovementSuggestion, isFalse);
    expect(restored.automaticGenerationEnabled, isTrue);
    expect(restored.automaticGenerationTimeMinutes, 1395);
  });

  test('invalid custom prompt and schedule fall back safely', () {
    final settings = RecapAiSettings.fromJson({
      'custom_prompt': '   ',
      'automatic_generation_time_minutes': 9000,
    });
    expect(settings.customPrompt, kDefaultAiDiaryCustomPrompt);
    expect(settings.automaticGenerationTimeMinutes, 1439);
  });

  test('store persists all AI diary fields atomically', () async {
    final directory = await Directory.systemTemp.createTemp(
      'timetrace-ai-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = RecapAiSettingsStore(
      pathOverride: '${directory.path}${Platform.pathSeparator}recap_ai.json',
    );
    const expected = RecapAiSettings(
      enabled: true,
      apiKeyEnv: '',
      customPrompt: '只写一小段，语气自然。',
      includeDiaryEntries: true,
      includeHabitReflection: true,
      includeImprovementSuggestion: false,
      automaticGenerationEnabled: true,
      automaticGenerationTimeMinutes: 21 * 60,
    );

    await store.save(expected);
    final actual = await store.load();

    expect(actual.enabled, isTrue);
    expect(actual.customPrompt, expected.customPrompt);
    expect(actual.includeDiaryEntries, isTrue);
    expect(actual.includeHabitReflection, isTrue);
    expect(actual.includeImprovementSuggestion, isFalse);
    expect(actual.automaticGenerationEnabled, isTrue);
    expect(actual.automaticGenerationTimeMinutes, 21 * 60);
    expect(File('${store.path}.tmp').existsSync(), isFalse);
  });
}
