import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_credential_port.dart';

void main() {
  test('maps the free local provider as ready without credentials', () {
    final status = BridgeAiCredentialPort(
      _FakeCredentialBridgeApi(statusValue: _localStatus),
    ).status();

    expect(status.serviceAvailable, isTrue);
    expect(status.ready, isTrue);
    expect(status.selectedProvider, AiRecapProviderId.localSummary);
    expect(status.selectedModel, AiRecapModel.localSummary);
    expect(status.credentialSource, AiCredentialSource.notRequired);
    expect(status.requiresApiKey, isFalse);
    expect(status.supportsConnectionTest, isFalse);
    expect(status.providers, hasLength(2));
    expect(
      status.providers.first.models.single.costTier,
      AiRecapCostTier.freeLocal,
    );
  });

  test('maps every redacted DeepSeek credential source', () {
    final cases = <String, (bool, bool, bool, AiCredentialSource)>{
      'secure_store': (true, true, false, AiCredentialSource.secureStore),
      'legacy_environment': (
        true,
        true,
        true,
        AiCredentialSource.legacyEnvironment,
      ),
      'none': (false, true, false, AiCredentialSource.none),
      'unavailable': (false, false, false, AiCredentialSource.unavailable),
    };

    for (final entry in cases.entries) {
      final (ready, secure, migration, expectedSource) = entry.value;
      final status = BridgeAiCredentialPort(
        _FakeCredentialBridgeApi(
          statusValue: _deepSeekStatus(
            ready: ready,
            source: entry.key,
            secureStorageAvailable: secure,
            migrationAvailable: migration,
          ),
        ),
      ).status();

      expect(status.credentialSource, expectedSource);
      expect(status.ready, ready);
      expect(status.serviceAvailable, isTrue);
      expect(status.selectedProvider, AiRecapProviderId.deepSeek);
      expect(status.selectedModel, AiRecapModel.flash);
      expect(status.requiresApiKey, isTrue);
      expect(status.supportsConnectionTest, isTrue);
    }
  });

  test('forwards provider-scoped mutations and atomic selection', () async {
    final api = _FakeCredentialBridgeApi(
      statusValue: _deepSeekStatus(
        ready: true,
        source: 'secure_store',
        model: AiRecapModel.pro.id,
      ),
    );
    final port = BridgeAiCredentialPort(api);

    await port.saveApiKey('secret-value', provider: AiRecapProviderId.deepSeek);
    await port.removeApiKey(provider: AiRecapProviderId.deepSeek);
    await port.importEnvironmentApiKey(provider: AiRecapProviderId.deepSeek);
    final status = await port.setProviderSelection(
      AiRecapProviderId.deepSeek,
      AiRecapModel.pro,
    );

    expect(api.credentialProviderIds, [
      AiRecapProviderId.deepSeek.id,
      AiRecapProviderId.deepSeek.id,
      AiRecapProviderId.deepSeek.id,
    ]);
    expect(api.savedApiKey, 'secret-value');
    expect(api.savedProvider, AiRecapProviderId.deepSeek.id);
    expect(api.savedModel, AiRecapModel.pro.id);
    expect(status.selectedModel, AiRecapModel.pro);
  });

  test('rejects credentials for local and incompatible provider models', () {
    final port = BridgeAiCredentialPort(
      _FakeCredentialBridgeApi(statusValue: _localStatus),
    );

    expect(
      () => port.saveApiKey(
        'secret-value',
        provider: AiRecapProviderId.localSummary,
      ),
      throwsA(
        isA<AiCredentialFailure>().having(
          (failure) => failure.code,
          'code',
          AiCredentialFailureCode.unsupportedProvider,
        ),
      ),
    );
    expect(
      port.setProviderSelection(
        AiRecapProviderId.localSummary,
        AiRecapModel.flash,
      ),
      throwsA(
        isA<AiCredentialFailure>().having(
          (failure) => failure.code,
          'code',
          AiCredentialFailureCode.unsupportedModel,
        ),
      ),
    );
  });

  test('maps all credential-relevant stable wire errors', () async {
    for (final entry in _errorCodes.entries) {
      final port = BridgeAiCredentialPort(
        _FakeCredentialBridgeApi(
          settingsError: wire.AiRecapErrorDto(code: entry.key, retryable: true),
        ),
      );

      await expectLater(
        port.saveApiKey('secret-value', provider: AiRecapProviderId.deepSeek),
        throwsA(
          isA<AiCredentialFailure>().having(
            (failure) => failure.code,
            'code',
            entry.value,
          ),
        ),
      );
    }
  });

  test(
    'accepts only a mutually exclusive successful connection reply',
    () async {
      final success = BridgeAiCredentialPort(_FakeCredentialBridgeApi());
      await expectLater(success.testConnection(), completes);

      final authentication = BridgeAiCredentialPort(
        _FakeCredentialBridgeApi(
          connectionReply: const wire.AiRecapConnectionReplyDto(
            success: false,
            error: wire.AiRecapErrorDto(
              code: 'authentication',
              retryable: false,
            ),
          ),
        ),
      );
      await expectLater(
        authentication.testConnection(),
        throwsA(
          isA<AiCredentialFailure>().having(
            (failure) => failure.code,
            'code',
            AiCredentialFailureCode.authentication,
          ),
        ),
      );

      for (final malformed in [
        const wire.AiRecapConnectionReplyDto(success: false),
        const wire.AiRecapConnectionReplyDto(
          success: true,
          error: wire.AiRecapErrorDto(code: 'network', retryable: true),
        ),
      ]) {
        final port = BridgeAiCredentialPort(
          _FakeCredentialBridgeApi(connectionReply: malformed),
        );
        await expectLater(
          port.testConnection(),
          throwsA(
            isA<AiCredentialFailure>().having(
              (failure) => failure.code,
              'code',
              AiCredentialFailureCode.invalidResponse,
            ),
          ),
        );
      }
    },
  );

  test('fails closed for malformed status and raw bridge exceptions', () async {
    final malformed = BridgeAiCredentialPort(
      _FakeCredentialBridgeApi(
        statusValue: wire.AiRecapStatusDto(
          serviceAvailable: true,
          ready: true,
          selectedProviderId: AiRecapProviderId.localSummary.id,
          selectedModelId: AiRecapModel.flash.id,
          providers: _wireProviders,
          credentialSource: 'not_required',
          secureStorageAvailable: false,
          environmentMigrationAvailable: false,
        ),
      ),
    );
    expect(malformed.status(), const AiRecapProviderStatus.unavailable());

    final throwing = BridgeAiCredentialPort(
      _FakeCredentialBridgeApi(throwOnMutation: true),
    );
    try {
      await throwing.saveApiKey(
        'secret-value',
        provider: AiRecapProviderId.deepSeek,
      );
      fail('expected a redacted failure');
    } on AiCredentialFailure catch (failure) {
      expect(failure.code, AiCredentialFailureCode.bridgeUnavailable);
      expect(failure.toString(), isNot(contains('secret-value')));
      expect(failure.toString(), isNot(contains('raw-provider-body')));
    }
  });
}

const Map<String, AiCredentialFailureCode> _errorCodes = {
  'not_configured': AiCredentialFailureCode.notConfigured,
  'invalid_api_key': AiCredentialFailureCode.invalidKey,
  'unsupported_provider': AiCredentialFailureCode.unsupportedProvider,
  'unsupported_model': AiCredentialFailureCode.unsupportedModel,
  'provider_not_ready': AiCredentialFailureCode.providerNotReady,
  'connection_test_not_supported':
      AiCredentialFailureCode.connectionTestNotSupported,
  'credential_store': AiCredentialFailureCode.secureStorageUnavailable,
  'local_storage': AiCredentialFailureCode.localStorageUnavailable,
  'authentication': AiCredentialFailureCode.authentication,
  'network': AiCredentialFailureCode.network,
  'timeout': AiCredentialFailureCode.timeout,
  'rate_limited': AiCredentialFailureCode.rateLimited,
  'provider_unavailable': AiCredentialFailureCode.providerUnavailable,
  'invalid_response': AiCredentialFailureCode.invalidResponse,
  'busy': AiCredentialFailureCode.busy,
  'future_unknown_code': AiCredentialFailureCode.bridgeUnavailable,
};

const List<wire.AiProviderOptionDto> _wireProviders = [
  wire.AiProviderOptionDto(
    id: 'local_summary',
    displayName: '本地总结（免费）',
    description: '使用本机聚合统计生成固定结构报告，数据不离开设备。',
    requiresApiKey: false,
    supportsConnectionTest: false,
    models: [
      wire.AiModelOptionDto(
        id: 'local-summary-v1',
        displayName: '本地总结 v1',
        costTier: 'free_local',
      ),
    ],
  ),
  wire.AiProviderOptionDto(
    id: 'deepseek',
    displayName: 'DeepSeek',
    description: '生成时发送应用名与聚合时长，使用你的 API Key，可能产生费用。',
    requiresApiKey: true,
    supportsConnectionTest: true,
    models: [
      wire.AiModelOptionDto(
        id: 'deepseek-v4-flash',
        displayName: 'DeepSeek Flash',
        costTier: 'paid_cloud',
      ),
      wire.AiModelOptionDto(
        id: 'deepseek-v4-pro',
        displayName: 'DeepSeek Pro',
        costTier: 'paid_cloud',
      ),
    ],
  ),
];

const wire.AiRecapStatusDto _localStatus = wire.AiRecapStatusDto(
  serviceAvailable: true,
  ready: true,
  selectedProviderId: 'local_summary',
  selectedModelId: 'local-summary-v1',
  providers: _wireProviders,
  credentialSource: 'not_required',
  secureStorageAvailable: false,
  environmentMigrationAvailable: false,
);

wire.AiRecapStatusDto _deepSeekStatus({
  bool ready = true,
  String source = 'secure_store',
  bool secureStorageAvailable = true,
  bool migrationAvailable = false,
  String model = 'deepseek-v4-flash',
}) => wire.AiRecapStatusDto(
  serviceAvailable: true,
  ready: ready,
  selectedProviderId: 'deepseek',
  selectedModelId: model,
  providers: _wireProviders,
  credentialSource: source,
  secureStorageAvailable: secureStorageAvailable,
  environmentMigrationAvailable: migrationAvailable,
);

class _FakeCredentialBridgeApi implements AiCredentialBridgeApi {
  _FakeCredentialBridgeApi({
    wire.AiRecapStatusDto? statusValue,
    this.settingsError,
    this.connectionReply = const wire.AiRecapConnectionReplyDto(success: true),
    this.throwOnMutation = false,
  }) : statusValue = statusValue ?? _deepSeekStatus();

  final wire.AiRecapStatusDto statusValue;
  final wire.AiRecapErrorDto? settingsError;
  final wire.AiRecapConnectionReplyDto connectionReply;
  final bool throwOnMutation;
  final List<String> credentialProviderIds = [];
  String? savedApiKey;
  String? savedProvider;
  String? savedModel;

  @override
  wire.AiRecapStatusDto status() => statusValue;

  @override
  Future<wire.AiRecapSettingsReplyDto> saveApiKey({
    required String providerId,
    required String apiKey,
  }) async {
    if (throwOnMutation) throw StateError('raw-provider-body');
    credentialProviderIds.add(providerId);
    savedApiKey = apiKey;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> removeApiKey(String providerId) async {
    credentialProviderIds.add(providerId);
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey(
    String providerId,
  ) async {
    credentialProviderIds.add(providerId);
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> setProviderSelection({
    required String providerId,
    required String modelId,
  }) async {
    savedProvider = providerId;
    savedModel = modelId;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapConnectionReplyDto> testConnection() async =>
      connectionReply;

  wire.AiRecapSettingsReplyDto _settingsReply() =>
      wire.AiRecapSettingsReplyDto(status: statusValue, error: settingsError);
}
