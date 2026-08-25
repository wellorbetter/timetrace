import 'package:flutter/foundation.dart';

/// Exact local-calendar bounds used to identify one time report.
///
/// Time-of-day information is deliberately discarded. Logical scope remains
/// part of identity so a daily and weekly report do not collide on Monday.
@immutable
class AiRecapRangeKey {
  AiRecapRangeKey({
    required this.scope,
    required DateTime startDate,
    required DateTime endDate,
  }) : startDate = DateTime(startDate.year, startDate.month, startDate.day),
       endDate = DateTime(endDate.year, endDate.month, endDate.day);

  factory AiRecapRangeKey.fromIsoDates(
    String start,
    String end, {
    required AiRecapScope scope,
  }) {
    return AiRecapRangeKey(
      scope: scope,
      startDate: _parseIsoCalendarDate(start),
      endDate: _parseIsoCalendarDate(end),
    );
  }

  final AiRecapScope scope;
  final DateTime startDate;
  final DateTime endDate;

  bool get isValid {
    if (endDate.isBefore(startDate)) return false;
    return switch (scope) {
      AiRecapScope.daily => _sameDate(startDate, endDate),
      AiRecapScope.weekly =>
        startDate.weekday == DateTime.monday &&
            _calendarDayDifference(startDate, endDate) <= 6,
      AiRecapScope.monthly =>
        startDate.day == 1 &&
            startDate.year == endDate.year &&
            startDate.month == endDate.month,
      AiRecapScope.unsupported => false,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapRangeKey &&
          scope == other.scope &&
          _sameDate(startDate, other.startDate) &&
          _sameDate(endDate, other.endDate);

  @override
  int get hashCode => Object.hash(
    scope,
    startDate.year,
    startDate.month,
    startDate.day,
    endDate.year,
    endDate.month,
    endDate.day,
  );

  static bool _sameDate(DateTime left, DateTime right) =>
      left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

/// Closed report type kept separate even when two periods share date bounds.
enum AiRecapScope {
  daily('daily', '日报'),
  weekly('weekly', '周报'),
  monthly('monthly', '月报'),
  unsupported('unsupported');

  const AiRecapScope(this.id, [this.label = '']);

  final String id;
  final String label;

  bool get isSupported => this != unsupported;

  static AiRecapScope fromId(String value) => switch (value) {
    'daily' => daily,
    'weekly' => weekly,
    'monthly' => monthly,
    _ => throw const FormatException('Unsupported AI recap scope'),
  };
}

int _calendarDayDifference(DateTime start, DateTime end) => DateTime.utc(
  end.year,
  end.month,
  end.day,
).difference(DateTime.utc(start.year, start.month, start.day)).inDays;

/// Redacted source of the credential currently used by the native service.
enum AiCredentialSource {
  secureStore,
  legacyEnvironment,
  none,
  notRequired,
  unavailable,
}

/// Closed report-provider identifiers accepted by the native service.
enum AiRecapProviderId {
  localSummary('local_summary'),
  deepSeek('deepseek');

  const AiRecapProviderId(this.id);

  final String id;

  static AiRecapProviderId fromId(String value) => switch (value) {
    'local_summary' => localSummary,
    'deepseek' => deepSeek,
    _ => throw const FormatException('Unsupported AI recap provider'),
  };
}

/// Closed cost/privacy tiers rendered by Settings without guessing from names.
enum AiRecapCostTier {
  freeLocal('free_local'),
  paidCloud('paid_cloud');

  const AiRecapCostTier(this.id);

  final String id;

  static AiRecapCostTier fromId(String value) => switch (value) {
    'free_local' => freeLocal,
    'paid_cloud' => paidCloud,
    _ => throw const FormatException('Unsupported AI recap cost tier'),
  };
}

/// Closed models intentionally exposed by the built-in recap feature.
enum AiRecapModel {
  localSummary(
    'local-summary-v1',
    '本地总结 v1',
    '免费、无需密钥，数据不离开设备',
    AiRecapProviderId.localSummary,
  ),
  flash(
    'deepseek-v4-flash',
    'Flash',
    '响应更快，适合日常回顾',
    AiRecapProviderId.deepSeek,
  ),
  pro('deepseek-v4-pro', 'Pro', '分析更深入，生成时间稍长', AiRecapProviderId.deepSeek);

  const AiRecapModel(this.id, this.label, this.description, this.providerId);

  final String id;
  final String label;
  final String description;
  final AiRecapProviderId providerId;

  static AiRecapModel fromId(String value) => switch (value) {
    'local-summary-v1' => localSummary,
    'deepseek-v4-flash' => flash,
    'deepseek-v4-pro' => pro,
    _ => throw const FormatException('Unsupported AI recap model'),
  };
}

/// One model option from the native closed provider catalog.
@immutable
class AiRecapModelOption {
  const AiRecapModelOption({
    required this.model,
    required this.displayName,
    required this.costTier,
  });

  final AiRecapModel model;
  final String displayName;
  final AiRecapCostTier costTier;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapModelOption &&
          model == other.model &&
          displayName == other.displayName &&
          costTier == other.costTier;

  @override
  int get hashCode => Object.hash(model, displayName, costTier);
}

/// One provider option from the native closed provider catalog.
@immutable
class AiRecapProviderOption {
  const AiRecapProviderOption({
    required this.id,
    required this.displayName,
    required this.description,
    required this.requiresApiKey,
    required this.supportsConnectionTest,
    required this.models,
  });

  final AiRecapProviderId id;
  final String displayName;
  final String description;
  final bool requiresApiKey;
  final bool supportsConnectionTest;
  final List<AiRecapModelOption> models;

  AiRecapModelOption? modelOption(AiRecapModel model) {
    for (final option in models) {
      if (option.model == model) return option;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapProviderOption &&
          id == other.id &&
          displayName == other.displayName &&
          description == other.description &&
          requiresApiKey == other.requiresApiKey &&
          supportsConnectionTest == other.supportsConnectionTest &&
          listEquals(models, other.models);

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    description,
    requiresApiKey,
    supportsConnectionTest,
    Object.hashAll(models),
  );
}

const List<AiRecapProviderOption> defaultAiRecapProviderOptions = [
  AiRecapProviderOption(
    id: AiRecapProviderId.localSummary,
    displayName: '本地总结（免费）',
    description: '使用本机聚合统计生成固定结构报告，数据不离开设备。',
    requiresApiKey: false,
    supportsConnectionTest: false,
    models: [
      AiRecapModelOption(
        model: AiRecapModel.localSummary,
        displayName: '本地总结 v1',
        costTier: AiRecapCostTier.freeLocal,
      ),
    ],
  ),
  AiRecapProviderOption(
    id: AiRecapProviderId.deepSeek,
    displayName: 'DeepSeek',
    description: '生成时发送应用名与聚合时长，使用你的 API Key，可能产生费用。',
    requiresApiKey: true,
    supportsConnectionTest: true,
    models: [
      AiRecapModelOption(
        model: AiRecapModel.flash,
        displayName: 'DeepSeek Flash',
        costTier: AiRecapCostTier.paidCloud,
      ),
      AiRecapModelOption(
        model: AiRecapModel.pro,
        displayName: 'DeepSeek Pro',
        costTier: AiRecapCostTier.paidCloud,
      ),
    ],
  ),
];

/// Redacted local provider status. It never contains credential material.
@immutable
class AiRecapProviderStatus {
  const AiRecapProviderStatus({
    bool? configured,
    bool? ready,
    this.serviceAvailable = true,
    this.selectedProvider = AiRecapProviderId.deepSeek,
    AiRecapModel? selectedModel,
    AiRecapModel? defaultModel,
    this.providers = defaultAiRecapProviderOptions,
    String? providerName,
    this.credentialSource = AiCredentialSource.none,
    this.secureStorageAvailable = true,
    this.environmentMigrationAvailable = false,
  }) : ready = ready ?? configured ?? false,
       selectedModel = selectedModel ?? defaultModel ?? AiRecapModel.flash,
       _legacyProviderName = providerName;

  const AiRecapProviderStatus.unconfigured()
    : ready = false,
      serviceAvailable = true,
      selectedProvider = AiRecapProviderId.deepSeek,
      selectedModel = AiRecapModel.flash,
      providers = defaultAiRecapProviderOptions,
      _legacyProviderName = null,
      credentialSource = AiCredentialSource.none,
      secureStorageAvailable = true,
      environmentMigrationAvailable = false;

  const AiRecapProviderStatus.unavailable()
    : ready = false,
      serviceAvailable = false,
      selectedProvider = AiRecapProviderId.localSummary,
      selectedModel = AiRecapModel.localSummary,
      providers = defaultAiRecapProviderOptions,
      _legacyProviderName = null,
      credentialSource = AiCredentialSource.unavailable,
      secureStorageAvailable = false,
      environmentMigrationAvailable = false;

  final bool serviceAvailable;
  final bool ready;
  final AiRecapProviderId selectedProvider;
  final AiRecapModel selectedModel;
  final List<AiRecapProviderOption> providers;
  final String? _legacyProviderName;
  final AiCredentialSource credentialSource;
  final bool secureStorageAvailable;
  final bool environmentMigrationAvailable;

  /// Compatibility alias for pre-provider UI while it migrates to [ready].
  bool get configured => ready;

  /// Compatibility alias for pre-provider UI while it migrates to selection.
  AiRecapModel get defaultModel => selectedModel;

  AiRecapProviderOption? get selectedProviderOption {
    for (final provider in providers) {
      if (provider.id == selectedProvider) return provider;
    }
    return null;
  }

  String get providerName =>
      selectedProviderOption?.displayName ??
      _legacyProviderName ??
      (selectedProvider == AiRecapProviderId.localSummary
          ? '本地总结（免费）'
          : 'DeepSeek');

  bool get requiresApiKey => selectedProviderOption?.requiresApiKey ?? false;

  bool get supportsConnectionTest =>
      selectedProviderOption?.supportsConnectionTest ?? false;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapProviderStatus &&
          serviceAvailable == other.serviceAvailable &&
          ready == other.ready &&
          selectedProvider == other.selectedProvider &&
          selectedModel == other.selectedModel &&
          listEquals(providers, other.providers) &&
          providerName == other.providerName &&
          credentialSource == other.credentialSource &&
          secureStorageAvailable == other.secureStorageAvailable &&
          environmentMigrationAvailable == other.environmentMigrationAvailable;

  @override
  int get hashCode => Object.hash(
    serviceAvailable,
    ready,
    selectedProvider,
    selectedModel,
    Object.hashAll(providers),
    providerName,
    credentialSource,
    secureStorageAvailable,
    environmentMigrationAvailable,
  );
}

/// One complete, validated recap returned by the native service.
@immutable
class AiRecapResult {
  const AiRecapResult({
    required this.rangeKey,
    required this.generatedAt,
    required this.model,
    required this.summary,
    required this.highlights,
    required this.suggestions,
    required this.totalActiveSeconds,
    required this.applicationCount,
    this.providerId = AiRecapProviderId.deepSeek,
    this.topApplications = const [],
  });

  final AiRecapRangeKey rangeKey;
  final DateTime generatedAt;
  final AiRecapProviderId providerId;
  final AiRecapModel model;
  final AiRecapStatement summary;
  final List<AiRecapStatement> highlights;
  final List<AiRecapStatement> suggestions;
  final int totalActiveSeconds;
  final int applicationCount;
  final List<AiRecapEvidence> topApplications;
}

/// One exact aggregate row cited by a generated statement.
@immutable
class AiRecapEvidence {
  const AiRecapEvidence({required this.appName, required this.activeSeconds});

  final String appName;
  final int activeSeconds;
}

/// Generated interpretation paired with locally verified evidence.
@immutable
class AiRecapStatement {
  const AiRecapStatement({required this.text, required this.evidence});

  final String text;
  final List<AiRecapEvidence> evidence;
}

/// Closed error taxonomy shared by the controller and bridge adapter.
enum AiRecapFailureCode {
  notConfigured,
  invalidRange,
  unsupportedProvider,
  unsupportedModel,
  providerNotReady,
  connectionTestNotSupported,
  noUsageData,
  requestTooLarge,
  network,
  timeout,
  authentication,
  rateLimited,
  providerUnavailable,
  credentialStoreUnavailable,
  localStorageUnavailable,
  invalidResponse,
  busy,
  bridgeUnavailable,
}

/// A redacted, actionable failure. No provider body or user data is retained.
@immutable
class AiRecapFailure implements Exception {
  const AiRecapFailure({required this.code, required this.retryable});

  final AiRecapFailureCode code;
  final bool retryable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapFailure &&
          code == other.code &&
          retryable == other.retryable;

  @override
  int get hashCode => Object.hash(code, retryable);

  @override
  String toString() => 'AiRecapFailure(${code.name}, retryable: $retryable)';
}

final RegExp _isoCalendarDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime _parseIsoCalendarDate(String value) {
  if (!_isoCalendarDate.hasMatch(value)) {
    throw const FormatException('Expected an exact YYYY-MM-DD date');
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  final parsed = DateTime(year, month, day);
  if (parsed.year != year || parsed.month != month || parsed.day != day) {
    throw const FormatException('Invalid calendar date');
  }
  return parsed;
}
