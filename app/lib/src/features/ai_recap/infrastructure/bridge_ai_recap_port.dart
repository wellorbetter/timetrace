import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Small seam around generated FRB methods so mapping is testable without FFI.
abstract interface class AiRecapBridgeApi {
  wire.AiRecapStatusDto status();

  wire.AiRecapDto? latest({
    required String scope,
    required String start,
    required String end,
  });

  Future<wire.AiRecapGenerateReplyDto> generate({
    required String scope,
    required String start,
    required String end,
    required String model,
  });
}

/// Production generated-API adapter.
class TimeTraceAiRecapBridgeApi implements AiRecapBridgeApi {
  const TimeTraceAiRecapBridgeApi(this._api);

  final TimeTraceApi _api;

  @override
  wire.AiRecapStatusDto status() => _api.aiRecapStatus();

  @override
  wire.AiRecapDto? latest({
    required String scope,
    required String start,
    required String end,
  }) => _api.getLatestAiRecap(scope: scope, start: start, end: end);

  @override
  Future<wire.AiRecapGenerateReplyDto> generate({
    required String scope,
    required String start,
    required String end,
    required String model,
  }) =>
      _api.generateAiRecap(scope: scope, start: start, end: end, model: model);
}

/// Maps the generated bridge contract into the UI's closed local model.
class BridgeAiRecapPort implements AiRecapPort {
  const BridgeAiRecapPort(this._api);

  final AiRecapBridgeApi _api;

  @override
  AiRecapProviderStatus status() {
    try {
      final value = _api.status();
      return AiRecapProviderStatus(
        configured: value.configured,
        providerName: value.provider,
        defaultModel: AiRecapModel.fromId(value.defaultModel),
      );
    } catch (_) {
      return const AiRecapProviderStatus.unavailable();
    }
  }

  @override
  AiRecapResult? latest(AiRecapRangeKey key) {
    try {
      final value = _api.latest(
        scope: key.scope.id,
        start: _isoDate(key.startDate),
        end: _isoDate(key.endDate),
      );
      return value == null ? null : _mapRecap(value, expectedKey: key);
    } on AiRecapFailure {
      rethrow;
    } catch (_) {
      throw const AiRecapFailure(
        code: AiRecapFailureCode.bridgeUnavailable,
        retryable: true,
      );
    }
  }

  @override
  Future<AiRecapResult> generate(
    AiRecapRangeKey key,
    AiRecapModel model,
  ) async {
    try {
      final reply = await _api.generate(
        scope: key.scope.id,
        start: _isoDate(key.startDate),
        end: _isoDate(key.endDate),
        model: model.id,
      );
      final recap = reply.recap;
      final error = reply.error;
      if ((recap == null) == (error == null)) {
        throw const AiRecapFailure(
          code: AiRecapFailureCode.invalidResponse,
          retryable: true,
        );
      }
      if (error != null) throw _mapFailure(error);
      return _mapRecap(recap!, expectedKey: key);
    } on AiRecapFailure {
      rethrow;
    } catch (_) {
      throw const AiRecapFailure(
        code: AiRecapFailureCode.bridgeUnavailable,
        retryable: true,
      );
    }
  }
}

AiRecapResult _mapRecap(
  wire.AiRecapDto value, {
  required AiRecapRangeKey expectedKey,
}) {
  try {
    final key = AiRecapRangeKey.fromIsoDates(
      value.startDate,
      value.endDate,
      scope: AiRecapScope.fromId(value.scope),
    );
    final generatedAt = DateTime.parse(value.generatedAtUtc).toUtc();
    if (key != expectedKey || !key.isValid) {
      throw const FormatException('Mismatched recap range');
    }
    return AiRecapResult(
      rangeKey: key,
      generatedAt: generatedAt,
      model: AiRecapModel.fromId(value.model),
      summary: _mapStatement(value.summary),
      highlights: List.unmodifiable(value.highlights.map(_mapStatement)),
      suggestions: List.unmodifiable(value.suggestions.map(_mapStatement)),
      totalActiveSeconds: (value.totalActiveSeconds as num).toInt(),
      applicationCount: (value.applicationCount as num).toInt(),
    );
  } catch (_) {
    throw const AiRecapFailure(
      code: AiRecapFailureCode.invalidResponse,
      retryable: true,
    );
  }
}

AiRecapStatement _mapStatement(wire.AiRecapStatementDto value) {
  if (value.text.trim().isEmpty ||
      value.evidence.isEmpty ||
      value.evidence.length > 3) {
    throw const AiRecapFailure(
      code: AiRecapFailureCode.invalidResponse,
      retryable: true,
    );
  }
  final evidence = value.evidence.map((item) {
    final seconds = (item.activeSeconds as num).toInt();
    if (item.appName.trim().isEmpty || seconds <= 0) {
      throw const AiRecapFailure(
        code: AiRecapFailureCode.invalidResponse,
        retryable: true,
      );
    }
    return AiRecapEvidence(appName: item.appName, activeSeconds: seconds);
  });
  return AiRecapStatement(
    text: value.text,
    evidence: List.unmodifiable(evidence),
  );
}

AiRecapFailure _mapFailure(wire.AiRecapErrorDto value) {
  final code = switch (value.code) {
    'not_configured' => AiRecapFailureCode.notConfigured,
    'invalid_range' => AiRecapFailureCode.invalidRange,
    'unsupported_model' => AiRecapFailureCode.unsupportedModel,
    'no_usage_data' => AiRecapFailureCode.noUsageData,
    'request_too_large' => AiRecapFailureCode.requestTooLarge,
    'network' => AiRecapFailureCode.network,
    'timeout' => AiRecapFailureCode.timeout,
    'authentication' => AiRecapFailureCode.authentication,
    'rate_limited' => AiRecapFailureCode.rateLimited,
    'provider_unavailable' => AiRecapFailureCode.providerUnavailable,
    'invalid_response' => AiRecapFailureCode.invalidResponse,
    'busy' => AiRecapFailureCode.busy,
    _ => AiRecapFailureCode.bridgeUnavailable,
  };
  return AiRecapFailure(code: code, retryable: value.retryable);
}

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
