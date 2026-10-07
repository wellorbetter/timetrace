import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/features/browsing/presentation/date_range_control.dart';
import 'package:timetrace_app/src/features/feed/presentation/feed_filter_control.dart';
import 'package:timetrace_app/src/core/preferences/presentation_preferences_provider.dart';
import 'package:flutter/gestures.dart';
import 'package:timetrace_app/src/features/browsing/providers/feed_projection_provider.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import 'package:timetrace_app/src/features/feed/presentation/feed_screen.dart';
import 'dart:async';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/dashboard_screen.dart';
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
import '../../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import '../../time_tools/time_tools_state_test.dart' show MemoryTimeStore;
import '../refresh_lifecycle_test.dart' show snap;

class _ForbiddenApi extends Fake implements TimeTraceApi {}

class _SyntheticApi extends Fake implements TimeTraceApi {
  final calls = <(AccountingRangeRequest, AccountingAsOfRequest)>[];
  int forbidden = 0;
  int rows = 1;
  bool fail = false;
  final gates = <Completer<AccountingSnapshotDto>>[];
  final gateRequests = <(AccountingRangeRequest_Utc, AccountingAsOfRequest)>[];
  bool defer = false;
  @override
  Future<AccountingSnapshotDto> getAccountingSnapshot({
    required AccountingRangeRequest range,
    required AccountingAsOfRequest asOf,
  }) async {
    calls.add((range, asOf));
    final bounds = range as AccountingRangeRequest_Utc;
    if (fail) throw StateError('synthetic read failure');
    final result = snapshotFor(bounds, asOf);
    if (defer) {
      final gate = Completer<AccountingSnapshotDto>();
      gates.add(gate);
      gateRequests.add((bounds, asOf));
      return gate.future;
    }
    return result;
  }

  AccountingSnapshotDto snapshotFor(
    AccountingRangeRequest_Utc bounds,
    AccountingAsOfRequest asOf,
  ) {
    final q = AccountingQuerySpec(
      range: bounds,
      asOf: asOf,
      startUtc: bounds.startUtc,
      endUtc: bounds.endUtc,
    );
    final base = snap(q);
    if (rows == 1) return base;
    final start = DateTime.parse(bounds.startUtc);
    return AccountingSnapshotDto(
      requestedStartUtc: bounds.startUtc,
      requestedEndUtc: bounds.endUtc,
      effectiveStartUtc: bounds.startUtc,
      effectiveEndUtc: bounds.endUtc,
      observedThroughUtc: bounds.endUtc,
      totals: base.totals,
      intervals: [
        for (var i = 0; i < rows; i++)
          AccountingIntervalDto(
            startUtc: start.add(Duration(seconds: i)).toIso8601String(),
            endUtc: start.add(Duration(seconds: i + 1)).toIso8601String(),
            state: AccountingStateDto.active,
            appId: 'synthetic-public',
            windowId: 'synthetic-window',
            windowAppId: 'synthetic-public',
            sourceIdentity: 'synthetic-$i',
            sourceRevision: 1,
          ),
      ],
      apps: base.apps,
      windows: base.windows,
      pages: base.pages,
      hours: base.hours,
      integrity: base.integrity,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    forbidden++;
    throw StateError('forbidden synthetic backend');
  }
}

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

class _CountingBrowsing extends BrowsingNotifier {
  bool reject = false;
  final batches = <BrowsingQueryIdentity?>[];
  @override
  void loadMore({int count = 100, BrowsingQueryIdentity? query}) {
    batches.add(query);
    if (!reject) super.loadMore(count: count, query: query);
  }
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
  _Fixture({
    int rows = 1,
    bool reject = false,
    int minutes = 10,
    _SyntheticApi? source,
  }) {
    api = source ?? _SyntheticApi();
    api.rows = rows;
    browsing.reject = reject;
    backend = MemoryPreferencesBackend(
      jsonEncode({
        'version': 1,
        'feedBucketMinutes': minutes,
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
        apiProvider.overrideWithValue(api),
        browsingProvider.overrideWith(() => browsing),
        uiPreferencesBackendProvider.overrideWithValue(backend),
        feedDiagnosticsProvider.overrideWithValue(
          (event) => events.update(event.name, (n) => n + 1, ifAbsent: () => 1),
        ),
        browsingClockProvider.overrideWithValue(() => now),
        dashboardIanaTimezoneProvider.overrideWithValue(timezone),
        dataRefreshPolicyProvider.overrideWithValue(const DataRefreshPolicy()),
        dataRefreshVisibilityProvider.overrideWithValue(() => true),
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
  final String? timezone = null;
  DateTime now = DateTime(2026, 5, 15, 12);
  late final _SyntheticApi api;
  final browsing = _CountingBrowsing();
  final events = <String, int>{};
  late final ProviderContainer container;
  late final MemoryPreferencesBackend backend;
  late final DiaryComposerStore composer;
  final time = MemoryTimeStore();
  final drafts = <String, String>{};
  final calls = <_Call>[];
  int feedCalls = 0;
  int paid = 0;
  _RangeOnly get range =>
      container.read(browsingProvider.notifier) as _RangeOnly;
  void close() {
    composer.dispose();
    container.dispose();
  }
}

class _PaintProbe extends SingleChildRenderObjectWidget {
  const _PaintProbe({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PaintCounter(onPaint);
  @override
  void updateRenderObject(BuildContext context, _PaintCounter renderObject) =>
      renderObject.onPaint = onPaint;
}

class _PaintCounter extends RenderProxyBox {
  _PaintCounter(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

class _MixedHeightApi extends _SyntheticApi {
  @override
  AccountingSnapshotDto snapshotFor(
    AccountingRangeRequest_Utc bounds,
    AccountingAsOfRequest asOf,
  ) {
    final base = super.snapshotFor(bounds, asOf);
    return AccountingSnapshotDto(
      requestedStartUtc: base.requestedStartUtc,
      requestedEndUtc: base.requestedEndUtc,
      effectiveStartUtc: base.effectiveStartUtc,
      effectiveEndUtc: base.effectiveEndUtc,
      observedThroughUtc: base.observedThroughUtc,
      totals: base.totals,
      intervals: [
        for (var i = 0; i < base.intervals.length; i++)
          AccountingIntervalDto(
            startUtc: base.intervals[i].startUtc,
            endUtc: base.intervals[i].endUtc,
            state: i < 30000
                ? AccountingStateDto.active
                : ((i ~/ 60).isEven
                      ? AccountingStateDto.idle
                      : AccountingStateDto.systemGap),
            appId: i < 30000 ? base.intervals[i].appId : null,
            windowId: i < 30000 ? base.intervals[i].windowId : null,
            windowAppId: i < 30000 ? base.intervals[i].windowAppId : null,
            sourceIdentity: base.intervals[i].sourceIdentity,
            sourceRevision: base.intervals[i].sourceRevision,
          ),
      ],
      apps: base.apps,
      windows: base.windows,
      pages: base.pages,
      hours: base.hours,
      integrity: base.integrity,
    );
  }
}

void main() {
  for (final width in [280.0,720.0,1100.0]) {
    for (final scale in [1.0,2.0]) {
      for (final alignment in FeedToolbarAlignment.values) {
        testWidgets('bounded toolbar $alignment width$width scale$scale preserves query', (tester) async {
          final f = _Fixture(rows: 60);
          addTearDown(f.close);
          await f.container.read(feedToolbarAlignmentProvider.notifier).setAlignment(alignment);
          await f.container.read(browsingProvider.notifier)
              .setRange(DateRangeSelection(DateRange.month));
          await _mountRouter(tester,f,size: Size(width,1000),scale: scale);
          final header = find.byKey(const Key('feed_header_actions'));
          final date = find.byKey(const Key('feed_header_date'));
          final actions = [
            find.byKey(const Key('feed_global_filter')),
            find.widgetWithIcon(IconButton,Icons.calendar_month_outlined),
            find.byKey(const Key('workspace_recap')),
            find.byKey(const Key('feed_refresh')),
          ];
          final bounds = tester.getRect(header);
          final dateBounds = tester.getRect(date);
          expect(dateBounds.left, lessThanOrEqualTo(bounds.left + .1));
          for (final action in actions) {
            expect(action, findsOneWidget);
            final rect = tester.getRect(action);
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.left, greaterThanOrEqualTo(bounds.left - .1));
            expect(rect.right, lessThanOrEqualTo(bounds.right + .1));
            expect(rect.top, greaterThanOrEqualTo(bounds.top - .1));
            expect(rect.bottom, lessThanOrEqualTo(bounds.bottom + .1));
          }
          final last = tester.getRect(actions.last);
          if (alignment == FeedToolbarAlignment.right) {
            expect(last.right, closeTo(bounds.right,.1));
          } else {
            expect(tester.getRect(actions.first).left, closeTo(bounds.left,.1));
          }
          expect(tester.getCenter(find.byIcon(Icons.refresh_rounded)), tester.getCenter(actions.last));
          final requested = f.container.read(feedProjectionProvider).requestedQuery;
          final state = f.container.read(browsingProvider);
          final calls = f.api.calls.length;
          final dateState = tester.state(find.byType(DateRangeControl));
          final filterState = tester.state(find.byType(FeedFilterControl));
          await f.container.read(feedToolbarAlignmentProvider.notifier).setAlignment(
            alignment == FeedToolbarAlignment.left ? FeedToolbarAlignment.right : FeedToolbarAlignment.left);
          await tester.pumpAndSettle();
          expect(f.container.read(feedProjectionProvider).requestedQuery, requested);
          expect(f.container.read(browsingProvider).filter,state.filter);
          expect(f.container.read(browsingProvider).range,state.range);
          expect(f.container.read(browsingProvider).selectedAnchor,state.selectedAnchor);
          expect(f.api.calls.length,calls);
          expect(tester.state(find.byType(DateRangeControl)),same(dateState));
          expect(tester.state(find.byType(FeedFilterControl)),same(filterState));
          // Actual keyboard traversal follows the unmodified action order.
          tester.widget<IconButton>(actions.first).focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(tester.widget<IconButton>(actions[1]).focusNode!.hasFocus,true);
          f.api.fail = true;
          await f.browsing.refresh();
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('feed_header_actions')),findsOneWidget);
          f.api.fail = false;
          f.api.defer = true;
          final pending = f.browsing.refresh();
          await tester.pump();
          expect(find.descendant(of: actions.last,matching: find.byType(CircularProgressIndicator)),findsOneWidget);
          final (range,asOf) = f.api.gateRequests.last;
          f.api.gates.last.complete(f.api.snapshotFor(range,asOf));
          await pending;
          await tester.pumpAndSettle();
          expect(tester.takeException(),isNull);
          expect(f.api.forbidden,0);
          expect(f.paid,0);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }

  for (final change in [
    'remount',
    'remount-without-proof',
    'refresh-insert',
    'resize',
    'text-scale',
  ]) {
    testWidgets(
      'mixed-height far canonical anchor uses mounted bounds after $change',
      (tester) async {
        final f = _Fixture(rows: 60000, minutes: 1, source: _MixedHeightApi());
        addTearDown(f.close);
        await _mountRouter(tester, f, size: const Size(280, 720), scale: 2);
        final view = find.byKey(const PageStorageKey('semantic-activity-feed'));
        final oldQuery = f.container
            .read(feedProjectionProvider)
            .displayedQuery;
        f.browsing.loadMore(
          count: 60000,
          query: oldQuery,
        ); // Isolate locator, not an auto-fill claim.
        await tester.pumpAndSettle();
        final bounds = f.api.calls.first.$1 as AccountingRangeRequest_Utc;
        final start = DateTime.parse(
          bounds.startUtc,
        ).toLocal().add(const Duration(minutes: 200));
        final sought = ValueKey(
          'feed_activity:${start.toUtc().microsecondsSinceEpoch}:${start.add(const Duration(minutes: 1)).toUtc().microsecondsSinceEpoch}',
        );
        await tester.scrollUntilVisible(
          find.byKey(sought),
          1000,
          scrollable: find
              .descendant(of: view, matching: find.byType(Scrollable))
              .first,
          maxScrolls: 200,
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(view),
            scrollDelta: const Offset(0, 100),
          ),
        );
        await tester.pumpAndSettle();
        final memory = f.container.read(feedProjectionProvider).viewState;
        expect(memory.viewportAnchor, isNotNull);
        final cards = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('feed_activity:'),
        );
        final mounted =
            cards
                .evaluate()
                .where(
                  (e) =>
                      tester.getRect(find.byWidget(e.widget)).bottom >
                      tester.getTopLeft(view).dy,
                )
                .toList()
              ..sort(
                (a, b) =>
                    (tester.getTopLeft(find.byWidget(a.widget)).dy -
                            tester.getTopLeft(view).dy)
                        .abs()
                        .compareTo(
                          (tester.getTopLeft(find.byWidget(b.widget)).dy -
                                  tester.getTopLeft(view).dy)
                              .abs(),
                        ),
              );
        final key = mounted.first.widget.key!;
        final before =
            tester.getTopLeft(find.byKey(key)).dy - tester.getTopLeft(view).dy;
        final attemptsBefore = f.events['anchorSeek'] ?? 0;
        if (change == 'refresh-insert') {
          f.api.rows += 120;
          await f.browsing.refresh();
          await tester.pumpAndSettle();
          expect(
            f.container.read(feedProjectionProvider).displayedQuery,
            isNot(oldQuery),
          );
          expect(
            f.container.read(feedProjectionProvider).viewState.pixelOffset,
            isNull,
          );
        } else if (change == 'resize') {
          tester.view.physicalSize = const Size(360, 900);
          await tester.pumpAndSettle();
        } else {
          if (change == 'remount-without-proof') {
            f.container.read(feedPresentationMemoProvider).clear();
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await _mountRouter(
            tester,
            f,
            size: const Size(280, 720),
            scale: change == 'text-scale' ? 1 : 2,
            registerRouterDisposal: false,
          );
        }
        expect(
          find.byKey(key),
          findsOneWidget,
          reason:
              'Actual canonical target must be mounted, not just retained in memory',
        );
        expect(
          tester.getTopLeft(find.byKey(key)).dy - tester.getTopLeft(view).dy,
          closeTo(before, 1),
        );
        expect(
          f.container
              .read(feedProjectionProvider)
              .viewState
              .viewportAnchor
              ?.fragmentKey,
          memory.viewportAnchor?.fragmentKey,
        );
        expect(f.events['anchorUnresolved'] ?? 0, 0);
        debugPrint(
          'MIXED_REPAIR mode=$change seeks=${(f.events['anchorSeek'] ?? 0) - attemptsBefore} targetMounted=true offset=${tester.getTopLeft(find.byKey(key)).dy - tester.getTopLeft(view).dy} expected=$before',
        );
        expect(
          (f.events['anchorSeek'] ?? 0) - attemptsBefore,
          lessThanOrEqualTo(1003 + 108),
        ); // Dataset rows + double refinements, not auto-fill8.
        final completed = f.events['anchorSeek'];
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(
          f.events['anchorSeek'],
          completed,
          reason: 'No autonomous restoration frames after completion',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
        expect(f.api.forbidden, 0);
        expect(f.paid, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final narrow in [false, true]) {
    testWidgets(
      'canonical viewport anchor survives inserted rows and real remount narrow=$narrow',
      (tester) async {
        final f = _Fixture(rows: narrow ? 20000 : 5000, minutes: 1);
        addTearDown(f.close);
        await _mountRouter(
          tester,
          f,
          size: narrow ? const Size(280, 720) : const Size(1200, 900),
          scale: narrow ? 2 : 1,
        );
        final viewport = find.byKey(
          const PageStorageKey('semantic-activity-feed'),
        );
        // Expand an actual row before seeking: measured row heights are not uniform.
        final card = find
            .byWidgetPredicate(
              (w) =>
                  w is InkWell &&
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('feed_segment:'),
            )
            .first;
        await tester.tap(card);
        await tester.pumpAndSettle();
        for (var i = 0; i < 8; i++) {
          await tester.drag(viewport, const Offset(0, -600));
          await tester.pumpAndSettle();
        }
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(viewport),
            scrollDelta: const Offset(0, 180),
          ),
        );
        await tester.pumpAndSettle();
        final memory = f.container.read(feedProjectionProvider).viewState;
        expect(memory.viewportAnchor, isNotNull);
        expect(memory.pixelOffset, greaterThan(3000));
        final vpTop = tester.getTopLeft(viewport).dy;
        final rows = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('feed_activity:'),
        );
        final mounted =
            rows.evaluate().where((e) {
              final r = tester.getRect(find.byWidget(e.widget));
              return r.bottom > vpTop;
            }).toList()..sort(
              (a, b) => (tester.getTopLeft(find.byWidget(a.widget)).dy - vpTop)
                  .abs()
                  .compareTo(
                    (tester.getTopLeft(find.byWidget(b.widget)).dy - vpTop)
                        .abs(),
                  ),
            );
        final key = mounted.first.widget.key!;
        final before = tester.getTopLeft(find.byKey(key)).dy - vpTop;
        debugPrint(
          'ANCHOR before=$before memoryOffset=${memory.localOffset} key=$key fragment=${memory.viewportAnchor?.fragmentKey} pixel=${memory.pixelOffset}',
        );
        final oldQuery = f.container
            .read(feedProjectionProvider)
            .displayedQuery;
        f.api.rows += 120;
        await f.browsing.refresh();
        await tester.pumpAndSettle();
        final current = f.container.read(feedProjectionProvider);
        expect(current.displayedQuery, isNot(oldQuery));
        expect(current.viewState.pixelOffset, isNull);
        expect(
          current.viewState.viewportAnchor?.fragmentKey,
          memory.viewportAnchor?.fragmentKey,
        );
        expect(find.byKey(key), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(key)).dy -
              tester.getTopLeft(viewport).dy,
          closeTo(before, 1),
        );
        // Narrow Feed geometry above is independently asserted. The existing
        // read-only Dashboard has a known narrow AppBar/quote overflow; use
        // the baseline's supported desktop width for the cross-page remount.
        if (narrow) {
          tester.view.physicalSize = const Size(1200, 900);
          await tester.pumpAndSettle();
        }
        final remountOffset =
            tester.getTopLeft(find.byKey(key)).dy -
            tester.getTopLeft(viewport).dy;
        final router = f.container.read(appRouterProvider);
        router.go('/dashboard');
        await tester.pumpAndSettle();
        router.go('/feed');
        await tester.pumpAndSettle();
        expect(find.byKey(key), findsOneWidget);
        expect(
          tester.getTopLeft(find.byKey(key)).dy -
              tester.getTopLeft(viewport).dy,
          closeTo(remountOffset, 1),
        );
        expect(tester.takeException(), isNull);
        expect(f.api.forbidden, 0);
        expect(f.paid, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('derived memo does not hold an off-route refresh lease', (
    tester,
  ) async {
    final f = _Fixture();
    addTearDown(f.close);
    await _mountRouter(tester, f, size: const Size(1200, 900));
    final calls = f.api.calls.length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    f.now = f.now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(f.api.calls.length, calls);
    expect(f.api.forbidden, 0);
  });
  for (final size in [
    const Size(1800, 1200),
    const Size(280, 720),
    const Size(360, 300),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'actual viewport header card detail targets size=$size scale=$scale',
        (tester) async {
          final f = _Fixture(rows: 5000, minutes: 1);
          addTearDown(f.close);
          await _mountRouter(tester, f, size: size, scale: scale);
          expect(tester.takeException(), isNull);
          expect(f.browsing.batches.length, lessThanOrEqualTo(8));
          final refresh = find.byKey(const Key('feed_refresh'));
          expect(tester.getSize(refresh).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
          final card = find
              .byWidgetPredicate(
                (w) =>
                    w is InkWell &&
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>).value.startsWith(
                      'feed_segment:',
                    ),
              )
              .first;
          await tester.ensureVisible(card);
          await tester.pumpAndSettle();
          expect(tester.getSize(card).width, lessThanOrEqualTo(960));
          final row = find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>).value.startsWith(
                      'feed_activity:',
                    ),
              )
              .first;
          final viewport = find.byKey(
            const PageStorageKey('semantic-activity-feed'),
          );
          expect(tester.getSize(row).width, lessThanOrEqualTo(960));
          expect(
            tester.getCenter(row).dx,
            closeTo(tester.getCenter(viewport).dx, .1),
          );
          expect(
            find
                .byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key as ValueKey<String>).value.startsWith(
                        'feed_activity:',
                      ),
                )
                .evaluate()
                .length,
            lessThan(22),
          );
          final title = find
              .descendant(of: card, matching: find.byType(Text))
              .first;
          final paragraph = tester.renderObject<RenderParagraph>(title);
          expect(paragraph.textScaler.scale(14), closeTo(14 * scale, .001));
          await tester.tap(card);
          await tester.pumpAndSettle();
          expect(f.container.read(browsingProvider).selectedAnchor, isNotNull);
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byKey(const PageStorageKey('semantic-activity-feed')),
            const Offset(0, -200),
          );
          await tester.pumpAndSettle();
          expect(
            f.container.read(feedProjectionProvider).viewState.pixelOffset,
            isNotNull,
          );
          expect(f.api.forbidden, 0);
          expect(f.paid, 0);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'finite actual fill exhausted/no-progress/error without autonomous frames',
    (tester) async {
      final f = _Fixture(rows: 20000);
      addTearDown(f.close);
      await _mountRouter(tester, f, size: const Size(1200, 60000));
      expect(f.browsing.batches, hasLength(8));
      final frames = f.events['fill'];
      await tester.pump(const Duration(seconds: 1));
      expect(f.events['fill'], frames);
      expect(f.container.read(feedProjectionProvider).canLoadMore, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('no progress does not keep scheduling or fake filler', (
    tester,
  ) async {
    final f = _Fixture(rows: 500, reject: true);
    addTearDown(f.close);
    await _mountRouter(tester, f, size: const Size(1200, 5000));
    expect(f.browsing.batches, hasLength(1));
    for (var i = 0; i < 5; i++) await tester.pump();
    expect(f.browsing.batches, hasLength(1));
    expect(
      f.container.read(feedProjectionProvider).viewState.visibleCount,
      100,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'queued A batch cannot increment B C or survive dispose; resized budget is finite',
    (tester) async {
      final f = _Fixture(rows: 20000);
      addTearDown(f.close);
      await _mountRouter(tester, f, size: const Size(1200, 60000));
      expect(f.browsing.batches, hasLength(8));
      final a = f.container.read(feedProjectionProvider).displayedQuery;
      await tester.tap(find.byKey(const Key('feed_load_more')));
      final b = f.browsing.selectDay(DateTime(2026, 5, 2));
      final c = f.browsing.selectDay(DateTime(2026, 5, 3));
      await Future.wait([b, c]);
      await tester.pumpAndSettle();
      final latest = f.container.read(feedProjectionProvider).displayedQuery;
      expect(latest, isNot(a));
      expect(f.browsing.batches.take(8).every((q) => q == a), isTrue);
      expect(f.browsing.batches.skip(8).every((q) => q == latest), isTrue);
      expect(
        f.container.read(feedProjectionProvider).viewState.visibleCount,
        9700,
        reason: 'The queued A action must not add a ninth C batch',
      );
      tester.view.physicalSize = const Size(1200, 62000);
      await tester.pumpAndSettle();
      expect(
        f.container.read(feedProjectionProvider).viewState.visibleCount,
        19300,
      );
      final before = f.browsing.batches.length;
      await tester.tap(find.byKey(const Key('feed_load_more')));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(f.browsing.batches.length, before);
      expect(f.api.forbidden, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('empty filtered and error states do not load or invent rows', (
    tester,
  ) async {
    final f = _Fixture(rows: 0);
    addTearDown(f.close);
    await _mountRouter(tester, f, size: const Size(360, 720), scale: 2);
    expect(find.text('这个范围还没有活动记录'), findsOneWidget);
    expect(f.browsing.batches, isEmpty);
    await f.browsing.setFilter(const FeedFilter(appId: 'missing-synthetic'));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配筛选的活动'), findsOneWidget);
    expect(f.browsing.batches, isEmpty);
    f.api.fail = true;
    await f.browsing.refresh();
    await tester.pumpAndSettle();
    expect(f.events['fill'] ?? 0, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('new query and late completion revoke old derived presentation', (
    tester,
  ) async {
    final f = _Fixture(rows: 500);
    addTearDown(f.close);
    await _mountRouter(tester, f, size: const Size(1200, 800));
    f.api.defer = true;
    final b = f.browsing.selectDay(DateTime(2026, 5, 2));
    final c = f.browsing.selectDay(DateTime(2026, 5, 3));
    await tester.pump();
    final gates = List.of(f.api.gates);
    final requests = List.of(f.api.gateRequests);
    // Complete C first, then B; canonical acceptance/late-finally guards remain real.
    gates[1].complete(f.api.snapshotFor(requests[1].$1, requests[1].$2));
    for (var i = 2; i < gates.length; i++)
      gates[i].complete(f.api.snapshotFor(requests[i].$1, requests[i].$2));
    await c;
    await tester.pumpAndSettle();
    final current = f.container.read(feedProjectionProvider).displayedQuery;
    final counts = Map.of(f.events);
    gates[0].complete(f.api.snapshotFor(requests[0].$1, requests[0].$2));
    await b;
    await tester.pumpAndSettle();
    expect(f.container.read(feedProjectionProvider).displayedQuery, current);
    expect(f.events['grouping'], counts['grouping']);
    expect(f.container.read(browsingProvider).range.day, DateTime(2026, 5, 3));
    expect(f.api.forbidden, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final reverse in [false, true]) {
    testWidgets(
      'optimized cold mount and warm true rail navigation reverse=$reverse',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _Fixture();
        addTearDown(fixture.close);
        await fixture.container.read(timeToolsProvider.notifier).ensureLoaded();
        await fixture.container
            .read(workspaceDocumentProvider.notifier)
            .ensureLoaded();
        final router = fixture.container.read(appRouterProvider);
        addTearDown(router.dispose);
        if (reverse) router.go('/dashboard');
        var paints = 0;
        final builds = <String, int>{};
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          final type = element.widget.runtimeType.toString();
          if (type == 'FeedScreen' ||
              type == 'DashboardScreen' ||
              type == '_ActivityCard')
            builds.update(type, (n) => n + 1, ifAbsent: () => 1);
        };
        addTearDown(() => debugOnRebuildDirtyWidget = null);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: MaterialApp.router(
              routerConfig: router,
              builder: (context, child) => MaterialScope(
                policy: MaterialPolicy.resolve(
                  colorScheme: Theme.of(context).colorScheme,
                  wallpaper: WallpaperLoadState.absent,
                  signals: const MaterialSignals(
                    highContrast: AccessibilitySignal.disabled,
                    reduceTransparency: AccessibilitySignal.enabled,
                  ),
                ),
                tokens: MaterialTokens.forWidth(1200),
                child: _PaintProbe(onPaint: () => paints++, child: child!),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (reverse) {
          expect(find.byType(DashboardScreen), findsOneWidget);
          await tester.tap(find.byTooltip('时间流').first);
          await tester.pumpAndSettle();
        }
        expect(find.byType(FeedScreen), findsOneWidget);
        final firstFeed = tester.state(find.byType(FeedScreen));
        final cold = [
          fixture.api.calls.length,
          Map.of(fixture.events),
          Map.of(builds),
        ];
        final grouped = fixture.events['grouping'];
        final filtered = fixture.events['filtering'];
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byTooltip('工作台').first);
          await tester.pumpAndSettle();
          expect(find.byType(DashboardScreen), findsOneWidget);
          await tester.tap(find.byTooltip('时间流').first);
          await tester.pumpAndSettle();
          expect(find.byType(FeedScreen), findsOneWidget);
        }
        expect(tester.state(find.byType(FeedScreen)), isNot(same(firstFeed)));
        expect(fixture.api.calls, hasLength(2));
        expect(fixture.api.forbidden, 0);
        expect(
          fixture.events['grouping'],
          grouped,
          reason:
              'Warm route remount reuses one current sanitized derived value',
        );
        expect(fixture.events['filtering'], filtered);
        expect(fixture.paid, 0);
        expect(tester.takeException(), isNull);
        debugPrint(
          'SYNTHETIC_OPTIMIZED cold=$cold warm=[${fixture.api.calls.length},${fixture.events},$builds] remount=true rootPaints=$paints identicalRequests=${fixture.api.calls.first == fixture.api.calls.last}',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

Future<void> _mountRouter(
  WidgetTester tester,
  _Fixture f, {
  required Size size,
  double scale = 1,
  bool registerRouterDisposal = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await f.container.read(timeToolsProvider.notifier).ensureLoaded();
  await f.container.read(workspaceDocumentProvider.notifier).ensureLoaded();
  final router = f.container.read(appRouterProvider);
  if (registerRouterDisposal) addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: MaterialScope(
            policy: MaterialPolicy.resolve(
              colorScheme: Theme.of(context).colorScheme,
              wallpaper: WallpaperLoadState.absent,
              signals: const MaterialSignals(
                highContrast: AccessibilitySignal.disabled,
                reduceTransparency: AccessibilitySignal.enabled,
              ),
            ),
            tokens: MaterialTokens.forWidth(size.width),
            child: child!,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
