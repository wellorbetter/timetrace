import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_credential_port.dart';

void main() {
  test('maps every redacted credential source and setting field', () {
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
      final (configured, secure, migration, expectedSource) = entry.value;
      final port = BridgeAiCredentialPort(
        _FakeCredentialBridgeApi(
          statusValue: _status(
            configured: configured,
            source: entry.key,
            secureStorageAvailable: secure,
            migrationAvailable: migration,
          ),
        ),
      );

      final status = port.status();
      expect(status.credentialSource, expectedSource);
      expect(status.configured, configured);
      expect(status.secureStorageAvailable, secure);
      expect(status.environmentMigrationAvailable, migration);
      expect(
        status.serviceAvailable,
        expectedSource != AiCredentialSource.unavailable,
      );
      expect(status.defaultModel, AiRecapModel.flash);
    }
  });

  test('forwards every mutation with only the required value', () async {
    final api = _FakeCredentialBridgeApi(
      statusValue: _status(
        configured: true,
        source: 'secure_store',
        defaultModel: AiRecapModel.pro.id,
      ),
    );
    final port = BridgeAiCredentialPort(api);

    await port.saveApiKey('secret-value');
    await port.removeApiKey();
    await port.importEnvironmentApiKey();
    final status = await port.setDefaultModel(AiRecapModel.pro);

    expect(api.savedApiKey, 'secret-value');
    expect(api.removeCalls, 1);
    expect(api.importCalls, 1);
    expect(api.savedModel, AiRecapModel.pro.id);
    expect(status.defaultModel, AiRecapModel.pro);
  });

  test('maps all credential-relevant stable wire errors', () async {
    for (final entry in _errorCodes.entries) {
      final port = BridgeAiCredentialPort(
        _FakeCredentialBridgeApi(
          settingsError: wire.AiRecapErrorDto(code: entry.key, retryable: true),
        ),
      );

      await expectLater(
        port.saveApiKey('secret-value'),
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
        statusValue: _status(configured: false, source: 'secure_store'),
      ),
    );
    expect(malformed.status(), const AiRecapProviderStatus.unavailable());
    await expectLater(
      malformed.removeApiKey(),
      throwsA(
        isA<AiCredentialFailure>().having(
          (failure) => failure.code,
          'code',
          AiCredentialFailureCode.bridgeUnavailable,
        ),
      ),
    );

    final throwing = BridgeAiCredentialPort(
      _FakeCredentialBridgeApi(throwOnMutation: true),
    );
    try {
      await throwing.saveApiKey('secret-value');
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
  'unsupported_model': AiCredentialFailureCode.unsupportedModel,
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

wire.AiRecapStatusDto _status({
  bool? serviceAvailable,
  bool configured = true,
  String source = 'secure_store',
  bool secureStorageAvailable = true,
  bool migrationAvailable = false,
  String defaultModel = 'deepseek-v4-flash',
}) => wire.AiRecapStatusDto(
  serviceAvailable: serviceAvailable ?? source != 'unavailable',
  configured: configured,
  provider: 'DeepSeek',
  defaultModel: defaultModel,
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
  }) : statusValue = statusValue ?? _status();

  final wire.AiRecapStatusDto statusValue;
  final wire.AiRecapErrorDto? settingsError;
  final wire.AiRecapConnectionReplyDto connectionReply;
  final bool throwOnMutation;
  String? savedApiKey;
  String? savedModel;
  int removeCalls = 0;
  int importCalls = 0;

  @override
  wire.AiRecapStatusDto status() => statusValue;

  @override
  Future<wire.AiRecapSettingsReplyDto> saveApiKey(String apiKey) async {
    if (throwOnMutation) throw StateError('raw-provider-body');
    savedApiKey = apiKey;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> removeApiKey() async {
    removeCalls += 1;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> importEnvironmentApiKey() async {
    importCalls += 1;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapSettingsReplyDto> setDefaultModel(String model) async {
    savedModel = model;
    return _settingsReply();
  }

  @override
  Future<wire.AiRecapConnectionReplyDto> testConnection() async =>
      connectionReply;

  wire.AiRecapSettingsReplyDto _settingsReply() =>
      wire.AiRecapSettingsReplyDto(status: statusValue, error: settingsError);
}
