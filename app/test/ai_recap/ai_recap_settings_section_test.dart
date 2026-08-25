import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/application/ai_credential_port.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_settings_section.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_credential_provider.dart';

void main() {
  group('AiCredentialController', () {
    test('saves a key but retains only redacted status', () async {
      final port = _FakeCredentialPort();
      final container = ProviderContainer(
        overrides: [aiCredentialPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);
      expect(container.read(aiCredentialRevisionProvider), 0);

      final saved = await container
          .read(aiCredentialControllerProvider.notifier)
          .saveApiKey('  secret-value  ');

      expect(saved, isTrue);
      expect(port.savedApiKey, 'secret-value');
      final state = container.read(aiCredentialControllerProvider);
      expect(state.status.credentialSource, AiCredentialSource.secureStore);
      expect(state.status.configured, isTrue);
      expect(state.operation, isNull);
      expect(state.failure, isNull);
      expect(container.read(aiCredentialRevisionProvider), 1);
    });

    test(
      'connection test has no usage payload and exposes a closed result',
      () async {
        final port = _FakeCredentialPort(
          initialStatus: const AiRecapProviderStatus(
            configured: true,
            credentialSource: AiCredentialSource.secureStore,
          ),
        );
        final container = ProviderContainer(
          overrides: [aiCredentialPortProvider.overrideWithValue(port)],
        );
        addTearDown(container.dispose);

        final connected = await container
            .read(aiCredentialControllerProvider.notifier)
            .testConnection();

        expect(connected, isTrue);
        expect(port.connectionTestCalls, 1);
        expect(
          container
              .read(aiCredentialControllerProvider)
              .connectionTestSucceeded,
          isTrue,
        );
      },
    );

    test('unknown exceptions are redacted to bridge unavailable', () async {
      final port = _FakeCredentialPort()..saveError = StateError('raw-secret');
      final container = ProviderContainer(
        overrides: [aiCredentialPortProvider.overrideWithValue(port)],
      );
      addTearDown(container.dispose);

      final saved = await container
          .read(aiCredentialControllerProvider.notifier)
          .saveApiKey('secret-value');

      expect(saved, isFalse);
      expect(
        container.read(aiCredentialControllerProvider).failure,
        AiCredentialFailureCode.bridgeUnavailable,
      );
      expect(container.read(aiCredentialRevisionProvider), 1);
    });
  });

  group('AiRecapSettingsSection', () {
    testWidgets('works at 420 px and never displays the stored key', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final port = _FakeCredentialPort();

      await _pumpSection(tester, port);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('ai-api-key-field')),
      );
      expect(field.obscureText, isTrue);
      expect(
        find.byKey(const ValueKey('ai-provider-selector')),
        findsOneWidget,
      );
      expect(find.text('服务提供方'), findsOneWidget);
      expect(find.textContaining('使用你的 API Key'), findsOneWidget);
      expect(find.byType(Card), findsNothing);
      expect(find.text('未配置'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.byKey(const ValueKey('ai-api-key-field')),
        'sk-sensitive-value',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-save-key-button')),
      );
      await tester.tap(find.byKey(const ValueKey('ai-save-key-button')));
      await tester.pumpAndSettle();

      expect(port.savedApiKey, 'sk-sensitive-value');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-api-key-field')))
            .controller
            ?.text,
        isEmpty,
      );
      expect(find.text('已连接'), findsOneWidget);
      expect(find.textContaining('sk-sensitive-value'), findsNothing);
      expect(find.textContaining('••••••••••••••••••'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows environment source and imports only after user action', (
      tester,
    ) async {
      final port = _FakeCredentialPort(
        initialStatus: const AiRecapProviderStatus(
          configured: true,
          credentialSource: AiCredentialSource.legacyEnvironment,
          environmentMigrationAvailable: true,
        ),
      );

      await _pumpSection(tester, port);

      expect(find.text('环境变量'), findsOneWidget);
      expect(port.importCalls, 0);
      await tester.tap(
        find.byKey(const ValueKey('ai-import-environment-button')),
      );
      await tester.pumpAndSettle();

      expect(port.importCalls, 1);
      expect(find.text('已连接'), findsOneWidget);
    });

    testWidgets('local free provider hides key and connection controls', (
      tester,
    ) async {
      final port = _FakeCredentialPort(
        initialStatus: const AiRecapProviderStatus(
          ready: true,
          selectedProvider: AiRecapProviderId.localSummary,
          selectedModel: AiRecapModel.localSummary,
          credentialSource: AiCredentialSource.notRequired,
        ),
      );

      await _pumpSection(tester, port);

      expect(find.text('本地总结（免费）'), findsOneWidget);
      expect(find.text('本地总结 v1'), findsWidgets);
      expect(find.byKey(const ValueKey('ai-fixed-model')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-default-model-selector')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('ai-api-key-field')), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-test-connection-button')),
        findsNothing,
      );
    });

    testWidgets('provider switching keeps conditional controls consistent', (
      tester,
    ) async {
      final port = _FakeCredentialPort(
        initialStatus: const AiRecapProviderStatus(
          ready: true,
          selectedProvider: AiRecapProviderId.localSummary,
          selectedModel: AiRecapModel.localSummary,
          credentialSource: AiCredentialSource.notRequired,
        ),
      );
      await _pumpSection(tester, port);

      expect(find.byKey(const ValueKey('ai-api-key-field')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ai-provider-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek').last);
      await tester.pumpAndSettle();

      expect(port.modelUpdates, [AiRecapModel.flash]);
      expect(find.byKey(const ValueKey('ai-api-key-field')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-test-connection-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-default-model-selector')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('ai-provider-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本地总结（免费）').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-api-key-field')), findsNothing);
      expect(find.byKey(const ValueKey('ai-fixed-model')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ai-provider-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DeepSeek').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-api-key-field')), findsOneWidget);
      expect(port.modelUpdates, [
        AiRecapModel.flash,
        AiRecapModel.localSummary,
        AiRecapModel.flash,
      ]);
    });

    testWidgets('clears the API key field even when secure save fails', (
      tester,
    ) async {
      final port = _FakeCredentialPort()
        ..saveError = StateError('must never reach the UI');
      await _pumpSection(tester, port);

      await tester.enterText(
        find.byKey(const ValueKey('ai-api-key-field')),
        'sk-sensitive-value',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('ai-save-key-button')),
      );
      await tester.tap(find.byKey(const ValueKey('ai-save-key-button')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('ai-api-key-field')))
            .controller
            ?.text,
        isEmpty,
      );
      expect(find.textContaining('sk-sensitive-value'), findsNothing);
      expect(find.textContaining('must never reach the UI'), findsNothing);
      expect(find.textContaining('报告生成组件暂时不可用'), findsOneWidget);
    });

    testWidgets('default model and connection test are explicit actions', (
      tester,
    ) async {
      final port = _FakeCredentialPort(
        initialStatus: const AiRecapProviderStatus(
          configured: true,
          credentialSource: AiCredentialSource.secureStore,
        ),
      );

      await _pumpSection(tester, port);
      expect(port.modelUpdates, isEmpty);
      expect(port.connectionTestCalls, 0);
      expect(
        find.byKey(const ValueKey('ai-default-model-selector')),
        findsOneWidget,
      );

      await tester.tap(find.text('DeepSeek Pro'));
      await tester.pumpAndSettle();
      expect(port.modelUpdates, [AiRecapModel.pro]);

      final connectionButton = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('ai-test-connection-button')),
      );
      connectionButton.onPressed!();
      await tester.pumpAndSettle();
      expect(port.connectionTestCalls, 1);
      expect(find.text('连接成功，可以生成报告。'), findsOneWidget);
      expect(find.textContaining('不会发送任何使用数据'), findsOneWidget);
    });
  });
}

Future<void> _pumpSection(WidgetTester tester, AiCredentialPort port) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [aiCredentialPortProvider.overrideWithValue(port)],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(12),
            child: AiRecapSettingsSection(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _FakeCredentialPort implements AiCredentialPort {
  _FakeCredentialPort({
    AiRecapProviderStatus initialStatus =
        const AiRecapProviderStatus.unconfigured(),
  }) : _status = initialStatus;

  AiRecapProviderStatus _status;
  String? savedApiKey;
  Object? saveError;
  int importCalls = 0;
  int connectionTestCalls = 0;
  final List<AiRecapModel> modelUpdates = [];

  @override
  AiRecapProviderStatus status() => _status;

  @override
  Future<AiRecapProviderStatus> saveApiKey(
    String apiKey, {
    AiRecapProviderId? provider,
  }) async {
    final error = saveError;
    if (error != null) throw error;
    savedApiKey = apiKey;
    _status = AiRecapProviderStatus(
      configured: true,
      defaultModel: _status.defaultModel,
      credentialSource: AiCredentialSource.secureStore,
    );
    return _status;
  }

  @override
  Future<AiRecapProviderStatus> removeApiKey({
    AiRecapProviderId? provider,
  }) async {
    _status = AiRecapProviderStatus(
      configured: false,
      defaultModel: _status.defaultModel,
      credentialSource: AiCredentialSource.none,
    );
    return _status;
  }

  @override
  Future<AiRecapProviderStatus> importEnvironmentApiKey({
    AiRecapProviderId? provider,
  }) async {
    importCalls += 1;
    _status = AiRecapProviderStatus(
      configured: true,
      defaultModel: _status.defaultModel,
      credentialSource: AiCredentialSource.secureStore,
    );
    return _status;
  }

  @override
  Future<AiRecapProviderStatus> setDefaultModel(AiRecapModel model) async {
    modelUpdates.add(model);
    _status = AiRecapProviderStatus(
      configured: _status.configured,
      defaultModel: model,
      credentialSource: _status.credentialSource,
      environmentMigrationAvailable: _status.environmentMigrationAvailable,
    );
    return _status;
  }

  @override
  Future<AiRecapProviderStatus> setProviderSelection(
    AiRecapProviderId provider,
    AiRecapModel model,
  ) async {
    modelUpdates.add(model);
    _status = AiRecapProviderStatus(
      ready: provider == AiRecapProviderId.localSummary || _status.configured,
      selectedProvider: provider,
      selectedModel: model,
      credentialSource: provider == AiRecapProviderId.localSummary
          ? AiCredentialSource.notRequired
          : _status.credentialSource,
    );
    return _status;
  }

  @override
  Future<void> testConnection() async {
    connectionTestCalls += 1;
  }
}
