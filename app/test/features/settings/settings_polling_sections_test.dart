import 'dart:async';
import 'package:timetrace_app/src/core/preferences/presentation_preferences_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/preferences/local_storage_folder_action.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/preferences/ai_key_store.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/material_appearance_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';
import 'package:timetrace_app/src/features/feed/providers/feed_preferences_provider.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/local_storage_information.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

class MemoryConfigApi implements TimeTraceApi {
  MemoryConfigApi(int ms)
    : config = ConfigDto(
        pollIntervalMs: BigInt.from(ms),
        idleThresholdMinutes: BigInt.from(5),
        minimizeToTray: true,
        startMinimized: false,
        autoStartTracking: true,
        excludedApps: const ['fixture.exe'],
        dbPath: r'C:\synthetic\time.db',
      );
  ConfigDto config;
  int reads = 0, writes = 0, unexpected = 0, pauseWrites = 0, startupWrites = 0;
  bool fail = false;
  @override
  ConfigDto getConfig() {
    reads++;
    return config;
  }

  @override
  void setConfig({required ConfigDto config}) {
    writes++;
    if (fail) throw StateError('synthetic failure');
    this.config = config;
  }

  @override
  bool isTrackingPaused() => false;
  @override
  bool isSelfStartEnabled() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpected++;
    throw StateError('Unexpected backend access: ${invocation.memberName}');
  }
}

class MemoryLocale extends LocaleNotifier {
  @override
  AppLocale build() => AppLocale.zh;
  @override
  void set(AppLocale value) => state = value;
}

class MemoryTheme extends ThemeNotifier {
  @override
  bool build() => false;
  @override
  void set(bool value) => state = value;
  @override
  void toggle() => state = !state;
}

class MemoryFont extends FontNotifier {
  @override
  AppFont build() => AppFont.defaultFont;
  @override
  void select(AppFont value) => state = value;
}

class MemoryBackground extends BackgroundNotifier {
  int pickerCalls = 0;
  @override
  BackgroundPref build() => const BackgroundPref();
  @override
  void setColor(Color? value) => state = BackgroundPref(color: value);
  @override
  void setOpacity(double value) => state = state.copyWith(opacity: value);
  @override
  void clear() => state = const BackgroundPref();
  @override
  Future<void> pickImage() async {
    pickerCalls++;
    throw StateError('Native picker trap');
  }
}

class MemoryAppearance extends MaterialAppearanceNotifier {
  int saves = 0;
  @override
  MaterialAppearance build() => const MaterialAppearance();
  @override
  void persist() => saves++;
}

class MemoryEnabled extends AiEnabledNotifier {
  @override
  bool build() => false;
  @override
  void setEnabled(bool value) => state = value;
}

class MemoryModel extends DeepSeekModelNotifier {
  @override
  String build() => 'deepseek-flash';
  @override
  void setModel(String value) => state = value;
}

class MemoryMinutes extends FeedBucketMinutesNotifier {
  @override
  int build() => 10;
  @override
  void setMinutes(int value) => state = value;
}

class MemoryMode extends FeedDisplayModeNotifier {
  @override
  FeedDisplayMode build() => FeedDisplayMode.overview;
  @override
  void setMode(FeedDisplayMode value) => state = value;
}

class MemoryKeys implements AiKeyStore {
  int writes = 0, reads = 0;
  String? value;
  bool fail = false;
  Completer<void>? writeGate;
  @override
  Future<String?> read() async { reads++; return value; }
  @override
  Future<void> write(String input) async {
    writes++;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (fail) throw StateError('Synthetic secure-store failure');
    value = input;
  }

  @override
  Future<void> clear() async { writes++; value = null; }
}

class SettingsFixture {
  SettingsFixture(int ms, {MemoryPreferencesBackend? themeBackend})
    : api = MemoryConfigApi(ms) {
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        localeProvider.overrideWith(MemoryLocale.new),
        themeModeProvider.overrideWith(
          themeBackend == null ? MemoryTheme.new : ThemeNotifier.new,
        ),
        uiPreferencesBackendProvider.overrideWithValue(
          themeBackend ?? MemoryPreferencesBackend(),
        ),
        fontProvider.overrideWith(MemoryFont.new),
        backgroundProvider.overrideWith(() => background),
        materialAppearanceProvider.overrideWith(() => appearance),
        aiEnabledProvider.overrideWith(MemoryEnabled.new),
        deepSeekModelProvider.overrideWith(MemoryModel.new),
        aiKeyStoreProvider.overrideWithValue(keys),
        deepSeekEnvironmentKeyProvider.overrideWithValue(''),
        feedBucketMinutesProvider.overrideWith(MemoryMinutes.new),
        feedDisplayModeProvider.overrideWith(MemoryMode.new),
      ],
    );
  }
  final MemoryConfigApi api;
  final background = MemoryBackground();
  final appearance = MemoryAppearance();
  final keys = MemoryKeys();
  late final ProviderContainer container;
  int pathReads = 0, processReads = 0;
  Widget host(double scale, {String? initialSection, FolderAction? folderAction}) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: MaterialScope(
        policy: MaterialPolicy.resolve(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          wallpaper: WallpaperLoadState.absent,
          signals: const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.disabled,
          ),
        ),
        tokens: MaterialTokens.forWidth(360),
        child: SettingsScreen(
          initialSection: initialSection,
          storageFolderAction: folderAction,
          storageLocations: () {
            pathReads++;
            return const LocalStorageLocations(
              appData: r'C:\synthetic\roaming',
              localAppData: r'C:\synthetic\local',
            );
          },
          loadExcludedProcesses: () async {
            processReads++;
            return const {'synthetic.exe': ''};
          },
        ),
      ),
    ),
  );
  void expectSafe() {
    expect(api.unexpected, 0);
    expect(api.pauseWrites, 0);
    expect(api.startupWrites, 0);
    expect(keys.writes, 0);
    expect(background.pickerCalls, 0);
    expect(appearance.saves, 0);
    expect(pathReads, greaterThan(0));
  }
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}


class DeferredFixtureFolder implements FolderAction {
  Completer<FolderActionResult>? gate;
  int calls = 0;
  final targets = <String>[];
  @override
  Future<FolderActionResult> open(String target) async {
    calls++;
    targets.add(target);
    final pending = gate;
    if (pending != null) return pending.future;
    return const FolderActionResult(
      FolderActionStatus.accepted, stage: FolderActionStage.request);
  }
}

Future<void> toggleSection(WidgetTester tester, String type) async {
  final header = find.byKey(ValueKey('settings_toggle_$type'));
  await reveal(tester, header);
  await tester.tap(header);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('real pointer blank then Tab Enter Space shows keyboard header paint without IO', (tester) async {
    tester.view.physicalSize = const Size(720,1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = MemoryPreferencesBackend();
    final fixture = SettingsFixture(500, themeBackend: backend);
    addTearDown(fixture.container.dispose);
    await tester.pumpWidget(fixture.host(1));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('settings_toggle_theme'));
    FilledButton current() => tester.widget<FilledButton>(header);
    void pointerPaint() {
      expect(current().style!.overlayColor!.resolve({WidgetState.focused})!.a, 0);
      expect(current().style!.side!.resolve({WidgetState.focused})!.color, Colors.transparent);
    }
    void keyboardPaint() {
      expect(current().style!.overlayColor!.resolve({WidgetState.focused})!.a, greaterThan(0));
      expect(current().style!.side!.resolve({WidgetState.focused})!.color.a, greaterThan(0));
    }
    await tester.tap(header); // collapsed; logical focus retained
    await tester.pumpAndSettle();
    expect(current().focusNode!.hasFocus, true);
    await tester.tapAt(const Offset(2,2)); // actual page blank
    await tester.pump();
    pointerPaint();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    keyboardPaint();
    // These child-button Shortcuts handle activation before ancestor Focus.
    for (final key in [LogicalKeyboardKey.enter,LogicalKeyboardKey.space]) {
      await reveal(tester, header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2,2));
      await tester.pump();
      expect(current().focusNode!.hasFocus, true);
      pointerPaint();
      final wasVisible = find.byKey(const ValueKey('settings_body_theme')).evaluate().isNotEmpty;
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      keyboardPaint();
      expect(find.byKey(const ValueKey('settings_body_theme')).evaluate().isNotEmpty, !wasVisible);
    }
    expect(backend.commits, 0);
    expect(fixture.api.writes, 0);
    fixture.expectSafe();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); // local observer disposed
  });

  testWidgets('toolbar/window failed feedback remains in collapsed categories, draft retained', (tester) async {
    final backend = MemoryPreferencesBackend();
    backend.faults.add('commit');
    final fixture = SettingsFixture(500, themeBackend: backend);
    addTearDown(fixture.container.dispose);
    await tester.pumpWidget(fixture.host(1));
    await tester.pumpAndSettle();
    final custom = find.byKey(const Key('feed_custom_minutes'));
    await reveal(tester,custom);
    await tester.tap(custom);
    await tester.pumpAndSettle();
    final input = find.descendant(of: find.byKey(const Key('custom_feed_minutes')),
        matching: find.byType(TextField));
    await tester.enterText(input,'17');
    final controller = tester.widget<TextField>(input).controller!;
    controller.selection = const TextSelection.collapsed(offset: 1);
    await fixture.container.read(feedToolbarAlignmentProvider.notifier)
        .setAlignment(FeedToolbarAlignment.right);
    await fixture.container.read(immersiveWindowProvider.notifier).setEnabled(true);
    await tester.pumpAndSettle();
    await toggleSection(tester,'feed');
    await toggleSection(tester,'background');
    expect(find.byKey(const ValueKey('settings_status_feed')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('settings_status_feed'))).data, '未保存 · 有错误');
    expect(tester.widget<Text>(find.byKey(const ValueKey('settings_status_background'))).data, '未保存 · 有错误');
    expect(input, findsNothing);
    await toggleSection(tester,'feed');
    expect(tester.widget<TextField>(input).controller, same(controller));
    expect(controller.text,'17');
    expect(controller.selection,const TextSelection.collapsed(offset: 1));
    expect(backend.commits,0);
    expect(fixture.api.writes,0);
    fixture.expectSafe();
    expect(tester.takeException(),isNull);
  });
  testWidgets('category folds retain invalid poll, hidden focus and type across resize/locale',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      for (final type in ['theme', 'language', 'font', 'background', 'workspace',
        'feed', 'recap', 'monitoring', 'record', 'startup', 'data', 'about']) {
        expect(find.byKey(ValueKey('settings_toggle_$type')), findsOneWidget);
      }
      final input = find.byKey(const Key('settings_poll_value'));
      await reveal(tester, input);
      await tester.enterText(input, 'NaN');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(input).controller!;
      controller.selection = const TextSelection(baseOffset: 1, extentOffset: 2);
      final editable = tester.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)));
      final reads = fixture.api.reads, keyReads = fixture.keys.reads;
      await toggleSection(tester, 'monitoring');
      expect(input, findsNothing);
      final retainedBody = find.byKey(
        const ValueKey('settings_body_monitoring'), skipOffstage: false);
      final visibility = tester.widget<Visibility>(
        find.ancestor(of: retainedBody, matching: find.byType(Visibility)));
      expect(visibility.maintainState, true);
      expect(visibility.visible, false);
      expect(tester.widgetList<ExcludeSemantics>(
        find.ancestor(of: retainedBody, matching: find.byType(ExcludeSemantics, skipOffstage: false)))
        .any((node) => node.excluding), true);
      expect(tester.widgetList<TickerMode>(
        find.ancestor(of: retainedBody, matching: find.byType(TickerMode, skipOffstage: false)))
        .any((node) => !node.enabled), true);
      final header = find.byKey(const ValueKey('settings_toggle_monitoring'));
      expect(tester.widget<FilledButton>(header).focusNode!.hasFocus, true);
      editable.focusNode.requestFocus();
      await tester.pump();
      expect(editable.focusNode.hasFocus, false);
      expect(find.text('未保存 · 有错误'), findsOneWidget);
      tester.view.physicalSize = const Size(280, 1000);
      fixture.container.read(localeProvider.notifier).set(AppLocale.en);
      await tester.pumpWidget(fixture.host(2));
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      expect(fixture.api.reads, reads);
      expect(fixture.keys.reads, keyReads);
      await toggleSection(tester, 'monitoring');
      expect(tester.widget<TextField>(input).controller, same(controller));
      expect(controller.text, 'NaN');
      expect(controller.selection, const TextSelection(baseOffset: 1, extentOffset: 2));
      expect(tester.widget<TextField>(input).decoration!.errorText, isNotNull);
      expect(fixture.api.writes, 0);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    });
  testWidgets('custom minutes fold retains controller and selection without persistence',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      final custom = find.byKey(const Key('feed_custom_minutes'));
      await reveal(tester, custom);
      await tester.tap(custom);
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('custom_feed_minutes'));
      await reveal(tester, input);
      await tester.enterText(input, '17');
      final field = find.descendant(of: input, matching: find.byType(TextField));
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection(baseOffset: 1, extentOffset: 1);
      await toggleSection(tester, 'feed');
      expect(input, findsNothing);
      expect(find.text('未保存'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(input, findsNothing);
      await toggleSection(tester, 'feed');
      expect(tester.widget<TextField>(field).controller, same(controller));
      expect(controller.text, '17');
      expect(controller.selection, const TextSelection(baseOffset: 1, extentOffset: 1));
      expect(fixture.container.read(feedBucketMinutesProvider), 10);
      expect(fixture.api.writes, 0);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    });
  testWidgets('failed config remains reachable folded; retry keeps intent and newer draft',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('settings_poll_value'));
      await reveal(tester, input);
      fixture.api.fail = true;
      await tester.enterText(input, '60');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final intent = fixture.container.read(settingsWriteFeedbackProvider)!;
      final controller = tester.widget<TextField>(input).controller!;
      await tester.enterText(input, '0.6');
      await toggleSection(tester, 'monitoring');
      expect(find.text('未保存 · 有错误'), findsOneWidget);
      expect(find.byKey(const Key('settings_retry_poll')), findsNothing);
      await toggleSection(tester, 'monitoring');
      final retry = find.byKey(const Key('settings_retry_poll'));
      await reveal(tester, retry);
      fixture.api.fail = false;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      final verified = fixture.container.read(settingsWriteFeedbackProvider)!;
      expect(verified.id, intent.id);
      expect(verified.verified, true);
      expect(controller.text, '0.6');
      expect(tester.widget<TextField>(input).controller, same(controller));
      expect(fixture.api.config.pollIntervalMs, BigInt.from(60000));
      expect(fixture.api.writes, 2);
      expect(find.textContaining('有错误'), findsNothing);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    });
  testWidgets('folded masked Key emits busy/error only and retry retains input',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('ai_api_key_input'));
      await reveal(tester, input);
      fixture.keys.fail = true;
      final gate = Completer<void>();
      fixture.keys.writeGate = gate;
      await tester.enterText(input, 'fixture-only-not-real-secret');
      final controller = tester.widget<TextField>(input).controller!;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await toggleSection(tester, 'recap');
      expect(input, findsNothing);
      expect(find.text('未保存 · 保存中'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('未保存 · 有错误'), findsOneWidget);
      expect(find.textContaining('fixture-only-not-real-secret'), findsNothing);
      expect(fixture.keys.writes, 1);
      final reads = fixture.keys.reads;
      await toggleSection(tester, 'recap');
      expect(fixture.keys.reads, reads);
      expect(tester.widget<TextField>(input).controller, same(controller));
      expect(controller.text, 'fixture-only-not-real-secret');
      expect(tester.widget<TextField>(input).obscureText, true);
      fixture.keys.fail = false;
      fixture.keys.writeGate = null;
      final retry = find.byKey(const Key('ai_save_key'));
      await reveal(tester, retry);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(fixture.keys.writes, 2);
      expect(controller.text, isEmpty);
      expect(fixture.container.read(aiEnabledProvider), false);
      expect(fixture.api.writes, 0);
      expect(fixture.api.unexpected, 0);
      expect(fixture.background.pickerCalls, 0);
      expect(fixture.appearance.saves, 0);
      expect(tester.takeException(), isNull);
    });
  testWidgets('folded data surfaces late fake folder failure and same-opener retry',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      final folder = DeferredFixtureFolder();
      final gate = Completer<FolderActionResult>();
      folder.gate = gate;
      await tester.pumpWidget(fixture.host(1, folderAction: folder));
      await tester.pumpAndSettle();
      final open = find.byKey(const ValueKey('storage_folder_0'));
      await reveal(tester, open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(folder.calls, 1);
      await toggleSection(tester, 'data');
      expect(open, findsNothing);
      expect(find.text('处理中'), findsOneWidget);
      gate.complete(const FolderActionResult(
        FolderActionStatus.inaccessible, stage: FolderActionStage.probe, nativeCode: 5));
      await tester.pumpAndSettle();
      expect(find.text('有错误'), findsOneWidget);
      expect(find.byKey(const Key('storage_folder_feedback')), findsNothing);
      expect(find.textContaining(r'C:\synthetic'), findsNothing);
      await toggleSection(tester, 'data');
      expect(find.textContaining('无法访问存储目录'), findsOneWidget);
      folder.gate = null;
      await reveal(tester, open);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(folder.calls, 2);
      expect(folder.targets[1], folder.targets[0]);
      expect(find.text('文件夹打开请求已发送。'), findsOneWidget);
      expect(find.text('有错误'), findsNothing);
      expect(fixture.api.writes, 0);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    });
  testWidgets('changed initialSection opens folded target before ensureVisible',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1, initialSection: 'feed'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('feed_custom_minutes')), findsOneWidget);
      await toggleSection(tester, 'recap');
      expect(find.byKey(const Key('ai_api_key_input')), findsNothing);
      final reads = fixture.api.reads, keyReads = fixture.keys.reads;
      await tester.pumpWidget(fixture.host(1, initialSection: 'recap'));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('ai_api_key_input'));
      expect(input, findsOneWidget);
      final rect = tester.getRect(input);
      expect(rect.bottom, greaterThan(0));
      expect(rect.top, lessThan(tester.view.physicalSize.height));
      expect(fixture.api.reads, reads);
      expect(fixture.keys.reads, keyReads);
      expect(fixture.api.writes, 0);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    });

  testWidgets(
    'real theme failure has one warning and retry; verified ACK removes both',
    (tester) async {
      tester.view.physicalSize = const Size(280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = MemoryPreferencesBackend(
        '{"version":1,"dark":false,"unknown":{"keep":7}}',
      );
      final fixture = SettingsFixture(500, themeBackend: backend);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(2));
      await tester.pumpAndSettle();
      backend.faults.add('writeAndFlush');
      final dark = find.byWidgetPredicate(
        (widget) => widget is RadioListTile<bool> && widget.value == true,
      );
      await reveal(tester, dark);
      await tester.tap(dark);
      await tester.pumpAndSettle();
      expect(fixture.container.read(themeModeProvider), true);
      final failed = fixture.container.read(
        uiPreferencesControllerProvider,
      )['theme']!;
      expect(failed.status, UiPreferencesOperationStatus.failed);
      expect(find.text('尚未保存；当前仅为预览。'), findsOneWidget);
      final retry = find.byKey(const ValueKey('preferences_retry_theme'));
      expect(retry, findsOneWidget);
      expect(backend.commits, 0);
      await reveal(tester, retry);
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
      backend.faults.clear();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      final verified = fixture.container.read(
        uiPreferencesControllerProvider,
      )['theme']!;
      expect(verified.id, failed.id);
      expect(verified.target, failed.target);
      expect(verified.preimage, failed.preimage);
      expect(verified.status, UiPreferencesOperationStatus.verifiedAck);
      expect(find.text('尚未保存；当前仅为预览。'), findsNothing);
      expect(retry, findsNothing);
      expect(backend.files[backend.canonicalPath], contains('"dark": true'));
      expect(backend.files[backend.canonicalPath], contains('"keep": 7'));
      expect(fixture.api.writes, 0);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [280.0, 360.0, 720.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'legacy 500ms effective 30s minutes roundtrip and real 1min save/readback width=$width scale=$scale',
        (tester) async {
          tester.view.physicalSize = Size(width, 850);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture = SettingsFixture(500);
          addTearDown(fixture.container.dispose);
          await tester.pumpWidget(fixture.host(scale));
          await tester.pumpAndSettle();
          final input = find.byKey(const Key('settings_poll_value'));
          final unit = find.byKey(const Key('settings_poll_unit'));
          await reveal(tester, unit);
          expect(tester.getSize(unit).height, greaterThanOrEqualTo(48));
          expect(tester.getSize(unit).width, greaterThanOrEqualTo(48));
          final unitRect = tester.getRect(unit);
          expect(unitRect.left, greaterThanOrEqualTo(0));
          expect(unitRect.right, lessThanOrEqualTo(width));
          expect(unitRect.top, greaterThanOrEqualTo(0));
          expect(unitRect.bottom, lessThanOrEqualTo(850));
          expect(tester.widget<TextField>(input).controller!.text, '30');
          expect(fixture.api.config.pollIntervalMs, BigInt.from(500));
          expect(fixture.api.writes, 0);
          await tester.tap(unit);
          await tester.pumpAndSettle();
          expect(find.byType(MaterialTransientPanel), findsOneWidget);
          await tester.tap(find.widgetWithText(MenuItemButton, '分钟'));
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(input).controller!.text, '0.5');
          await tester.showKeyboard(input);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(
            fixture.container.read(settingsProvider).value!.pollIntervalMs,
            30000,
          );
          expect(fixture.api.writes, 0);
          await tester.enterText(input, '1');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(
            fixture.container.read(settingsProvider).value!.pollIntervalMs,
            60000,
          );
          expect(find.byKey(const Key('settings_save')), findsNothing);
          expect(fixture.api.writes, 1);
          expect(fixture.api.config.pollIntervalMs, BigInt.from(60000));
          fixture.container.invalidate(settingsProvider);
          await fixture.container.read(settingsProvider.future);
          await tester.pumpAndSettle();
          expect(
            fixture.container.read(settingsProvider).value!.pollIntervalMs,
            60000,
          );
          expect(fixture.api.reads, 3);
          expect(
            find.byKey(const Key('settings_monitoring_section')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('settings_record_section')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('settings_startup_section')),
            findsOneWidget,
          );
          fixture.expectSafe();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'failed config ACK retains retry input; invalid and legacy values never auto-write',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = SettingsFixture(60001);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      final input = find.byKey(const Key('settings_poll_value'));
      await reveal(tester, input);
      expect(tester.widget<TextField>(input).controller!.text, '60');
      expect(fixture.api.config.pollIntervalMs, BigInt.from(60001));
      expect(fixture.api.writes, 0);
      await tester.enterText(input, 'NaN');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        fixture.container.read(settingsProvider).value!.pollIntervalMs,
        60000,
      );
      expect(tester.widget<TextField>(input).decoration!.errorText, isNotNull);
      await tester.enterText(input, '30');
      fixture.api.fail = true;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final controller = tester.widget<TextField>(input).controller;
      tester.view.physicalSize = const Size(500, 850);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller, same(controller));
      final save = find.byKey(const Key('settings_retry_poll'));
      await reveal(tester, save);
      expect(fixture.api.config.pollIntervalMs, BigInt.from(60001));
      expect(controller!.text, '30');
      expect(find.text('保存失败，输入仍保留，请重试'), findsOneWidget);
      fixture.api.fail = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fixture.api.config.pollIntervalMs, BigInt.from(30000));
      expect(fixture.api.writes, 2);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'excluded process popup uses only injected synthetic loader and cancel preserves config',
    (tester) async {
      final fixture = SettingsFixture(500);
      addTearDown(fixture.container.dispose);
      await tester.pumpWidget(fixture.host(1));
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(ListTile, '排除应用');
      await reveal(tester, tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(fixture.processReads, 1);
      expect(find.byType(MaterialTransientPanel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(MaterialCard),
        ),
        findsOneWidget,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('synthetic.exe'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(fixture.api.writes, 0);
      expect(fixture.api.config.excludedApps, ['fixture.exe']);
      fixture.expectSafe();
      expect(tester.takeException(), isNull);
    },
  );
  test('poll rational quantization and strict range never drifts', () {
    for (final ms in [30000, 30001, 45000, 59999, 60000]) {
      for (final unit in PollingUnit.values) {
        expect(
          parsePollingMilliseconds(formatPollingValue(ms, unit), unit),
          ms,
        );
      }
    }
    expect(parsePollingMilliseconds('0.008333', PollingUnit.minutes), isNull);
    expect(parsePollingMilliseconds('0.5', PollingUnit.minutes), 30000);
    expect(parsePollingMilliseconds('1', PollingUnit.minutes), 60000);
    expect(parsePollingMilliseconds('0.4995', PollingUnit.seconds), isNull);
    expect(parsePollingMilliseconds('29.9995', PollingUnit.seconds), 30000);
    expect(parsePollingMilliseconds('60.0004', PollingUnit.seconds), 60000);
    for (final value in [
      '',
      '-1',
      'NaN',
      'Infinity',
      '1e0',
      '0.499',
      '29.999',
      '+30',
      '.5',
      '30.',
      '60.001',
      '999999999999999999999999999999999999999999999999999999999999999999999',
    ]) {
      expect(
        parsePollingMilliseconds(value, PollingUnit.seconds),
        isNull,
        reason: value,
      );
    }
    expect(formatPollingValue(60001, PollingUnit.seconds), '60.001');
    expect(formatPollingValue(-1000, PollingUnit.seconds), '-1');
  });

  test('legacy canonical display clamps read-only and preserves every DTO field', () async {
    expect(AppSettings.defaults().pollIntervalMs, 30000);
    for (final raw in [
      BigInt.zero, BigInt.from(500), BigInt.from(1000), BigInt.from(3000),
      BigInt.from(29999), BigInt.from(30000), BigInt.from(30001),
      BigInt.from(59999), BigInt.from(60000), BigInt.from(60001),
      BigInt.parse('18446744073709551615'),
    ]) {
      final fixture = SettingsFixture(30000);
      try {
        final old = fixture.api.config;
        fixture.api.config = ConfigDto(
          pollIntervalMs: raw,
          idleThresholdMinutes: old.idleThresholdMinutes,
          minimizeToTray: old.minimizeToTray,
          startMinimized: old.startMinimized,
          autoStartTracking: old.autoStartTracking,
          excludedApps: old.excludedApps,
          dbPath: old.dbPath,
        );
        final original = fixture.api.config;
        final loaded = await fixture.container.read(settingsProvider.future);
        final effective = raw < BigInt.from(30000) ? 30000
            : raw > BigInt.from(60000) ? 60000 : raw.toInt();
        expect(loaded.pollIntervalMs, effective, reason: '$raw');
        expect(loaded.idleThresholdMinutes, old.idleThresholdMinutes.toInt());
        expect(loaded.minimizeToTray, old.minimizeToTray);
        expect(loaded.startMinimized, old.startMinimized);
        expect(loaded.autoStartTracking, old.autoStartTracking);
        expect(loaded.excludedApps, old.excludedApps);
        expect(loaded.dbPath, old.dbPath);
        expect(fixture.api.config, same(original));
        expect(fixture.api.reads, 1);
        expect(fixture.api.writes, 0);
        expect(fixture.api.unexpected, 0);
        expect(fixture.keys.reads, 0);
        expect(fixture.keys.writes, 0);
        expect(fixture.background.pickerCalls, 0);
      } finally {
        fixture.container.dispose();
      }
    }
  });

  test('strict apply save retry reject new invalid canonical before any API call', () async {
    final fixture = SettingsFixture(30000);
    addTearDown(fixture.container.dispose);
    final original = await fixture.container.read(settingsProvider.future);
    final notifier = fixture.container.read(settingsProvider.notifier);
    for (final ms in [-1, 0, 500, 1000, 3000, 29999, 60001]) {
      final invalid = original.copyWith(pollIntervalMs: ms);
      await expectLater(notifier.apply(invalid), throwsArgumentError);
      expect(fixture.container.read(settingsProvider).value, original);
      expect(fixture.container.read(settingsWriteFeedbackProvider), isNull);
      expect(fixture.api.reads, 1);
      expect(fixture.api.writes, 0);
    }
    notifier.preview(original.copyWith(pollIntervalMs: 29999));
    await expectLater(notifier.save(), throwsArgumentError);
    final failed = fixture.container.read(settingsWriteFeedbackProvider)!;
    expect(failed.failed, true);
    expect(failed.verified, false);
    expect(failed.target.pollIntervalMs, 29999);
    await expectLater(notifier.retry(), throwsArgumentError);
    final retried = fixture.container.read(settingsWriteFeedbackProvider)!;
    expect(retried.id, failed.id);
    expect(retried.target, failed.target);
    expect(retried.failed, true);
    expect(fixture.api.reads, 1);
    expect(fixture.api.writes, 0);
    notifier.preview(original);
    final target = original.copyWith(pollIntervalMs: 45000);
    await notifier.apply(target);
    expect(fixture.api.writes, 1);
    expect(fixture.api.reads, 2);
    expect(fixture.api.config.pollIntervalMs, BigInt.from(45000));
    expect(fixture.api.config.idleThresholdMinutes, BigInt.from(original.idleThresholdMinutes));
    expect(fixture.api.config.minimizeToTray, original.minimizeToTray);
    expect(fixture.api.config.startMinimized, original.startMinimized);
    expect(fixture.api.config.autoStartTracking, original.autoStartTracking);
    expect(fixture.api.config.excludedApps, original.excludedApps);
    expect(fixture.api.config.dbPath, original.dbPath);
    expect(fixture.container.read(settingsWriteFeedbackProvider)!.verified, true);
    expect(fixture.api.unexpected, 0);
    expect(fixture.api.pauseWrites, 0);
    expect(fixture.api.startupWrites, 0);
    expect(fixture.keys.reads, 0);
    expect(fixture.keys.writes, 0);
  });

  testWidgets('invalid lower draft refuses unit switch; valid unit draft waits for Enter', (tester) async {
    final fixture = SettingsFixture(500);
    addTearDown(fixture.container.dispose);
    await tester.pumpWidget(fixture.host(1));
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('settings_poll_value'));
    final unit = find.byKey(const Key('settings_poll_unit'));
    await reveal(tester, input);
    final controller = tester.widget<TextField>(input).controller!;
    expect(controller.text, '30');
    await tester.enterText(input, '29.999');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).decoration!.errorText, '请输入 30–60 秒或 0.5–1 分钟');
    await tester.tap(unit);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '分钟'));
    await tester.pumpAndSettle();
    expect(controller.text, '29.999');
    expect(tester.widget<TextField>(input).controller, same(controller));
    expect(tester.widget<TextField>(input).decoration!.errorText, '先修正数值，再切换单位');
    expect(fixture.api.writes, 0);
    expect(fixture.api.config.pollIntervalMs, BigInt.from(500));
    await tester.enterText(input, '45');
    await tester.tap(unit);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '分钟'));
    await tester.pumpAndSettle();
    expect(controller.text, '0.75');
    expect(tester.widget<TextField>(input).decoration!.errorText, isNull);
    expect(fixture.api.writes, 0);
    expect(fixture.container.read(settingsProvider).value!.pollIntervalMs, 30000);
    await tester.showKeyboard(input);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fixture.api.config.pollIntervalMs, BigInt.from(45000));
    expect(fixture.api.writes, 1);
    expect(fixture.container.read(settingsWriteFeedbackProvider)!.verified, true);
    fixture.expectSafe();
    expect(tester.takeException(), isNull);
  });
}
