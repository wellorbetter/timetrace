import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/preferences/local_storage_folder_action.dart';
import 'package:timetrace_app/src/features/settings/data/settings_export_service.dart';
import 'package:timetrace_app/src/features/settings/presentation/settings_screen.dart';
import 'package:timetrace_app/src/features/settings/presentation/local_storage_information.dart';
import 'settings_polling_sections_test.dart' show SettingsFixture;

// Every callback is explicit memory. The public SettingsFixture supplies memory
// config/preferences/theme/feed/Key and native picker/API traps; no main app.
const target = r'C:\合成 空格\TimeTrace\export.csv';
const csv = 'schema_version,integrity,state,seconds\nv1,partial,unknown,61\n';
DateTime fixtureClock() => DateTime.utc(2026, 10, 8);

void main() {
  test('one flight includes delayed query, delayed write and stale/reentrant calls', () async {
    final queryGate = Completer<String>(), writeGate = Completer<void>();
    var queries = 0, writes = 0, locations = 0, clocks = 0;
    Future<SettingsExportResult>? nested;
    late SettingsExportService service;
    service = SettingsExportService(
      location: () { locations++; return target; },
      clock: () { clocks++; return fixtureClock(); },
      query: ({required start, required end}) {
        queries++;
        expect(start, '2026-10-01'); expect(end, '2026-10-08');
        nested = service.export();
        return queryGate.future;
      },
      write: (path, data) {
        writes++; expect(path, target); expect(data, csv);
        return writeGate.future;
      },
    );
    final first = service.export();
    expect(service.export(), same(first));
    expect(nested, same(first));
    expect(service.busy, isTrue);
    expect([queries, writes, locations, clocks], [1, 0, 1, 1]);
    queryGate.complete(csv); await Future<void>.delayed(Duration.zero);
    expect([queries, writes], [1, 1]);
    expect(service.export(), same(first));
    expect(service.busy, isTrue);
    writeGate.complete();
    final result = await first;
    expect(result.status, SettingsExportStatus.success);
    expect(service.busy, isFalse);
    expect([queries, writes, locations, clocks], [1, 1, 1, 1]);
  });

  for (final content in ['header-only-valid-empty\n', csv]) {
    test('successful empty/partial bytes are preserved exactly $content', () async {
      final saved = <String>[];
      final service = SettingsExportService(location: () => target,
        clock: fixtureClock,
        query: ({required start, required end}) async => content,
        write: (path, data) async { expect(path, target); saved.add(data); });
      expect((await service.export()).status, SettingsExportStatus.success);
      expect(saved, [content]);
    });
  }

  for (final path in <String?>[null, '', 'relative', r'C:relative',
      r'C:\safe\..\TimeTrace\export.csv', 'C:\\bad\u0000\\TimeTrace\\export.csv',
      r'C:\safe\TimeTrace\other.csv']) {
    test('invalid target has zero query/write $path', () async {
      var queries = 0, writes = 0, clocks = 0;
      final service = SettingsExportService(location: () => path,
        clock: () { clocks++; return fixtureClock(); },
        query: ({required start, required end}) async { queries++; return csv; },
        write: (_, __) async { writes++; });
      final result = await service.export();
      expect(result.stage, SettingsExportStage.location);
      expect(result.status, SettingsExportStatus.failed);
      expect([queries, writes, clocks], [0, 0, 0]);
      expect(service.busy, isFalse);
    });
  }

  test('drive/UNC target validation is pure and exact', () {
    for (final path in [target, r'\\合成server\共享 空格\TimeTrace\export.csv',
        'D:/synthetic/TimeTrace/export.csv']) {
      expect(isAbsoluteExportTarget(path), isTrue);
    }
  });

  for (final stage in SettingsExportStage.values) {
    test('failure $stage is sanitized, releases guard and permits explicit retry', () async {
      var failing = true, queries = 0, writes = 0;
      final service = SettingsExportService(
        location: () {
          if (failing && stage == SettingsExportStage.location) {
            throw StateError('PRIVATE-PATH-CONTENT');
          }
          return target;
        },
        clock: fixtureClock,
        query: ({required start, required end}) async {
          queries++;
          if (failing && stage == SettingsExportStage.query) {
            throw StateError('PRIVATE-PATH-CONTENT');
          }
          return csv;
        },
        write: (_, data) async {
          writes++;
          if (failing && stage == SettingsExportStage.write) {
            throw StateError('PRIVATE-PATH-CONTENT');
          }
          expect(data, csv);
        },
      );
      final failed = await service.export();
      expect(failed.status, SettingsExportStatus.failed);
      expect(failed.stage, stage);
      expect(failed.feedback, isNot(contains('PRIVATE')));
      expect(service.busy, isFalse);
      expect(queries, stage == SettingsExportStage.location ? 0 : 1);
      expect(writes, stage == SettingsExportStage.write ? 1 : 0);
      failing = false;
      expect((await service.export()).status, SettingsExportStatus.success);
      expect(service.busy, isFalse);
    });
  }

  testWidgets('actual SettingsScreen stays interactive during query/write and guards repeats',
      (tester) async {
    final fixture = SettingsFixture(30000);
    addTearDown(fixture.container.dispose);
    final queryGate = Completer<String>(), writeGate = Completer<void>();
    var queries = 0, writes = 0;
    final service = SettingsExportService(location: () => target, clock: fixtureClock,
      query: ({required start, required end}) { queries++; return queryGate.future; },
      write: (path, data) { writes++; expect(path, target); expect(data, csv);
        return writeGate.future; });
    await tester.pumpWidget(host(fixture, service));
    await tester.pumpAndSettle();
    final export = find.byKey(const Key('settings_export_csv'));
    await tester.ensureVisible(export);
    final callback = tester.widget<ListTile>(export).onTap!;
    callback(); callback(); await tester.pump();
    expect(queries, 1); expect(writes, 0);
    expect(tester.widget<ListTile>(export).onTap, isNull);
    expect(find.byKey(const Key('settings_export_busy')), findsOneWidget);
    // Actual other settings disclosure can be toggled while query is pending.
    final about = find.byKey(const ValueKey('settings_toggle_about'));
    await tester.ensureVisible(about); await tester.tap(about); await tester.pump();
    expect(find.text('TimeTrace v1.0.1 · Rust + Flutter · MIT'), findsNothing);
    expect(find.byKey(const ValueKey('settings_status_data')), findsOneWidget);
    queryGate.complete(csv); await tester.pump();
    expect(writes, 1);
    await tester.tap(about); await tester.pump();
    expect(find.text('TimeTrace v1.0.1 · Rust + Flutter · MIT'), findsOneWidget);
    callback(); await tester.pump(); expect(queries, 1); expect(writes, 1);
    writeGate.complete(); await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(export).onTap, isNotNull);
    expect(find.byKey(const Key('settings_export_busy')), findsNothing);
    expect(find.textContaining('CSV 已导出'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings_status_data')), findsNothing);
    expect(fixture.api.writes, 0); fixture.expectSafe();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  testWidgets('actual settings query failure has visible retry and no file write',
      (tester) async {
    final fixture = SettingsFixture(30000);
    addTearDown(fixture.container.dispose);
    var fail = true, queries = 0, writes = 0;
    final service = SettingsExportService(location: () => target, clock: fixtureClock,
      query: ({required start, required end}) async {
        queries++; if (fail) throw StateError('PRIVATE-QUERY-PATH'); return csv; },
      write: (_, __) async { writes++; });
    await tester.pumpWidget(host(fixture, service)); await tester.pumpAndSettle();
    final export = find.byKey(const Key('settings_export_csv'));
    await tester.ensureVisible(export); await tester.tap(export); await tester.pumpAndSettle();
    expect(queries, 1); expect(writes, 0);
    expect(find.textContaining('导出查询失败'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(find.text('有错误'), findsOneWidget);
    fail = false;
    await tester.tap(export); await tester.pumpAndSettle();
    expect(queries, 2); expect(writes, 1);
    expect(find.textContaining('导出查询失败'), findsNothing);
    expect(find.textContaining('CSV 已导出'), findsOneWidget);
    expect(fixture.api.writes, 0); fixture.expectSafe();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pumpAndSettle();
  });

  for (final afterWrite in [false, true]) {
    for (final throws in [false, true]) {
      testWidgets('unmount suppresses late feedback but does not pretend cancellation $afterWrite/$throws',
          (tester) async {
        final fixture = SettingsFixture(30000);
        addTearDown(fixture.container.dispose);
        final queryGate = Completer<String>(), writeGate = Completer<void>();
        var writes = 0;
        final service = SettingsExportService(location: () => target, clock: fixtureClock,
          query: ({required start, required end}) => queryGate.future,
          write: (_, __) { writes++; return writeGate.future; });
        await tester.pumpWidget(host(fixture, service)); await tester.pumpAndSettle();
        final export = find.byKey(const Key('settings_export_csv'));
        await tester.ensureVisible(export); await tester.tap(export); await tester.pump();
        if (afterWrite) { queryGate.complete(csv); await tester.pump(); expect(writes, 1); }
        await tester.pumpWidget(const SizedBox()); await tester.pump();
        if (afterWrite) {
          if (throws) { writeGate.completeError(StateError('PRIVATE late write')); }
          else { writeGate.complete(); }
        } else {
          if (throws) { queryGate.completeError(StateError('PRIVATE late query')); }
          else { queryGate.complete(csv); await tester.pump(); writeGate.complete(); }
        }
        await tester.pumpAndSettle();
        expect(service.busy, isFalse);
        expect(writes, !afterWrite && throws ? 0 : 1);
        expect(find.byKey(const Key('settings_export_feedback')), findsNothing);
        expect(fixture.api.writes, 0); fixture.expectSafe();
        expect(tester.takeException(), isNull);
      });
    }
  }
}

Widget host(SettingsFixture fixture, SettingsExportService service) =>
  UncontrolledProviderScope(container: fixture.container, child: MaterialApp(
    home: MaterialScope(
      policy: MaterialPolicy.resolve(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        wallpaper: WallpaperLoadState.absent,
        signals: const MaterialSignals(
          highContrast: AccessibilitySignal.disabled,
          reduceTransparency: AccessibilitySignal.disabled)),
      tokens: MaterialTokens.forWidth(360),
      child: SettingsScreen(
        exportService: service,
        storageLocations: () {
          fixture.pathReads++;
          return const LocalStorageLocations(
            appData: r'C:\synthetic\roaming', localAppData: r'C:\synthetic\local');
        },
        storageFolderAction: const ForbiddenFolder(),
        loadExcludedProcesses: () async => const {},
      ),
    ),
  ));

class ForbiddenFolder implements FolderAction {
  const ForbiddenFolder();
  @override
  Future<FolderActionResult> open(String _) async =>
    throw StateError('forbidden native folder action');
}
