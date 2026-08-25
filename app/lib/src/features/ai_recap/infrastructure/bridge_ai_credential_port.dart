import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Small seam around generated FRB credential methods for deterministic tests.
abstract interface class AiCredentialBridgeApi {
  wire.AiRecapStatusDto status();

  Future<wire.AiRecapSettingsReplyDto> saveApiKey({
    required String providerId,
    required String apiKey,
  });

  Future<wire.AiRecapSettingsReplyDto> removeApiKey(String providerId);

  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey(
    String providerId,
  );

  Future<wire.AiRecapSettingsReplyDto> setProviderSelection({
    required String providerId,
    required String modelId,
  });

  Future<wire.AiRecapConnectionReplyDto> testConnection();
}

class TimeTraceAiCredentialBridgeApi implements AiCredentialBridgeApi {
  const TimeTraceAiCredentialBridgeApi(this._api);

  final TimeTraceApi _api;

  @override
  wire.AiRecapStatusDto status() => _api.aiRecapStatus();

  @override
  Future<wire.AiRecapSettingsReplyDto> saveApiKey({
    required String providerId,
    required String apiKey,
  }) => _api.saveAiRecapApiKey(providerId: providerId, apiKey: apiKey);

  @override
  Future<wire.AiRecapSettingsReplyDto> removeApiKey(String providerId) =>
      _api.deleteAiRecapApiKey(providerId: providerId);

  @override
  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey(
    String providerId,
  ) => _api.importAiRecapEnvironmentKey(providerId: providerId);

  @override
  Future<wire.AiRecapSettingsReplyDto> setProviderSelection({
    required String providerId,
    required String modelId,
  }) => _api.setAiRecapProviderSelection(
    providerId: providerId,
    modelId: modelId,
  );

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
      return mapAiRecapStatus(_api.status());
    } catch (_) {
      return const AiRecapProviderStatus.unavailable();
    }
  }

  @override
  Future<AiRecapProviderStatus> saveApiKey(
    String apiKey, {
    AiRecapProviderId? provider,
  }) {
    final providerId = _credentialProvider(provider);
    return _settingsMutation(
      () => _api.saveApiKey(providerId: providerId.id, apiKey: apiKey),
    );
  }

  @override
  Future<AiRecapProviderStatus> removeApiKey({AiRecapProviderId? provider}) {
    final providerId = _credentialProvider(provider);
    return _settingsMutation(() => _api.removeApiKey(providerId.id));
  }

  @override
  Future<AiRecapProviderStatus> importEnvironmentApiKey({
    AiRecapProviderId? provider,
  }) {
    final providerId = _credentialProvider(provider);
    return _settingsMutation(() => _api.importEnvironmentApiKey(providerId.id));
  }

  @override
  Future<AiRecapProviderStatus> setProviderSelection(
    AiRecapProviderId provider,
    AiRecapModel model,
  ) {
    if (model.providerId != provider) {
      return Future<AiRecapProviderStatus>.error(
        const AiCredentialFailure(AiCredentialFailureCode.unsupportedModel),
      );
    }
    return _settingsMutation(
      () =>
          _api.setProviderSelection(providerId: provider.id, modelId: model.id),
    );
  }

  @override
  Future<AiRecapProviderStatus> setDefaultModel(AiRecapModel model) =>
      setProviderSelection(model.providerId, model);

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
      final status = mapAiRecapStatus(reply.status);
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

  AiRecapProviderId _credentialProvider(AiRecapProviderId? provider) {
    final selected = provider ?? status().selectedProvider;
    if (selected != AiRecapProviderId.deepSeek) {
      throw const AiCredentialFailure(
        AiCredentialFailureCode.unsupportedProvider,
      );
    }
    return selected;
  }
}

AiRecapProviderStatus mapAiRecapStatus(wire.AiRecapStatusDto value) {
  final source = switch (value.credentialSource) {
    'secure_store' => AiCredentialSource.secureStore,
    'legacy_environment' => AiCredentialSource.legacyEnvironment,
    'none' => AiCredentialSource.none,
    'not_required' => AiCredentialSource.notRequired,
    'unavailable' => AiCredentialSource.unavailable,
    _ => throw const FormatException('Unknown credential source'),
  };

  final providers = value.providers.map(_mapProvider).toList(growable: false);
  if (providers.length != AiRecapProviderId.values.length ||
      providers.map((provider) => provider.id).toSet().length !=
          providers.length) {
    throw const FormatException('Invalid provider catalog');
  }
  final selectedProvider = AiRecapProviderId.fromId(value.selectedProviderId);
  final selectedModel = AiRecapModel.fromId(value.selectedModelId);
  final selectedOption = providers.singleWhere(
    (provider) => provider.id == selectedProvider,
  );
  if (selectedModel.providerId != selectedProvider ||
      selectedOption.modelOption(selectedModel) == null) {
    throw const FormatException('Incompatible provider model');
  }

  final credentialReady =
      source == AiCredentialSource.secureStore ||
      source == AiCredentialSource.legacyEnvironment;
  if (value.serviceAvailable) {
    if (selectedOption.requiresApiKey) {
      if (source == AiCredentialSource.notRequired ||
          value.ready != credentialReady) {
        throw const FormatException('Inconsistent credential status');
      }
    } else if (source != AiCredentialSource.notRequired || !value.ready) {
      throw const FormatException('Inconsistent local provider status');
    }
  } else if (value.ready || source != AiCredentialSource.unavailable) {
    throw const FormatException('Invalid unavailable service status');
  }
  final migrationAvailable =
      source == AiCredentialSource.legacyEnvironment &&
      value.secureStorageAvailable;
  if (value.environmentMigrationAvailable != migrationAvailable) {
    throw const FormatException('Inconsistent migration status');
  }

  return AiRecapProviderStatus(
    serviceAvailable: value.serviceAvailable,
    ready: value.ready,
    selectedProvider: selectedProvider,
    selectedModel: selectedModel,
    providers: List.unmodifiable(providers),
    credentialSource: source,
    secureStorageAvailable: value.secureStorageAvailable,
    environmentMigrationAvailable: value.environmentMigrationAvailable,
  );
}

AiRecapProviderOption _mapProvider(wire.AiProviderOptionDto value) {
  final provider = AiRecapProviderId.fromId(value.id);
  final models = value.models
      .map((item) {
        final model = AiRecapModel.fromId(item.id);
        if (model.providerId != provider || item.displayName.trim().isEmpty) {
          throw const FormatException('Invalid model option');
        }
        return AiRecapModelOption(
          model: model,
          displayName: item.displayName.trim(),
          costTier: AiRecapCostTier.fromId(item.costTier),
        );
      })
      .toList(growable: false);
  if (value.displayName.trim().isEmpty ||
      value.description.trim().isEmpty ||
      models.isEmpty ||
      models.map((model) => model.model).toSet().length != models.length) {
    throw const FormatException('Invalid provider option');
  }
  if ((provider == AiRecapProviderId.localSummary &&
          (value.requiresApiKey || value.supportsConnectionTest)) ||
      (provider == AiRecapProviderId.deepSeek &&
          (!value.requiresApiKey || !value.supportsConnectionTest))) {
    throw const FormatException('Invalid provider capabilities');
  }
  final expectedModels = switch (provider) {
    AiRecapProviderId.localSummary => {AiRecapModel.localSummary},
    AiRecapProviderId.deepSeek => {AiRecapModel.flash, AiRecapModel.pro},
  };
  if (models.length != expectedModels.length ||
      !models.every(
        (option) =>
            expectedModels.contains(option.model) &&
            option.costTier ==
                (provider == AiRecapProviderId.localSummary
                    ? AiRecapCostTier.freeLocal
                    : AiRecapCostTier.paidCloud),
      )) {
    throw const FormatException('Incomplete provider model catalog');
  }
  return AiRecapProviderOption(
    id: provider,
    displayName: value.displayName.trim(),
    description: value.description.trim(),
    requiresApiKey: value.requiresApiKey,
    supportsConnectionTest: value.supportsConnectionTest,
    models: List.unmodifiable(models),
  );
}

AiCredentialFailure _mapFailure(wire.AiRecapErrorDto value) {
  final code = switch (value.code) {
    'not_configured' => AiCredentialFailureCode.notConfigured,
    'invalid_api_key' => AiCredentialFailureCode.invalidKey,
    'unsupported_provider' => AiCredentialFailureCode.unsupportedProvider,
    'unsupported_model' => AiCredentialFailureCode.unsupportedModel,
    'provider_not_ready' => AiCredentialFailureCode.providerNotReady,
    'connection_test_not_supported' =>
      AiCredentialFailureCode.connectionTestNotSupported,
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
