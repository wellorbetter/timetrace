import 'dart:async';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import '../dashboard/diary_entry_metadata_test.dart'
    show MemoryDiaryMetadataStore, MemoryMetadataCandidates;

const empty = CalendarData(
  images: {},
  entryImages: {},
  diaryDays: {},
  entries: [],
);

class FakeApi implements TimeTraceApi {
  final calls = <String>[];
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected synthetic API method');
  @override
  List<(String, int?, String)> getDiaryImagesDetailed({
    required String start,
    required String end,
  }) {
    calls.add('images:$start:$end');
    return [
      ('2026-01-01', 5, 'synthetic-linked'),
      ('2026-02-01', null, 'synthetic-staged'),
    ];
  }

  @override
  List<(String, String)> getDiaryEntries({
    required String start,
    required String end,
  }) {
    calls.add('marks:$start:$end');
    return [('2026-01-01', 'text'), ('2026-03-01', '')];
  }

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) {
    calls.add('entries:$start:$end');
    return [
      const DiaryEntryDto(
        id: 999,
        date: '2026-01-01',
        content: 'draft',
        status: 'draft',
      ),
      for (var i = 0; i < 103; i++)
        DiaryEntryDto(
          id: i,
          date: '2026-01-01',
          content: 'synthetic',
          status: 'published',
        ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'loader API identity change supersedes in-flight year and queued disposal is safe',
    (tester) async {
      final old = Completer<CalendarData>();
      var nextReads = 0;
      final c = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          calendarYearClockProvider.overrideWithValue(() => DateTime(2026)),
          calendarDataLoaderProvider.overrideWithValue((_) => old.future),
        ],
      );
      final sub = c.listen(calendarDataProvider, (_, _) {});
      await tester.pump();
      c.updateOverrides([
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        calendarYearClockProvider.overrideWithValue(() => DateTime(2026)),
        calendarDataLoaderProvider.overrideWithValue((_) {
          nextReads++;
          return empty;
        }),
      ]);
      c.read(calendarDataProvider);
      await tester.pump();
      expect(nextReads, 1);
      old.complete(
        const CalendarData(
          images: {
            'late': ['synthetic'],
          },
          entryImages: {},
          diaryDays: {},
          entries: [],
        ),
      );
      await tester.pump();
      expect(c.read(calendarDataProvider).requireValue, same(empty));
      sub.close();
      c.dispose();
      final other = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          calendarYearClockProvider.overrideWithValue(() => DateTime(2026)),
          calendarDataLoaderProvider.overrideWithValue((_) => empty),
        ],
      );
      final watch = other.listen(calendarDataProvider, (_, _) {});
      watch.close();
      other.dispose();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  test('default three annual calls, markers images published cap remain', () {
    final api = FakeApi(), data = loadCalendarYear(FakeApi(), 2026);
    final own = loadCalendarYear(api, 2026);
    expect(api.calls, [
      'images:2026-01-01:2026-12-31',
      'marks:2026-01-01:2026-12-31',
      'entries:2026-01-01:2026-12-31',
    ]);
    expect(own.entries.length, 100);
    expect(own.entries.every((e) => e.status == 'published'), isTrue);
    expect(own.diaryDays, {'2026-01-01'});
    expect(own.entryImages[5], ['synthetic-linked']);
    expect(data.images['2026-02-01'], ['synthetic-staged']);
  });
  testWidgets(
    'same-year route reattach shares flight, explicit invalidate and year reject late',
    (tester) async {
      var now = DateTime(2026, 10, 3);
      final req = <(int, Completer<CalendarData>)>[];
      final c = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          calendarYearClockProvider.overrideWithValue(() => now),
          calendarDataLoaderProvider.overrideWithValue((year) {
            final d = Completer<CalendarData>();
            req.add((year, d));
            return d.future;
          }),
        ],
      );
      var sub = c.listen(calendarDataProvider, (_, _) {});
      await tester.pump();
      expect(req.length, 1);
      sub.close();
      await tester.pump();
      sub = c.listen(calendarDataProvider, (_, _) {});
      await tester.pump();
      expect(req.length, 1);
      c.invalidate(calendarDataProvider);
      c.read(calendarDataProvider);
      await tester.pump();
      expect(req.length, 2);
      req[0].$2.complete(
        const CalendarData(
          images: {
            'old': ['synthetic'],
          },
          entryImages: {},
          diaryDays: {},
          entries: [],
        ),
      );
      await tester.pump();
      expect(c.read(calendarDataProvider).isLoading, isTrue);
      req[1].$2.complete(empty);
      await tester.pump();
      expect(c.read(calendarDataProvider).requireValue, same(empty));
      sub.close();
      await tester.pump();
      sub = c.listen(calendarDataProvider, (_, _) {});
      await tester.pump();
      expect(req.length, 2);
      now = DateTime(2027);
      await tester.pump(const Duration(seconds: 30));
      expect(req.last.$1, 2027);
      req[2].$2.completeError(StateError('synthetic-fail'));
      await tester.pump();
      expect(c.read(calendarDataProvider).hasError, isTrue);
      c.invalidate(calendarDataProvider);
      c.read(calendarDataProvider);
      await tester.pump();
      expect(req.length, 4);
      req[3].$2.complete(empty);
      await tester.pump();
      expect(c.read(calendarDataProvider).hasValue, isTrue);
      sub.close();
      c.dispose();
    },
  );
  testWidgets(
    'batch persisted dates invalidates annual once and dispose cancels pending',
    (tester) async {
      var loads = 0;
      final api = FakeApi();
      final c = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          apiProvider.overrideWithValue(api),
          diaryEntryMetadataStoreProvider.overrideWithValue(
            MemoryDiaryMetadataStore(),
          ),
          diaryCandidateRepositoryProvider.overrideWithValue(
            MemoryMetadataCandidates(),
          ),
          calendarYearClockProvider.overrideWithValue(() => DateTime(2026)),
          dataRefreshPolicyProvider.overrideWithValue(
            const DataRefreshPolicy(interval: Duration.zero),
          ),
          calendarDataLoaderProvider.overrideWithValue((_) {
            loads++;
            return empty;
          }),
        ],
      );
      final sub = c.listen(calendarDataProvider, (_, _) {});
      await tester.pump();
      final store = c.read(diaryComposerStoreProvider);
      store.onPersisted!('2026-10-01');
      store.onPersisted!('2026-10-02');
      await tester.pump(const Duration(milliseconds: 249));
      expect(loads, 1);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(loads, 2);
      store.onPersisted!('2026-10-03');
      sub.close();
      c.dispose();
      await tester.pump(const Duration(milliseconds: 300));
      expect(loads, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
