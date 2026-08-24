import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Small seam around generated FRB credential methods for deterministic tests.
abstract interface class AiCredentialBridgeApi {
  wire.AiRecapStatusDto status();

  Future<wire.AiRecapSettingsReplyDto> saveApiKey(String apiKey);

  Future<wire.AiRecapSettingsReplyDto> removeApiKey();

  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey();

  Future<wire.AiRecapSettingsReplyDto> setDefaultModel(String model);

  Future<wire.AiRecapConnectionReplyDto> testConnection();
}

class TimeTraceAiCredentialBridgeApi implements AiCredentialBridgeApi {
  const TimeTraceAiCredentialBridgeApi(this._api);

  final TimeTraceApi _api;

  @override
  wire.AiRecapStatusDto status() => _api.aiRecapStatus();

  @override
  Future<wire.AiRecapSettingsReplyDto> saveApiKey(String apiKey) =>
      _api.saveAiRecapApiKey(apiKey: apiKey);

  @override
  Future<wire.AiRecapSettingsReplyDto> removeApiKey() =>
      _api.deleteAiRecapApiKey();

  @override
  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey() =>
      _api.importAiRecapEnvironmentKey();

  @override
  Future<wire.AiRecapSettingsReplyDto> setDefaultModel(String model) =>
      _api.setAiRecapDefaultModel(model: model);

  @override
  Future<wire.AiRecapConnectionReplyDto> testConnection() =>
      _api.testAiRecapConnection();
}

class BridgeAiCredentialPort implements AiCredentialPort {
  const BridgeAiCredentialPort(this._api);

  final AiCredentialBridgeApi _api;

  @override
  AiRecapProviderStatus status() {
    try {
      return _mapStatus(_api.status());
    } catch (_) {
      return const AiRecapProviderStatus.unavailable();
    }
  }

  @override
  Future<AiRecapProviderStatus> saveApiKey(String apiKey) =>
      _settingsMutation(() => _api.saveApiKey(apiKey));

  @override
  Future<AiRecapProviderStatus> removeApiKey() =>
      _settingsMutation(_api.removeApiKey);

  @override
  Future<AiRecapProviderStatus> importEnvironmentApiKey() =>
      _settingsMutation(_api.importEnvironmentApiKey);

  @override
  Future<AiRecapProviderStatus> setDefaultModel(AiRecapModel model) =>
      _settingsMutation(() => _api.setDefaultModel(model.id));

  @override
  Future<void> testConnection() async {
    try {
      final reply = await _api.testConnection();
      final error = reply.error;
      if (reply.success && error == null) return;
      if (!reply.success && error != null) throw _mapFailure(error);
      throw const AiCredentialFailure(AiCredentialFailureCode.invalidResponse);
    } on AiCredentialFailure {
      rethrow;
    } catch (_) {
      throw const AiCredentialFailure(
        AiCredentialFailureCode.bridgeUnavailable,
      );
    }
  }

  Future<AiRecapProviderStatus> _settingsMutation(
    Future<wire.AiRecapSettingsReplyDto> Function() action,
  ) async {
    try {
      final reply = await action();
      final status = _mapStatus(reply.status);
      final error = reply.error;
      if (error != null) throw _mapFailure(error);
      return status;
    } on AiCredentialFailure {
      rethrow;
    } catch (_) {
      throw const AiCredentialFailure(
        AiCredentialFailureCode.bridgeUnavailable,
      );
    }
  }
}

AiRecapProviderStatus _mapStatus(wire.AiRecapStatusDto value) {
  final provider = value.provider.trim();
  if (provider.isEmpty) throw const FormatException('Missing provider');

  final source = switch (value.credentialSource) {
    'secure_store' => AiCredentialSource.secureStore,
    'legacy_environment' => AiCredentialSource.legacyEnvironment,
    'none' => AiCredentialSource.none,
    'unavailable' => AiCredentialSource.unavailable,
    _ => throw const FormatException('Unknown credential source'),
  };
  final sourceIsConfigured =
      source == AiCredentialSource.secureStore ||
      source == AiCredentialSource.legacyEnvironment;
  if (value.configured != sourceIsConfigured) {
    throw const FormatException('Inconsistent credential status');
  }
  if (value.serviceAvailable !=
      (source != AiCredentialSource.unavailable)) {
    throw const FormatException('Inconsistent service status');
  }
  if (value.environmentMigrationAvailable &&
      (source != AiCredentialSource.legacyEnvironment ||
          !value.secureStorageAvailable)) {
    throw const FormatException('Inconsistent migration status');
  }

  return AiRecapProviderStatus(
    configured: value.configured,
    serviceAvailable: value.serviceAvailable,
    providerName: provider,
    defaultModel: AiRecapModel.fromId(value.defaultModel),
    credentialSource: source,
    secureStorageAvailable: value.secureStorageAvailable,
    environmentMigrationAvailable: value.environmentMigrationAvailable,
  );
}

AiCredentialFailure _mapFailure(wire.AiRecapErrorDto value) {
  final code = switch (value.code) {
    'not_configured' => AiCredentialFailureCode.notConfigured,
    'invalid_api_key' => AiCredentialFailureCode.invalidKey,
    'unsupported_model' => AiCredentialFailureCode.unsupportedModel,
    'credential_store' => AiCredentialFailureCode.secureStorageUnavailable,
    'local_storage' => AiCredentialFailureCode.localStorageUnavailable,
    'authentication' => AiCredentialFailureCode.authentication,
    'network' => AiCredentialFailureCode.network,
    'timeout' => AiCredentialFailureCode.timeout,
    'rate_limited' => AiCredentialFailureCode.rateLimited,
    'provider_unavailable' => AiCredentialFailureCode.providerUnavailable,
    'invalid_response' => AiCredentialFailureCode.invalidResponse,
    'busy' => AiCredentialFailureCode.busy,
    _ => AiCredentialFailureCode.bridgeUnavailable,
  };
  return AiCredentialFailure(code);
}
