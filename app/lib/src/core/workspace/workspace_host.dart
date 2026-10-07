import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/foundation.dart' show listEquals;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../material/material.dart';
import 'workspace_model.dart';
import 'workspace_geometry.dart';
import 'workspace_stack_transition.dart';

class WorkspaceContentLayout {
  const WorkspaceContentLayout({
    required this.constraints,
    required this.persistedSize,
    required this.displaySize,
    required this.contentRevision,
    this.visibleIds = const {},
  });
  final BoxConstraints constraints;
  final WorkspaceSize persistedSize, displaySize;
  final Object? contentRevision;
  final Set<String> visibleIds;
}

class WorkspaceDescriptor {
  const WorkspaceDescriptor({
    required this.id,
    required this.label,
    required this.contentBuilder,
    required this.thumbnailBuilder,
    this.thumbnailForSize,
    this.defaultSize = WorkspaceSize.twoByTwo,
    this.supportedSizes = WorkspaceSize.values,
    this.contentRevision,
  });
  final String id, label;
  final WorkspaceSize defaultSize;
  final List<WorkspaceSize> supportedSizes;
  final Widget Function(BuildContext, WorkspaceContentLayout) contentBuilder;
  final WidgetBuilder thumbnailBuilder;
  final Widget Function(BuildContext, WorkspaceSize)? thumbnailForSize;
  final Object? contentRevision;
}

/// Business content and storage are injected. Component leases never change
/// their parent when a group moves, changes page, is hidden, or is revealed.
class WorkspaceHost extends StatefulWidget {
  const WorkspaceHost({
    required this.document,
    required this.registry,
    required this.onAction,
    this.editing = false,
    this.shelfOpen = false,
    this.focusId,
    this.focusRevision = 0,
    this.geometryPolicy = const WorkspaceGeometryPolicy(),
    this.prefixBudget,
    this.viewportHeight,
    this.canEdit = true,
    super.key,
  });
  final WorkspaceDocument document;
  final Map<String, WorkspaceDescriptor> registry;
  final ValueChanged<WorkspaceAction> onAction;
  final bool editing, shelfOpen;
  final String? focusId;
  final int focusRevision;
  final WorkspaceGeometryPolicy geometryPolicy;
  final WorkspacePrefixPresentationBudget? prefixBudget;
  final double? viewportHeight;
  final bool canEdit;
  @override
  State<WorkspaceHost> createState() => WorkspaceHostState();
}

class WorkspaceHostState extends State<WorkspaceHost> {
  final _canvasKey = GlobalKey();
  final _leases = <String, GlobalKey>{};
  final _stages = <String, GlobalKey<WorkspaceStackTransitionState>>{};
  final _mountedIds = <String>{};
  final _selected = <String, String>{};
  int _selectionEpoch = 0;
  bool _shelfDragging = false;
  final _leftScroll = ScrollController();
  final _rightScroll = ScrollController();
  bool _shelfDismissed = false;
  WorkspaceMeasurementSnapshot? _snapshot;
  WorkspaceDrag? _drag;
  String? _dragDocument;
  String? _projectionKey;
  Map<String, int> _holeBoundaries = const {};
  int holeProjectionComputations = 0;
  double get leftScrollOffset =>
      _leftScroll.hasClients ? _leftScroll.offset : 0;
  double get rightScrollOffset =>
      _rightScroll.hasClients ? _rightScroll.offset : 0;
  String get _documentKey => jsonEncode(widget.document.toJson());
  String _layoutKey(double width, double? viewportHeight) => jsonEncode([
    _documentKey,
    width,
    viewportHeight,
    identityHashCode(MaterialScope.maybeOf(context)?.policy),
    widget.geometryPolicy.cellHeight,
    widget.geometryPolicy.gap,
    widget.geometryPolicy.rowGap,
    widget.geometryPolicy.breakpoint,
    if (widget.prefixBudget != null) widget.prefixBudget!.signature,
    _editing,
    MediaQuery.textScalerOf(context).scale(1),
    Directionality.of(context).name,
    for (final group in widget.document.groups)
      [
        group,
        _visible(group),
        for (final id in group)
          [
            id,
            _size(id).colSpan,
            _size(id).rowSpan,
            _size(id).isNatural,
            identityHashCode(widget.registry[id]?.contentRevision),
            widget.registry[id]?.label,
          ],
      ],
  ]);
  bool _publishQueued = false;
  void _measured() {
    if (_publishQueued) return;
    _publishQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publishQueued = false;
      if (!mounted) return;
      final render = _canvasKey.currentContext?.findRenderObject();
      if (render is! _WorkspaceRender ||
          !render.ready ||
          render.snapshot == null)
        return;
      final next = render.snapshot!;
      if (_snapshot?.fingerprint == next.fingerprint &&
          _snapshot?.generation == next.generation)
        return;
      setState(() {
        _snapshot = next;
        _projectionKey = null;
      });
    });
  }

  void _startDrag(WorkspaceDrag drag, {bool shelf = false}) {
    setState(() {
      _drag = drag;
      _dragDocument = _documentKey;
      _projectionKey = null;
      _shelfDragging = shelf;
    });
  }

  void _endDrag() {
    if (mounted)
      setState(() {
        _drag = null;
        _dragDocument = null;
        _projectionKey = null;
        _holeBoundaries = const {};
        _shelfDragging = false;
      });
  }

  bool _appendLegal(WorkspaceDrag drag) =>
      mounted &&
      widget.canEdit &&
      (_dragDocument == null || _dragDocument == _documentKey) &&
      drag.members.every(
        (id) =>
            widget.registry.containsKey(id) ||
            widget.document.groups.any((g) => g.contains(id)),
      );
  bool _measuredDrag(WorkspaceDrag drag) {
    final render = _canvasKey.currentContext?.findRenderObject();
    final snapshot = _snapshot;
    return _appendLegal(drag) &&
        snapshot != null &&
        snapshot.complete &&
        render is _WorkspaceRender &&
        render.ready &&
        render.snapshot?.generation == snapshot.generation &&
        render.snapshot?.fingerprint == snapshot.fingerprint &&
        snapshot.groupOf(drag.members) != null;
  }

  // A shelf item has no moving-group measurement. Only the occupied target
  // needs measurement for a semantic edge insertion; slots and centers still
  // use _measuredDrag and never infer the hidden item's height.
  bool _shelfEdgeLegal(
    WorkspaceDrag drag,
    WorkspaceDropIntent intent,
    int target,
    String fingerprint,
  ) {
    if (intent.central ||
        !_shelfDragging ||
        !_appendLegal(drag) ||
        drag.members.length != 1 ||
        !listEquals(_drag?.members, drag.members) ||
        !widget.registry.containsKey(drag.members.single) ||
        widget.document.groups.any((g) => g.contains(drag.members.single)))
      return false;
    final render = _canvasKey.currentContext?.findRenderObject();
    final snapshot = _snapshot;
    return snapshot != null &&
        snapshot.complete &&
        snapshot.fingerprint.startsWith('$fingerprint|') &&
        render is _WorkspaceRender &&
        render.ready &&
        snapshot.width == render.size.width &&
        render.geometry?.parentWidth == snapshot.width &&
        render.snapshot?.generation == snapshot.generation &&
        render.snapshot?.fingerprint == snapshot.fingerprint &&
        target >= 0 &&
        target < snapshot.groups.length &&
        target < widget.document.groups.length &&
        listEquals(snapshot.groups[target], widget.document.groups[target]);
  }

  bool get _editing => widget.editing || _shelfDragging;
  WorkspaceGeometry? get geometry {
    final render = _canvasKey.currentContext?.findRenderObject();
    return render is _WorkspaceRender && render.ready ? render.geometry : null;
  }

  WorkspaceSize _size(String id) =>
      widget.document.sizes[id] ??
      widget.registry[id]?.defaultSize ??
      WorkspaceSize.twoByTwo;
  WorkspaceSize _groupSize(List<String> group) =>
      WorkspaceSize.maximum(group.map(_size));
  String _visible(List<String> group) => group.contains(_selected[group.first])
      ? _selected[group.first]!
      : group.first;
  @override
  void initState() {
    super.initState();
    _focus();
  }

  void _focus() {
    for (final group in widget.document.groups) {
      if (group.contains(widget.focusId))
        _selected[group.first] = widget.focusId!;
    }
  }

  @override
  void didUpdateWidget(WorkspaceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shelfOpen != widget.shelfOpen ||
        oldWidget.editing != widget.editing)
      _shelfDismissed = false;
    if (oldWidget.focusRevision != widget.focusRevision ||
        oldWidget.focusId != widget.focusId) {
      _selectionEpoch++;
      for (final stage in _stages.values) {
        stage.currentState?.settle();
      }
      _focus();
    }
  }

  void _select(List<String> group, String id) {
    final epoch = ++_selectionEpoch;
    void commit() {
      if (!mounted ||
          epoch != _selectionEpoch ||
          !widget.document.groups.any(
            (current) => current.first == group.first && current.contains(id),
          ))
        return;
      setState(() => _selected[group.first] = id);
    }

    final stage = _stages[_visible(group)]?.currentState;
    if (stage == null) {
      commit();
    } else {
      unawaited(stage.switchTo(group.indexOf(id), commit));
    }
  }

  Future<void> _chooseStack(List<String> group) async {
    final members = List<String>.of(group);
    final targets = {
      for (final id in widget.document.groups.expand((g) => g))
        if (!members.contains(id) && widget.registry.containsKey(id))
          id: widget.registry[id]!.label,
    };
    final capture = MaterialOverlayCapture.of(context);
    final target = await showDialog<String>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: MaterialTransientPanel(
          capture: capture,
          child: _StackTargetChoices(targets: targets),
        ),
      ),
    );
    if (!mounted ||
        !_editing ||
        target == null ||
        !widget.registry.containsKey(target) ||
        !widget.document.groups.any((g) => g.contains(target)) ||
        members.contains(target) ||
        !widget.document.groups.any((g) => listEquals(g, members)))
      return;
    widget.onAction(
      WorkspaceAction(
        WorkspaceActionKind.stack,
        drag: WorkspaceDrag(members),
        id: target,
      ),
    );
  }

  bool _legal(Offset global, int index, bool slot) {
    final render = _canvasKey.currentContext?.findRenderObject();
    if (render is! _WorkspaceRender || !render.ready) return false;
    final hit = render.geometry?.hit(render.globalToLocal(global));
    return hit != null && hit.isSlot == slot && hit.index == index;
  }

  @override
  void dispose() {
    _selectionEpoch++;
    _leftScroll.dispose();
    _rightScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.document.groups;
    final visibleIds = Set<String>.unmodifiable(
      groups.map(_visible).where(widget.registry.containsKey),
    );
    for (final id in groups.expand((group) => group)) {
      _mountedIds.add(id);
      _leases.putIfAbsent(id, GlobalKey.new);
      _stages.putIfAbsent(id, () => GlobalKey<WorkspaceStackTransitionState>());
    }
    final active = groups.expand((group) => group).toSet();
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth)
          throw FlutterError('WorkspaceHost requires a finite parent width');
        final showShelf = (_editing || widget.shelfOpen) && !_shelfDismissed;
        final sideShelf = showShelf && constraints.maxWidth >= 760;
        final width =
            constraints.maxWidth -
            (sideShelf ? 168 + MaterialTokens.spaceLg : 0);
        final fingerprint = _layoutKey(
          width,
          widget.viewportHeight ??
              (constraints.hasBoundedHeight ? constraints.maxHeight : null),
        );
        final snapshot = _snapshot;
        final render = _canvasKey.currentContext?.findRenderObject();
        final actual =
            snapshot?.fingerprint.startsWith(fingerprint + '|') == true &&
                render is _WorkspaceRender &&
                render.snapshot?.generation == snapshot?.generation
            ? render.geometry
            : null;
        final projectionKey =
            '$fingerprint|${snapshot?.generation}|${_drag?.members}|$_dragDocument';
        if (_projectionKey != projectionKey) {
          _projectionKey = projectionKey;
          _holeBoundaries = _drag != null && actual != null && snapshot != null
              ? workspaceHoleBoundaries(
                  snapshot,
                  _drag!,
                  actual,
                  widget.geometryPolicy,
                )
              : const {};
          if (_drag != null && actual != null) holeProjectionComputations++;
        }
        final nodes = <Widget>[
          for (final id in _mountedIds)
            _WorkspaceNode(
              key: ValueKey('lease-$id'),
              role: _NodeRole.content,
              id: id,
              groupIndex: groups.indexWhere((group) => group.contains(id)),
              visible: groups.any((group) => _visible(group) == id),
              memberSize: _size(id),
              groupSize: groups.any((group) => group.contains(id))
                  ? _groupSize(groups.firstWhere((group) => group.contains(id)))
                  : _size(id),
              child: _LiveMember(
                visibleIds: visibleIds,
                key: _leases[id],
                descriptor: widget.registry[id],
                id: id,
                persistedSize: _size(id),
                displaySize: groups.any((group) => group.contains(id))
                    ? _groupSize(
                        groups.firstWhere((group) => group.contains(id)),
                      )
                    : _size(id),
                visible: groups.any((group) => _visible(group) == id),
                editing: _editing,
                stageKey: _stages[id]!,
                resetToken: (widget.focusId, widget.focusRevision),
                selection: groups.any((group) => group.contains(id))
                    ? groups
                          .firstWhere((group) => group.contains(id))
                          .indexOf(
                            _visible(
                              groups.firstWhere((group) => group.contains(id)),
                            ),
                          )
                    : 0,
              ),
            ),
          for (var index = 0; index < groups.length; index++) ...[
            if (_editing)
              _WorkspaceNode(
                key: ValueKey('overlay-${groups[index].first}'),
                role: _NodeRole.overlay,
                groupIndex: index,
                child: _DropSurface(
                  key: ValueKey('workspace_group_${groups[index].first}'),
                  members: groups[index],
                  spanFor: (drag, merge) => WorkspaceSize.maximum(
                    [...drag.members, if (merge) ...groups[index]].map(_size),
                  ),
                  horizontal: width >= widget.geometryPolicy.breakpoint,
                  legal: (point) => _legal(point, index, false),
                  intentDragLegal: (drag, intent) =>
                      _measuredDrag(drag) ||
                      _shelfEdgeLegal(drag, intent, index, fingerprint),
                  revision: (fingerprint, snapshot?.generation, widget.canEdit),
                  onPlace: (drag, after) {
                    widget.onAction(
                      WorkspaceAction(
                        WorkspaceActionKind.place,
                        drag: drag,
                        index: index + (after ? 1 : 0),
                      ),
                    );
                    if (_shelfDragging) _endDrag();
                  },
                  onStack: (drag) => widget.onAction(
                    WorkspaceAction(
                      WorkspaceActionKind.stack,
                      drag: drag,
                      id: _visible(groups[index]),
                    ),
                  ),
                  child: LongPressDraggable<WorkspaceDrag>(
                    hitTestBehavior: HitTestBehavior.opaque,
                    data: WorkspaceDrag(groups[index]),
                    onDragStarted: () =>
                        _startDrag(WorkspaceDrag(groups[index])),
                    onDragEnd: (_) => _endDrag(),
                    dragAnchorStrategy: (_, _, _) => const Offset(80, 52),
                    feedback: MaterialOverlayCapture.of(context).wrap(
                      _DragPreview(
                        descriptor: widget.registry[_visible(groups[index])],
                        count: groups[index].length,
                        size: _groupSize(groups[index]),
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            if (_editing)
              _WorkspaceNode(
                key: ValueKey('toolbar-${groups[index].first}'),
                role: _NodeRole.toolbar,
                groupIndex: index,
                child: _GroupControls(
                  group: groups[index],
                  selected: _visible(groups[index]),
                  descriptor: widget.registry[_visible(groups[index])],
                  index: index,
                  groupCount: groups.length,
                  size: _groupSize(groups[index]),
                  memberSize: _size(_visible(groups[index])),
                  targets: active.difference(groups[index].toSet()).toList(),
                  onStack: () => _chooseStack(groups[index]),
                  onAction: widget.onAction,
                  onDragStarted: () => _startDrag(WorkspaceDrag(groups[index])),
                  onDragEnded: _endDrag,
                ),
              ),
            if (groups[index].length > 1)
              _WorkspaceNode(
                key: ValueKey('navigation-${groups[index].first}'),
                role: _NodeRole.navigation,
                groupIndex: index,
                child: _GroupNavigation(
                  group: groups[index],
                  registry: widget.registry,
                  selected: _visible(groups[index]),
                  onSelect: (id) => _select(groups[index], id),
                ),
              ),
          ],
          for (var index = 0; index < (actual?.slots.length ?? 0); index++)
            _WorkspaceNode(
              key: ValueKey(
                'slot-${actual!.slots[index].key}-${snapshot!.generation}',
              ),
              role: _NodeRole.slot,
              slotIndex: index,
              slotRect: actual.slots[index].rect,
              measurementGeneration: snapshot.generation,
              child: _DropSurface(
                key: ValueKey('workspace_slot_$index'),
                spanFor: (drag, _) =>
                    WorkspaceSize.maximum(drag.members.map(_size)),
                legal: (point) =>
                    actual.slots[index].ready &&
                    _legal(point, actual.slots[index].insertionIndex, true),
                dragLegal: (drag) =>
                    _measuredDrag(drag) &&
                    (index == actual.slots.length - 1 ||
                        _holeBoundaries.containsKey(actual.slots[index].key)),
                revision: snapshot.generation,
                horizontal: width >= widget.geometryPolicy.breakpoint,
                onPlace: (drag, _) => widget.onAction(
                  WorkspaceAction(
                    WorkspaceActionKind.place,
                    drag: drag,
                    index: index == actual.slots.length - 1
                        ? groups.length
                        : _holeBoundaries[actual.slots[index].key]!,
                  ),
                ),
                child: const Center(child: Text('拖到这里添加组件')),
              ),
            ),
        ];
        final canvas = _WorkspaceCanvas(
          key: _canvasKey,
          groupSizes: groups.map(_groupSize).toList(),
          groups: groups,
          fingerprint: fingerprint,
          contentRevisions: {
            for (final entry in widget.registry.entries)
              entry.key: entry.value.contentRevision,
          },
          onMeasured: _measured,
          policy: widget.geometryPolicy,
          prefixBudget: _editing ? null : widget.prefixBudget,
          editing: _editing,
          children: nodes,
        );
        final viewportHeight =
            widget.viewportHeight ??
            (constraints.hasBoundedHeight ? constraints.maxHeight : null);
        final shelfHeight =
            viewportHeight ??
            (MediaQuery.sizeOf(context).height > 0
                ? math.min(MediaQuery.sizeOf(context).height * .7, 480.0)
                : 480.0);
        final shelf = _Shelf(
          minHeight: math.max(0, shelfHeight - (sideShelf ? 0 : 48)),
          registry: widget.registry,
          sizes: widget.document.sizes,
          active: active,
          onAction: widget.onAction,
          onDragStarted: (drag) => _startDrag(drag, shelf: true),
          onDragEnded: _endDrag,
        );
        final appendHeight = _editing && widget.canEdit ? 48.0 : 0.0;
        return SizedBox(
          height: viewportHeight,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  right: sideShelf ? 168 + MaterialTokens.spaceLg : 0,
                  bottom: appendHeight,
                ),
                child: SingleChildScrollView(
                  key: const Key('workspace_left_viewport'),
                  primary: false,
                  controller: _leftScroll,
                  child: canvas,
                ),
              ),
              if (appendHeight > 0)
                Positioned(
                  left: 0,
                  right: sideShelf ? 168 + MaterialTokens.spaceLg : 0,
                  bottom: 0,
                  height: 48,
                  child: DragTarget<WorkspaceDrag>(
                    key: const Key('workspace_semantic_append'),
                    onWillAcceptWithDetails: (details) =>
                        _appendLegal(details.data),
                    onAcceptWithDetails: (details) {
                      if (_appendLegal(details.data)) {
                        widget.onAction(
                          WorkspaceAction(
                            WorkspaceActionKind.place,
                            drag: details.data,
                            index: groups.length,
                          ),
                        );
                        // Accept may remove the shelf's Draggable before its
                        // onDragEnd callback; restore transient editing here.
                        _endDrag();
                      }
                    },
                    builder: (context, candidates, rejected) => Semantics(
                      label: '追加独立组件（自动排布）',
                      child: MaterialActionButton(
                        onPressed: null,
                        child: const Text('追加独立组件（自动排布）'),
                      ),
                    ),
                  ),
                ),
              if (!showShelf &&
                  _shelfDismissed &&
                  (_editing || widget.shelfOpen))
                Positioned(
                  top: 0,
                  right: 0,
                  child: MaterialIconAction(
                    buttonKey: const Key('workspace_reopen_shelf'),
                    tooltip: '打开组件库',
                    icon: const Icon(Icons.library_add),
                    onPressed: () => setState(() => _shelfDismissed = false),
                  ),
                ),
              if (showShelf)
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: viewportHeight != null ? 0 : null,
                  width: sideShelf ? 168 : math.min(constraints.maxWidth, 320),
                  height: viewportHeight == null ? shelfHeight : null,
                  child: MaterialTransientPanel(
                    capture: MaterialOverlayCapture.of(context),
                    scrollable: false,
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        if (!sideShelf)
                          Align(
                            alignment: Alignment.centerRight,
                            child: MaterialIconAction(
                              buttonKey: const Key('workspace_dismiss_shelf'),
                              tooltip: '关闭组件库',
                              icon: const Icon(Icons.close),
                              onPressed: () =>
                                  setState(() => _shelfDismissed = true),
                            ),
                          ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.escape,
                              ): () =>
                                  setState(() => _shelfDismissed = true),
                            },
                            child: Focus(
                              autofocus: !sideShelf,
                              child: CustomScrollView(
                                key: const Key('workspace_right_viewport'),
                                primary: false,
                                controller: _rightScroll,
                                slivers: [SliverToBoxAdapter(child: shelf)],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LiveMember extends StatefulWidget {
  const _LiveMember({
    required this.descriptor,
    required this.id,
    required this.persistedSize,
    required this.displaySize,
    required this.visible,
    required this.editing,
    required this.stageKey,
    required this.resetToken,
    required this.selection,
    required this.visibleIds,
    super.key,
  });
  final WorkspaceDescriptor? descriptor;
  final Set<String> visibleIds;
  final String id;
  final WorkspaceSize persistedSize, displaySize;
  final bool visible, editing;
  final GlobalKey<WorkspaceStackTransitionState> stageKey;
  final int selection;
  final Object? resetToken;
  @override
  State<_LiveMember> createState() => _LiveMemberState();
}

class _LiveMemberState extends State<_LiveMember>
    with SingleTickerProviderStateMixin {
  late final _wiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
    value: 1,
  );
  void _motion() {
    if (widget.editing && !MediaQuery.disableAnimationsOf(context)) {
      _wiggle.forward(from: 0);
    } else {
      _wiggle.stop();
      _wiggle.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motion();
  }

  @override
  void didUpdateWidget(_LiveMember oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editing != widget.editing) _motion();
  }

  @override
  void dispose() {
    _wiggle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: !widget.visible,
    child: ExcludeFocus(
      excluding: !widget.visible || widget.editing,
      child: IgnorePointer(
        ignoring: !widget.visible || widget.editing,
        child: TickerMode(
          enabled: widget.visible,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final descriptor = widget.descriptor;
              final body = descriptor == null
                  ? SizedBox(
                      height: widget.displaySize.isNatural ? 80 : null,
                      child: Center(child: Text('未安装组件：${widget.id}')),
                    )
                  : descriptor.contentBuilder(
                      context,
                      WorkspaceContentLayout(
                        constraints: constraints,
                        persistedSize: widget.persistedSize,
                        displaySize: widget.displaySize,
                        contentRevision: descriptor.contentRevision,
                        visibleIds: widget.visibleIds,
                      ),
                    );
              return AnimatedBuilder(
                animation: _wiggle,
                child: WorkspaceStackTransition(
                  key: widget.stageKey,
                  selection: widget.selection,
                  resetToken: widget.resetToken,
                  child: body,
                ),
                builder: (context, child) => Transform.rotate(
                  key: ValueKey('workspace_wiggle_${widget.id}'),
                  angle: widget.editing
                      ? math.sin(_wiggle.value * math.pi * 6) *
                            .035 *
                            math.pow(1 - _wiggle.value, 2)
                      : 0,
                  child: child,
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _GroupControls extends StatelessWidget {
  const _GroupControls({
    required this.group,
    required this.selected,
    required this.descriptor,
    required this.index,
    required this.groupCount,
    required this.size,
    required this.memberSize,
    required this.targets,
    required this.onAction,
    required this.onStack,
    required this.onDragStarted,
    required this.onDragEnded,
  });
  final List<String> group, targets;
  final String selected;
  final WorkspaceDescriptor? descriptor;
  final int index, groupCount;
  final WorkspaceSize size, memberSize;
  final ValueChanged<WorkspaceAction> onAction;
  final VoidCallback onStack;
  final VoidCallback onDragStarted, onDragEnded;
  @override
  Widget build(BuildContext context) {
    final capture = MaterialOverlayCapture.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: MaterialTokens.spaceLg),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: MaterialTokens.spaceXs,
        children: [
          Draggable<WorkspaceDrag>(
            data: WorkspaceDrag(group),
            onDragStarted: onDragStarted,
            onDragEnd: (_) => onDragEnded(),
            dragAnchorStrategy: (_, _, _) => const Offset(80, 52),
            feedback: capture.wrap(
              _DragPreview(
                descriptor: descriptor,
                count: group.length,
                size: size,
              ),
            ),
            child: MenuAnchor(
              style: materialMenuStyle,
              menuChildren: [
                MaterialTransientPanel(
                  capture: capture,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MenuItemButton(
                        onPressed: index > 0
                            ? () => onAction(
                                WorkspaceAction(
                                  WorkspaceActionKind.move,
                                  index: index,
                                  delta: -1,
                                ),
                              )
                            : null,
                        child: const Text('向前移动'),
                      ),
                      MenuItemButton(
                        onPressed: index < groupCount - 1
                            ? () => onAction(
                                WorkspaceAction(
                                  WorkspaceActionKind.move,
                                  index: index,
                                  delta: 1,
                                ),
                              )
                            : null,
                        child: const Text('向后移动'),
                      ),
                      if (group.length > 1)
                        MenuItemButton(
                          onPressed: () => onAction(
                            WorkspaceAction(
                              WorkspaceActionKind.detach,
                              id: selected,
                              index: index + 1,
                            ),
                          ),
                          child: const Text('拆为独立组件'),
                        ),
                      MenuItemButton(
                        onPressed: onStack,
                        child: const Text('自定义堆叠…'),
                      ),
                    ],
                  ),
                ),
              ],
              builder: (context, controller, _) => MaterialIconAction(
                buttonKey: ValueKey('workspace_handle_$selected'),
                tooltip: '拖动${descriptor?.label ?? selected}',
                icon: const Icon(Icons.drag_indicator_rounded, size: 18),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          ),
          MenuAnchor(
            style: materialMenuStyle,
            menuChildren: [
              MaterialTransientPanel(
                capture: capture,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option
                        in descriptor?.supportedSizes ??
                            const <WorkspaceSize>[])
                      MenuItemButton(
                        key: ValueKey(
                          'workspace_resize_${selected}_${workspaceSizeName(option)}',
                        ),
                        onPressed: () => onAction(
                          WorkspaceAction(
                            WorkspaceActionKind.resize,
                            id: selected,
                            size: option,
                          ),
                        ),
                        child: Semantics(
                          label: '${workspaceSizeName(option)}，${option.label}',
                          selected: option.sameExtent(memberSize),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 56,
                                height: 48,
                                child: WorkspaceThumbnail(
                                  descriptor: descriptor,
                                  size: option,
                                ),
                              ),
                              const SizedBox(width: MaterialTokens.spaceSm),
                              Text(workspaceSizeName(option)),
                              if (option.sameExtent(memberSize))
                                const Padding(
                                  padding: EdgeInsets.only(
                                    left: MaterialTokens.spaceSm,
                                  ),
                                  child: Icon(Icons.check_rounded, size: 18),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.only(top: MaterialTokens.spaceSm),
                      child: Text('S 1×1 · M 2×1 · L 2×2 · XL 2×3\n整行随内容高度'),
                    ),
                  ],
                ),
              ),
            ],
            builder: (context, controller, _) => MaterialIconAction(
              buttonKey: ValueKey('workspace_resize_$selected'),
              tooltip: '调整${descriptor?.label ?? selected}尺寸',
              icon: const Icon(Icons.aspect_ratio_rounded, size: 18),
              onPressed: descriptor == null
                  ? null
                  : () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
            ),
          ),
          MaterialIconAction(
            buttonKey: ValueKey('workspace_hide_$selected'),
            tooltip: '收回组件栏',
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () => onAction(
              WorkspaceAction(
                WorkspaceActionKind.hide,
                drag: WorkspaceDrag(group),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StackTargetChoices extends StatelessWidget {
  const _StackTargetChoices({required this.targets});
  final Map<String, String> targets;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('自定义堆叠', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: MaterialTokens.spaceSm),
      if (targets.isEmpty) const Text('没有可堆叠的组件'),
      for (final entry in targets.entries)
        MaterialActionButton(
          buttonKey: ValueKey('workspace_stack_target_${entry.key}'),
          onPressed: () => Navigator.pop(context, entry.key),
          child: Text(entry.value),
        ),
      const SizedBox(height: MaterialTokens.spaceSm),
      MaterialActionButton(
        buttonKey: const Key('workspace_stack_cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

/// Labels are presentation only; persisted extents remain unchanged.
String workspaceSizeName(WorkspaceSize size) {
  if (size.isNatural) return '整行';
  if (size.sameExtent(WorkspaceSize.oneByOne)) return 'S';
  if (size.sameExtent(WorkspaceSize.twoByOne)) return 'M';
  if (size.sameExtent(WorkspaceSize.twoByTwo)) return 'L';
  if (size.sameExtent(WorkspaceSize.twoByThree)) return 'XL';
  return size.label;
}

/// A bounded, pure thumbnail. Only previews may contain-scale.
class WorkspaceThumbnail extends StatelessWidget {
  const WorkspaceThumbnail({
    required this.descriptor,
    required this.size,
    super.key,
  });
  final WorkspaceDescriptor? descriptor;
  final WorkspaceSize size;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const policy = WorkspaceGeometryPolicy(breakpoint: 0);
      const fullWidth = 4 * 154.0 + 3 * MaterialTokens.spaceMd;
      final ratio = size.isNatural
          ? 2.5
          : policy.widthFor(fullWidth, size) / policy.heightFor(size);
      final budgetWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : 160.0;
      final budgetHeight = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : 104.0;
      final width = math.min(budgetWidth, budgetHeight * ratio);
      final height = width / ratio;
      return Center(
        child: SizedBox(
          key: ValueKey(
            'workspace_thumbnail_frame_${descriptor?.id ?? 'unknown'}_${workspaceSizeName(size)}',
          ),
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              descriptor?.thumbnailForSize?.call(context, size) ??
                  descriptor?.thumbnailBuilder(context) ??
                  const Icon(Icons.extension_off_outlined),
              if (size.isNatural)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Text(
                    '整行示意',
                    textScaler: TextScaler.noScaling,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(fontSize: 9),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _GroupNavigation extends StatelessWidget {
  const _GroupNavigation({
    required this.group,
    required this.registry,
    required this.selected,
    required this.onSelect,
  });
  final List<String> group;
  final Map<String, WorkspaceDescriptor> registry;
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: MaterialTokens.spaceSm),
    child: Wrap(
      alignment: WrapAlignment.center,
      children: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: '上一个组件',
            onPressed: () => onSelect(
              group[(group.indexOf(selected) - 1 + group.length) %
                  group.length],
            ),
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
        ),
        for (final id in group)
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              key: ValueKey('workspace_switch_$id'),
              tooltip: registry[id]?.label ?? id,
              onPressed: () => onSelect(id),
              icon: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutQuart,
                width: id == selected ? 22 : 7,
                height: 7,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    MaterialTokens.controlRadius,
                  ),
                  color:
                      (MaterialScope.maybeOf(
                                context,
                              )?.policy.navigationForeground ??
                              Theme.of(context).colorScheme.primary)
                          .withValues(alpha: id == selected ? 1 : .65),
                ),
              ),
            ),
          ),
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: '下一个组件',
            onPressed: () =>
                onSelect(group[(group.indexOf(selected) + 1) % group.length]),
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
        ),
      ],
    ),
  );
}

class _DragPreview extends StatelessWidget {
  const _DragPreview({required this.descriptor, this.count = 1, this.size});
  final WorkspaceDescriptor? descriptor;
  final int count;
  final WorkspaceSize? size;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Material(
      key: const Key('workspace_drag_preview_surface'),
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 160,
        height: 104,
        child: Stack(
          children: [
            Positioned.fill(
              child: ExcludeSemantics(
                child: WorkspaceThumbnail(
                  descriptor: descriptor,
                  size:
                      size ?? descriptor?.defaultSize ?? WorkspaceSize.twoByTwo,
                ),
              ),
            ),
            Positioned(
              right: 4,
              top: 4,
              child: _SizeBadge(
                key: const Key('workspace_drag_size'),
                size: size ?? descriptor?.defaultSize ?? WorkspaceSize.twoByTwo,
              ),
            ),
            if (count > 1)
              Positioned(
                right: MaterialTokens.spaceSm,
                bottom: MaterialTokens.spaceXs,
                child: Text(
                  '$count 个组件',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _Shelf extends StatelessWidget {
  const _Shelf({
    required this.registry,
    required this.sizes,
    required this.active,
    required this.onAction,
    required this.onDragStarted,
    required this.onDragEnded,
    this.minHeight = 240,
  });
  final Map<String, WorkspaceDescriptor> registry;
  final Set<String> active;
  final Map<String, WorkspaceSize> sizes;
  final ValueChanged<WorkspaceAction> onAction;
  final ValueChanged<WorkspaceDrag> onDragStarted;
  final VoidCallback onDragEnded;
  final double minHeight;
  @override
  Widget build(BuildContext context) => DragTarget<WorkspaceDrag>(
    key: const Key('workspace_component_shelf'),
    hitTestBehavior: HitTestBehavior.opaque,
    onWillAcceptWithDetails: (_) => true,
    onAcceptWithDetails: (details) =>
        onAction(WorkspaceAction(WorkspaceActionKind.hide, drag: details.data)),
    builder: (context, candidates, rejected) => Semantics(
      label: '组件收纳区',
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: const EdgeInsets.all(MaterialTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final descriptor in registry.values.where(
                (item) => !active.contains(item.id),
              ))
                Draggable<WorkspaceDrag>(
                  data: WorkspaceDrag([descriptor.id]),
                  onDragStarted: () =>
                      onDragStarted(WorkspaceDrag([descriptor.id])),
                  onDragEnd: (_) => onDragEnded(),
                  dragAnchorStrategy: (_, _, _) => const Offset(80, 52),
                  feedback: MaterialOverlayCapture.of(context).wrap(
                    _DragPreview(
                      descriptor: descriptor,
                      size: sizes[descriptor.id] ?? descriptor.defaultSize,
                    ),
                  ),
                  child: TextButton(
                    key: ValueKey('workspace_add_${descriptor.id}'),
                    onPressed: () => onAction(
                      WorkspaceAction(
                        WorkspaceActionKind.reveal,
                        id: descriptor.id,
                      ),
                    ),
                    child: Column(
                      children: [
                        SizedBox(
                          height: 92,
                          child: ExcludeSemantics(
                            child: WorkspaceThumbnail(
                              descriptor: descriptor,
                              size:
                                  sizes[descriptor.id] ??
                                  descriptor.defaultSize,
                            ),
                          ),
                        ),
                        const SizedBox(height: MaterialTokens.spaceSm),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                descriptor.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            _SizeBadge(
                              key: ValueKey('workspace_size_${descriptor.id}'),
                              size:
                                  sizes[descriptor.id] ??
                                  descriptor.defaultSize,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (candidates.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.all(MaterialTokens.spaceMd),
                  child: Text('松开即可收纳'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SizeBadge extends StatelessWidget {
  const _SizeBadge({required this.size, super.key});
  final WorkspaceSize size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: size.isNatural ? '整行，随内容高度' : '${size.colSpan}列，${size.rowSpan}行',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Text(
          workspaceSizeName(size),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ),
  );
}

class _DropSurface extends StatefulWidget {
  const _DropSurface({
    required this.legal,
    required this.horizontal,
    required this.onPlace,
    required this.child,
    this.members = const [],
    this.spanFor,
    this.onStack,
    this.dragLegal,
    this.intentDragLegal,
    this.revision,
    super.key,
  });
  final bool Function(Offset) legal;
  final bool horizontal;
  final List<String> members;
  final WorkspaceSize Function(WorkspaceDrag, bool)? spanFor;
  final void Function(WorkspaceDrag, bool) onPlace;
  final ValueChanged<WorkspaceDrag>? onStack;
  final bool Function(WorkspaceDrag)? dragLegal;
  final bool Function(WorkspaceDrag, WorkspaceDropIntent)? intentDragLegal;
  final Object? revision;
  final Widget child;
  @override
  State<_DropSurface> createState() => _DropSurfaceState();
}

class _DropSurfaceState extends State<_DropSurface> {
  Timer? _timer;
  WorkspaceDropIntent? _intent;
  bool _merge = false;
  @override
  void didUpdateWidget(_DropSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      _timer?.cancel();
      _intent = null;
      _merge = false;
    }
  }

  bool _dragLegal(WorkspaceDrag drag, WorkspaceDropIntent intent) =>
      (widget.dragLegal?.call(drag) ?? true) &&
      (widget.intentDragLegal?.call(drag, intent) ?? true);

  bool _track(WorkspaceDrag drag, Offset global) {
    if (drag.members.any(widget.members.contains) ||
        !widget.legal(global)) {
      _clear();
      return false;
    }
    final box = context.findRenderObject() as RenderBox;
    final intent = workspaceDropIntent(
      box.globalToLocal(global),
      box.size,
      horizontal: widget.horizontal,
    );
    if (intent == null || !_dragLegal(drag, intent)) {
      _clear();
      return false;
    }
    if (_intent?.central != intent.central) {
      _timer?.cancel();
      _merge = false;
      if (intent.central && widget.onStack != null)
        _timer = Timer(const Duration(milliseconds: 600), () {
          if (mounted &&
              widget.legal(global) &&
              _intent?.central == true &&
              _dragLegal(drag, intent)) {
            setState(() => _merge = true);
          }
        });
    }
    setState(() => _intent = intent);
    return true;
  }

  void _clear() {
    _timer?.cancel();
    if (mounted)
      setState(() {
        _intent = null;
        _merge = false;
      });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragTarget<WorkspaceDrag>(
    hitTestBehavior: HitTestBehavior.opaque,
    onWillAcceptWithDetails: (details) =>
        _track(details.data, details.offset + const Offset(80, 52)),
    onMove: (details) =>
        _track(details.data, details.offset + const Offset(80, 52)),
    onLeave: (_) => _clear(),
    onAcceptWithDetails: (details) {
      if (_intent == null ||
          !_track(details.data, details.offset + const Offset(80, 52)))
        return;
      final merge = _merge, after = _intent!.after;
      _clear();
      if (merge && widget.onStack != null) {
        widget.onStack!(details.data);
      } else {
        widget.onPlace(details.data, after);
      }
    },
    builder: (context, candidates, rejected) => Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        if (candidates.isNotEmpty && _intent != null) ...[
          if (widget.members.isNotEmpty && !_merge)
            Positioned(
              left: _intent!.edge == AxisDirection.right ? null : 0,
              right: _intent!.edge == AxisDirection.left ? null : 0,
              top: _intent!.edge == AxisDirection.down ? null : 0,
              bottom: _intent!.edge == AxisDirection.up ? null : 0,
              width:
                  _intent!.edge == AxisDirection.left ||
                      _intent!.edge == AxisDirection.right
                  ? MaterialTokens.spaceXs
                  : null,
              height:
                  _intent!.edge == AxisDirection.up ||
                      _intent!.edge == AxisDirection.down
                  ? MaterialTokens.spaceXs
                  : null,
              child: IgnorePointer(
                child: ColoredBox(
                  key: ValueKey('workspace_insert_${_intent!.edge.name}'),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          Positioned(
            left: MaterialTokens.spaceMd,
            right: MaterialTokens.spaceMd,
            top: _intent!.after && !_merge ? null : MaterialTokens.spaceSm,
            bottom: _intent!.after && !_merge ? MaterialTokens.spaceSm : null,
            child: IgnorePointer(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _merge
                        ? '松开合并为堆叠'
                        : widget.members.isEmpty
                        ? '放到这个位置'
                        : _intent!.after
                        ? '插入后面'
                        : '插入前面',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  if (widget.spanFor != null)
                    _SizeBadge(
                      size: widget.spanFor!(candidates.first!, _merge),
                    ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

enum _NodeRole { content, overlay, toolbar, navigation, slot }

class _WorkspaceData extends ContainerBoxParentData<RenderBox> {
  _NodeRole role = _NodeRole.content;
  String id = '';
  int groupIndex = -1, slotIndex = -1;
  Rect slotRect = Rect.zero;
  int? measurementGeneration;
  bool visible = true;
  WorkspaceSize memberSize = WorkspaceSize.twoByTwo,
      groupSize = WorkspaceSize.twoByTwo;
}

class _WorkspaceNode extends ParentDataWidget<_WorkspaceData> {
  const _WorkspaceNode({
    required this.role,
    required super.child,
    this.id = '',
    this.groupIndex = -1,
    this.slotIndex = -1,
    this.slotRect = Rect.zero,
    this.measurementGeneration,
    this.visible = true,
    this.memberSize = WorkspaceSize.twoByTwo,
    this.groupSize = WorkspaceSize.twoByTwo,
    super.key,
  });
  final _NodeRole role;
  final String id;
  final int groupIndex, slotIndex;
  final Rect slotRect;
  final int? measurementGeneration;
  final bool visible;
  final WorkspaceSize memberSize, groupSize;
  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _WorkspaceData;
    final changed =
        data.role != role ||
        data.id != id ||
        data.groupIndex != groupIndex ||
        data.slotIndex != slotIndex ||
        data.slotRect != slotRect ||
        data.measurementGeneration != measurementGeneration ||
        data.visible != visible ||
        !data.memberSize.sameExtent(memberSize) ||
        !data.groupSize.sameExtent(groupSize);
    data.role = role;
    data.id = id;
    data.groupIndex = groupIndex;
    data.slotIndex = slotIndex;
    data.slotRect = slotRect;
    data.measurementGeneration = measurementGeneration;
    data.visible = visible;
    data.memberSize = memberSize;
    data.groupSize = groupSize;
    if (changed) renderObject.parent?.markNeedsLayout();
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _WorkspaceCanvas;
}

class _WorkspaceCanvas extends MultiChildRenderObjectWidget {
  const _WorkspaceCanvas({
    required this.groupSizes,
    required this.policy,
    required this.editing,
    required super.children,
    required this.groups,
    required this.fingerprint,
    required this.contentRevisions,
    required this.onMeasured,
    this.prefixBudget,
    super.key,
  });
  final List<WorkspaceSize> groupSizes;
  final WorkspaceGeometryPolicy policy;
  final bool editing;
  final List<List<String>> groups;
  final String fingerprint;
  final Map<String, Object?> contentRevisions;
  final WorkspacePrefixPresentationBudget? prefixBudget;
  final VoidCallback onMeasured;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _WorkspaceRender(groupSizes, policy, editing)
        ..groups = groups
        ..fingerprint = fingerprint
        ..contentRevisions = contentRevisions
        ..prefixBudget = prefixBudget
        ..onMeasured = onMeasured;
  @override
  void updateRenderObject(BuildContext context, _WorkspaceRender renderObject) {
    final changed = renderObject.fingerprint != fingerprint;
    renderObject
      ..groupSizes = groupSizes
      ..policy = policy
      ..editing = editing
      ..groups = groups
      ..fingerprint = fingerprint
      ..contentRevisions = contentRevisions
      ..prefixBudget = prefixBudget
      ..onMeasured = onMeasured;
    if (changed) renderObject.markNeedsLayout();
  }
}

class _WorkspaceRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _WorkspaceData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _WorkspaceData> {
  _WorkspaceRender(this.groupSizes, this.policy, this.editing);
  List<WorkspaceSize> groupSizes;
  WorkspaceGeometryPolicy policy;
  bool editing;
  bool ready = false;
  WorkspaceGeometry? geometry;
  WorkspaceMeasurementSnapshot? snapshot;
  List<List<String>> groups = const [];
  String fingerprint = '';
  Map<String, Object?> contentRevisions = const {};
  WorkspacePrefixPresentationBudget? prefixBudget;
  VoidCallback? onMeasured;
  int _generation = 0;
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _WorkspaceData)
      child.parentData = _WorkspaceData();
  }

  @override
  void markNeedsLayout() {
    ready = false;
    super.markNeedsLayout();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    if (!width.isFinite) throw FlutterError('Workspace requires finite width');
    final heights = List<double>.filled(groupSizes.length, 0),
        before = List<double>.filled(groupSizes.length, 0),
        after = List<double>.filled(groupSizes.length, 0);
    final children = getChildrenAsList();
    final members = <String, WorkspaceMemberMeasurement>{};
    var budget = !editing && policy.columns(width) > 1 &&
            prefixBudget?.matches(groups, groupSizes) == true
        ? prefixBudget : null;
    double? prefixHeight;
    if (budget != null) {
      // Measure the sole live natural member and real chrome before finite
      // prefix constraints. A second same-constraint layout is a no-op.
      for (final child in children) {
        final data = child.parentData! as _WorkspaceData;
        final i = data.groupIndex;
        if (i < 0 || i > 2) continue;
        final natural = data.role == _NodeRole.content &&
            groupSizes[i].isNatural && data.memberSize.isNatural;
        if (natural || data.role == _NodeRole.navigation ||
            data.role == _NodeRole.toolbar) {
          child.layout(BoxConstraints.tightFor(
            width: policy.widthFor(width, groupSizes[i])),
            parentUsesSize: true);
          if (natural) heights[i] = math.max(heights[i], child.size.height);
          if (data.role == _NodeRole.navigation) after[i] = child.size.height;
          if (data.role == _NodeRole.toolbar) before[i] = child.size.height;
        }
      }
      final chrome = math.max(before[0] + after[0], before[1] + after[1]);
      final available = budget.firstFoldExtent - heights[2] -
          before[2] - after[2] - policy.rowGap - chrome;
      prefixHeight = math.min(
        math.min(budget.contentHeights[0]!, budget.contentHeights[1]!),
        available);
      if (!prefixHeight.isFinite ||
          prefixHeight < budget.minimumContentHeight) {
        budget = null;
        prefixHeight = null;
      }
    }
    for (final child in children) {
      final data = child.parentData! as _WorkspaceData;
      final index = data.groupIndex;
      if (data.role == _NodeRole.content) {
        final groupSize = index >= 0 ? groupSizes[index] : data.groupSize;
        final childWidth = policy.widthFor(width, groupSize);
        // Every natural member is measured now, using its sole live instance.
        // No intrinsic pass or cached/previous-width height is consulted.
        final natural = groupSize.isNatural && data.memberSize.isNatural;
        child.layout(
          BoxConstraints.tightFor(
            width: childWidth,
            height: natural
                ? null
                : budget != null && index >= 0 && index < 2
                ? prefixHeight
                : policy.heightFor(
                    groupSize.isNatural ? data.memberSize : groupSize,
                  ),
          ),
          parentUsesSize: true,
        );
        if (index >= 0)
          heights[index] = math.max(heights[index], child.size.height);
        members[data.id] = WorkspaceMemberMeasurement(
          id: data.id,
          width: childWidth,
          height: child.size.height,
          constraints: child.constraints,
          contentRevision: contentRevisions[data.id],
        );
      } else if (data.role == _NodeRole.toolbar ||
          data.role == _NodeRole.navigation) {
        child.layout(
          BoxConstraints.tightFor(
            width: policy.widthFor(width, groupSizes[index]),
          ),
          parentUsesSize: true,
        );
        if (data.role == _NodeRole.toolbar) {
          before[index] = child.size.height;
        } else {
          after[index] = child.size.height;
        }
      }
    }
    var measures = [
      for (var i = 0; i < groupSizes.length; i++)
        WorkspaceGroupMeasure(
          size: groupSizes[i],
          contentHeight: heights[i],
          before: before[i],
          after: after[i],
        ),
    ];
    if (budget != null) {
      measures = budget.applyClearance(width, groups, measures, policy);
    }
    final actualFingerprint =
        '$fingerprint|${jsonEncode([
          heights,
          before,
          after,
          if (budget != null) measures.map((m) => m.after).toList(),
          for (final member in members.values) [member.id, member.width, member.height, member.constraints.toString(), identityHashCode(member.contentRevision)],
        ])}';
    if (snapshot?.fingerprint != actualFingerprint) {
      snapshot = WorkspaceMeasurementSnapshot(
        generation: ++_generation,
        fingerprint: actualFingerprint,
        width: width,
        groups: groups,
        measures: measures,
        members: members,
      );
    }
    geometry = workspaceGeometry(
      width,
      measures,
      policy: policy,
      editing: editing,
    );
    for (final child in children) {
      final data = child.parentData! as _WorkspaceData;
      final index = data.groupIndex;
      if (data.role == _NodeRole.content) {
        data.offset = index < 0
            ? Offset.zero
            : geometry!.contents[index].topLeft;
      } else if (data.role == _NodeRole.toolbar) {
        data.offset = geometry!.groups[index].topLeft;
      } else if (data.role == _NodeRole.navigation) {
        data.offset = Offset(
          geometry!.groups[index].left,
          geometry!.contents[index].bottom,
        );
      } else {
        final rect = data.role == _NodeRole.slot
            ? data.slotRect
            : geometry!.groups[index];
        child.layout(BoxConstraints.tight(rect.size), parentUsesSize: true);
        data.offset = rect.topLeft;
      }
    }
    size = constraints.constrain(Size(width, geometry!.height));
    ready = true;
    onMeasured?.call();
  }

  bool _paintable(RenderBox child) {
    final data = child.parentData! as _WorkspaceData;
    if (data.role == _NodeRole.slot &&
        data.measurementGeneration != snapshot?.generation)
      return false;
    return data.role != _NodeRole.content ||
        (data.visible && data.groupIndex >= 0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in getChildrenAsList()) {
      if (_paintable(child))
        context.paintChild(
          child,
          offset + (child.parentData! as _WorkspaceData).offset,
        );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in getChildrenAsList().reversed) {
      if (!_paintable(child)) continue;
      if (result.addWithPaintOffset(
        offset: (child.parentData! as _WorkspaceData).offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      ))
        return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    for (final child in getChildrenAsList()) {
      if (_paintable(child)) visitor(child);
    }
  }
}
