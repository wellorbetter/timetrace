class RecapAiSettings {
  const RecapAiSettings({
    this.enabled = false,
    this.provider = 'openai',
    this.endpoint = 'https://api.openai.com/v1/chat/completions',
    this.model = '',
    this.apiKeyEnv = 'OPENAI_API_KEY',
    this.runtimeApiKey = '',
    this.includeDiaryEntries = false,
    this.responseStyle = 'balanced',
    this.customSystemPrompt = '',
  });

  final bool enabled;
  final String provider;
  final String endpoint;
  final String model;
  final String apiKeyEnv;

  /// Session-only secret entered in the UI. It is intentionally excluded from
  /// [toJson] so TimeTrace never writes a plaintext API key to disk.
  final String runtimeApiKey;

  /// Diary text is more sensitive than aggregate activity facts, so it remains
  /// local unless the user explicitly opts in.
  final bool includeDiaryEntries;

  /// concise / balanced / detailed
  final String responseStyle;

  /// Optional advanced instruction appended to TimeTrace's safety prompt.
  final String customSystemPrompt;

  bool get isConfigured =>
      enabled && endpoint.trim().isNotEmpty && model.trim().isNotEmpty;

  bool get needsApiKey => provider != 'ollama';

  bool get isFreeOnline =>
      provider == 'gemini-free' || provider == 'openrouter-free';

  String get displayProvider => switch (provider) {
    'gemini-free' => 'Gemini Free',
    'openrouter-free' => 'OpenRouter Free',
    'openai' => 'OpenAI',
    'openrouter' => 'OpenRouter',
    'deepseek' => 'DeepSeek',
    'ollama' => 'Ollama（本地）',
    _ => '自定义兼容接口',
  };

  RecapAiSettings copyWith({
    bool? enabled,
    String? provider,
    String? endpoint,
    String? model,
    String? apiKeyEnv,
    String? runtimeApiKey,
    bool? includeDiaryEntries,
    String? responseStyle,
    String? customSystemPrompt,
  }) => RecapAiSettings(
    enabled: enabled ?? this.enabled,
    provider: provider ?? this.provider,
    endpoint: endpoint ?? this.endpoint,
    model: model ?? this.model,
    apiKeyEnv: apiKeyEnv ?? this.apiKeyEnv,
    runtimeApiKey: runtimeApiKey ?? this.runtimeApiKey,
    includeDiaryEntries: includeDiaryEntries ?? this.includeDiaryEntries,
    responseStyle: responseStyle ?? this.responseStyle,
    customSystemPrompt: customSystemPrompt ?? this.customSystemPrompt,
  );

  Map<String, Object> toJson() => {
    'enabled': enabled,
    'provider': provider,
    'endpoint': endpoint,
    'model': model,
    'api_key_env': apiKeyEnv,
    'include_diary_entries': includeDiaryEntries,
    'response_style': responseStyle,
    'custom_system_prompt': customSystemPrompt,
  };

  factory RecapAiSettings.fromJson(Map<String, Object?> json) => RecapAiSettings(
    enabled: json['enabled'] == true,
    provider: json['provider'] as String? ?? 'openai',
    endpoint:
        json['endpoint'] as String? ??
        'https://api.openai.com/v1/chat/completions',
    model: json['model'] as String? ?? '',
    apiKeyEnv: json['api_key_env'] as String? ?? 'OPENAI_API_KEY',
    includeDiaryEntries: json['include_diary_entries'] == true,
    responseStyle: json['response_style'] as String? ?? 'balanced',
    customSystemPrompt: json['custom_system_prompt'] as String? ?? '',
  );
}

const recapProviderEndpoints = <String, String>{
  'gemini-free':
      'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
  'openrouter-free': 'https://openrouter.ai/api/v1/chat/completions',
  'openai': 'https://api.openai.com/v1/chat/completions',
  'openrouter': 'https://openrouter.ai/api/v1/chat/completions',
  'deepseek': 'https://api.deepseek.com/chat/completions',
  'ollama': 'http://127.0.0.1:11434/v1/chat/completions',
};

const recapProviderModels = <String, List<String>>{
  'gemini-free': ['gemini-2.5-flash'],
  'openrouter-free': ['openrouter/free'],
  'openai': ['gpt-5-mini', 'gpt-5-nano'],
  'openrouter': ['openai/gpt-5-mini', 'google/gemini-2.5-flash'],
  'deepseek': ['deepseek-chat', 'deepseek-reasoner'],
  'ollama': ['qwen3:8b', 'llama3.2:3b'],
};

const recapProviderKeyEnvs = <String, String>{
  'gemini-free': 'GEMINI_API_KEY',
  'openrouter-free': 'OPENROUTER_API_KEY',
  'openai': 'OPENAI_API_KEY',
  'openrouter': 'OPENROUTER_API_KEY',
  'deepseek': 'DEEPSEEK_API_KEY',
};
