import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/ai_recap.dart' as wire;
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/infrastructure/bridge_ai_recap_port.dart';

void main() {
  test(
    'maps status, exact latest range and a successful typed reply',
    () async {
      final api = _FakeBridgeApi(recap: _wireRecap());
      final port = BridgeAiRecapPort(api);

      expect(port.status().configured, isTrue);
      expect(port.latestReports().single.summary.text, '安全摘要');
      final generated = await port.generate(_key);

      expect(generated.rangeKey, _key);
      expect(generated.providerId, AiRecapProviderId.deepSeek);
      expect(generated.totalActiveSeconds, 3600);
      expect(api.lastStart, '2026-08-24');
      expect(api.lastEnd, '2026-08-24');
      expect(api.lastScope, 'daily');
    },
  );

  test(
    'maps every stable wire error without exposing exception text',
    () async {
      for (final entry in _errorCodes.entries) {
        final port = BridgeAiRecapPort(
          _FakeBridgeApi(
            error: wire.AiRecapErrorDto(code: entry.key, retryable: true),
          ),
        );

        await expectLater(
          port.generate(_key),
          throwsA(
            isA<AiRecapFailure>().having(
              (failure) => failure.code,
              'code',
              entry.value,
            ),
          ),
        );
      }
    },
  );

  test('rejects malformed replies and mismatched ranges', () async {
    final malformed = BridgeAiRecapPort(_FakeBridgeApi(emptyReply: true));
    await expectLater(
      malformed.generate(_key),
      throwsA(
        isA<AiRecapFailure>().having(
          (failure) => failure.code,
          'code',
          AiRecapFailureCode.invalidResponse,
        ),
      ),
    );

    final mismatched = BridgeAiRecapPort(
      _FakeBridgeApi(recap: _wireRecap(start: '2026-08-23')),
    );
    expect(() => mismatched.latestReports(), throwsA(isA<AiRecapFailure>()));

    for (final invalidDate in [
      '2026-02-30',
      '2026-8-24',
      '2026-08-24T00:00:00Z',
    ]) {
      final invalid = BridgeAiRecapPort(
        _FakeBridgeApi(recap: _wireRecap(start: invalidDate)),
      );
      expect(
        () => invalid.latestReports(),
        throwsA(
          isA<AiRecapFailure>().having(
            (failure) => failure.code,
            'code',
            AiRecapFailureCode.invalidResponse,
          ),
        ),
      );
    }

    final mismatchedProvider = BridgeAiRecapPort(
      _FakeBridgeApi(
        recap: _wireRecap(
          provider: 'local_summary',
          model: 'deepseek-v4-flash',
        ),
      ),
    );
    expect(
      () => mismatchedProvider.latestReports(),
      throwsA(
        isA<AiRecapFailure>().having(
          (failure) => failure.code,
          'code',
          AiRecapFailureCode.invalidResponse,
        ),
      ),
    );
  });

  test('reports a bridge status failure separately from missing key', () {
    final port = BridgeAiRecapPort(_FakeBridgeApi(throwOnStatus: true));

    final status = port.status();
    expect(status.serviceAvailable, isFalse);
    expect(status.configured, isFalse);
  });
}

final AiRecapRangeKey _key = AiRecapRangeKey(
  scope: AiRecapScope.daily,
  startDate: DateTime(2026, 8, 24),
  endDate: DateTime(2026, 8, 24),
);

const Map<String, AiRecapFailureCode> _errorCodes = {
  'not_configured': AiRecapFailureCode.notConfigured,
  'invalid_range': AiRecapFailureCode.invalidRange,
  'unsupported_provider': AiRecapFailureCode.unsupportedProvider,
  'unsupported_model': AiRecapFailureCode.unsupportedModel,
  'provider_not_ready': AiRecapFailureCode.providerNotReady,
  'connection_test_not_supported':
      AiRecapFailureCode.connectionTestNotSupported,
  'no_usage_data': AiRecapFailureCode.noUsageData,
  'request_too_large': AiRecapFailureCode.requestTooLarge,
  'network': AiRecapFailureCode.network,
  'timeout': AiRecapFailureCode.timeout,
  'authentication': AiRecapFailureCode.authentication,
  'rate_limited': AiRecapFailureCode.rateLimited,
  'provider_unavailable': AiRecapFailureCode.providerUnavailable,
  'invalid_response': AiRecapFailureCode.invalidResponse,
  'busy': AiRecapFailureCode.busy,
};

wire.AiRecapDto _wireRecap({
  String start = '2026-08-24',
  String provider = 'deepseek',
  String model = 'deepseek-v4-flash',
}) => wire.AiRecapDto(
  providerId: provider,
  scope: 'daily',
  startDate: start,
  endDate: '2026-08-24',
  generatedAtUtc: '2026-08-24T01:30:00Z',
  model: model,
  summary: _wireStatement('安全摘要'),
  highlights: [_wireStatement('亮点')],
  suggestions: [_wireStatement('建议')],
  topApplications: const [
    wire.AiRecapEvidenceDto(appName: 'Editor', activeSeconds: 3600),
  ],
  totalActiveSeconds: 3600,
  applicationCount: 2,
);

wire.AiRecapStatementDto _wireStatement(String text) =>
    wire.AiRecapStatementDto(
      text: text,
      evidence: const [
        wire.AiRecapEvidenceDto(appName: 'Editor', activeSeconds: 3600),
      ],
    );

class _FakeBridgeApi implements AiRecapBridgeApi {
  _FakeBridgeApi({
    this.recap,
    this.error,
    this.emptyReply = false,
    this.throwOnStatus = false,
  });

  final wire.AiRecapDto? recap;
  final wire.AiRecapErrorDto? error;
  final bool emptyReply;
  final bool throwOnStatus;
  String? lastStart;
  String? lastEnd;
  String? lastScope;

  @override
  wire.AiRecapStatusDto status() {
    if (throwOnStatus) throw StateError('bridge unavailable');
    return const wire.AiRecapStatusDto(
      serviceAvailable: true,
      ready: true,
      selectedProviderId: 'deepseek',
      selectedModelId: 'deepseek-v4-flash',
      providers: _wireProviders,
      credentialSource: 'secure_store',
      secureStorageAvailable: true,
      environmentMigrationAvailable: false,
    );
  }

  @override
  List<wire.AiRecapDto> latestReports() => [?recap];

  @override
  Future<wire.AiRecapGenerateReplyDto> generate({
    required String scope,
    required String start,
    required String end,
  }) async {
    lastScope = scope;
    lastStart = start;
    lastEnd = end;
    if (emptyReply) return const wire.AiRecapGenerateReplyDto();
    return wire.AiRecapGenerateReplyDto(recap: recap, error: error);
  }
}

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
