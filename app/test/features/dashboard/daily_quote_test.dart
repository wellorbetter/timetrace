import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import 'package:timetrace_app/src/core/preferences/safe_cache_service.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart' as core;
import 'package:timetrace_app/src/core/workspace/workspace_host.dart' as host;
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/workspace_component_registry.dart';
import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/dashboard/providers/daily_quote_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/daily_quote_line.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_heading_content.dart';

DailyQuote _complete({String text = '清风明月。', List<String>? lines}) =>
    DailyQuote.full(
      text,
      '测试作者《测试作品》',
      online: true,
      author: '测试作者',
      work: '测试作品',
      dynasty: '测试时代',
      sourceUrl: dailyPoemEndpoint,
      fullContent: lines ?? ['清风明月。', '末句有出处。'],
    );

Map<String, dynamic> _payload() => {
  'status': 'success',
  'token': 'SECRET-TOKEN',
  'data': {
    'content': '清风明月。',
    'ip': 'SECRET-IP',
    'matchTags': ['PRIVATE-TAG'],
    'origin': {
      'title': '测试作品',
      'author': '测试作者',
      'dynasty': '测试时代',
      'content': ['清风明月。', '末句有出处。'],
      'translate': ['MODERN-TRANSLATION'],
    },
  },
};

class _Headers implements HttpHeaders {
  final writes = <String>[];
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      writes.add(name);
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      writes.add(name);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);
  final Future<HttpClientResponse> Function() response;
  final trackedHeaders = _Headers();
  @override
  HttpHeaders get headers => trackedHeaders;
  @override
  bool followRedirects = true;
  int closes = 0;
  int aborts = 0;
  @override
  Future<HttpClientResponse> close() {
    closes++;
    return response();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborts++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.chunks);
  @override
  final int statusCode;
  final Stream<List<int>> chunks;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => chunks.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client({int status = 200, List<List<int>>? chunks}) {
    request = _Request(
      () async => _Response(
        status,
        Stream.fromIterable(chunks ?? [utf8.encode(jsonEncode(_payload()))]),
      ),
    );
  }
  late _Request request;
  Future<HttpClientRequest> Function()? connect;
  final uris = <Uri>[];
  @override
  Duration? connectionTimeout;
  final forceCloses = <bool>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uris.add(url);
    return connect == null ? request : await connect!();
  }

  @override
  void close({bool force = false}) {
    forceCloses.add(force);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DailyQuoteRepository typed(
  MemoryPreferencesBackend backend,
  Future<DailyQuote> Function() fetch,
) => DailyQuoteRepository(
  read: () => throw StateError('default permissive read forbidden'),
  write: (_) => throw StateError('default write forbidden'),
  readOutcome: () => UiPreferencesStore.readOutcome(backend: backend),
  patch: (delta, token, validate) => UiPreferencesStore.tryPatch(
    delta,
    expectedTargetToken: token,
    backend: backend,
    validateRoot: validate,
  ),
  fetch: fetch,
);

void main() {
  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('excerpt keyboard reader preserves cache and closes ${key.keyLabel}', (tester) async {
      final backend = MemoryPreferencesBackend(jsonEncode({
        'version': 1,
        'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
      }));
      var fetches = 0;
      final repository = typed(backend, () async {
        fetches++;
        throw StateError('unexpected quote HTTP');
      });
      addTearDown(repository.dispose);
      final container = ProviderContainer(overrides: [
        uiPreferencesBackendProvider.overrideWithValue(backend),
        dailyQuoteRepositoryProvider.overrideWithValue(repository),
        dailyQuoteClockProvider.overrideWithValue(() => DateTime(2026, 10, 3)),
        dailyQuoteTickProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(
            body: SizedBox(width: 280, height: 240,
              child: DailyQuoteLine(heading: '每日诗词')),
          )),
        ));
        await tester.pumpAndSettle();
        final excerpt = find.byKey(const Key('daily_poetry_expand'));
        expect(find.text('阅读全文'), findsNothing);
        expect(find.byTooltip('下一首'), findsOneWidget);
        expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
        expect(find.byIcon(Icons.refresh), findsNothing);
        expect(tester.getSemantics(excerpt).getSemanticsData().hasFlag(SemanticsFlag.isButton), isTrue);
        expect(tester.getSemantics(excerpt).label, contains('阅读全文'));
        expect(tester.getSemantics(excerpt).label, contains(offlineDailyQuotes[0].text));
        expect(tester.getSemantics(excerpt).label, contains(offlineDailyQuotes[0].attribution));
        for (var attempt = 0; attempt < 6; attempt++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focusedButton = FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextButton>();
          if (focusedButton?.key == const Key('daily_poetry_expand')) break;
        }
        expect(FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TextButton>()?.key,
            const Key('daily_poetry_expand'));
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_full_text')), findsOneWidget);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(fetches, 0);
        expect(backend.commits, 0);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_full_text')), findsNothing);
        expect(fetches, 0);
        expect(backend.commits, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  for (final width in [280.0, 720.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('explicit saved natural poetry keeps busy error cache states width$width scale$scale', (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final original = _complete(
          text: '清风明月。山水相依，行行复行行。',
          lines: [
            '清风明月。山水相依，行行复行行。',
            for (var i = 0; i < 24; i++) '原文第$i行，完整保留。',
          ],
        );
        final backend = MemoryPreferencesBackend(jsonEncode({
          'version': 1,
          'dailyQuoteV2': original.toCache('2026-10-03'),
          'workspaceLayoutV3': {
            'version': 3,
            'groups': [['dailyPoetry']],
            'sizes': {'dailyPoetry': core.WorkspaceSize.fullNatural.toJson()},
          },
        }));
        final pending = Completer<DailyQuote>();
        var fetches = 0;
        final repository = typed(backend, () {
          fetches++;
          if (fetches == 1) return pending.future;
          throw StateError('synthetic natural refresh failure');
        });
        addTearDown(repository.dispose);
        final container = ProviderContainer(overrides: [
          uiPreferencesBackendProvider.overrideWithValue(backend),
          dailyQuoteRepositoryProvider.overrideWithValue(repository),
          dailyQuoteClockProvider.overrideWithValue(() => DateTime(2026, 10, 3)),
          dailyQuoteTickProvider.overrideWithValue(null),
        ]);
        addTearDown(container.dispose);
        // Optional poetry is a saved user choice, not part of product defaults.
        final document = decodeDashboardWorkspace(
          UiPreferencesStore.read(backend: backend),
        ).document;
        final size = document.sizes['dailyPoetry']!;
        final descriptor = createWorkspaceRegistry()['dailyPoetry']!;
        expect(size.sameExtent(core.WorkspaceSize.fullNatural), isTrue);
        expect(descriptor.defaultSize.sameExtent(core.WorkspaceSize.twoByOne), isTrue);
        final bounds = BoxConstraints(minWidth: width, maxWidth: width);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(body: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: bounds,
                child: Builder(builder: (context) => descriptor.contentBuilder(
                  context,
                  host.WorkspaceContentLayout(
                    constraints: bounds,
                    persistedSize: size,
                    displaySize: size,
                    contentRevision: document,
                    visibleIds: const {'dailyPoetry'},
                  ),
                )),
              ),
            )),
          ),
        ));
        await tester.pumpAndSettle();
        final refresh = find.byKey(const Key('daily_poetry_refresh'));
        final full = find.byKey(const Key('daily_poetry_expand'));
        void expectNaturalFace() {
          final face = tester.getRect(find.byType(WorkspacePoetryContent));
          final body = tester.getRect(find.byType(DailyQuoteLine));
          expect(body.width, greaterThan(0));
          expect(body.height, greaterThan(0));
          expect(body.bottom, lessThanOrEqualTo(face.bottom + .01));
          expect(tester.getSize(refresh), const Size(48, 48));
          expect(tester.getSize(full).height, greaterThanOrEqualTo(48));
          expect(find.byType(DailyQuoteLine), findsOneWidget);
          expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
          expect(tester.takeException(), isNull);
        }
        expectNaturalFace();
        expect(fetches, 0);
        expect(backend.commits, 0);
        await tester.ensureVisible(full);
        await tester.tap(full);
        await tester.pumpAndSettle();
        expect(
          tester.widget<Text>(find.byKey(const Key('daily_poetry_full_text')))
              .textSpan!.toPlainText(),
          original.fullContent.join('\n'),
        );
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await tester.pump();
        expect(find.byKey(const Key('daily_poetry_busy')), findsOneWidget);
        expect(fetches, 1);
        expectNaturalFace();
        backend.faults.add('writeAndFlush');
        pending.complete(offlineDailyQuotes[2]);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_busy')), findsNothing);
        final retry = find.byKey(const Key('daily_poetry_cache_retry'));
        expect(retry, findsOneWidget);
        expectNaturalFace();
        backend.faults.clear();
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(retry, findsNothing);
        expect(fetches, 1);
        await tester.ensureVisible(refresh);
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_status')), findsOneWidget);
        expect(fetches, 2);
        expect(
          tester.widget<Text>(find.byKey(const Key('daily_poetry_text')))
              .textSpan!.toPlainText(),
          offlineDailyQuotes[2].text,
        );
        expectNaturalFace();
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets(
    'ACK clear keeps mounted poem and explicit reader without fetching',
    (tester) async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
        }),
      );
      var fetches = 0;
      final container = ProviderContainer(
        overrides: [
          uiPreferencesBackendProvider.overrideWithValue(backend),
          dailyQuoteClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3),
          ),
          dailyQuoteTickProvider.overrideWithValue(null),
          dailyQuoteFetchProvider.overrideWithValue(() async {
            fetches++;
            return offlineDailyQuotes[2];
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 280, height: 240, child: DailyQuoteLine()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = find.byType(DailyQuoteLine).evaluate().single;
      final displayed = tester
          .widget<Text>(find.byKey(const Key('daily_poetry_text')))
          .textSpan!
          .toPlainText();
      final service = container.read(safeCacheServiceProvider);
      service.clear(
        service.capture(SafeCacheScope.dailyQuoteV2)!,
        confirmed: true,
      );
      await tester.pumpAndSettle();
      expect(find.byType(DailyQuoteLine).evaluate().single, same(before));
      expect(
        tester
            .widget<Text>(find.byKey(const Key('daily_poetry_text')))
            .textSpan!
            .toPlainText(),
        displayed,
      );
      expect(find.textContaining('缓存已清除'), findsOneWidget);
      expect(find.byKey(const Key('daily_poetry_cache_retry')), findsNothing);
      expect(fetches, 0);
      await tester.tap(find.byKey(const Key('daily_poetry_expand')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('daily_poetry_full_text')))
            .textSpan!
            .toPlainText(),
        offlineDailyQuotes[0].fullContent.join('\n'),
      );
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(fetches, 0);
      expect(tester.takeException(), isNull);
    },
  );
  for (final size in const [
    core.WorkspaceSize.twoByOne,
    core.WorkspaceSize.twoByTwo,
    core.WorkspaceSize.twoByThree,
    core.WorkspaceSize.fullNatural,
  ]) {
    for (final width in [280.0, 720.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final long in [false, true]) {
          testWidgets(
            'registry adaptive face ${host.workspaceSizeName(size)} width$width scale$scale long$long',
            (tester) async {
              final quote = long
                  ? _complete(
                      text: '清风明月。山水相依，行行复行行。',
                      lines: [
                        '清风明月。山水相依，行行复行行。',
                        for (var i = 1; i < 24; i++) '长诗原文第$i行，末行完整保留。',
                      ],
                    )
                  : offlineDailyQuotes[0];
              final backend = MemoryPreferencesBackend();
              final repository = typed(backend, () async => quote);
              addTearDown(repository.dispose);
              final colors = ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: long ? Brightness.dark : Brightness.light,
              );
              final policy = MaterialPolicy.resolve(
                colorScheme: colors,
                wallpaper: WallpaperLoadState.absent,
                signals: const MaterialSignals(
                  highContrast: AccessibilitySignal.disabled,
                  reduceTransparency: AccessibilitySignal.enabled,
                ),
              );
              final registry = createWorkspaceRegistry();
              final descriptor = registry['dailyPoetry']!;
              expect(
                descriptor.supportedSizes.any(
                  (s) => s.sameExtent(core.WorkspaceSize.oneByOne),
                ),
                isFalse,
              );
              final bounds = BoxConstraints(
                maxWidth: width,
                minWidth: width,
                maxHeight: size.isNatural
                    ? double.infinity
                    : size.rowSpan * 172.0,
                minHeight: size.isNatural ? 0 : size.rowSpan * 172.0,
              );
              await tester.pumpWidget(
                ProviderScope(
                  overrides: [
                    dailyQuoteRepositoryProvider.overrideWithValue(repository),
                    uiPreferencesBackendProvider.overrideWithValue(backend),
                    dailyQuoteClockProvider.overrideWithValue(
                      () => DateTime(2026, 10, 3),
                    ),
                    dailyQuoteTickProvider.overrideWithValue(null),
                  ],
                  child: MaterialApp(
                    theme: ThemeData(colorScheme: colors),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      body: SingleChildScrollView(
                        child: MaterialScope(
                          policy: policy,
                          tokens: MaterialTokens.forWidth(width),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: ConstrainedBox(
                              constraints: bounds,
                              child: Builder(
                                builder: (context) => descriptor.contentBuilder(
                                  context,
                                  host.WorkspaceContentLayout(
                                    constraints: bounds,
                                    persistedSize: size,
                                    displaySize: size,
                                    contentRevision: quote,
                                    visibleIds: const {'dailyPoetry'},
                                  ),
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
              final prose = find.byKey(const Key('daily_poetry_text'));
              final face = tester.getRect(find.byType(WorkspacePoetryContent));
              final body = tester.getRect(find.byType(DailyQuoteLine));
              expect(body.width, greaterThan(0));
              expect(body.height, greaterThan(0));
              expect(body.bottom, lessThanOrEqualTo(face.bottom + .01));
              expect(
                tester.widget<Text>(prose).textSpan!.toPlainText(),
                quote.text,
              );
              expect(tester.widget<Text>(prose).textAlign, TextAlign.center);
              expect(find.byType(MaterialCard), findsOneWidget);
              expect(find.byType(BackdropFilter), findsNothing);
              expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
              final refresh = find.byKey(const Key('daily_poetry_refresh'));
              expect(tester.getSize(refresh), const Size(48, 48));
              expect(tester.getRect(refresh).right, closeTo(body.right, .01));
              final full = find.byKey(const Key('daily_poetry_expand'));
              expect(tester.getSize(full).width, greaterThanOrEqualTo(48));
              expect(tester.getSize(full).height, greaterThanOrEqualTo(48));
              await tester.ensureVisible(full);
              await tester.pumpAndSettle();
              await tester.tap(full);
              await tester.pumpAndSettle();
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const Key('daily_poetry_full_text')),
                    )
                    .textSpan!
                    .toPlainText(),
                quote.fullContent.join('\n'),
              );
              expect(
                tester
                    .widget<Text>(
                      find.byKey(const Key('daily_poetry_full_attribution')),
                    )
                    .data,
                quote.attribution,
              );
              await tester.tap(find.text('收起'));
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox());
            },
          );
        }
      }
    }
  }

  test(
    'verified cache ACK preserves display with zero automatic fetch or retry',
    () async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'foreign': {'keep': 9},
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
        }),
      );
      var fetches = 0;
      final container = ProviderContainer(
        overrides: [
          uiPreferencesBackendProvider.overrideWithValue(backend),
          dailyQuoteClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3),
          ),
          dailyQuoteFetchProvider.overrideWithValue(() async {
            fetches++;
            return offlineDailyQuotes[2];
          }),
        ],
      );
      addTearDown(container.dispose);
      final repository = container.read(dailyQuoteRepositoryProvider);
      final quote = await repository.load(DateTime(2026, 10, 3));
      expect(fetches, 0);
      final service = container.read(safeCacheServiceProvider);
      final ticket = service.capture(SafeCacheScope.dailyQuoteV2)!;
      expect(service.clear(ticket, confirmed: false), isNull);
      expect(container.read(safeCacheEpochProvider), 0);
      final result = service.clear(ticket, confirmed: true);
      expect(result!.status, UiPreferencesOperationStatus.verifiedAck);
      expect(container.read(safeCacheEpochProvider), 1);
      expect(container.read(dailyQuoteRepositoryProvider), same(repository));
      expect(repository.completedCount, 0);
      expect(repository.status('2026-10-03').quote, same(quote));
      expect(repository.status('2026-10-03').message, contains('缓存已清除'));
      expect(repository.status('2026-10-03').cachePending, isFalse);
      expect(await repository.load(DateTime(2026, 10, 3)), same(quote));
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
      expect(fetches, 0);
      final root = UiPreferencesStore.read(backend: backend);
      expect(root.containsKey('dailyQuoteV2'), isFalse);
      expect(root['foreign'], {'keep': 9});
      await repository.refresh(DateTime(2026, 10, 3));
      expect(fetches, 1);
      expect(
        repository.status('2026-10-03').quote,
        same(offlineDailyQuotes[2]),
      );
      expect(repository.status('2026-10-03').cachePending, isFalse);
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2'],
        offlineDailyQuotes[2].toCache('2026-10-03'),
      );
    },
  );

  for (final failure in ['writeAndFlush', 'future']) {
    test(
      'failed or future cache clear does not advance epoch or request $failure',
      () async {
        final original = jsonEncode({
          'version': failure == 'future' ? 2 : 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
          'foreign': 'keep',
        });
        final backend = MemoryPreferencesBackend(original);
        final container = ProviderContainer(
          overrides: [
            uiPreferencesBackendProvider.overrideWithValue(backend),
            dailyQuoteClockProvider.overrideWithValue(
              () => DateTime(2026, 10, 3),
            ),
            dailyQuoteFetchProvider.overrideWithValue(
              () => throw StateError('HTTP forbidden'),
            ),
          ],
        );
        addTearDown(container.dispose);
        final repository = container.read(dailyQuoteRepositoryProvider);
        final service = container.read(safeCacheServiceProvider);
        if (failure == 'future') {
          expect(service.capture(SafeCacheScope.dailyQuoteV2), isNull);
        } else {
          final displayed = await repository.load(DateTime(2026, 10, 3));
          final ticket = service.capture(SafeCacheScope.dailyQuoteV2)!;
          backend.faults.add(failure);
          expect(
            service.clear(ticket, confirmed: true)!.status,
            UiPreferencesOperationStatus.failed,
          );
          expect(repository.status('2026-10-03').quote, same(displayed));
        }
        expect(container.read(safeCacheEpochProvider), 0);
        expect(repository.flightCount, 0);
        expect(backend.files[backend.canonicalPath], original);
        expect(backend.commits, 0);
      },
    );
  }

  test(
    'ACK invalidates late fetch and finally without cancelling a fresh user refresh',
    () async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
        }),
      );
      final stale = Completer<DailyQuote>(), fresh = Completer<DailyQuote>();
      var fetches = 0;
      final container = ProviderContainer(
        overrides: [
          uiPreferencesBackendProvider.overrideWithValue(backend),
          dailyQuoteClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3),
          ),
          dailyQuoteFetchProvider.overrideWithValue(
            () => ++fetches == 1 ? stale.future : fresh.future,
          ),
        ],
      );
      addTearDown(container.dispose);
      final repository = container.read(dailyQuoteRepositoryProvider);
      final displayed = await repository.load(DateTime(2026, 10, 3));
      final oldFlight = repository.refresh(DateTime(2026, 10, 3));
      final service = container.read(safeCacheServiceProvider);
      service.clear(
        service.capture(SafeCacheScope.dailyQuoteV2)!,
        confirmed: true,
      );
      expect(fetches, 1);
      expect(repository.flightCount, 0);
      expect(repository.status('2026-10-03').quote, same(displayed));
      expect(repository.status('2026-10-03').busy, isFalse);
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
      final newFlight = repository.refresh(DateTime(2026, 10, 3));
      expect(fetches, 2);
      stale.complete(offlineDailyQuotes[1]);
      expect(await oldFlight, same(displayed));
      expect(repository.flightCount, 1);
      expect(repository.status('2026-10-03').busy, isTrue);
      expect(
        UiPreferencesStore.read(backend: backend).containsKey('dailyQuoteV2'),
        isFalse,
      );
      fresh.complete(offlineDailyQuotes[2]);
      await newFlight;
      expect(repository.flightCount, 0);
      expect(repository.status('2026-10-03').busy, isFalse);
      expect(
        repository.status('2026-10-03').quote,
        same(offlineDailyQuotes[2]),
      );
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2'],
        offlineDailyQuotes[2].toCache('2026-10-03'),
      );
    },
  );

  test(
    'clear during pending cache commit invalidates its validator and retry intent',
    () async {
      final backend = MemoryPreferencesBackend();
      var epoch = 0, fetches = 0, patches = 0;
      late DailyQuoteRepository repository;
      repository = DailyQuoteRepository(
        read: () => throw StateError('permissive read forbidden'),
        write: (_) => throw StateError('legacy write forbidden'),
        readOutcome: () => UiPreferencesStore.readOutcome(backend: backend),
        cacheEpoch: () => epoch,
        patch: (delta, token, validate) {
          patches++;
          epoch++;
          repository.clearMemory(visibleDate: DateTime(2026, 10, 3));
          return UiPreferencesStore.tryPatch(
            delta,
            expectedTargetToken: token,
            validateRoot: validate,
            backend: backend,
          );
        },
        fetch: () async {
          fetches++;
          return offlineDailyQuotes[2];
        },
      );
      addTearDown(repository.dispose);
      await repository.load(DateTime(2026, 10, 3));
      expect(patches, 1);
      expect(fetches, 1);
      expect(backend.commits, 0);
      expect(backend.files, isEmpty);
      expect(repository.status('2026-10-03').message, contains('缓存已清除'));
      expect(repository.status('2026-10-03').cachePending, isFalse);
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
      await repository.load(DateTime(2026, 10, 3));
      expect(fetches, 1);
    },
  );

  testWidgets(
    'verse itself is the explicit fulltext action for a complete poem',
    (tester) async {
      final repository = typed(
        MemoryPreferencesBackend(),
        () async => offlineDailyQuotes[0],
      );
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dailyQuoteRepositoryProvider.overrideWithValue(repository),
            dailyQuoteTickProvider.overrideWithValue(null),
            dailyQuoteClockProvider.overrideWithValue(
              () => DateTime(2026, 10, 3),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(width: 280, child: DailyQuoteLine())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
      await tester.tap(find.byKey(const Key('daily_poetry_text')));
      await tester.pumpAndSettle();
      expect(find.text('阅读全文'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('daily_poetry_full_text')))
            .textSpan!
            .toPlainText(),
        offlineDailyQuotes[0].fullContent.join('\n'),
      );
      expect(find.textContaining('王维'), findsWidgets);
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(232, 172),
    const Size(464, 344),
    const Size(464, 688),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('corner poetry actions remain tappable $size scale$scale', (
        tester,
      ) async {
        var fetches = 0;
        final quote = offlineDailyQuotes[2];
        final repository = typed(MemoryPreferencesBackend(), () async {
          fetches++;
          return quote;
        });
        addTearDown(repository.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              dailyQuoteRepositoryProvider.overrideWithValue(repository),
              dailyQuoteTickProvider.overrideWithValue(null),
              dailyQuoteClockProvider.overrideWithValue(
                () => DateTime(2026, 10, 4),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(800, 600),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      key: const Key('poetry_face'),
                      width: size.width,
                      height: size.height,
                      child: const DailyQuoteLine(heading: '每日诗词'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final refresh = find.byKey(const Key('daily_poetry_refresh'));
        final full = find.byKey(const Key('daily_poetry_expand'));
        expect(tester.getSize(refresh), const Size(48, 48));
        expect(tester.getSize(full).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(full).height, greaterThanOrEqualTo(48));
        expect(find.byIcon(Icons.menu_book_outlined), findsNothing);
        expect(find.text('阅读全文'), findsNothing);
        final face = tester.getRect(find.byKey(const Key('poetry_face')));
        expect(tester.getRect(refresh).right, face.right);
        expect(
          (tester.getRect(full).center.dx - face.center.dx).abs(),
          lessThan(1),
        );
        expect(tester.getRect(refresh).top, face.top);
        expect(find.text('每日诗词'), findsOneWidget);
        expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
        expect(find.byIcon(Icons.refresh), findsNothing);
        expect(find.byKey(const Key('daily_poetry_offline')), findsNothing);
        await tester.tap(refresh);
        await tester.pumpAndSettle();
        expect(fetches, 2);
        await tester.tap(full);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('daily_poetry_full_text')))
              .textSpan!
              .toPlainText(),
          quote.fullContent.join('\n'),
        );
        expect(find.byType(MaterialCard), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_full_text')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
  for (final day in [
    '2026-02-31',
    '2026-02-29',
    '2026-2-03',
    'not-a-date',
    '0000-01-01',
    '2026-00-01',
    '2026-13-01',
    '2026-01-00',
    '2026-04-31',
    '2026-01-32',
  ]) {
    test(
      'invalid complete cache day stays immutable through load refresh retry $day',
      () async {
        final original = jsonEncode({
          'version': 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache(day),
          'foreign': {'keep': 7},
        });
        final backend = MemoryPreferencesBackend(original);
        final repository = typed(backend, () async => offlineDailyQuotes[2]);
        addTearDown(repository.dispose);
        await repository.load(DateTime(2026, 10, 3));
        await repository.refresh(DateTime(2026, 10, 3));
        expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
        expect(backend.files[backend.canonicalPath], original);
        expect(backend.commits, 0);
        expect(repository.status('2026-10-03').cachePending, isTrue);
      },
    );
  }
  test(
    'valid leap day roundtrip is readable and can replace through typed ACK',
    () async {
      var fetches = 0;
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2024-02-29'),
        }),
      );
      final repository = typed(backend, () async {
        fetches++;
        return offlineDailyQuotes[2];
      });
      addTearDown(repository.dispose);
      expect(
        (await repository.load(DateTime(2024, 2, 29))).text,
        offlineDailyQuotes[0].text,
      );
      expect(fetches, 0);
      expect(repository.status('2024-02-29').cachePending, isFalse);
      await repository.refresh(DateTime(2024, 2, 29));
      expect(fetches, 1);
      expect(backend.commits, 1);
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2']['day'],
        '2024-02-29',
      );
    },
  );
  for (final externalDay in ['2026-10-03', '2026-10-04']) {
    for (final operation in ['refresh', 'retry']) {
      test(
        'full quote preimage protects $operation against external $externalDay before typed patch',
        () async {
          final old = offlineDailyQuotes[0].toCache('2026-10-03');
          final external = offlineDailyQuotes[1].toCache(externalDay);
          final backend = MemoryPreferencesBackend(
            jsonEncode({'version': 1, 'dailyQuoteV2': old, 'foreign': 7}),
          );
          var inject = false, fetches = 0;
          final repository = DailyQuoteRepository(
            read: () => throw StateError('permissive forbidden'),
            write: (_) => throw StateError('permissive forbidden'),
            readOutcome: () => UiPreferencesStore.readOutcome(backend: backend),
            patch: (delta, token, validate) {
              if (inject)
                backend.files[backend.canonicalPath] = jsonEncode({
                  'version': 1,
                  'dailyQuoteV2': external,
                  'foreign': 7,
                });
              return UiPreferencesStore.tryPatch(
                delta,
                expectedTargetToken: token,
                validateRoot: validate,
                backend: backend,
              );
            },
            fetch: () async {
              fetches++;
              return offlineDailyQuotes[2];
            },
          );
          addTearDown(repository.dispose);
          await repository.load(DateTime(2026, 10, 3));
          if (operation == 'retry') {
            backend.faults.add('writeAndFlush');
            await repository.refresh(DateTime(2026, 10, 3));
            backend.faults.clear();
          }
          inject = true;
          if (operation == 'refresh') {
            await repository.refresh(DateTime(2026, 10, 3));
          } else {
            expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
          }
          expect(
            UiPreferencesStore.read(backend: backend)['dailyQuoteV2'],
            external,
          );
          expect(repository.status('2026-10-03').cachePending, isTrue);
          expect(backend.commits, 0);
          expect(fetches, 1);
        },
      );
    }
  }
  test(
    'same-day external full content during fetch is not silently rebased',
    () async {
      final backend = MemoryPreferencesBackend(
        jsonEncode({
          'version': 1,
          'dailyQuoteV2': offlineDailyQuotes[0].toCache('2026-10-03'),
        }),
      );
      final pending = Completer<DailyQuote>();
      final repository = typed(backend, () => pending.future);
      addTearDown(repository.dispose);
      final loading = repository.refresh(DateTime(2026, 10, 3));
      final external = offlineDailyQuotes[1].toCache('2026-10-03');
      backend.files[backend.canonicalPath] = jsonEncode({
        'version': 1,
        'dailyQuoteV2': external,
      });
      pending.complete(offlineDailyQuotes[2]);
      await loading;
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2'],
        external,
      );
      expect(backend.commits, 0);
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
    },
  );
  test(
    'unrelated background changes merge without quote CAS conflict',
    () async {
      final old = offlineDailyQuotes[0].toCache('2026-10-03');
      final backend = MemoryPreferencesBackend(
        jsonEncode({'version': 1, 'dailyQuoteV2': old, 'background': 'before'}),
      );
      final repository = DailyQuoteRepository(
        read: () => {},
        write: (_) => throw StateError('forbidden'),
        readOutcome: () => UiPreferencesStore.readOutcome(backend: backend),
        patch: (delta, token, validate) {
          backend.files[backend.canonicalPath] = jsonEncode({
            'version': 1,
            'dailyQuoteV2': old,
            'background': 'fresh',
            'foreign': {'keep': 9},
          });
          return UiPreferencesStore.tryPatch(
            delta,
            expectedTargetToken: token,
            validateRoot: validate,
            backend: backend,
          );
        },
        fetch: () async => offlineDailyQuotes[2],
      );
      addTearDown(repository.dispose);
      await repository.refresh(DateTime(2026, 10, 3));
      final root = UiPreferencesStore.read(backend: backend);
      expect(root['background'], 'fresh');
      expect(root['foreign'], {'keep': 9});
      expect(root['dailyQuoteV2'], offlineDailyQuotes[2].toCache('2026-10-03'));
      expect(repository.status('2026-10-03').cachePending, isFalse);
    },
  );
  for (final stage in ['afterFlush', 'beforeBackup']) {
    test(
      'shared $stage race conserves external bytes and pending full preimage',
      () async {
        final old = offlineDailyQuotes[0].toCache('2026-10-03');
        final external = offlineDailyQuotes[1].toCache('2026-10-03');
        final backend = MemoryPreferencesBackend(
          jsonEncode({'version': 1, 'dailyQuoteV2': old, 'foreign': 7}),
        );
        final bytes = jsonEncode({
          'version': 1,
          'dailyQuoteV2': external,
          'foreign': 8,
        });
        if (stage == 'afterFlush') {
          backend.afterFlush = () =>
              backend.files[backend.canonicalPath] = bytes;
        } else {
          backend.beforeBackup = () =>
              backend.files[backend.canonicalPath] = bytes;
        }
        var fetches = 0;
        final repository = typed(backend, () async {
          fetches++;
          return offlineDailyQuotes[2];
        });
        addTearDown(repository.dispose);
        await repository.refresh(DateTime(2026, 10, 3));
        expect(backend.files[backend.canonicalPath], bytes);
        expect(backend.commits, 0);
        expect(repository.status('2026-10-03').cachePending, isTrue);
        backend.afterFlush = null;
        backend.beforeBackup = null;
        expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
        expect(backend.files[backend.canonicalPath], bytes);
        expect(fetches, 1);
      },
    );
  }
  test(
    'lost typed ACK retries exact result without another commit backup or fetch',
    () async {
      final backend = MemoryPreferencesBackend(
        '{"version":1,"background":"keep"}',
      )..faults.add('verify');
      var fetches = 0;
      final repository = typed(backend, () async {
        fetches++;
        return offlineDailyQuotes[2];
      });
      addTearDown(repository.dispose);
      await repository.load(DateTime(2026, 10, 3));
      expect(backend.commits, 1);
      expect(repository.status('2026-10-03').cachePending, isTrue);
      final before = Map.of(backend.files);
      backend.faults.clear();
      expect(repository.retryCache(DateTime(2026, 10, 3)), isTrue);
      expect(backend.files, before);
      expect(backend.commits, 1);
      expect(fetches, 1);
      expect(repository.status('2026-10-03').cachePending, isFalse);
    },
  );
  test(
    'same already stored result is acknowledged with zero new backups',
    () async {
      final backend = MemoryPreferencesBackend();
      var calls = 0;
      final repository = typed(backend, () async {
        calls++;
        return offlineDailyQuotes[0];
      });
      addTearDown(repository.dispose);
      await repository.load(DateTime(2026, 10, 3));
      final before = Map.of(backend.files), commits = backend.commits;
      await repository.refresh(DateTime(2026, 10, 3));
      expect(backend.files, before);
      expect(backend.commits, commits);
      expect(calls, 2);
      expect(repository.status('2026-10-03').cachePending, isFalse);
      expect(repository.status('2026-10-03').message, '这次仍是同一句');
    },
  );
  test(
    'failed replacement preserves pending old value and retry is cache-only',
    () async {
      final backend = MemoryPreferencesBackend()..faults.add('writeAndFlush');
      var fetches = 0;
      final repository = typed(backend, () async {
        if (++fetches == 2) throw StateError('synthetic');
        return offlineDailyQuotes[0];
      });
      addTearDown(repository.dispose);
      final old = await repository.load(DateTime(2026, 10, 3));
      expect(repository.status('2026-10-03').cachePending, isTrue);
      expect(await repository.refresh(DateTime(2026, 10, 3)), same(old));
      expect(repository.status('2026-10-03').cachePending, isTrue);
      backend.faults.clear();
      expect(repository.retryCache(DateTime(2026, 10, 3)), isTrue);
      expect(fetches, 2);
      expect(backend.commits, 1);
    },
  );
  test(
    'different visible replacement write fails and retry saves without refetch',
    () async {
      var fetches = 0;
      final backend = MemoryPreferencesBackend();
      final repository = typed(
        backend,
        () async =>
            ++fetches == 1 ? offlineDailyQuotes[0] : offlineDailyQuotes[2],
      );
      addTearDown(repository.dispose);
      await repository.load(DateTime(2026, 10, 3));
      backend.faults.add('writeAndFlush');
      final quote = await repository.refresh(DateTime(2026, 10, 3));
      expect(quote, same(offlineDailyQuotes[2]));
      expect(repository.status('2026-10-03').cachePending, isTrue);
      backend.faults.clear();
      expect(repository.retryCache(DateTime(2026, 10, 3)), isTrue);
      expect(fetches, 2);
      expect(backend.commits, 2);
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2'],
        quote.toCache('2026-10-03'),
      );
    },
  );

  test(
    'unsubscribed day family releases while completed memory remains bounded',
    () async {
      final repository = DailyQuoteRepository(
        read: () => {},
        write: (_) {},
        fetch: () async => _complete(),
      );
      addTearDown(repository.dispose);
      final container = ProviderContainer(
        overrides: [dailyQuoteRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      const day = '2026-10-03T00:00:00.000';
      final listener = container.listen(dailyQuoteProvider(day), (_, _) {});
      await container.read(dailyQuoteProvider(day).future);
      expect(container.exists(dailyQuoteProvider(day)), isTrue);
      listener.close();
      await container.pump();
      expect(container.exists(dailyQuoteProvider(day)), isFalse);
      expect(repository.completedCount, 1);
      expect(repository.flightCount, 0);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'full poem uses one inherited material card $brightness scale2',
      (tester) async {
        final colors = ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        );
        final policy = MaterialPolicy.resolve(
          colorScheme: colors,
          wallpaper: WallpaperLoadState.absent,
          signals: const MaterialSignals(
            highContrast: AccessibilitySignal.disabled,
            reduceTransparency: AccessibilitySignal.enabled,
          ),
        );
        final repository = DailyQuoteRepository(
          read: () => {},
          write: (_) {},
          fetch: () async => offlineDailyQuotes[2],
        );
        addTearDown(repository.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              dailyQuoteRepositoryProvider.overrideWithValue(repository),
              dailyQuoteTickProvider.overrideWithValue(null),
              dailyQuoteClockProvider.overrideWithValue(
                () => DateTime(2026, 10, 3),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(colorScheme: colors),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: MaterialScope(
                  policy: policy,
                  tokens: MaterialTokens.forWidth(280),
                  child: const SizedBox(width: 280, child: DailyQuoteLine()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('daily_poetry_expand')));
        await tester.pumpAndSettle();
        expect(find.byType(MaterialCard), findsOneWidget);
        expect(
          tester.widget<Card>(find.byType(Card)).color,
          policy.contentSurface,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(
          MediaQuery.textScalerOf(
            tester.element(find.byKey(const Key('daily_poetry_full_text'))),
          ).scale(19),
          38,
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'explicit replacement joins load; busy ends and identical result is honest',
    () async {
      final pending = Completer<DailyQuote>();
      var calls = 0;
      final repository = typed(MemoryPreferencesBackend(), () {
        calls++;
        return pending.future;
      });
      addTearDown(repository.dispose);
      final a = repository.load(DateTime(2026, 10, 3));
      final b = repository.refresh(DateTime(2026, 10, 3));
      expect(calls, 1);
      expect(repository.flightCount, 1);
      expect(repository.status('2026-10-03').busy, isTrue);
      pending.complete(_complete());
      expect(await a, same(await b));
      expect(repository.flightCount, 0);
      expect(repository.status('2026-10-03').busy, isFalse);
      await repository.refresh(DateTime(2026, 10, 3));
      expect(calls, 2);
      expect(repository.status('2026-10-03').message, '这次仍是同一句');
    },
  );
  test(
    'completed LRU contains only seven; active flights separate and offline explicit',
    () async {
      var calls = 0;
      final repository = typed(MemoryPreferencesBackend(), () async {
        calls++;
        return _complete();
      });
      addTearDown(repository.dispose);
      for (var day = 1; day <= 7; day++) {
        await repository.load(DateTime(2026, 10, day));
      }
      await repository.load(DateTime(2026, 10, 1));
      await repository.load(DateTime(2026, 10, 8));
      expect(repository.completedCount, 7);
      expect(repository.completedDays, contains('2026-10-01'));
      expect(repository.completedDays, isNot(contains('2026-10-02')));
      expect(repository.flightCount, 0);
      await repository.load(DateTime(2026, 10, 2));
      expect(calls, 9);
      final before = calls;
      for (var i = 0; i < 4; i++) {
        final quote = await repository.refresh(
          DateTime(2026, 10, 8),
          offline: true,
        );
        expect(offlineDailyQuotes, contains(same(quote)));
      }
      expect(calls, before);
      expect(repository.completedCount, 7);
    },
  );
  for (final original in [
    '{"version":2,"foreign":"future"}',
    '{bad',
    jsonEncode({
      'version': 1,
      'dailyQuoteV2': {'schemaVersion': 3, 'private': 'preserve'},
    }),
    jsonEncode({
      'version': 1,
      'dailyQuoteV2': {'schemaVersion': 2, 'day': '2026-10-03', 'text': 7},
    }),
  ]) {
    test('typed future/corrupt bytes failclosed $original', () async {
      final backend = MemoryPreferencesBackend(original);
      final repository = typed(backend, () async => _complete());
      addTearDown(repository.dispose);
      expect(
        (await repository.load(DateTime(2026, 10, 3))).hasFullPoem,
        isTrue,
      );
      await repository.refresh(DateTime(2026, 10, 3));
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
      expect(backend.commits, 0);
      expect(backend.files[backend.canonicalPath], original);
      expect(repository.status('2026-10-03').cachePending, isTrue);
    });
  }
  test(
    'typed write failure preserves displayed value and cache retry never fetches',
    () async {
      final backend = MemoryPreferencesBackend(
        '{"version":1,"unknown":{"keep":9}}',
      )..faults.add('writeAndFlush');
      var calls = 0;
      final repository = typed(backend, () async {
        calls++;
        return _complete();
      });
      addTearDown(repository.dispose);
      final quote = await repository.load(DateTime(2026, 10, 3));
      expect(repository.status('2026-10-03').quote, same(quote));
      expect(repository.status('2026-10-03').cachePending, isTrue);
      backend.faults.clear();
      expect(repository.retryCache(DateTime(2026, 10, 3)), isTrue);
      expect(calls, 1);
      expect(backend.commits, 1);
      expect(UiPreferencesStore.read(backend: backend)['unknown'], {'keep': 9});
      expect(repository.status('2026-10-03').cachePending, isFalse);
    },
  );
  test(
    'midnight old completion and old retry cannot overwrite new single slot',
    () async {
      final backend = MemoryPreferencesBackend();
      final old = Completer<DailyQuote>(), next = Completer<DailyQuote>();
      var calls = 0;
      final repository = typed(
        backend,
        () => ++calls == 1 ? old.future : next.future,
      );
      addTearDown(repository.dispose);
      final a = repository.load(DateTime(2026, 10, 3));
      final b = repository.load(DateTime(2026, 10, 4));
      next.complete(offlineDailyQuotes[1]);
      await b;
      old.complete(offlineDailyQuotes[0]);
      await a;
      expect(repository.status('2026-10-03').cachePending, isTrue);
      final before = Map.of(backend.files), commits = backend.commits;
      expect(repository.retryCache(DateTime(2026, 10, 3)), isFalse);
      expect(backend.files, before);
      expect(backend.commits, commits);
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2']['day'],
        '2026-10-04',
      );
      expect(repository.flightCount, 0);
    },
  );
  test(
    'disposed late request has no cache or completed side effects',
    () async {
      final backend = MemoryPreferencesBackend(),
          pending = Completer<DailyQuote>();
      final repository = typed(backend, () => pending.future);
      final result = repository.load(DateTime(2026, 10, 3));
      repository.dispose();
      pending.complete(_complete());
      await result;
      expect(backend.files, isEmpty);
      expect(repository.completedCount, 0);
      expect(repository.flightCount, 0);
    },
  );
  test(
    'failed replacement retains previous full value, then retry succeeds',
    () async {
      var calls = 0;
      final repository = typed(MemoryPreferencesBackend(), () async {
        calls++;
        if (calls == 2) throw StateError('synthetic failure');
        return calls == 1 ? offlineDailyQuotes[0] : offlineDailyQuotes[2];
      });
      addTearDown(repository.dispose);
      final first = await repository.load(DateTime(2026, 10, 3));
      expect(await repository.refresh(DateTime(2026, 10, 3)), same(first));
      expect(repository.status('2026-10-03').busy, isFalse);
      expect(repository.status('2026-10-03').message, contains('保留'));
      expect(
        await repository.refresh(DateTime(2026, 10, 3)),
        same(offlineDailyQuotes[2]),
      );
      expect(calls, 3);
    },
  );
  testWidgets(
    'two explicit entry points share pending and deliver busy/result without stream gap',
    (tester) async {
      final pending = Completer<DailyQuote>();
      var calls = 0;
      final repository = typed(MemoryPreferencesBackend(), () {
        calls++;
        return calls == 1
            ? Future.value(offlineDailyQuotes[0])
            : pending.future;
      });
      addTearDown(repository.dispose);
      final container = ProviderContainer(
        overrides: [
          dailyQuoteRepositoryProvider.overrideWithValue(repository),
          dailyQuoteTickProvider.overrideWithValue(null),
          dailyQuoteClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(children: [DailyQuoteLine(), DailyQuoteLine()]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('daily_poetry_refresh')).first);
      await tester.pump();
      expect(calls, 2);
      expect(find.byKey(const Key('daily_poetry_busy')), findsNWidgets(2));
      expect(find.text('正在换一首…'), findsNWidgets(2));
      expect(find.byTooltip('下一首'), findsNWidgets(2));
      for (final refresh
          in find.byKey(const Key('daily_poetry_refresh')).evaluate()) {
        expect(
          tester.getSize(find.byWidget(refresh.widget)),
          const Size(48, 48),
        );
      }
      expect(find.byKey(const Key('daily_poetry_text')), findsNWidgets(2));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('daily_poetry_refresh')).last,
            )
            .onPressed,
        isNull,
      );
      pending.complete(offlineDailyQuotes[2]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('daily_poetry_busy')), findsNothing);
      for (final text in tester.widgetList<Text>(
        find.byKey(const Key('daily_poetry_text')),
      )) {
        expect(text.textSpan!.toPlainText(), offlineDailyQuotes[2].text);
      }
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mounted midnight timer moves family day and old result never relabels current',
    (tester) async {
      var now = DateTime(2026, 10, 3, 23, 59), calls = 0;
      final old = Completer<DailyQuote>(), next = Completer<DailyQuote>();
      final backend = MemoryPreferencesBackend();
      final repository = typed(
        backend,
        () => ++calls == 1 ? old.future : next.future,
      );
      addTearDown(repository.dispose);
      final container = ProviderContainer(
        overrides: [
          dailyQuoteRepositoryProvider.overrideWithValue(repository),
          dailyQuoteTickProvider.overrideWithValue(const Duration(seconds: 1)),
          dailyQuoteClockProvider.overrideWithValue(() => now),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: DailyQuoteLine())),
        ),
      );
      await tester.pump();
      expect(calls, 1);
      now = DateTime(2026, 10, 4, 0, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      next.complete(offlineDailyQuotes[2]);
      await tester.pump();
      await tester.pump();
      old.complete(offlineDailyQuotes[0]);
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('daily_poetry_text')))
            .textSpan!
            .toPlainText(),
        offlineDailyQuotes[2].text,
      );
      expect(
        UiPreferencesStore.read(backend: backend)['dailyQuoteV2']['day'],
        '2026-10-04',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'complete model snapshots lines and accepts a verified one-line work',
    () {
      final lines = ['清风明月。', '末句有出处。'];
      final quote = _complete(lines: lines);
      lines[0] = '被外部修改';
      expect(quote.fullContent.first, '清风明月。');
      expect(() => quote.fullContent.add('篡改'), throwsUnsupportedError);
      expect(_complete(lines: ['清风明月。']).hasFullPoem, isTrue);
      expect(const DailyQuote('摘句', '旧缓存').hasFullPoem, isFalse);
    },
  );

  test(
    'public HTTP is fixed, bounded and caches only allowed poem fields',
    () async {
      final client = _Client();
      final quote = await fetchDailyQuote(clientFactory: () => client);
      expect(client.uris.single.toString(), dailyPoemEndpoint);
      expect(client.uris.single.query, isEmpty);
      expect(client.uris.single.userInfo, isEmpty);
      expect(client.connectionTimeout, const Duration(seconds: 5));
      expect(client.request.followRedirects, isFalse);
      expect(client.request.trackedHeaders.writes, isEmpty);
      expect(client.forceCloses, [true]);
      expect(quote.hasFullPoem, isTrue);
      expect(quote.fullContent, ['清风明月。', '末句有出处。']);
      final cache = jsonEncode(quote.toCache('2026-10-03'));
      for (final forbidden in [
        'SECRET-TOKEN',
        'SECRET-IP',
        'PRIVATE-TAG',
        'MODERN-TRANSLATION',
        'translate',
        'matchTags',
        'token',
      ]) {
        expect(cache, isNot(contains(forbidden)));
      }
      expect(quote.sourceUrl, dailyPoemEndpoint);
    },
  );

  final badPayloads = <String, void Function(Map<String, dynamic>)>{
    'status': (p) => p['status'] = 'error',
    'data type': (p) => p['data'] = [],
    'origin missing': (p) => (p['data'] as Map).remove('origin'),
    'title type': (p) => ((p['data'] as Map)['origin'] as Map)['title'] = 7,
    'author bound': (p) =>
        ((p['data'] as Map)['origin'] as Map)['author'] = 'x' * 121,
    'dynasty empty': (p) =>
        ((p['data'] as Map)['origin'] as Map)['dynasty'] = ' ',
    'excerpt bound': (p) => (p['data'] as Map)['content'] = 'x' * 121,
    'mismatched excerpt': (p) => (p['data'] as Map)['content'] = '另一首作品',
    'line wrong type': (p) =>
        ((p['data'] as Map)['origin'] as Map)['content'] = [7],
    'empty lines': (p) => ((p['data'] as Map)['origin'] as Map)['content'] = [],
    'empty line': (p) =>
        ((p['data'] as Map)['origin'] as Map)['content'] = [' '],
    'too many lines': (p) => ((p['data'] as Map)['origin'] as Map)['content'] =
        List.filled(129, '清风明月。'),
    'line length': (p) =>
        ((p['data'] as Map)['origin'] as Map)['content'] = ['x' * 513],
    'total length': (p) => ((p['data'] as Map)['origin'] as Map)['content'] =
        List.filled(128, 'x' * 129),
  };
  for (final entry in badPayloads.entries) {
    test(
      'invalid full poem ${entry.key} falls back as one complete value',
      () async {
        final payload = _payload();
        entry.value(payload);
        final client = _Client(chunks: [utf8.encode(jsonEncode(payload))]);
        final repository = DailyQuoteRepository(
          read: () => {},
          write: (_) {},
          fetch: () => fetchDailyQuote(clientFactory: () => client),
        );
        final quote = await repository.load(DateTime(2026, 10, 3));
        expect(quote.hasFullPoem, isTrue);
        expect(quote.online, isFalse);
        expect(offlineDailyQuotes, contains(same(quote)));
        expect(client.forceCloses, [true]);
      },
    );
  }

  for (final (name, status, chunks) in <(String, int, List<List<int>>)>[
    ('redirect', 302, [utf8.encode(jsonEncode(_payload()))]),
    ('server error', 500, []),
    ('bad JSON', 200, [utf8.encode('{broken')]),
    (
      'bad UTF8',
      200,
      [
        [0xff, 0xfe],
      ],
    ),
    (
      'over 32KiB',
      200,
      [
        List.filled(32768, 32),
        [32],
      ],
    ),
  ]) {
    test('$name rejects response and always closes client', () async {
      final client = _Client(status: status, chunks: chunks);
      await expectLater(
        fetchDailyQuote(clientFactory: () => client),
        throwsFormatException,
      );
      expect(client.forceCloses, [true]);
      expect(client.request.followRedirects, isFalse);
    });
  }
  test(
    'exact 32KiB response is accepted, not an off-by-one rejection',
    () async {
      final bytes = utf8.encode(jsonEncode(_payload()));
      final client = _Client(
        chunks: [bytes, List.filled(32768 - bytes.length, 32)],
      );
      expect(
        (await fetchDailyQuote(clientFactory: () => client)).hasFullPoem,
        isTrue,
      );
      expect(client.forceCloses, [true]);
    },
  );

  test(
    'deadline covers continuous chunks rather than resetting per chunk',
    () async {
      final stream = StreamController<List<int>>();
      final client = _Client()
        ..request = _Request(() async => _Response(200, stream.stream));
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => stream.add([32]),
      );
      try {
        await expectLater(
          fetchDailyQuote(
            clientFactory: () => client,
            deadline: const Duration(milliseconds: 50),
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(client.forceCloses, [true]);
      } finally {
        timer.cancel();
        // Release the underlying cancelled read as well as the visible timeout.
        stream.add([32]);
        await stream.close();
      }
    },
  );
  test(
    'connect timeout closes client and rejects late request before close',
    () async {
      final connection = Completer<HttpClientRequest>();
      final client = _Client()..connect = () => connection.future;
      await expectLater(
        fetchDailyQuote(
          clientFactory: () => client,
          deadline: const Duration(milliseconds: 10),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.forceCloses, [true]);
      connection.complete(client.request);
      await Future<void>.delayed(Duration.zero);
      expect(client.request.closes, 0);
      expect(client.request.aborts, 1);
    },
  );
  test('headers timeout aborts the pending request', () async {
    final headers = Completer<HttpClientResponse>();
    final client = _Client()..request = _Request(() => headers.future);
    await expectLater(
      fetchDailyQuote(
        clientFactory: () => client,
        deadline: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.request.aborts, 1);
    expect(client.forceCloses, [true]);
    headers.complete(
      _Response(200, Stream.value(utf8.encode(jsonEncode(_payload())))),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'V1 is upgraded once and is never paired with an unrelated full poem',
    () async {
      var calls = 0;
      final legacy = {'day': '2026-10-3', 'text': '不应配其他全文', 'source': '旧作品'};
      final prefs = <String, dynamic>{
        'keep': {'nested': true},
        'dailyQuoteV1': legacy,
      };
      final repository = DailyQuoteRepository(
        read: () => prefs,
        write: (delta) {
          expect(delta.keys, ['dailyQuoteV2']);
          prefs.addAll(delta);
        },
        fetch: () async {
          calls++;
          throw StateError('synthetic unavailable');
        },
      );
      final quote = await repository.load(DateTime(2026, 10, 3));
      expect(quote.text, isNot('不应配其他全文'));
      expect(quote.hasFullPoem, isTrue);
      expect(prefs['dailyQuoteV1'], same(legacy));
      expect(prefs['keep'], {'nested': true});
      expect(calls, 1);
      final restarted = DailyQuoteRepository(
        read: () => prefs,
        write: (_) {},
        fetch: () async => throw StateError('must not fetch complete cache'),
      );
      expect(
        (await restarted.load(DateTime(2026, 10, 3))).fullContent,
        quote.fullContent,
      );
    },
  );
  test('bad V2 mismatch is replaced with a valid one-line work', () async {
    final cached = _complete().toCache('2026-10-03')..['text'] = '别首诗';
    var calls = 0;
    final repository = DailyQuoteRepository(
      read: () => {'dailyQuoteV2': cached},
      write: (_) {},
      fetch: () async {
        calls++;
        return _complete(lines: ['清风明月。']);
      },
    );
    expect((await repository.load(DateTime(2026, 10, 3))).fullContent, [
      '清风明月。',
    ]);
    expect(calls, 1);
  });
  test(
    'concurrent same-day loads share one fetch and stay in memory after write failure',
    () async {
      var calls = 0;
      final pending = Completer<DailyQuote>();
      final repository = DailyQuoteRepository(
        read: () => {},
        write: (_) => throw StateError('synthetic write'),
        fetch: () {
          calls++;
          return pending.future;
        },
      );
      final a = repository.load(DateTime(2026, 10, 3));
      final b = repository.load(DateTime(2026, 10, 3));
      expect(calls, 1);
      pending.complete(_complete());
      expect(await a, same(await b));
      expect(
        (await repository.load(DateTime(2026, 10, 3))).hasFullPoem,
        isTrue,
      );
      expect(calls, 1);
    },
  );
  test(
    'read failure never writes unknown prefs and still returns full content',
    () async {
      var writes = 0;
      var calls = 0;
      final repository = DailyQuoteRepository(
        read: () => throw StateError('synthetic read'),
        write: (_) {
          writes++;
        },
        fetch: () async {
          calls++;
          return _complete();
        },
      );
      expect(
        (await repository.load(DateTime(2026, 10, 3))).fullContent.last,
        '末句有出处。',
      );
      expect(
        (await repository.load(DateTime(2026, 10, 3))).hasFullPoem,
        isTrue,
      );
      expect(writes, 0);
      expect(calls, 1);
    },
  );
  test(
    'all three offline originals match the checked source, including final lines',
    () {
      expect(offlineDailyQuotes.length, 3);
      expect(offlineDailyQuotes[0].fullContent, [
        '中岁颇好道，晚家南山陲。',
        '兴来每独往，胜事空自知。',
        '行到水穷处，坐看云起时。',
        '偶然值林叟，谈笑无还期。',
      ]);
      expect(offlineDailyQuotes[1].fullContent, [
        '春未老，风细柳斜斜。',
        '试上超然台上看，半壕春水一城花。',
        '烟雨暗千家。',
        '寒食后，酒醒却咨嗟。',
        '休对故人思故国，且将新火试新茶。',
        '诗酒趁年华。',
      ]);
      expect(offlineDailyQuotes[2].fullContent, [
        '莫笑农家腊酒浑，丰年留客足鸡豚。',
        '山重水复疑无路，柳暗花明又一村。',
        '箫鼓追随春社近，衣冠简朴古风存。',
        '从今若许闲乘月，拄杖无时夜叩门。',
      ]);
      expect(offlineDailyQuotes.map((q) => q.dynasty), ['唐', '北宋', '南宋']);
      for (final quote in offlineDailyQuotes) {
        expect(quote.hasFullPoem, isTrue);
        expect(quote.sourceUrl, contains('oldid='));
        expect(quote.fullContent.join().contains(quote.text), isTrue);
      }
    },
  );

  for (final width in [280.0, 720.0]) {
    testWidgets(
      'full poem dialog includes original first and final lines at $width scale2',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final quote = offlineDailyQuotes[2];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              dailyQuoteTickProvider.overrideWithValue(null),
              dailyQuoteClockProvider.overrideWithValue(
                () => DateTime(2026, 10, 3, 12),
              ),
              dailyQuoteRepositoryProvider.overrideWithValue(
                DailyQuoteRepository(
                  read: () => {},
                  write: (_) {},
                  fetch: () async => quote,
                ),
              ),
            ],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: SizedBox(width: width, child: const DailyQuoteLine()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final collapsed = tester.widget<Text>(
          find.byKey(const Key('daily_poetry_text')),
        );
        expect(collapsed.textSpan!.toPlainText(), quote.text);
        expect(find.byKey(const Key('daily_poetry_full_text')), findsNothing);
        expect(find.byTooltip('下一首'), findsOneWidget);
        expect(find.byTooltip('换一首离线诗'), findsNothing);
        expect(find.byWidgetPredicate((widget) =>
          widget is Semantics && widget.properties.label == '阅读全文'),
          findsOneWidget);
        await tester.tap(find.byKey(const Key('daily_poetry_expand')));
        await tester.pumpAndSettle();
        expect(find.text('游山西村'), findsOneWidget);
        final full = tester.widget<Text>(
          find.byKey(const Key('daily_poetry_full_text')),
        );
        expect(full.textSpan!.toPlainText(), quote.fullContent.join('\n'));
        expect(full.textSpan!.toPlainText(), contains('莫笑农家腊酒浑'));
        expect(full.textSpan!.toPlainText(), contains('拄杖无时夜叩门'));
        expect(full.maxLines, isNull);
        expect(find.byType(SelectionArea), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsWidgets);
        final provenance = tester.widget<Text>(
          find.byKey(const Key('daily_poetry_full_attribution')),
        );
        expect(provenance.data, contains('〔南宋〕陆游'));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('daily_poetry_full_text')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'incomplete quote is plain prose without full-poem button or semantics',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dailyQuoteProvider.overrideWith(
              (ref, day) async => const DailyQuote('仅有摘句', '未知出处'),
            ),
            dailyQuoteRepositoryProvider.overrideWithValue(
              DailyQuoteRepository(
                read: () => {},
                write: (_) {},
                fetch: () async => throw StateError('unused'),
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SizedBox(width: 280, child: DailyQuoteLine())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final handle = tester.ensureSemantics();
      try {
        expect(find.byKey(const Key('daily_poetry_expand')), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(find.bySemanticsLabel('展开诗句全文'), findsNothing);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('daily_poetry_text')))
              .textSpan!
              .toPlainText(),
          '仅有摘句',
        );
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );
  test(
    'attribution deduplicates legacy names and preserves known dynasty only',
    () {
      expect(const DailyQuote('句子', '陆游 · 陆游').attribution, '〔宋〕陆游');
      expect(const DailyQuote('句子', '王维《终南别业》').attribution, '〔唐〕王维 · 《终南别业》');
      expect(
        const DailyQuote('句子', 'raw', author: '陆游', work: '陆游').attribution,
        '〔宋〕陆游',
      );
      expect(
        const DailyQuote(
          '句子',
          'raw',
          author: 'Unknown',
          work: 'Book',
        ).attribution,
        'Unknown · 《Book》',
      );
      expect(
        const DailyQuote('句子', 'Unknown · Unknown').attribution,
        'Unknown',
      );
      final cached = DailyQuote.decode({
        'text': '句子',
        'source': 'raw',
        'author': '陆游',
        'work': '游山西村',
      });
      expect(cached!.attribution, '〔宋〕陆游 · 《游山西村》');
    },
  );
  for (final width in [280.0, 720.0]) {
    testWidgets('diary title and poetry balance at $width', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: DiaryHeadingContent(
                date: DateTime(2026, 10, 3),
                showQuote: true,
                quote: const SizedBox(key: Key('quote_fixture'), height: 64),
              ),
            ),
          ),
        ),
      );
      final identity = tester.getRect(
        find.byKey(const Key('diary_heading_identity')),
      );
      final quote = tester.getRect(find.byKey(const Key('quote_fixture')));
      if (width >= 480) {
        expect(quote.left, greaterThan(identity.right));
        expect((quote.center.dy - identity.center.dy).abs(), lessThan(1));
      } else {
        expect(quote.top, greaterThan(identity.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'daily cache survives repository restart and refreshes next day',
    () async {
      var calls = 0;
      var prefs = <String, dynamic>{'keep': true};
      DailyQuoteRepository repository() => DailyQuoteRepository(
        read: () => prefs,
        write: (value) => prefs.addAll(value),
        fetch: () async {
          calls++;
          return _complete();
        },
      );
      final today = DateTime(2026, 10, 3);
      final first = await repository().load(today);
      final restarted = await repository().load(today);
      expect(first.text, restarted.text);
      expect(calls, 1);
      expect(prefs['keep'], isTrue);
      await repository().load(DateTime(2026, 10, 4));
      expect(calls, 2);
    },
  );
  test(
    'network failure and bad cache produce bounded offline daily poem',
    () async {
      var prefs = <String, dynamic>{
        'dailyQuoteV1': {'day': '2026-10-3', 'text': 7},
      };
      final repository = DailyQuoteRepository(
        read: () => prefs,
        write: (value) => prefs.addAll(value),
        fetch: () async => throw Exception('offline'),
      );
      final quote = await repository.load(DateTime(2026, 10, 3));
      expect(quote.online, isFalse);
      expect(quote.text, isNotEmpty);
      expect((await repository.load(DateTime(2026, 10, 3))).text, quote.text);
      expect(DailyQuote.decode({'text': 'x' * 121, 'source': ''}), isNull);
    },
  );
  testWidgets('daily line fits narrow width and large text with provenance', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dailyQuoteRepositoryProvider.overrideWithValue(
            DailyQuoteRepository(
              read: () => {},
              write: (_) {},
              fetch: () async => offlineDailyQuotes[2],
            ),
          ),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: SizedBox(width: 240, child: DailyQuoteLine()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('〔南宋〕陆游'), findsOneWidget);
    expect(find.byTooltip('下一首'), findsOneWidget);
    expect(find.byTooltip('换一首离线诗'), findsNothing);
    expect(find.byWidgetPredicate((widget) =>
          widget is Semantics && widget.properties.label == '阅读全文'),
          findsOneWidget);
    expect(find.textContaining('不上传日记'), findsNothing);
    await tester.tap(find.byKey(const Key('daily_poetry_expand')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daily_poetry_full_text')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('daily_poetry_full_text')))
          .maxLines,
      isNull,
    );
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daily_poetry_full_text')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mixed poetry uses distinct Chinese and Latin font runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dailyQuoteRepositoryProvider.overrideWithValue(
            DailyQuoteRepository(
              read: () => {},
              write: (_) {},
              fetch: () async => _complete(
                text: '清风与明月. Stay gentle.',
                lines: ['清风与明月. Stay gentle.', 'Another gentle line.'],
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 600, child: DailyQuoteLine())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final poetry = tester.widget<Text>(
      find.byKey(const Key('daily_poetry_text')),
    );
    final runs = (poetry.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(runs.first.style!.fontFamily, 'KaiTi');
    expect(runs.last.style!.fontFamily, 'Georgia');
    expect(runs.last.style!.fontStyle, FontStyle.italic);
    expect(runs.first.style!.fontStyle, FontStyle.normal);
    expect(poetry.textAlign, TextAlign.center);
    await tester.tap(find.byKey(const Key('daily_poetry_expand')));
    await tester.pumpAndSettle();
    final full = tester.widget<Text>(
      find.byKey(const Key('daily_poetry_full_text')),
    );
    final fullRuns = (full.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(fullRuns.first.style!.fontFamily, 'KaiTi');
    expect(fullRuns.last.style!.fontFamily, 'Georgia');
    expect(full.textSpan!.toPlainText(), contains('Another gentle line.'));
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
