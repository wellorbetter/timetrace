class RecapAiSettings {
  const RecapAiSettings({
    this.enabled = false,
    this.endpoint = 'https://api.openai.com/v1/chat/completions',
    this.model = '',
    this.apiKeyEnv = 'OPENAI_API_KEY',
    this.includeDiaryEntries = false,
  });

  final bool enabled;
  final String endpoint;
  final String model;
  final String apiKeyEnv;

  /// Diary text is more sensitive than aggregate activity facts, so it remains
  /// local unless the user explicitly opts in.
  final bool includeDiaryEntries;

  bool get isConfigured =>
      enabled && endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  RecapAiSettings copyWith({
    bool? enabled,
    String? endpoint,
    String? model,
    String? apiKeyEnv,
    bool? includeDiaryEntries,
  }) => RecapAiSettings(
    enabled: enabled ?? this.enabled,
    endpoint: endpoint ?? this.endpoint,
    model: model ?? this.model,
    apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
    includeDiaryEntries: includeDiaryEntries ?? this.includeDiaryEntries,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'endpoint': endpoint,
    'model': model,
    'api_key_env': apiKeyEnv,
    'include_diary_entries': includeDiaryEntries,
  };

  factory RecapAiSettings.fromJson(Map<String, Object?> json) => RecapAiSettings(
    enabled: json['enabled'] == true,
    endpoint:
        json['endpoint'] as String? ??
        'https://api.openai.com/v1/chat/completions',
    model: json['model'] as String? ?? '',
    apiKeyEnv: json['api_key_env'] as String? ?? 'OPENAI_API_KEY',
    includeDiaryEntries: json['include_diary_entries'] == true,
  );
}
