import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/features/settings/presentation/local_storage_information.dart';
import 'package:timetrace_app/src/core/preferences/local_storage_folder_action.dart';
import 'package:timetrace_app/src/core/preferences/local_storage_paths.dart';
import 'package:timetrace_app/src/core/preferences/safe_cache_service.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';

void main() {
  folderActionWidgetTests();
  for (final brightness in Brightness.values) {
    testWidgets('pure storage paths wrap scale2 $brightness without IO', (
      tester,
    ) async {
      var resolves = 0;
      final opened = <String>[];
      final scheme = ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      );
      final policy = MaterialPolicy.resolve(
        colorScheme: scheme,
        wallpaper: WallpaperLoadState.absent,
        signals: const MaterialSignals(
          highContrast: AccessibilitySignal.disabled,
          reduceTransparency: AccessibilitySignal.enabled,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: MaterialScope(
                policy: policy,
                tokens: MaterialTokens.forWidth(280),
                child: SizedBox(
                  width: 280,
                  child: SingleChildScrollView(
                    child: MaterialCard(
                      child: LocalStorageInformation(
                        openFolder: (path) async {
                          opened.add(path);
                        },
                        resolve: () {
                          resolves++;
                          return const LocalStorageLocations(
                            appData: r'C:\synthetic\roaming',
                            localAppData: r'D:\synthetic\local',
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(resolves, 1);
      expect(
        find.text(r'C:\synthetic\roaming\TimeTrace\ui_config.json'),
        findsNothing,
      );
      expect(
        find.text(r'D:\synthetic\local\TimeTrace\diary-candidates-v1'),
        findsNothing,
      );
      expect(find.byType(MaterialCard), findsOneWidget);
      expect(
        find.text(r'D:\synthetic\local\TimeTrace\diary-draft-tags-v1'),
        findsNothing,
      );
      expect(find.text('草稿标签与发表凭据'), findsOneWidget);
      expect(find.textContaining('不是每日缓存'), findsOneWidget);
      final folder = find.byKey(const ValueKey('storage_folder_0'));
      await tester.ensureVisible(folder);
      await tester.pumpAndSettle();
      expect(tester.getSize(folder).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(folder).width, greaterThanOrEqualTo(48));
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect(opened, [r'C:\synthetic\roaming\TimeTrace']);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final base in [null, '', 'relative', 'C:relative', 'bad\u0000path']) {
    test('invalid base never invents path $base', () {
      final locations = LocalStorageLocations(
        appData: base,
        localAppData: base,
      );
      expect(locations.location(base, 'ui_config.json'), startsWith('位置不可用'));
    });
  }
  test('valid drive and UNC are string only', () {
    const locations = LocalStorageLocations(
      appData: r'\\server\share',
      localAppData: r'C:\local\',
    );
    expect(
      locations.location(locations.appData, 'diary_images'),
      r'\\server\share\TimeTrace\diary_images',
    );
    expect(
      locations.location(locations.localAppData, 'workspace-time-tools-v1'),
      r'C:\local\TimeTrace\workspace-time-tools-v1',
    );
  });
}


void folderActionWidgetTests() {
  const fixtureLocations = LocalStorageLocations(
    appData: r'\\合成server\共享 空格',
    localAppData: r'C:\合成 local',
  );
  Widget surface({FolderAction? action, Future<void> Function(String)? legacy,
      SafeCacheService? cache}) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: LocalStorageInformation(
      resolve: () => fixtureLocations,
      folderAction: action,
      openFolder: legacy,
      cacheService: cache,
    ))),
  );
  Future<void> click(WidgetTester tester, int index) async {
    final button = find.byKey(ValueKey('storage_folder_$index'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('all six legacy targets are exact with zero typed service calls', (tester) async {
    final paths = <String>[];
    final forbidden = _FolderFake((_) async => throw StateError('forbidden typed IO'));
    await tester.pumpWidget(surface(action: forbidden, legacy: (path) async {
      paths.add(path);
    }));
    expect(paths, isEmpty);
    expect(forbidden.paths, isEmpty);
    for (var index = 0; index < 6; index++) {
      await click(tester, index);
    }
    expect(paths, [
      r'\\合成server\共享 空格\TimeTrace',
      r'C:\合成 local\TimeTrace\workspace-time-tools-v1',
      r'C:\合成 local\TimeTrace\diary-candidates-v1',
      r'C:\合成 local\TimeTrace\diary-entry-metadata-v1',
      r'C:\合成 local\TimeTrace\diary-draft-tags-v1',
      r'\\合成server\共享 空格\TimeTrace\diary_images',
    ]);
    expect(forbidden.paths, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('typed service also receives all six exact targets only on click', (tester) async {
    final action = _FolderFake((_) async => const FolderActionResult(
      FolderActionStatus.accepted, stage: FolderActionStage.request));
    await tester.pumpWidget(surface(action: action));
    expect(action.paths, isEmpty);
    for (var index = 0; index < 6; index++) {
      await click(tester, index);
    }
    expect(action.paths, [
      r'\\合成server\共享 空格\TimeTrace',
      r'C:\合成 local\TimeTrace\workspace-time-tools-v1',
      r'C:\合成 local\TimeTrace\diary-candidates-v1',
      r'C:\合成 local\TimeTrace\diary-entry-metadata-v1',
      r'C:\合成 local\TimeTrace\diary-draft-tags-v1',
      r'\\合成server\共享 空格\TimeTrace\diary_images',
    ]);
  });
  for (final status in FolderActionStatus.values) {
    testWidgets('typed status $status has private-safe honest feedback', (tester) async {
      final action = _FolderFake((_) async => FolderActionResult(
        status, stage: FolderActionStage.request, nativeCode: 999));
      await tester.pumpWidget(surface(action: action));
      await click(tester, 0);
      final text = tester.widget<Text>(find.byKey(const Key('storage_folder_feedback'))).data!;
      final original = switch (status) {
        FolderActionStatus.accepted => '文件夹打开请求已发送。',
        FolderActionStatus.missing => '尚无存储目录；未修改任何数据。',
        FolderActionStatus.inaccessible => '无法访问存储目录；未修改任何数据，可重试。',
        FolderActionStatus.requestFailed => '文件夹打开请求失败；未修改任何数据，可重试。',
        FolderActionStatus.unsupported => '当前系统不支持打开存储文件夹；未修改任何数据。',
      };
      expect(text, status == FolderActionStatus.accepted ? original
        : '$original 阶段：系统打开请求；错误码：999。');
      expect(text, isNot(contains('合成')));
      expect(text, status == FolderActionStatus.accepted
        ? isNot(contains('999')) : contains('999'));
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('storage_folder_0'))).onPressed, isNotNull);
    });
  }
  for (final stage in FolderActionStage.values) {
    testWidgets('failure exposes only stage/code and cleanup marker $stage', (tester) async {
      final action = _FolderFake((_) async => FolderActionResult(
        FolderActionStatus.requestFailed, stage: stage, nativeCode: -2147417850,
        cleanupFailed: true));
      await tester.pumpWidget(surface(action: action));
      await click(tester, 0);
      final text = tester.widget<Text>(
        find.byKey(const Key('storage_folder_feedback'))).data!;
      expect(text, contains(storageFolderFailureDetails(FolderActionResult(
        FolderActionStatus.requestFailed, stage: stage, nativeCode: -2147417850,
        cleanupFailed: true))));
      expect(text, contains('-2147417850'));
      expect(text, contains('资源释放未能确认'));
      expect(text, isNot(contains('合成server')));
      expect(text, isNot(contains('共享 空格')));
      expect(text, isNot(contains('PRIVATE')));
      expect(action.paths, [r'\\合成server\共享 空格\TimeTrace']);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('missing folder is truthful, no fallback or creation and cache explanation visible',
      (tester) async {
    final action = _FolderFake((_) async => const FolderActionResult(
      FolderActionStatus.missing, stage: FolderActionStage.probe, nativeCode: 3));
    await tester.pumpWidget(surface(action: action));
    expect(find.textContaining('配置 ui_config.json'), findsOneWidget);
    expect(find.textContaining('不是独立诗词历史'), findsOneWidget);
    await click(tester, 0);
    expect(action.paths, [r'\\合成server\共享 空格\TimeTrace']);
    expect(find.textContaining('尚无存储目录'), findsOneWidget);
    expect(find.textContaining('目录访问检查'), findsOneWidget);
    expect(find.textContaining('错误码：3'), findsOneWidget);
    expect(find.text('文件夹打开请求已发送。'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  test('all six pure folder targets preserve drives/UNC/trailing separators', () {
    for (final base in [r'C:\合成 空格\', r'\\合成server\共享 空格\', 'D:/synthetic/']) {
      final root = base.replaceFirst(RegExp(r'[\\/]+$'), '');
      expect(timeTraceStorageFolderLocation(base, 'ui_config.json'), '$root\\TimeTrace');
      for (final suffix in ['workspace-time-tools-v1', 'diary-candidates-v1',
          'diary-entry-metadata-v1', diaryDraftTagsAssetSuffix, 'diary_images']) {
        expect(timeTraceStorageFolderLocation(base, suffix), '$root\\TimeTrace\\$suffix');
      }
    }
    for (final base in [null, '', 'relative', 'C:relative', 'C:\\bad\u0000']) {
      expect(timeTraceStorageFolderLocation(base, 'ui_config.json'), isNull);
    }
    for (final suffix in ['', '.', '..', r'..\escape', 'bad\u0000']) {
      expect(timeTraceStorageFolderLocation(r'C:\synthetic', suffix), isNull);
    }
  });
  for (final legacy in [true, false]) {
    testWidgets('pending request guards even stale repeat callback $legacy', (tester) async {
      final pending = Completer<FolderActionResult>();
      var calls = 0;
      final action = _FolderFake((_) { calls++; return pending.future; });
      await tester.pumpWidget(surface(
        action: action,
        legacy: legacy ? (_) async { calls++; await pending.future; } : null,
      ));
      final button = find.byKey(const ValueKey('storage_folder_0'));
      final stale = tester.widget<IconButton>(button).onPressed!;
      stale();
      stale();
      await tester.pump();
      expect(calls, 1);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(tester.widget<TextButton>(find.byKey(const Key('safe_cache_clear'))).onPressed, isNull);
      pending.complete(const FolderActionResult(
        FolderActionStatus.accepted, stage: FolderActionStage.request));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      expect(calls, 1);
      if (legacy) expect(action.paths, isEmpty);
    });
  }
  testWidgets('failure then accepted clears only folder failure and preserves cache feedback', (tester) async {
    final cache = _NoCacheService();
    var attempts = 0;
    final action = _FolderFake((_) async => FolderActionResult(
      ++attempts == 1 ? FolderActionStatus.requestFailed : FolderActionStatus.accepted,
      stage: FolderActionStage.request));
    await tester.pumpWidget(surface(action: action, cache: cache));
    final clear = find.byKey(const Key('safe_cache_clear'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    final originalCacheText = tester.widget<Text>(find.byKey(const Key('safe_cache_feedback'))).data;
    expect(originalCacheText, '没有可安全清理的已知诗词缓存；未修改任何数据。');
    await click(tester, 0);
    expect(find.textContaining('文件夹打开请求失败'), findsOneWidget);
    await click(tester, 0);
    expect(find.textContaining('文件夹打开请求失败'), findsNothing);
    expect(find.text('文件夹打开请求已发送。'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('safe_cache_feedback'))).data, originalCacheText);
    expect(cache.captures, 1);
    expect(cache.clears, 0);
  });
  for (final legacy in [true, false]) {
    testWidgets('throwing request is sanitized and guard resets $legacy', (tester) async {
      var calls = 0;
      Future<FolderActionResult> throwing(String _) async {
        calls++;
        throw StateError('PRIVATE-PATH-AND-CONTENT');
      }
      await tester.pumpWidget(surface(
        action: _FolderFake(throwing),
        legacy: legacy ? (path) async { await throwing(path); } : null,
      ));
      await click(tester, 0);
      await click(tester, 0);
      expect(calls, 2);
      expect(find.textContaining('PRIVATE-PATH'), findsNothing);
      expect(find.textContaining('文件夹打开请求失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    for (final throws in [false, true]) {
      testWidgets('late completion after disposal is safe $legacy $throws', (tester) async {
        final pending = Completer<FolderActionResult>();
        final action = _FolderFake((_) => pending.future);
        await tester.pumpWidget(surface(
          action: action,
          legacy: legacy ? (_) async { await pending.future; } : null,
        ));
        await tester.tap(find.byKey(const ValueKey('storage_folder_0')));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        if (throws) {
          pending.completeError(StateError('PRIVATE late completion'));
        } else {
          pending.complete(const FolderActionResult(
            FolderActionStatus.accepted, stage: FolderActionStage.request));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

class _FolderFake implements FolderAction {
  _FolderFake(this.operation);
  final Future<FolderActionResult> Function(String) operation;
  final paths = <String>[];
  @override
  Future<FolderActionResult> open(String directory) {
    paths.add(directory);
    return operation(directory);
  }
}

class _NoCacheService extends SafeCacheService {
  _NoCacheService() : super(controller: UiPreferencesController(), onVerifiedClear: _ignore);
  int captures = 0, clears = 0;
  static void _ignore() {}
  @override
  SafeCacheTicket? capture(SafeCacheScope scope) {
    captures++;
    return null;
  }
  @override
  UiPreferencesOperation? clear(SafeCacheTicket ticket, {required bool confirmed}) {
    clears++;
    throw StateError('forbidden fake cache write');
  }
}
