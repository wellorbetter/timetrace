import 'package:timetrace_app/src/features/dashboard/providers/diary_entry_metadata_provider.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_entry_metadata_store.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'package:timetrace_app/src/features/dashboard/domain/diary_entry_metadata.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/daily_quote_line.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_heading_content.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_entry_metadata_controls.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/features/browsing/providers/accounting_snapshot_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/browsing_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/diary_generation_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/ai_connection_provider.dart';
import 'package:timetrace_app/src/features/browsing/data/diary_candidate_repository.dart';
import 'package:timetrace_app/src/features/browsing/presentation/date_range_control.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/time_tools/presentation/time_tool_widgets.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart' as core;
import 'package:timetrace_app/src/core/workspace/workspace_host.dart' as host;
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/daily_quote_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/component_workspace.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/workspace_component_registry.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/time_tools/providers/time_tools_provider.dart';

import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import '../time_tools/time_tools_state_test.dart' show MemoryTimeStore;
import '../browsing/refresh_lifecycle_test.dart' show snap;

class _PresentationBrowsing extends BrowsingNotifier {
  @override
  BrowsingState build() => BrowsingState();
  @override
  Future<void> selectRange(DateRange range) async {
    state = state.copyWith(range: DateRangeSelection(range));
  }

  @override
  Future<void> selectDay(DateTime day) async {
    state = state.copyWith(
      range: DateRangeSelection(DateRange.custom, day: day),
    );
  }
}

class _SyntheticSavedKey extends SavedDeepSeekKey {
  @override
  Future<String> build() async => '';
}

class _SyntheticEnabled extends AiEnabledNotifier {
  @override
  bool build() => false;
}

class _SyntheticModel extends DeepSeekModelNotifier {
  @override
  String build() => 'synthetic-no-request';
}

class _SyntheticCandidateRepo implements DiaryCandidateRepository {
  int reads = 0;
  @override
  Future<CandidateLoad> load() async {
    reads++;
    return CandidateLoad([]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected candidate write');
}

AccountingSnapshotDto _presentationSnap(
  AccountingQuerySpec query, {
  bool private = false,
}) {
  final original = snap(query, private: private);
  if (query.range case AccountingRangeRequest_LocalDate(
    :final localDate,
    :final timezone,
  )) {
    // The bridge owns local-date UTC resolution. Deliberately use bounds
    // distinct from Dart's nominal local-machine range, not a timezone service.
    final start = DateTime.parse(
      query.startUtc,
    ).add(const Duration(hours: 5)).toIso8601String();
    final end = DateTime.parse(
      query.endUtc,
    ).add(const Duration(hours: 5)).toIso8601String();
    return AccountingSnapshotDto(
      requestedStartUtc: start,
      requestedEndUtc: end,
      effectiveStartUtc: start,
      effectiveEndUtc: end,
      observedThroughUtc: end,
      totals: original.totals,
      intervals: original.intervals,
      apps: original.apps,
      windows: original.windows,
      pages: original.pages,
      hours: original.hours,
      integrity: original.integrity,
      localDate: localDate,
      timezone: timezone,
    );
  }
  return original;
}

Future<List<int>> paintedBytes(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

class _SyntheticMetadata implements DiaryEntryMetadataStore {
  int reads = 0, writes = 0;
  final values = <DiaryEntryKey, DiaryEntryMetadata>{};
  @override
  Future<DiaryMetadataLoad> load(DiaryEntryKey key) async {
    reads++;
    return DiaryMetadataLoad(
      values.containsKey(key)
          ? DiaryMetadataLoadStatus.loaded
          : DiaryMetadataLoadStatus.missing,
      value: values[key],
    );
  }

  @override
  Future<void> put(
    DiaryEntryMetadata value, {
    required int? expectedRevision,
  }) async {
    writes++;
    if (values[value.key]?.revision != expectedRevision)
      throw const DiaryMetadataConflict();
    values[value.key] = value;
  }
}

DailyQuoteRepository _memoryQuotes() => DailyQuoteRepository(
  read: () => {},
  write: (_) {},
  fetch: () async => offlineDailyQuotes.first,
);

class AdapterFixture {
  AdapterFixture(
    this.backend, {
    WorkspaceLayoutStore? store,
    DailyQuote? quote,
    bool dashboard = false,
  }) {
    container = ProviderContainer(
      overrides: [
        if (dashboard) ...[
          apiProvider.overrideWith(
            (ref) => throw StateError('unexpected repair API default'),
          ),
          browsingProvider.overrideWith(_PresentationBrowsing.new),
          browsingClockProvider.overrideWithValue(() => now),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshPolicyProvider.overrideWithValue(
            const DataRefreshPolicy(interval: Duration.zero),
          ),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue(
            (q) async => _presentationSnap(q),
          ),
          dashboardMetadataLoaderProvider.overrideWithValue(
            (_) => const DashboardMetadata(),
          ),
          deepSeekEnvironmentKeyProvider.overrideWithValue(''),
          deepSeekKeyProvider.overrideWithValue(''),
          savedDeepSeekKeyProvider.overrideWith(_SyntheticSavedKey.new),
          aiKeyStoreProvider.overrideWith(
            (ref) => throw StateError('unexpected repair key default'),
          ),
          aiEnabledProvider.overrideWith(_SyntheticEnabled.new),
          deepSeekModelProvider.overrideWith(_SyntheticModel.new),
          diaryRequesterProvider.overrideWithValue(
            ({required key, required model, required summary}) async =>
                throw StateError('forbidden repair paid request'),
          ),
        ],
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
        diaryEntryMetadataStoreProvider.overrideWithValue(metadata),
        diaryCandidateRepositoryProvider.overrideWithValue(candidate),
        dailyQuoteRepositoryProvider.overrideWithValue(_memoryQuotes()),
        dailyQuoteTickProvider.overrideWithValue(null),
        dailyQuoteClockProvider.overrideWithValue(() => now),
        workspaceLayoutStoreProvider.overrideWithValue(
          store ?? WorkspaceLayoutStore(backend: backend),
        ),
        timeToolsStoreProvider.overrideWithValue(time),
        timeToolsClockProvider.overrideWithValue(() => now),
        timeToolsIdProvider.overrideWithValue(
          () => 'adapter-task-' + (++ids).toString(),
        ),
        dailyQuoteProvider.overrideWith(
          (ref, day) async => quote ?? offlineDailyQuotes.first,
        ),
        calendarDataProvider.overrideWith(
          (ref) async => const CalendarData(
            images: {},
            entryImages: {},
            diaryDays: {},
            entries: [],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }
  final MemoryPreferencesBackend backend;
  final time = MemoryTimeStore();
  final metadata = _SyntheticMetadata();
  final candidate = _SyntheticCandidateRepo();
  late final ProviderContainer container;
  DateTime now = DateTime.utc(2026, 10, 3, 12);
  int ids = 0;
  WorkspaceDocumentNotifier get doc =>
      container.read(workspaceDocumentProvider.notifier);
  WorkspaceLayoutNotifier get layout =>
      container.read(workspaceLayoutProvider.notifier);
  Future<void> load() => doc.ensureLoaded();
  List<List<String>> get groups =>
      container.read(workspaceDocumentProvider).document.groups;
}

Future<void> settleWrites() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class LeaseProbe extends StatefulWidget {
  const LeaseProbe(this.id, this.created, this.disposed, {super.key});
  final String id;
  final Map<String, int> created, disposed;
  @override
  State<LeaseProbe> createState() => _LeaseProbeState();
}

class DelayedBlockedStore extends WorkspaceLayoutStore {
  DelayedBlockedStore(MemoryPreferencesBackend backend)
    : super(backend: backend);
  final first = Completer<core.WorkspaceWriteOutcome>();
  int attempts = 0;
  @override
  FutureOr<core.WorkspaceWriteOutcome> writePatch(core.WorkspacePatch patch) {
    attempts++;
    return first.future;
  }
}

class _LeaseProbeState extends State<LeaseProbe> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.id, (count) => count + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed.update(widget.id, (count) => count + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextButton(
    key: ValueKey('lease_' + widget.id),
    onPressed: () {},
    child: Text(widget.id),
  );
}

Future<void> mount(
  WidgetTester tester,
  AdapterFixture f, {
  double width = 1200,
  double scale = 1,
  bool reduceMotion = false,
  double? viewportHeight,
  Map<String, core.WorkspaceSize> sizes = const {},
  Map<WorkspaceComponent, WorkspaceBusinessBuilder> builders = const {},
}) async {
  await f.load();
  await f.container.read(timeToolsProvider.notifier).ensureLoaded();
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: const [WorkspaceEditActions()]),
          body: MediaQuery(
            data: MediaQueryData(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduceMotion,
            ),
            child: SingleChildScrollView(
              child: ComponentWorkspace(
                viewportHeight: viewportHeight,
                builders: builders,
                components: {
                  for (final component in const [
                    WorkspaceComponent.bar,
                    WorkspaceComponent.summary,
                    WorkspaceComponent.apps,
                    WorkspaceComponent.hourly,
                    WorkspaceComponent.calendar,
                  ])
                    component: TextButton(
                      key: ValueKey('visible_' + component.name),
                      onPressed: () {},
                      child: Text('BODY_' + component.name),
                    ),
                  WorkspaceComponent.diary: const SizedBox(
                    height: 860,
                    child: TextField(key: Key('registry_diary_draft')),
                  ),
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PoetryMenuAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PoetryMenuAppBar();
  @override
  Size get preferredSize => const Size.fromHeight(56);
  @override
  Widget build(BuildContext context) =>
      AppBar(actions: const [WorkspaceEditActions()]);
}

void main() {
  _acceptanceUsabilityTests();

  // Synthetic OUTER-to-client budgets, not native frame measurements.
  // Standard:16 horizontal frame and48 total caption/frame height.
  // Immersive:0 native horizontal frame and48 Flutter caption height.
  for (final frame in ['standard', 'immersive']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'three-block real dashboard collapsed diary fits client $frame scale$scale',
        (tester) async {
          final outerWidth = scale == 1 ? 1280.0 : 720.0;
          final outerHeight = scale == 1 ? 900.0 : 640.0;
          final clientWidth = outerWidth - (frame == 'standard' ? 16 : 0);
          final clientHeight = outerHeight - 48;
          final text = '清风明月照山河，行行复行行，山水相依映日长。';
          final quote = DailyQuote.full(
            text,
            '合成作者《合成作品》',
            online: true,
            author: '合成作者',
            work: '合成作品',
            dynasty: '合成时代',
            sourceUrl: dailyPoemEndpoint,
            fullContent: [text, '合成末句，完整保留。'],
          );
          final backend = MemoryPreferencesBackend();
          final f = AdapterFixture(backend, dashboard: true, quote: quote);
          await f.load();
          // Local overrides only: do not replace every old AdapterFixture.
          final visual = ProviderContainer(parent: f.container, overrides: [
            uiPreferencesBackendProvider.overrideWithValue(backend),
            diaryCandidateClockProvider.overrideWithValue(() => f.now.toUtc()),
            diaryCandidateIdProvider.overrideWithValue(() => 'window-fixture-candidate'),
          ]);
          addTearDown(visual.dispose);
          tester.view.physicalSize = Size(clientWidth, clientHeight);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff58694f));
          await tester.pumpWidget(UncontrolledProviderScope(
            container: visual,
            child: MaterialApp(
              theme: ThemeData(colorScheme: scheme),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(clientWidth, clientHeight),
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                ),
                child: MaterialScope(
                  policy: MaterialPolicy.resolve(
                    colorScheme: scheme,
                    wallpaper: WallpaperLoadState.absent,
                    signals: const MaterialSignals(
                      highContrast: AccessibilitySignal.disabled,
                      reduceTransparency: AccessibilitySignal.enabled,
                    ),
                  ),
                  tokens: MaterialTokens.forWidth(clientWidth),
                  child: const Padding(
                    padding: EdgeInsets.only(left: 65),
                    child: DashboardScreen(),
                  ),
                ),
              ),
            ),
          ));
          await tester.pumpAndSettle();
          expect(f.groups, [
            ['calendar'],
            ['bar', 'summary', 'apps', 'hourly'],
            ['diary'],
          ]);
          expect(find.byType(WorkspacePoetryContent), findsNothing);
          final diary = find.byKey(const Key('workspace_component_diary'));
          final heading = find.descendant(of: diary, matching: find.byType(DiaryHeadingContent));
          final headingQuote = find.descendant(of: diary, matching: find.byType(DailyQuoteLine));
          expect(heading, findsOneWidget);
          expect(tester.widget<DiaryHeadingContent>(heading).showQuote, isTrue);
          expect(headingQuote, findsOneWidget);
          expect(find.text(text), findsOneWidget);
          final hostState = tester.state<host.WorkspaceHostState>(find.byType(host.WorkspaceHost));
          final left = find.byKey(const Key('workspace_left_viewport'));
          final viewport = tester.getRect(left);
          final page = tester.getRect(find.byType(DashboardScreen));
          final appBar = tester.getRect(find.byType(AppBar));
          final date = tester.getRect(find.byType(DateRangeControl));
          // Actual AppBar/date/body chrome and real business builders render;
          // this never substitutes a nominal320 height for their geometry.
          expect(page.size, Size(clientWidth - 65, clientHeight));
          expect(viewport.top, greaterThanOrEqualTo(date.bottom));
          expect(date.top, greaterThanOrEqualTo(appBar.bottom));
          expect(hostState.geometry!.groups, hasLength(3));
          expect(hostState.geometry!.parentWidth, closeTo(viewport.width, .01));
          if (scale == 1) {
            final calendar = tester.getRect(find.byKey(const Key('workspace_component_calendar')));
            final data = tester.getRect(find.byKey(const Key('workspace_component_bar')));
            expect(calendar.top, closeTo(data.top, .01));
            expect(data.left, greaterThan(calendar.right));
            expect(calendar.bottom, lessThanOrEqualTo(viewport.bottom + .01));
            expect(data.bottom, lessThanOrEqualTo(viewport.bottom + .01));
            expect(tester.getRect(diary).top, greaterThan(data.bottom));
            expect(tester.getRect(diary).bottom, lessThanOrEqualTo(viewport.bottom + .01));
            expect(tester.getRect(headingQuote).bottom, lessThanOrEqualTo(viewport.bottom + .01));
            expect(tester.widget<SingleChildScrollView>(left).controller!.offset, 0);
          } else {
            expect(hostState.geometry!.groups[1].top,
                greaterThan(hostState.geometry!.groups[0].bottom));
            final scroll = tester.widget<SingleChildScrollView>(left).controller!;
            expect(scroll.position.maxScrollExtent, greaterThan(0));
            await tester.ensureVisible(heading);
            await tester.pumpAndSettle();
            expect(heading.hitTestable(), findsOneWidget);
          }
          expect(backend.commits, 0);
          expect(backend.files, isEmpty);
          expect(f.metadata.writes, 0);
          // Real diary metadata watches candidates and initializes its one
          // empty in-memory load; the fixture still traps every candidate write.
          expect(f.candidate.reads, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          // Unmount schedules a zero-duration provider-dispose timer. Drain it
          // before the binding invariant; registered tearDown stays child-first
          // (visual before f.container), also covering assertion error paths.
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 10),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 1),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final width in [280.0, 360.0, 719.0, 720.0, 1099.0, 1100.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('confirmed default actual host geometry width$width scale$scale', (tester) async {
        final backend = MemoryPreferencesBackend();
        final f = AdapterFixture(backend);
        await mount(tester, f, width: width, scale: scale, viewportHeight: 650);
        expect(f.groups, [
          ['calendar'],
          ['bar', 'summary', 'apps', 'hourly'],
          ['diary'],
        ]);
        expect(backend.commits, 0);
        expect(backend.files, isEmpty);
        final hostState = tester.state<host.WorkspaceHostState>(find.byType(host.WorkspaceHost));
        final geometry = hostState.geometry!;
        final actualWidth = tester.getSize(find.byKey(const Key('workspace_left_viewport'))).width;
        expect(geometry.parentWidth, closeTo(actualWidth, .01));
        expect(actualWidth, closeTo(width, .01));
        expect(geometry.groups, hasLength(3));
        final calendar = geometry.groups[0], data = geometry.groups[1];
        final diary = geometry.groups[2];
        expect(calendar.left, 0);
        expect(diary.width, closeTo(actualWidth, .01));

        if (actualWidth >= 720) {
          expect(calendar.top, closeTo(data.top, .01));
          expect(data.left, greaterThan(calendar.right));
          expect(calendar.width, closeTo(data.width, .01));
          expect(diary.top, greaterThan(data.bottom));
        } else {
          expect(calendar.width, closeTo(actualWidth, .01));
          expect(data.width, closeTo(actualWidth, .01));
          expect(data.top, greaterThan(calendar.bottom));
          expect(diary.top, greaterThan(data.bottom));
        }
        expect(find.byType(WorkspacePoetryContent), findsNothing);
        expect(find.byKey(const Key('daily_poetry_refresh')), findsNothing);
        // Explicitly adding optional poetry preserves the original fullNatural
        // geometry and control assertions without making it a product default.
        await f.layout.reveal(WorkspaceComponent.dailyPoetry);
        await f.layout.setSize(WorkspaceComponent.dailyPoetry, core.WorkspaceSize.fullNatural);
        await tester.pumpAndSettle();
        final poetry = hostState.geometry!.groups.last;
        expect(poetry.width, closeTo(actualWidth, .01));
        expect(poetry.left, 0);
        expect(poetry.top, greaterThan(diary.bottom));
        expect(find.byType(WorkspacePoetryContent), findsOneWidget);
        expect(find.byKey(const Key('daily_poetry_refresh')), findsOneWidget);
        expect(find.byKey(const Key('daily_poetry_expand')), findsOneWidget);
        expect(find.byType(PomodoroWidget), findsNothing);
        expect(find.byType(TasksWidget), findsNothing);
        expect(find.byType(CountdownWidget), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('daily_poetry_expand')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_expand')).hitTestable(), findsOneWidget);
        expect(tester.getSize(find.byKey(const Key('daily_poetry_refresh'))), const Size(48, 48));
        expect(tester.getSize(find.byKey(const Key('daily_poetry_expand'))).height, greaterThanOrEqualTo(48));
        expect(backend.commits, 2); // explicit reveal and explicit resize only
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final width in [
    760.0,
    720.0 + 168 + MaterialTokens.spaceLg - 1,
    720.0 + 168 + MaterialTokens.spaceLg,
    1100.0,
  ]) {
    testWidgets('confirmed default shelf uses actual parent width and independent scroll $width', (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend());
      await mount(tester, f, width: width, scale: 2, viewportHeight: 650);
      final left = find.byKey(const Key('workspace_left_viewport'));
      final state = tester.state<host.WorkspaceHostState>(find.byType(host.WorkspaceHost));
      expect(state.geometry!.parentWidth, closeTo(width, .01));
      await tester.tap(find.byKey(const Key('workspace_toggle_shelf')));
      await tester.pumpAndSettle();
      final right = find.byKey(const Key('workspace_right_viewport'));
      final shelf = find.byKey(const Key('workspace_component_shelf'));
      final actualWidth = tester.getSize(left).width;
      expect(tester.getSize(right).width, 168);
      expect(actualWidth, closeTo(width - 168 - MaterialTokens.spaceLg, .01));
      expect(state.geometry!.parentWidth, closeTo(actualWidth, .01));
      final geometry = state.geometry!;
      if (actualWidth < 720) {
        expect(geometry.groups[1].top, greaterThan(geometry.groups[0].bottom));
      } else {
        expect(geometry.groups[0].top, closeTo(geometry.groups[1].top, .01));
      }
      final shelfRect = tester.getRect(right);
      final leftWidget = tester.widget<SingleChildScrollView>(left);
      final rightWidget = tester.widget<CustomScrollView>(right);
      expect(identical(leftWidget.controller, rightWidget.controller), isFalse);
      final rightBefore = rightWidget.controller!.offset;
      await tester.drag(left, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(leftWidget.controller!.offset, greaterThan(0));
      expect(rightWidget.controller!.offset, rightBefore);
      expect(tester.getRect(right), shelfRect);
      expect(shelf, findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_toggle_shelf')));
      await tester.pumpAndSettle();
      expect(right, findsNothing);
      expect(state.geometry!.parentWidth, closeTo(width, .01));
      expect(f.backend.commits, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final scoped in [false, true]) {
      testWidgets(
        'simple block previews are pure and size-aware $brightness scope$scoped',
        (tester) async {
          final f = AdapterFixture(MemoryPreferencesBackend(), dashboard: true);
          final scheme = ColorScheme.fromSeed(
            seedColor: const Color(0xff58694f),
            brightness: brightness,
          );
          final registry = createWorkspaceRegistry(
            builders: {
              for (final component in WorkspaceComponent.values)
                component: (_, _) =>
                    throw StateError('preview mounted business content'),
            },
          );
          for (final component in WorkspaceComponent.values) {
            final descriptor = registry[component.name]!;
            for (final size in descriptor.supportedSizes) {
              Widget preview = SizedBox(
                width: 160,
                height: 104,
                child: host.WorkspaceThumbnail(
                  descriptor: descriptor,
                  size: size,
                ),
              );
              if (scoped) {
                preview = MaterialScope(
                  policy: MaterialPolicy.resolve(
                    colorScheme: scheme,
                    wallpaper: WallpaperLoadState.absent,
                    signals: const MaterialSignals(
                      highContrast: AccessibilitySignal.disabled,
                      reduceTransparency: AccessibilitySignal.disabled,
                    ),
                  ),
                  tokens: MaterialTokens.forWidth(480),
                  child: preview,
                );
              }
              await tester.pumpWidget(
                UncontrolledProviderScope(
                  container: f.container,
                  child: MaterialApp(
                    theme: ThemeData(colorScheme: scheme),
                    home: Scaffold(body: Center(child: preview)),
                  ),
                ),
              );
              await tester.pump();
              final miniature = find.byType(WorkspaceComponentMiniature);
              expect(miniature, findsOneWidget);
              expect(
                tester.widget<WorkspaceComponentMiniature>(miniature).size,
                same(size),
              );
              expect(
                find.descendant(of: miniature, matching: find.byType(RichText)),
                findsNothing,
              );
              expect(find.byType(BackdropFilter), findsNothing);
              final frame = tester.getRect(
                find.byKey(
                  ValueKey(
                    'workspace_thumbnail_frame_${component.name}_${host.workspaceSizeName(size)}',
                  ),
                ),
              );
              expect(frame.width, greaterThan(0));
              expect(frame.height, greaterThan(0));
              expect(frame.width, lessThanOrEqualTo(160));
              expect(frame.height, lessThanOrEqualTo(104));
              expect(tester.getRect(miniature), frame);
              expect(tester.takeException(), isNull);
            }
          }
          // The fixture traps bridge/key/paid-request defaults. Pure previews
          // also leave injected storage, candidate loading and tool IDs unused.
          expect(f.metadata.reads, 0);
          expect(f.metadata.writes, 0);
          expect(f.candidate.reads, 0);
          expect(f.time.writes, isEmpty);
          expect(f.ids, 0);
          expect(f.backend.commits, 0);
          expect(f.backend.files, isEmpty);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final bounded in [true, false]) {
    for (final legacy in [true, false]) {
      for (final width in [280.0, 1200.0]) {
        for (final scale in [1.0, 2.0]) {
          for (final brightness in Brightness.values) {
            testWidgets(
              'repair finite poetry bounded$bounded legacy$legacy width$width scale$scale $brightness',
              (tester) async {
                final f = AdapterFixture(
                  MemoryPreferencesBackend(),
                  quote: offlineDailyQuotes.first,
                );
                final scheme = ColorScheme.fromSeed(
                  seedColor: const Color(0xff58694f),
                  brightness: brightness,
                );
                final layout = host.WorkspaceContentLayout(
                  constraints: BoxConstraints(
                    maxWidth: width,
                    maxHeight: bounded ? 154 : double.infinity,
                  ),
                  persistedSize: core.WorkspaceSize.fullNatural,
                  displaySize: core.WorkspaceSize.fullNatural,
                  contentRevision: 0,
                );
                await tester.pumpWidget(
                  UncontrolledProviderScope(
                    container: f.container,
                    child: MaterialApp(
                      theme: ThemeData(colorScheme: scheme),
                      home: Scaffold(
                        body: MaterialScope(
                          policy: MaterialPolicy.resolve(
                            colorScheme: scheme,
                            wallpaper: WallpaperLoadState.absent,
                            signals: const MaterialSignals(
                              highContrast: AccessibilitySignal.disabled,
                              reduceTransparency: AccessibilitySignal.disabled,
                            ),
                          ),
                          tokens: MaterialTokens.forWidth(width),
                          child: MediaQuery(
                            data: MediaQueryData(
                              size: Size(width, 800),
                              textScaler: TextScaler.linear(scale),
                            ),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: SizedBox(
                                width: width,
                                height: bounded ? 154 : 700,
                                child: Builder(
                                  builder: (context) {
                                    final child = legacy
                                        ? const MaterialCard(
                                            margin: EdgeInsets.zero,
                                            child: WorkspacePoetryContent(),
                                          )
                                        : createWorkspaceRegistry()['dailyPoetry']!
                                              .contentBuilder(context, layout);
                                    return bounded
                                        ? child
                                        : SingleChildScrollView(child: child);
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
                await tester.pumpAndSettle();
                final poetry = find.byType(WorkspacePoetryContent),
                    body = find.byType(DailyQuoteLine);
                expect(poetry, findsOneWidget);
                expect(
                  tester
                      .renderObject<RenderBox>(body)
                      .constraints
                      .hasBoundedHeight,
                  bounded,
                );
                final frame = tester.getRect(poetry);
                for (final key in [
                  'daily_poetry_refresh',
                  'daily_poetry_expand',
                ]) {
                  final action = find.byKey(Key(key));
                  expect(action, findsOneWidget);
                  final bounds = tester.getRect(action);
                  expect(bounds.height, key == 'daily_poetry_refresh' ? 48 : greaterThanOrEqualTo(48));
                  expect(bounds.width, greaterThanOrEqualTo(48));
                  expect(bounds.left, greaterThanOrEqualTo(frame.left));
                  expect(bounds.right, lessThanOrEqualTo(frame.right));
                  if (key == 'daily_poetry_refresh') {
                    expect(bounds.bottom, lessThanOrEqualTo(frame.bottom));
                  } else {
                    // The excerpt lives in the bounded body scroll viewport.
                    expect(bounds.overlaps(frame), isTrue);
                    expect(action.hitTestable(), findsOneWidget);
                  }
                }
                final lease = body.evaluate().single;
                await tester.tap(find.byKey(const Key('daily_poetry_expand')));
                await tester.pumpAndSettle();
                expect(
                  find.byKey(const Key('daily_poetry_full_text')),
                  findsOneWidget,
                );
                await tester.tap(find.text('收起'));
                await tester.pumpAndSettle();
                expect(body.evaluate().single, same(lease));
                expect(f.metadata.writes, 0);
                expect(f.candidate.reads, 0);
                expect(f.backend.commits, 0);
                expect(tester.takeException(), isNull);
                await tester.pumpWidget(const SizedBox());
              },
            );
          }
        }
      }
    }
  }
  for (final width in [280.0, 360.0, 480.0, 720.0, 1100.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'repair toolbar real remaining width$width scale$scale $brightness',
          (tester) async {
            final f = AdapterFixture(
              MemoryPreferencesBackend(
                jsonEncode({'version': 1, 'workspaceGroupsV2': []}),
              ),
              dashboard: true,
            );
            await f.load();
            await f.container.read(timeToolsProvider.notifier).ensureLoaded();
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final scheme = ColorScheme.fromSeed(
              seedColor: const Color(0xff58694f),
              brightness: brightness,
            );
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: f.container,
                child: MaterialApp(
                  theme: ThemeData(colorScheme: scheme),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 900),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: MaterialScope(
                      policy: MaterialPolicy.resolve(
                        colorScheme: scheme,
                        wallpaper: WallpaperLoadState.absent,
                        signals: const MaterialSignals(
                          highContrast: AccessibilitySignal.disabled,
                          reduceTransparency: AccessibilitySignal.disabled,
                        ),
                      ),
                      tokens: MaterialTokens.forWidth(width),
                      child: const Padding(
                        padding: EdgeInsets.only(left: 65),
                        child: DashboardScreen(),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final appbar = find.byType(AppBar);
            void checkToolbar({required bool editing}) {
              expect(
                MediaQuery.textScalerOf(
                  tester.element(find.byType(WorkspaceEditActions)),
                ).scale(14),
                14 * scale,
              );
              final bar = tester.getRect(appbar);
              final toolbar = tester.getRect(
                find.byKey(const Key('workspace_toolbar_bounds')),
              );
              final availableWidth = bar.width - 2 * MaterialTokens.spaceMd;
              expect(toolbar.width, closeTo(availableWidth, .001));
              expect(
                toolbar.right,
                closeTo(bar.right - MaterialTokens.spaceMd, .001),
              );
              expect(
                tester.getRect(find.byKey(const Key('dashboard_refresh'))).right,
                closeTo(toolbar.right, .001),
              );
              expect(
                toolbar.height,
                closeTo(
                  WorkspaceEditActions.heightFor(
                    tester.element(find.byType(WorkspaceEditActions)),
                    availableWidth,
                    editing: editing,
                    trailingCount: 2,
                  ),
                  .001,
                ),
              );
              expect(
                bar.height,
                closeTo(toolbar.height + MaterialTokens.spaceSm, .001),
              );
              expect(
                tester.getRect(find.byType(DateRangeControl)).top,
                greaterThanOrEqualTo(bar.bottom),
              );
            }

            checkToolbar(editing: false);
            void check(String key) {
              final action = find.byKey(Key(key)),
                  bounds = tester.getRect(action),
                  bar = tester.getRect(appbar);
              expect(bounds.size, const Size(48, 48));
              expect(bounds.left, greaterThanOrEqualTo(bar.left));
              expect(bounds.right, lessThanOrEqualTo(bar.right));
              expect(bounds.top, greaterThanOrEqualTo(bar.top));
              expect(bounds.bottom, lessThanOrEqualTo(bar.bottom));
            }

            for (final key in [
              'workspace_toggle_shelf',
              'workspace_edit_layout',
              'workspace_recap',
              'dashboard_refresh',
            ])
              check(key);
            if (width == 720)
              expect(
                tester
                    .getRect(find.byKey(const Key('workspace_edit_layout')))
                    .top,
                tester.getRect(find.byKey(const Key('dashboard_refresh'))).top,
              );
            await tester.tap(find.byKey(const Key('workspace_edit_layout')));
            await tester.pumpAndSettle();
            checkToolbar(editing: true);
            for (final key in [
              'workspace_edit_help',
              'workspace_edit_layout',
              'workspace_recap',
              'dashboard_refresh',
            ])
              check(key);
            final reset = find.ancestor(
              of: find.text('恢复默认'),
              matching: find.byType(FilledButton),
            );
            expect(tester.getSize(reset).height, 48);
            expect(
              tester.getRect(reset).right,
              lessThanOrEqualTo(tester.getRect(appbar).right),
            );
            final helpButton = find.descendant(
              of: find.byKey(const Key('workspace_edit_help')),
              matching: find.byType(IconButton),
            );
            tester.widget<IconButton>(helpButton).focusNode!.requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('context_help_surface')),
              findsOneWidget,
            );
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            expect(
              tester.widget<IconButton>(helpButton).focusNode!.hasFocus,
              isTrue,
            );
            await tester.tap(find.byKey(const Key('workspace_recap')));
            await tester.pumpAndSettle();
            expect(find.text('还没有候选，选择本地整理或 AI 生成'), findsOneWidget);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('workspace_edit_layout')));
            await tester.pumpAndSettle();
            expect(f.container.read(workspaceEditProvider), isFalse);
            expect(f.metadata.writes, 0);
            expect(f.candidate.reads, 1);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  Future<void> mountPoetryMenu(WidgetTester tester, AdapterFixture f) async {
    await f.load();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: f.container,
        child: const MaterialApp(
          home: Scaffold(
            appBar: _PoetryMenuAppBar(),
            body: SizedBox(
              height: 700,
              child: ComponentWorkspace(viewportHeight: 700),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [
    core.WorkspaceSize.twoByOne,
    core.WorkspaceSize.twoByTwo,
    core.WorkspaceSize.twoByThree,
    core.WorkspaceSize.fullNatural,
  ]) {
    for (final scale in [1.0, 2.0]) {
      for (final long in [false, true]) {
        testWidgets(
          'real registry poetry body constraints ${host.workspaceSizeName(size)} scale$scale long$long',
          (tester) async {
            final backend = MemoryPreferencesBackend(
              jsonEncode({
                'version': 1,
                'workspaceLayoutV3': {
                  'version': 3,
                  'groups': [
                    ['dailyPoetry'],
                  ],
                  'sizes': {'dailyPoetry': size.toJson()},
                },
              }),
            );
            final quote = long
                ? DailyQuote.full(
                    '合成诗句，保留完整正文。',
                    '测试作品',
                    author: '合成作者',
                    work: '合成作品',
                    dynasty: '测试',
                    sourceUrl: 'https://example.invalid/synthetic',
                    fullContent: List.generate(
                      24,
                      (i) => i == 0 ? '合成诗句，保留完整正文。' : '测试长正文第$i行。',
                    ),
                  )
                : const DailyQuote('合成短句', '测试');
            final f = AdapterFixture(backend, quote: quote);
            await f.load();
            tester.view.physicalSize = const Size(1200, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: f.container,
                child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
                  home: const Scaffold(
                    body: SizedBox(
                      height: 700,
                      child: ComponentWorkspace(viewportHeight: 700),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final content = find.byType(WorkspacePoetryContent);
            expect(content, findsOneWidget);
            final bridge = tester.widget<WorkspacePoetryContent>(content);
            expect(bridge.layout, isNotNull);
            expect(bridge.layout!.displaySize.sameExtent(size), isTrue);
            final body = find.descendant(
              of: content,
              matching: find.byType(DailyQuoteLine),
            );
            final box = tester.renderObject<RenderBox>(body);
            expect(box.constraints.hasBoundedHeight, !size.isNatural);
            expect(box.size.height, greaterThan(0));
            expect(box.size.width, greaterThan(0));
            final parent = tester.getRect(content);
            expect(
              tester.getRect(body).bottom,
              lessThanOrEqualTo(parent.bottom + .01),
            );
            // Heading now belongs to the line; prose starts below its first row.
            final heading = find.descendant(
              of: body, matching: find.text('每日诗词'),
            );
            final next = find.descendant(
              of: body, matching: find.byKey(const Key('daily_poetry_refresh')),
            );
            final verse = find.descendant(
              of: body, matching: find.byKey(const Key('daily_poetry_text')),
            );
            final reader = find.descendant(
              of: body, matching: find.byKey(const Key('daily_poetry_expand')),
            );
            expect(heading, findsOneWidget);
            expect(next, findsOneWidget);
            expect(verse, findsOneWidget);
            if (quote.hasFullPoem) {
              expect(reader, findsOneWidget);
            } else {
              expect(reader, findsNothing);
            }
            final headingBounds = tester.getRect(heading);
            final nextBounds = tester.getRect(next);
            final verseBounds = tester.getRect(verse);
            expect(tester.getSize(next), const Size(48, 48));
            expect(nextBounds.top, closeTo(tester.getRect(body).top, .01));
            expect(nextBounds.right, closeTo(tester.getRect(body).right, .01));
            expect(headingBounds.overlaps(nextBounds), isFalse);
            expect(verseBounds.top, greaterThanOrEqualTo(headingBounds.bottom));
            expect(verseBounds.top, greaterThanOrEqualTo(nextBounds.bottom));
            if (quote.hasFullPoem) {
              expect(tester.getRect(reader).top, greaterThanOrEqualTo(nextBounds.bottom));
            }
            expect(verseBounds.overlaps(nextBounds), isFalse);
            expect(
              find
                  .ancestor(
                    of: body,
                    matching: find.byType(SingleChildScrollView),
                  )
                  .evaluate()
                  .where(
                    (e) =>
                        content.evaluate().single == e ||
                        e
                                .findAncestorWidgetOfExactType<
                                  WorkspacePoetryContent
                                >() !=
                            null,
                  ),
              isEmpty,
            );
            expect(f.metadata.writes, 0);
            expect(f.candidate.reads, 0);
            expect(backend.commits, 0);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  testWidgets(
    'poetry size menu persists finite bridge and same lease across reopen',
    (tester) async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'workspaceLayoutV3': {
            'version': 3,
            'groups': [
              ['dailyPoetry'],
            ],
            'sizes': {'dailyPoetry': core.WorkspaceSize.twoByOne.toJson()},
          },
        }),
      );
      final f = AdapterFixture(backend);
      await mountPoetryMenu(tester, f);
      final before = find.byType(DailyQuoteLine).evaluate().single;
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final menu = find.byKey(const Key('workspace_resize_dailyPoetry'));
      expect(tester.getSize(menu), const Size(48, 48));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace_resize_dailyPoetry_S')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('workspace_resize_dailyPoetry_XL')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DailyQuoteLine).evaluate().single, same(before));
      expect(
        tester
            .renderObject<RenderBox>(find.byType(DailyQuoteLine))
            .constraints
            .hasBoundedHeight,
        isTrue,
      );
      final fresh = AdapterFixture(backend);
      await fresh.load();
      expect(
        fresh.container
            .read(workspaceDocumentProvider)
            .document
            .sizes['dailyPoetry']!
            .sameExtent(core.WorkspaceSize.twoByThree),
        isTrue,
      );
      await mountPoetryMenu(tester, fresh);
      expect(
        tester
            .widget<WorkspacePoetryContent>(find.byType(WorkspacePoetryContent))
            .layout!
            .displaySize
            .sameExtent(core.WorkspaceSize.twoByThree),
        isTrue,
      );
      expect(
        tester
            .renderObject<RenderBox>(find.byType(DailyQuoteLine))
            .constraints
            .hasBoundedHeight,
        isTrue,
      );
      expect(f.metadata.writes, 0);
      expect(f.candidate.reads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
  for (final width in [480.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'workspace top actions keep 48dp aligned baseline width$width scale$scale',
        (tester) async {
          final f = AdapterFixture(MemoryPreferencesBackend());
          await f.load();
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: f.container,
              child: MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: Align(
                    alignment: Alignment.topRight,
                    child: WorkspaceEditActions(),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final edit = find.byKey(const Key('workspace_edit_layout'));
          final shelf = find.byKey(const Key('workspace_toggle_shelf'));
          expect(tester.getSize(edit), const Size(48, 48));
          expect(tester.getSize(shelf), const Size(48, 48));
          expect(tester.getRect(edit).top, tester.getRect(shelf).top);
          await tester.tap(edit);
          await tester.pumpAndSettle();
          final help = find.byKey(const Key('workspace_edit_help'));
          expect(tester.getSize(help), const Size(48, 48));
          expect(tester.getSize(edit), const Size(48, 48));
          final reset = find.ancestor(
            of: find.text('恢复默认'),
            matching: find.byType(FilledButton),
          );
          expect(tester.getSize(reset).height, 48);
          expect(tester.getRect(help).top, tester.getRect(edit).top);
          expect(tester.getRect(reset).top, tester.getRect(edit).top);
          expect(
            f.container.read(diaryDraftTagsStoreProvider),
            isA<MemoryDiaryDraftTagsStore>(),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'size-aware registry previews paint every component at loose and tight spans without business IO',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend());
      final registry = createWorkspaceRegistry(
        builders: {
          for (final type in WorkspaceComponent.values)
            type: (_, _) => throw StateError('business preview forbidden'),
        },
      );
      for (final budget in [const Size(160, 104), const Size(56, 48)]) {
        for (final size in core.WorkspaceSize.values) {
          final images = <String>{};
          for (final type in WorkspaceComponent.values) {
            final descriptor = registry[type.name]!;
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: f.container,
                child: MaterialApp(
                  home: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: budget.width,
                        height: budget.height,
                        child: RepaintBoundary(
                          key: const Key('size-preview-pixels'),
                          child: host.WorkspaceThumbnail(
                            descriptor: descriptor,
                            size: size,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final frame = tester.getSize(
              find.byKey(
                ValueKey(
                  'workspace_thumbnail_frame_${type.name}_${host.workspaceSizeName(size)}',
                ),
              ),
            );
            expect(frame.width, greaterThan(0));
            expect(frame.height, greaterThan(0));
            expect(frame.width, lessThanOrEqualTo(budget.width));
            expect(frame.height, lessThanOrEqualTo(budget.height));
            if (size.isNatural) expect(find.text('整行示意'), findsOneWidget);
            final rgba = await paintedBytes(
              tester,
              find.byKey(const Key('size-preview-pixels')),
            );
            expect(
              rgba.toSet().length,
              greaterThan(8),
              reason: '${type.name}/${size.label}/$budget',
            );
            images.add(base64Encode(rgba));
            expect(tester.takeException(), isNull);
          }
          expect(images, hasLength(WorkspaceComponent.values.length));
        }
      }
      expect(f.time.writes, isEmpty);
      expect(f.ids, 0);
      expect(f.backend.files, isEmpty);
      expect(
        f.container.read(diaryDraftTagsStoreProvider),
        isA<MemoryDiaryDraftTagsStore>(),
      );
    },
  );
  testWidgets(
    'task due and confirmed source tags survive explicit quote replacement and stack switching',
    (tester) async {
      final f = AdapterFixture(
        MemoryPreferencesBackend(
          jsonEncode({
            'version': 1,
            'workspaceGroupsV2': [
              ['tasks'],
              ['diary', 'dailyPoetry'],
            ],
          }),
        ),
      );
      final entryKey = DiaryEntryKey('2026-10-03', 7);
      f.metadata.values[entryKey] = DiaryEntryMetadata(
        key: entryKey,
        source: DiaryEntrySource.ai,
        tags: ['合成标签'],
      );
      final tools = f.container.read(timeToolsProvider.notifier);
      await tools.ensureLoaded();
      final due = f.now.add(const Duration(hours: 1));
      expect(tools.addTask('合成带截止任务', dueAtUtc: due), isTrue);
      await tools.flush();
      await mount(
        tester,
        f,
        builders: {
          WorkspaceComponent.diary: (_, layout) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DiaryHeadingContent(
                date: DateTime(2026, 10, 3),
                showQuote: !layout.visibleIds.contains(
                  WorkspaceComponent.dailyPoetry.name,
                ),
              ),
              DiaryEntryMetadataControls(entryKey: entryKey),
            ],
          ),
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('合成带截止任务'), findsOneWidget);
      expect(find.textContaining('预计：'), findsOneWidget);
      expect(find.text('AI 生成'), findsOneWidget);
      expect(find.text('合成标签'), findsOneWidget);
      await f.container
          .read(diaryEntryMetadataProvider(entryKey).notifier)
          .setTags(['合成标签', '补充']);
      await tester.pumpAndSettle();
      expect(f.metadata.values[entryKey]!.source, DiaryEntrySource.ai);
      expect(f.metadata.values[entryKey]!.tags, ['合成标签', '补充']);
      final embeddedRefresh = find.descendant(
        of: find.byKey(const Key('workspace_component_diary')),
        matching: find.byKey(const Key('daily_poetry_refresh')),
      );
      await tester.ensureVisible(embeddedRefresh);
      await tester.tap(embeddedRefresh);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('workspace_switch_dailyPoetry')),
      );
      await tester.tap(find.byKey(const Key('workspace_switch_dailyPoetry')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('workspace_switch_diary')),
      );
      await tester.tap(find.byKey(const Key('workspace_switch_diary')));
      await tester.pumpAndSettle();
      expect(
        f.container.read(timeToolsProvider).data.tasks.single.dueAtUtc,
        due,
      );
      expect(f.metadata.values[entryKey]!.source, DiaryEntrySource.ai);
      expect(find.text('AI 生成'), findsOneWidget);
      expect(find.text('合成标签'), findsOneWidget);
      expect(find.text('补充'), findsOneWidget);
      expect(f.candidate.reads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'real dashboard diary follows selected poetry; shelf hidden and inactive stack do not suppress',
    (tester) async {
      var now = DateTime(2026, 10, 3, 12), paidRequests = 0;
      final time = MemoryTimeStore(),
          repo = _SyntheticCandidateRepo(),
          metadata = _SyntheticMetadata();
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'workspaceLayoutV3': {
            'version': 3,
            'groups': [
              ['diary'],
              ['dailyPoetry', 'tasks'],
              ['future'],
            ],
            'sizes': {
              'diary': core.WorkspaceSize.fullNatural.toJson(),
              'dailyPoetry': core.WorkspaceSize.twoByTwo.toJson(),
              'tasks': core.WorkspaceSize.twoByTwo.toJson(),
            },
          },
        }),
      );
      final container = ProviderContainer(
        overrides: [
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
          diaryEntryMetadataStoreProvider.overrideWithValue(metadata),
          dailyQuoteRepositoryProvider.overrideWithValue(_memoryQuotes()),
          dailyQuoteTickProvider.overrideWithValue(null),
          dailyQuoteClockProvider.overrideWithValue(() => now),
          apiProvider.overrideWith(
            (ref) => throw StateError('unexpected synthetic API read'),
          ),
          browsingProvider.overrideWith(_PresentationBrowsing.new),
          browsingClockProvider.overrideWithValue(() => now),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshPolicyProvider.overrideWithValue(
            const DataRefreshPolicy(interval: Duration.zero),
          ),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue(
            (query) async => _presentationSnap(query),
          ),
          dashboardMetadataLoaderProvider.overrideWithValue(
            (_) => const DashboardMetadata(),
          ),
          workspaceLayoutStoreProvider.overrideWithValue(
            WorkspaceLayoutStore(backend: backend),
          ),
          timeToolsStoreProvider.overrideWithValue(time),
          timeToolsClockProvider.overrideWithValue(() => now),
          timeToolsIdProvider.overrideWithValue(() => 'synthetic-task'),
          calendarDataProvider.overrideWith(
            (ref) async => const CalendarData(
              images: {},
              entryImages: {},
              diaryDays: {},
              entries: [],
            ),
          ),
          dailyQuoteProvider.overrideWith(
            (ref, day) async => offlineDailyQuotes.first,
          ),
          diaryCandidateRepositoryProvider.overrideWithValue(repo),
          diaryCandidateClockProvider.overrideWithValue(() => now.toUtc()),
          diaryCandidateIdProvider.overrideWithValue(
            () => 'synthetic-candidate',
          ),
          diaryRequesterProvider.overrideWithValue(({
            required key,
            required model,
            required summary,
          }) async {
            paidRequests++;
            throw StateError('no AI authorized');
          }),
          deepSeekEnvironmentKeyProvider.overrideWithValue(''),
          deepSeekKeyProvider.overrideWithValue(''),
          savedDeepSeekKeyProvider.overrideWith(_SyntheticSavedKey.new),
          aiKeyStoreProvider.overrideWith(
            (ref) => throw StateError('no key store read'),
          ),
          aiEnabledProvider.overrideWith(_SyntheticEnabled.new),
          deepSeekModelProvider.overrideWith(_SyntheticModel.new),
        ],
      );

      addTearDown(container.dispose);
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
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
      await tester.pumpAndSettle();
      Finder headingQuote() => find.descendant(
        of: find.byKey(const Key('workspace_component_diary')),
        matching: find.byType(DailyQuoteLine),
      );
      expect(headingQuote(), findsNothing);
      await tester.tap(find.byKey(const Key('workspace_switch_tasks')));
      await tester.pumpAndSettle();
      expect(headingQuote(), findsOneWidget);
      container
          .read(workspaceFocusProvider.notifier)
          .select(WorkspaceComponent.dailyPoetry);
      await tester.pumpAndSettle();
      expect(headingQuote(), findsNothing);
      await container
          .read(workspaceLayoutProvider.notifier)
          .hideGroup(
            WorkspaceDrag([
              WorkspaceComponent.dailyPoetry,
              WorkspaceComponent.tasks,
            ]),
          );
      await tester.pumpAndSettle();
      expect(headingQuote(), findsOneWidget);
      container.read(workspaceShelfOpenProvider.notifier).toggle();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workspace_add_dailyPoetry')),
        findsOneWidget,
      );
      expect(headingQuote(), findsOneWidget);
      await container
          .read(workspaceLayoutProvider.notifier)
          .reveal(WorkspaceComponent.dailyPoetry);
      await tester.pumpAndSettle();
      expect(headingQuote(), findsNothing);
      expect(paidRequests, 0);
      expect(metadata.reads, 0);
      expect(metadata.writes, 0);
      expect(repo.reads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      container.dispose();
    },
  );

  for (final timezone in [null, 'America/New_York']) {
    testWidgets(
      'dashboard cold retry controls and same-query pending retain task tree; midnight cannot relabel old data $timezone',
      (tester) async {
        final requests =
            <(AccountingQuerySpec, Completer<AccountingSnapshotDto>)>[];
        var now = DateTime(2026, 10, 3, 12);
        var paidRequests = 0;
        final time = MemoryTimeStore();
        final repo = _SyntheticCandidateRepo();
        final metadata = _SyntheticMetadata();
        final backend = MemoryPreferencesBackend(
          jsonEncode({
            'version': 1,
            'workspaceLayoutV3': {
              'version': 3,
              'groups': [
                ['tasks'],
              ],
              'sizes': {'tasks': core.WorkspaceSize.twoByTwo.toJson()},
            },
          }),
        );
        final container = ProviderContainer(
          overrides: [
            diaryDraftTagsStoreProvider.overrideWithValue(
              MemoryDiaryDraftTagsStore(),
            ),
            diaryEntryMetadataStoreProvider.overrideWithValue(metadata),
            dailyQuoteRepositoryProvider.overrideWithValue(_memoryQuotes()),
            dailyQuoteTickProvider.overrideWithValue(null),
            dailyQuoteClockProvider.overrideWithValue(() => now),
            apiProvider.overrideWith(
              (ref) => throw StateError('unexpected synthetic API read'),
            ),
            browsingProvider.overrideWith(_PresentationBrowsing.new),
            browsingClockProvider.overrideWithValue(() => now),
            dashboardIanaTimezoneProvider.overrideWithValue(timezone),
            dataRefreshPolicyProvider.overrideWithValue(
              const DataRefreshPolicy(interval: Duration.zero),
            ),
            dataRefreshVisibilityProvider.overrideWithValue(() => true),
            dashboardSnapshotLoaderProvider.overrideWithValue((query) {
              final pending = Completer<AccountingSnapshotDto>();
              requests.add((query, pending));
              return pending.future;
            }),
            dashboardMetadataLoaderProvider.overrideWithValue(
              (_) => const DashboardMetadata(),
            ),
            workspaceLayoutStoreProvider.overrideWithValue(
              WorkspaceLayoutStore(backend: backend),
            ),
            timeToolsStoreProvider.overrideWithValue(time),
            timeToolsClockProvider.overrideWithValue(() => now),
            timeToolsIdProvider.overrideWithValue(() => 'synthetic-task'),
            calendarDataProvider.overrideWith(
              (ref) async => const CalendarData(
                images: {},
                entryImages: {},
                diaryDays: {},
                entries: [],
              ),
            ),
            dailyQuoteProvider.overrideWith(
              (ref, day) async => offlineDailyQuotes.first,
            ),
            diaryCandidateRepositoryProvider.overrideWithValue(repo),
            diaryCandidateClockProvider.overrideWithValue(() => now.toUtc()),
            diaryCandidateIdProvider.overrideWithValue(
              () => 'synthetic-candidate',
            ),
            diaryRequesterProvider.overrideWithValue(({
              required key,
              required model,
              required summary,
            }) async {
              paidRequests++;
              throw StateError('no AI authorized');
            }),
            deepSeekEnvironmentKeyProvider.overrideWithValue(''),
            deepSeekKeyProvider.overrideWithValue(''),
            savedDeepSeekKeyProvider.overrideWith(_SyntheticSavedKey.new),
            aiKeyStoreProvider.overrideWith(
              (ref) => throw StateError('no key store read'),
            ),
            aiEnabledProvider.overrideWith(_SyntheticEnabled.new),
            deepSeekModelProvider.overrideWith(_SyntheticModel.new),
          ],
        );
        addTearDown(container.dispose);
        await container.read(timeToolsProvider.notifier).ensureLoaded();
        await container.read(workspaceDocumentProvider.notifier).ensureLoaded();
        final queryPreview = find.descendant(
          of: find.byKey(const Key('dashboard_query_notice')),
          matching: find.byKey(const Key('dashboard_query_structure_preview')),
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: DashboardScreen()),
          ),
        );
        await tester.pump();
        expect(find.byType(DateRangeControl), findsOneWidget);
        expect(queryPreview, findsOneWidget);
        expect(find.byType(AppBar), findsOneWidget);
        expect(
          tester
              .widget<DateRangeControl>(find.byType(DateRangeControl))
              .enabled,
          isTrue,
        );
        requests[0].$2.completeError(StateError('synthetic cold error'));
        await tester.pump();
        await tester.pump();
        expect(find.byType(DateRangeControl), findsOneWidget);
        await tester.tap(find.text('数据暂时无法读取，重试'));
        await tester.pump();
        expect(requests, hasLength(2));
        requests[1].$2.complete(_presentationSnap(requests[1].$1));
        await tester.pumpAndSettle();
        expect(queryPreview, findsNothing);
        final open = find.byKey(const Key('time_task_open_add'));
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('time_task_input'));
        await tester.enterText(input, 'pending内存输入');
        final lease = tester.element(find.byType(TasksWidget));
        final workspaceLease = tester.element(find.byType(ComponentWorkspace));
        final hostLease = tester.state(find.byType(host.WorkspaceHost));
        await tester.tap(find.byTooltip('刷新数据'));
        await tester.pump();
        expect(find.text('正在刷新…'), findsOneWidget);
        expect(tester.element(find.byType(TasksWidget)), same(lease));
        expect(tester.widget<TextField>(input).controller!.text, 'pending内存输入');
        requests[2].$2.completeError(StateError('synthetic refresh error'));
        await tester.pump();
        await tester.pump();
        expect(tester.element(find.byType(TasksWidget)), same(lease));
        expect(tester.widget<TextField>(input).controller!.text, 'pending内存输入');
        now = DateTime(2026, 10, 4, 0, 1);
        await tester.tap(find.byTooltip('刷新数据'));
        await tester.pump();
        expect(requests[3].$1.key, isNot(requests[1].$1.key));
        expect(queryPreview, findsOneWidget);
        expect(tester.element(find.byType(TasksWidget)), same(lease));
        expect(
          tester.element(find.byType(ComponentWorkspace)),
          same(workspaceLease),
        );
        expect(tester.state(find.byType(host.WorkspaceHost)), same(hostLease));
        expect(tester.widget<TextField>(input).controller!.text, 'pending内存输入');
        expect(find.text('正在加载使用数据…'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('dashboard_query_notice')),
            matching: find.text('正在加载所选范围…'),
          ),
          findsOneWidget,
        );
        expect(
          container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          isNull,
        );
        expect(find.byType(DateRangeControl), findsOneWidget);
        // A new date action remains enabled while this request is incomplete.
        await tester.tap(find.byTooltip('前一天'));
        await tester.pump();
        expect(container.read(dashboardRangeProvider).range, DateRange.custom);
        expect(requests, hasLength(5));
        requests[3].$2.complete(
          _presentationSnap(requests[3].$1, private: true),
        );
        await tester.pump();
        expect(tester.element(find.byType(TasksWidget)), same(lease));
        expect(
          tester.element(find.byType(ComponentWorkspace)),
          same(workspaceLease),
        );
        expect(tester.state(find.byType(host.WorkspaceHost)), same(hostLease));
        expect(tester.widget<TextField>(input).controller!.text, 'pending内存输入');
        expect(
          find.descendant(
            of: find.byKey(const Key('dashboard_query_notice')),
            matching: find.text('正在加载所选范围…'),
          ),
          findsOneWidget,
        );
        expect(
          container.read(dashboardRefreshStatusProvider).acceptedQueryKey,
          isNull,
        );
        requests[4].$2.complete(
          _presentationSnap(requests[4].$1, private: true),
        );
        await tester.pumpAndSettle();
        expect(container.read(dashboardProvider).requireValue.apps, isEmpty);
        expect(queryPreview, findsNothing);
        expect(paidRequests, 0);
        expect(metadata.reads, 0);
        expect(metadata.writes, 0);
        expect(repo.reads, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      },
    );
  }
  for (final type in [
    WorkspaceComponent.pomodoro,
    WorkspaceComponent.tasks,
    WorkspaceComponent.countdown,
    WorkspaceComponent.dailyPoetry,
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('registry $type single material surface $brightness', (
        tester,
      ) async {
        final f = AdapterFixture(MemoryPreferencesBackend());
        await f.container.read(timeToolsProvider.notifier).ensureLoaded();
        final colors = ColorScheme.fromSeed(
          seedColor: const Color(0xff797252),
          brightness: brightness,
        );
        final policy = MaterialPolicy.resolve(
          colorScheme: colors,
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
              theme: ThemeData(colorScheme: colors),
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: MaterialScope(
                    policy: policy,
                    tokens: MaterialTokens.forWidth(180),
                    child: SizedBox(
                      width: 180,
                      height: 160,
                      child: Builder(
                        builder: (context) =>
                            createWorkspaceRegistry()[type.name]!
                                .contentBuilder(
                                  context,
                                  host.WorkspaceContentLayout(
                                    constraints: const BoxConstraints.tightFor(
                                      width: 180,
                                      height: 160,
                                    ),
                                    persistedSize: type.defaultSize,
                                    displaySize: type.defaultSize,
                                    contentRevision: null,
                                  ),
                                ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MaterialCard), findsOneWidget);
        expect(find.byType(Card), findsOneWidget);
        expect(
          tester.widget<Card>(find.byType(Card)).color,
          policy.contentSurface,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final mode in ['loose', 'drag', 'narrow']) {
    testWidgets('ten static miniatures paint distinct nonzero RGBA $mode', (
      tester,
    ) async {
      final f = AdapterFixture(MemoryPreferencesBackend());
      final images = <String>{};
      for (final type in WorkspaceComponent.values) {
        final preview = RepaintBoundary(
          key: const Key('miniature_pixels'),
          child: WorkspaceComponentMiniature(component: type),
        );
        final Widget child = mode == 'loose'
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [SizedBox(height: 92, child: preview)],
              )
            : SizedBox(
                width: mode == 'drag' ? 160 : 70,
                height: mode == 'drag' ? 104 : 46,
                child: preview,
              );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              home: Scaffold(body: Center(child: child)),
            ),
          ),
        );
        await tester.pump();
        final size = tester.getSize(find.byKey(const Key('miniature_pixels')));
        expect(
          size.width,
          mode == 'loose'
              ? 140
              : mode == 'drag'
              ? 160
              : 70,
        );
        expect(
          size.height,
          mode == 'loose'
              ? 92
              : mode == 'drag'
              ? 104
              : 46,
        );
        final rgba = await paintedBytes(
          tester,
          find.byKey(const Key('miniature_pixels')),
        );
        expect(rgba.toSet().length, greaterThan(8), reason: type.name);
        images.add(base64Encode(rgba));
        expect(tester.takeException(), isNull);
      }
      expect(images, hasLength(WorkspaceComponent.values.length));
      expect(f.time.writes, isEmpty);
      expect(f.ids, 0);
      expect(f.backend.files, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test(
    'legacy future order IDs survive layout actions reorder hide and reopen',
    () async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'order': [
            'future-a',
            'bar',
            'future-b',
            'apps',
            'summary',
            'hourly',
            'future-c',
          ],
          'workspaceGroupsV2': [
            ['bar', 'apps', 'summary', 'hourly'],
            ['foreign'],
          ],
          'extra': {'keep': 1},
        }),
      );
      final f = AdapterFixture(backend);
      await f.load();
      await f.layout.reveal(WorkspaceComponent.calendar);
      expect(UiPreferencesStore.read(backend: backend)['order'], [
        'future-a',
        'bar',
        'future-b',
        'apps',
        'summary',
        'hourly',
        'future-c',
      ]);
      await f.container.read(dashboardOrderProvider.notifier).move(0, 1);
      expect(UiPreferencesStore.read(backend: backend)['order'], [
        'future-a',
        'apps',
        'future-b',
        'bar',
        'summary',
        'hourly',
        'future-c',
      ]);
      await f.layout.hideGroup(WorkspaceDrag([WorkspaceComponent.bar]));
      expect(UiPreferencesStore.read(backend: backend)['order'], [
        'future-a',
        'apps',
        'future-b',
        'summary',
        'hourly',
        'future-c',
      ]);
      expect(f.groups.last, ['calendar']);
      expect(f.groups.any((group) => group.contains('foreign')), isTrue);
      final fresh = AdapterFixture(backend);
      await fresh.load();
      expect(fresh.groups, f.groups);
      await fresh.layout.reveal(WorkspaceComponent.bar);
      final order = UiPreferencesStore.read(backend: backend)['order'] as List;
      expect(
        order.where((id) => id.toString().startsWith('future-')).toList(),
        ['future-a', 'future-b', 'future-c'],
      );
      expect(
        order
            .where((id) => ['bar', 'apps', 'summary', 'hourly'].contains(id))
            .toList(),
        ['apps', 'summary', 'hourly', 'bar'],
      );
      expect(
        (UiPreferencesStore.read(backend: backend)['extra'] as Map)['keep'],
        1,
      );
      expect(fresh.container.read(workspaceDocumentProvider).dirty, isFalse);
    },
  );
  test(
    'late first blocked ack cannot strand reset in unknown-only memory',
    () async {
      const original =
          '{"version":1,"workspaceGroupsV2":[["calendar","foreign"]],"extra":1}';
      final backend = MemoryPreferencesBackend(original);
      final store = DelayedBlockedStore(backend);
      final f = AdapterFixture(backend, store: store);
      await f.load();
      final resetting = f.layout.reset();
      await settleWrites();
      expect(store.attempts, 1);
      expect(f.groups, [
        ['calendar'],
        ['bar', 'summary', 'apps', 'hourly'],
        ['diary'],
        ['foreign'],
      ]);
      for (final component in WorkspaceComponent.values) {
        expect(
          f.container
              .read(workspaceDocumentProvider)
              .document
              .sizes[component.name]!
              .colSpan,
          component.defaultSize.colSpan,
        );
      }
      store.first.complete(
        const core.WorkspaceWriteBlocked(
          core.WorkspaceRootUnreadable('synthetic late blocked'),
        ),
      );
      await resetting;
      expect(f.groups, [
        ['calendar'],
        ['bar', 'summary', 'apps', 'hourly'],
        ['diary'],
        ['foreign'],
      ]);
      expect(f.container.read(workspaceDocumentProvider).dirty, isTrue);
      expect(f.container.read(workspaceDocumentProvider).writable, isFalse);
      expect(f.container.read(workspaceDocumentProvider).error, isNotNull);
      expect(backend.files[backend.canonicalPath], original);
      await f.doc.retrySave();
      expect(store.attempts, 1);
    },
  );
  testWidgets(
    'third-party synthetic descriptor joins without core or business edits',
    (tester) async {
      final backend = MemoryPreferencesBackend(
        '{"version":1,"workspaceGroupsV2":[["synthetic-plugin"]],"extra":{"keep":9}}',
      );
      final f = AdapterFixture(backend);
      await f.load();
      final created = <String, int>{}, disposed = <String, int>{};
      final previewSizes = <core.WorkspaceSize>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: const [WorkspaceEditActions()]),
              body: SingleChildScrollView(
                child: ComponentWorkspace(
                  registry: {
                    'synthetic-plugin': host.WorkspaceDescriptor(
                      id: 'synthetic-plugin',
                      label: 'Synthetic plugin',
                      defaultSize: core.WorkspaceSize.oneByOne,
                      thumbnailBuilder: (_) =>
                          const SizedBox(width: 80, height: 60),
                      thumbnailForSize: (_, size) {
                        previewSizes.add(size);
                        return const ColoredBox(
                          key: Key('forwarded-size-preview'),
                          color: Colors.purple,
                        );
                      },
                      contentBuilder: (_, _) =>
                          LeaseProbe('synthetic-plugin', created, disposed),
                    ),
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('lease_synthetic-plugin')).hitTestable(),
        findsOneWidget,
      );
      expect(
        f.container.read(diaryDraftTagsStoreProvider),
        isA<MemoryDiaryDraftTagsStore>(),
      );
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final resize = find.byKey(const Key('workspace_resize_synthetic-plugin'));
      expect(tester.getSize(resize), const Size(48, 48));
      await tester.tap(resize);
      await tester.pumpAndSettle();
      expect(
        previewSizes.any((s) => s.sameExtent(core.WorkspaceSize.twoByThree)),
        isTrue,
      );
      for (final element
          in find.byKey(const Key('forwarded-size-preview')).evaluate()) {
        final box = element.renderObject! as RenderBox;
        expect(box.size.width, greaterThan(0));
        expect(box.size.height, greaterThan(0));
      }
      await tester.tap(
        find.byKey(const Key('workspace_resize_synthetic-plugin_XL')),
      );
      await tester.pumpAndSettle();
      expect(
        f.container
            .read(workspaceDocumentProvider)
            .document
            .sizes['synthetic-plugin']!
            .sameExtent(core.WorkspaceSize.twoByThree),
        isTrue,
      );
      final reopened = AdapterFixture(backend);
      await reopened.load();
      expect(
        reopened.container
            .read(workspaceDocumentProvider)
            .document
            .sizes['synthetic-plugin']!
            .sameExtent(core.WorkspaceSize.twoByThree),
        isTrue,
      );
      await f.doc.perform(
        core.WorkspaceAction(
          core.WorkspaceActionKind.resize,
          id: 'synthetic-plugin',
          size: core.WorkspaceSize.twoByThree,
        ),
      );
      await tester.pumpAndSettle();
      expect(f.groups, [
        ['synthetic-plugin'],
      ]);
      expect(created, {'synthetic-plugin': 1});
      expect(disposed, isEmpty);
      expect(
        (UiPreferencesStore.read(backend: backend)['extra'] as Map)['keep'],
        9,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'upgrade zero writes, four tools only library, unknown V3 survives same patch',
    () async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'workspaceGroupsV2': [
            ['bar', 'extension'],
            ['diary'],
          ],
          'wallpaper': 'synthetic',
          'unknown': {
            'nested': [1, 2],
          },
        }),
      );
      final f = AdapterFixture(backend);
      await f.load();
      expect(backend.commits, 0);
      expect(f.groups, [
        ['bar', 'extension'],
        ['diary'],
      ]);
      expect(f.groups.expand((e) => e), isNot(contains('pomodoro')));
      await f.layout.reveal(WorkspaceComponent.pomodoro);
      final root = UiPreferencesStore.read(backend: backend);
      expect(root['unknown'], {
        'nested': [1, 2],
      });
      expect(root['wallpaper'], 'synthetic');
      expect(root['workspaceGroupsV2'], [
        ['bar', 'extension'],
        ['diary'],
      ]);
      expect(root['workspaceLayoutV3']['groups'], [
        ['bar', 'extension'],
        ['diary'],
        ['pomodoro'],
      ]);
      expect(root['order'], ['bar']);
      expect(
        backend.committedRoots.every(
          (r) => r.containsKey('workspaceLayoutV3') && r.containsKey('order'),
        ),
        isTrue,
      );
      final fresh = AdapterFixture(backend);
      await fresh.load();
      expect(fresh.groups, f.groups);
    },
  );
  test('order has no prewrite and preserves non-data/unknown slots', () async {
    final f = AdapterFixture(
      MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'workspaceGroupsV2': [
            ['bar', 'foreign', 'calendar', 'apps'],
            ['summary', 'hourly'],
          ],
          'order': ['bar', 'apps', 'summary', 'hourly'],
          'background': {'x': 1},
        }),
      ),
    );
    await f.load();
    await f.container.read(dashboardOrderProvider.notifier).move(0, 1);
    expect(f.groups, [
      ['apps', 'foreign', 'calendar', 'bar'],
      ['summary', 'hourly'],
    ]);
    expect(f.backend.commits, 1);
    final saved = UiPreferencesStore.read(backend: f.backend);
    expect(saved['order'], ['apps', 'bar', 'summary', 'hourly']);
    expect(saved['background'], {'x': 1});
  });
  for (final raw in [
    '{bad',
    '[]',
    '',
    '{"version":2}',
    '{"version":1,"workspaceLayoutV3":{"version":4}}',
    '{"version":1,"workspaceLayoutV3":{"version":3,"groups":"bad","sizes":{}}}',
    '{"version":1,"workspaceGroupsV2":"bad"}',
    '{"version":1,"workspaceComponentsV1":42}',
    '{"version":1,"order":[42]}',
  ]) {
    for (final entry in ['layout', 'order']) {
      test('fail closed ' + entry + ' root ' + raw, () async {
        final backend = MemoryPreferencesBackend(raw);
        final f = AdapterFixture(backend);
        await f.load();
        final before = Map.of(backend.files);
        final document = f.groups;
        if (entry == 'layout') {
          await f.layout.reveal(WorkspaceComponent.calendar);
          await f.layout.reset();
        } else {
          await f.container.read(dashboardOrderProvider.notifier).move(0, 1);
        }
        expect(backend.files, before);
        expect(backend.commits, 0);
        expect(f.groups, document);
        expect(f.container.read(workspaceDocumentProvider).writable, isFalse);
      });
    }
  }
  for (final entry in ['layout', 'order']) {
    for (final stage in [
      'exists',
      'read',
      'prepare',
      'writeAndFlush',
      'backup',
      'commit',
      'rollback',
      'verify',
    ]) {
      test(entry + ' typed I/O failure ' + stage, () async {
        const initial =
            '{"version":1,"workspaceGroupsV2":[["bar","apps"]],"extra":9}';
        final backend = MemoryPreferencesBackend(initial);
        final f = AdapterFixture(backend);
        if (stage == 'exists' || stage == 'read') backend.faults.add(stage);
        await f.load();
        if (stage != 'exists' && stage != 'read') {
          backend.faults.add(stage);
          if (stage == 'rollback') backend.faults.add('commit');
        }
        if (entry == 'layout') {
          await f.layout.reveal(WorkspaceComponent.calendar);
        } else {
          await f.container.read(dashboardOrderProvider.notifier).move(0, 1);
        }
        final view = f.container.read(workspaceDocumentProvider);
        if (stage == 'exists' || stage == 'read') {
          expect(view.writable, isFalse);
          expect(view.dirty, isFalse);
          expect(backend.commits, 0);
        } else {
          expect(view.dirty, isTrue);
          expect(view.error, isNotNull);
          expect(backend.files.values.any((v) => v == initial), isTrue);
          if (stage == 'rollback') {
            expect(backend.files.containsKey(backend.canonicalPath), isFalse);
            expect(
              UiPreferencesStore.readOutcome(backend: backend),
              isA<UiPreferencesUnreadable>(),
            );
            expect(backend.commits, 0);
          }
        }
        {
          if (stage == 'verify') {
            await f.doc.retrySave();
            expect(f.container.read(workspaceDocumentProvider).dirty, isTrue);
            expect(
              f.container.read(workspaceDocumentProvider).writable,
              isTrue,
            );
            expect(backend.commits, 1);
            final root =
                jsonDecode(backend.files[backend.canonicalPath]!)
                    as Map<String, dynamic>;
            root['extra'] = {'fresh': true};
            backend.files[backend.canonicalPath] = jsonEncode(root);
          }
          backend.faults.clear();
          if (stage == 'rollback') await f.doc.restoreRecovery();
          if (stage != 'verify') await f.doc.reload();
          await f.doc.retrySave();
          expect(f.container.read(workspaceDocumentProvider).dirty, isFalse);
          if (stage == 'verify') {
            expect(backend.commits, 1);
            expect(
              (UiPreferencesStore.read(backend: backend)['extra']
                  as Map)['fresh'],
              isTrue,
            );
          }
        }
      });
    }
  }
  for (final key in ['workspaceComponentsV1', 'workspaceGroupsV2']) {
    test('layout first migration legacy target changed: ' + key, () async {
      final source = key.endsWith('V1')
          ? ['data']
          : [
              ['bar', 'apps'],
            ];
      final backend = MemoryPreferencesBackend(
        jsonEncode({'version': 1, key: source}),
      );
      final f = AdapterFixture(backend);
      await f.load();
      backend.files[backend.canonicalPath] = jsonEncode({
        'version': 1,
        key: key.endsWith('V1')
            ? ['calendar']
            : [
                ['calendar'],
              ],
      });
      final retained = Map.of(backend.files);
      await f.layout.reveal(WorkspaceComponent.diary);
      expect(backend.files, retained);
      final view = f.container.read(workspaceDocumentProvider);
      expect(view.dirty, isTrue);
      expect(view.writable, isFalse);
    });
  }
  test(
    'unverified commit retries only latest intent and preserves fresh root',
    () async {
      final backend = MemoryPreferencesBackend('{"version":1,"extra":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}');
      final f = AdapterFixture(backend);
      await f.load();
      backend.faults.add('verify');
      await f.layout.reveal(WorkspaceComponent.calendar);
      await f.layout.reveal(WorkspaceComponent.diary);
      expect(backend.commits, 1);
      expect(f.container.read(workspaceDocumentProvider).dirty, isTrue);
      final root =
          jsonDecode(backend.files[backend.canonicalPath]!)
              as Map<String, dynamic>;
      root['extra'] = {'new': 7};
      backend.files[backend.canonicalPath] = jsonEncode(root);
      backend.faults.clear();
      await f.doc.retrySave();
      expect(backend.commits, 2);
      expect(f.container.read(workspaceDocumentProvider).dirty, isFalse);
      expect(
        (UiPreferencesStore.read(backend: backend)['extra'] as Map)['new'],
        7,
      );
      expect(
        decodeDashboardWorkspace(
          UiPreferencesStore.read(backend: backend),
        ).document.groups,
        f.groups,
      );
      expect(f.groups.last, ['diary']);
    },
  );
  for (final replacement in ['target', 'future']) {
    test(
      'unverified retry refuses later ' +
          replacement +
          ' root without overwrite',
      () async {
        final backend = MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}');
        final f = AdapterFixture(backend);
        await f.load();
        backend.faults.add('verify');
        await f.layout.reveal(WorkspaceComponent.calendar);
        backend.faults.clear();
        final bytes = replacement == 'future'
            ? '{"version":2,"extra":"keep"}'
            : '{"version":1,"workspaceGroupsV2":[["apps"]],"extra":"keep"}';
        backend.files[backend.canonicalPath] = bytes;
        await f.doc.retrySave();
        expect(f.container.read(workspaceDocumentProvider).dirty, isTrue);
        expect(f.container.read(workspaceDocumentProvider).writable, isFalse);
        expect(backend.files[backend.canonicalPath], bytes);
        expect(backend.commits, 1);
      },
    );
  }
  test(
    'fresh unrelated root changes merge and preserve unknown metadata',
    () async {
      final backend = MemoryPreferencesBackend(
        '{"version":1,"workspaceGroupsV2":[["bar"]],"wallpaper":"a"}',
      );
      final f = AdapterFixture(backend);
      await f.load();
      backend.files[backend.canonicalPath] =
          '{"version":1,"workspaceGroupsV2":[["bar"]],"wallpaper":"b","extra":{"z":7}}';
      await f.layout.reveal(WorkspaceComponent.calendar);
      final root = UiPreferencesStore.read(backend: backend);
      expect(root['wallpaper'], 'b');
      expect(root['extra'], {'z': 7});
      expect(f.container.read(workspaceDocumentProvider).dirty, isFalse);
    },
  );
  test(
    'explicit empty remains empty after restart without upgrade write',
    () async {
      final f = AdapterFixture(
        MemoryPreferencesBackend('{"workspaceGroupsV2":[]}'),
      );
      await f.load();
      expect(f.groups, isEmpty);
      expect(f.backend.commits, 0);
    },
  );
  for (final fault in ['commit', 'secondCommit', 'conflict']) {
    test(
      'reset full memory intent known defaults unknown sizes retained: ' +
          fault,
      () async {
        final initial = jsonEncode({
          'version': 1,
          'wallpaper': 'synthetic',
          'workspaceLayoutV3': {
            'version': 3,
            'groups': [
              ['diary', 'foreign', 'calendar'],
              ['apps', 'foreign2'],
            ],
            'sizes': {
              'diary': {
                'colSpan': 4,
                'rowSpan': 0,
                'fullNatural': true,
                'extra': 8,
              },
              'apps': {'colSpan': 2, 'rowSpan': 3, 'note': 'keep'},
              'foreign': {
                'colSpan': 2,
                'rowSpan': 3,
                'unknownMetadata': [1],
              },
            },
            'documentMetadata': {'x': 1},
          },
        });
        final backend = MemoryPreferencesBackend(initial);
        final f = AdapterFixture(backend);
        await f.load();
        if (fault == 'commit') backend.faults.add('commit');
        if (fault == 'secondCommit') {
          backend.afterFlush = () {
            if (backend.commits == 1) backend.faults.add('commit');
          };
        }
        if (fault == 'conflict') {
          backend.afterFlush = () => backend.files[backend.canonicalPath] =
              '{"version":2,"foreign":"never overwrite"}';
        }
        await f.layout.reset();
        final view = f.container.read(workspaceDocumentProvider);
        expect(view.document.groups, [
          ['calendar'],
          ['bar', 'summary', 'apps', 'hourly'],
          ['diary'],
          ['foreign'],
          ['foreign2'],
        ]);
        expect(
          view.document.sizes['dailyPoetry']!.sameExtent(core.WorkspaceSize.twoByOne),
          isTrue,
        );
        expect(
          view.document.sizes['apps']!.sameExtent(core.WorkspaceSize.twoByTwo),
          isTrue,
        );
        expect(view.document.sizes['apps']!.metadata, {'note': 'keep'});
        expect(view.document.sizes['foreign']!.toJson(), {
          'unknownMetadata': [1],
          'colSpan': 2,
          'rowSpan': 3,
          'fullNatural': false,
        });
        expect(view.document.metadata, {
          'documentMetadata': {'x': 1},
        });
        expect(view.dirty, isTrue);
        expect(view.error, isNotNull);
        expect(
          backend.committedRoots.every(
            (r) => r.containsKey('order') && r.containsKey('workspaceLayoutV3'),
          ),
          isTrue,
        );
        if (fault == 'conflict') {
          expect(view.writable, isFalse);
          expect(
            backend.files[backend.canonicalPath],
            '{"version":2,"foreign":"never overwrite"}',
          );
        } else {
          backend.afterFlush = null;
          backend.faults.clear();
          await f.doc.retrySave();
          expect(f.container.read(workspaceDocumentProvider).dirty, isFalse);
          final fresh = AdapterFixture(backend);
          await fresh.load();
          expect(fresh.groups, view.document.groups);
          expect(
            fresh.groups.take(3).toList(),
            [
              ['calendar'],
              ['bar', 'summary', 'apps', 'hourly'],
              ['diary'],
            ],
          );
          expect(
            fresh.groups.expand((e) => e).where((id) => id == 'calendar'),
            hasLength(1),
          );
          expect(
            fresh.container.read(workspaceDocumentProvider).document.sizes['dailyPoetry']!
                .sameExtent(core.WorkspaceSize.twoByOne),
            isTrue,
          );
        }
      },
    );
  }
  testWidgets(
    'library thumbnails do not instantiate time stores or quote fetch',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}'));
      await mount(tester, f);
      final initialReads = f.time.reads;
      await tester.tap(find.byKey(const Key('workspace_toggle_shelf')));
      await tester.pumpAndSettle();
      for (final id in ['pomodoro', 'tasks', 'countdown', 'dailyPoetry']) {
        expect(find.byKey(ValueKey('workspace_add_' + id)), findsOneWidget);
      }
      expect(f.groups, [
        ['bar', 'summary', 'apps', 'hourly'],
      ]);
      expect(f.time.reads, initialReads);
      expect(find.byKey(const Key('daily_poetry_expand')), findsNothing);
      expect(f.backend.commits, 0);
    },
  );
  testWidgets(
    'time state persists across resize stack switch hide reveal and reopen',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}'));
      final tool = f.container.read(timeToolsProvider.notifier);
      await tool.ensureLoaded();
      tool.addTask('synthetic task');
      tool.setCountdown('synthetic target', DateTime.utc(2027));
      tool.startPomodoro();
      await tool.flush();
      await f.load();
      await f.layout.reveal(WorkspaceComponent.pomodoro);
      await f.layout.reveal(WorkspaceComponent.tasks);
      await f.layout.reveal(WorkspaceComponent.countdown);
      await f.layout.reveal(WorkspaceComponent.dailyPoetry);
      await mount(tester, f);
      await f.layout.setSize(
        WorkspaceComponent.pomodoro,
        core.WorkspaceSize.twoByTwo,
      );
      await f.layout.stack(
        WorkspaceComponent.tasks,
        WorkspaceComponent.pomodoro,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace_switch_tasks')));
      await tester.pumpAndSettle();
      expect(find.text('synthetic task').hitTestable(), findsOneWidget);
      await f.layout.hideGroup(
        WorkspaceDrag([WorkspaceComponent.pomodoro, WorkspaceComponent.tasks]),
      );
      await tester.pumpAndSettle();
      await f.layout.reveal(WorkspaceComponent.pomodoro);
      await f.layout.reveal(WorkspaceComponent.tasks);
      await tester.pumpAndSettle();
      f.now = f.now.add(const Duration(minutes: 2));
      expect(
        f.container.read(timeToolsProvider).data.tasks.single.text,
        'synthetic task',
      );
      expect(
        f.container.read(timeToolsProvider).data.countdown!.targetUtc,
        DateTime.utc(2027),
      );
      expect(
        f.container.read(timeToolsProvider).data.pomodoro.remaining(f.now),
        23 * 60,
      );
      final fresh = ProviderContainer(
        overrides: [
          timeToolsStoreProvider.overrideWithValue(f.time),
          timeToolsClockProvider.overrideWithValue(() => f.now),
          timeToolsIdProvider.overrideWithValue(() => 'fresh'),
        ],
      );
      addTearDown(fresh.dispose);
      await fresh.read(timeToolsProvider.notifier).ensureLoaded();
      expect(
        fresh.read(timeToolsProvider).data.tasks.single.text,
        'synthetic task',
      );
      expect(
        fresh.read(timeToolsProvider).data.pomodoro.remaining(f.now),
        23 * 60,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('last click wins and external focus cancels queued transition', (
    tester,
  ) async {
    final f = AdapterFixture(MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}'));
    await mount(tester, f);
    await tester.tap(find.byKey(const Key('workspace_switch_summary')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const Key('workspace_switch_apps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('visible_apps')).hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('visible_summary')).hitTestable(),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('workspace_switch_summary')));
    await tester.pump(const Duration(milliseconds: 20));
    f.container
        .read(workspaceFocusProvider.notifier)
        .select(WorkspaceComponent.bar);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('visible_bar')).hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('visible_summary')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const Key('visible_bar'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('visible_apps'), skipOffstage: false),
      findsOneWidget,
    );
  });
  testWidgets(
    'one business State lease survives resize moves switches hide and reveal',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}'));
      final created = <String, int>{}, disposed = <String, int>{};
      await mount(
        tester,
        f,
        builders: {
          for (final component in defaultDataComponents)
            component: (_, _) => LeaseProbe(component.name, created, disposed),
        },
      );
      expect(created, {'bar': 1, 'summary': 1, 'apps': 1, 'hourly': 1});
      await f.layout.setSize(
        WorkspaceComponent.bar,
        core.WorkspaceSize.twoByThree,
      );
      await f.doc.perform(
        core.WorkspaceAction(
          core.WorkspaceActionKind.detach,
          id: 'apps',
          index: 1,
        ),
      );
      await tester.pumpAndSettle();
      await f.layout.stack(WorkspaceComponent.apps, WorkspaceComponent.bar);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workspace_switch_apps')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lease_apps')).hitTestable(), findsOneWidget);
      await f.layout.hideGroup(WorkspaceDrag(defaultDataComponents));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lease_apps')).hitTestable(), findsNothing);
      await f.layout.reveal(WorkspaceComponent.apps);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('lease_apps')).hitTestable(), findsOneWidget);
      expect(created, {'bar': 1, 'summary': 1, 'apps': 1, 'hourly': 1});
      expect(disposed, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'same wiggle early nonzero decays after 1600ms reduced motion still',
    (tester) async {
      final f = AdapterFixture(MemoryPreferencesBackend('{"version":1,"workspaceGroupsV2":[["bar","summary","apps","hourly"]]}'));
      await mount(tester, f);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pump();
      double angle() => tester
          .widget<Transform>(find.byKey(const Key('workspace_wiggle_bar')))
          .transform
          .storage[1]
          .abs();
      await tester.pump(const Duration(milliseconds: 130));
      final early = angle();
      expect(early, greaterThan(.02));
      await tester.pump(const Duration(milliseconds: 1067));
      expect(angle(), lessThan(early));
      await tester.pump(const Duration(milliseconds: 600));
      expect(angle(), lessThan(.000001));
      await mount(tester, f, reduceMotion: true);
      expect(angle(), lessThan(.000001));
    },
  );
  for (final width in [480.0, 719.0, 720.0, 1200.0]) {
    testWidgets(
      'all spans compact/large-text visible with natural long diary ' +
          width.toString(),
      (tester) async {
        final backend = MemoryPreferencesBackend(
          jsonEncode({
            'version': 1,
            'workspaceLayoutV3': {
              'version': 3,
              'groups': [
                ['pomodoro'],
                ['countdown'],
                ['tasks'],
                ['dailyPoetry'],
                ['diary'],
              ],
              'sizes': {
                'pomodoro': core.WorkspaceSize.oneByOne.toJson(),
                'countdown': core.WorkspaceSize.twoByOne.toJson(),
                'tasks': core.WorkspaceSize.twoByThree.toJson(),
                'dailyPoetry': core.WorkspaceSize.twoByTwo.toJson(),
              },
            },
          }),
        );
        final f = AdapterFixture(backend);
        await mount(tester, f, width: width, scale: 2);
        final initial = Map.of(backend.files);
        expect(tester.takeException(), isNull);
        expect(backend.files, initial);
        expect(
          f.container
              .read(workspaceDocumentProvider)
              .document
              .sizes['pomodoro']!
              .colSpan,
          1,
        );
        final diary = find.byKey(
          const Key('registry_diary_draft'),
          skipOffstage: false,
        );
        expect(tester.getSize(diary).height, greaterThan(800));
      },
    );
  }
  for (final titleScale in [1.0, 2.0]) {
    for (final month in [2, 10, 12]) {
      testWidgets('complete month title glyphs $month scaler $titleScale', (
        tester,
      ) async {
        final f = AdapterFixture(MemoryPreferencesBackend());
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    textScaler: TextScaler.linear(titleScale),
                  ),
                  child: SizedBox(
                    key: const Key('title_calendar_slot'),
                    width: 280,
                    height: 320,
                    child: WorkspaceCalendarContent(
                      selected: DateTime(2026, month, 1),
                      rangeLabel: '所选日',
                      onSelected: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final title = find.byKey(const Key('calendar_month_title'));
        final paragraph = tester.renderObject<RenderParagraph>(title);
        final text = '2026年$month月';
        expect(tester.widget<Text>(title).data, text);
        expect(
          MediaQuery.textScalerOf(tester.element(title)).scale(14),
          14 * titleScale,
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        final fit = tester.getRect(
          find.byKey(const Key('calendar_month_title_fit')),
        );
        final slot = tester.getRect(
          find.byKey(const Key('title_calendar_slot')),
        );
        expect(fit.left, greaterThanOrEqualTo(slot.left));
        expect(fit.right, lessThanOrEqualTo(slot.right));
        for (var index = 0; index < text.length; index++) {
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          );
          expect(boxes, isNotEmpty, reason: 'glyph ${text[index]}');
          for (final box in boxes) {
            final glyph = MatrixUtils.transformRect(
              paragraph.getTransformTo(null),
              box.toRect(),
            );
            expect(glyph.left, greaterThanOrEqualTo(fit.left - .01));
            expect(glyph.right, lessThanOrEqualTo(fit.right + .01));
            expect(glyph.top, greaterThanOrEqualTo(fit.top - .01));
            expect(glyph.bottom, lessThanOrEqualTo(fit.bottom + .01));
          }
        }
        for (final key in ['calendar_month_previous', 'calendar_month_next']) {
          expect(tester.getSize(find.byKey(Key(key))), const Size(48, 48));
        }
        expect(find.byType(SingleChildScrollView), findsNothing);
        await tester.tap(find.byKey(const Key('calendar_month_previous')));
        await tester.pumpAndSettle();
        expect(find.text('2026年${month - 1}月'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
  for (final scale in [1.0, 2.0]) {
    for (final slotSize in [
      const Size(280, 320),
      const Size(440, 320),
      const Size(440, 480),
    ]) {
      testWidgets('whole month fits $slotSize with actual scaler $scale', (
        tester,
      ) async {
        final f = AdapterFixture(MemoryPreferencesBackend());
        DateTime? selected;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    key: const Key('bounded_calendar_fixture'),
                    width: slotSize.width,
                    height: slotSize.height,
                    child: RepaintBoundary(
                      key: const Key('calendar_pixels'),
                      child: WorkspaceCalendarContent(
                        selected: DateTime(2026, 2, 1),
                        rangeLabel: '所选日',
                        onSelected: (date) => selected = date,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final slot = tester.getRect(
          find.byKey(const Key('bounded_calendar_fixture')),
        );
        for (final key in ['calendar_month_previous', 'calendar_month_next']) {
          final arrow = find.byKey(Key(key));
          expect(tester.getSize(arrow), const Size(48, 48));
          expect(slot.contains(tester.getRect(arrow).center), isTrue);
          expect(arrow.hitTestable(), findsOneWidget);
        }
        for (final text in [
          '2026年2月',
          'Sun',
          'Mon',
          'Tue',
          'Wed',
          'Thu',
          'Fri',
          'Sat',
          '1',
          '28',
        ]) {
          final finder = find.text(text).first;
          final rect = tester.getRect(finder);
          expect(
            rect.left,
            greaterThanOrEqualTo(slot.left - .01),
            reason: text,
          );
          expect(rect.right, lessThanOrEqualTo(slot.right + .01), reason: text);
          expect(rect.top, greaterThanOrEqualTo(slot.top - .01), reason: text);
          expect(
            rect.bottom,
            lessThanOrEqualTo(slot.bottom + .01),
            reason: text,
          );
        }
        final day = find.text('28').first;
        final render = tester.renderObject<RenderParagraph>(day);
        final scaler = MediaQuery.textScalerOf(tester.element(day));
        expect(scaler.scale(15), 15 * scale);
        final transform = render.getTransformTo(null).storage;
        // Ignore the identity Z axis: maxScaleOnAxis would wrongly report
        // >=1 for a 2D downscale. Measure the actual painted X/Y basis.
        final paintedScale = math.sqrt(
          transform[0] * transform[0] + transform[1] * transform[1],
        );
        final effective = scaler.scale(15) * paintedScale;
        debugPrint(
          'controlled calendar $slotSize scaler=$scale effectivePrimary=$effective',
        );
        expect(
          effective,
          greaterThanOrEqualTo(9),
          reason: 'normal 2x2 effective primary px=$effective',
        );
        expect(find.byType(SingleChildScrollView), findsNothing);
        final rgba = await paintedBytes(
          tester,
          find.byKey(const Key('calendar_pixels')),
        );
        expect(rgba.toSet().length, greaterThan(10));
        await tester.tap(day);
        await tester.pumpAndSettle();
        expect((selected!.year, selected!.month, selected!.day), (2026, 2, 28));
        await tester.tap(find.byKey(const Key('calendar_month_next')));
        await tester.pumpAndSettle();
        expect(find.text('2026年3月'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}


void _acceptanceUsabilityTests() {
  const prefix = [
    ['calendar'], ['bar', 'summary', 'apps', 'hourly'], ['diary'],
  ];
  for (final savedExtras in [false, true]) {
    for (final clientWidth in [719.0, 720.0, 1099.0, 1100.0, 1200.0, 1264.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('preferred first fold real dashboard extras$savedExtras '
          'client$clientWidth scale$scale', (tester) async {
          const clientHeight = 752.0; // preferred800 outer less synthetic48 frame
          final ratio = switch (clientWidth) {
            719 => 1.0, 720 => 1.25, 1099 => 1.5, _ => 2.0,
          };
          final groups = [...prefix, if (savedExtras) ...[
            ['dailyPoetry'], ['tasks'],
          ]];
          final backend = MemoryPreferencesBackend(savedExtras ? jsonEncode({
            'version': 1, 'workspaceLayoutV3': {
              'version': 3, 'groups': groups, 'sizes': <String, Object?>{},
            },
          }) : null);
          final quote = DailyQuote.full(
            '首折合成诗句，清风明月。', '合成作者《合成作品》',
            online: true, author: '合成作者', work: '合成作品',
            dynasty: '合成时代', sourceUrl: dailyPoemEndpoint,
            fullContent: ['首折合成诗句，清风明月。', '合成末句，完整保留。'],
          );
          final f = AdapterFixture(backend, dashboard: true, quote: quote);
          await f.load();
          await f.container.read(timeToolsProvider.notifier).ensureLoaded();
          final visual = ProviderContainer(parent: f.container, overrides: [
            uiPreferencesBackendProvider.overrideWithValue(backend),
            diaryCandidateClockProvider.overrideWithValue(() => f.now.toUtc()),
            diaryCandidateIdProvider.overrideWithValue(() => 'firstfold-memory'),
          ]);
          addTearDown(visual.dispose);
          tester.view.devicePixelRatio = ratio;
          tester.view.physicalSize = Size(clientWidth * ratio, clientHeight * ratio);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff58694f));
          Widget tree() => UncontrolledProviderScope(container: visual,
            child: MaterialApp(theme: ThemeData(colorScheme: scheme),
              home: MediaQuery(data: MediaQueryData(
                size: Size(clientWidth, clientHeight),
                textScaler: TextScaler.linear(scale), disableAnimations: true,
              ), child: MaterialScope(policy: MaterialPolicy.resolve(
                colorScheme: scheme, wallpaper: WallpaperLoadState.absent,
                signals: const MaterialSignals(
                  highContrast: AccessibilitySignal.disabled,
                  reduceTransparency: AccessibilitySignal.enabled,
                ),
              ), tokens: MaterialTokens.forWidth(clientWidth),
                child: const Padding(padding: EdgeInsets.only(left: 65),
                  child: DashboardScreen()),
              )),
            ));
          try {
            await tester.pumpWidget(tree());
            await tester.pumpAndSettle();
            final left = find.byKey(const Key('workspace_left_viewport'));
            final viewport = tester.getRect(left);
            final hostFinder = find.byType(host.WorkspaceHost);
            final state = tester.state<host.WorkspaceHostState>(hostFinder);
            final hostWidget = tester.widget<host.WorkspaceHost>(hostFinder);
            final diary = find.byKey(const Key('workspace_component_diary'));
            final diaryElement = tester.element(diary);
            final heading = find.descendant(of: diary,
              matching: find.byType(DiaryHeadingContent));
            expect(f.groups, groups);
            expect(tester.widget<DiaryHeadingContent>(heading).showQuote, !savedExtras);
            expect(state.geometry!.groups, hasLength(groups.length));
            expect(state.geometry!.parentWidth, closeTo(viewport.width, .01));
            final wideReadable = viewport.width >= 720 && scale == 1;
            if (wideReadable) {
              // Positive first-fold assertion, not conditional on whether the
              // implementation happened to install a budget.
              expect(hostWidget.prefixBudget, isNotNull);
              final calendar = tester.getRect(find.byKey(
                const Key('workspace_component_calendar')));
              final data = tester.getRect(find.byKey(
                const Key('workspace_component_bar')));
              expect(calendar.top, closeTo(data.top, .01));
              expect(data.left, greaterThan(calendar.right));
              expect(calendar.height, greaterThanOrEqualTo(360));
              expect(data.height, closeTo(calendar.height, .01));
              expect(tester.getRect(diary).top, greaterThan(data.bottom));
              expect(tester.getRect(diary).bottom,
                lessThanOrEqualTo(viewport.bottom + .01));
              if (savedExtras) {
                expect(state.geometry!.groups[3].top,
                  greaterThanOrEqualTo(viewport.height - .01));
              }
            } else {
              expect(hostWidget.prefixBudget, isNull);
              expect(tester.widget<SingleChildScrollView>(left)
                .controller!.position.maxScrollExtent, greaterThan(0));
              await tester.ensureVisible(heading);
              await tester.pumpAndSettle();
              expect(heading.hitTestable(), findsOneWidget);
            }
            if (savedExtras) {
              final beforePoetry = state.geometry!.contents[3].size;
              final beforeTasks = state.geometry!.contents[4].size;
              expect(beforePoetry.height, hostWidget.geometryPolicy.heightFor(
                WorkspaceComponent.dailyPoetry.defaultSize));
              expect(beforeTasks.height, hostWidget.geometryPolicy.heightFor(
                WorkspaceComponent.tasks.defaultSize));
              await tester.ensureVisible(find.byKey(
                const Key('workspace_component_tasks')));
              await tester.pumpAndSettle();
              expect(find.byKey(const Key('workspace_component_tasks'))
                .hitTestable(), findsOneWidget);
              expect(state.geometry!.contents[3].size, beforePoetry);
              expect(state.geometry!.contents[4].size, beforeTasks);
              if (clientWidth == 1264 && scale == 1) {
                await tester.ensureVisible(heading);
                await tester.pumpAndSettle();
                final toggle = find.descendant(of: diary, matching:
                  find.byWidgetPredicate((w) => w is Semantics &&
                    w.properties.label == '展开日记'));
                expect(toggle, findsOneWidget);
                await tester.tap(toggle);
                await tester.pumpAndSettle();
                expect(tester.widget<host.WorkspaceHost>(hostFinder).prefixBudget,
                  isNull); // expanded diary must use its real natural scroll
                expect(tester.element(diary), same(diaryElement));
                expect(state.geometry!.contents[3].size, beforePoetry);
                expect(state.geometry!.contents[4].size, beforeTasks);
              }
            }
            expect(tester.element(diary), same(diaryElement));
            expect(backend.commits, 0);
            if (!savedExtras) expect(backend.files, isEmpty);
            expect(f.time.writes, isEmpty);
            expect(f.metadata.writes, 0);
            expect(f.candidate.reads, 1); // sole empty memory metadata load
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(milliseconds: 1));
            await tester.pumpAndSettle(const Duration(milliseconds: 10),
              EnginePhase.sendSemanticsUpdate, const Duration(seconds: 1));
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
