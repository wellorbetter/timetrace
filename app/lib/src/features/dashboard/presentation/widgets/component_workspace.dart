import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/material/material.dart';
import '../../../../core/widgets/context_help.dart';
import '../../../../core/widgets/workspace_glyph.dart';
import '../../../../core/workspace/workspace_host.dart' as host;
import '../../../../core/workspace/workspace_model.dart' as model;
import '../../../../core/workspace/workspace_geometry.dart' as geometry;
import '../../../../core/preferences/ui_preferences_store.dart';
import '../../providers/workspace_layout_provider.dart';
import 'workspace_component_registry.dart';

/// Page-level entry; layout controls never sit between range and content.
class WorkspaceEditActions extends ConsumerWidget {
  const WorkspaceEditActions({this.trailingActions = const [], super.key});
  final List<Widget> trailingActions;

  // Resolve the very same ButtonStyle used by the secondary reset action.
  // Its foreground/state ink stays owned by MaterialActionButton.
  static TextStyle? _resetLabelStyle(BuildContext context) =>
      materialActionStyle(context).textStyle?.resolve(const <WidgetState>{});

  // Match the actual Wrap's child sizes, including a scaled/reset label that
  // needs multiple lines under a narrow bounded title. Icons stay 48 by 48.
  static List<Size> _targetSizes(
    BuildContext context,
    double width, {
    required bool editing,
    required int trailingCount,
  }) {
    const target = materialControlTarget;
    final sizes = <Size>[];
    if (editing) {
      final label = TextPainter(
        text: TextSpan(
          text: '恢复默认',
          style: _resetLabelStyle(context),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(
        maxWidth: width.isFinite
            ? math.max(0, width - 2 * MaterialTokens.spaceMd)
            : double.infinity,
      );
      sizes.addAll([
        const Size(target, target),
        Size(
          math.max(target, label.width + 2 * MaterialTokens.spaceMd),
          math.max(target, label.height),
        ),
        const Size(target, target),
      ]);
      label.dispose();
    } else {
      sizes.addAll([const Size(target, target), const Size(target, target)]);
    }
    sizes.addAll(List.filled(trailingCount, const Size(target, target)));
    return sizes;
  }

  /// AppBar needs this exact run height before laying out its bounded title.
  static double heightFor(
    BuildContext context,
    double width, {
    required bool editing,
    int trailingCount = 0,
  }) {
    var height = 0.0, rowHeight = 0.0, used = 0.0;
    for (final target in _targetSizes(
      context,
      width,
      editing: editing,
      trailingCount: trailingCount,
    )) {
      final next = used == 0
          ? target.width
          : used + MaterialTokens.spaceSm + target.width;
      if (used > 0 && next > width) {
        height += rowHeight + MaterialTokens.spaceSm;
        used = target.width;
        rowHeight = target.height;
      } else {
        used = next;
        rowHeight = math.max(rowHeight, target.height);
      }
    }
    return height + rowHeight;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(workspaceEditProvider);
    final shelfOpen = ref.watch(workspaceShelfOpenProvider);
    final view = ref.watch(workspaceDocumentProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final sizes = _targetSizes(
          context,
          constraints.maxWidth,
          editing: editing,
          trailingCount: trailingActions.length,
        );
        return SizedBox(
          key: const Key('workspace_toolbar_bounds'),
          // A title receives a loose but finite maximum width. Occupy it before
          // aligning runs; legacy unbounded AppBar.actions remain intrinsic.
          width: constraints.hasBoundedWidth ? constraints.maxWidth : null,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: MaterialTokens.spaceSm,
            runSpacing: MaterialTokens.spaceSm,
            children: [
              if (!editing)
                MaterialIconAction(
                  buttonKey: const Key('workspace_toggle_shelf'),
                  tooltip: shelfOpen ? '收起组件栏' : '展开组件栏',
                  onPressed: ref.read(workspaceShelfOpenProvider.notifier).toggle,
                  icon: WorkspaceGlyph(
                    shelfOpen
                        ? WorkspaceGlyphKind.shelfOpen
                        : WorkspaceGlyphKind.shelfClosed,
                  ),
                ),
              if (editing)
                const SizedBox(
                  width: materialControlTarget,
                  height: materialControlTarget,
                  child: ContextHelp(
                    key: Key('workspace_edit_help'),
                    message:
                        '长按组件或拖动手柄移动整个堆叠。\n\n靠近左沿或上沿插在前面，右沿或下沿插在后面，标记会显示实际插入方向。在中间停留约 0.6 秒，看到“松开合并为堆叠”后松手即可合并。末尾空白区域会放到最后；格位间隙或其他无效位置松手会取消。\n\n手柄菜单的“拆为独立组件”只拆出当前页。拖到右侧整列或点 × 收回整个堆叠；圆点切换组内组件。',
                  ),
                ),
              if (editing)
                SizedBox(
                  width: sizes[1].width,
                  height: sizes[1].height,
                  child: MaterialActionButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MaterialTokens.spaceMd,
                    ),
                    onPressed: view.writable && !view.loading
                        ? () => ref.read(workspaceLayoutProvider.notifier).reset()
                        : null,
                    child: const Text('恢复默认'),
                  ),
                ),
              MaterialIconAction(
                buttonKey: const Key('workspace_edit_layout'),
                tooltip: editing ? '完成布局编辑' : '组件',
                onPressed: view.writable && !view.loading
                    ? ref.read(workspaceEditProvider.notifier).toggle
                    : null,
                icon: Icon(
                  editing ? Icons.check_rounded : Icons.widgets_outlined,
                  size: 20,
                ),
              ),
              ...trailingActions,
            ],
          ),
        );
      },
    );
  }
}

/// Compatibility composition only; approved core owns leases and geometry.
class ComponentWorkspace extends ConsumerWidget {
  const ComponentWorkspace({
    this.components = const {},
    this.builders = const {},
    this.registry,
    this.contentHeight = 320,
    this.includeTools = true,
    this.viewportHeight,
    this.prefixBudget,
    super.key,
  });
  final Map<WorkspaceComponent, Widget> components;
  final Map<WorkspaceComponent, WorkspaceBusinessBuilder> builders;
  final Map<String, host.WorkspaceDescriptor>? registry;
  final double contentHeight;
  final bool includeTools;
  final double? viewportHeight;
  final geometry.WorkspacePrefixPresentationBudget? prefixBudget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(workspaceDocumentProvider);
    final notifier = ref.read(workspaceDocumentProvider.notifier);
    final editing = ref.watch(workspaceEditProvider);
    final shelf = ref.watch(workspaceShelfOpenProvider);
    final focus = ref.watch(workspaceFocusProvider);
    final source =
        registry ??
        createWorkspaceRegistry(
          components: components,
          builders: builders,
          includeTools: includeTools,
        );
    final descriptors = {
      for (final entry in source.entries)
        entry.key: host.WorkspaceDescriptor(
          id: entry.value.id,
          label: entry.value.label,
          defaultSize: entry.value.defaultSize,
          supportedSizes: entry.value.supportedSizes,
          thumbnailBuilder: entry.value.thumbnailBuilder,
          thumbnailForSize: entry.value.thumbnailForSize,
          contentRevision: entry.value.contentRevision,
          contentBuilder: (context, layout) => KeyedSubtree(
            key: ValueKey('workspace_component_' + entry.key),
            child: DecoratedBox(
              key: ValueKey('workspace_lift_' + entry.key),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  MaterialTokens.contentRadius,
                ),
                boxShadow: editing
                    ? MaterialTokens.cardShadow(
                        dark: Theme.of(context).brightness == Brightness.dark,
                        lifted: true,
                      )
                    : const [],
              ),
              child: entry.value.contentBuilder(context, layout),
            ),
          ),
        ),
    };
    return SizedBox(
      height: viewportHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final workspace = host.WorkspaceHost(
            document: view.document,
            prefixBudget: view.writable && !view.loading && !view.dirty &&
                    view.error == null && !editing
                ? prefixBudget : null,
            registry: descriptors,
            canEdit: view.writable && !view.loading,
            onAction: (action) {
              if (view.writable && !view.loading) notifier.perform(action);
            },
            editing: editing && view.writable && !view.loading,
            shelfOpen: shelf && view.writable && !view.loading,
            focusId: focus?.component.name,
            focusRevision: focus?.revision ?? 0,
            geometryPolicy: geometry.WorkspaceGeometryPolicy(
              cellHeight: (contentHeight - MaterialTokens.spaceMd) / 2,
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (view.loading) const Text('正在读取工作台布局…'),
              if (view.error != null) ...[
                Text(view.error!, key: const Key('workspace_layout_error')),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: view.loading ? null : () => notifier.reload(),
                      child: const Text('重试读取'),
                    ),
                    if (view.dirty && !view.writable)
                      TextButton(
                        onPressed: view.loading
                            ? null
                            : () => notifier.reload(discardChanges: true),
                        child: const Text('刷新配置（放弃未保存布局）'),
                      ),
                    if (ref.read(workspaceLayoutStoreProvider).lastRead
                        case UiPreferencesUnreadable(:final recoverable)
                        when recoverable != null)
                      TextButton(
                        onPressed: notifier.restoreRecovery,
                        child: const Text('恢复已保留配置'),
                      ),
                  ],
                ),
              ],
              if (view.dirty)
                Wrap(
                  children: [
                    const Text('布局修改尚未保存到本机'),
                    TextButton(
                      onPressed: view.writable ? notifier.retrySave : null,
                      child: const Text('重试保存布局'),
                    ),
                  ],
                ),
              if (constraints.hasBoundedHeight)
                Expanded(child: workspace)
              else
                workspace,
            ],
          );
        },
      ),
    );
  }
}

class WorkspaceGrid extends StatelessWidget {
  const WorkspaceGrid({required this.items, this.emptyCellBuilder, super.key});
  final List<WorkspaceGridItem> items;

  /// Empty half-rows before a full-span entry keep the boundary index of that
  /// entry. These transient cells never enter the persisted group sequence.
  final Widget Function(int insertionIndex)? emptyCellBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final twoColumns =
          const MaterialBreakpoints().classify(constraints.maxWidth) !=
          MaterialWidthClass.compact;
      final cells = <Widget>[];
      var halfRow = false;
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        if (twoColumns &&
            halfRow &&
            item.fullWidth &&
            emptyCellBuilder != null) {
          cells.add(
            _GridCell(
              key: ValueKey('workspace_gap_slot_$index'),
              fullWidth: false,
              fillRow: true,
              child: emptyCellBuilder!(index),
            ),
          );
        }
        cells.add(
          _GridCell(
            key: item.key,
            fullWidth: item.fullWidth,
            fillRow: item.fillRow,
            child: item.child,
          ),
        );
        halfRow = twoColumns && !item.fullWidth ? !halfRow : false;
      }
      return _GridLayout(twoColumns: twoColumns, children: cells);
    },
  );
}

class WorkspaceGridItem {
  const WorkspaceGridItem({
    required this.child,
    this.fullWidth = false,
    this.fillRow = false,
    this.key,
  });
  final Widget child;
  final bool fullWidth;
  final bool fillRow;
  final Key? key;
}

/// Full-width entries close a row; medium entries alternate left/right.
bool workspaceHasTrailingHalfSlot(WorkspaceGroups groups) {
  var half = false;
  for (final group in groups) {
    half = group.contains(WorkspaceComponent.diary) ? false : !half;
  }
  return half;
}

typedef WorkspaceDropIntent = ({bool after, bool central, AxisDirection edge});

WorkspaceDropIntent? workspaceDropIntent(
  Offset point,
  Size size, {
  required bool horizontal,
}) => geometry.workspaceDropIntent(point, size, horizontal: horizontal);

class _GridData extends ContainerBoxParentData<RenderBox> {
  bool fullWidth = false;
  bool fillRow = false;
}

class _GridCell extends ParentDataWidget<_GridData> {
  const _GridCell({
    required this.fullWidth,
    required this.fillRow,
    required super.child,
    super.key,
  });
  final bool fullWidth, fillRow;
  @override
  void applyParentData(RenderObject renderObject) {
    final data = renderObject.parentData! as _GridData;
    if (data.fullWidth != fullWidth || data.fillRow != fillRow) {
      data.fullWidth = fullWidth;
      data.fillRow = fillRow;
      renderObject.parent?.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => _GridLayout;
}

class _GridLayout extends MultiChildRenderObjectWidget {
  const _GridLayout({required this.twoColumns, required super.children});
  final bool twoColumns;
  @override
  _GridRender createRenderObject(BuildContext context) =>
      _GridRender(twoColumns);
  @override
  void updateRenderObject(BuildContext context, _GridRender renderObject) {
    if (renderObject.twoColumns != twoColumns) {
      renderObject.twoColumns = twoColumns;
      renderObject.markNeedsLayout();
    }
  }
}

/// Natural-height ordered rows; only the empty append cell stretches to its
/// row. This avoids intrinsic measurement of calendar/chart LayoutBuilders.
class _GridRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridData> {
  _GridRender(this.twoColumns);
  bool twoColumns;
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridData) child.parentData = _GridData();
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final policy = geometry.WorkspaceGeometryPolicy(
      breakpoint: twoColumns ? 0 : double.infinity,
    );
    final children = getChildrenAsList();
    final measures = <geometry.WorkspaceGroupMeasure>[];
    for (final child in children) {
      final data = child.parentData! as _GridData;
      final size = data.fullWidth
          ? model.WorkspaceSize.fullNatural
          : model.WorkspaceSize.twoByTwo;
      child.layout(
        BoxConstraints.tightFor(width: policy.widthFor(width, size)),
        parentUsesSize: true,
      );
      measures.add(
        geometry.WorkspaceGroupMeasure(
          size: size,
          contentHeight: child.size.height,
        ),
      );
    }
    final first = geometry.workspaceGeometry(width, measures, policy: policy);
    for (var index = 0; index < children.length; index++) {
      final child = children[index];
      final data = child.parentData! as _GridData;
      if (!data.fillRow) continue;
      final top = first.groups[index].top;
      final band = [
        for (var i = 0; i < children.length; i++)
          if (first.groups[i].top == top) i,
      ];
      var height = band
          .map((i) => measures[i].contentHeight)
          .fold(0.0, math.max);
      if (band.every((i) => (children[i].parentData! as _GridData).fillRow)) {
        final previous = first.groups.where((rect) => rect.top < top).toList();
        if (previous.isNotEmpty) {
          final lastTop = previous.last.top;
          height = math.max(
            height,
            previous
                .where((r) => r.top == lastTop)
                .map((r) => r.height)
                .fold(0.0, math.max),
          );
        }
      }
      child.layout(
        BoxConstraints.tightFor(
          width: first.groups[index].width,
          height: height,
        ),
        parentUsesSize: true,
      );
      measures[index] = geometry.WorkspaceGroupMeasure(
        size: measures[index].size,
        contentHeight: height,
      );
    }
    final result = geometry.workspaceGeometry(width, measures, policy: policy);
    for (var index = 0; index < children.length; index++) {
      (children[index].parentData! as _GridData).offset =
          result.groups[index].topLeft;
    }
    size = constraints.constrain(Size(width, result.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
