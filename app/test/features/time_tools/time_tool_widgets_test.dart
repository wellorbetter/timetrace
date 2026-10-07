import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:timetrace_app/src/features/dashboard/providers/daily_quote_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/daily_quote_line.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/workspace_component_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_controller.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/features/feed/providers/feed_preferences_provider.dart';
import 'package:timetrace_app/src/features/time_tools/providers/time_tools_provider.dart';
import 'package:timetrace_app/src/features/time_tools/data/time_tools_store.dart';
import 'package:timetrace_app/src/features/time_tools/presentation/time_session_history_screen.dart';
import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/workspace/workspace_host.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/features/time_tools/domain/time_tool_state.dart';
import 'package:timetrace_app/src/features/time_tools/presentation/time_tool_widgets.dart';

import 'time_tools_state_test.dart' show Fixture, MemoryTimeStore;

/// No File/Directory/environment/native/backend default is evaluated.
class PublicMemoryAckStore implements TimeToolsStore {
  PublicMemoryAckStore(this.saved);
  TimeToolsState saved;
  Completer<void>? pending;
  bool fail = false;
  int attempts = 0;
  final writes = <TimeToolsState>[];
  @override
  Future<TimeToolsLoad> load() async => TimeToolsLoad(value: saved);
  @override
  Future<void> put(TimeToolsState value, {
    TimeToolsState? expectedBase, bool checkBase = false,
  }) async {
    attempts++;
    if (checkBase && jsonEncode(expectedBase?.toJson()) != jsonEncode(saved.toJson())) {
      throw StateError('synthetic CAS mismatch');
    }
    await pending?.future;
    if (fail) throw StateError('synthetic failed ACK');
    saved = value; writes.add(value);
  }
}

Future<List<int>> staticPaint(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer.asUint8List().toList();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<void> mount(
  WidgetTester tester,
  Fixture f,
  Widget child, {
  double width = 400,
  double height = 600,
  double scale = 1,
}) async {
  await f.notifier.ensureLoaded();
  addTearDown(f.container.dispose);
  addTearDown(() async => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: f.container,
      child: MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> tap(WidgetTester tester, String key) async {
  // Legacy tests retain their advanced h/m/s business checks in the single
  // settings window; the new basic-first cases below use direct actual taps.
  if (key == 'pomodoro_remaining_end') {
    await tap(tester, 'pomodoro_configure');
    return;
  }
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty && key == 'pomodoro_reset') {
    await tap(tester, 'pomodoro_configure');
  } else if (finder.evaluate().isEmpty && key == 'countdown_remaining_end') {
    await tap(tester, 'countdown_more');
  }
  await tester.pump(const Duration(milliseconds: 300));
  await tester.ensureVisible(finder); await tester.pump();
  await tester.ensureVisible(finder); await tester.pump();
  await tester.tap(finder); await tester.pump();
  await tester.pump(const Duration(milliseconds: 300)); await tester.pump();
  if (key == 'pomodoro_configure' || key == 'pomodoro_remaining_edit') {
    await tester.ensureVisible(find.byKey(const Key('pomodoro_advanced')));
    await tester.tap(find.byKey(const Key('pomodoro_advanced')));
    await tester.pump();
  }
}

Future<void> reachTask(WidgetTester tester, String key) async {
  // The list's own Scrollable precedes any editor's internal text Scrollable.
  final scrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  final target = find.byKey(Key(key));
  await tester.scrollUntilVisible(
    target,
    100,
    scrollable: scrollable,
    maxScrolls: 100,
  );
  await tester.ensureVisible(target);
  await tester.pump();
}

Future<void> taskTap(WidgetTester tester, String key) async {
  await reachTask(tester, key);
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Fixture groupedFixture() => Fixture(
  storage: MemoryTimeStore()
    ..saved = TimeToolsState(
      revision: 5,
      tasks: [
        TimeTask(
          id: 'p1',
          text: 'first pending',
          createdAtUtc: DateTime.utc(2026, 9, 1),
        ),
        const TimeTask(id: 'd1', text: 'first completed', done: true),
        TimeTask(
          id: 'p2',
          text: 'second pending',
          dueAtUtc: DateTime.utc(2027),
        ),
        const TimeTask(id: 'd2', text: 'second completed', done: true),
      ],
    ),
);
Future<void> groupedMount(
  WidgetTester tester,
  Fixture f, {
  double width = 400,
  double height = 600,
  double scale = 1,
  Widget? child,
}) async {
  await f.notifier.ensureLoaded();
  addTearDown(f.container.dispose);
  addTearDown(() async => tester.pumpWidget(const SizedBox()));
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
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: child ?? const TasksWidget(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

class _ControlsBucket extends FeedBucketMinutesNotifier {
  @override
  int build() => 10;
}

/// Only new cases use this fully explicit memory fixture. Original Fixture
/// business tests remain intact, with no production/domain/store edits.
class _ExplicitTimerFixture implements Fixture {
  _ExplicitTimerFixture({MemoryTimeStore? storage})
      : store = storage ?? MemoryTimeStore() {
    container = ProviderContainer(overrides: [
      timeToolsStoreProvider.overrideWithValue(store),
      timeToolsClockProvider.overrideWithValue(() => now),
      timeToolsMonotonicProvider.overrideWithValue(() => elapsed),
      timeToolsIdProvider.overrideWithValue(() => 'explicit-timer-${++id}'),
      uiPreferencesBackendProvider.overrideWithValue(preferences),
      feedBucketMinutesProvider.overrideWith(_ControlsBucket.new),
      apiProvider.overrideWith((_) => throw StateError('forbidden API/private data')),
      dataRefreshVisibilityProvider.overrideWithValue(
        () => throw StateError('forbidden native visibility')),
    ]);
  }
  @override
  final MemoryTimeStore store;
  @override
  late final ProviderContainer container;
  @override
  DateTime now = DateTime.utc(2026, 10, 7, 12);
  @override
  int id = 0;
  Duration elapsed = Duration.zero;
  final preferences = MemoryPreferencesBackend();
  @override
  TimeToolsNotifier get notifier => container.read(timeToolsProvider.notifier);
  @override
  TimeToolsViewState get view => container.read(timeToolsProvider);
}

Future<GoRouter> mountTimerRoute(
  WidgetTester tester, Fixture f, Widget child, {
  double width = 400, double height = 600, double scale = 1,
  bool disposeFixture = true, bool reducedMotion = false,
}) async {
  await f.notifier.ensureLoaded();
  final router = GoRouter(initialLocation: '/dashboard', routes: [
    GoRoute(path: '/dashboard', builder: (_, _) => Scaffold(
      body: SizedBox(width: width, height: height, child: child)),
      routes: [createTimeSessionHistoryRoute()]),
  ]);
  addTearDown(router.dispose);
  if (disposeFixture) addTearDown(f.container.dispose);
  addTearDown(() async => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: f.container,
    child: MaterialApp.router(routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale), disableAnimations: reducedMotion),
        child: MaterialScope(
          policy: MaterialPolicy.resolve(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
            wallpaper: WallpaperLoadState.absent,
            signals: const MaterialSignals()),
          tokens: MaterialTokens.forWidth(width), child: child!,
        ),
      ),
    ),
  ));
  await tester.pump();
  return router;
}

void main() {
  _acceptanceUsabilityTests();
  testWidgets(
    'real pomodoro history distinguishes focus and rest with truthful unknown time',
    (tester) async {
      final now = DateTime.utc(2026, 10, 5);
      final f = Fixture(
        storage: MemoryTimeStore()
          ..saved = TimeToolsState(
            revision: 1,
            sessions: [
              TimeSession(
                id: 'focus-history',
                kind: TimeSessionKind.pomodoro,
                phase: PomodoroPhase.focus,
                startUtc: now,
                endUtc: now,
                status: TimeSessionStatus.completed,
              ),
              TimeSession(
                id: 'rest-history',
                kind: TimeSessionKind.pomodoro,
                phase: PomodoroPhase.rest,
                startUtc: now,
                endUtc: now,
                status: TimeSessionStatus.interrupted,
                elapsedKnown: false,
                knownMicroseconds: 3000000,
              ),
            ],
          ),
      );
      await mountTimerRoute(tester, f, const PomodoroWidget());
      await tap(tester, 'pomodoro_history');
      final focus = tester
          .widget<Text>(find.byKey(const Key('time_session_focus-history')))
          .data!;
      final rest = tester
          .widget<Text>(find.byKey(const Key('time_session_rest-history')))
          .data!;
      expect(focus, contains('专注 · 完成'));
      expect(focus, contains('结束：'));
      expect(focus, contains('有效：0.0 秒'));
      expect(rest, contains('休息 · 中断'));
      expect(rest, contains('未知（已知部分 3 秒）'));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'both task folds expose equal arrows and expanded semantics while preserving draft',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f);
      final semantics = tester.ensureSemantics();
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      for (final (group, initial) in [
        ('pending', true),
        ('completed', false),
      ]) {
        final key = 'tasks_${group}_heading';
        await reachTask(tester, key);
        final heading = find.byKey(Key(key));
        IconData arrow() => tester
            .widget<Icon>(
              find.descendant(of: heading, matching: find.byType(Icon)),
            )
            .icon!;
        bool expanded() => tester
            .widget<Semantics>(find.byKey(Key('tasks_${group}_semantics')))
            .properties
            .expanded!;
        expect(expanded(), initial);
        expect(
          tester.getSemantics(find.byKey(Key('tasks_${group}_group'))),
          containsSemantics(hasExpandedState: true, isExpanded: initial),
        );
        expect(arrow(), initial ? Icons.expand_less : Icons.expand_more);
        expect(tester.getSize(heading).height, greaterThanOrEqualTo(48));
        await taskTap(tester, key);
        expect(expanded(), !initial);
        expect(
          tester.getSemantics(find.byKey(Key('tasks_${group}_group'))),
          containsSemantics(hasExpandedState: true, isExpanded: !initial),
        );
        expect(arrow(), initial ? Icons.expand_more : Icons.expand_less);
        await taskTap(tester, key);
        expect(expanded(), initial);
        expect(arrow(), initial ? Icons.expand_less : Icons.expand_more);
      }
      await taskTap(tester, 'task_edit_p1');
      await tester.enterText(
        find.byKey(const Key('task_edit_input_p1')),
        'unchanged draft',
      );
      await taskTap(tester, 'tasks_pending_heading');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('task_edit_input_p1')))
            .controller!
            .text,
        'unchanged draft',
      );
      await taskTap(tester, 'tasks_pending_heading');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('task_edit_input_p1')))
            .controller!
            .text,
        'unchanged draft',
      );
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
  for (final (h, m, s, want) in [
    ('0', '0', '0', null),
    ('0', '0', '59', null),
    ('0', '1', '0', 60),
    ('0', '1', '1', 61),
    ('3', '0', '0', 10800),
    ('3', '0', '1', null),
    ('-1', '1', '0', null),
    ('0', '1.2', '0', null),
    ('0', '60', '0', null),
  ]) {
    testWidgets('real hms Enter boundaries $h:$m:$s -> $want', (tester) async {
      final f = Fixture();
      await mount(
        tester,
        f,
        const PomodoroWidget(),
        width: 180,
        height: 160,
        scale: 2,
      );
      final outer = tester.getRect(find.byType(PomodoroWidget));
      for (final key in [
        'pomodoro_remaining_edit',
        'pomodoro_start_pause',
        'pomodoro_configure',
        'pomodoro_history',
      ]) {
        final rect = tester.getRect(find.byKey(Key(key)));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(outer.contains(rect.topLeft), isTrue);
        expect(outer.contains(rect.bottomRight), isTrue);
        expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
      }
      final before = f.view.data.toJson();
      await tap(tester, 'pomodoro_remaining_edit');
      await tester.enterText(find.byKey(const Key('pomodoro_focus_hours')), h);
      await tester.enterText(
        find.byKey(const Key('pomodoro_focus_minutes')),
        m,
      );
      await tester.enterText(
        find.byKey(const Key('pomodoro_focus_seconds')),
        s,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      if (want == null) {
        expect(f.view.data.toJson(), before);
        expect(find.text('请输入合法时间，范围为60至10800秒'), findsOneWidget);
        await tap(tester, 'pomodoro_cancel_config');
      } else {
        await f.notifier.flush();
        expect(f.view.data.pomodoro.focusSeconds, want);
        expect(find.byKey(const Key('pomodoro_focus_seconds')), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'end time strict 61 canonical seconds, cancel zero mutation, each real history belongs to its kind',
    (tester) async {
      final f = Fixture();
      await mountTimerRoute(tester, f, const PomodoroWidget());
      final before = f.view.data.toJson();
      await tap(tester, 'pomodoro_remaining_end');
      final targetText = f.now
          .add(const Duration(seconds: 61))
          .toLocal()
          .toIso8601String()
          .substring(0, 19)
          .replaceFirst('T', ' ');
      expect(
        parseLocalCountdown(targetText)!.toUtc(),
        f.now.add(const Duration(seconds: 61)),
      );
      await tester.enterText(
        find.byKey(const Key('pomodoro_end_target')),
        targetText,
      );
      await tap(tester, 'pomodoro_cancel_config');
      expect(f.view.data.toJson(), before);
      await tap(tester, 'pomodoro_remaining_end');
      await tap(tester, 'pomodoro_apply_end');
      expect(f.view.data.pomodoro.focusSeconds, 61);
      await tap(tester, 'pomodoro_start_pause');
      await f.notifier.flush();
      final pID = f.view.data.sessions.single.id;
      f.notifier.setCountdown('独立日期', f.now.add(const Duration(days: 1)));
      await f.notifier.flush();
      final cID = f.view.data.sessions.last.id;
      await tap(tester, 'pomodoro_history');
      expect(find.byKey(Key('time_session_$pID')), findsOneWidget);
      expect(find.byKey(Key('time_session_$cID')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await mountTimerRoute(tester, f, const CountdownWidget(),
        disposeFixture: false);
      await tester.pump();
      await tap(tester, 'countdown_history');
      expect(find.byKey(Key('time_session_$pID')), findsNothing);
      expect(find.byKey(Key('time_session_$cID')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [280.0, 360.0, 720.0]) {
    testWidgets(
      'pending fold and due two step cancellation never defaults midnight width$width',
      (tester) async {
        final f = groupedFixture();
        await groupedMount(tester, f, width: width, height: 600, scale: 2);
        final before = f.view.data.toJson(), writes = f.store.writes.length;
        await taskTap(tester, 'tasks_pending_heading');
        expect(find.byKey(const Key('task_toggle_p1')), findsNothing);
        expect(f.view.data.toJson(), before);
        expect(f.store.writes.length, writes);
        await taskTap(tester, 'tasks_pending_heading');
        await taskTap(tester, 'task_edit_p1');
        await tester.enterText(
          find.byKey(const Key('task_edit_input_p1')),
          'keep draft',
        );
        await taskTap(tester, 'task_due_p1');
        expect(find.byType(MaterialTransientPanel), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('task_due_p1_date')),
          '2026-10-09',
        );
        await tap(tester, 'task_due_p1_next');
        await tap(tester, 'task_due_p1_confirm');
        expect(find.text('请输入有效日期和明确的时、分，未修改预计时间'), findsOneWidget);
        expect(f.view.data.toJson(), before);
        expect(f.store.writes.length, writes);
        await tap(tester, 'task_due_p1_cancel');
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('task_edit_input_p1')))
              .controller!
              .text,
          'keep draft',
        );
        await taskTap(tester, 'task_due_p1');
        await tap(tester, 'task_due_p1_next');
        await tester.enterText(
          find.byKey(const Key('task_due_p1_hours')),
          '14',
        );
        await tester.enterText(
          find.byKey(const Key('task_due_p1_minutes')),
          '35',
        );
        await tap(tester, 'task_due_p1_confirm');
        expect(f.view.data.toJson(), before);
        await taskTap(tester, 'task_save_p1');
        await f.notifier.flush();
        final task = f.view.data.tasks.first;
        expect(task.dueAtUtc, DateTime(2026, 10, 3, 14, 35).toUtc());
        expect(task.createdAtUtc, DateTime.utc(2026, 9, 1));
        expect(task.text, 'keep draft');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final size in [const Size(180, 160), const Size(232, 172)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          'glass timer surface and captured popup retain actions $brightness $size scale$scale',
          (tester) async {
            final f = Fixture();
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
            await mount(
              tester,
              f,
              MaterialScope(
                policy: policy,
                tokens: MaterialTokens.forWidth(size.width),
                child: const PomodoroWidget(),
              ),
              width: size.width,
              height: size.height,
              scale: scale,
            );
            final button = tester.widget<FilledButton>(
              find.byKey(const Key('pomodoro_start_pause')),
            );
            expect(
              button.style!.backgroundColor!.resolve({}),
              Color.alphaBlend(scheme.onSurface.withValues(alpha: .12),
                policy.contentSurface),
            );
            expect(
              button.style!.backgroundColor!.resolve({}),
              isNot(scheme.primary),
            );
            await tap(tester, 'pomodoro_configure');
            final secondary = tester.widget<FilledButton>(
              find.byKey(const Key('pomodoro_reset')),
            );
            expect(button.style!.foregroundColor!.resolve({}), scheme.primary);
            expect(
              secondary.style!.foregroundColor!.resolve({}),
              scheme.onSurface,
            );
            expect(button.style!.backgroundColor!.resolve({})!.a, lessThan(1));
            expect(find.byType(BackdropFilter), findsNothing);
            for (final key in [
              'pomodoro_reset',
              'pomodoro_save_config',
            ]) {
              await tester.ensureVisible(find.byKey(Key(key)));
              await tester.pump();
              final rect = tester.getRect(find.byKey(Key(key)));
              final panel = tester.getRect(find.byType(MaterialTransientPanel));
              expect(rect.width, greaterThanOrEqualTo(48));
              expect(rect.height, greaterThanOrEqualTo(48));
              expect(rect.left, greaterThanOrEqualTo(panel.left));
              expect(rect.right, lessThanOrEqualTo(panel.right));
              expect(find.descendant(of: find.byKey(Key(key)),
                matching: find.byType(Text)), findsOneWidget);
              expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
            }
            await tap(tester, 'pomodoro_cancel_config');
            await tap(tester, 'pomodoro_start_pause');
            expect(f.view.data.pomodoro.running, isTrue);
            await tap(tester, 'pomodoro_start_pause');
            expect(f.view.data.pomodoro.running, isFalse);
            final before = f.view.data.toJson();
            await tap(tester, 'pomodoro_configure');
            expect(find.byType(MaterialTransientPanel), findsOneWidget);
            expect(find.byType(MaterialCard), findsOneWidget);
            final field = find.byKey(const Key('pomodoro_focus_minutes'));
            expect(
              MaterialScope.of(tester.element(field)).policy,
              same(policy),
            );
            expect(
              ProviderScope.containerOf(tester.element(field)),
              same(f.container),
            );
            expect(
              tester.widget<Card>(find.byType(Card)).color,
              policy.contentSurface,
            );
            await tester.enterText(field, '3');
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(f.view.data.toJson(), before);
            await tap(tester, 'pomodoro_configure');
            expect(tester.widget<TextField>(field).controller!.text, '3');
            await tap(tester, 'pomodoro_cancel_config');
            expect(f.view.data.toJson(), before);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  testWidgets(
    'completed heading expands and collapses by keyboard without persistence',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f);
      await reachTask(tester, 'tasks_completed_heading');
      Focus.of(tester.element(find.text('已完成 × 2'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await reachTask(tester, 'task_toggle_d1');
      expect(
        find.byKey(const Key('task_toggle_d1')).hitTestable(),
        findsOneWidget,
      );
      await reachTask(tester, 'tasks_completed_heading');
      Focus.of(tester.element(find.text('已完成 × 2'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byKey(const Key('task_toggle_d1')), findsNothing);
      expect(f.store.writes, isEmpty);
      expect(f.view.data.revision, 5);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'groups default collapsed stable order counts and toggle return without date changes',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f);
      final before = f.view.data.tasks.map((t) => t.toJson()).toList();
      expect(find.text('待完成 × 2'), findsOneWidget);
      expect(find.text('已完成 × 2'), findsOneWidget);
      expect(find.byKey(const Key('task_toggle_d1')), findsNothing);
      final writes = f.store.writes.length;
      await taskTap(tester, 'tasks_completed_heading');
      expect(f.store.writes.length, writes);
      await reachTask(tester, 'task_toggle_d2');
      expect(
        tester.getTopLeft(find.byKey(const Key('task_toggle_d1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('task_toggle_d2'))).dy),
      );
      await taskTap(tester, 'task_toggle_p1');
      await f.notifier.flush();
      expect(f.view.data.tasks.map((t) => t.id), ['p1', 'd1', 'p2', 'd2']);
      await taskTap(tester, 'task_toggle_p1');
      await f.notifier.flush();
      expect(f.view.data.tasks.map((t) => t.toJson()), before);
      expect(find.text('2 / 4 已完成'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'editing ID survives group reorder collapse and offscreen keepalive',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f, height: 240);
      await taskTap(tester, 'task_edit_p1');
      await tester.enterText(
        find.byKey(const Key('task_edit_input_p1')),
        'unsaved by ID',
      );
      expect(f.notifier.toggleTask('p1'), isTrue);
      await tester.pump();
      await reachTask(tester, 'task_edit_input_p1');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('task_edit_input_p1')))
            .controller!
            .text,
        'unsaved by ID',
      );
      await taskTap(tester, 'tasks_completed_heading');
      await taskTap(tester, 'tasks_completed_heading');
      await reachTask(tester, 'task_edit_input_p1');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('task_edit_input_p1')))
            .controller!
            .text,
        'unsaved by ID',
      );
      await taskTap(tester, 'task_save_p1');
      expect(f.view.data.tasks.first.text, 'unsaved by ID');
      expect(f.view.data.tasks.first.createdAtUtc, DateTime.utc(2026, 9, 1));
      expect(f.view.data.tasks.first.done, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final id in ['p1', 'd1']) {
    testWidgets(
      'delete $id cancel Escape captured ID and repeated confirm are safe',
      (tester) async {
        final f = groupedFixture();
        await groupedMount(tester, f);
        if (id == 'd1') await taskTap(tester, 'tasks_completed_heading');
        await taskTap(tester, 'task_delete_' + id);
        expect(find.text('任务 ID：' + id), findsOneWidget);
        final before = f.view.data.toJson();
        await tap(tester, 'task_delete_cancel_' + id);
        expect(f.view.data.toJson(), before);
        await taskTap(tester, 'task_delete_' + id);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(f.view.data.toJson(), before);
        await taskTap(tester, 'task_delete_' + id);
        // Move groups while confirmation is open: deletion remains bound to the ID.
        f.notifier.toggleTask(id);
        await tester.pump();
        final revision = f.view.data.revision;
        final callback = tester
            .widget<FilledButton>(find.byKey(Key('task_delete_confirm_' + id)))
            .onPressed!;
        callback();
        callback();
        await tester.pumpAndSettle();
        await f.notifier.flush();
        expect(f.view.data.revision, revision + 1);
        expect(f.view.data.tasks.map((t) => t.id), isNot(contains(id)));
        expect(
          f.view.data.tasks.map((t) => t.id),
          ['p1', 'd1', 'p2', 'd2'].where((taskId) => taskId != id),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'confirmation rechecks absent ID and blocked state before deleting',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f);
      await taskTap(tester, 'task_delete_p1');
      final callback = tester
          .widget<FilledButton>(find.byKey(const Key('task_delete_confirm_p1')))
          .onPressed!;
      f.notifier.deleteTask('p1');
      final revision = f.view.data.revision;
      callback();
      expect(f.view.data.revision, revision);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('task_delete_confirm_p1')),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'task_delete_cancel_p1');
      await taskTap(tester, 'task_delete_p2');
      final blockedCallback = tester
          .widget<FilledButton>(find.byKey(const Key('task_delete_confirm_p2')))
          .onPressed!;
      await f.notifier.flush();
      f.store.failRead = true;
      await f.notifier.reload();
      final before = f.view.data.toJson();
      blockedCallback();
      await tester.pump();
      expect(f.view.data.toJson(), before);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('task_delete_confirm_p2')),
            )
            .onPressed,
        isNull,
      );
      await tap(tester, 'task_delete_cancel_p2');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('confirm after task owner unmount cannot write', (tester) async {
    final f = groupedFixture();
    var shown = true;
    late StateSetter update;
    await groupedMount(
      tester,
      f,
      child: StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return shown ? const TasksWidget() : const SizedBox();
        },
      ),
    );
    await taskTap(tester, 'task_delete_p1');
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('task_delete_confirm_p1')))
        .onPressed!;
    final before = f.view.data.toJson(), writes = f.store.writes.length;
    update(() => shown = false);
    await tester.pump();
    confirm();
    await tester.pump();
    expect(f.view.data.toJson(), before);
    expect(f.store.writes.length, writes);
    await tap(tester, 'task_delete_cancel_p1');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'confirmed delete failure keeps intent and UI retry does not replay action',
    (tester) async {
      final f = groupedFixture();
      await groupedMount(tester, f);
      f.store.failWrite = true;
      await taskTap(tester, 'task_delete_p1');
      await tap(tester, 'task_delete_confirm_p1');
      await f.notifier.flush();
      await tester.pump();
      final intent = f.view.data.toJson();
      expect(f.view.dirty, isTrue);
      expect(f.view.error, isNotNull);
      expect(f.view.data.tasks.map((t) => t.id), isNot(contains('p1')));
      f.store.failWrite = false;
      await taskTap(tester, 'time_tools_retry');
      await f.notifier.flush();
      expect(f.view.data.toJson(), intent);
      expect(f.store.saved!.toJson(), intent);
      expect(f.view.dirty, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [
    const Size(180, 160),
    const Size(232, 172),
    const Size(476, 356),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'group small tool actual targets reachable $size scale$scale',
        (tester) async {
          final f = groupedFixture();
          await groupedMount(
            tester,
            f,
            width: size.width,
            height: size.height,
            scale: scale,
          );
          expect(find.byType(ListView), findsOneWidget);
          expect(find.byType(FittedBox), findsNothing);
          final outer = tester.getRect(find.byType(TasksWidget));
          for (final key in [
            'task_toggle_p1',
            'task_edit_p1',
            'task_delete_p1',
            'tasks_completed_heading',
          ]) {
            await reachTask(tester, key);
            final rect = tester.getRect(find.byKey(Key(key)));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.left, greaterThanOrEqualTo(outer.left));
            expect(rect.right, lessThanOrEqualTo(outer.right));
            expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
          }
          await taskTap(tester, 'tasks_completed_heading');
          for (final key in [
            'task_toggle_d1',
            'task_edit_d1',
            'task_delete_d1',
          ]) {
            await reachTask(tester, key);
            final rect = tester.getRect(find.byKey(Key(key)));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(rect.left, greaterThanOrEqualTo(outer.left));
            expect(rect.right, lessThanOrEqualTo(outer.right));
            expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
          }
          await taskTap(tester, 'task_delete_d1');
          for (final key in [
            'task_delete_cancel_d1',
            'task_delete_confirm_d1',
          ]) {
            final rect = tester.getRect(find.byKey(Key(key)));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
            expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
          }
          await tap(tester, 'task_delete_cancel_d1');
          expect(tester.takeException(), isNull);
          expect(f.store.writes, isEmpty);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'timer centered primary action is keyboard reachable without scaled target',
    (tester) async {
      final f = Fixture();
      await mount(
        tester,
        f,
        const PomodoroWidget(),
        width: 180,
        height: 160,
        scale: 2,
      );
      var primaryFocused = false;
      for (var i = 0; i < 8 && !primaryFocused; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        primaryFocused = Focus.of(tester.element(find.text('开始'))).hasFocus;
      }
      expect(primaryFocused, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(f.view.data.pomodoro.running, isTrue);
      expect(
        tester.getSize(find.byKey(const Key('pomodoro_start_pause'))),
        predicate<Size>((size) => size.width >= 48 && size.width <= 180 && size.height >= 48),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'legacy task displays unrecorded creation rather than fabricated now',
    (tester) async {
      final f = Fixture(
        storage: MemoryTimeStore()
          ..saved = TimeToolsState(
            revision: 1,
            tasks: const [TimeTask(id: 'old', text: '历史任务')],
          ),
      );
      await mount(tester, f, const TasksWidget());
      expect(find.text('添加时间：未记录'), findsOneWidget);
      expect(f.view.data.tasks.single.createdAtUtc, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  Rect paintedBounds(WidgetTester tester, Finder finder) {
    final box = tester.renderObject<RenderBox>(finder);
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  for (final size in [
    const Size(180, 160),
    const Size(232, 172),
    const Size(476, 172),
    const Size(476, 356),
  ]) {
    for (final scale in [1.0, 2.0]) {
      for (final pomodoro in [true, false]) {
        testWidgets(
          'timer glyph and unified 48dp actions centered in $size scale$scale pomodoro=$pomodoro',
          (tester) async {
            final f = Fixture();
            await f.notifier.ensureLoaded();
            if (!pomodoro)
              f.notifier.setCountdown(
                '合成目标',
                f.now.add(const Duration(days: 1)),
              );
            await mount(
              tester,
              f,
              pomodoro ? const PomodoroWidget() : const CountdownWidget(),
              width: size.width,
              height: size.height,
              scale: scale,
            );
            final root = find.byType(
              pomodoro ? PomodoroWidget : CountdownWidget,
            );
            final outer = tester.getRect(root);
            final clock = paintedBounds(
              tester,
              find.byKey(
                Key(pomodoro ? 'pomodoro_remaining' : 'countdown_remaining'),
              ),
            );
            expect(outer.contains(clock.topLeft), isTrue);
            expect(outer.contains(clock.bottomRight), isTrue);
            expect((clock.center.dx - outer.center.dx).abs(), lessThan(1));
            final keys = pomodoro
                ? [
                    'pomodoro_start_pause',
                    'pomodoro_configure',
                    'pomodoro_history',
                  ]
                : ['countdown_edit'];
            final primary = tester.getRect(find.byKey(Key(keys.first)));
            expect((primary.center.dx - outer.center.dx).abs(), lessThan(1));
            for (final key in keys) {
              final button = find.byKey(Key(key));
              if (pomodoro) {
                expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
                expect(tester.getSize(button).width, lessThanOrEqualTo(outer.width));
                expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
                expect(find.descendant(of: button, matching: find.byType(Text)),
                  findsOneWidget);
              } else {
                expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
                expect(tester.getSize(button).height, 48);
                expect(find.byIcon(Icons.edit_calendar), findsNothing);
              }
              final rect = tester.getRect(button);
              expect(outer.contains(rect.topLeft), isTrue);
              expect(outer.contains(rect.bottomRight), isTrue);
              expect(tester.widget(button), isA<FilledButton>());
            }
            expect(find.byType(Scrollable), findsNothing);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  for (final span in [
    WorkspaceSize.oneByOne,
    WorkspaceSize.twoByOne,
    WorkspaceSize.twoByTwo,
  ]) {
    testWidgets(
      'real host finite timer $span retains input through hide and reveal',
      (tester) async {
        final f = Fixture();
        await f.notifier.ensureLoaded();
        addTearDown(f.container.dispose);
        var shown = true;
        late StateSetter update;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: f.container,
            child: MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: SizedBox(
                    width: 976,
                    child: SingleChildScrollView(
                      child: StatefulBuilder(
                        builder: (context, setState) {
                          update = setState;
                          return WorkspaceHost(
                            document: WorkspaceDocument(
                              groups: shown
                                  ? [
                                      ['pomodoro'],
                                    ]
                                  : [],
                              sizes: {'pomodoro': span},
                            ),
                            registry: {
                              'pomodoro': WorkspaceDescriptor(
                                id: 'pomodoro',
                                label: '番茄钟',
                                contentBuilder: (_, _) => const MaterialCard(
                                  margin: EdgeInsets.zero,
                                  child: PomodoroWidget(),
                                ),
                                thumbnailBuilder: (_) => const SizedBox(),
                              ),
                            },
                            onAction: (_) {},
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tap(tester, 'pomodoro_configure');
        await tester.enterText(
          find.byKey(const Key('pomodoro_focus_minutes')),
          '37',
        );
        await tap(tester, 'pomodoro_cancel_config');
        update(() => shown = false);
        await tester.pump();
        update(() => shown = true);
        await tester.pump();
        await tap(tester, 'pomodoro_configure');
        expect(
          tester
              .widget<TextField>(
                find.byKey(const Key('pomodoro_focus_minutes')),
              )
              .controller!
              .text,
          '37',
        );
        await tap(tester, 'pomodoro_cancel_config');
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'task empty action due validation clear and old unknown created time',
    (tester) async {
      final f = Fixture();
      await mount(tester, f, const TasksWidget());
      expect(f.view.data.tasks, isEmpty);
      expect(find.byType(TextField), findsNothing);
      await tap(tester, 'time_task_empty_add');
      await tester.enterText(find.byKey(const Key('time_task_input')), '计划任务');
      await tap(tester, 'time_task_due');
      await tester.enterText(
        find.byKey(const Key('time_task_due_date')),
        '2026-02-31',
      );
      await tap(tester, 'time_task_due_next');
      expect(f.view.data.tasks, isEmpty);
      expect(find.text('请输入有效日期和明确的时、分，未修改预计时间'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('time_task_due_date')),
        '2026-10-01',
      );
      await tap(tester, 'time_task_due_next');
      await tester.enterText(
        find.byKey(const Key('time_task_due_hours')),
        '12',
      );
      await tester.enterText(
        find.byKey(const Key('time_task_due_minutes')),
        '0',
      );
      await tap(tester, 'time_task_due_confirm');
      await tap(tester, 'time_task_add');
      final created = f.view.data.tasks.single.createdAtUtc;
      expect(created, f.now);
      expect(
        f.view.data.tasks.single.dueAtUtc,
        parseLocalCountdown('2026-10-01 12:00')!.toUtc(),
      );
      expect(find.textContaining('预计已到期'), findsOneWidget);
      await tap(tester, 'task_edit_fixture-1');
      await tap(tester, 'task_due_fixture-1_clear');
      await tap(tester, 'task_save_fixture-1');
      expect(f.view.data.tasks.single.dueAtUtc, isNull);
      expect(f.view.data.tasks.single.createdAtUtc, created);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'tasks progressive form preserves unsubmitted input across cancel and resize',
    (tester) async {
      final f = Fixture();
      await mount(
        tester,
        f,
        const TasksWidget(),
        width: 280,
        height: 320,
        scale: 2,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('还没有任务'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('time_task_open_add'))),
        const Size(48, 48),
      );
      await tap(tester, 'time_task_open_add');
      await tester.enterText(
        find.byKey(const Key('time_task_input')),
        '未提交合成内容',
      );
      tester.view.physicalSize = const Size(240, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('time_task_input')))
            .controller!
            .text,
        '未提交合成内容',
      );
      await tap(tester, 'time_task_cancel_add');
      expect(find.byType(TextField), findsNothing);
      expect(f.view.data.tasks, isEmpty);
      await tap(tester, 'time_task_open_add');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('time_task_input')))
            .controller!
            .text,
        '未提交合成内容',
      );
      await tap(tester, 'time_task_add');
      expect(find.byType(TextField), findsNothing);
      expect(f.view.data.tasks.single.text, '未提交合成内容');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('pomodoro primary action and 48dp secondary disclosure', (
    tester,
  ) async {
    final f = Fixture();
    await mount(
      tester,
      f,
      const PomodoroWidget(),
      width: 180,
      height: 160,
      scale: 2,
    );
    expect(find.byType(TextField), findsNothing);
    expect(
      tester.widget(find.byKey(const Key('pomodoro_start_pause'))),
      isA<FilledButton>(),
    );
    expect(find.text('开始'), findsOneWidget);
    expect(find.byKey(const Key('pomodoro_configure')).hitTestable(), findsOneWidget);
    await tap(tester, 'pomodoro_configure');
    for (final key in ['pomodoro_reset', 'pomodoro_save_config']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final size in [
    const Size(180, 160),
    const Size(360, 360),
    const Size(560, 700),
  ]) {
    for (final widget in [
      const PomodoroWidget(),
      const TasksWidget(),
      const CountdownWidget(),
    ]) {
      testWidgets(
        'bounded scaled time tool has no overflow at ' +
            size.toString() +
            ' ' +
            widget.runtimeType.toString(),
        (tester) async {
          final f = Fixture();
          await mount(
            tester,
            f,
            widget,
            width: size.width,
            height: size.height,
            scale: 2,
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(Card), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets('pomodoro actions and inline invalid duration then configure', (
    tester,
  ) async {
    final f = Fixture();
    await mount(tester, f, const PomodoroWidget());
    await tap(tester, 'pomodoro_configure');
    await tester.enterText(
      find.byKey(const Key('pomodoro_focus_minutes')),
      '0',
    );
    await tap(tester, 'pomodoro_save_config');
    expect(find.text('请输入合法时间，范围为60至10800秒'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('pomodoro_focus_minutes')),
      '1',
    );
    await tester.enterText(find.byKey(const Key('pomodoro_rest_minutes')), '1');
    await tap(tester, 'pomodoro_save_config');
    await tap(tester, 'pomodoro_start_pause');
    expect(f.view.data.pomodoro.running, isTrue);
    f.now = f.now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:40'), findsOneWidget);
    await tap(tester, 'pomodoro_start_pause');
    expect(f.view.data.pomodoro.deadlineUtc, isNull);
    await tap(tester, 'pomodoro_reset');
    expect(f.view.data.pomodoro.remainingSeconds, 60);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'hidden ticker stops display updates but deadline survives remount',
    (tester) async {
      final f = Fixture();
      await f.notifier.ensureLoaded();
      f.notifier.startPomodoro();
      await f.notifier.flush();
      var visible = true;
      late StateSetter update;
      await mount(
        tester,
        f,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(enabled: visible, child: const PomodoroWidget());
          },
        ),
      );
      final writes = f.store.writes.length;
      f.now = f.now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('24:40'), findsOneWidget);
      update(() => visible = false);
      await tester.pump();
      f.now = f.now.add(const Duration(seconds: 20));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('24:40'), findsOneWidget);
      expect(f.store.writes.length, writes);
      update(() => visible = true);
      await tester.pump();
      await tester.pump();
      expect(find.text('24:20'), findsOneWidget);
      expect(f.store.writes.length, writes);
      await tester.pumpWidget(const SizedBox());
      // Reuse the non-autoDispose business scope, not a widget-owned timer.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: f.container,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 360, height: 600, child: PomodoroWidget()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('24:20'), findsOneWidget);
      f.now = f.now.add(const Duration(hours: 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(f.view.data.pomodoro.completed, isTrue);
      expect(f.view.data.pomodoro.running, isFalse);
      expect(f.view.data.pomodoro.phase, PomodoroPhase.focus);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('tasks add toggle inline edit cancel and retain original order', (
    tester,
  ) async {
    final f = Fixture();
    await mount(tester, f, const TasksWidget());
    for (final text in ['第一件', '第二件', '第三件']) {
      await tap(tester, 'time_task_open_add');
      await tester.enterText(find.byKey(const Key('time_task_input')), text);
      await tap(tester, 'time_task_add');
    }
    await tap(tester, 'task_toggle_fixture-2');
    await tap(tester, 'task_edit_fixture-1');
    await tester.enterText(
      find.byKey(const Key('task_edit_input_fixture-1')),
      '未保存修改',
    );
    await tap(tester, 'task_cancel_fixture-1');
    expect(f.view.data.tasks.first.text, '第一件');
    await tap(tester, 'task_edit_fixture-1');
    await tester.enterText(
      find.byKey(const Key('task_edit_input_fixture-1')),
      '明确保存修改',
    );
    await tap(tester, 'task_save_fixture-1');
    expect(f.view.data.tasks.map((t) => t.id), [
      'fixture-1',
      'fixture-2',
      'fixture-3',
    ]);
    expect(f.view.data.tasks.first.text, '明确保存修改');
    expect(f.view.data.tasks[1].done, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'long lazy task list scrolls within bounded tool and text scale',
    (tester) async {
      final storage = MemoryTimeStore()
        ..saved = TimeToolsState(
          revision: 1,
          tasks: [
            for (var i = 0; i < 40; i++)
              TimeTask(
                id: 'long-' + i.toString(),
                text: '合成很长中文任务，保留顺序并允许局部滚动，第' + i.toString() + '项',
              ),
          ],
        );
      final f = Fixture(storage: storage);
      await mount(
        tester,
        f,
        const TasksWidget(),
        width: 240,
        height: 420,
        scale: 2,
      );
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byKey(const Key('task_toggle_long-39')), findsNothing);
      // The single lazy list includes short headings and variable-height rows.
      await tester.ensureVisible(find.byType(ListView));
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -18000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.byKey(const Key('task_toggle_long-39')),
        400,
        scrollable: find.byType(Scrollable),
        maxScrolls: 80,
      );
      expect(find.byKey(const Key('task_toggle_long-39')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('save failure exposes retry without losing input result', (
    tester,
  ) async {
    final f = Fixture();
    await mount(tester, f, const TasksWidget());
    f.store.failWrite = true;
    await tap(tester, 'time_task_open_add');
    await tester.enterText(find.byKey(const Key('time_task_input')), '合成任务');
    await tap(tester, 'time_task_add');
    await f.notifier.flush();
    await tester.pump();
    expect(f.view.data.tasks.single.text, '合成任务');
    expect(find.byKey(const Key('time_tools_error')), findsOneWidget);
    f.store.failWrite = false;
    await tap(tester, 'time_tools_retry');
    await f.notifier.flush();
    await tester.pump();
    expect(f.view.dirty, isFalse);
    expect(f.store.saved!.tasks, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'countdown validates local input and retains target through editing cancel',
    (tester) async {
      final f = Fixture();
      await mount(tester, f, const CountdownWidget());
      await tap(tester, 'countdown_edit');
      await tester.enterText(find.byKey(const Key('countdown_title')), '合成目标');
      await tester.enterText(
        find.byKey(const Key('countdown_target')),
        '2026-02-31 12:00',
      );
      await tap(tester, 'countdown_save');
      expect(f.view.data.countdown, isNull);
      expect(find.text('请输入标题及有效的本地日期时间'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('countdown_target')),
        '2026-10-04 12:00',
      );
      await tap(tester, 'countdown_save');
      final target = parseLocalCountdown('2026-10-04 12:00')!.toUtc();
      expect(f.view.data.countdown!.targetUtc, target);
      await tap(tester, 'countdown_edit');
      await tester.enterText(find.byKey(const Key('countdown_title')), '取消的修改');
      await tap(tester, 'countdown_cancel');
      expect(f.view.data.countdown!.title, '合成目标');
      f.now = target.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('已到期'), findsOneWidget);
      expect(f.view.data.countdown!.targetUtc, target);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('visible primary labels and real Enter Space keep business phase transitions',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await f.notifier.ensureLoaded();
      f.notifier.configurePomodoroSeconds(60, 60);
      await f.notifier.flush();
      await mount(tester, f, const PomodoroWidget(),
        width: 180, height: 160, scale: 2);
      final primary = find.byKey(const Key('pomodoro_start_pause'));
      final outer = tester.getRect(find.byType(PomodoroWidget));
      void target() {
        final rect = tester.getRect(primary);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(rect.width, lessThanOrEqualTo(outer.width));
        expect((rect.center.dx - outer.center.dx).abs(), lessThan(1));
        expect(outer.contains(rect.topLeft), isTrue);
        expect(outer.contains(rect.bottomRight - const Offset(.01, .01)), isTrue);
      }
      expect(find.text('开始'), findsOneWidget); target();
      Focus.of(tester.element(find.text('开始'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(); await f.notifier.flush();
      expect(f.view.data.pomodoro.running, isTrue);
      expect(find.text('暂停'), findsOneWidget); target();
      Focus.of(tester.element(find.text('暂停'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(); await f.notifier.flush();
      expect(f.view.data.pomodoro.running, isFalse);
      expect(find.text('继续'), findsOneWidget); target();
      await tap(tester, 'pomodoro_start_pause');
      f.now = f.now.add(const Duration(seconds: 61));
      f.elapsed += const Duration(seconds: 61);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(); await f.notifier.flush();
      expect(f.view.data.pomodoro.completed, isTrue);
      expect(find.text('下一阶段'), findsOneWidget); target();
      await tap(tester, 'pomodoro_start_pause');
      expect(f.view.data.pomodoro.phase, PomodoroPhase.rest);
      expect(f.view.data.pomodoro.running, isTrue);
      expect(f.preferences.commits, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

  testWidgets('countdown date/time child cancellations preserve draft selection and long seconds target commits once',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await mount(tester, f, const CountdownWidget());
      expect(find.text('设置目标'), findsOneWidget);
      expect(find.byKey(const Key('pomodoro_start_pause')), findsNothing);
      expect(find.byKey(const Key('countdown_start_pause')), findsNothing);
      await tap(tester, 'countdown_set_target');
      await tester.enterText(find.byKey(const Key('countdown_title')), '公开合成目标');
      final target = f.now.add(const Duration(days: 10, seconds: 61));
      final text = target.toLocal().toIso8601String()
          .substring(0, 19).replaceFirst('T', ' ');
      await tester.enterText(find.byKey(const Key('countdown_target')), text);
      final controller = tester.widget<TextField>(
        find.byKey(const Key('countdown_target'))).controller!;
      controller.selection = const TextSelection(baseOffset: 2, extentOffset: 5);
      final draft = controller.value;
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      for (final date in [true, false]) {
        await tap(tester, date ? 'countdown_date_picker' : 'countdown_time_picker');
        final picker = date ? find.byType(DatePickerDialog) : find.byType(TimePickerDialog);
        expect(picker, findsOneWidget);
        final cancel = MaterialLocalizations.of(tester.element(picker)).cancelButtonLabel;
        await tester.tap(find.text(cancel).last);
        await tester.pumpAndSettle();
        expect(controller.value, draft);
        expect(f.view.data.toJson(), before);
        expect(f.store.writes.length, writes);
      }
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('countdown_save'))).onPressed!;
      confirm(); confirm();
      await tester.pumpAndSettle(); await f.notifier.flush();
      expect(f.view.data.countdown!.targetUtc, target);
      expect(f.view.data.revision, (before['revision'] as int) + 1);
      expect(f.store.writes.length, writes + 1);
      expect(f.view.data.sessions, hasLength(1));
      expect(find.text('修改目标'), findsOneWidget);
      expect(f.preferences.commits, 0);
      await tester.pumpWidget(const SizedBox());
    });

  testWidgets('timer draft barrier Escape latest blocked canEdit and stale owner confirm never commit',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await mount(tester, f, const CountdownWidget());
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      await tap(tester, 'countdown_edit');
      await tester.enterText(find.byKey(const Key('countdown_title')), '保留草稿');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      await tap(tester, 'countdown_edit');
      expect(tester.widget<TextField>(find.byKey(const Key('countdown_title')))
        .controller!.text, '保留草稿');
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      await tap(tester, 'countdown_edit');
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('countdown_save'))).onPressed!;
      f.store.result = const TimeToolsLoad(blocked: true, message: '合成只读');
      await f.notifier.reload(); await tester.pump();
      confirm();
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      expect(find.text('合成只读'), findsOneWidget);
      await tap(tester, 'countdown_cancel');
      await tester.pumpWidget(const SizedBox());
      confirm(); // disposed owner check occurs before touching controllers/ref.
      expect(f.store.writes.length, writes);
      expect(f.preferences.commits, 0);
      expect(tester.takeException(), isNull);
    });

  testWidgets('actual kind history push retains controls owner and uses effective top match not address bar',
    (tester) async {
      for (final pomodoro in [true, false]) {
        final f = _ExplicitTimerFixture();
        await f.notifier.ensureLoaded();
        if (pomodoro) {
          f.notifier.startPomodoro();
        } else {
          f.notifier.setCountdown('合成目标', f.now.add(const Duration(days: 1)));
        }
        await f.notifier.flush();
        final router = await mountTimerRoute(tester, f,
          pomodoro ? const PomodoroWidget() : const CountdownWidget(),
          reducedMotion: true);
        final owner = f.notifier, data = f.view.data;
        final kind = pomodoro ? TimeSessionKind.pomodoro : TimeSessionKind.countdown;
        final id = data.activeSession(kind)!.id;
        final writes = f.store.writes.length;
        await tap(tester, pomodoro ? 'pomodoro_history' : 'countdown_history');
        final top = router.routerDelegate.currentConfiguration.last;
        expect(top, isA<ImperativeRouteMatch>());
        expect((top as ImperativeRouteMatch).matches.uri.path,
          timeSessionHistoryLocation(kind));
        expect(tester.widget<TimeSessionHistoryScreen>(
          find.byType(TimeSessionHistoryScreen)).kind, kind);
        expect(router.canPop(), isTrue);
        expect(find.byKey(Key('time_session_$id')), findsOneWidget);
        expect(f.notifier, same(owner));
        expect(f.view.data, same(data));
        expect(f.store.writes.length, writes);
        await tap(tester, 'time_history_back');
        expect(find.byType(TimeSessionHistoryScreen), findsNothing);
        expect(router.routerDelegate.currentConfiguration.last.matchedLocation, '/dashboard');
        expect(router.canPop(), isFalse);
        expect(f.view.data.activeSession(kind)!.id, id);
        expect(f.store.writes.length, writes);
        expect(f.preferences.commits, 0);
        await tester.pumpWidget(const SizedBox());
      }
    });


  for (final year in [2027, 42]) {
    testWidgets('actual date and time picker confirmations retain seconds and commit once year $year',
      (tester) async {
        final f = _ExplicitTimerFixture();
        if (year < 1000) f.now = DateTime.utc(1, 1, 1);
        await mount(tester, f, const CountdownWidget());
        await tap(tester, 'countdown_set_target');
        await tester.enterText(find.byKey(const Key('countdown_title')), '合成 picker 目标');
        final paddedYear = year.toString().padLeft(4, '0');
        await tester.enterText(find.byKey(const Key('countdown_target')),
          '$paddedYear-03-04 12:13:14');
        final controller = tester.widget<TextField>(
          find.byKey(const Key('countdown_target'))).controller!;
        final before = f.view.data.toJson();
        final revision = f.view.data.revision;
        final sessionIds = f.view.data.sessions.map((session) => session.id).toList();
        final writes = f.store.writes.length, ids = f.id;
        void draftOnly() {
          expect(f.view.data.toJson(), before);
          expect(f.view.data.revision, revision);
          expect(f.view.data.sessions.map((session) => session.id).toList(), sessionIds);
          expect(f.store.writes.length, writes);
          expect(f.id, ids);
          expect(f.preferences.commits, 0);
        }

        await tap(tester, 'countdown_date_picker');
        final dateDialog = find.byType(DatePickerDialog);
        expect(dateDialog, findsOneWidget);
        final dateLabels = MaterialLocalizations.of(tester.element(dateDialog));
        await tester.tap(find.descendant(of: find.byType(CalendarDatePicker),
          matching: find.text('5')));
        await tester.pump();
        await tester.tap(find.descendant(of: dateDialog,
          matching: find.text(dateLabels.okButtonLabel)));
        await tester.pumpAndSettle();
        expect(dateDialog, findsNothing);
        expect(controller.text, '$paddedYear-03-05 12:13:14');
        final pickedDate = parseLocalCountdown(controller.text)!;
        expect(pickedDate.year, year);
        expect(pickedDate.day, 5);
        expect(pickedDate.hour, 12);
        expect(pickedDate.minute, 13);
        expect(pickedDate.second, 14);
        draftOnly();

        await tap(tester, 'countdown_time_picker');
        final timeDialog = find.byType(TimePickerDialog);
        expect(timeDialog, findsOneWidget);
        final timeLabels = MaterialLocalizations.of(tester.element(timeDialog));
        await tester.tap(find.byTooltip(timeLabels.inputTimeModeButtonLabel));
        await tester.pumpAndSettle();
        final timeFields = find.descendant(of: timeDialog,
          matching: find.byType(TextField));
        expect(timeFields, findsNWidgets(2));
        // The original 12:13 uses PM in this explicit MaterialApp's en-US picker.
        await tester.enterText(timeFields.at(0), '2');
        await tester.enterText(timeFields.at(1), '25');
        await tester.tap(find.descendant(of: timeDialog,
          matching: find.text(timeLabels.okButtonLabel)));
        await tester.pumpAndSettle();
        expect(timeDialog, findsNothing);
        expect(controller.text, '$paddedYear-03-05 14:25:14');
        final pickedTime = parseLocalCountdown(controller.text)!;
        expect(pickedTime.year, year);
        expect(pickedTime.month, 3);
        expect(pickedTime.day, 5);
        expect(pickedTime.hour, 14);
        expect(pickedTime.minute, 25);
        expect(pickedTime.second, 14);
        draftOnly();

        final confirm = tester.widget<FilledButton>(
          find.byKey(const Key('countdown_save'))).onPressed!;
        confirm(); confirm();
        await tester.pumpAndSettle();
        await f.notifier.flush();
        expect(f.view.data.countdown!.targetUtc, pickedTime.toUtc());
        expect(f.view.data.revision, revision + 1);
        expect(f.store.writes.length, writes + 1);
        expect(f.view.data.sessions, hasLength(1));
        expect(f.id, ids + 1);
        expect(f.preferences.commits, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
  }
  testWidgets('composite unrelated components stable through timer dirty ACK fail retry',
    (tester) async {
      final now = DateTime.utc(2026, 10, 7, 12);
      final store = PublicMemoryAckStore(TimeToolsState(
        countdown: CountdownState(title: 'SYNTHETIC_COUNTDOWN',
          targetUtc: now.add(const Duration(days: 10))),
        tasks: [TimeTask(id: 'synthetic-task', text: 'SYNTHETIC_TASK')],
      ));
      final prefs = MemoryPreferencesBackend();
      final quote = offlineDailyQuotes.first;
      final quoteRepo = DailyQuoteRepository(read: () => {},
        write: (_) {}, fetch: () async => quote);
      final draft = TextEditingController(text: 'SYNTHETIC_DRAFT')
        ..selection = const TextSelection(baseOffset: 2, extentOffset: 6);
      var ids = 0;
      final container = ProviderContainer(overrides: [
        timeToolsStoreProvider.overrideWithValue(store),
        timeToolsClockProvider.overrideWithValue(() => now),
        timeToolsMonotonicProvider.overrideWithValue(() => Duration.zero),
        timeToolsIdProvider.overrideWithValue(() => 'synthetic-${++ids}'),
        uiPreferencesBackendProvider.overrideWithValue(prefs),
        dailyQuoteRepositoryProvider.overrideWithValue(quoteRepo),
        dailyQuoteProvider.overrideWith((ref, day) async => quote),
        dailyQuoteClockProvider.overrideWithValue(() => now),
        dailyQuoteTickProvider.overrideWithValue(null),
        dailyQuoteFetchProvider.overrideWithValue(
          () async => throw StateError('forbidden network')),
        apiProvider.overrideWith((ref) => throw StateError('forbidden API/private data')),
        dataRefreshVisibilityProvider.overrideWithValue(
          () => throw StateError('forbidden native visibility')),
      ]);
      addTearDown(container.dispose); addTearDown(quoteRepo.dispose);
      addTearDown(draft.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox()));
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notifier = container.read(timeToolsProvider.notifier);
      await notifier.ensureLoaded();
      final document = WorkspaceDocument(groups: [
        ['pomodoro'], ['countdown'], ['tasks'], ['dailyPoetry'], ['diary'],
      ]);
      final registry = createWorkspaceRegistry(components: {
        WorkspaceComponent.diary: SizedBox(height: 100,
          child: TextField(key: const Key('synthetic_editor'), controller: draft)),
        WorkspaceComponent.dailyPoetry: RepaintBoundary(
          key: const Key('synthetic_static_quote'),
          child: const MaterialCard(margin: EdgeInsets.zero,
            child: Padding(padding: EdgeInsets.all(16), child: DailyQuoteLine()))),
      });
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff58694f));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: ThemeData(colorScheme: scheme),
          home: Scaffold(body: MaterialScope(
            policy: MaterialPolicy.resolve(colorScheme: scheme,
              wallpaper: WallpaperLoadState.absent,
              signals: const MaterialSignals(
                highContrast: AccessibilitySignal.disabled,
                reduceTransparency: AccessibilitySignal.enabled)),
            tokens: MaterialTokens.forWidth(1200),
            child: SingleChildScrollView(child: WorkspaceHost(
              document: document, registry: registry,
              onAction: (_) => throw StateError('unexpected layout write'))),
          ))),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final host = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
      final beforeGeometry = List<Rect>.of(host.geometry!.groups);
      final beforeDocument = jsonEncode(document.toJson());
      final beforeData = container.read(timeToolsProvider).data;
      final beforeDraft = draft.value;
      final beforeElements = [
        tester.element(find.byType(CountdownWidget)),
        tester.element(find.byType(TasksWidget)),
        tester.element(find.byType(DailyQuoteLine)),
        tester.element(find.byKey(const Key('synthetic_editor'))),
      ];
      final heading = find.byKey(const ValueKey('tasks_heading'));
      final headingRect = tester.getRect(heading);
      final more = find.byKey(const Key('countdown_more'));
      final moreRect = tester.getRect(more);
      final initialPaint = await staticPaint(tester,
        find.byKey(const Key('synthetic_static_quote')));
      final differences = <String>[];
      Future<void> snapshot(String stage) async {
        final data = container.read(timeToolsProvider).data;
        expect(data.countdown!.toJson(), beforeData.countdown!.toJson());
        expect(data.tasks.map((task) => task.toJson()).toList(),
          beforeData.tasks.map((task) => task.toJson()).toList());
        expect(jsonEncode(document.toJson()), beforeDocument);
        expect(host.geometry!.groups, beforeGeometry);
        expect(draft.value, beforeDraft);
        expect(tester.element(find.byType(CountdownWidget)), same(beforeElements[0]));
        expect(tester.element(find.byType(TasksWidget)), same(beforeElements[1]));
        expect(tester.element(find.byType(DailyQuoteLine)), same(beforeElements[2]));
        expect(tester.element(find.byKey(const Key('synthetic_editor'))), same(beforeElements[3]));
        expect(tester.getRect(more), moreRect);
        if (tester.getRect(heading) != headingRect) differences.add('$stage task header geometry');
        final label = find.descendant(of: more, matching: find.byType(Text));
        if (tester.widget<Text>(label).data != '更多') differences.add('$stage unrelated countdown label');
        expect(await staticPaint(tester, find.byKey(const Key('synthetic_static_quote'))), initialPaint);
        expect(prefs.commits, 0);
      }
      for (final stage in ['start', 'pause', 'resume']) {
        store.pending = Completer<void>();
        await tester.tap(find.byKey(const Key('pomodoro_start_pause')));
        await tester.pump();
        expect(container.read(timeToolsProvider).dirty, isTrue);
        await snapshot('$stage dirty');
        store.pending!.complete(); store.pending = null;
        await notifier.flush(); await tester.pumpAndSettle();
        expect(container.read(timeToolsProvider).dirty, isFalse);
        await snapshot('$stage ACK');
      }
      store.fail = true;
      expect(notifier.pausePomodoro(), isTrue);
      await notifier.flush(); await tester.pumpAndSettle();
      expect(container.read(timeToolsProvider).error, isNotNull);
      expect(find.byKey(const Key('time_tools_error')), findsWidgets);
      final retry = find.byKey(const Key('time_tools_retry'));
      expect(retry, findsWidgets);
      store.fail = false;
      await tester.tap(retry.first); await notifier.flush(); await tester.pumpAndSettle();
      expect(container.read(timeToolsProvider).dirty, isFalse);
      expect(container.read(timeToolsProvider).error, isNull);
      await snapshot('retry ACK');
      expect(tester.takeException(), isNull);
      // Collect both concrete old presentation defects before failing this RED.
      expect(differences, isEmpty,
        reason: 'normal timer ACK must not change unrelated header/operation label');
      await tester.pumpWidget(const SizedBox());
    });

  testWidgets('single basic settings preserves seconds and advanced fold focus draft without writes',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await f.notifier.ensureLoaded();
      expect(f.notifier.configurePomodoroSeconds(61, 121), isTrue);
      await f.notifier.flush();
      await mount(tester, f, const PomodoroWidget());
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      await tester.tap(find.byKey(const Key('pomodoro_configure')));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialTransientPanel), findsOneWidget);
      expect(find.byKey(const Key('pomodoro_focus_hours')), findsNothing);
      final basic = find.byKey(const Key('pomodoro_focus_total_minutes'));
      expect(tester.widget<TextField>(basic).controller!.text, '1');
      await tester.enterText(basic, '2');
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      final header = find.byKey(const Key('pomodoro_advanced'));
      await tester.ensureVisible(header); await tester.tap(header); await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const Key('pomodoro_focus_minutes')))
        .controller!.text, '2');
      final seconds = find.byKey(const Key('pomodoro_focus_seconds'));
      expect(tester.widget<TextField>(seconds).controller!.text, '1');
      await tester.ensureVisible(seconds);
      await tester.enterText(seconds, '7');
      final controller = tester.widget<TextField>(seconds).controller!;
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
      await tester.showKeyboard(seconds);
      final draft = controller.value;
      final scope = FocusScope.of(tester.element(seconds));
      expect(scope.hasFocus, isTrue);
      // Invoke the actual header callback while a child owns focus, so focus
      // restoration is not accidentally provided by a pointer tap.
      tester.widget<FilledButton>(header).onPressed!();
      await tester.pump();
      expect(tester.widget<FilledButton>(header).focusNode!.hasFocus, isTrue);
      expect(scope.hasFocus, isFalse);
      expect(seconds, findsNothing);
      final semantics = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'^秒$')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab); await tester.pump();
      expect(scope.hasFocus, isFalse);
      expect(controller.value, draft);
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      await tester.ensureVisible(header); await tester.tap(header); await tester.pump();
      expect(controller.value, draft);
      // Hidden invalid end-time text must never participate in duration save.
      await tester.enterText(find.byKey(const Key('pomodoro_end_target')), 'invalid end');
      tester.widget<FilledButton>(header).onPressed!(); await tester.pump();
      final confirm = tester.widget<FilledButton>(
        find.byKey(const Key('pomodoro_save_config'))).onPressed!;
      confirm(); confirm(); await tester.pumpAndSettle(); await f.notifier.flush();
      expect(f.view.data.pomodoro.focusSeconds, 127);
      expect(f.view.data.pomodoro.restSeconds, 121);
      expect(f.view.data.pomodoro.running, isFalse);
      expect(f.view.data.revision, (before['revision'] as int) + 1);
      expect(f.store.writes.length, writes + 1);
      expect(f.preferences.commits, 0);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    });

  testWidgets('single settings applies end independently of invalid duration draft exactly once',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await mount(tester, f, const PomodoroWidget());
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      await tester.tap(find.byKey(const Key('pomodoro_configure')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('pomodoro_focus_total_minutes')), 'bad');
      final header = find.byKey(const Key('pomodoro_advanced'));
      await tester.ensureVisible(header); await tester.tap(header); await tester.pump();
      final end = f.now.add(const Duration(seconds: 122)).toLocal()
          .toIso8601String().substring(0, 19).replaceFirst('T', ' ');
      await tester.enterText(find.byKey(const Key('pomodoro_end_target')), end);
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      expect(find.byType(MaterialTransientPanel), findsOneWidget);
      final apply = tester.widget<FilledButton>(
        find.byKey(const Key('pomodoro_apply_end'))).onPressed!;
      apply(); apply(); await tester.pumpAndSettle(); await f.notifier.flush();
      expect(f.view.data.pomodoro.focusSeconds, 122);
      expect(f.view.data.pomodoro.restSeconds, (before['pomodoro'] as Map)['restSeconds']);
      expect(f.view.data.pomodoro.running, isFalse);
      expect(f.view.data.revision, (before['revision'] as int) + 1);
      expect(f.store.writes.length, writes + 1);
      expect(f.preferences.commits, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

  testWidgets('tasks own data pending remains visible through delayed ACK and failure retry',
    (tester) async {
      final store = PublicMemoryAckStore(TimeToolsState(tasks: [
        const TimeTask(id: 'own-task', text: 'SYNTHETIC_OWN_TASK')]));
      final prefs = MemoryPreferencesBackend();
      final container = ProviderContainer(overrides: [
        timeToolsStoreProvider.overrideWithValue(store),
        timeToolsClockProvider.overrideWithValue(() => DateTime.utc(2026, 10, 7, 12)),
        timeToolsMonotonicProvider.overrideWithValue(() => Duration.zero),
        timeToolsIdProvider.overrideWithValue(() => 'synthetic-own-id'),
        uiPreferencesBackendProvider.overrideWithValue(prefs),
        apiProvider.overrideWith((_) => throw StateError('forbidden API/private data')),
        dataRefreshVisibilityProvider.overrideWithValue(
          () => throw StateError('forbidden native visibility')),
      ]);
      addTearDown(container.dispose);
      addTearDown(() async => tester.pumpWidget(const SizedBox()));
      final notifier = container.read(timeToolsProvider.notifier);
      await notifier.ensureLoaded();
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MaterialApp(home: Scaffold(body: TasksWidget()))));
      await tester.pumpAndSettle();
      final tasks = find.byType(TasksWidget);
      final pending = find.descendant(of: tasks, matching: find.text('修改尚未保存到本机'));
      expect(pending, findsNothing);
      store.pending = Completer<void>();
      await tester.tap(find.byKey(const Key('task_toggle_own-task'))); await tester.pump();
      expect(container.read(timeToolsProvider).data.tasks.single.done, isTrue);
      expect(pending, findsOneWidget);
      store.pending!.complete(); store.pending = null;
      await notifier.flush(); await tester.pumpAndSettle();
      expect(pending, findsNothing);
      final ownToggle = find.byKey(const Key('task_toggle_own-task'));
      expect(ownToggle, findsNothing);
      final completedHeading = find.byKey(const Key('tasks_completed_heading'));
      await tester.ensureVisible(completedHeading);
      await tester.tap(completedHeading); await tester.pumpAndSettle();
      await tester.ensureVisible(ownToggle);
      expect(ownToggle, findsOneWidget);
      store.fail = true;
      await tester.tap(find.byKey(const Key('task_toggle_own-task')));
      await notifier.flush(); await tester.pumpAndSettle();
      expect(container.read(timeToolsProvider).data.tasks.single.id, 'own-task');
      expect(pending, findsOneWidget);
      expect(find.byKey(const Key('time_tools_error')), findsOneWidget);
      store.fail = false;
      await tester.tap(find.byKey(const Key('time_tools_retry')));
      await notifier.flush(); await tester.pumpAndSettle();
      expect(container.read(timeToolsProvider).dirty, isFalse);
      expect(pending, findsNothing);
      expect(prefs.commits, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

}

void _acceptanceUsabilityTests() {
  testWidgets('time edit has whole visible button without write on cancel',
    (tester) async {
      final f = _ExplicitTimerFixture();
      await mount(tester, f, const CountdownWidget(),
        width: 280, height: 160, scale: 2);
      final target = find.byKey(const Key('countdown_edit'));
      final button = tester.widget<FilledButton>(target);
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      expect(button.style!.backgroundColor!.resolve({})!.a, greaterThan(0));
      expect(button.style!.side!.resolve({})!.color, isNot(Colors.transparent));
      final before = f.view.data.toJson(), writes = f.store.writes.length;
      await tester.tap(target);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(f.view.data.toJson(), before);
      expect(f.store.writes.length, writes);
      expect(f.preferences.commits, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
    });
}
