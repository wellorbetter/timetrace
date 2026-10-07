import 'dart:async';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/workspace/workspace_host.dart' as host;
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/component_workspace.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_card.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/daily_quote_line.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/daily_quote_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/accounting_snapshot_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/browsing_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';
import 'package:timetrace_app/src/features/browsing/data/diary_candidate_repository.dart';
import 'package:timetrace_app/src/features/time_tools/providers/time_tools_provider.dart';
import 'package:timetrace_app/src/features/time_tools/presentation/time_tool_widgets.dart';
import '../../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import '../../time_tools/time_tools_state_test.dart' show MemoryTimeStore;
import '../../browsing/refresh_lifecycle_test.dart' show snap;

class _ForbiddenApi extends Fake implements TimeTraceApi {}

class _NoSavedKey extends SavedDeepSeekKey {
  @override
  Future<String> build() async => '';
}

class _NoAi extends AiEnabledNotifier {
  @override
  bool build() => false;
}

class _NoModel extends DeepSeekModelNotifier {
  @override
  String build() => 'synthetic-no-AI';
}

class _MemoryCandidates implements DiaryCandidateRepository {
  @override
  Future<CandidateLoad> load() async => CandidateLoad([]);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('no candidate writes');
}

class _RangeOnly extends BrowsingNotifier {
  int selections = 0;
  @override
  BrowsingState build() => BrowsingState(
    range: DateRangeSelection(DateRange.custom, day: DateTime(2026, 5, 1)),
  );
  @override
  Future<void> selectDay(DateTime day) async {
    selections++;
    state = state.copyWith(
      range: DateRangeSelection(
        DateRange.custom,
        day: DateTime(day.year, day.month, day.day),
      ),
    );
  }

  void choose(DateRangeSelection selection) =>
      state = state.copyWith(range: selection);
}

AccountingSnapshotDto response(
  AccountingQuerySpec q, {
  String? localDate,
  String? timezoneOverride,
  bool wrongUtc = false,
  bool private = false,
}) {
  final original = snap(q, private: private);
  final range = q.range;
  final local = range is AccountingRangeRequest_LocalDate;
  final start = local
      ? DateTime.parse(
          q.startUtc,
        ).add(const Duration(hours: 5)).toIso8601String()
      : (wrongUtc
            ? DateTime.parse(
                q.startUtc,
              ).add(const Duration(minutes: 1)).toIso8601String()
            : q.startUtc);
  final end = local
      ? DateTime.parse(q.endUtc).add(const Duration(hours: 5)).toIso8601String()
      : q.endUtc;
  return AccountingSnapshotDto(
    requestedStartUtc: start,
    requestedEndUtc: end,
    effectiveStartUtc: start,
    effectiveEndUtc: end,
    observedThroughUtc: end,
    totals: original.totals,
    intervals: original.intervals,
    apps: private
        ? const []
        : [
            AttributionTotalDto(
              id: 'fixture-' + q.startUtc.substring(0, 10),
              seconds: 1,
            ),
          ],
    windows: original.windows,
    pages: original.pages,
    hours: original.hours,
    integrity: original.integrity,
    localDate: local ? (localDate ?? range.localDate) : null,
    timezone: local ? (timezoneOverride ?? range.timezone) : null,
  );
}

class _Call {
  _Call(this.query);
  final AccountingQuerySpec query;
  final result = Completer<AccountingSnapshotDto>();
}

class _Fixture {
  _Fixture({this.timezone}) {
    backend = MemoryPreferencesBackend(
      jsonEncode({
        'version': 1,
        'workspaceGroupsV2': [
          ['calendar'],
          ['bar'],
          ['tasks'],
          ['diary'],
        ],
      }),
    );
    composer = DiaryComposerStore(
      api: _ForbiddenApi(),
      writeDraft: (date, text) {
        drafts[date] = text;
      },
    );
    container = ProviderContainer(
      overrides: [
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        apiProvider.overrideWithValue(_ForbiddenApi()),
        browsingProvider.overrideWith(_RangeOnly.new),
        browsingClockProvider.overrideWithValue(
          () => DateTime(2026, 5, 15, 12),
        ),
        dashboardIanaTimezoneProvider.overrideWithValue(timezone),
        dataRefreshPolicyProvider.overrideWithValue(
          const DataRefreshPolicy(interval: Duration.zero),
        ),
        dataRefreshVisibilityProvider.overrideWithValue(() => true),
        dashboardSnapshotLoaderProvider.overrideWithValue((q) {
          final c = _Call(q);
          calls.add(c);
          return c.result.future;
        }),
        dashboardMetadataLoaderProvider.overrideWithValue(
          (_) => const DashboardMetadata(),
        ),
        workspaceLayoutStoreProvider.overrideWithValue(
          WorkspaceLayoutStore(backend: backend),
        ),
        timeToolsStoreProvider.overrideWithValue(time),
        timeToolsClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 5, 15, 12),
        ),
        timeToolsIdProvider.overrideWithValue(() => 'synthetic-task'),
        calendarDataProvider.overrideWith(
          (ref) async => const CalendarData(
            images: {},
            entryImages: {},
            diaryDays: {},
            entries: [],
          ),
        ),
        diaryDraftProvider.overrideWith((ref, date) async => drafts[date]),
        diaryComposerStoreProvider.overrideWithValue(composer),
        diaryImageImporterProvider.overrideWithValue((_, __) async => []),
        diaryEntryMetadataStoreProvider.overrideWith(
          (ref) => throw StateError('no sidecar access'),
        ),
        diaryCandidateRepositoryProvider.overrideWithValue(_MemoryCandidates()),
        diaryRequesterProvider.overrideWithValue(({
          required key,
          required model,
          required summary,
        }) async {
          paid++;
          throw StateError('forbidden paid request');
        }),
        deepSeekEnvironmentKeyProvider.overrideWithValue(''),
        deepSeekKeyProvider.overrideWithValue(''),
        savedDeepSeekKeyProvider.overrideWith(_NoSavedKey.new),
        aiKeyStoreProvider.overrideWith(
          (ref) => throw StateError('no key store'),
        ),
        aiEnabledProvider.overrideWith(_NoAi.new),
        deepSeekModelProvider.overrideWith(_NoModel.new),
        dailyQuoteRepositoryProvider.overrideWithValue(
          DailyQuoteRepository(
            read: () => {},
            write: (_) {},
            fetch: () async => offlineDailyQuotes.first,
          ),
        ),
        dailyQuoteTickProvider.overrideWithValue(null),
        dailyQuoteClockProvider.overrideWithValue(() => DateTime(2026, 5, 15)),
        dailyQuoteProvider.overrideWith(
          (ref, date) async => offlineDailyQuotes.first,
        ),
      ],
    );
  }
  final String? timezone;
  late final ProviderContainer container;
  late final MemoryPreferencesBackend backend;
  late final DiaryComposerStore composer;
  final time = MemoryTimeStore();
  final drafts = <String, String>{};
  final calls = <_Call>[];
  int paid = 0;
  _RangeOnly get range =>
      container.read(browsingProvider.notifier) as _RangeOnly;
  void close() {
    composer.dispose();
    container.dispose();
  }
}

Future<void> mount(WidgetTester tester, _Fixture f) async {
  tester.view.physicalSize = const Size(1200, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await f.container.read(timeToolsProvider.notifier).ensureLoaded();
  await f.container.read(workspaceDocumentProvider.notifier).ensureLoaded();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp(
        home: MaterialScope(
          policy: MaterialPolicy.resolve(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
            wallpaper: WallpaperLoadState.absent,
            signals: const MaterialSignals(
              highContrast: AccessibilitySignal.disabled,
              reduceTransparency: AccessibilitySignal.enabled,
            ),
          ),
          tokens: MaterialTokens.forWidth(1200),
          child: const DashboardScreen(),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> tick(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> select(WidgetTester tester, int day) async {
  final target = find.byKey(
    ValueKey('calendar_date_2026-05-${day.toString().padLeft(2, '0')}'),
  );
  await tester.tap(target);
  await tick(tester);
}

void main() {
  for (final width in [280.0, 720.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'day summary shared help width$width scale$scale $brightness',
          (tester) async {
            final f = _Fixture();
            addTearDown(f.close);
            tester.view.physicalSize = Size(width, 600);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final query = accountingQueryFor(
              DateRangeSelection(DateRange.custom, day: DateTime(2026, 5, 1)),
              DateTime(2026, 5, 15),
            );
            final source = snap(query);
            final state = projectAccountingSnapshot(source).copyWith(
              hours: [
                LocalHourBucketDto(
                  stableId: 'synthetic-hour',
                  localDate: '2026-05-01',
                  localHour: 0,
                  utcOffsetSeconds: 0,
                  fold: 0,
                  startUtc: query.startUtc,
                  endUtc: query.endUtc,
                  totals: source.totals,
                  apps: source.apps,
                ),
              ],
            );
            final scheme = ColorScheme.fromSeed(
              seedColor: const Color(0xff58694f),
              brightness: brightness,
            );
            final policy = MaterialPolicy.resolve(
              colorScheme: scheme,
              wallpaper: WallpaperLoadState.absent,
              signals: const MaterialSignals(
                highContrast: AccessibilitySignal.disabled,
                reduceTransparency: AccessibilitySignal.disabled,
              ),
            );
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: f.container,
                child: MaterialApp(
                  theme: policy.applyTo(ThemeData(colorScheme: scheme)),
                  home: Scaffold(
                    body: MediaQuery(
                      data: MediaQueryData(
                        size: Size(width, 600),
                        textScaler: TextScaler.linear(scale),
                      ),
                      child: MaterialScope(
                        policy: policy,
                        tokens: MaterialTokens.forWidth(width),
                        child: SizedBox(
                          width: width,
                          height: 358,
                          child: DaySummaryPanel(
                            date: DateTime(2026, 5, 1),
                            state: state,
                            singleDay: true,
                            timezoneAvailable: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final firstError = tester.takeException();
            expect(firstError, isNull);
            expect(find.text('5月1日 · 周五'), findsOneWidget);
            expect(find.byType(ContextHelp), findsNWidgets(2));
            expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
            expect(find.text('synthetic-public'), findsOneWidget);
            for (final message in [
              '当天应用活跃时长汇总，不含锁屏和空闲时间。',
              '本地日的活跃分布，夏令时日可能有 23 或 25 个小时桶。',
            ]) {
              final help = find.byWidgetPredicate(
                (w) => w is ContextHelp && w.message == message,
              );
              final button = find.descendant(
                of: help,
                matching: find.byType(IconButton),
              );
              final glyph = find.descendant(
                of: help,
                matching: find.byIcon(Icons.question_mark_rounded),
              );
              final bounds = tester.getRect(button);
              expect(bounds.size, const Size(48, 48));
              expect(tester.getRect(glyph).size, const Size(18, 18));
              expect(tester.getRect(glyph).center, bounds.center);
              await tester.tapAt(bounds.topLeft + const Offset(2, 2));
              await tester.pumpAndSettle();
              expect(find.text(message), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pumpAndSettle();
              expect(find.text(message), findsNothing);
              final native = tester.widget<IconButton>(button);
              expect(native.focusNode!.hasFocus, isTrue);
              await tester.sendKeyEvent(LogicalKeyboardKey.enter);
              await tester.pumpAndSettle();
              expect(find.text(message), findsOneWidget);
              await tester.sendKeyEvent(LogicalKeyboardKey.escape);
              await tester.pumpAndSettle();
              expect(native.focusNode!.hasFocus, isTrue);
            }
            expect(f.calls, isEmpty);
            expect(f.paid, 0);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  for (final timezone in [null, 'America/New_York']) {
    testWidgets(
      'cold/selection/error preserves real workspace and new query ownership $timezone',
      (tester) async {
        final f = _Fixture(timezone: timezone);
        addTearDown(f.close);
        await mount(tester, f);
        expect(f.calls, hasLength(1));
        final workspace = tester.element(find.byType(ComponentWorkspace));
        final hostState = tester.state(find.byType(host.WorkspaceHost));
        final calendar = tester.state(find.byType(CalendarGrid));
        final task = tester.state(find.byType(TasksWidget));
        final diaryToggle = find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == '展开日记',
        );
        await tester.tap(
          find
              .descendant(
                of: diaryToggle,
                matching: find.byIcon(Icons.menu_book_outlined),
              )
              .first,
        );
        await tester.pumpAndSettle();
        final diary = tester.state(find.byType(DiarySection));
        final initialGroups = f.container
            .read(workspaceDocumentProvider)
            .document
            .groups;
        expect(find.byType(CircularProgressIndicator), findsNothing);
        f.calls.first.result.completeError(
          StateError('private internal details'),
        );
        await tick(tester);
        expect(
          tester.element(find.byType(ComponentWorkspace)),
          same(workspace),
        );
        expect(tester.state(find.byType(TasksWidget)), same(task));
        expect(tester.state(find.byType(DiarySection)), same(diary));
        expect(find.textContaining('private internal'), findsNothing);
        final retries = find.byKey(const Key('dashboard_local_retry'));
        await tester.tap(retries.first);
        await tick(tester);
        expect(f.calls, hasLength(2));
        f.calls[1].result.complete(response(f.calls[1].query));
        await tester.pumpAndSettle();
        expect(
          f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          f.calls[1].query.key,
        );
        await select(tester, 1);
        expect(f.calls, hasLength(2));
        expect(f.range.selections, 0);
        final add = find.byKey(const Key('time_task_open_add'));
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('time_task_input'));
        await tester.enterText(input, 'retain synthetic unfinished text');
        await select(tester, 2);
        expect(f.calls, hasLength(3));
        expect(f.range.selections, 1);
        expect(
          f.container.read(dashboardRangeProvider).day,
          DateTime(2026, 5, 2),
        );
        expect(
          tester.element(find.byType(ComponentWorkspace)),
          same(workspace),
        );
        expect(tester.state(find.byType(host.WorkspaceHost)), same(hostState));
        expect(tester.state(find.byType(CalendarGrid)), same(calendar));
        expect(tester.state(find.byType(TasksWidget)), same(task));
        expect(tester.state(find.byType(DiarySection)), same(diary));
        expect(
          tester.widget<TextField>(input).controller!.text,
          'retain synthetic unfinished text',
        );
        expect(
          f.container.read(workspaceDocumentProvider).document.groups,
          initialGroups,
        );
        expect(
          find.text('fixture-' + f.calls[1].query.startUtc.substring(0, 10)),
          findsNothing,
        );
        expect(
          f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          isNull,
        );
        await select(tester, 2);
        expect(f.calls, hasLength(3));
        f.calls[2].result.completeError(StateError('late private details'));
        await tick(tester);
        expect(tester.state(find.byType(TasksWidget)), same(task));
        await select(tester, 2);
        expect(f.calls, hasLength(3)); // Failure needs explicit retry.
        await tester.tap(find.byKey(const Key('dashboard_refresh')));
        await tick(tester);
        expect(f.calls, hasLength(4));
        f.calls[3].result.complete(response(f.calls[3].query));
        await tester.pumpAndSettle();
        expect(
          f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          f.calls[3].query.key,
        );
        await tester.tap(find.byKey(const Key('dashboard_refresh')));
        await tick(tester);
        expect(f.calls, hasLength(5));
        expect(
          f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          f.calls[3].query.key,
        );
        f.calls[4].result.completeError(StateError('same-query refresh fails'));
        await tick(tester);
        expect(f.container.read(dashboardProvider).hasValue, isTrue);
        expect(
          f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          f.calls[3].query.key,
        );
        expect(tester.state(find.byType(TasksWidget)), same(task));
        expect(f.paid, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets('A B C late success error finally cannot replace C $timezone', (
      tester,
    ) async {
      final f = _Fixture(timezone: timezone);
      addTearDown(f.close);
      await mount(tester, f);
      await select(tester, 2);
      await select(tester, 3);
      expect(f.calls, hasLength(3));
      f.calls[2].result.complete(response(f.calls[2].query));
      await tick(tester);
      final data = f.container.read(dashboardProvider).requireValue;
      expect(
        data.apps.single.appName,
        'fixture-' + f.calls[2].query.startUtc.substring(0, 10),
      );
      final status = f.container.read(dashboardRefreshStatusProvider);
      expect(status.acceptedQueryKey, f.calls[2].query.key);
      f.calls[0].result.complete(response(f.calls[0].query));
      await tick(tester);
      f.calls[1].result.completeError(StateError('superseded error'));
      await tick(tester);
      expect(f.container.read(dashboardProvider).requireValue, same(data));
      expect(
        f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
        status.acceptedQueryKey,
      );
      expect(f.container.read(dashboardRefreshStatusProvider).error, isNull);
      await tester.tap(find.byKey(const Key('dashboard_refresh')));
      await tick(tester);
      final refresh = f.container.read(dashboardProvider.notifier).refresh();
      expect(
        f.calls,
        hasLength(4),
      ); // stale finally must not erase this flight.
      f.calls[3].result.complete(response(f.calls[3].query));
      await refresh;
      await tick(tester);
      expect(f.paid, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('same highlighted hour still selects complete custom day', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.close);
    await mount(tester, f);
    f.calls[0].result.complete(response(f.calls[0].query));
    await tester.pumpAndSettle();
    f.range.choose(
      DateRangeSelection(
        DateRange.custom,
        day: DateTime(2026, 5, 1),
        startUtc: DateTime.utc(2026, 5, 1, 1),
        endUtc: DateTime.utc(2026, 5, 1, 2),
      ),
    );
    await tick(tester);
    final count = f.calls.length;
    await select(tester, 1);
    expect(f.calls.length, count + 1);
    expect(f.container.read(dashboardRangeProvider).startUtc, isNull);
    expect(f.container.read(dashboardRangeProvider).endUtc, isNull);
    expect(f.range.selections, 1);
    await tester.pumpWidget(const SizedBox());
  });
  for (final range in [DateRange.today, DateRange.week]) {
    testWidgets(
      'same highlighted $range still selects complete custom day by numeral',
      (tester) async {
        final f = _Fixture();
        addTearDown(f.close);
        await mount(tester, f);
        f.calls[0].result.complete(response(f.calls[0].query));
        await tester.pumpAndSettle();
        f.range.choose(DateRangeSelection(range));
        await tester.pumpAndSettle();
        final highlighted = tester
            .widget<CalendarGrid>(find.byType(CalendarGrid))
            .selected;
        final count = f.calls.length;
        final date =
            '${highlighted.year}-${highlighted.month.toString().padLeft(2, '0')}-${highlighted.day.toString().padLeft(2, '0')}';
        await tester.tap(find.byKey(ValueKey('calendar_date_$date')));
        await tick(tester);
        expect(f.calls.length, count + 1);
        final selected = f.container.read(dashboardRangeProvider);
        expect(selected.range, DateRange.custom);
        expect(
          selected.day,
          DateTime(highlighted.year, highlighted.month, highlighted.day),
        );
        expect(selected.startUtc, isNull);
        expect(selected.endUtc, isNull);
        expect(f.range.selections, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('local request metadata mismatch cannot receive accepted key', (
    tester,
  ) async {
    final f = _Fixture(timezone: 'America/New_York');
    addTearDown(f.close);
    await mount(tester, f);
    f.calls[0].result.complete(
      response(f.calls[0].query, localDate: '2026-05-02'),
    );
    await tick(tester);
    expect(f.container.read(dashboardProvider).hasError, isTrue);
    expect(
      f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
      isNull,
    );
    expect(find.byType(TasksWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'wrong timezone and UTC response cannot acquire accepted ownership',
    (tester) async {
      final f = _Fixture(timezone: 'America/New_York');
      addTearDown(f.close);
      await mount(tester, f);
      f.calls[0].result.complete(
        response(f.calls[0].query, timezoneOverride: 'UTC'),
      );
      await tick(tester);
      expect(
        f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
        isNull,
      );
      expect(f.container.read(dashboardProvider).hasError, isTrue);
      f.range.choose(
        DateRangeSelection(
          DateRange.custom,
          day: DateTime(2026, 5, 1),
          startUtc: DateTime.utc(2026, 5, 1, 1),
          endUtc: DateTime.utc(2026, 5, 1, 2),
        ),
      );
      await tick(tester);
      expect(f.calls, hasLength(2));
      f.calls[1].result.complete(response(f.calls[1].query, wrongUtc: true));
      await tick(tester);
      expect(
        f.container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
        isNull,
      );
      expect(f.container.read(dashboardProvider).hasError, isTrue);
      expect(find.byType(TasksWidget), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
