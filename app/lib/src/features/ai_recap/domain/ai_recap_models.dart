import 'package:flutter/foundation.dart';

/// Exact local-calendar bounds used to identify one recap.
///
/// Time-of-day information is deliberately discarded. Logical scope remains
/// part of identity so "today" and "week to date" do not collide on Monday.
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
      AiRecapScope.today => _sameDate(startDate, endDate),
      AiRecapScope.weekToDate =>
        startDate.weekday == DateTime.monday &&
            endDate.difference(startDate).inDays <= 6,
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

/// Logical recap scope kept separate even when two scopes share date bounds.
enum AiRecapScope {
  today('today'),
  weekToDate('week_to_date'),
  unsupported('unsupported');

  const AiRecapScope(this.id);

  final String id;

  bool get isSupported => this != unsupported;

  static AiRecapScope fromId(String value) => switch (value) {
    'today' => today,
    'week_to_date' => weekToDate,
    _ => throw const FormatException('Unsupported AI recap scope'),
  };
}

/// DeepSeek models intentionally exposed by the built-in recap feature.
enum AiRecapModel {
  flash('deepseek-v4-flash', 'Flash', '响应更快，适合日常回顾'),
  pro('deepseek-v4-pro', 'Pro', '分析更深入，生成时间稍长');

  const AiRecapModel(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static AiRecapModel fromId(String value) => switch (value) {
    'deepseek-v4-flash' => flash,
    'deepseek-v4-pro' => pro,
    _ => throw FormatException('Unsupported AI recap model'),
  };
}

/// Redacted local provider status. It never contains credential material.
@immutable
class AiRecapProviderStatus {
  const AiRecapProviderStatus({
    required this.configured,
    this.serviceAvailable = true,
    this.providerName = 'DeepSeek',
    this.defaultModel = AiRecapModel.flash,
  });

  const AiRecapProviderStatus.unconfigured()
    : configured = false,
      serviceAvailable = true,
      providerName = 'DeepSeek',
      defaultModel = AiRecapModel.flash;

  const AiRecapProviderStatus.unavailable()
    : configured = false,
      serviceAvailable = false,
      providerName = 'DeepSeek',
      defaultModel = AiRecapModel.flash;

  final bool configured;
  final bool serviceAvailable;
  final String providerName;
  final AiRecapModel defaultModel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiRecapProviderStatus &&
          configured == other.configured &&
          serviceAvailable == other.serviceAvailable &&
          providerName == other.providerName &&
          defaultModel == other.defaultModel;

  @override
  int get hashCode =>
      Object.hash(configured, serviceAvailable, providerName, defaultModel);
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
  });

  final AiRecapRangeKey rangeKey;
  final DateTime generatedAt;
  final AiRecapModel model;
  final AiRecapStatement summary;
  final List<AiRecapStatement> highlights;
  final List<AiRecapStatement> suggestions;
  final int totalActiveSeconds;
  final int applicationCount;
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
  unsupportedModel,
  noUsageData,
  requestTooLarge,
  network,
  timeout,
  authentication,
  rateLimited,
  providerUnavailable,
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
