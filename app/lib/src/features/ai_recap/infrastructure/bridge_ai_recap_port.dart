import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_recap_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Small seam around generated FRB methods so mapping is testable without FFI.
abstract interface class AiRecapBridgeApi {
  wire.AiRecapStatusDto status();

  List<wire.AiRecapDto> latestReports();

  Future<wire.AiRecapGenerateReplyDto> generate({
    required String scope,
    required String start,
    required String end,
  });
}

/// Production generated-API adapter.
class TimeTraceAiRecapBridgeApi implements AiRecapBridgeApi {
  const TimeTraceAiRecapBridgeApi(this._api);

  final TimeTraceApi _api;

  @override
  wire.AiRecapStatusDto status() => _api.aiRecapStatus();

  @override
  List<wire.AiRecapDto> latestReports() => _api.getLatestAiReports();

  @override
  Future<wire.AiRecapGenerateReplyDto> generate({
    required String scope,
    required String start,
    required String end,
  }) => _api.generateAiRecap(scope: scope, start: start, end: end);
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
        serviceAvailable: value.serviceAvailable,
        providerName: value.provider,
        defaultModel: AiRecapModel.fromId(value.defaultModel),
        credentialSource: _credentialSource(value.credentialSource),
        secureStorageAvailable: value.secureStorageAvailable,
        environmentMigrationAvailable: value.environmentMigrationAvailable,
      );
    } catch (_) {
      return const AiRecapProviderStatus.unavailable();
    }
  }

  @override
  List<AiRecapResult> latestReports() {
    try {
      final reports = _api
          .latestReports()
          .map(_mapRecap)
          .toList(growable: false);
      if (reports.length > 3 ||
          reports.map((report) => report.rangeKey.scope).toSet().length !=
              reports.length) {
        throw const FormatException('Invalid persisted report set');
      }
      return List.unmodifiable(reports);
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
  Future<AiRecapResult> generate(AiRecapRangeKey key) async {
    try {
      final reply = await _api.generate(
        scope: key.scope.id,
        start: _isoDate(key.startDate),
        end: _isoDate(key.endDate),
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

AiRecapResult _mapRecap(wire.AiRecapDto value, {AiRecapRangeKey? expectedKey}) {
  try {
    final key = AiRecapRangeKey.fromIsoDates(
      value.startDate,
      value.endDate,
      scope: AiRecapScope.fromId(value.scope),
    );
    final generatedAt = DateTime.parse(value.generatedAtUtc).toUtc();
    if (!key.isValid || (expectedKey != null && key != expectedKey)) {
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
      topApplications: List.unmodifiable(
        value.topApplications.map(_mapEvidence),
      ),
    );
  } catch (_) {
    throw const AiRecapFailure(
      code: AiRecapFailureCode.invalidResponse,
      retryable: true,
    );
  }
}

AiRecapEvidence _mapEvidence(wire.AiRecapEvidenceDto value) {
  final seconds = (value.activeSeconds as num).toInt();
  if (value.appName.trim().isEmpty || seconds <= 0) {
    throw const AiRecapFailure(
      code: AiRecapFailureCode.invalidResponse,
      retryable: true,
    );
  }
  return AiRecapEvidence(appName: value.appName, activeSeconds: seconds);
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
    return _mapEvidence(item);
  });
  return AiRecapStatement(
    text: value.text,
    evidence: List.unmodifiable(evidence),
  );
}

AiCredentialSource _credentialSource(String value) => switch (value) {
  'secure_store' => AiCredentialSource.secureStore,
  'legacy_environment' => AiCredentialSource.legacyEnvironment,
  'none' => AiCredentialSource.none,
  'unavailable' => AiCredentialSource.unavailable,
  _ => throw const FormatException('Unknown credential source'),
};

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
    'credential_store' => AiRecapFailureCode.credentialStoreUnavailable,
    'local_storage' => AiRecapFailureCode.localStorageUnavailable,
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
