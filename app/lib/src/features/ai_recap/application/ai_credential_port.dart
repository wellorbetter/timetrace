import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// A deliberately narrow boundary for report-provider selection and secrets.
///
/// Implementations must never return, log, or otherwise expose credential
/// material. The only observable credential information is the redacted
/// [AiRecapProviderStatus].
abstract interface class AiCredentialPort {
  AiRecapProviderStatus status();

  Future<AiRecapProviderStatus> saveApiKey(
    String apiKey, {
    AiRecapProviderId? provider,
  });

  Future<AiRecapProviderStatus> removeApiKey({AiRecapProviderId? provider});

  Future<AiRecapProviderStatus> importEnvironmentApiKey({
    AiRecapProviderId? provider,
  });

  Future<AiRecapProviderStatus> setProviderSelection(
    AiRecapProviderId provider,
    AiRecapModel model,
  );

  /// Compatibility entry point that selects the provider owning [model].
  Future<AiRecapProviderStatus> setDefaultModel(AiRecapModel model);

  /// Tests only provider authentication and availability.
  ///
  /// This operation deliberately accepts no usage-data argument, so callers
  /// cannot accidentally include recorded applications or durations.
  Future<void> testConnection();
}

enum AiCredentialFailureCode {
  notConfigured,
  invalidKey,
  unsupportedProvider,
  unsupportedModel,
  providerNotReady,
  connectionTestNotSupported,
  secureStorageUnavailable,
  localStorageUnavailable,
  authentication,
  network,
  timeout,
  rateLimited,
  providerUnavailable,
  invalidResponse,
  busy,
  bridgeUnavailable,
}

class AiCredentialFailure implements Exception {
  const AiCredentialFailure(this.code);

  final AiCredentialFailureCode code;

  @override
  String toString() => 'AiCredentialFailure(${code.name})';
}

/// Safe fallback used until a platform bridge implementation is available.
class UnavailableAiCredentialPort implements AiCredentialPort {
  const UnavailableAiCredentialPort();

  @override
  AiRecapProviderStatus status() => const AiRecapProviderStatus.unavailable();

  @override
  Future<AiRecapProviderStatus> importEnvironmentApiKey({
    AiRecapProviderId? provider,
  }) => _unavailable();

  @override
  Future<AiRecapProviderStatus> removeApiKey({AiRecapProviderId? provider}) =>
      _unavailable();

  @override
  Future<AiRecapProviderStatus> saveApiKey(
    String apiKey, {
    AiRecapProviderId? provider,
  }) => _unavailable();

  @override
  Future<AiRecapProviderStatus> setProviderSelection(
    AiRecapProviderId provider,
    AiRecapModel model,
  ) => _unavailable();

  @override
  Future<AiRecapProviderStatus> setDefaultModel(AiRecapModel model) =>
      _unavailable();

  @override
  Future<void> testConnection() => Future<void>.error(
    const AiCredentialFailure(AiCredentialFailureCode.bridgeUnavailable),
  );

  Future<AiRecapProviderStatus> _unavailable() =>
      Future<AiRecapProviderStatus>.error(
        const AiCredentialFailure(AiCredentialFailureCode.bridgeUnavailable),
      );
}
