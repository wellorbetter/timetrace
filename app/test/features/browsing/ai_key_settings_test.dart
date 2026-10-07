import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ai_key_store.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';
import 'package:timetrace_app/src/features/settings/presentation/ai_connection_settings.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';

class FakeKeys implements AiKeyStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String input) async {
    if (fail) throw StateError('fixture storage unavailable');
    value = input;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class MemoryEnabled extends AiEnabledNotifier {
  @override
  bool build() => true;
  @override
  void setEnabled(bool value) => state = value;
}

class MemoryModel extends DeepSeekModelNotifier {
  @override
  String build() => 'deepseek-flash';
  @override
  void setModel(String value) => state = value;
}

void main() {
  testWidgets(
    'environment source is separate, Enter failure retains input and model is glass',
    (tester) async {
      final store = FakeKeys();
      final container = ProviderContainer(
        overrides: [
          aiKeyStoreProvider.overrideWithValue(store),
          deepSeekEnvironmentKeyProvider.overrideWithValue(
            'synthetic-environment-secret',
          ),
          aiEnabledProvider.overrideWith(MemoryEnabled.new),
          deepSeekModelProvider.overrideWith(MemoryModel.new),
        ],
      );
      addTearDown(container.dispose);
      final policy = MaterialPolicy.resolve(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        wallpaper: WallpaperLoadState.absent,
        signals: const MaterialSignals(
          highContrast: AccessibilitySignal.disabled,
          reduceTransparency: AccessibilitySignal.disabled,
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: MaterialScope(
                policy: policy,
                tokens: MaterialTokens.forWidth(360),
                child: const AiConnectionSettings(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ai_save_key')), findsNothing);
      await tester.tap(find.byKey(const Key('ai_provider_details')));
      await tester.pumpAndSettle();
      expect(find.text('使用环境 Key'), findsOneWidget);
      expect(find.text('synthetic-environment-secret'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ai_enabled')));
      await tester.pumpAndSettle();
      expect(container.read(aiEnabledProvider), isFalse);
      await tester.tap(find.byKey(const Key('ai_provider_details')));
      await tester.pumpAndSettle();
      expect(find.text('使用环境 Key'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('ai_api_key_input'));
      store.fail = true;
      await tester.enterText(input, 'synthetic-new-key');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'synthetic-new-key',
      );
      expect(store.value, isNull);
      expect(find.textContaining('无法保存'), findsOneWidget);
      store.fail = false;
      await tester.showKeyboard(input);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.value, 'synthetic-new-key');
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.tap(find.byKey(const Key('ai_provider_details')));
      await tester.pumpAndSettle();
      final panel = tester.widget<MaterialTransientPanel>(
        find.byType(MaterialTransientPanel),
      );
      expect(panel.capture!.container, same(container));
      expect(panel.capture!.scope!.policy, same(policy));
      expect(find.byType(MaterialCard), findsOneWidget);
      await tester.tap(find.widgetWithText(MenuItemButton, 'deepseek-v4-pro'));
      await tester.pumpAndSettle();
      expect(container.read(deepSeekModelProvider), 'deepseek-v4-pro');
      expect(find.byType(MaterialTransientPanel), findsNothing);
      await tester.tap(find.byType(ContextHelp));
      await tester.pumpAndSettle();
      expect(find.textContaining('DEEPSEEK_API_KEY'), findsOneWidget);
      expect(find.text('synthetic-environment-secret'), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'Windows credential roundtrip only uses isolated fake fixture',
    () async {
      final store = SecureAiKeyStore.testFixture(
        '$pid-${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(await store.read(), isNull);
      try {
        await store.write('fixture-not-an-api-key');
        expect(await store.read(), 'fixture-not-an-api-key');
        await store.write('fixture-replacement');
        expect(await store.read(), 'fixture-replacement');
      } finally {
        await store.clear();
      }
      expect(await store.read(), isNull);
    },
    skip: !Platform.isWindows,
  );
  test(
    'manual key wins, survives container restart, clear restores environment',
    () async {
      final store = FakeKeys();
      ProviderContainer create() => ProviderContainer(
        overrides: [
          aiKeyStoreProvider.overrideWithValue(store),
          deepSeekEnvironmentKeyProvider.overrideWithValue(
            'fixture-environment',
          ),
        ],
      );
      final first = create();
      await first.read(savedDeepSeekKeyProvider.future);
      expect(first.read(deepSeekKeyProvider), 'fixture-environment');
      await first
          .read(savedDeepSeekKeyProvider.notifier)
          .save('  fixture-manual  ');
      expect(first.read(deepSeekKeyProvider), 'fixture-manual');
      first.dispose();
      final second = create();
      addTearDown(second.dispose);
      await second.read(savedDeepSeekKeyProvider.future);
      expect(second.read(deepSeekKeyProvider), 'fixture-manual');
      await second.read(savedDeepSeekKeyProvider.notifier).clear();
      expect(second.read(deepSeekKeyProvider), 'fixture-environment');
    },
  );
  test('invalid or failed save never changes effective key', () async {
    final store = FakeKeys()..value = 'fixture-old';
    final container = ProviderContainer(
      overrides: [
        aiKeyStoreProvider.overrideWithValue(store),
        deepSeekEnvironmentKeyProvider.overrideWithValue(''),
      ],
    );
    addTearDown(container.dispose);
    await container.read(savedDeepSeekKeyProvider.future);
    final notifier = container.read(savedDeepSeekKeyProvider.notifier);
    for (final key in ['', 'bad key', 'bad\nkey']) {
      await expectLater(
        notifier.save(key),
        throwsA(isA<AiConnectionFailure>()),
      );
    }
    store.fail = true;
    await expectLater(
      notifier.save('fixture-new'),
      throwsA(isA<AiConnectionFailure>()),
    );
    expect(container.read(deepSeekKeyProvider), 'fixture-old');
  });
  for (final width in [360.0, 900.0]) {
    testWidgets('masked input, save, clear and source state at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = FakeKeys();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiKeyStoreProvider.overrideWithValue(store),
            deepSeekEnvironmentKeyProvider.overrideWithValue(''),
            aiEnabledProvider.overrideWith(MemoryEnabled.new),
            deepSeekModelProvider.overrideWith(MemoryModel.new),
          ],
          child: const MaterialApp(
            home: Scaffold(body: AiConnectionSettings()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('ai_api_key_input'));
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      await tester.enterText(input, 'fixture-test-only');
      await tester.tap(find.byKey(const Key('ai_key_visibility')));
      await tester.pump();
      expect(tester.widget<TextField>(input).obscureText, isFalse);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(store.value, 'fixture-test-only');
      await tester.tap(find.byKey(const Key('ai_provider_details')));
      await tester.pumpAndSettle();
      expect(find.text('使用已保存 Key'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.widget<TextField>(input).obscureText, isTrue);
      await tester.tap(find.byKey(const Key('ai_clear_key')));
      await tester.pumpAndSettle();
      expect(store.value, isNull);
      await tester.tap(find.byKey(const Key('ai_provider_details')));
      await tester.pumpAndSettle();
      expect(find.text('未配置 Key'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
