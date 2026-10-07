import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';
import 'package:timetrace_app/src/core/widgets/workspace_glyph.dart';
import 'package:timetrace_app/src/features/browsing/data/diary_candidate_repository.dart';
import 'package:timetrace_app/src/features/browsing/domain/diary_candidate.dart';
import 'package:timetrace_app/src/features/browsing/presentation/recap_button.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

DashboardState _dayState(int day) {
  final start = '2026-10-${day.toString().padLeft(2, '0')}T00:00:00Z';
  final end = '2026-10-${(day + 1).toString().padLeft(2, '0')}T00:00:00Z';
  return DashboardState(
    apps: const [],
    appAttribution: const [],
    windows: const [],
    pages: const [],
    hours: const [],
    totalActiveSeconds: 0,
    totalIdleSeconds: 0,
    pausedSeconds: 0,
    privacyExcludedSeconds: 0,
    systemGapSeconds: 0,
    unknownSeconds: 0,
    accountedSeconds: 0,
    integrity: SnapshotIntegrityDto.complete,
    requestedStartUtc: start,
    requestedEndUtc: end,
    effectiveStartUtc: start,
    effectiveEndUtc: end,
    observedThroughUtc: end,
  );
}

class _AvailableDashboard extends DashboardNotifier {
  @override
  Future<DashboardState> build() async => _dayState(2);
  void selectDay(int day) => state = AsyncData(_dayState(day));
  void unavailable() =>
      state = AsyncError(StateError('fixture'), StackTrace.empty);
  void loading() => state = const AsyncLoading();
}

class _EnabledAi extends AiEnabledNotifier {
  @override
  bool build() => true;
  @override
  void setEnabled(bool value) => state = value;
}

class _FixtureModel extends DeepSeekModelNotifier {
  @override
  String build() => 'fixture-model';
}

class _Requests {
  final pending = <Completer<String>>[];
  final summaries = <String>[];
  Future<String> call({
    required String key,
    required String model,
    required String summary,
  }) {
    expect(key, 'fixture-key');
    expect(model, 'fixture-model');
    summaries.add(summary);
    final completer = Completer<String>();
    pending.add(completer);
    return completer.future;
  }
}

class _MemoryApi implements TimeTraceApi {
  final drafts = <String, String>{'2026-10-02': '已有草稿，不能覆盖'};
  final entries = <DiaryEntryDto>[
    const DiaryEntryDto(
      id: 1,
      date: '2026-10-02',
      content: '已有草稿，不能覆盖',
      status: 'draft',
    ),
  ];
  final savedDates = <String>[];
  bool failSave = false;
  bool appendThenThrow = false;
  bool failVerification = false;
  bool throwVerification = false;
  int appendCalls = 0;
  int verificationReads = 0;
  final verificationDates = <(String, String)>[];

  @override
  int addDiaryEntry({required String date, required String content}) {
    appendCalls++;
    if (failSave) throw StateError('fixture write failure');
    final id = entries.length + 10;
    entries.add(
      DiaryEntryDto(id: id, date: date, content: content, status: 'published'),
    );
    savedDates.add(date);
    if (appendThenThrow) throw StateError('fixture committed before returning');
    return id;
  }

  @override
  List<DiaryEntryDto> getDiaryEntriesDetailed({
    required String start,
    required String end,
  }) {
    verificationReads++;
    verificationDates.add((start, end));
    if (throwVerification) throw StateError('fixture verification failure');
    if (failVerification) return [];
    return entries
        .where(
          (entry) =>
              entry.date.compareTo(start) >= 0 &&
              entry.date.compareTo(end) <= 0,
        )
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected API access: ${invocation.memberName}');
}

class _MemoryRepository implements DiaryCandidateRepository {
  final documents = <String, Map<String, dynamic>>{};
  bool failWrites = false;
  bool failReads = false;
  CandidatePublishStatus? failStatus;
  Completer<CandidateLoad>? pendingLoad;
  int nextId = 0;
  int nextTime = 0;
  int puts = 0;
  int loads = 0;
  String id() => 'candidate-${++nextId}';
  DateTime clock() => DateTime.utc(2026, 10, 3, 12, 0, nextTime++);
  @override
  Future<CandidateLoad> load() async {
    loads++;
    if (failReads) throw StateError('fixture read failure');
    final pending = pendingLoad;
    if (pending != null) return pending.future;
    return CandidateLoad(
      documents.values.map(DiaryCandidate.fromJson).toList(),
    );
  }

  @override
  Future<void> put(DiaryCandidate candidate) async {
    puts++;
    if (failWrites || candidate.publishStatus == failStatus) {
      throw StateError('fixture storage failure');
    }
    final previous = documents[candidate.id];
    if (previous == null ||
        (previous['revision'] as int) <= candidate.revision) {
      documents[candidate.id] = candidate.toJson();
    }
  }
}

// Synthetic immutable commits mirror the file repository's occupied-revision
// rule, including damaged evidence. Both awaits are explicitly controlled.
class _InterleavedRepository extends _MemoryRepository {
  final revisions = <(String, int), String>{};
  Completer<void>? pendingPut;
  CandidatePublishStatus? pauseStatus;
  int? pauseRevision;
  bool failPausedPut = false;
  bool _paused = false;

  void damage(DiaryCandidate candidate, int revision) {
    revisions[(candidate.id, revision)] = '{fixture damaged revision';
  }

  @override
  Future<CandidateLoad> load() async {
    if (pendingLoad != null) return super.load();
    final loaded = await super.load();
    var hasIssue = false;
    final candidates = loaded.candidates.map((candidate) {
      final highest = revisions.keys
          .where((key) => key.$1 == candidate.id)
          .map((key) => key.$2)
          .fold(candidate.revision, (a, b) => a > b ? a : b);
      if (highest == candidate.revision) return candidate;
      hasIssue = true;
      return candidate.copyWith(
        revision: highest,
        recoveryBlocked: true,
        publishStatus: CandidatePublishStatus.unknown,
        storageError: 'fixture damaged history',
      );
    }).toList();
    return CandidateLoad(candidates, hasRecoveryIssue: hasIssue);
  }

  @override
  Future<void> put(DiaryCandidate candidate) async {
    if (!_paused &&
        pendingPut != null &&
        candidate.publishStatus == pauseStatus &&
        (pauseRevision == null || candidate.revision == pauseRevision)) {
      _paused = true;
      await pendingPut!.future;
      if (failPausedPut) throw StateError('fixture paused write failure');
    }
    final key = (candidate.id, candidate.revision);
    final encoded = jsonEncode(candidate.toJson());
    final existing = revisions[key];
    if (existing != null && existing != encoded) {
      throw StateError('fixture immutable revision collision');
    }
    await super.put(candidate);
    revisions[key] = encoded;
  }
}

class _FileInterleavedRepository extends _MemoryRepository {
  _FileInterleavedRepository(this.root)
    : files = FileDiaryCandidateRepository(directory: () => root);
  final Directory root;
  final FileDiaryCandidateRepository files;
  Completer<void>? receiptPut;
  final receiptStarted = Completer<void>();
  bool _pausedReceipt = false;

  @override
  Future<CandidateLoad> load() => pendingLoad?.future ?? files.load();

  @override
  Future<void> put(DiaryCandidate candidate) async {
    if (!_pausedReceipt &&
        receiptPut != null &&
        candidate.revision == 2 &&
        candidate.publishStatus ==
            CandidatePublishStatus.awaitingVerification) {
      _pausedReceipt = true;
      receiptStarted.complete();
      await receiptPut!.future;
    }
    await files.put(candidate);
  }
}

ProviderContainer _container(
  _Requests requests,
  _MemoryApi api, {
  String key = 'fixture-key',
  _MemoryRepository? repository,
  void Function()? onCalendarLoad,
}) {
  final storage = repository ?? _MemoryRepository();
  final container = ProviderContainer(
    overrides: [
      dashboardProvider.overrideWith(_AvailableDashboard.new),
      deepSeekKeyProvider.overrideWithValue(key),
      aiEnabledProvider.overrideWith(_EnabledAi.new),
      deepSeekModelProvider.overrideWith(_FixtureModel.new),
      diaryRequesterProvider.overrideWithValue(requests.call),
      diaryCandidateRepositoryProvider.overrideWithValue(storage),
      diaryCandidateClockProvider.overrideWithValue(storage.clock),
      diaryCandidateIdProvider.overrideWithValue(storage.id),
      apiProvider.overrideWithValue(api),
      calendarDataProvider.overrideWith((ref) async {
        onCalendarLoad?.call();
        return const CalendarData(
          images: {},
          entryImages: {},
          diaryDays: {},
          entries: [],
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container, {
  int buttons = 1,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < buttons; index++)
                RecapButton(key: ValueKey('recap-$index')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

// All widget waits are bounded; pending progress animations never settle.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _openAi(WidgetTester tester, {int index = 0}) async {
  await _tap(tester, find.byKey(const Key('workspace_recap')).at(index));
}

Future<void> _confirm(WidgetTester tester, {bool cancel = false}) async {
  await _tap(tester, find.byKey(const Key('recap_generate_ai')));
  expect(find.text('发送摘要给 AI 服务？'), findsOneWidget);
  await _tap(tester, find.text(cancel ? '取消' : '生成'));
}

DiaryCandidate _latest(ProviderContainer container) =>
    container.read(diaryCandidatesProvider).ordered.first;
Finder _toggle(ProviderContainer container) =>
    find.byKey(ValueKey('recap_candidate_toggle_${_latest(container).id}'));
Finder _save(ProviderContainer container) =>
    find.byKey(ValueKey('recap_candidate_save_${_latest(container).id}'));
Future<void> _expand(WidgetTester tester, ProviderContainer container) =>
    _tap(tester, _toggle(container));

Future<void> _flush() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<DiaryCandidate> _fixtureCandidate(
  ProviderContainer container, {
  DiaryCandidateSource source = DiaryCandidateSource.ai,
  String content = '原日候选',
}) async {
  final assets = container.read(diaryCandidatesProvider.notifier);
  await assets.ensureLoaded();
  final candidate = assets.add(
    source: source,
    startUtc: '2026-10-02T00:00:00Z',
    endUtc: '2026-10-03T00:00:00Z',
    saveDate: '2026-10-02',
    content: content,
  );
  await _flush();
  return container.read(diaryCandidatesProvider).items[candidate.id]!;
}

void main() {
  testWidgets('AI requires confirmation and cancel sends zero requests', (
    tester,
  ) async {
    final requests = _Requests();
    final api = _MemoryApi();
    final container = _container(requests, api);
    await _mount(tester, container);
    await _openAi(tester);
    expect(requests.pending, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await _confirm(tester, cancel: true);
    expect(requests.pending, isEmpty);
    expect(
      container.read(diaryGenerationProvider).status,
      DiaryGenerationStatus.idle,
    );
    expect(find.byType(MarkdownBody), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending survives closing and a second entry cannot send', (
    tester,
  ) async {
    final requests = _Requests();
    final container = _container(requests, _MemoryApi());
    await _mount(tester, container, buttons: 2);
    await _openAi(tester);
    await _confirm(tester);
    expect(requests.pending, hasLength(1));
    expect(find.byKey(const Key('recap_pending_progress')), findsOneWidget);
    expect(find.byKey(const Key('recap_entry_pending')), findsNWidgets(2));
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('recap_generate_ai')))
          .onPressed,
      isNull,
    );
    await _tap(tester, find.byKey(const Key('workspace_recap')).first);
    expect(find.byKey(const Key('recap_pending_progress')), findsNothing);
    expect(find.byKey(const Key('recap_entry_pending')), findsNWidgets(2));
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('AI 日记生成中')), findsWidgets);
    semantics.dispose();
    await _openAi(tester, index: 1);
    await _tap(tester, find.byKey(const Key('recap_generate_ai')));
    expect(find.byType(AlertDialog), findsNothing);
    expect(requests.pending, hasLength(1));
    // The scope-level guard also rejects concurrent callers outside the widget.
    expect(
      await container
          .read(diaryGenerationProvider.notifier)
          .start(
            startUtc: _dayState(3).requestedStartUtc,
            endUtc: _dayState(3).requestedEndUtc,
            saveDate: '2026-10-03',
            summary: 'second entry',
            key: 'fixture-key',
            model: 'fixture-model',
          ),
      isFalse,
    );
    requests.pending.single.complete('唯一结果');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(requests.pending, hasLength(1));
    expect(container.read(diaryCandidatesProvider).items, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remove button during pending and remount after completion restores result',
    (tester) async {
      final requests = _Requests();
      final container = _container(requests, _MemoryApi());
      await _mount(tester, container);
      await _openAi(tester);
      await _confirm(tester);
      await _mount(tester, container, buttons: 0);
      expect(container.read(diaryGenerationProvider).isPending, isTrue);
      requests.pending.single.complete('## 原日内容\n昨天我记录了这段活动。');
      await tester.pump();
      expect(container.read(diaryGenerationProvider).hasResult, isTrue);
      await _mount(tester, container);
      await _tap(tester, find.byKey(const Key('workspace_recap')));
      expect(container.read(diaryCandidatesProvider).items, hasLength(1));
      expect(
        find.textContaining(container.read(diaryGenerationProvider).rangeLabel),
        findsOneWidget,
      );
      await _tap(tester, _toggle(container));
      expect(find.textContaining('昨天我记录'), findsOneWidget);
      expect(find.textContaining('## 原日内容'), findsNothing);
      expect(requests.pending, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remount during pending stays blocked and handles changed date/loading/key availability',
    (tester) async {
      final requests = _Requests();
      final container = _container(requests, _MemoryApi());
      await _mount(tester, container);
      await _openAi(tester);
      await _confirm(tester);
      await _mount(tester, container, buttons: 0);
      await _mount(tester, container);
      await _openAi(tester);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('recap_generate_ai')))
            .onPressed,
        isNull,
      );
      final dashboard =
          container.read(dashboardProvider.notifier) as _AvailableDashboard;
      dashboard.selectDay(3);
      await tester.pump();
      container.read(aiEnabledProvider.notifier).setEnabled(false);
      dashboard.loading();
      await tester.pump();
      expect(find.byKey(const Key('recap_pending_progress')), findsOneWidget);
      expect(
        find.textContaining(container.read(diaryGenerationProvider).rangeLabel),
        findsOneWidget,
      );
      expect(find.text('正在读取所选范围…'), findsOneWidget);
      dashboard.unavailable();
      await tester.pump();
      expect(find.byKey(const Key('recap_pending_progress')), findsOneWidget);
      expect(find.text('本地数据暂时不可用，请刷新后重试。'), findsOneWidget);
      requests.pending.single.complete('原范围生成内容');
      await tester.pump();
      expect(container.read(diaryCandidatesProvider).items, hasLength(1));
      expect(find.byKey(const Key('recap_entry_pending')), findsNothing);
      expect(requests.pending, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'date change saves AI result to origin and appends without changing draft',
    (tester) async {
      final requests = _Requests();
      final api = _MemoryApi();
      final container = _container(requests, api);
      await _mount(tester, container);
      await _openAi(tester);
      await _confirm(tester);
      (container.read(dashboardProvider.notifier) as _AvailableDashboard)
          .selectDay(3);
      await tester.pump();
      requests.pending.single.complete('原日 AI 日记');
      await tester.pump();
      final record = container.read(diaryGenerationProvider);
      final expectedDate = calFmt(
        DateTime.parse(_dayState(2).requestedStartUtc).toLocal(),
      );
      expect(record.saveDate, expectedDate);
      expect(record.startUtc, _dayState(2).requestedStartUtc);
      expect(find.textContaining(record.rangeLabel), findsOneWidget);
      await _expand(tester, container);
      await _tap(tester, _save(container));
      expect(api.savedDates, [expectedDate]);
      expect(
        api.entries
            .where((entry) => entry.status == 'published')
            .single
            .content,
        '原日 AI 日记',
      );
      expect(
        api.entries.where((entry) => entry.status == 'draft').single.content,
        '已有草稿，不能覆盖',
      );
      expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
      expect(find.text('已保存到日记'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final throwRead in [false, true]) {
    testWidgets(
      'append receipt survives read failure throw=$throwRead and remount retries only verification',
      (tester) async {
        final requests = _Requests();
        final api = _MemoryApi()
          ..failVerification = !throwRead
          ..throwVerification = throwRead;
        var calendarLoads = 0;
        final container = _container(
          requests,
          api,
          onCalendarLoad: () => calendarLoads++,
        );
        final calendarSubscription = container.listen(
          calendarDataProvider,
          (_, _) {},
        );
        addTearDown(calendarSubscription.close);
        await container.read(calendarDataProvider.future);
        final initialCalendarLoads = calendarLoads;
        await _mount(tester, container);
        await _openAi(tester);
        await _confirm(tester);
        requests.pending.single.complete('只新增一次的原日结果');
        await tester.pump();
        final generation = container.read(diaryGenerationProvider);
        final key = generation.candidateId!;
        await _expand(tester, container);
        await _tap(tester, _save(container));
        final receipt = container.read(diarySaveProvider)[key]!;
        final published = api.entries
            .where((entry) => entry.status == 'published')
            .single;
        expect(receipt.entryId, published.id.toString());
        expect(receipt.status, DiarySaveStatus.awaitingVerification);
        expect(receipt.date, generation.saveDate);
        expect(receipt.content, generation.content);
        expect(api.appendCalls, 1);
        expect(api.verificationReads, 1);
        expect(calendarLoads, initialCalendarLoads);
        expect(find.text('已写入，待核对保存'), findsWidgets);
        // Repeated failed verification still does not append a second entry.
        await _tap(tester, _save(container));
        expect(api.appendCalls, 1);
        expect(api.verificationReads, 2);
        await _mount(tester, container, buttons: 0);
        (container.read(dashboardProvider.notifier) as _AvailableDashboard)
            .selectDay(3);
        await _mount(tester, container);
        await _tap(tester, find.byKey(const Key('workspace_recap')));
        expect(
          container.read(diarySaveProvider)[key]!.entryId,
          published.id.toString(),
        );
        await _expand(tester, container);
        expect(find.text('核对保存'), findsOneWidget);
        expect(find.textContaining(generation.rangeLabel), findsOneWidget);
        api
          ..failVerification = false
          ..throwVerification = false;
        final messenger = tester.state<ScaffoldMessengerState>(
          find.byType(ScaffoldMessenger),
        );
        messenger.clearSnackBars();
        messenger.removeCurrentSnackBar();
        await tester.pump();
        await _tap(tester, _save(container));
        await container.read(calendarDataProvider.future);
        final verified = container.read(diarySaveProvider)[key]!;
        expect(verified.entryId, published.id.toString());
        expect(verified.status, DiarySaveStatus.saved);
        expect(api.appendCalls, 1);
        expect(api.savedDates, [generation.saveDate]);
        expect(api.verificationReads, 3);
        expect(api.verificationDates, [
          (generation.saveDate, generation.saveDate),
          (generation.saveDate, generation.saveDate),
          (generation.saveDate, generation.saveDate),
        ]);
        expect(
          api.entries.where((entry) => entry.status == 'published').single.id,
          published.id,
        );
        expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
        expect(calendarLoads, initialCalendarLoads + 1);
        expect(find.text('已保存到日记'), findsOneWidget);
        expect(tester.widget<FilledButton>(_save(container)).onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('local append also retries verification without another append', (
    tester,
  ) async {
    final api = _MemoryApi()..throwVerification = true;
    final container = _container(_Requests(), api);
    await _mount(tester, container);
    await _tap(tester, find.byKey(const Key('workspace_recap')));
    await _tap(tester, find.byKey(const Key('recap_generate_local')));
    await _expand(tester, container);
    await _tap(tester, _save(container));
    expect(api.appendCalls, 1);
    expect(
      container.read(diarySaveProvider).values.single.status,
      DiarySaveStatus.awaitingVerification,
    );
    await _mount(tester, container, buttons: 0);
    await _mount(tester, container);
    await _tap(tester, find.byKey(const Key('workspace_recap')));
    await _expand(tester, container);
    expect(find.text('核对保存'), findsOneWidget);
    api.throwVerification = false;
    await _tap(tester, _save(container));
    expect(api.appendCalls, 1);
    expect(api.verificationReads, 2);
    expect(
      api.entries.where((entry) => entry.status == 'published'),
      hasLength(1),
    );
    expect(
      container.read(diarySaveProvider).values.single.status,
      DiarySaveStatus.saved,
    );
    expect(tester.takeException(), isNull);
  });

  for (final known in [true, false]) {
    testWidgets(
      'failure known=$known keeps origin and retries only after confirmation',
      (tester) async {
        final requests = _Requests();
        final container = _container(requests, _MemoryApi());
        await _mount(tester, container);
        await _openAi(tester);
        await _confirm(tester);
        (container.read(dashboardProvider.notifier) as _AvailableDashboard)
            .selectDay(3);
        await tester.pump();
        requests.pending.single.completeError(
          known
              ? const AiConnectionFailure('DeepSeek 暂时不可用（500）')
              : StateError('sensitive internal fixture'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final failure = container.read(diaryGenerationProvider);
        expect(failure.status, DiaryGenerationStatus.error);
        expect(failure.startUtc, _dayState(2).requestedStartUtc);
        expect(find.text(failure.rangeLabel), findsOneWidget);
        expect(find.byKey(const Key('recap_entry_pending')), findsNothing);
        expect(
          find.text(known ? 'DeepSeek 暂时不可用（500）' : '生成失败，请稍后重试'),
          findsOneWidget,
        );
        expect(find.textContaining('sensitive internal fixture'), findsNothing);
        await _confirm(tester, cancel: true);
        expect(requests.pending, hasLength(1));
        expect(
          container.read(diaryGenerationProvider).status,
          DiaryGenerationStatus.error,
        );
        await _confirm(tester);
        expect(requests.pending, hasLength(2));
        expect(
          container.read(diaryGenerationProvider).startUtc,
          _dayState(3).requestedStartUtc,
        );
        requests.pending.last.complete('重试成功');
        await tester.pump();
        expect(container.read(diaryGenerationProvider).hasResult, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'scope disposal ignores late success and late unknown failure',
    () async {
      for (final fail in [false, true]) {
        final completer = Completer<String>();
        final storage = _MemoryRepository();
        final container = ProviderContainer(
          overrides: [
            dashboardProvider.overrideWith(_AvailableDashboard.new),
            deepSeekKeyProvider.overrideWithValue('fixture-key'),
            aiEnabledProvider.overrideWith(_EnabledAi.new),
            deepSeekModelProvider.overrideWith(_FixtureModel.new),
            apiProvider.overrideWithValue(_MemoryApi()),
            diaryCandidateRepositoryProvider.overrideWithValue(storage),
            diaryCandidateClockProvider.overrideWithValue(storage.clock),
            diaryCandidateIdProvider.overrideWithValue(storage.id),
            diaryRequesterProvider.overrideWithValue(
              ({
                required String key,
                required String model,
                required String summary,
              }) => completer.future,
            ),
          ],
        );
        final completion = container
            .read(diaryGenerationProvider.notifier)
            .start(
              startUtc: 'start',
              endUtc: 'end',
              saveDate: '2026-10-02',
              summary: 'fixture',
              key: 'fixture-key',
              model: 'fixture-model',
            );
        container.dispose();
        if (fail) {
          completer.completeError(StateError('late fixture'));
        } else {
          completer.complete('late result');
        }
        expect(await completion, isTrue);
      }
    },
  );

  test('range label uses local dates and treats end as exclusive', () {
    final start = DateTime(2026, 10, 2);
    final singleDay = DiaryGeneration(
      startUtc: start.toUtc().toIso8601String(),
      endUtc: DateTime(2026, 10, 3).toUtc().toIso8601String(),
      saveDate: '2026-10-02',
    );
    expect(singleDay.rangeLabel, '2026-10-02');
    final multipleDays = DiaryGeneration(
      startUtc: start.toUtc().toIso8601String(),
      endUtc: DateTime(2026, 10, 5).toUtc().toIso8601String(),
      saveDate: '2026-10-02',
    );
    expect(multipleDays.rangeLabel, '2026-10-02 — 2026-10-04');
  });

  test('missing key fails without making a network request', () async {
    await expectLater(
      requestDeepSeekRecap(key: '', model: 'fixture', summary: 'fixture'),
      throwsA(isA<AiConnectionFailure>()),
    );
  });

  testWidgets(
    'explicit local generation preserves list alongside paid AI history',
    (tester) async {
      final requests = _Requests();
      final api = _MemoryApi();
      final storage = _MemoryRepository();
      final container = _container(requests, api, repository: storage);
      await _mount(tester, container);
      await _openAi(tester);
      expect(find.text('日记候选'), findsOneWidget);
      expect(find.text('默认生成'), findsNothing);
      expect(find.byType(SegmentedButton<bool>), findsNothing);
      expect(find.byType(ContextHelp), findsOneWidget);
      expect(container.read(diaryCandidatesProvider).items, isEmpty);
      expect(requests.pending, isEmpty);
      await _tap(tester, find.byKey(const Key('recap_generate_local')));
      expect(_latest(container).source, DiaryCandidateSource.local);
      expect(find.byType(MarkdownBody), findsNothing);
      await _expand(tester, container);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.textContaining('## 本地复盘'), findsNothing);
      await _tap(tester, _save(container));
      expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
      await _confirm(tester);
      requests.pending.single.complete('## 付费结果\n需要长期保留。');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(container.read(diaryCandidatesProvider).items, hasLength(2));
      final paid = _latest(container);
      expect(paid.source, DiaryCandidateSource.ai);
      expect(paid.content, contains('长期保留'));
      await _expand(tester, container);
      expect(find.byType(MarkdownBody), findsOneWidget);
      // A third explicit local generation must not replace the paid candidate.
      await _tap(tester, find.byKey(const Key('recap_generate_local')));
      expect(container.read(diaryCandidatesProvider).items, hasLength(3));
      expect(
        container.read(diaryCandidatesProvider).items[paid.id]!.content,
        paid.content,
      );
      (container.read(dashboardProvider.notifier) as _AvailableDashboard)
          .selectDay(3);
      await tester.pump();
      await _tap(tester, find.byKey(const Key('workspace_recap')));
      await _openAi(tester);
      expect(requests.pending, hasLength(1));
      expect(storage.documents, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing AI and unavailable summary do not generate local candidates',
    (tester) async {
      tester.view.physicalSize = const Size(480, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = _Requests();
      final container = _container(requests, _MemoryApi(), key: '');
      await _mount(tester, container);
      await _openAi(tester);
      expect(find.text('尚未接入 AI'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('recap_generate_ai')))
            .onPressed,
        isNull,
      );
      expect(container.read(diaryCandidatesProvider).items, isEmpty);
      await _tap(tester, find.byKey(const Key('recap_generate_local')));
      expect(container.read(diaryCandidatesProvider).items, hasLength(1));
      (container.read(dashboardProvider.notifier) as _AvailableDashboard)
          .unavailable();
      await tester.pump();
      expect(find.text('本地数据暂时不可用，请刷新后重试。'), findsOneWidget);
      expect(find.byType(ContextHelp), findsOneWidget);
      expect(container.read(diaryCandidatesProvider).items, hasLength(1));
      expect(requests.pending, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test('paid content stays in memory on storage failure; retry never calls requester', () async {
    final storage = _MemoryRepository()..failWrites = true;
    final requests = _Requests();
    final container = _container(requests, _MemoryApi(), repository: storage);
    await container.read(diaryCandidatesProvider.notifier).ensureLoaded();
    final completion = container
        .read(diaryGenerationProvider.notifier)
        .start(
          startUtc: '2026-10-02T00:00:00Z',
          endUtc: '2026-10-03T00:00:00Z',
          saveDate: '2026-10-02',
          summary: 'fixture',
          key: 'fixture-key',
          model: 'fixture-model',
        );
    requests.pending.single.complete('珍贵付费全文');
    await completion;
    await _flush();
    final candidate = _latest(container);
    expect(candidate.content, '珍贵付费全文');
    expect(candidate.persisted, isFalse);
    expect(candidate.storageError, isNotNull);
    expect(container.read(diaryGenerationProvider).hasResult, isTrue);
    storage.failWrites = false;
    expect(
      await container
          .read(diaryCandidatesProvider.notifier)
          .persist(candidate.id),
      isTrue,
    );
    expect(_latest(container).persisted, isTrue);
    expect(requests.pending, hasLength(1));
    final fresh = _container(_Requests(), _MemoryApi(), repository: storage);
    await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
    expect(_latest(fresh).content, candidate.content);
    expect(_latest(fresh).generatedAtUtc, candidate.generatedAtUtc);
    expect(_latest(fresh).source, DiaryCandidateSource.ai);
  });

  test('late history load merges rather than replacing a newly generated candidate', () async {
    final storage = _MemoryRepository()
      ..pendingLoad = Completer<CandidateLoad>();
    final requests = _Requests();
    final container = _container(requests, _MemoryApi(), repository: storage);
    final assets = container.read(diaryCandidatesProvider.notifier);
    final loading = assets.load();
    await Future<void>.delayed(Duration.zero);
    final newer = assets.add(
      source: DiaryCandidateSource.local,
      startUtc: '2026-10-03T00:00:00Z',
      endUtc: '2026-10-04T00:00:00Z',
      saveDate: '2026-10-03',
      content: '新结果',
    );
    final historical = DiaryCandidate(
      id: 'historical-paid',
      source: DiaryCandidateSource.ai,
      startUtc: '2026-10-02T00:00:00Z',
      endUtc: '2026-10-03T00:00:00Z',
      saveDate: '2026-10-02',
      content: '历史付费全文',
      capturedAtUtc: DateTime.utc(2026, 10, 2),
      generatedAtUtc: DateTime.utc(2026, 10, 2),
      persisted: true,
    );
    storage.pendingLoad!.complete(CandidateLoad([historical]));
    await loading;
    expect(
      container.read(diaryCandidatesProvider).items.keys,
      containsAll([historical.id, newer.id]),
    );
    expect(container.read(diaryCandidatesProvider).ordered.first.id, newer.id);
    expect(requests.pending, isEmpty);
  });

  test(
    'read failure retains memory and retry loads history without AI',
    () async {
      final storage = _MemoryRepository()..failReads = true;
      final requests = _Requests();
      final container = _container(requests, _MemoryApi(), repository: storage);
      final assets = container.read(diaryCandidatesProvider.notifier);
      await assets.ensureLoaded();
      expect(container.read(diaryCandidatesProvider).loadError, isNotNull);
      final generated = assets.add(
        source: DiaryCandidateSource.local,
        startUtc: '2026-10-02T00:00:00Z',
        endUtc: '2026-10-03T00:00:00Z',
        saveDate: '2026-10-02',
        content: '读取失败仍保留',
      );
      await _flush();
      storage.failReads = false;
      await assets.load();
      expect(container.read(diaryCandidatesProvider).loadError, isNull);
      expect(
        container.read(diaryCandidatesProvider).items[generated.id]!.content,
        generated.content,
      );
      expect(requests.pending, isEmpty);
    },
  );

  test(
    'intent storage failure occurs before DB and permits first append on retry',
    () async {
      final storage = _MemoryRepository();
      final api = _MemoryApi();
      final container = _container(_Requests(), api, repository: storage);
      final candidate = await _fixtureCandidate(container);
      storage.failStatus = CandidatePublishStatus.appendIntent;
      final save = container.read(diarySaveProvider.notifier);
      expect(
        await save.saveCandidate(candidate.id),
        DiarySaveStatus.writeFailed,
      );
      expect(api.appendCalls, 0);
      expect(_latest(container).publishStatus, CandidatePublishStatus.ready);
      storage.failStatus = null;
      expect(await save.saveCandidate(candidate.id), DiarySaveStatus.saved);
      expect(api.appendCalls, 1);
      expect(api.savedDates, ['2026-10-02']);
    },
  );

  for (final throwsRead in [false, true]) {
    test(
      'persisted returned ID survives new scope; read failure=$throwsRead never reappends',
      () async {
        final storage = _MemoryRepository();
        final api = _MemoryApi()
          ..failVerification = !throwsRead
          ..throwVerification = throwsRead;
        final first = _container(_Requests(), api, repository: storage);
        final candidate = await _fixtureCandidate(first);
        expect(
          await first
              .read(diarySaveProvider.notifier)
              .saveCandidate(candidate.id),
          DiarySaveStatus.awaitingVerification,
        );
        final id = _latest(first).entryId;
        expect(id, isNotNull);
        final second = _container(_Requests(), api, repository: storage);
        await second.read(diaryCandidatesProvider.notifier).ensureLoaded();
        expect(_latest(second).entryId, id);
        expect(
          await second
              .read(diarySaveProvider.notifier)
              .saveCandidate(candidate.id),
          DiarySaveStatus.awaitingVerification,
        );
        expect(api.appendCalls, 1);
        api
          ..failVerification = false
          ..throwVerification = false;
        expect(
          await second
              .read(diarySaveProvider.notifier)
              .saveCandidate(candidate.id),
          DiarySaveStatus.saved,
        );
        expect(api.appendCalls, 1);
        final third = _container(_Requests(), api, repository: storage);
        await third.read(diaryCandidatesProvider.notifier).ensureLoaded();
        expect(_latest(third).entryId, id);
        expect(_latest(third).publishStatus, CandidatePublishStatus.saved);
        expect(
          await third
              .read(diarySaveProvider.notifier)
              .saveCandidate(candidate.id),
          DiarySaveStatus.saved,
        );
        expect(api.appendCalls, 1);
        expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
      },
    );
  }

  test('receipt metadata write failure retains returned ID, and disk intent blocks a new scope', () async {
    final storage = _MemoryRepository();
    final api = _MemoryApi();
    final first = _container(_Requests(), api, repository: storage);
    final candidate = await _fixtureCandidate(first);
    storage.failStatus = CandidatePublishStatus.awaitingVerification;
    expect(
      await first.read(diarySaveProvider.notifier).saveCandidate(candidate.id),
      DiarySaveStatus.awaitingVerification,
    );
    expect(_latest(first).entryId, isNotNull);
    expect(_latest(first).persisted, isFalse);
    expect(api.appendCalls, 1);
    expect(storage.documents[candidate.id]!['publishStatus'], 'appendIntent');
    final fresh = _container(_Requests(), api, repository: storage);
    await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
    expect(
      await fresh.read(diarySaveProvider.notifier).saveCandidate(candidate.id),
      DiarySaveStatus.resultUnknown,
    );
    expect(_latest(fresh).entryId, isNull);
    expect(api.appendCalls, 1);
  });

  test('same scope retries receipt storage with its returned ID and no second append', () async {
    final storage = _MemoryRepository();
    final api = _MemoryApi();
    final container = _container(_Requests(), api, repository: storage);
    final candidate = await _fixtureCandidate(container);
    storage.failStatus = CandidatePublishStatus.awaitingVerification;
    expect(
      await container
          .read(diarySaveProvider.notifier)
          .saveCandidate(candidate.id),
      DiarySaveStatus.awaitingVerification,
    );
    final id = _latest(container).entryId;
    storage.failStatus = null;
    expect(
      await container
          .read(diarySaveProvider.notifier)
          .saveCandidate(candidate.id),
      DiarySaveStatus.saved,
    );
    expect(_latest(container).entryId, id);
    expect(api.appendCalls, 1);
  });

  for (final committed in [false, true]) {
    test(
      'append throws committed=$committed: durable unknown prevents replay in same and new scopes',
      () async {
        final storage = _MemoryRepository();
        final api = _MemoryApi()
          ..failSave = !committed
          ..appendThenThrow = committed;
        final first = _container(_Requests(), api, repository: storage);
        final candidate = await _fixtureCandidate(first);
        final save = first.read(diarySaveProvider.notifier);
        expect(
          await save.saveCandidate(candidate.id),
          DiarySaveStatus.resultUnknown,
        );
        expect(_latest(first).entryId, isNull);
        expect(_latest(first).publishStatus, CandidatePublishStatus.unknown);
        expect(api.appendCalls, 1);
        expect(
          api.entries.where((entry) => entry.status == 'published'),
          hasLength(committed ? 1 : 0),
        );
        api
          ..failSave = false
          ..appendThenThrow = false;
        expect(
          await save.saveCandidate(candidate.id),
          DiarySaveStatus.resultUnknown,
        );
        expect(api.appendCalls, 1);
        final fresh = _container(_Requests(), api, repository: storage);
        await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
        expect(
          await fresh
              .read(diarySaveProvider.notifier)
              .saveCandidate(candidate.id),
          DiarySaveStatus.resultUnknown,
        );
        expect(
          _latest(fresh).entryId,
          isNull,
        ); // Text-match is not ownership proof.
        expect(api.appendCalls, 1);
        expect(
          api.verificationDates.every(
            (range) => range == ('2026-10-02', '2026-10-02'),
          ),
          isTrue,
        );
      },
    );
  }

  test('unknown outcome write failure still leaves durable intent and never replays append', () async {
    final storage = _MemoryRepository();
    final api = _MemoryApi()..appendThenThrow = true;
    final first = _container(_Requests(), api, repository: storage);
    final candidate = await _fixtureCandidate(first);
    storage.failStatus = CandidatePublishStatus.unknown;
    expect(
      await first.read(diarySaveProvider.notifier).saveCandidate(candidate.id),
      DiarySaveStatus.resultUnknown,
    );
    expect(storage.documents[candidate.id]!['publishStatus'], 'appendIntent');
    expect(_latest(first).publishStatus, CandidatePublishStatus.unknown);
    final second = _container(_Requests(), api, repository: storage);
    await second.read(diaryCandidatesProvider.notifier).ensureLoaded();
    expect(
      await second.read(diarySaveProvider.notifier).saveCandidate(candidate.id),
      DiarySaveStatus.resultUnknown,
    );
    expect(api.appendCalls, 1);
  });

  test('local and two paid requests retain independent ordered histories and only selected candidate publishes', () async {
    final storage = _MemoryRepository();
    final requests = _Requests();
    final api = _MemoryApi();
    final container = _container(requests, api, repository: storage);
    final local = await _fixtureCandidate(
      container,
      source: DiaryCandidateSource.local,
      content: '本地历史',
    );
    final generator = container.read(diaryGenerationProvider.notifier);
    for (final day in [2, 3]) {
      final completion = generator.start(
        startUtc: '2026-10-0${day}T00:00:00Z',
        endUtc: '2026-10-0${day + 1}T00:00:00Z',
        saveDate: '2026-10-0$day',
        summary: '范围$day',
        key: 'fixture-key',
        model: 'fixture-model',
      );
      requests.pending.last.complete('付费历史$day');
      await completion;
      await _flush();
    }
    final history = container.read(diaryCandidatesProvider).ordered;
    expect(history.map((item) => item.content), ['付费历史3', '付费历史2', '本地历史']);
    expect(history.map((item) => item.id).toSet(), hasLength(3));
    expect(history.map((item) => item.source), [
      DiaryCandidateSource.ai,
      DiaryCandidateSource.ai,
      DiaryCandidateSource.local,
    ]);
    expect(history.every((item) => item.generatedAtUtc != null), isTrue);
    final selected = history[1];
    expect(
      await container
          .read(diarySaveProvider.notifier)
          .saveCandidate(selected.id),
      DiarySaveStatus.saved,
    );
    expect(api.savedDates, ['2026-10-02']);
    expect(
      api.entries.where((item) => item.status == 'published').single.content,
      selected.content,
    );
    expect(
      container.read(diaryCandidatesProvider).items[local.id]!.publishStatus,
      CandidatePublishStatus.ready,
    );
    final fresh = _container(_Requests(), api, repository: storage);
    await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
    expect(
      fresh.read(diaryCandidatesProvider).ordered.map((item) => item.content),
      history.map((item) => item.content),
    );
    expect(requests.pending, hasLength(2));
  });

  for (final savedInitially in [false, true]) {
    for (final sameRevision in [false, true]) {
      test(
        'late recovery snapshot preserves ${savedInitially ? "saved" : "awaiting"} receipt at ${sameRevision ? "equal" : "lower"} revision',
        () async {
          final storage = _MemoryRepository();
          final api = _MemoryApi()..failVerification = !savedInitially;
          final requests = _Requests();
          final container = _container(requests, api, repository: storage);
          final original = await _fixtureCandidate(container);
          storage.pendingLoad = Completer<CandidateLoad>();
          final reload = container
              .read(diaryCandidatesProvider.notifier)
              .load();
          await Future<void>.delayed(Duration.zero);
          final save = container.read(diarySaveProvider.notifier);
          expect(
            await save.saveCandidate(original.id),
            savedInitially
                ? DiarySaveStatus.saved
                : DiarySaveStatus.awaitingVerification,
          );
          final receipt = container
              .read(diaryCandidatesProvider)
              .items[original.id]!;
          expect(receipt.entryId, isNotNull);
          storage.pendingLoad!.complete(
            CandidateLoad([
              original.copyWith(
                revision: sameRevision ? receipt.revision : original.revision,
                publishStatus: CandidatePublishStatus.unknown,
                recoveryBlocked: true,
                storageError: 'fixture damaged history',
              ),
            ], hasRecoveryIssue: true),
          );
          await reload;
          final retained = container
              .read(diaryCandidatesProvider)
              .items[original.id]!;
          expect(retained.revision, receipt.revision);
          expect(retained.entryId, receipt.entryId);
          expect(retained.publishStatus, receipt.publishStatus);
          expect(retained.content, original.content);
          expect(retained.startUtc, original.startUtc);
          expect(retained.endUtc, original.endUtc);
          expect(retained.saveDate, original.saveDate);
          expect(
            container.read(diaryCandidatesProvider).hasRecoveryIssue,
            isTrue,
          );
          storage.pendingLoad = null;
          api.failVerification = false;
          expect(await save.saveCandidate(original.id), DiarySaveStatus.saved);
          final fresh = _container(_Requests(), api, repository: storage);
          await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
          expect(_latest(fresh).entryId, receipt.entryId);
          expect(_latest(fresh).publishStatus, CandidatePublishStatus.saved);
          expect(
            await fresh
                .read(diarySaveProvider.notifier)
                .saveCandidate(original.id),
            DiarySaveStatus.saved,
          );
          expect(api.appendCalls, 1);
          expect(
            api.verificationDates.every(
              (range) => range == ('2026-10-02', '2026-10-02'),
            ),
            isTrue,
          );
          expect(
            api.entries
                .where((entry) => entry.status == 'published')
                .single
                .content,
            original.content,
          );
          expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
          expect(requests.pending, isEmpty);
        },
      );
    }
  }

  test(
    'higher damaged revision retains known ID and verifies without append',
    () async {
      final storage = _MemoryRepository();
      final api = _MemoryApi()..failVerification = true;
      final container = _container(_Requests(), api, repository: storage);
      final original = await _fixtureCandidate(container);
      storage.pendingLoad = Completer<CandidateLoad>();
      final reload = container.read(diaryCandidatesProvider.notifier).load();
      await Future<void>.delayed(Duration.zero);
      expect(
        await container
            .read(diarySaveProvider.notifier)
            .saveCandidate(original.id),
        DiarySaveStatus.awaitingVerification,
      );
      final receipt = _latest(container);
      final damagedRevision = receipt.revision + 2;
      storage.pendingLoad!.complete(
        CandidateLoad([
          original.copyWith(
            revision: damagedRevision,
            publishStatus: CandidatePublishStatus.unknown,
            recoveryBlocked: true,
            storageError: 'fixture damaged history',
          ),
        ], hasRecoveryIssue: true),
      );
      await reload;
      final retained = _latest(container);
      expect(retained.revision, greaterThan(damagedRevision));
      expect(retained.entryId, receipt.entryId);
      expect(
        retained.publishStatus,
        CandidatePublishStatus.awaitingVerification,
      );
      expect(retained.recoveryBlocked, isTrue);
      expect(retained.persisted, isFalse);
      expect(retained.content, original.content);
      storage.pendingLoad = null;
      api.failVerification = false;
      expect(
        await container
            .read(diarySaveProvider.notifier)
            .saveCandidate(original.id),
        DiarySaveStatus.saved,
      );
      final fresh = _container(_Requests(), api, repository: storage);
      await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
      expect(_latest(fresh).entryId, receipt.entryId);
      expect(
        await fresh.read(diarySaveProvider.notifier).saveCandidate(original.id),
        DiarySaveStatus.saved,
      );
      expect(api.appendCalls, 1);
      expect(
        api.verificationDates.every(
          (range) => range == ('2026-10-02', '2026-10-02'),
        ),
        isTrue,
      );
      expect(
        api.entries
            .where((entry) => entry.status == 'published')
            .single
            .content,
        original.content,
      );
      expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
    },
  );

  for (final outcome in [
    'saved',
    'receiptWriteFailure',
    'verificationMissing',
    'verificationThrows',
  ]) {
    test(
      'in-flight receipt resumes from revision5, not old2: $outcome',
      () async {
        final storage = _InterleavedRepository();
        final api = _MemoryApi()
          ..failVerification = outcome == 'verificationMissing'
          ..throwVerification = outcome == 'verificationThrows';
        final requests = _Requests();
        final container = _container(requests, api, repository: storage);
        final original = await _fixtureCandidate(container);
        final before = Map<(String, int), String>.from(storage.revisions);
        storage.pendingLoad = Completer<CandidateLoad>();
        final assets = container.read(diaryCandidatesProvider.notifier);
        final reload = assets.load();
        await _flush();
        storage
          ..pendingPut = Completer<void>()
          ..pauseStatus = CandidatePublishStatus.awaitingVerification
          ..pauseRevision = 2
          ..failPausedPut = outcome == 'receiptWriteFailure';
        final save = container.read(diarySaveProvider.notifier);
        final saving = save.saveCandidate(original.id);
        await _flush();
        final receipt = _latest(container);
        expect(receipt.revision, 2);
        expect(receipt.entryId, isNotNull);
        expect(
          receipt.publishStatus,
          CandidatePublishStatus.awaitingVerification,
        );
        storage.damage(original, 4);
        final damagedBytes = storage.revisions[(original.id, 4)];
        storage.pendingLoad!.complete(
          CandidateLoad([
            original.copyWith(
              revision: 4,
              recoveryBlocked: true,
              publishStatus: CandidatePublishStatus.unknown,
              storageError: 'fixture damaged revision4',
            ),
          ], hasRecoveryIssue: true),
        );
        await reload;
        final promoted = _latest(container);
        expect(promoted.revision, 5);
        expect(promoted.entryId, receipt.entryId);
        expect(promoted.recoveryBlocked, isTrue);
        storage.pendingLoad = null;
        storage.pendingPut!.complete();
        expect(
          await saving,
          outcome == 'saved'
              ? DiarySaveStatus.saved
              : DiarySaveStatus.awaitingVerification,
        );
        final resumed = _latest(container);
        expect(resumed.revision, greaterThanOrEqualTo(promoted.revision));
        expect(resumed.entryId, receipt.entryId);
        expect(resumed.content, original.content);
        expect(resumed.saveDate, original.saveDate);
        expect(resumed.startUtc, original.startUtc);
        expect(resumed.endUtc, original.endUtc);
        expect(resumed.recoveryBlocked, isTrue);
        expect(
          resumed.publishStatus,
          outcome == 'saved'
              ? CandidatePublishStatus.saved
              : CandidatePublishStatus.awaitingVerification,
        );
        if (outcome == 'receiptWriteFailure') {
          expect(resumed.persisted, isFalse);
          expect(api.verificationReads, 0);
        }
        storage.failPausedPut = false;
        api
          ..failVerification = false
          ..throwVerification = false;
        expect(await save.saveCandidate(original.id), DiarySaveStatus.saved);
        final committed = _latest(container);
        expect(committed.revision, greaterThan(5));
        expect(committed.persisted, isTrue);
        expect(committed.entryId, receipt.entryId);
        for (final entry in before.entries) {
          expect(storage.revisions[entry.key], entry.value);
        }
        expect(storage.revisions[(original.id, 4)], damagedBytes);
        final fresh = _container(_Requests(), api, repository: storage);
        await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
        final reopened = _latest(fresh);
        expect(reopened.revision, committed.revision);
        expect(reopened.publishStatus, CandidatePublishStatus.saved);
        expect(reopened.entryId, receipt.entryId);
        expect(reopened.saveDate, original.saveDate);
        expect(reopened.content, original.content);
        expect(
          await fresh
              .read(diarySaveProvider.notifier)
              .saveCandidate(original.id),
          DiarySaveStatus.saved,
        );
        expect(api.appendCalls, 1);
        expect(api.savedDates, ['2026-10-02']);
        expect(
          api.verificationDates.every(
            (range) => range == ('2026-10-02', '2026-10-02'),
          ),
          isTrue,
        );
        expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
        expect(requests.pending, isEmpty);
      },
    );
  }

  for (final failWrite in [false, true]) {
    test(
      'promoted recovery during intent IO never restores old ready: fail=$failWrite',
      () async {
        final storage = _InterleavedRepository();
        final api = _MemoryApi();
        final container = _container(_Requests(), api, repository: storage);
        final original = await _fixtureCandidate(container);
        storage.pendingLoad = Completer<CandidateLoad>();
        final assets = container.read(diaryCandidatesProvider.notifier);
        final reload = assets.load();
        await _flush();
        storage
          ..pendingPut = Completer<void>()
          ..pauseStatus = CandidatePublishStatus.appendIntent
          ..pauseRevision = 1
          ..failPausedPut = failWrite;
        final saving = container
            .read(diarySaveProvider.notifier)
            .saveCandidate(original.id);
        await _flush();
        storage.damage(original, 4);
        storage.pendingLoad!.complete(
          CandidateLoad([
            original.copyWith(
              revision: 4,
              recoveryBlocked: true,
              publishStatus: CandidatePublishStatus.unknown,
            ),
          ], hasRecoveryIssue: true),
        );
        await reload;
        expect(_latest(container).revision, 4);
        storage.pendingLoad = null;
        storage.pendingPut!.complete();
        expect(await saving, DiarySaveStatus.resultUnknown);
        expect(_latest(container).revision, 4);
        expect(
          _latest(container).publishStatus,
          CandidatePublishStatus.unknown,
        );
        expect(_latest(container).recoveryBlocked, isTrue);
        expect(api.appendCalls, 0);
        storage.failPausedPut = false;
        expect(
          await container
              .read(diarySaveProvider.notifier)
              .saveCandidate(original.id),
          DiarySaveStatus.resultUnknown,
        );
        final fresh = _container(_Requests(), api, repository: storage);
        await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
        expect(
          await fresh
              .read(diarySaveProvider.notifier)
              .saveCandidate(original.id),
          DiarySaveStatus.resultUnknown,
        );
        expect(api.appendCalls, 0);
      },
    );
  }

  test(
    'saved commit awaiting IO persists a concurrently promoted saved receipt',
    () async {
      final storage = _InterleavedRepository();
      final api = _MemoryApi();
      final container = _container(_Requests(), api, repository: storage);
      final original = await _fixtureCandidate(container);
      storage.pendingLoad = Completer<CandidateLoad>();
      final assets = container.read(diaryCandidatesProvider.notifier);
      final reload = assets.load();
      await _flush();
      storage
        ..pendingPut = Completer<void>()
        ..pauseStatus = CandidatePublishStatus.saved
        ..pauseRevision = 3;
      final saving = container
          .read(diarySaveProvider.notifier)
          .saveCandidate(original.id);
      await _flush();
      final saved = _latest(container);
      expect(saved.revision, 3);
      expect(saved.publishStatus, CandidatePublishStatus.saved);
      storage.damage(original, 4);
      storage.pendingLoad!.complete(
        CandidateLoad([
          original.copyWith(
            revision: 4,
            recoveryBlocked: true,
            publishStatus: CandidatePublishStatus.unknown,
          ),
        ], hasRecoveryIssue: true),
      );
      await reload;
      expect(_latest(container).revision, 5);
      expect(_latest(container).entryId, saved.entryId);
      expect(_latest(container).publishStatus, CandidatePublishStatus.saved);
      storage.pendingLoad = null;
      storage.pendingPut!.complete();
      expect(await saving, DiarySaveStatus.saved);
      expect(_latest(container).revision, 5);
      expect(_latest(container).persisted, isTrue);
      final fresh = _container(_Requests(), api, repository: storage);
      await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
      expect(_latest(fresh).revision, 5);
      expect(_latest(fresh).publishStatus, CandidatePublishStatus.saved);
      expect(_latest(fresh).entryId, saved.entryId);
      expect(
        await fresh.read(diarySaveProvider.notifier).saveCandidate(original.id),
        DiarySaveStatus.saved,
      );
      expect(api.appendCalls, 1);
    },
  );

  test(
    'replace rejects a stale lower revision without dropping a saved receipt',
    () async {
      final storage = _MemoryRepository();
      final api = _MemoryApi();
      final container = _container(_Requests(), api, repository: storage);
      final original = await _fixtureCandidate(container);
      final assets = container.read(diaryCandidatesProvider.notifier);
      expect(
        await container
            .read(diarySaveProvider.notifier)
            .saveCandidate(original.id),
        DiarySaveStatus.saved,
      );
      final saved = _latest(container);
      assets.replace(original.copyWith(revision: 1));
      expect(_latest(container), same(saved));
      expect(api.appendCalls, 1);
    },
  );

  test(
    'in-flight receipt commits beyond damaged immutable file and reopens saved',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'timetrace-candidate-interleave-fixture-',
      );
      final fixturePath = root.absolute.path;
      addTearDown(() async {
        if (root.absolute.path != fixturePath ||
            !root.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last
                .startsWith('timetrace-candidate-interleave-fixture-')) {
          throw StateError('Unsafe fixture cleanup');
        }
        if (await root.exists()) await root.delete(recursive: true);
      });
      File revision(String id, int number) =>
          File('${root.path}${Platform.pathSeparator}$id.$number.json');
      final storage = _FileInterleavedRepository(root);
      final requests = _Requests();
      final api = _MemoryApi();
      final container = _container(requests, api, repository: storage);
      final original = await _fixtureCandidate(container);
      // add() starts asynchronous disk IO; wait for the same immutable commit.
      expect(
        await container
            .read(diaryCandidatesProvider.notifier)
            .persist(original.id),
        isTrue,
      );
      final firstBytes = await revision(original.id, 0).readAsString();
      storage.pendingLoad = Completer<CandidateLoad>();
      final assets = container.read(diaryCandidatesProvider.notifier);
      final reload = assets.load();
      await _flush();
      storage.receiptPut = Completer<void>();
      final saving = container
          .read(diarySaveProvider.notifier)
          .saveCandidate(original.id);
      await storage.receiptStarted.future;
      final receipt = _latest(container);
      expect(receipt.revision, 2);
      expect(receipt.entryId, isNotNull);
      final intentBytes = await revision(original.id, 1).readAsString();
      final damaged = revision(original.id, 4);
      const damagedBytes = '{fixture interrupted commit';
      await damaged.writeAsString(damagedBytes, flush: true);
      final diskSnapshot = await storage.files.load();
      expect(diskSnapshot.candidates.single.revision, 4);
      expect(diskSnapshot.candidates.single.recoveryBlocked, isTrue);
      storage.pendingLoad!.complete(diskSnapshot);
      await reload;
      expect(_latest(container).revision, 5);
      expect(_latest(container).entryId, receipt.entryId);
      storage.pendingLoad = null;
      storage.receiptPut!.complete();
      expect(await saving, DiarySaveStatus.saved);
      final saved = _latest(container);
      expect(saved.revision, 6);
      expect(saved.persisted, isTrue);
      expect(saved.entryId, receipt.entryId);
      expect(saved.recoveryBlocked, isTrue);
      expect(await revision(original.id, 0).readAsString(), firstBytes);
      expect(await revision(original.id, 1).readAsString(), intentBytes);
      expect(await damaged.readAsString(), damagedBytes);
      expect(await revision(original.id, 2).exists(), isTrue);
      expect(await revision(original.id, 5).exists(), isTrue);
      expect(await revision(original.id, 6).exists(), isTrue);
      final freshStorage = _FileInterleavedRepository(root);
      final fresh = _container(_Requests(), api, repository: freshStorage);
      await fresh.read(diaryCandidatesProvider.notifier).ensureLoaded();
      final reopened = _latest(fresh);
      expect(reopened.revision, 6);
      expect(reopened.entryId, receipt.entryId);
      expect(reopened.publishStatus, CandidatePublishStatus.saved);
      expect(reopened.saveDate, original.saveDate);
      expect(reopened.content, original.content);
      expect(reopened.startUtc, original.startUtc);
      expect(reopened.endUtc, original.endUtc);
      expect(
        await fresh.read(diarySaveProvider.notifier).saveCandidate(original.id),
        DiarySaveStatus.saved,
      );
      expect(api.appendCalls, 1);
      expect(api.savedDates, ['2026-10-02']);
      expect(api.verificationDates, [('2026-10-02', '2026-10-02')]);
      expect(api.drafts['2026-10-02'], '已有草稿，不能覆盖');
      expect(requests.pending, isEmpty);
      expect(await damaged.readAsString(), damagedBytes);
    },
  );

  for (final explicitlyLoad in [false, true]) {
    test(
      'scope disposed before queued ${explicitlyLoad ? "load" : "ensureLoaded"} starts performs no IO',
      () async {
        final storage = _MemoryRepository();
        final requests = _Requests();
        final api = _MemoryApi();
        final container = ProviderContainer(
          overrides: [
            diaryCandidateRepositoryProvider.overrideWithValue(storage),
            diaryCandidateClockProvider.overrideWithValue(storage.clock),
            diaryCandidateIdProvider.overrideWithValue(storage.id),
            diaryRequesterProvider.overrideWithValue(requests.call),
            deepSeekKeyProvider.overrideWithValue('fixture-key'),
            deepSeekModelProvider.overrideWith(_FixtureModel.new),
            aiEnabledProvider.overrideWith(_EnabledAi.new),
            apiProvider.overrideWithValue(api),
          ],
        );
        final assets = container.read(diaryCandidatesProvider.notifier);
        final operation = explicitlyLoad
            ? assets.load()
            : assets.ensureLoaded();
        container.dispose();
        await expectLater(operation, completes);
        expect(storage.loads, 0);
        expect(storage.puts, 0);
        expect(api.appendCalls, 0);
        expect(api.verificationReads, 0);
        expect(requests.pending, isEmpty);
      },
    );
  }

  test('scope disposal ignores delayed history load', () async {
    final storage = _MemoryRepository()
      ..pendingLoad = Completer<CandidateLoad>();
    final container = ProviderContainer(
      overrides: [
        diaryCandidateRepositoryProvider.overrideWithValue(storage),
        diaryCandidateClockProvider.overrideWithValue(storage.clock),
        diaryCandidateIdProvider.overrideWithValue(storage.id),
        diaryRequesterProvider.overrideWithValue(_Requests().call),
        deepSeekKeyProvider.overrideWithValue('fixture-key'),
        deepSeekModelProvider.overrideWith(_FixtureModel.new),
        aiEnabledProvider.overrideWith(_EnabledAi.new),
        apiProvider.overrideWithValue(_MemoryApi()),
      ],
    );
    final operation = container
        .read(diaryCandidatesProvider.notifier)
        .ensureLoaded();
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    storage.pendingLoad!.complete(CandidateLoad([]));
    await operation;
  });

  testWidgets('workspace glyphs paint without an Icon font', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Row(
          children: [
            WorkspaceGlyph(WorkspaceGlyphKind.data),
            WorkspaceGlyph(WorkspaceGlyphKind.settings),
          ],
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(WorkspaceGlyph),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: find.byType(WorkspaceGlyph),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
