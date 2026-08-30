const kDefaultAiDiaryCustomPrompt = '''
用第一人称和自然口语写作，控制在 200～300 字。
先整理今天主要的使用情况，再简单反思时间使用习惯。
只有在事实充分时，才给出一条明天可以尝试的温和建议。
不要使用列表、数据报告或过度正式的语气。
''';

class RecapAiSettings {
  const RecapAiSettings({
    this.enabled = false,
    this.endpoint = 'https://api.deepseek.com/chat/completions',
    this.model = 'deepseek-v4-flash',
    this.apiKeyEnv = 'DEEPSEEK_API_KEY',
    this.includeDiaryEntries = false,
    this.customPrompt = kDefaultAiDiaryCustomPrompt,
    this.includeHabitReflection = true,
    this.includeImprovementSuggestion = true,
    this.automaticGenerationEnabled = false,
    this.automaticGenerationTimeMinutes = 22 * 60 + 30,
  });

  final bool enabled;
  final String endpoint;
  final String model;
  final String apiKeyEnv;

  /// Diary text is more sensitive than aggregate activity facts, so it remains
  /// local unless the user explicitly opts in.
  final bool includeDiaryEntries;

  /// User-editable writing preferences. Factual and privacy guardrails live in
  /// the fixed system prompt and are deliberately not configurable here.
  final String customPrompt;
  final bool includeHabitReflection;
  final bool includeImprovementSuggestion;

  /// Optional daily generation schedule expressed as local minutes after
  /// midnight. Keeping this as a primitive makes it safe to persist without a
  /// Flutter dependency and lets the scheduler interpret it in local time.
  final bool automaticGenerationEnabled;
  final int automaticGenerationTimeMinutes;

  bool get isConfigured =>
      enabled && endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  bool get hasProviderConfiguration =>
      endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  int get normalizedAutomaticGenerationTimeMinutes =>
      automaticGenerationTimeMinutes.clamp(0, 24 * 60 - 1).toInt();

  RecapAiSettings copyWith({
    bool? enabled,
    String? endpoint,
    String? model,
    String? apiKeyEnv,
    bool? includeDiaryEntries,
    String? customPrompt,
    bool? includeHabitReflection,
    bool? includeImprovementSuggestion,
    bool? automaticGenerationEnabled,
    int? automaticGenerationTimeMinutes,
  }) => RecapAiSettings(
    enabled: enabled ?? this.enabled,
    endpoint: endpoint ?? this.endpoint,
    model: model ?? this.model,
    apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
    includeDiaryEntries: includeDiaryEntries ?? this.includeDiaryEntries,
    customPrompt: customPrompt ?? this.customPrompt,
    includeHabitReflection:
        includeHabitReflection ?? this.includeHabitReflection,
    includeImprovementSuggestion:
        includeImprovementSuggestion ?? this.includeImprovementSuggestion,
    automaticGenerationEnabled:
        automaticGenerationEnabled ?? this.automaticGenerationEnabled,
    automaticGenerationTimeMinutes:
        automaticGenerationTimeMinutes ?? this.automaticGenerationTimeMinutes,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    // Old builds defaulted AI to on. Requiring this consent marker prevents
    // those implicit defaults from becoming a silent cloud opt-in.
    'explicit_ai_opt_in': enabled,
    'endpoint': endpoint,
    'model': model,
    'api_key_env': apiKeyEnv,
    'include_diary_entries': includeDiaryEntries,
    'custom_prompt': customPrompt,
    'include_habit_reflection': includeHabitReflection,
    'include_improvement_suggestion': includeImprovementSuggestion,
    'automatic_generation_enabled': automaticGenerationEnabled,
    'automatic_generation_time_minutes':
        normalizedAutomaticGenerationTimeMinutes,
  };

  factory RecapAiSettings.fromJson(
    Map<String, Object?> json,
  ) => RecapAiSettings(
    enabled: json['enabled'] == true && json['explicit_ai_opt_in'] == true,
    endpoint:
        json['endpoint'] as String? ??
        'https://api.deepseek.com/chat/completions',
    model: json['model'] as String? ?? 'deepseek-v4-flash',
    apiKeyEnv: json['api_key_env'] as String? ?? 'DEEPSEEK_API_KEY',
    includeDiaryEntries: json['include_diary_entries'] == true,
    customPrompt: _nonEmptyString(
      json['custom_prompt'],
      fallback: kDefaultAiDiaryCustomPrompt,
    ),
    includeHabitReflection: json['include_habit_reflection'] is bool
        ? json['include_habit_reflection']! as bool
        : true,
    includeImprovementSuggestion: json['include_improvement_suggestion'] is bool
        ? json['include_improvement_suggestion']! as bool
        : true,
    automaticGenerationEnabled: json['automatic_generation_enabled'] == true,
    automaticGenerationTimeMinutes: _scheduleMinutes(
      json['automatic_generation_time_minutes'],
    ),
  );
}

String _nonEmptyString(Object? value, {required String fallback}) {
  if (value is! String || value.trim().isEmpty) return fallback;
  return value;
}

int _scheduleMinutes(Object? value) {
  if (value is! num) return 22 * 60 + 30;
  return value.toInt().clamp(0, 24 * 60 - 1).toInt();
}
