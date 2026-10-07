import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart' as core;
import 'package:timetrace_app/src/core/workspace/workspace_host.dart';
import 'package:timetrace_app/src/core/workspace/workspace_geometry.dart';

import '../../ui_preferences_store_test.dart' show MemoryPreferencesBackend;
import 'package:timetrace_app/src/features/dashboard/providers/workspace_layout_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/component_workspace.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/data/diary_draft_tags_store.dart';

final componentStarts = <WorkspaceComponent, int>{};

class LeaseProbe extends StatefulWidget {
  const LeaseProbe({required this.id, required this.child});
  final WorkspaceComponent id;
  final Widget child;
  @override
  State<LeaseProbe> createState() => _LeaseProbeState();
}

class _LeaseProbeState extends State<LeaseProbe> {
  @override
  void initState() {
    super.initState();
    componentStarts.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class MemoryLayoutStore extends WorkspaceLayoutStore {
  MemoryLayoutStore([Map<String, dynamic>? initial])
    : memory = MemoryPreferencesBackend(
        initial == null ? null : jsonEncode(initial),
      ),
      super(backend: null);
  final MemoryPreferencesBackend memory;
  int patches = 0;
  Map<String, dynamic> get values => UiPreferencesStore.read(backend: memory);
  List<dynamic> get savedGroups => [
    for (final group in decodeWorkspaceGroups(values))
      group.map((member) => member.name).toList(),
  ];
  @override
  core.WorkspaceRootOutcome loadRoot() =>
      WorkspaceLayoutStore(backend: memory).loadRoot();
  @override
  FutureOr<core.WorkspaceWriteOutcome> writePatch(core.WorkspacePatch patch) {
    patches++;
    return WorkspaceLayoutStore(backend: memory).writePatch(patch);
  }
}

Finder appendSlot(WidgetTester tester) {
  final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
  final host = tester.widget<WorkspaceHost>(find.byType(WorkspaceHost));
  final slots = state.geometry?.slots ?? [];
  for (var i = slots.length - 1; i >= 0; i--) {
    if (slots[i].insertionIndex == host.document.groups.length) {
      return find.byKey(ValueKey('workspace_slot_' + i.toString()));
    }
  }
  return find.byKey(const Key('no_append_slot'));
}

Rect groupBounds(WidgetTester tester, String member) {
  final host = tester.widget<WorkspaceHost>(find.byType(WorkspaceHost));
  final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
  final index = host.document.groups.indexWhere(
    (group) => group.contains(member),
  );
  return state.geometry!.groups[index].shift(
    tester.getTopLeft(find.byType(WorkspaceHost)),
  );
}

Finder internalSlot(WidgetTester tester, int insertionIndex) {
  final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
  final slots = state.geometry?.slots ?? [];
  for (var i = 0; i < slots.length - 1; i++) {
    if (slots[i].insertionIndex == insertionIndex) {
      return find.byKey(ValueKey('workspace_slot_' + i.toString()));
    }
  }
  return find.byKey(const Key('no_internal_slot'));
}

class WorkspaceFixture extends StatelessWidget {
  const WorkspaceFixture({
    this.reduceMotion = false,
    this.bodyHeight = 120,
    this.viewportHeight,
    super.key,
  });
  final bool reduceMotion;
  final double bodyHeight;
  final double? viewportHeight;
  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Scaffold(
      appBar: AppBar(actions: const [WorkspaceEditActions()]),
      body: SingleChildScrollView(
        child: ComponentWorkspace(
          viewportHeight: viewportHeight,
          contentHeight: bodyHeight,
          components: {
            for (final item in WorkspaceComponent.values)
              item: LeaseProbe(
                id: item,
                child: SizedBox(
                  height: bodyHeight,
                  child: item == WorkspaceComponent.diary
                      ? const TextField(key: Key('diary_fixture_editor'))
                      : Center(child: Text('BODY_${item.name}')),
                ),
              ),
          },
        ),
      ),
    ),
  );
}

Future<void> mount(
  WidgetTester tester,
  MemoryLayoutStore store, {
  double width = 1200,
  bool reduceMotion = false,
  double bodyHeight = 120,
  double? viewportHeight,
  bool preload = false,
}) async {
  componentStarts.clear();
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final fixture = WorkspaceFixture(
    reduceMotion: reduceMotion,
    bodyHeight: bodyHeight,
    viewportHeight: viewportHeight,
  );
  if (preload) {
    final container = ProviderContainer(
      overrides: [
        workspaceLayoutStoreProvider.overrideWithValue(store),
        diaryDraftTagsStoreProvider.overrideWithValue(
          MemoryDiaryDraftTagsStore(),
        ),
      ],
    );
    await container.read(workspaceDocumentProvider.notifier).ensureLoaded();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: fixture),
    );
  } else
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          workspaceLayoutStoreProvider.overrideWithValue(store),
          diaryDraftTagsStoreProvider.overrideWithValue(
            MemoryDiaryDraftTagsStore(),
          ),
        ],
        child: fixture,
      ),
    );
  await tester.pumpAndSettle();
}


Future<Element> mountHiddenSummary(
  WidgetTester tester,
  MemoryLayoutStore store,
) async {
  await mount(
    tester,
    store,
    bodyHeight: 360,
    viewportHeight: 650,
    preload: true,
    reduceMotion: true,
  );
  await tester.enterText(
    find.byKey(const Key('diary_fixture_editor')),
    'keep draft',
  );
  final input = tester.element(find.byKey(const Key('diary_fixture_editor')));
  await tester.tap(find.byKey(const Key('workspace_edit_layout')));
  await tester.pumpAndSettle();
  expect(componentStarts, {
    WorkspaceComponent.calendar: 1,
    WorkspaceComponent.diary: 1,
  });
  return input;
}

Future<TestGesture> startHiddenSummaryDrag(WidgetTester tester) async {
  final source = find.byKey(const Key('workspace_add_summary'));
  final pointer = tester.getCenter(source);
  expect(source.hitTestable(), findsOneWidget);
  expect(tester.getRect(find.byType(WorkspaceHost)).contains(pointer), isTrue);
  final gesture = await tester.startGesture(pointer);
  await gesture.moveBy(const Offset(-25, 0));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('workspace_group_calendar')), findsOneWidget);
  expect(
    tester.state<WorkspaceHostState>(find.byType(WorkspaceHost)).geometry,
    isNotNull,
  );
  return gesture;
}

RenderBox measuredConsumerCanvas(WidgetTester tester) {
  final target = find.byKey(const Key('workspace_group_calendar'));
  final surface = tester.renderObject<RenderBox>(target);
  final canvasWidget = find.ancestor(
    of: target,
    matching: find.byWidgetPredicate(
      (widget) => widget is MultiChildRenderObjectWidget,
    ),
  ).first;
  final canvas = tester.renderObject<RenderBox>(canvasWidget);
  expect(surface.parent, same(canvas));
  return canvas;
}

void expectConsumerDiary(WidgetTester tester, Element input) {
  expect(
    tester.element(find.byKey(const Key('diary_fixture_editor'))),
    same(input),
  );
  expect(
    tester.widget<EditableText>(find.byType(EditableText)).controller.text,
    'keep draft',
  );
}

void expectConsumerReject(
  WidgetTester tester,
  MemoryLayoutStore store,
  Element input,
) {
  expect(store.savedGroups, [
    ['calendar'],
    ['diary'],
  ]);
  expect(store.patches, 0);
  expect(componentStarts[WorkspaceComponent.summary], isNull);
  expect(componentStarts, {
    WorkspaceComponent.calendar: 1,
    WorkspaceComponent.diary: 1,
  });
  expectConsumerDiary(tester, input);
}

void main() {
  _acceptanceUsabilityTests();
  for (final vertical in ['upper', 'lower']) {
    testWidgets(
      'first summary $vertical hole rejects then durable semantic append',
      (tester) async {
        final store = MemoryLayoutStore({
          'workspaceGroupsV2': [
            ['calendar'],
            ['diary'],
          ],
        });
        await mount(
          tester,
          store,
          bodyHeight: 360,
          viewportHeight: 650,
          preload: true,
        );
        await tester.enterText(
          find.byKey(const Key('diary_fixture_editor')),
          'keep draft',
        );
        final input = tester.element(
          find.byKey(const Key('diary_fixture_editor')),
        );
        await tester.tap(find.byKey(const Key('workspace_edit_layout')));
        await tester.pumpAndSettle();
        final hole = tester.getRect(internalSlot(tester, 1));
        final points = [
          Offset(
            hole.left + hole.width / 4,
            vertical == 'upper' ? hole.top + 20 : hole.bottom - 20,
          ),
        ];
        for (final point in points) {
          final drag = await tester.startGesture(
            tester.getCenter(find.byKey(const Key('workspace_add_summary'))),
          );
          await drag.moveBy(const Offset(-25, 0));
          await tester.pump();
          await drag.moveTo(point);
          await tester.pump(const Duration(milliseconds: 750));
          expect(find.text('放到这个位置'), findsNothing);
          expect(find.text('松开合并为堆叠'), findsNothing);
          await drag.up();
          await tester.pumpAndSettle();
          expect(store.savedGroups, [
            ['calendar'],
            ['diary'],
          ]);
          expect(store.patches, 0);
          expect(componentStarts[WorkspaceComponent.summary], isNull);
        }
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_add_summary'))),
        );
        await drag.moveBy(const Offset(-25, 0));
        await tester.pump();
        final append = find.byKey(const Key('workspace_semantic_append'));
        expect(tester.getSize(append).height, 48);
        await drag.moveTo(tester.getCenter(append));
        await tester.pump();
        await drag.up();
        await tester.pumpAndSettle();
        expect(store.savedGroups, [
          ['calendar'],
          ['diary'],
          ['summary'],
        ]);
        expect(componentStarts[WorkspaceComponent.summary], 1);
        expect(
          tester.element(find.byKey(const Key('diary_fixture_editor'))),
          same(input),
        );
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'keep draft',
        );
        expect(
          decodeWorkspaceGroups(
            store.values,
          ).map((g) => g.map((e) => e.name).toList()).toList(),
          [
            ['calendar'],
            ['diary'],
            ['summary'],
          ],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final after in [false, true]) {
    testWidgets(
      'first summary measured calendar edge inserts durably after=$after',
      (tester) async {
        final store = MemoryLayoutStore({
          'workspaceGroupsV2': [
            ['calendar'],
            ['diary'],
          ],
        });
        final input = await mountHiddenSummary(tester, store);
        final gesture = await startHiddenSummaryDrag(tester);
        final target = find.byKey(const Key('workspace_group_calendar'));
        final calendar = tester.getRect(target);
        final canvas = measuredConsumerCanvas(tester);
        final point = Offset(
          after ? calendar.right - 8 : calendar.left + 8,
          calendar.center.dy,
        );
        final host = tester.widget<WorkspaceHost>(find.byType(WorkspaceHost));
        final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
        final hit = state.geometry!.hit(canvas.globalToLocal(point));
        expect(hit, isNotNull);
        expect(hit!.isSlot, isFalse);
        expect(hit.index, host.document.groups.indexWhere((g) => g.contains('calendar')));
        expect(
          tester.hitTestOnBinding(point).path.map((entry) => entry.target),
          contains(tester.renderObject<RenderBox>(target)),
        );
        await gesture.moveTo(point);
        await tester.pump();
        final indicator = find.byKey(
          ValueKey(after ? 'workspace_insert_right' : 'workspace_insert_left'),
        );
        expect(indicator, findsOneWidget);
        expect(
          tester.widget<ColoredBox>(indicator).color,
          Theme.of(tester.element(indicator)).colorScheme.primary,
        );
        final line = tester.getRect(indicator);
        expect(line.height, calendar.height);
        expect(
          after ? line.right : line.left,
          after ? calendar.right : calendar.left,
        );
        await tester.pump(const Duration(milliseconds: 750));
        expect(indicator, findsOneWidget);
        expect(find.text('松开合并为堆叠'), findsNothing);
        expectConsumerReject(tester, store, input);
        await gesture.up();
        await tester.pumpAndSettle();
        final expected = after
            ? [
                ['calendar'],
                ['summary'],
                ['diary'],
              ]
            : [
                ['summary'],
                ['calendar'],
                ['diary'],
              ];
        expect(store.savedGroups, expected);
        expect(store.patches, 1);
        expect(componentStarts, {
          WorkspaceComponent.calendar: 1,
          WorkspaceComponent.diary: 1,
          WorkspaceComponent.summary: 1,
        });
        expectConsumerDiary(tester, input);
        expect(
          decodeWorkspaceGroups(store.values)
              .map((g) => g.map((e) => e.name).toList()).toList(),
          expected,
        );
        // A second, widget-free reader reopens the same synthetic backend.
        final reopened = ProviderContainer(
          overrides: [
            workspaceLayoutStoreProvider.overrideWithValue(
              WorkspaceLayoutStore(backend: store.memory),
            ),
          ],
        );
        addTearDown(reopened.dispose);
        await reopened.read(workspaceDocumentProvider.notifier).ensureLoaded();
        expect(reopened.read(workspaceDocumentProvider).document.groups, expected);
        expect(store.patches, 1);
        expect(componentStarts[WorkspaceComponent.summary], 1);
        expectConsumerDiary(tester, input);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final location in ['central', 'gutter']) {
    testWidgets(
      'first summary consumer $location rejects without losing diary draft',
      (tester) async {
        final store = MemoryLayoutStore({
          'workspaceGroupsV2': [
            ['calendar'],
            ['diary'],
          ],
        });
        final input = await mountHiddenSummary(tester, store);
        final gesture = await startHiddenSummaryDrag(tester);
        final calendar = tester.getRect(
          find.byKey(const Key('workspace_group_calendar')),
        );
        final canvas = measuredConsumerCanvas(tester);
        final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
        final point = location == 'central'
            ? calendar.center
            : Offset(calendar.right + 8, calendar.center.dy);
        final hit = state.geometry!.hit(canvas.globalToLocal(point));
        if (location == 'central') {
          expect(hit, isNotNull);
          expect(hit!.isSlot, isFalse);
          expect(hit.index, 0);
        } else {
          expect(hit, isNull);
        }
        await gesture.moveTo(point);
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.byKey(const Key('workspace_insert_left')), findsNothing);
        expect(find.byKey(const Key('workspace_insert_right')), findsNothing);
        expect(find.text('松开合并为堆叠'), findsNothing);
        expect(find.text('放到这个位置'), findsNothing);
        expectConsumerReject(tester, store, input);
        await gesture.up();
        await tester.pumpAndSettle();
        expectConsumerReject(tester, store, input);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'first summary consumer rejects release on invalidated measurement',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['calendar'],
          ['diary'],
        ],
      });
      final input = await mountHiddenSummary(tester, store);
      final gesture = await startHiddenSummaryDrag(tester);
      final target = find.byKey(const Key('workspace_group_calendar'));
      final calendar = tester.getRect(target);
      final point = Offset(calendar.left + 8, calendar.center.dy);
      await gesture.moveTo(point);
      await tester.pump();
      expect(find.byKey(const Key('workspace_insert_left')), findsOneWidget);
      expectConsumerReject(tester, store, input);
      final canvas = measuredConsumerCanvas(tester);
      final state = tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
      final dropTarget = tester.widget<DragTarget<core.WorkspaceDrag>>(
        find.descendant(
          of: target,
          matching: find.byType(DragTarget<core.WorkspaceDrag>),
        ),
      );
      expect(state.geometry, isNotNull);
      canvas.markNeedsLayout();
      // No intervening pump can settle the geometry before the release check.
      expect(state.geometry, isNull);
      dropTarget.onAcceptWithDetails!(
        DragTargetDetails<core.WorkspaceDrag>(
          data: core.WorkspaceDrag(['summary']),
          offset: point - const Offset(80, 52),
        ),
      );
      expectConsumerReject(tester, store, input);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.geometry, isNotNull);
      expectConsumerReject(tester, store, input);
      expect(tester.takeException(), isNull);
    },
  );
  for (final targetPoint in ['upper', 'lower']) {
    testWidgets(
      'empty cell before full diary inserts after calendar ($targetPoint)',
      (tester) async {
        final store = MemoryLayoutStore({
          'workspaceGroupsV2': [
            ['calendar'],
            ['diary'],
            ['summary'],
          ],
        });
        await mount(tester, store, bodyHeight: 360);
        await tester.enterText(
          find.byKey(const Key('diary_fixture_editor')),
          'keep draft',
        );
        await tester.tap(find.byKey(const Key('workspace_edit_layout')));
        await tester.pumpAndSettle();
        final calendar = groupBounds(tester, 'calendar');
        final empty = tester.getRect(internalSlot(tester, 1));
        final diary = groupBounds(tester, 'diary');
        expect(empty.top, calendar.top);
        expect(empty.height, calendar.height);
        expect(empty.left, greaterThan(calendar.right));
        expect(diary.top, greaterThan(empty.bottom));
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_handle_summary'))),
        );
        await gesture.moveBy(const Offset(-25, 0));
        await tester.pump();
        await gesture.moveTo(
          Offset(
            empty.left + empty.width / 4,
            targetPoint == 'upper' ? empty.top + 20 : empty.bottom - 20,
          ),
        );
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.text('放到这个位置'), findsOneWidget);
        expect(find.text('松开合并为堆叠'), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(store.savedGroups, [
          ['calendar'],
          ['summary'],
          ['diary'],
        ]);
        expect(internalSlot(tester, 1), findsNothing);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          'keep draft',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'moving a later stack into an internal empty cell keeps all members',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceLayoutV3': core.WorkspaceDocument(
          groups: [
            ['calendar'],
            ['diary'],
            ['bar', 'summary'],
          ],
          sizes: {'calendar': core.WorkspaceSize.twoByThree},
        ).toJson(),
      });
      await mount(tester, store, bodyHeight: 140);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final empty = tester.getRect(internalSlot(tester, 1));
      expect(
        empty.height,
        greaterThanOrEqualTo(groupBounds(tester, 'bar').height),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_lift_bar'))),
      );
      await tester.pump(const Duration(milliseconds: 550));
      await gesture.moveTo(
        Offset(empty.left + empty.width / 4, empty.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 750));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, [
        ['calendar'],
        ['bar', 'summary'],
        ['diary'],
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('compact column does not create phantom internal empty cells', (
    tester,
  ) async {
    await mount(
      tester,
      MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['calendar'],
          ['diary'],
        ],
      }),
      width: 480,
    );
    await tester.tap(find.byKey(const Key('workspace_edit_layout')));
    await tester.pumpAndSettle();
    expect(internalSlot(tester, 1), findsNothing);
    expect(appendSlot(tester), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('stack transition has intermediate frames and last click wins', (
    tester,
  ) async {
    await mount(tester, MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]}));
    await tester.tap(find.byKey(const Key('workspace_switch_summary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final slide = tester.widget<FractionalTranslation>(
      find.byKey(const Key('workspace_stack_slide')).hitTestable(),
    );
    expect(slide.translation.dx.abs(), greaterThan(0));
    expect(slide.translation.dy, 0);
    await tester.tap(find.byKey(const Key('workspace_switch_apps')));
    await tester.pumpAndSettle();
    expect(find.text('BODY_apps').hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<FractionalTranslation>(
            find.byKey(const Key('workspace_stack_slide')).hitTestable(),
          )
          .translation,
      Offset.zero,
    );
    await tester.tap(find.byKey(const Key('workspace_switch_summary')));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byKey(const Key('workspace_switch_apps')));
    await tester.pumpAndSettle();
    expect(find.text('BODY_apps').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'drop geometry rejects outside points and distinguishes all four edges',
    () {
      const size = Size(400, 400);
      for (final point in [
        const Offset(-1, 200),
        const Offset(401, 200),
        const Offset(200, -1),
        const Offset(200, 401),
      ]) {
        expect(workspaceDropIntent(point, size, horizontal: true), isNull);
      }
      for (final sample in <(Offset, AxisDirection, bool)>[
        (const Offset(10, 200), AxisDirection.left, false),
        (const Offset(390, 200), AxisDirection.right, true),
        (const Offset(200, 10), AxisDirection.up, false),
        (const Offset(140, 390), AxisDirection.down, true),
      ]) {
        final intent = workspaceDropIntent(sample.$1, size, horizontal: true)!;
        expect(intent.edge, sample.$2);
        expect(intent.after, sample.$3);
        expect(intent.central, isFalse);
      }
      expect(
        workspaceDropIntent(
          const Offset(200, 200),
          size,
          horizontal: true,
        )!.central,
        isTrue,
      );
    },
  );
  testWidgets(
    'bottom edge inserts after and gap outside targets never changes order',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
          ['calendar'],
          ['apps'],
        ],
      });
      await mount(tester, store);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final target = groupBounds(tester, 'calendar');
      var gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_handle_apps'))),
      );
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveTo(
        Offset(target.left + target.width * .35, target.bottom - 5),
      );
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('插入后面'), findsOneWidget);
      final marker = tester.getRect(
        find.byKey(const Key('workspace_insert_down')),
      );
      expect(marker.bottom, target.bottom);
      expect(
        tester.getRect(find.text('插入后面')).top,
        greaterThan(target.center.dy),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, [
        ['bar'],
        ['calendar'],
        ['apps'],
      ]);
      final before = store.savedGroups.map((g) => List.of(g as List)).toList();
      final first = groupBounds(tester, 'bar');
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_add_hourly'))),
      );
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveTo(Offset(first.right + 8, first.center.dy));
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('插入前面'), findsNothing);
      expect(find.text('插入后面'), findsNothing);
      expect(find.text('松开合并为堆叠'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, before);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'after a filled row its lower right blank is the same append index',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
          ['calendar'],
          ['apps'],
        ],
      });
      await mount(tester, store);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final empty = tester.getRect(appendSlot(tester));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_handle_apps'))),
      );
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveTo(
        Offset(empty.left + empty.width * .8, empty.bottom - 20),
      );
      await tester.pump();
      expect(find.text('放到这个位置'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, [
        ['bar'],
        ['calendar'],
        ['apps'],
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'odd grid append slot fills right blank and accepts lower-area drop at index 1',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
        ],
      });
      await mount(tester, store, bodyHeight: 500);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final first = groupBounds(tester, 'bar');
      final empty = tester.getRect(internalSlot(tester, 1));
      expect(empty.top, first.top);
      expect(empty.left, greaterThan(first.right));
      expect(empty.width, first.width);
      expect(empty.height, first.height);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_add_summary'))),
      );
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      // First-use fixed content has no actual chrome; use the independent
      // semantic append, then assert that actual packing fills this same hole.
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('workspace_semantic_append'))),
      );
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text('追加独立组件（自动排布）'), findsOneWidget);
      expect(find.text('松开合并为堆叠'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, [
        ['bar'],
        ['summary'],
      ]);
      final appended = groupBounds(tester, 'summary');
      expect(appended.top, first.top);
      expect(appended.left, empty.left);
      final nextEmpty = tester.getRect(appendSlot(tester));
      expect(nextEmpty.top, greaterThan(appended.bottom));
      expect(nextEmpty.left, first.left);
      expect(tester.takeException(), isNull);
    },
  );
  for (final groups in <List<List<String>>>[
    [
      ['bar'],
      ['calendar'],
    ],
    [
      ['diary'],
    ],
    [],
  ]) {
    testWidgets('append cell covers the remaining next row after $groups', (
      tester,
    ) async {
      await mount(
        tester,
        MemoryLayoutStore({'workspaceGroupsV2': groups}),
        bodyHeight: 200,
      );
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final empty = tester.getRect(appendSlot(tester));
      if (groups.isNotEmpty) {
        final last = groupBounds(tester, groups.last.first);
        expect(empty.top, greaterThan(last.bottom));
        expect(empty.height, last.height);
        if (groups.last.first == 'diary') {
          expect(empty.width, last.width);
        } else {
          expect(empty.width, greaterThan(last.width * 2));
        }
      } else {
        expect(empty.height, 320);
      }
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'ordered group boundary moves preserve members, order and persistence',
    () async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar', 'summary'],
          ['calendar'],
          ['apps', 'hourly'],
          ['diary'],
        ],
      });
      final container = ProviderContainer(
        overrides: [workspaceLayoutStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(workspaceLayoutProvider.notifier);
      await container.read(workspaceDocumentProvider.notifier).ensureLoaded();
      final group = WorkspaceDrag([
        WorkspaceComponent.bar,
        WorkspaceComponent.summary,
      ]);
      await notifier.placeGroup(group, 2);
      expect(store.savedGroups, [
        ['calendar'],
        ['bar', 'summary'],
        ['apps', 'hourly'],
        ['diary'],
      ]);
      await notifier.placeGroup(group, 4);
      expect(store.savedGroups, [
        ['calendar'],
        ['apps', 'hourly'],
        ['diary'],
        ['bar', 'summary'],
      ]);
      await notifier.placeGroup(group, 0);
      await notifier.stackGroup(group, WorkspaceComponent.apps);
      expect(store.savedGroups, [
        ['calendar'],
        ['apps', 'hourly', 'bar', 'summary'],
        ['diary'],
      ]);
      await notifier.hideGroup(
        WorkspaceDrag([
          WorkspaceComponent.apps,
          WorkspaceComponent.hourly,
          WorkspaceComponent.bar,
          WorkspaceComponent.summary,
        ]),
      );
      expect(store.savedGroups, [
        ['calendar'],
        ['diary'],
      ]);
      expect(
        decodeWorkspaceGroups(store.values),
        container.read(workspaceLayoutProvider),
      );
    },
  );
  for (final after in [false, true]) {
    testWidgets('drop edge inserts ${after ? 'after' : 'before'} target', (
      tester,
    ) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
          ['calendar'],
          ['apps'],
        ],
      });
      await mount(tester, store);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final source = tester.getCenter(
        find.byKey(const Key('workspace_handle_apps')),
      );
      final target = groupBounds(tester, 'bar');
      final gesture = await tester.startGesture(source);
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump();
      await gesture.moveTo(
        Offset(after ? target.right - 25 : target.left + 25, target.center.dy),
      );
      await tester.pump(const Duration(milliseconds: 750));
      expect(find.text(after ? '插入后面' : '插入前面'), findsOneWidget);
      final marker = tester.getRect(
        find.byKey(Key('workspace_insert_${after ? 'right' : 'left'}')),
      );
      expect(
        after ? marker.right : marker.left,
        after ? target.right : target.left,
      );
      final hint = tester.getRect(find.text(after ? '插入后面' : '插入前面'));
      expect(
        after ? hint.top : hint.bottom,
        after ? greaterThan(target.center.dy) : lessThan(target.center.dy),
      );
      expect(find.text('松开合并为堆叠'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        store.savedGroups,
        after
            ? [
                ['bar'],
                ['apps'],
                ['calendar'],
              ]
            : [
                ['apps'],
                ['bar'],
                ['calendar'],
              ],
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'shelf defaults hidden, toggles width and editing restores prior state',
    (tester) async {
      final store = MemoryLayoutStore();
      await mount(tester, store);
      final shelf = find.byKey(const Key('workspace_component_shelf'));
      final bar = find.byKey(const Key('workspace_component_bar'));
      final originalWidth = tester.getSize(bar).width;
      expect(shelf, findsNothing);
      await tester.tap(find.byKey(const Key('workspace_toggle_shelf')));
      await tester.pumpAndSettle();
      expect(shelf, findsOneWidget);
      expect(tester.getSize(bar).width, lessThan(originalWidth));
      await tester.tap(find.byKey(const Key('workspace_toggle_shelf')));
      await tester.pumpAndSettle();
      expect(shelf, findsNothing);
      expect(tester.getSize(bar).width, originalWidth);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      expect(shelf, findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      expect(shelf, findsNothing);
      expect(store.values, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'deep scroll can return to blank lower shelf with stable thumbnail',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
          ['summary'],
          ['apps'],
          ['hourly'],
        ],
      });
      await mount(tester, store, bodyHeight: 500, viewportHeight: 1000);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('workspace_left_viewport')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      final shelf = tester.getRect(
        find.byKey(const Key('workspace_component_shelf')),
      );
      final source = tester.getCenter(
        find.byKey(const Key('workspace_lift_apps')),
      );
      final drop = Offset(shelf.center.dx, 900);
      expect(shelf.contains(drop), isTrue);
      final gesture = await tester.startGesture(source);
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveTo(drop);
      await tester.pump();
      expect(find.text('松开即可收纳'), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        store.savedGroups.expand((group) => group as List),
        isNot(contains('apps')),
      );
      expect(find.byKey(const Key('workspace_add_apps')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('edit help explains dwell and entry wiggle decays to still', (
    tester,
  ) async {
    await mount(tester, MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]}));
    await tester.tap(find.byKey(const Key('workspace_edit_layout')));
    await tester.pump();
    double angle() => tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byKey(const Key('workspace_lift_bar')),
            matching: find.byType(Transform),
          ),
        )
        .map((widget) => widget.transform.storage[1].abs())
        .fold<double>(0, (a, b) => a > b ? a : b);
    await tester.pump(const Duration(milliseconds: 130));
    final early = angle();
    expect(early, greaterThan(.02));
    await tester.pump(const Duration(milliseconds: 1067));
    expect(angle(), lessThan(early));
    await tester.pumpAndSettle();
    expect(angle(), lessThan(.000001));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('workspace_edit_help')),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('停留约 0.6 秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('grid rows follow tallest content without clipping long diary', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceGrid(
              items: [
                WorkspaceGridItem(
                  key: Key('short'),
                  child: SizedBox(height: 80),
                ),
                WorkspaceGridItem(
                  key: Key('tall'),
                  child: SizedBox(height: 280),
                ),
                WorkspaceGridItem(
                  key: Key('long_diary'),
                  fullWidth: true,
                  child: SizedBox(height: 860),
                ),
                WorkspaceGridItem(
                  key: Key('after'),
                  child: SizedBox(height: 80),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    Rect bounds(String name) => tester.getRect(find.byKey(Key(name)));
    expect(bounds('short').top, bounds('tall').top);
    expect(bounds('long_diary').top, greaterThan(bounds('tall').bottom));
    expect(bounds('long_diary').height, 860);
    expect(bounds('long_diary').width, 1000);
    expect(bounds('after').top, greaterThan(bounds('long_diary').bottom));
    expect(tester.takeException(), isNull);
  });
  for (final width in [480.0, 719.0, 720.0, 1200.0]) {
    testWidgets('grid uses equal medium slots and full diary at $width', (
      tester,
    ) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar'],
          ['apps'],
          ['diary'],
          ['calendar'],
          ['summary'],
          ['hourly'],
        ],
      });
      await mount(tester, store, width: width);
      Rect bounds(String name) => groupBounds(tester, name);
      final bar = bounds('bar');
      final apps = bounds('apps');
      final diary = bounds('diary');
      final calendar = bounds('calendar');
      final summary = bounds('summary');
      expect(bar.width, closeTo(apps.width, .01));
      expect(diary.width, closeTo(width, .01));
      if (width >= 720) {
        expect(bar.top, closeTo(apps.top, .01));
        expect(apps.left, greaterThan(bar.right));
        expect(bar.width * 2 + (apps.left - bar.right), closeTo(width, .01));
        expect(diary.top, greaterThanOrEqualTo(apps.bottom));
        expect(calendar.top, closeTo(summary.top, .01));
        expect(calendar.width, closeTo(bar.width, .01));
        expect(bounds('hourly').top, greaterThanOrEqualTo(summary.bottom));
      } else {
        expect(bar.width, closeTo(width, .01));
        expect(apps.top, greaterThanOrEqualTo(bar.bottom));
        expect(diary.top, greaterThanOrEqualTo(apps.bottom));
      }
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      expect(bounds('bar').width, closeTo(bounds('apps').width, .01));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('diary stack keeps full span and reflows after detaching', (
    tester,
  ) async {
    await mount(
      tester,
      MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar', 'diary'],
          ['apps'],
          ['calendar'],
          ['summary'],
          ['hourly'],
        ],
      }),
    );
    Rect bounds(String name) => groupBounds(tester, name);
    expect(bounds('bar').width, 1200);
    await tester.tap(find.byKey(const Key('workspace_switch_diary')));
    await tester.pumpAndSettle();
    expect(bounds('diary').width, 1200);
    await tester.enterText(
      find.byKey(const Key('diary_fixture_editor')),
      '保留草稿',
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComponentWorkspace)),
    );
    container
        .read(workspaceLayoutProvider.notifier)
        .place(WorkspaceComponent.diary, 1);
    await tester.pumpAndSettle();
    expect(bounds('bar').width, lessThan(1200));
    expect(bounds('diary').width, 1200);
    expect(find.text('保留草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('default data views form one group and legacy layout/order migrate', () {
    expect(decodeWorkspaceGroups({}), [
        [WorkspaceComponent.calendar],
        defaultDataComponents,
        [WorkspaceComponent.diary],
      ]);
    expect(decodeWorkspaceGroups({'workspaceComponentsV1': []}), isEmpty);
    expect(
      decodeWorkspaceGroups({
        'order': ['apps', 'bar'],
        'workspaceComponentsV1': ['calendar', 'data', 'diary'],
      }),
      [
        [WorkspaceComponent.calendar],
        [
          WorkspaceComponent.apps,
          WorkspaceComponent.bar,
          WorkspaceComponent.summary,
          WorkspaceComponent.hourly,
        ],
        [WorkspaceComponent.diary],
      ],
    );
    expect(
      decodeWorkspaceGroups({
        'workspaceGroupsV2': [
          ['apps', 'bogus', 'apps'],
          ['apps', 'diary'],
          [],
          'invalid',
        ],
      }),
      [
        [WorkspaceComponent.apps],
        [WorkspaceComponent.diary],
      ],
    );
    expect(
      decodeWorkspaceGroups({
        'workspaceGroupsV2': [],
        'workspaceComponentsV1': ['data'],
      }),
      isEmpty,
    );
  });
  test(
    'detach, merge, reorder, return and empty restart persist unique components',
    () async {
      final store = MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]});
      final container = ProviderContainer(
        overrides: [workspaceLayoutStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(workspaceLayoutProvider.notifier);
      await container.read(workspaceDocumentProvider.notifier).ensureLoaded();
      await notifier.place(WorkspaceComponent.summary, 1);
      expect(container.read(workspaceLayoutProvider), [
        [
          WorkspaceComponent.bar,
          WorkspaceComponent.apps,
          WorkspaceComponent.hourly,
        ],
        [WorkspaceComponent.summary],
      ]);
      await notifier.stack(WorkspaceComponent.summary, WorkspaceComponent.bar);
      expect(container.read(workspaceLayoutProvider).single.length, 4);
      await notifier.place(WorkspaceComponent.calendar, 0);
      await notifier.moveGroup(0, 1);
      expect(container.read(workspaceLayoutProvider).last, [
        WorkspaceComponent.calendar,
      ]);
      await notifier.stack(WorkspaceComponent.bar, WorkspaceComponent.calendar);
      expect(container.read(workspaceLayoutProvider).last, [
        WorkspaceComponent.calendar,
        WorkspaceComponent.bar,
      ]);
      for (final item in WorkspaceComponent.values) {
        await notifier.hide(item);
      }
      final restarted = ProviderContainer(
        overrides: [workspaceLayoutStoreProvider.overrideWithValue(store)],
      );
      addTearDown(restarted.dispose);
      await restarted.read(workspaceDocumentProvider.notifier).ensureLoaded();
      expect(restarted.read(workspaceLayoutProvider), isEmpty);
      await notifier.reset();
      expect(container.read(workspaceLayoutProvider), [
        [WorkspaceComponent.calendar],
        defaultDataComponents,
        [WorkspaceComponent.diary],
      ]);
      await notifier.reorderData(['hourly', 'apps', 'summary', 'bar']);
      expect(
        container.read(workspaceLayoutProvider)[1].first,
        WorkspaceComponent.hourly,
      );
    },
  );
  for (final width in [480.0, 1200.0]) {
    testWidgets(
      'top entry, per-view names, detach/merge and dirty diary survive at $width',
      (tester) async {
        final store = MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]});
        await mount(tester, store, width: width);
        expect(find.text('BODY_bar').hitTestable(), findsOneWidget);
        expect(find.text('BODY_summary').hitTestable(), findsNothing);
        final entry = find.byKey(const Key('workspace_edit_layout'));
        expect(
          find.ancestor(of: entry, matching: find.byType(AppBar)),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('workspace_switch_summary')));
        await tester.pumpAndSettle();
        expect(find.text('BODY_summary').hitTestable(), findsOneWidget);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        if (width < 760) {
          await tester.tap(find.byKey(const Key('workspace_dismiss_shelf')));
          await tester.pumpAndSettle();
        }
        final lift =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(const Key('workspace_lift_summary')),
                    )
                    .decoration
                as BoxDecoration;
        expect(lift.border, isNull);
        expect(lift.boxShadow, isNotEmpty);
        await tester.tap(find.byTooltip('拖动使用汇总'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('拆为独立组件'));
        await tester.pumpAndSettle();
        expect(store.savedGroups, [
          ['bar', 'apps', 'hourly'],
          ['summary'],
        ]);
        await tester.tap(find.byTooltip('拖动使用汇总'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义堆叠…'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workspace_stack_target_bar')));
        await tester.pumpAndSettle();
        expect(store.savedGroups.length, 1);
        if (width < 760) {
          await tester.tap(find.byKey(const Key('workspace_reopen_shelf')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('workspace_add_diary')));
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('diary_fixture_editor')),
          '未保存的日记',
        );
        await tester.tap(entry);
        await tester.pumpAndSettle();
        if (width < 760) {
          await tester.tap(find.byKey(const Key('workspace_dismiss_shelf')));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(
          find.byKey(const Key('workspace_hide_diary')),
        );
        await tester.tap(find.byKey(const Key('workspace_hide_diary')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('diary_fixture_editor')).hitTestable(),
          findsNothing,
        );
        if (width < 760) {
          await tester.tap(find.byKey(const Key('workspace_reopen_shelf')));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(
          find.byKey(const Key('workspace_add_diary')),
        );
        await tester.tap(find.byKey(const Key('workspace_add_diary')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '未保存的日记',
        );
        await tester.tap(entry);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('diary_fixture_editor')),
        );
        expect(
          find.byKey(const Key('diary_fixture_editor')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text('未保存的日记'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'long press moves entire stack into last slot without detaching',
    (tester) async {
      final store = MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]});
      await mount(tester, store);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final body = find.byKey(const Key('workspace_lift_bar'));
      expect(
        tester.getRect(find.byKey(const Key('workspace_hide_bar'))).bottom,
        lessThan(tester.getRect(body).top),
      );
      final gesture = await tester.startGesture(tester.getCenter(body));
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveBy(const Offset(24, 24));
      await tester.pump(const Duration(milliseconds: 200));
      final preview = find.byKey(const Key('workspace_drag_preview_bar'));
      expect(preview, findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const Key('workspace_drag_preview_surface')))
            .width,
        160,
      );
      expect(
        tester.getSize(preview).width,
        104,
      ); // L preview is square inside the unchanged feedback frame.
      await gesture.moveTo(tester.getCenter(appendSlot(tester)));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups, [
        ['bar', 'summary', 'apps', 'hourly'],
      ]);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      expect(find.text('BODY_bar').hitTestable(), findsOneWidget);
      expect(find.text('BODY_summary').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dwelling over a group merges and current component can return to shelf',
    (tester) async {
      final store = MemoryLayoutStore({
        'workspaceGroupsV2': [
          ['bar', 'summary', 'apps', 'hourly'],
          ['calendar'],
        ],
      });
      await mount(tester, store);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pumpAndSettle();
      final source = tester.getCenter(
        find.byKey(const Key('workspace_handle_calendar')),
      );
      final gesture = await tester.startGesture(source);
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('workspace_lift_bar'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('松开合并为堆叠'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(store.savedGroups.single, [
        'bar',
        'summary',
        'apps',
        'hourly',
        'calendar',
      ]);
      await tester.tap(find.byKey(const Key('workspace_switch_calendar')));
      await tester.pumpAndSettle();
      final handle = tester.getCenter(find.byTooltip('拖动日历'));
      final shelf = tester.getCenter(
        find.byKey(const Key('workspace_component_shelf')),
      );
      await tester.dragFrom(handle, shelf - handle);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_add_calendar')), findsOneWidget);
      expect(find.text('BODY_calendar').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'reduced motion is still and repeated external focus reveals real apps page',
    (tester) async {
      final store = MemoryLayoutStore({'workspaceGroupsV2': [['bar', 'summary', 'apps', 'hourly']]});
      await mount(tester, store, reduceMotion: true);
      final element = tester.element(find.byType(ComponentWorkspace));
      final container = ProviderScope.containerOf(element);
      container
          .read(workspaceFocusProvider.notifier)
          .select(WorkspaceComponent.apps);
      await tester.pumpAndSettle();
      expect(find.text('BODY_apps').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_switch_summary')));
      await tester.pumpAndSettle();
      container
          .read(workspaceFocusProvider.notifier)
          .select(WorkspaceComponent.apps);
      await tester.pumpAndSettle();
      expect(find.text('BODY_apps').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace_edit_layout')));
      await tester.pump();
      for (final transform in tester.widgetList<Transform>(
        find.ancestor(
          of: find.byKey(const Key('workspace_lift_apps')),
          matching: find.byType(Transform),
        ),
      )) {
        expect(transform.transform.storage[1].abs(), lessThan(.000001));
      }
      expect(tester.takeException(), isNull);
    },
  );
}

void _acceptanceUsabilityTests() {
  testWidgets('component optional prefix passes host and preserves extra size',
    (tester) async {
      final groups = [['calendar'],['bar','summary','apps','hourly'],
        ['diary'],['dailyPoetry'],['tasks']];
      final store=MemoryLayoutStore({'version':1,'workspaceLayoutV3':{
        'version':3,'groups':groups,'sizes':<String,Object?>{},
      }});
      final container=ProviderContainer(overrides:[
        workspaceLayoutStoreProvider.overrideWithValue(store),
        uiPreferencesBackendProvider.overrideWithValue(store.memory),
        diaryDraftTagsStoreProvider.overrideWithValue(MemoryDiaryDraftTagsStore()),
      ]);
      addTearDown(container.dispose);
      await container.read(workspaceDocumentProvider.notifier).ensureLoaded();
      final budget=WorkspacePrefixPresentationBudget(prefixGroups:groups.take(3),
        contentHeights:{0:500,1:500},firstFoldExtent:600,
        minimumContentHeight:180);
      tester.view.physicalSize=const Size(1200,800);
      tester.view.devicePixelRatio=1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(UncontrolledProviderScope(container:container,
        child:MaterialApp(home:Scaffold(body:SizedBox(width:1200,height:600,
          child:ComponentWorkspace(prefixBudget:budget,contentHeight:320,
            viewportHeight:600,includeTools:false,
            components:{for(final item in WorkspaceComponent.values)
              item:SizedBox(height:item==WorkspaceComponent.diary?85:120,
                child:Text(item.name))},
          ))))));
      await tester.pumpAndSettle();
      final host=tester.widget<WorkspaceHost>(find.byType(WorkspaceHost));
      final state=tester.state<WorkspaceHostState>(find.byType(WorkspaceHost));
      expect(host.prefixBudget,same(budget));
      expect(state.geometry!.contents[2].height,85);
      expect(state.geometry!.groups[3].top,greaterThanOrEqualTo(600));
      expect(state.geometry!.contents[3].height,
        host.geometryPolicy.heightFor(WorkspaceComponent.dailyPoetry.defaultSize));
      expect(state.geometry!.contents[4].height,
        host.geometryPolicy.heightFor(WorkspaceComponent.tasks.defaultSize));
      expect(store.patches,0);
      expect(store.savedGroups,groups);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds:1));
      await tester.pumpAndSettle();
    });
}
