import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui' as ui;
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/workspace/workspace_model.dart';
import 'package:timetrace_app/src/core/workspace/workspace_controller.dart';
import 'package:timetrace_app/src/core/workspace/workspace_geometry.dart';
import 'package:timetrace_app/src/core/workspace/workspace_host.dart';

import 'workspace_model_test.dart' show MemoryStore;

final starts = <String, int>{};
final disposals = <String, int>{};
final thumbnails = <String, int>{};
final _feedbackIdentity = Provider<String>(
  (ref) => throw StateError('unexpected fallback container'),
);

class Probe extends StatefulWidget {
  const Probe({
    required this.id,
    required this.height,
    this.widthSensitive = false,
    super.key,
  });
  final String id;
  final ValueNotifier<double> height;
  final bool widthSensitive;
  @override
  State<Probe> createState() => ProbeState();
}

class ProbeState extends State<Probe> {
  final text = TextEditingController();
  @override
  void initState() {
    super.initState();
    starts.update(widget.id, (value) => value + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    disposals.update(widget.id, (value) => value + 1, ifAbsent: () => 1);
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ValueListenableBuilder<double>(
      valueListenable: widget.height,
      builder: (context, height, _) => SizedBox(
        key: ValueKey('body-${widget.id}'),
        height:
            MediaQuery.textScalerOf(context).scale(height) +
            (widget.widthSensitive && constraints.maxWidth < 600 ? 80 : 0),
        child: TextField(key: ValueKey('field-${widget.id}'), controller: text),
      ),
    ),
  );
}

class Fixture extends StatefulWidget {
  const Fixture({
    required this.initial,
    required this.heights,
    this.editing = false,
    this.shelfOpen = false,
    this.reduceMotion = false,
    this.descriptorSizes = const {},
    this.labels = const {},
    this.supported = const {},
    this.viewportHeight,
    super.key,
  });
  final WorkspaceDocument initial;
  final Map<String, ValueNotifier<double>> heights;
  final bool editing, shelfOpen, reduceMotion;
  final Map<String, WorkspaceSize> descriptorSizes;
  final Map<String, String> labels;
  final Map<String, List<WorkspaceSize>> supported;
  final double? viewportHeight;
  @override
  State<Fixture> createState() => FixtureState();
}

class FixtureState extends State<Fixture> {
  final host = GlobalKey<WorkspaceHostState>();
  late final store = MemoryStore(const WorkspaceRootMissing());
  late final controller = WorkspaceController(
    store: store,
    defaults: widget.initial,
    onChanged: (_) {
      if (mounted) setState(() {});
    },
  );
  final actions = <WorkspaceAction>[];
  late bool editing = widget.editing;
  late bool shelfOpen = widget.shelfOpen;
  late double? viewportHeight = widget.viewportHeight;
  bool canEdit = true;
  double scale = 1;
  Object? contentRevision;
  String? focusId;
  int focusRevision = 0;
  @override
  void initState() {
    super.initState();
    unawaited(controller.load());
  }

  void focus(String id) => setState(() {
    focusId = id;
    focusRevision++;
  });
  void setCanEdit(bool value) => setState(() => canEdit = value);
  void setScale(double value) => setState(() => scale = value);
  void setViewport(double value) => setState(() => viewportHeight = value);
  void changeContent() =>
      setState(() => contentRevision = (contentRevision as int? ?? 0) + 1);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
        disableAnimations: widget.reduceMotion,
      ),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Wrap(
              children: [
                TextButton(
                  key: const Key('edit'),
                  onPressed: () => setState(() => editing = !editing),
                  child: const Text('Edit'),
                ),
                TextButton(
                  key: const Key('shelf'),
                  onPressed: () => setState(() => shelfOpen = !shelfOpen),
                  child: const Text('Shelf'),
                ),
              ],
            ),
            WorkspaceHost(
              key: host,
              viewportHeight: viewportHeight,
              document: controller.state.document,
              registry: {
                for (final entry in widget.heights.entries)
                  entry.key: WorkspaceDescriptor(
                    id: entry.key,
                    label: widget.labels[entry.key] ?? entry.key,
                    supportedSizes:
                        widget.supported[entry.key] ?? WorkspaceSize.values,
                    defaultSize:
                        widget.descriptorSizes[entry.key] ??
                        widget.initial.sizes[entry.key] ??
                        WorkspaceSize.twoByTwo,
                    contentRevision: contentRevision,
                    contentBuilder: (context, layout) => Probe(
                      id: entry.key,
                      height: entry.value,
                      widthSensitive: true,
                    ),
                    thumbnailBuilder: (context) {
                      thumbnails.update(
                        entry.key,
                        (value) => value + 1,
                        ifAbsent: () => 1,
                      );
                      return const ColoredBox(color: Color(0xffaabbcc));
                    },
                  ),
              },
              onAction: (action) {
                actions.add(action);
                unawaited(controller.perform(action));
              },
              editing: editing,
              canEdit: canEdit,
              shelfOpen: shelfOpen,
              focusId: focusId,
              focusRevision: focusRevision,
              geometryPolicy: const WorkspaceGeometryPolicy(cellHeight: 100),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<FixtureState> mount(
  WidgetTester tester, {
  required WorkspaceDocument document,
  required Map<String, ValueNotifier<double>> heights,
  double width = 1200,
  bool editing = false,
  bool shelfOpen = false,
  bool reduceMotion = false,
  Map<String, WorkspaceSize> descriptorSizes = const {},
  Map<String, String> labels = const {},
  Map<String, List<WorkspaceSize>> supported = const {},
  double? viewportHeight,
}) async {
  starts.clear();
  disposals.clear();
  thumbnails.clear();
  tester.view.physicalSize = Size(width, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  for (final value in heights.values) {
    addTearDown(value.dispose);
  }
  final key = GlobalKey<FixtureState>();
  await tester.pumpWidget(
    Fixture(
      key: key,
      initial: document,
      heights: heights,
      editing: editing,
      shelfOpen: shelfOpen,
      reduceMotion: reduceMotion,
      descriptorSizes: descriptorSizes,
      labels: labels,
      supported: supported,
      viewportHeight: viewportHeight,
    ),
  );
  await tester.pump();
  return key.currentState!;
}

Future<void> select(WidgetTester tester, String id) async {
  await tester.ensureVisible(find.byKey(ValueKey('workspace_switch_$id')));
  await tester.tap(find.byKey(ValueKey('workspace_switch_$id')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 240));
}

DragTarget<WorkspaceDrag> groupTarget(WidgetTester tester, String id) =>
    tester.widget<DragTarget<WorkspaceDrag>>(
      find.descendant(
        of: find.byKey(ValueKey('workspace_group_$id')),
        matching: find.byType(DragTarget<WorkspaceDrag>),
      ),
    );

DragTargetDetails<WorkspaceDrag> dropDetails(
  List<String> members,
  Offset pointer,
) => DragTargetDetails(
  data: WorkspaceDrag(members),
  offset: pointer - const Offset(80, 52),
);

void main() {
  _acceptanceUsabilityTests();
  for (final hiddenSize in [
    WorkspaceSize.twoByTwo,
    WorkspaceSize.fullNatural,
  ]) {
    testWidgets(
      'unmeasured shelf $hiddenSize cannot use a geometry slot',
      (tester) async {
        final f = await mount(
          tester,
          document: WorkspaceDocument(groups: [['bar']]),
          heights: {
            'bar': ValueNotifier(100.0),
            'calendar': ValueNotifier(100.0),
          },
          descriptorSizes: {'calendar': hiddenSize},
          editing: true,
          reduceMotion: true,
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_add_calendar'))),
        );
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pumpAndSettle();
        final last = f.host.currentState!.geometry!.slots.length - 1;
        expect(last, greaterThanOrEqualTo(0));
        final slot = tester.getRect(find.byKey(ValueKey('workspace_slot_$last')));
        await gesture.moveTo(Offset(slot.left + 8, slot.center.dy));
        await tester.pump();
        expect(find.text('放到这个位置'), findsNothing);
        expect(starts, {'bar': 1});
        await gesture.up();
        await tester.pumpAndSettle();
        expect(f.actions, isEmpty);
        expect(f.store.patches, isEmpty);
        expect(f.controller.state.document.groups, [['bar']]);
        expect(starts, {'bar': 1});
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final width in [1200.0, 480.0]) {
    for (final after in [false, true]) {
      testWidgets(
        'hidden calendar uses measured bar edge at $width after=$after',
        (tester) async {
          final f = await mount(
            tester,
            width: width,
            document: WorkspaceDocument(groups: [['bar']]),
            heights: {
              'bar': ValueNotifier(100.0),
              'calendar': ValueNotifier(100.0),
            },
            descriptorSizes: {
              'bar': WorkspaceSize.twoByOne,
              'calendar': WorkspaceSize.twoByTwo,
            },
            shelfOpen: true,
            reduceMotion: true,
            viewportHeight: width < 720 ? 360 : null,
          );
          await tester.pumpAndSettle();
          final entry = find.byKey(const Key('workspace_add_calendar'));
          final entryCenter = tester.getCenter(entry);
          expect(entry.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(find.byType(WorkspaceHost)).contains(entryCenter),
            isTrue,
          );
          final gesture = await tester.startGesture(entryCenter);
          await gesture.moveBy(const Offset(-30, 0));
          await tester.pumpAndSettle();
          final barTarget = find.byKey(const Key('workspace_group_bar'));
          expect(barTarget, findsOneWidget);
          expect(f.host.currentState!.geometry, isNotNull);
          final bar = tester.getRect(barTarget);
          // The compact shelf overlays the right side. Use the exposed left
          // area while exercising the full target's top/bottom semantics.
          final point = width < 720
              ? Offset(bar.left + 80, after ? bar.bottom - 8 : bar.top + 8)
              : Offset(after ? bar.right - 8 : bar.left + 8, bar.center.dy);
          expect(
            tester.hitTestOnBinding(point).path.map((entry) => entry.target),
            contains(tester.renderObject<RenderBox>(barTarget)),
          );
          await gesture.moveTo(point);
          await tester.pump();
          final edge = width < 720
              ? (after ? 'down' : 'up')
              : (after ? 'right' : 'left');
          final indicator = find.byKey(ValueKey('workspace_insert_$edge'));
          expect(indicator, findsOneWidget);
          expect(
            tester.widget<ColoredBox>(indicator).color,
            Theme.of(tester.element(indicator)).colorScheme.primary,
          );
          final line = tester.getRect(indicator);
          if (width < 720) {
            expect(line.width, bar.width);
            expect(after ? line.bottom : line.top, after ? bar.bottom : bar.top);
          } else {
            expect(line.height, bar.height);
            expect(after ? line.right : line.left, after ? bar.right : bar.left);
          }
          // No speculative business lease or write while hovering, even beyond
          // the stack dwell interval.
          await tester.pump(const Duration(milliseconds: 650));
          expect(find.text('松开合并为堆叠'), findsNothing);
          expect(starts, {'bar': 1});
          expect(f.actions, isEmpty);
          expect(f.store.patches, isEmpty);
          await gesture.up();
          await tester.pumpAndSettle();
          final expected = after
              ? [['bar'], ['calendar']]
              : [['calendar'], ['bar']];
          expect(f.controller.state.document.groups, expected);
          expect(f.actions, hasLength(1));
          expect(f.actions.single.kind, WorkspaceActionKind.place);
          expect(f.actions.single.index, after ? 1 : 0);
          expect(f.actions.single.drag!.members, ['calendar']);
          expect(f.store.patches, hasLength(1));
          expect(starts, {'bar': 1, 'calendar': 1});
          expect(disposals, isEmpty);
          expect(f.editing, isFalse);
          expect(find.byKey(const Key('workspace_handle_bar')), findsNothing);
          final reopened = WorkspaceController(
            store: f.store,
            defaults: WorkspaceDocument(groups: [['bar']]),
          );
          addTearDown(reopened.dispose);
          await reopened.load();
          expect(reopened.state.document.groups, expected);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'hidden calendar center, gutter, feedback origin and unknown data reject',
    (tester) async {
      final f = await mount(
        tester,
        document: WorkspaceDocument(groups: [['bar']]),
        heights: {
          'bar': ValueNotifier(100.0),
          'calendar': ValueNotifier(100.0),
        },
        editing: true,
        reduceMotion: true,
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byKey(const Key('workspace_group_bar')));
      final edge = Offset(bar.left + 8, bar.center.dy);
      for (final point in [
        bar.center,
        Offset(bar.right + 6, bar.center.dy),
        // Feedback origin lies in the left edge region, but the actual pointer
        // is 80/52 further inside the card and must be classified as central.
        Offset(bar.left + bar.width * .2 + 80, bar.top + bar.height / 4 + 52),
        const Offset(-10, -10),
      ]) {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_add_calendar'))),
        );
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pumpAndSettle();
        await gesture.moveTo(point);
        await tester.pump(const Duration(milliseconds: 650));
        expect(find.byKey(const Key('workspace_insert_left')), findsNothing);
        expect(find.byKey(const Key('workspace_insert_right')), findsNothing);
        expect(find.text('松开合并为堆叠'), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(f.actions, isEmpty);
        expect(f.store.patches, isEmpty);
        expect(starts, {'bar': 1});
      }
      final target = groupTarget(tester, 'bar');
      expect(
        target.onWillAcceptWithDetails!(dropDetails(['not-registered'], edge)),
        isFalse,
      );
      target.onAcceptWithDetails!(dropDetails(['not-registered'], edge));
      await tester.pump();
      expect(f.actions, isEmpty);
      expect(f.store.patches, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final change in ['width', 'content', 'document', 'readonly']) {
    testWidgets(
      'hidden calendar old $change intent cannot commit and fresh drag recovers',
      (tester) async {
        final f = await mount(
          tester,
          document: WorkspaceDocument(groups: [['bar']]),
          heights: {
            'bar': ValueNotifier(100.0),
            'calendar': ValueNotifier(100.0),
          },
          editing: true,
          reduceMotion: true,
        );
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_add_calendar'))),
        );
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pumpAndSettle();
        final bar = tester.getRect(find.byKey(const Key('workspace_group_bar')));
        final oldPoint = Offset(bar.left + 8, bar.center.dy);
        await gesture.moveTo(oldPoint);
        await tester.pump();
        expect(find.byKey(const Key('workspace_insert_left')), findsOneWidget);
        if (change == 'width') {
          tester.view.physicalSize = const Size(1000, 2200);
        } else if (change == 'content') {
          f.changeContent();
        } else if (change == 'document') {
          await f.controller.setSize('bar', WorkspaceSize.twoByThree);
        } else {
          f.setCanEdit(false);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('workspace_insert_left')), findsNothing);
        final writes = f.store.patches.length;
        // Stress the release callback after the new generation has settled.
        // It must not reconstruct a canceled hover on release alone.
        groupTarget(tester, 'bar').onAcceptWithDetails!(
          dropDetails(['calendar'], oldPoint),
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(f.actions, isEmpty);
        expect(f.store.patches, hasLength(writes));
        expect(starts, {'bar': 1});
        if (change == 'readonly') {
          f.setCanEdit(true);
          await tester.pumpAndSettle();
        }
        final fresh = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_add_calendar'))),
        );
        await fresh.moveBy(const Offset(-30, 0));
        await tester.pumpAndSettle();
        final current = tester.getRect(
          find.byKey(const Key('workspace_group_bar')),
        );
        await fresh.moveTo(Offset(current.left + 8, current.center.dy));
        await tester.pump();
        expect(find.byKey(const Key('workspace_insert_left')), findsOneWidget);
        await fresh.up();
        await tester.pumpAndSettle();
        expect(f.actions, hasLength(1));
        expect(f.controller.state.document.groups, [['calendar'], ['bar']]);
        expect(starts, {'bar': 1, 'calendar': 1});
        expect(disposals, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('hidden calendar release requires currently ready geometry', (
    tester,
  ) async {
    final f = await mount(
      tester,
      document: WorkspaceDocument(groups: [['bar']]),
      heights: {
        'bar': ValueNotifier(100.0),
        'calendar': ValueNotifier(100.0),
      },
      editing: true,
      reduceMotion: true,
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('workspace_add_calendar'))),
    );
    await gesture.moveBy(const Offset(-30, 0));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byKey(const Key('workspace_group_bar')));
    final point = Offset(bar.left + 8, bar.center.dy);
    await gesture.moveTo(point);
    await tester.pump();
    expect(find.byKey(const Key('workspace_insert_left')), findsOneWidget);
    final barTarget = find.byKey(const Key('workspace_group_bar'));
    final surface = tester.renderObject<RenderBox>(barTarget);
    // The DropSurface is a direct render child of the measurement canvas.
    // Locate its actual widget ancestor and verify the render relationship
    // rather than relying on a tight business leaf to propagate invalidation.
    final canvasWidget = find.ancestor(
      of: barTarget,
      matching: find.byWidgetPredicate(
        (widget) => widget is MultiChildRenderObjectWidget,
      ),
    ).first;
    final canvas = tester.renderObject<RenderBox>(canvasWidget);
    expect(surface.parent, same(canvas));
    expect(f.host.currentState!.geometry, isNotNull);
    canvas.markNeedsLayout();
    expect(f.host.currentState!.geometry, isNull);
    final target = groupTarget(tester, 'bar');
    target.onAcceptWithDetails!(dropDetails(['calendar'], point));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(f.actions, isEmpty);
    expect(f.store.patches, isEmpty);
    expect(starts, {'bar': 1});
    expect(f.host.currentState!.geometry, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'too-small single-member hole rejects taller navigation at both ends',
    (tester) async {
      final original = [
        ['a'],
        ['natural'],
        ['moving', 'mate'],
      ];
      final f = await mount(
        tester,
        document: WorkspaceDocument(
          groups: original,
          sizes: {'natural': WorkspaceSize.fullNatural},
        ),
        heights: {
          for (final id in original.expand((g) => g))
            id: ValueNotifier(id == 'natural' ? 320 : 100),
        },
        editing: true,
        reduceMotion: true,
      );
      await tester.pumpAndSettle();
      final hole = tester.getRect(find.byKey(const Key('workspace_slot_0')));
      final moving = f.host.currentState!.geometry!.groups[2];
      expect(moving.height, greaterThan(hole.height));
      for (final y in [hole.top + 5, hole.bottom - 5]) {
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('workspace_handle_moving'))),
        );
        await drag.moveBy(const Offset(20, 0));
        await tester.pump();
        await drag.moveTo(Offset(hole.left + hole.width / 4, y));
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.text('放到这个位置'), findsNothing);
        await drag.up();
        await tester.pumpAndSettle();
        expect(f.actions, isEmpty);
        expect(f.store.patches, isEmpty);
        expect(f.controller.state.document.groups, original);
        expect(starts, {'a': 1, 'natural': 1, 'moving': 1, 'mate': 1});
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pointer moves reuse projection but revision cancels old dwell', (
    tester,
  ) async {
    final f = await mount(
      tester,
      document: WorkspaceDocument(
        groups: [
          ['a'],
          ['b'],
        ],
      ),
      heights: {'a': ValueNotifier(100), 'b': ValueNotifier(100)},
      editing: true,
      reduceMotion: true,
    );
    await tester.pumpAndSettle();
    final target = tester.getRect(find.byKey(const Key('workspace_group_a')));
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('workspace_handle_b'))),
    );
    await drag.moveBy(const Offset(20, 0));
    await tester.pumpAndSettle();
    final computations = f.host.currentState!.holeProjectionComputations;
    for (var i = 0; i < 5; i++) {
      await drag.moveTo(Offset(target.left + 8 + i, target.center.dy));
      await tester.pump();
    }
    expect(f.host.currentState!.holeProjectionComputations, computations);
    await drag.moveTo(target.center);
    await tester.pump(const Duration(milliseconds: 400));
    f.changeContent();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('松开合并为堆叠'), findsNothing);
    expect(
      f.host.currentState!.holeProjectionComputations,
      greaterThan(computations),
    );
    final afterContent = f.host.currentState!.holeProjectionComputations;
    tester.view.physicalSize = const Size(1000, 2200);
    f.setScale(2);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(
      f.host.currentState!.holeProjectionComputations,
      greaterThan(afterContent),
    );
    expect(find.text('松开合并为堆叠'), findsNothing);
    final afterWidth = f.host.currentState!.holeProjectionComputations;
    f.setViewport(420);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      f.host.currentState!.holeProjectionComputations,
      greaterThan(afterWidth),
    );
    expect(find.text('松开合并为堆叠'), findsNothing);
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(f.actions, isEmpty);
    expect(f.store.patches, isEmpty);
    expect(starts, {'a': 1, 'b': 1});
    expect(disposals, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'narrow shelf overlay dismiss keeps lease and viewport scale $scale',
      (tester) async {
        final f = await mount(
          tester,
          width: 480,
          document: WorkspaceDocument(
            groups: [
              ['a'],
            ],
          ),
          heights: {'a': ValueNotifier(860), 'hidden': ValueNotifier(100)},
          descriptorSizes: {'a': WorkspaceSize.fullNatural},
          shelfOpen: true,
          viewportHeight: 360,
        );
        f.setScale(scale);
        await tester.pumpAndSettle();
        final input = tester.element(find.byKey(const Key('field-a')));
        final close = find.byKey(const Key('workspace_dismiss_shelf'));
        expect(tester.getSize(close), const Size(48, 48));
        final hostRect = tester.getRect(find.byType(WorkspaceHost));
        expect(hostRect.width, 480);
        expect(hostRect.height, 360);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('workspace_right_viewport')), findsNothing);
        expect(tester.element(find.byKey(const Key('field-a'))), same(input));
        expect(starts, {'a': 1});
        expect(disposals, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('finite independent shelf stays reachable after left scroll', (
    tester,
  ) async {
    final f = await mount(
      tester,
      document: WorkspaceDocument(
        groups: [
          ['a'],
        ],
      ),
      heights: {
        'a': ValueNotifier(860),
        for (var i = 0; i < 12; i++) 'hidden$i': ValueNotifier(100),
      },
      descriptorSizes: {'a': WorkspaceSize.fullNatural},
      editing: true,
      shelfOpen: true,
      viewportHeight: 300,
    );
    await tester.pumpAndSettle();
    final left = find.byKey(const Key('workspace_left_viewport'));
    final right = find.byKey(const Key('workspace_right_viewport'));
    final shelfBefore = tester.getRect(right);
    await tester.drag(left, const Offset(0, -550));
    await tester.pumpAndSettle();
    expect(f.host.currentState!.leftScrollOffset, greaterThan(400));
    expect(tester.getRect(right), shelfBefore);
    final leftOffset = f.host.currentState!.leftScrollOffset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(right),
        scrollDelta: const Offset(0, 280),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.host.currentState!.rightScrollOffset, greaterThan(0));
    expect(f.host.currentState!.leftScrollOffset, leftOffset);
    expect(starts, {'a': 1});
    expect(disposals, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('first natural shelf append creates only one business lease', (
    tester,
  ) async {
    final f = await mount(
      tester,
      document: WorkspaceDocument(
        groups: [
          ['a'],
        ],
        sizes: {'a': WorkspaceSize.oneByOne},
      ),
      heights: {'a': ValueNotifier(100), 'hidden': ValueNotifier(860)},
      descriptorSizes: {'hidden': WorkspaceSize.fullNatural},
      editing: true,
      shelfOpen: true,
      viewportHeight: 350,
    );
    await tester.pumpAndSettle();
    expect(starts, {'a': 1});
    final drag = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('workspace_add_hidden'))),
    );
    await drag.moveBy(const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(starts, {'a': 1});
    final append = find.byKey(const Key('workspace_semantic_append'));
    expect(tester.getSize(append).height, 48);
    await drag.moveTo(tester.getCenter(append));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(f.controller.state.document.groups, [
      ['a'],
      ['hidden'],
    ]);
    expect(starts, {'a': 1, 'hidden': 1});
    expect(disposals, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final entry in ['handle', 'card', 'shelf']) {
    for (final mode in ['glass', 'opaque', 'contrast', 'absent']) {
      testWidgets(
        'real $entry drag captures source theme policy container and paint $mode',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final outer = ProviderContainer(
            overrides: [_feedbackIdentity.overrideWithValue('outer')],
          );
          final original = ProviderContainer(
            overrides: [_feedbackIdentity.overrideWithValue('source')],
          );
          addTearDown(outer.dispose);
          addTearDown(original.dispose);
          final scheme = ColorScheme.fromSeed(seedColor: Colors.orange);
          final policy = mode == 'absent'
              ? null
              : MaterialPolicy.resolve(
                  colorScheme: scheme,
                  wallpaper: mode == 'glass'
                      ? WallpaperLoadState.ready
                      : WallpaperLoadState.absent,
                  signals: MaterialSignals(
                    highContrast: mode == 'contrast'
                        ? AccessibilitySignal.enabled
                        : AccessibilitySignal.disabled,
                    reduceTransparency: mode == 'opaque'
                        ? AccessibilitySignal.enabled
                        : AccessibilitySignal.disabled,
                  ),
                );
          final expectedFill = policy?.contentSurface ?? scheme.surface;
          final seen = <WorkspaceSize>[];
          var hiddenBusiness = 0;
          final actions = <WorkspaceAction>[];
          final host = SingleChildScrollView(
            child: WorkspaceHost(
              document: WorkspaceDocument(
                groups: [
                  ['a'],
                ],
                sizes: {
                  'a': WorkspaceSize.twoByTwo,
                  'hidden': WorkspaceSize.twoByThree,
                },
              ),
              editing: true,
              shelfOpen: true,
              registry: {
                for (final id in ['a', 'hidden'])
                  id: WorkspaceDescriptor(
                    id: id,
                    label: id == 'a' ? '活动' : '隐藏',
                    contentBuilder: (_, _) {
                      if (id == 'hidden') {
                        hiddenBusiness++;
                        throw StateError('hidden business built');
                      }
                      return const SizedBox(
                        key: Key('captured-card-body'),
                        height: 100,
                      );
                    },
                    thumbnailBuilder: (_) =>
                        throw StateError('size callback lost'),
                    thumbnailForSize: (context, size) {
                      expect(
                        ProviderScope.containerOf(context, listen: false),
                        same(original),
                      );
                      expect(
                        ProviderScope.containerOf(
                          context,
                          listen: false,
                        ).read(_feedbackIdentity),
                        'source',
                      );
                      expect(Theme.of(context).colorScheme, scheme);
                      expect(
                        MaterialScope.maybeOf(context)?.policy,
                        same(policy),
                      );
                      // Record feedback callbacks, not subsequent shelf rebuilds.
                      // Source context assertions above still run on every call.
                      if (context
                              .findAncestorWidgetOfExactType<Material>()
                              ?.key ==
                          const Key('workspace_drag_preview_surface'))
                        seen.add(size);
                      return RepaintBoundary(
                        key: ValueKey('captured-paint-$id'),
                        child: ColoredBox(
                          color:
                              MaterialScope.maybeOf(
                                context,
                              )?.policy.contentSurface ??
                              Theme.of(context).colorScheme.surface,
                        ),
                      );
                    },
                  ),
              },
              onAction: actions.add,
            ),
          );
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: outer,
              child: MaterialApp(
                theme: ThemeData(
                  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
                ),
                home: Scaffold(
                  body: UncontrolledProviderScope(
                    container: original,
                    child: Theme(
                      data: ThemeData(colorScheme: scheme),
                      child: policy == null
                          ? host
                          : MaterialScope(
                              policy: policy,
                              tokens: MaterialTokens.forWidth(1200),
                              child: host,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final target = find.byKey(
            Key(
              entry == 'handle'
                  ? 'workspace_handle_a'
                  : entry == 'card'
                  ? 'captured-card-body'
                  : 'workspace_add_hidden',
            ),
          );
          final start = tester.getCenter(target);
          final gesture = await tester.startGesture(start);
          if (entry == 'card')
            await tester.pump(const Duration(milliseconds: 650));
          const delta = Offset(60, 30);
          await gesture.moveBy(delta);
          await tester.pump();
          final feedback = find.byKey(
            const Key('workspace_drag_preview_surface'),
          );
          expect(feedback, findsOneWidget);
          expect(tester.getSize(feedback), const Size(160, 104));
          final origin = tester.getTopLeft(feedback);
          expect(origin.dx, closeTo(start.dx + delta.dx - 80, .001));
          expect(origin.dy, closeTo(start.dy + delta.dy - 52, .001));
          final id = entry == 'shelf' ? 'hidden' : 'a';
          final paint = find.descendant(
            of: feedback,
            matching: find.byKey(ValueKey('captured-paint-$id')),
          );
          expect(paint, findsOneWidget);
          final context = tester.element(paint);
          expect(
            ProviderScope.containerOf(context, listen: false),
            same(original),
          );
          expect(MaterialScope.maybeOf(context)?.policy, same(policy));
          expect(Theme.of(context).colorScheme, scheme);
          final actualSize = tester.getSize(paint);
          expect(actualSize.width, greaterThan(0));
          expect(actualSize.height, greaterThan(0));
          expect(
            seen.last.sameExtent(
              entry == 'shelf'
                  ? WorkspaceSize.twoByThree
                  : WorkspaceSize.twoByTwo,
            ),
            isTrue,
          );
          final boundary = tester.renderObject<RenderRepaintBoundary>(paint);
          final rgba = (await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final center =
                  ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
              return [for (var i = 0; i < 4; i++) bytes.getUint8(center + i)];
            } finally {
              image.dispose();
            }
          }))!;
          expect(
            rgba[0],
            closeTo((expectedFill.r * expectedFill.a * 255).round(), 1),
          );
          expect(
            rgba[1],
            closeTo((expectedFill.g * expectedFill.a * 255).round(), 1),
          );
          expect(
            rgba[2],
            closeTo((expectedFill.b * expectedFill.a * 255).round(), 1),
          );
          expect(rgba[3], closeTo((expectedFill.a * 255).round(), 1));
          await gesture.cancel();
          await tester.pumpAndSettle();
          expect(hiddenBusiness, 0);
          expect(actions, isEmpty);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'independent 48dp size menu saves supported XL and reopens without touching group',
    (tester) async {
      final f = await mount(
        tester,
        editing: true,
        document: WorkspaceDocument(
          groups: [
            ['a'],
          ],
        ),
        heights: {'a': ValueNotifier(120)},
        supported: {
          'a': [WorkspaceSize.oneByOne, WorkspaceSize.twoByThree],
        },
      );
      final resize = find.byKey(const Key('workspace_resize_a'));
      expect(tester.getSize(resize), const Size(48, 48));
      await tester.tap(find.byKey(const Key('workspace_handle_a')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_resize_a_XL')), findsNothing);
      await tester.tap(find.byKey(const Key('workspace_handle_a')));
      await tester.pumpAndSettle();
      await tester.tap(resize);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workspace_resize_a_S')), findsOneWidget);
      expect(find.byKey(const Key('workspace_resize_a_M')), findsNothing);
      await tester.tap(find.byKey(const Key('workspace_resize_a_XL')));
      await tester.pumpAndSettle();
      expect(f.controller.state.document.groups, [
        ['a'],
      ]);
      expect(
        f.controller.state.document.sizes['a']!.sameExtent(
          WorkspaceSize.twoByThree,
        ),
        isTrue,
      );
      final reopened = WorkspaceController(
        store: f.store,
        defaults: WorkspaceDocument(
          groups: [
            ['a'],
          ],
        ),
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(
        reopened.state.document.sizes['a']!.sameExtent(
          WorkspaceSize.twoByThree,
        ),
        isTrue,
      );
      expect(starts, {'a': 1});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Chinese same-label target selection uses ID, cancel and stale target never mutate',
    (tester) async {
      final f = await mount(
        tester,
        editing: true,
        document: WorkspaceDocument(
          groups: [
            ['a'],
            ['b'],
            ['c'],
          ],
        ),
        heights: {
          'a': ValueNotifier(120),
          'b': ValueNotifier(120),
          'c': ValueNotifier(120),
        },
        labels: {'a': '源组件', 'b': '相同名称', 'c': '相同名称'},
      );
      Future<void> open() async {
        await tester.tap(find.byKey(const Key('workspace_handle_a')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义堆叠…'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('相同名称'), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('workspace_stack_cancel')));
      await tester.pumpAndSettle();
      expect(f.actions, isEmpty);
      await open();
      await f.controller.perform(
        WorkspaceAction(WorkspaceActionKind.hide, drag: WorkspaceDrag(['b'])),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('workspace_stack_target_b')));
      await tester.pumpAndSettle();
      expect(f.actions, isEmpty);
      expect(f.controller.state.document.groups, [
        ['a'],
        ['c'],
      ]);
      await open();
      await tester.tap(find.byKey(const Key('workspace_stack_target_c')));
      await tester.pumpAndSettle();
      expect(f.controller.state.document.groups, [
        ['c', 'a'],
      ]);
      expect(f.actions.single.drag!.members, ['a']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'thumbnail size callback receives all spans and legacy fallback paints nonzero',
    (tester) async {
      final seen = <WorkspaceSize>[];
      final aware = WorkspaceDescriptor(
        id: 'aware',
        label: '缩略图',
        contentBuilder: (_, _) =>
            throw StateError('business preview forbidden'),
        thumbnailBuilder: (_) => throw StateError('legacy should not run'),
        thumbnailForSize: (_, size) {
          seen.add(size);
          return const ColoredBox(color: Colors.red);
        },
      );
      final legacy = WorkspaceDescriptor(
        id: 'legacy',
        label: '旧接口',
        contentBuilder: (_, _) =>
            throw StateError('business preview forbidden'),
        thumbnailBuilder: (_) => const ColoredBox(color: Colors.blue),
      );
      for (final size in WorkspaceSize.values) {
        for (final budget in [const Size(160, 104), const Size(56, 48)]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: budget.width,
                  height: budget.height,
                  child: WorkspaceThumbnail(descriptor: aware, size: size),
                ),
              ),
            ),
          );
          final frame = tester.getSize(
            find.byKey(
              ValueKey(
                'workspace_thumbnail_frame_aware_${workspaceSizeName(size)}',
              ),
            ),
          );
          expect(frame.width, greaterThan(0));
          expect(frame.height, greaterThan(0));
          expect(frame.width, lessThanOrEqualTo(budget.width));
          expect(frame.height, lessThanOrEqualTo(budget.height));
          expect(
            tester.getSize(
              find.byWidgetPredicate(
                (w) => w is ColoredBox && w.color == Colors.red,
              ),
            ),
            frame,
          );
          if (size.sameExtent(WorkspaceSize.twoByTwo) ||
              size.sameExtent(WorkspaceSize.oneByOne))
            expect(frame.aspectRatio, closeTo(1, .001));
          expect(seen.last.sameExtent(size), isTrue);
        }
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 160,
              height: 104,
              child: WorkspaceThumbnail(
                descriptor: legacy,
                size: WorkspaceSize.twoByTwo,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(
          find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == Colors.blue,
          ),
        ),
        const Size(104, 104),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'custom stack empty state writes nothing and full group selection preserves order',
    (tester) async {
      final f = await mount(
        tester,
        editing: true,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b'],
          ],
        ),
        heights: {
          'a': ValueNotifier(120),
          'b': ValueNotifier(120),
          'c': ValueNotifier(120),
        },
        labels: {'a': '甲', 'b': '乙', 'c': '丙'},
      );
      Future<void> open() async {
        await tester.tap(find.byKey(const Key('workspace_handle_a')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义堆叠…'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('没有可堆叠的组件'), findsOneWidget);
      expect(find.byKey(const Key('workspace_stack_target_c')), findsNothing);
      await tester.tap(find.byKey(const Key('workspace_stack_cancel')));
      await tester.pumpAndSettle();
      expect(f.actions, isEmpty);
      await f.controller.perform(
        WorkspaceAction(WorkspaceActionKind.reveal, id: 'c'),
      );
      await tester.pumpAndSettle();
      await open();
      await tester.tap(find.byKey(const Key('workspace_stack_target_c')));
      await tester.pumpAndSettle();
      expect(f.actions.single.drag!.members, ['a', 'b']);
      expect(f.controller.state.document.groups, [
        ['c', 'a', 'b'],
      ]);
      expect(starts, {'a': 1, 'b': 1, 'c': 1});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wide short side shelf scroll preserves whole group hide and 48dp reveal',
    (tester) async {
      final fixture = await mount(
        tester,
        width: 800,
        editing: true,
        reduceMotion: true,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b'],
            ['c'],
          ],
        ),
        heights: {
          'a': ValueNotifier(100.0),
          'b': ValueNotifier(100.0),
          'c': ValueNotifier(100.0),
          'hidden': ValueNotifier(100.0),
        },
      );
      final shelf = find.byKey(const Key('workspace_component_shelf'));
      final rect = tester.getRect(shelf);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('workspace_handle_a'))),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(Offset(rect.left + 24, rect.top + 24));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(fixture.controller.state.document.groups, [
        ['c'],
      ]);
      expect(fixture.actions.last.kind, WorkspaceActionKind.hide);
      expect(fixture.actions.last.drag!.members, ['a', 'b']);
      final reveal = find.byKey(const Key('workspace_add_hidden'));
      await tester.ensureVisible(reveal);
      await tester.pump();
      final size = tester.getSize(reveal);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(reveal.hitTestable(), findsOneWidget);
      await tester.tap(reveal);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(fixture.controller.state.document.groups.last, ['hidden']);
      expect(starts['a'], 1);
      expect(starts['b'], 1);
      expect(disposals, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'actual selected projection excludes inactive hidden shelf and unknown IDs',
    (tester) async {
      final seen = <String, Set<String>>{};
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var document = WorkspaceDocument(
        groups: [
          ['a', 'b'],
          ['foreign'],
        ],
        sizes: {'a': WorkspaceSize.twoByTwo, 'b': WorkspaceSize.twoByTwo},
      );
      String? focus;
      var revision = 0, shelf = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SingleChildScrollView(
                  child: WorkspaceHost(
                    document: document,
                    shelfOpen: shelf,
                    focusId: focus,
                    focusRevision: revision,
                    registry: {
                      for (final id in ['a', 'b', 'hidden'])
                        id: WorkspaceDescriptor(
                          id: id,
                          label: id,
                          thumbnailBuilder: (_) => const SizedBox(),
                          contentBuilder: (_, layout) {
                            seen[id] = layout.visibleIds;
                            return Text(id);
                          },
                        ),
                    },
                    onAction: (_) {},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(seen['a'], {'a'});
      expect(seen['b'], {'a'});
      expect(seen.containsKey('hidden'), isFalse);
      expect(() => seen['a']!.add('mutation'), throwsUnsupportedError);
      await select(tester, 'b');
      expect(seen['a'], {'b'});
      expect(seen['b'], {'b'});
      rebuild(() {
        focus = 'a';
        revision++;
      });
      await tester.pump();
      expect(seen['a'], {'a'});
      rebuild(() {
        document = WorkspaceDocument(
          groups: [
            ['foreign'],
          ],
        );
      });
      await tester.pump();
      expect(seen['a'], isEmpty);
      expect(seen['b'], isEmpty);
      rebuild(() {
        document = WorkspaceDocument(
          groups: [
            ['b'],
          ],
        );
        shelf = false;
      });
      await tester.pump();
      expect(seen['b'], {'b'});
      expect(seen['a'], {'b'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shelf uses persisted size and whole group feedback includes unknown max span',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a', 'foreign'],
          ],
          sizes: {
            'a': WorkspaceSize.oneByOne,
            'foreign': WorkspaceSize.twoByThree,
            'hidden': WorkspaceSize.twoByThree,
          },
        ),
        heights: {'a': ValueNotifier(100.0), 'hidden': ValueNotifier(100.0)},
        descriptorSizes: {
          'a': WorkspaceSize.oneByOne,
          'hidden': WorkspaceSize.oneByOne,
        },
        editing: true,
        shelfOpen: true,
        reduceMotion: true,
      );
      final hiddenSize = find.byKey(const ValueKey('workspace_size_hidden'));
      expect(
        find.descendant(of: hiddenSize, matching: find.text('XL')),
        findsOneWidget,
      );
      expect(starts, {'a': 1});
      final handle = find.byKey(const ValueKey('workspace_handle_a'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(120, 60));
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('workspace_drag_preview_surface'))),
        const Size(160, 104),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('workspace_drag_size')),
          matching: find.text('XL'),
        ),
        findsOneWidget,
      );
      expect(find.text('2 个组件'), findsOneWidget);
      await gesture.cancel();
      await tester.pump();
      expect(fixture.controller.state.document.groups, [
        ['a', 'foreign'],
      ]);
      expect(fixture.actions, isEmpty);
      expect(starts, {'a': 1});
      await tester.tap(find.byKey(const Key('workspace_resize_a')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.textContaining('整行随内容高度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'browsing shelf drag enables temporary targets then restores browsing',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a'],
          ],
        ),
        heights: {'a': ValueNotifier(100.0), 'hidden': ValueNotifier(100.0)},
        shelfOpen: true,
        reduceMotion: true,
      );
      expect(starts, {'a': 1});
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace_add_hidden'))),
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace_handle_a')), findsOneWidget);
      expect(starts, {'a': 1});
      final group = tester.getRect(
        find.byKey(const ValueKey('workspace_group_a')),
      );
      await gesture.moveTo(Offset(group.left + 8, group.center.dy));
      await tester.pump();
      expect(fixture.actions, isEmpty);
      expect(starts, {'a': 1});
      await gesture.moveTo(
        tester.getCenter(find.byKey(const Key('workspace_semantic_append'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(fixture.controller.state.document.groups, [
        ['a'],
        ['hidden'],
      ]);
      expect(fixture.editing, isFalse);
      expect(fixture.shelfOpen, isTrue);
      expect(find.byKey(const ValueKey('workspace_handle_a')), findsNothing);
      expect(starts, {'a': 1, 'hidden': 1});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'long press moves the complete stack using one content lease per member',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b'],
            ['c'],
          ],
        ),
        heights: {
          'a': ValueNotifier(100.0),
          'b': ValueNotifier(100.0),
          'c': ValueNotifier(100.0),
        },
        editing: true,
        reduceMotion: true,
      );
      final source = tester.getRect(
        find.byKey(const ValueKey('workspace_group_a')),
      );
      final gesture = await tester.startGesture(source.center);
      await tester.pump(const Duration(milliseconds: 550));
      final target = tester.getRect(
        find.byKey(const ValueKey('workspace_group_c')),
      );
      await gesture.moveTo(Offset(target.right - 8, target.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(fixture.controller.state.document.groups, [
        ['c'],
        ['a', 'b'],
      ]);
      expect(starts, {'a': 1, 'b': 1, 'c': 1});
      expect(disposals, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'all natural pages measured on first layout; short→860, resize, scale and growth keep one dirty instance',
    (tester) async {
      final heights = {
        'short': ValueNotifier(120.0),
        'long': ValueNotifier(860.0),
        'next': ValueNotifier(100.0),
      };
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['short', 'long'],
            ['next'],
          ],
          sizes: {
            'short': WorkspaceSize.fullNatural,
            'long': WorkspaceSize.fullNatural,
          },
        ),
        heights: heights,
      );
      final initial = fixture.host.currentState!.geometry!;
      expect(initial.contents[0].height, 860);
      expect(initial.groups[1].top, initial.groups[0].bottom + 16);
      expect(starts, {'short': 1, 'long': 1, 'next': 1});
      await select(tester, 'long');
      expect(
        fixture.host.currentState!.geometry!.groups[1].top,
        initial.groups[1].top,
      );
      await tester.enterText(
        find.byKey(const ValueKey('field-long')),
        'dirty synthetic text',
      );
      await select(tester, 'short');
      await select(tester, 'long');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('field-long')))
            .controller!
            .text,
        'dirty synthetic text',
      );
      tester.view.physicalSize = const Size(480, 2200);
      await tester.pump();
      final narrow = fixture.host.currentState!.geometry!;
      expect(narrow.contents[0].height, 940);
      expect(narrow.groups[1].top, narrow.groups[0].bottom + 16);
      fixture.setScale(2);
      await tester.pump();
      final scaled = fixture.host.currentState!.geometry!;
      expect(scaled.contents[0].height, 1800);
      heights['long']!.value = 1000;
      fixture.changeContent();
      await tester.pump();
      final grown = fixture.host.currentState!.geometry!;
      expect(grown.contents[0].height, 2080);
      expect(grown.groups[1].top, grown.groups[0].bottom + 16);
      expect(starts.values.every((value) => value == 1), isTrue);
      expect(disposals, isEmpty);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('field-long')))
            .controller!
            .text,
        'dirty synthetic text',
      );
      expect(tester.takeException(), isNull);
      // A pending layout invalidates public drop geometry rather than exposing old rects.
      tester
          .renderObject<RenderBox>(find.byKey(const ValueKey('body-long')))
          .markNeedsLayout();
      expect(fixture.host.currentState!.geometry, isNull);
      await tester.pump();
      expect(fixture.host.currentState!.geometry!.contents[0].height, 2080);
    },
  );
  for (final width in [480.0, 719.0, 720.0, 1200.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'mixed max span at $width scale$scale stays stable across page switch',
        (tester) async {
          final fixture = await mount(
            tester,
            width: width,
            document: WorkspaceDocument(
              groups: [
                ['a', 'b'],
                ['c'],
              ],
              sizes: {
                'a': WorkspaceSize.oneByOne,
                'b': WorkspaceSize.twoByThree,
                'c': WorkspaceSize.twoByOne,
              },
            ),
            heights: {
              'a': ValueNotifier(80.0),
              'b': ValueNotifier(120.0),
              'c': ValueNotifier(100.0),
            },
          );
          fixture.setScale(scale);
          await tester.pump();
          final before = fixture.host.currentState!.geometry!;
          expect(before.contents.first.height, 324);
          expect(
            before.contents.first.width,
            width < 720 ? width : (width - 12) / 2,
          );
          await select(tester, 'b');
          final after = fixture.host.currentState!.geometry!;
          expect(after.groups, before.groups);
          expect(starts.values.every((value) => value == 1), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets(
    'thumbnail only library and preview never mount hidden business content',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a'],
          ],
        ),
        heights: {'a': ValueNotifier(100.0), 'hidden': ValueNotifier(100.0)},
        editing: true,
      );
      expect(starts, {'a': 1});
      expect(thumbnails['hidden'], greaterThan(0));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace_add_hidden'))),
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(starts, {'a': 1});
      expect(find.byType(RawImage), findsNothing);
      await gesture.moveTo(const Offset(-20, -20));
      await gesture.up();
      await tester.pump();
      expect(fixture.actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final dwell in [false, true]) {
    testWidgets(
      'center dwell ${dwell ? 'after600 merges' : 'before600 places'} whole group',
      (tester) async {
        final fixture = await mount(
          tester,
          document: WorkspaceDocument(
            groups: [
              ['a', 'b'],
              ['target'],
            ],
          ),
          heights: {
            'a': ValueNotifier(100.0),
            'b': ValueNotifier(100.0),
            'target': ValueNotifier(100.0),
          },
          editing: true,
          reduceMotion: true,
        );
        final target = tester.getRect(
          find.byKey(const ValueKey('workspace_group_target')),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('workspace_handle_a'))),
        );
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
        await gesture.moveTo(target.center);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 590));
        expect(find.text('松开合并为堆叠'), findsNothing);
        if (dwell) {
          await tester.pump(const Duration(milliseconds: 20));
          expect(find.text('松开合并为堆叠'), findsOneWidget);
        }
        await gesture.up();
        await tester.pump();
        await tester.pump();
        expect(
          fixture.actions.last.kind,
          dwell ? WorkspaceActionKind.stack : WorkspaceActionKind.place,
        );
        expect(fixture.actions.last.drag!.members, ['a', 'b']);
        expect(
          fixture.controller.state.document.groups,
          dwell
              ? [
                  ['target', 'a', 'b'],
                ]
              : [
                  ['target'],
                  ['a', 'b'],
                ],
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('gap/self/outside and moved-away dwell have no writes', (
    tester,
  ) async {
    final fixture = await mount(
      tester,
      document: WorkspaceDocument(
        groups: [
          ['a'],
          ['target'],
        ],
      ),
      heights: {'a': ValueNotifier(100.0), 'target': ValueNotifier(100.0)},
      editing: true,
      reduceMotion: true,
    );
    final source = tester.getCenter(
          find.byKey(const ValueKey('workspace_handle_a')),
        ),
        target = tester.getRect(
          find.byKey(const ValueKey('workspace_group_target')),
        ),
        own = tester.getRect(find.byKey(const ValueKey('workspace_group_a')));
    for (final drop in [
      own.center,
      Offset(own.right + 6, own.center.dy),
      const Offset(-10, -10),
    ]) {
      final gesture = await tester.startGesture(source);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(target.center);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(drop);
      await tester.pump(const Duration(milliseconds: 650));
      expect(find.text('松开合并为堆叠'), findsNothing);
      await gesture.up();
      await tester.pump();
    }
    expect(fixture.actions, isEmpty);
    expect(fixture.store.patches, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'slot upper/lower use same index and lower append uses final boundary',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a'],
            ['natural'],
            ['moving', 'mate'],
          ],
          sizes: {
            'natural': WorkspaceSize.fullNatural,
            'a': WorkspaceSize.twoByThree,
          },
        ),
        heights: {
          'a': ValueNotifier(100.0),
          'natural': ValueNotifier(320.0),
          'moving': ValueNotifier(100.0),
          'mate': ValueNotifier(100.0),
        },
        editing: true,
        reduceMotion: true,
      );
      final slot = tester.getRect(
        find.byKey(const ValueKey('workspace_slot_0')),
      );
      expect(
        fixture.host.currentState!.geometry!.slots.first.insertionIndex,
        1,
      );
      for (final y in [slot.top + 5, slot.bottom - 5]) {
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(const ValueKey('workspace_handle_moving')),
          ),
        );
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
        await gesture.moveTo(Offset(slot.left + slot.width / 4, y));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        await tester.pump();
        expect(fixture.actions.last.index, 1);
        expect(fixture.controller.state.document.groups[1], ['moving', 'mate']);
        await fixture.controller.placeGroup(
          WorkspaceDrag(['moving', 'mate']),
          3,
        );
        await tester.pump();
      }
      await tester.pump();
      final append = tester.getRect(
        find.byKey(const Key('workspace_semantic_append')),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace_handle_a'))),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(Offset(append.center.dx, append.bottom - 4));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(fixture.actions.last.index, 3);
      expect(fixture.controller.state.document.groups.last, ['a']);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'hide/reveal/detach/reorder retains dirty state and does not instantiate twice',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b'],
          ],
        ),
        heights: {'a': ValueNotifier(100.0), 'b': ValueNotifier(100.0)},
        reduceMotion: true,
      );
      await tester.enterText(find.byKey(const ValueKey('field-a')), 'retained');
      await fixture.controller.detach('a', 1);
      await tester.pump();
      await fixture.controller.moveGroup(1, -1);
      await tester.pump();
      await fixture.controller.hideGroup(WorkspaceDrag(['a']));
      await tester.pump();
      await fixture.controller.reveal('a');
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('field-a')))
            .controller!
            .text,
        'retained',
      );
      expect(starts, {'a': 1, 'b': 1});
      expect(disposals, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'latest click/focus nonce wins; reduced motion is immediately still',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b', 'c'],
          ],
        ),
        heights: {
          'a': ValueNotifier(100.0),
          'b': ValueNotifier(100.0),
          'c': ValueNotifier(100.0),
        },
      );
      await tester.tap(find.byKey(const ValueKey('workspace_switch_b')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(find.byKey(const ValueKey('workspace_switch_c')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      fixture.focus('a');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('workspace_switch_b')));
      await tester.pump(const Duration(milliseconds: 20));
      fixture.focus('a');
      await tester.pump(const Duration(milliseconds: 100));
      final slides = tester.widgetList<FractionalTranslation>(
        find.byKey(const Key('workspace_stack_slide')),
      );
      expect(slides.first.translation, Offset.zero);
      final rootKey = GlobalKey<WorkspaceHostState>();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SingleChildScrollView(
              child: WorkspaceHost(
                key: rootKey,
                document: WorkspaceDocument(
                  groups: [
                    ['x', 'y'],
                  ],
                ),
                registry: {
                  'x': WorkspaceDescriptor(
                    id: 'x',
                    label: 'X',
                    contentBuilder: (_, _) => const SizedBox(),
                    thumbnailBuilder: (_) => const SizedBox(),
                  ),
                  'y': WorkspaceDescriptor(
                    id: 'y',
                    label: 'Y',
                    contentBuilder: (_, _) => const SizedBox(),
                    thumbnailBuilder: (_) => const SizedBox(),
                  ),
                },
                onAction: (_) {},
                editing: true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('workspace_switch_y')));
      await tester.pump();
      for (final slide in tester.widgetList<FractionalTranslation>(
        find.byKey(const Key('workspace_stack_slide')),
      )) {
        expect(slide.translation, Offset.zero);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'shelf browsing visibility restored after editing and menu actions keyboard accessible',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['a', 'b'],
          ],
        ),
        heights: {
          'a': ValueNotifier(100.0),
          'b': ValueNotifier(100.0),
          'hidden': ValueNotifier(100.0),
        },
        reduceMotion: true,
      );
      expect(find.byKey(const Key('workspace_component_shelf')), findsNothing);
      await tester.tap(find.byKey(const Key('edit')));
      await tester.pump();
      expect(
        find.byKey(const Key('workspace_component_shelf')),
        findsOneWidget,
      );
      final handle = find.byKey(const ValueKey('workspace_handle_a'));
      expect(tester.getSize(handle), const Size(48, 48));
      await tester.tap(handle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('拆为独立组件'), findsOneWidget);
      expect(find.text('XL'), findsNothing); // Sizes have their own control.
      Focus.of(tester.element(find.text('拆为独立组件'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(fixture.controller.state.document.groups, [
        ['b'],
        ['a'],
      ]);
      await tester.tap(find.byKey(const Key('edit')));
      await tester.pump();
      expect(find.byKey(const Key('workspace_component_shelf')), findsNothing);
      expect(fixture.shelfOpen, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unknown descriptor is safe and disposing active dwell/transition cancels callbacks',
    (tester) async {
      final fixture = await mount(
        tester,
        document: WorkspaceDocument(
          groups: [
            ['unknown'],
            ['a', 'b'],
          ],
        ),
        heights: {'a': ValueNotifier(100.0), 'b': ValueNotifier(100.0)},
        editing: true,
      );
      expect(find.text('未安装组件：unknown'), findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace_handle_a'))),
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('workspace_group_unknown'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 700));
      expect(fixture.actions, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}

void _acceptanceUsabilityTests() {
  testWidgets('prefix host keeps extras constraints leases draft and null geometry',
    (tester) async {
      tester.view.physicalSize = const Size(1200,800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final groups = <List<String>>[
        ['calendar'], ['bar','summary'], ['diary'], ['poetry'], ['tasks'],
      ];
      final document = WorkspaceDocument(groups: groups);
      final heights = {
        for (final id in groups.expand((g) => g)) id: ValueNotifier<double>(
          id == 'diary' ? 85 : 120),
      };
      for (final v in heights.values) addTearDown(v.dispose);
      final budget = ValueNotifier<WorkspacePrefixPresentationBudget?>(
        WorkspacePrefixPresentationBudget(prefixGroups:groups.take(3),
          contentHeights:{0:500,1:500},firstFoldExtent:600,
          minimumContentHeight:180));
      addTearDown(budget.dispose);
      const policy = WorkspaceGeometryPolicy(cellHeight:100);
      final key = GlobalKey<WorkspaceHostState>();
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:
        ValueListenableBuilder<WorkspacePrefixPresentationBudget?>(
          valueListenable:budget,builder:(context,value,_) =>
            SizedBox(width:1200,height:600,child:WorkspaceHost(
              key:key,document:document,prefixBudget:value,geometryPolicy:policy,
              viewportHeight:600,onAction:(_) => throw StateError('no fixture writes'),
              registry:{for(final entry in heights.entries)
                entry.key:WorkspaceDescriptor(id:entry.key,label:entry.key,
                  defaultSize:entry.key=='diary' ? WorkspaceSize.fullNatural
                    : entry.key=='poetry' ? WorkspaceSize.twoByOne
                    : entry.key=='tasks' ? WorkspaceSize.twoByThree
                    : WorkspaceSize.twoByTwo,
                  thumbnailBuilder:(_) => const SizedBox(),
                  contentBuilder:(_,layout) => Probe(id:entry.key,height:entry.value),
                )},
            )),
        ))));
      await tester.pumpAndSettle();
      final diary = tester.state<ProbeState>(find.byWidgetPredicate(
        (widget) => widget is Probe && widget.id=='diary'));
      diary.text.value = const TextEditingValue(text:'kept draft',
        selection:TextSelection.collapsed(offset:4));
      final fit = key.currentState!.geometry!;
      expect(fit.groups[3].top,greaterThanOrEqualTo(600));
      expect(fit.contents[2].height,85);
      expect(fit.contents[3].height,policy.heightFor(WorkspaceSize.twoByOne));
      expect(fit.contents[4].height,policy.heightFor(WorkspaceSize.twoByThree));
      heights['diary']!.value = 140;
      await tester.pumpAndSettle();
      final changed = key.currentState!.geometry!;
      expect(changed.contents[2].height,140);
      expect(changed.contents[0].height,lessThan(fit.contents[0].height));
      expect(changed.groups[3].top,greaterThanOrEqualTo(600));
      expect(changed.contents[3].size,fit.contents[3].size);
      budget.value=null;
      await tester.pumpAndSettle();
      final legacy = key.currentState!.geometry!;
      expect(legacy.contents[0].height,policy.heightFor(WorkspaceSize.twoByTwo));
      expect(legacy.contents[3].size,fit.contents[3].size);
      expect(tester.state<ProbeState>(find.byWidgetPredicate(
        (widget)=>widget is Probe && widget.id=='diary')),same(diary));
      expect(diary.text.text,'kept draft');
      expect(diary.text.selection.baseOffset,4);
      expect(key.currentState!.leftScrollOffset,0);
      expect(key.currentState!.rightScrollOffset,0);
      final viewport=find.byKey(const Key('workspace_left_viewport'));
      await tester.drag(viewport,const Offset(0,-600));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('field-tasks')).hitTestable(),findsOneWidget);
      expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds:1));
      await tester.pumpAndSettle();
    });
}
