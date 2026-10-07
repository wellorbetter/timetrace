import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/safe_cache_service.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import 'package:timetrace_app/src/features/settings/presentation/local_storage_information.dart';

Map<String, Object> quote() => {
  'schemaVersion': 2,
  'day': '2026-10-05',
  'text': '古诗',
  'source': '来源',
  'online': false,
  'author': '作者',
  'work': '作品',
  'dynasty': '唐',
  'fullContent': ['古诗全文'],
  'sourceUrl': 'https://example.invalid/public-poem',
};
void main() {
  testWidgets(
    'visible typed confirmation cancel is zero write and ACK clears only quote',
    (tester) async {
      tester.view.physicalSize = const Size(280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = {
        'version': 1,
        'dailyQuoteV2': quote(),
        'unknown': {'keep': 1},
      };
      final backend = MemoryPreferencesBackend(jsonEncode(root));
      var openerCalls = 0;
      final container = ProviderContainer(
        overrides: [uiPreferencesBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                child: SingleChildScrollView(
                  child: LocalStorageInformation(
                    resolve: () => const LocalStorageLocations(
                      appData: r'C:\synthetic',
                      localAppData: r'D:\synthetic',
                    ),
                    openFolder: (_) async {
                      openerCalls++;
                      throw StateError('forbidden opener');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final clear = find.byKey(const Key('safe_cache_clear'));
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(backend.commits, 0);
      expect(container.read(safeCacheEpochProvider), 0);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('confirm_safe_cache_clear'));
      expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(backend.commits, 1);
      expect(container.read(safeCacheEpochProvider), 1);
      expect(jsonDecode(backend.files[backend.canonicalPath]!), {
        'version': 1,
        'unknown': {'keep': 1},
      });
      expect(openerCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'typed CAS clear preserves every unrelated asset and advances epoch only after ACK',
    () {
      final root = {
        'version': 1,
        'dailyQuoteV2': quote(),
        'unknown': {
          'nested': [1, 2],
        },
        'workspaceLayoutV3': {'keep': true},
        'tasks': ['durable'],
        'diary': ['durable'],
      };
      final backend = MemoryPreferencesBackend(jsonEncode(root));
      final container = ProviderContainer(
        overrides: [uiPreferencesBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      final service = container.read(safeCacheServiceProvider);
      final ticket = service.capture(SafeCacheScope.dailyQuoteV2)!;
      expect(service.clear(ticket, confirmed: false), isNull);
      expect(backend.commits, 0);
      backend.faults.add('commit');
      expect(
        service.clear(ticket, confirmed: true)!.status,
        UiPreferencesOperationStatus.failed,
      );
      expect(container.read(safeCacheEpochProvider), 0);
      expect(jsonDecode(backend.files[backend.canonicalPath]!), root);
      backend.faults.clear();
      expect(
        service.clear(ticket, confirmed: true)!.status,
        UiPreferencesOperationStatus.verifiedAck,
      );
      final expected = Map.of(root)..remove('dailyQuoteV2');
      expect(jsonDecode(backend.files[backend.canonicalPath]!), expected);
      expect(container.read(safeCacheEpochProvider), 1);
      expect(service.clear(ticket, confirmed: true), isNull);
      expect(service.capture(SafeCacheScope.dailyQuoteV2), isNull);
      expect(container.read(safeCacheEpochProvider), 1);
    },
  );
  test('quote changed after confirmation snapshot is never deleted', () {
    final backend = MemoryPreferencesBackend(
      jsonEncode({'version': 1, 'dailyQuoteV2': quote()}),
    );
    final container = ProviderContainer(
      overrides: [uiPreferencesBackendProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    final service = container.read(safeCacheServiceProvider);
    final ticket = service.capture(SafeCacheScope.dailyQuoteV2)!;
    final replacement = quote()..['day'] = '2026-10-06';
    final bytes = jsonEncode({'version': 1, 'dailyQuoteV2': replacement});
    backend.files[backend.canonicalPath] = bytes;
    expect(
      service.clear(ticket, confirmed: true)!.status,
      UiPreferencesOperationStatus.failed,
    );
    expect(backend.files[backend.canonicalPath], bytes);
    expect(backend.commits, 0);
    expect(container.read(safeCacheEpochProvider), 0);
  });
  for (final invalid in [
    null,
    {'schemaVersion': 3},
    quote()..['extra'] = 'future',
    quote()..['day'] = '2026-02-30',
    quote()..['fullContent'] = [],
    quote()..['text'] = 'not in poem',
  ]) {
    test('absent future corrupt cache refuses removal $invalid', () {
      final bytes = jsonEncode({
        'version': 1,
        if (invalid != null) 'dailyQuoteV2': invalid,
      });
      final backend = MemoryPreferencesBackend(bytes);
      final container = ProviderContainer(
        overrides: [uiPreferencesBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      expect(
        container
            .read(safeCacheServiceProvider)
            .capture(SafeCacheScope.dailyQuoteV2),
        isNull,
      );
      expect(backend.files[backend.canonicalPath], bytes);
      expect(backend.commits, 0);
      expect(container.read(safeCacheEpochProvider), 0);
    });
  }
}
