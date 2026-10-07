import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/material/material.dart';
import '../../browsing/providers/browsing_provider.dart';
import '../../browsing/providers/feed_projection_provider.dart';
import 'feed_workspace_controller.dart';

export 'feed_workspace_controller.dart';

/// All callbacks revalidate the rendered query and current capabilities.
/// No copy callback is supplied by the frame. A consumer adding copying must
/// recheck capabilities.copy against the CURRENT sanitized projection.
class FeedRowBinding {
  const FeedRowBinding({
    required this.fragment,
    required this.selected,
    required this.expanded,
    required this.onSelect,
    required this.onToggleDetails,
    required this.onOpenData,
    required this.onFilterApp,
    required this.onFilterWindow,
  });

  final FeedFragment fragment;
  final bool selected;
  final bool expanded;
  final VoidCallback? onSelect;
  final VoidCallback? onToggleDetails;
  final VoidCallback? onOpenData;
  final VoidCallback? onFilterApp;
  final VoidCallback? onFilterWindow;
}

typedef FeedFragmentBuilder =
    Widget Function(BuildContext context, FeedRowBinding binding);
typedef FeedWorkspaceHeaderBuilder =
    Widget Function(
      BuildContext context,
      FeedWorkspaceController controller,
      FeedProjectionState projection,
    );
typedef FeedDetailsBuilder =
    Widget Function(BuildContext context, FeedFragment fragment);
typedef FeedRowExtentBuilder =
    double Function(BuildContext context, MaterialTokens tokens);

/// One vertical CustomScrollView. Summaries have an explicit row extent so an
/// unmounted target can be positioned exactly without measuring all prior rows.
/// Inline details have natural height and join the same scroll axis.
///
/// Consumer contract:
/// - fragmentBuilder must fit rowExtentBuilder's finite height; use compact
///   summaries and put lengthy evidence in detailsBuilder.
/// - header/details/status builders must not add vertical scrollables.
/// - mount beneath MaterialScope and retain the shared ProviderScope.
/// - keep this widget's key stable across width classes.
/// - retained offstage routes must pass active=false, then true on re-entry.
/// - onOpenData navigates using shared state; do not serialize window titles.
/// - Feed controls use the controller's range/filter actions to restore views;
///   data workspace controls use BrowsingNotifier's explicit locate actions.
class FeedWorkspaceFrame extends ConsumerStatefulWidget {
  const FeedWorkspaceFrame({
    super.key,
    required this.fragmentBuilder,
    required this.detailsBuilder,
    required this.onOpenData,
    this.headerBuilder,
    this.statusBuilder,
    this.rowExtentBuilder,
    this.active = true,
  });

  final FeedFragmentBuilder fragmentBuilder;
  final FeedDetailsBuilder detailsBuilder;
  final VoidCallback onOpenData;
  final FeedWorkspaceHeaderBuilder? headerBuilder;
  final FeedWorkspaceHeaderBuilder? statusBuilder;
  final FeedRowExtentBuilder? rowExtentBuilder;
  final bool active;

  @override
  ConsumerState<FeedWorkspaceFrame> createState() => FeedWorkspaceFrameState();
}

/// Public State exposes controller/scrollController for the separately owned
/// acceptance tests; no test files or additional production paths are required.
class FeedWorkspaceFrameState extends ConsumerState<FeedWorkspaceFrame>
    implements FeedViewportPort {
  late final FeedWorkspaceController controller;
  final ScrollController scrollController = ScrollController(
    keepScrollOffset: false,
  );
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _detailsKey = GlobalKey();
  late final ProviderSubscription<FeedProjectionState> _subscription;
  _FeedGeometry? _geometry;
  FeedViewportCapture? _beforeLayout;
  BrowsingQueryIdentity? _renderedQuery;
  List<FeedFragment> _renderedRows = const [];
  double _rowExtent = 112;
  double _width = 0;
  int _expandedIndex = -1;
  bool _scheduled = false;
  bool _driving = false;
  bool _driveAgain = false;
  bool _saveScheduled = false;

  @override
  void initState() {
    super.initState();
    controller = FeedWorkspaceController(
      readProjection: () => ref.read(feedProjectionProvider),
      readBrowsing: () => ref.read(browsingProvider.notifier),
      onOpenData: () => widget.onOpenData(),
    )..attach(this);
    controller.addListener(_onControllerChanged);
    _subscription = ref.listenManual(feedProjectionProvider, (_, _) {
      _schedule();
    });
    scrollController.addListener(_scheduleViewportSave);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      controller.setActive(widget.active);
      _schedule();
    });
  }

  @override
  void didUpdateWidget(FeedWorkspaceFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      // These local operations do not write providers during parent build.
      // Invalidate before layout can queue a save of inherited/clamped pixels.
      if (widget.active) {
        controller.invalidateRestoration();
      } else {
        controller.cancelAutomaticScroll();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        controller.setActive(widget.active);
        _schedule();
      });
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _schedule();
  }

  void _scheduleViewportSave() {
    if (!mounted || !widget.active || controller.isMoving || _saveScheduled)
      return;
    _saveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _saveScheduled = false;
      if (mounted && widget.active && !controller.isMoving) {
        controller.rememberViewport();
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _schedule() {
    if (!mounted) return;
    if (_driving) {
      _driveAgain = true;
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _scheduled = false;
      if (!mounted) return;
      _measureGeometry();
      _driving = true;
      try {
        if (widget.active) await controller.synchronize();
      } finally {
        _driving = false;
        if (_driveAgain && mounted) {
          _driveAgain = false;
          _schedule();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _onSizeChanged(SizeChangedLayoutNotification notification) {
    // Header copy, status messages and asynchronously loaded detail content can
    // change height without rebuilding this State. Capture against the last
    // measured geometry, then run the usual post-layout compensation pass.
    if (mounted && widget.active && !controller.isMoving) {
      _beforeLayout ??= capture();
      _schedule();
    }
    return false;
  }

  double _height(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : 0;
  }

  void _measureGeometry() {
    final query = _renderedQuery;
    if (query == null || !scrollController.hasClients) {
      _geometry = null;
      _beforeLayout = null;
      return;
    }
    final previous = _geometry;
    final next = _FeedGeometry(
      query: query,
      rows: _renderedRows,
      rowExtent: _rowExtent,
      headerHeight: _height(_headerKey),
      detailHeight: _expandedIndex < 0 ? 0 : _height(_detailsKey),
      expandedIndex: _expandedIndex,
      width: _width,
      viewportHeight: scrollController.position.viewportDimension,
    );
    _geometry = next;
    final captureBefore = _beforeLayout;
    _beforeLayout = null;
    if (previous != null &&
        previous.query == query &&
        captureBefore != null &&
        next.layoutDiffers(previous)) {
      controller.queueGeometryRestore(captureBefore);
    }
  }

  @override
  FeedViewportCapture? capture() {
    final geometry = _geometry;
    if (geometry == null || !scrollController.hasClients) return null;
    final pixels = math.max(0.0, scrollController.position.pixels);
    if (geometry.rows.isEmpty) {
      return FeedViewportCapture(
        query: geometry.query,
        fragmentKey: null,
        localOffset: 0,
        pixelOffset: pixels,
      );
    }
    final relative = pixels - geometry.headerHeight;
    var index = 0;
    if (relative > 0) {
      final detailStart = (geometry.expandedIndex + 1) * geometry.rowExtent;
      if (geometry.expandedIndex >= 0 && relative >= detailStart) {
        index = relative < detailStart + geometry.detailHeight
            ? geometry.expandedIndex
            : ((relative - geometry.detailHeight) / geometry.rowExtent).floor();
      } else {
        index = (relative / geometry.rowExtent).floor();
      }
    }
    index = index.clamp(0, geometry.rows.length - 1).toInt();
    return FeedViewportCapture(
      query: geometry.query,
      fragmentKey: geometry.rows[index].key,
      localOffset: pixels - geometry.rowStart(index),
      pixelOffset: pixels,
    );
  }

  @override
  bool isReadyFor(BrowsingQueryIdentity query) =>
      mounted &&
      widget.active &&
      _renderedQuery == query &&
      _geometry?.query == query &&
      scrollController.hasClients &&
      scrollController.position.hasContentDimensions;

  @override
  Future<bool> restore(
    FeedViewportTarget target,
    bool Function() isCurrent,
  ) async {
    // The guard includes the locate intent as well as projection identity.
    // Bounded correction handles header wrapping and the newly mounted details.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!mounted || !widget.active || !isCurrent()) return false;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !widget.active || !isCurrent()) return false;
      _measureGeometry();
      if (!isReadyFor(target.query)) return false;
      final geometry = _geometry!;
      final index = target.index;
      double desired;
      if (index == null) {
        desired = target.pixelOffset;
      } else {
        if (index < 0 || index >= geometry.rows.length) return false;
        final extent =
            geometry.rowExtent +
            (index == geometry.expandedIndex ? geometry.detailHeight : 0);
        // An anchor inside a collapsed detail remains attached to its summary.
        final local = math.min(target.localOffset, math.max(0.0, extent - 1));
        desired = geometry.rowStart(index) + local;
      }
      final position = scrollController.position;
      desired = desired
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((position.pixels - desired).abs() <= 0.5) return true;
      if (!isCurrent() || !widget.active) return false;
      scrollController.jumpTo(desired);
    }
    // A final measurement confirms the bounded correction actually converged.
    if (!mounted || !widget.active || !isCurrent()) return false;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !widget.active || !isCurrent()) return false;
    _measureGeometry();
    if (!isReadyFor(target.query)) return false;
    final geometry = _geometry!;
    final index = target.index;
    if (index != null && (index < 0 || index >= geometry.rows.length))
      return false;
    final extent = index == null
        ? 0.0
        : geometry.rowExtent +
              (index == geometry.expandedIndex ? geometry.detailHeight : 0);
    final desired =
        (index == null
                ? target.pixelOffset
                : geometry.rowStart(index) +
                      math.min(target.localOffset, math.max(0.0, extent - 1)))
            .clamp(
              scrollController.position.minScrollExtent,
              scrollController.position.maxScrollExtent,
            )
            .toDouble();
    return (scrollController.position.pixels - desired).abs() <= 0.5;
  }

  Widget _defaultStatus(BuildContext context, FeedProjectionState state) {
    final messages = <String>[];
    final shown = state.projection;
    if (state.isPreviousRange && shown != null) {
      messages.add(
        '当前仍显示 ${shown.requestedStartUtc.toLocal()} 至 '
        '${shown.requestedEndUtc.toLocal()} 的结果；所选范围尚未就绪。',
      );
    } else if (state.isRefreshing) {
      messages.add('正在更新，已有片段仍可浏览。');
    }
    if (state.failure != null) {
      messages.add('本地数据读取失败，已有结果和选择仍保留，可重试。');
    }
    if (state.selectionInvalidationReason != null) {
      messages.add(
        selectionInvalidationMessage(state.selectionInvalidationReason),
      );
    }
    if (controller.notice != null) messages.add(controller.notice!.message);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.isInitialLoading)
          Semantics(label: '正在读取本地时间流', child: LinearProgressIndicator()),
        for (final message in messages)
          Padding(
            padding: const EdgeInsets.only(bottom: MaterialTokens.spaceSm),
            child: Text(message),
          ),
        if (state.failure != null || controller.notice != null)
          Wrap(
            spacing: MaterialTokens.spaceSm,
            children: [
              if (state.failure != null)
                MaterialIconButton(
                  tooltip: '重试读取本地数据',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => unawaited(controller.refresh()),
                ),
              if (controller.notice != null)
                MaterialIconButton(
                  tooltip: '关闭浏览位置提示',
                  icon: const Icon(Icons.close),
                  onPressed: controller.dismissNotice,
                ),
            ],
          ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    FeedProjectionState state,
    FeedFragment fragment,
    double inset,
  ) {
    final query = state.displayedQuery!;
    final enabled = widget.active && state.canInteract;
    final caps = fragment.capabilities;
    final private = fragment.isPrivacyExcluded;
    final binding = FeedRowBinding(
      fragment: fragment,
      selected: state.browsing.selectedAnchor?.fragmentKey == fragment.key,
      expanded: controller.expandedFragment?.key == fragment.key,
      onSelect: enabled
          ? () {
              controller.selectFragment(fragment.key, query);
            }
          : null,
      onToggleDetails:
          enabled && !private && (caps.inspectSource || caps.showEntityDetails)
          ? () {
              controller.toggleDetails(fragment.key, query);
            }
          : null,
      onOpenData: enabled
          ? () {
              controller.openData(fragmentKey: fragment.key, query: query);
            }
          : null,
      onFilterApp: enabled && !private && caps.filterApp
          ? () => unawaited(controller.filterApp(fragment.key, query))
          : null,
      onFilterWindow: enabled && !private && caps.filterWindow
          ? () => unawaited(controller.filterWindow(fragment.key, query))
          : null,
    );
    return Semantics(
      key: ValueKey(fragment.key),
      selected: binding.selected,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: widget.fragmentBuilder(context, binding),
      ),
    );
  }

  Widget _segment(
    FeedProjectionState state,
    int start,
    int count,
    double inset,
  ) {
    final rows = _renderedRows;
    final indices = <String, int>{
      for (var i = 0; i < count; i++) rows[start + i].key: i,
    };
    return SliverFixedExtentList(
      itemExtent: _rowExtent,
      delegate: SliverChildBuilderDelegate(
        (context, index) => _row(context, state, rows[start + index], inset),
        childCount: count,
        addAutomaticKeepAlives: false,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? indices[key.value] : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(feedProjectionProvider);
    final tokens = MaterialScope.of(context).tokens;
    return LayoutBuilder(
      builder: (context, constraints) {
        final query = state.displayedQuery;
        if (_geometry?.query == query) {
          _beforeLayout ??= capture();
        } else {
          // Drop old-query UI measurements rather than retaining a second cache
          // of entity identifiers or restoring pixels against another generation.
          _geometry = null;
          _beforeLayout = null;
        }
        _renderedQuery = query;
        _renderedRows = state.fragments;
        _width = constraints.maxWidth;
        final requestedExtent =
            widget.rowExtentBuilder?.call(context, tokens) ??
            math.max(
              112.0,
              MediaQuery.textScalerOf(context).scale(16) * 6 + 16,
            );
        if (!requestedExtent.isFinite ||
            requestedExtent < MaterialTokens.minimumTarget) {
          throw ArgumentError(
            'Feed row extent must be finite and at least 44.',
          );
        }
        _rowExtent = requestedExtent;
        final expanded = controller.expandedFragment;
        _expandedIndex = expanded == null
            ? -1
            : _renderedRows.indexWhere((row) => row.key == expanded.key);
        final split = _expandedIndex < 0
            ? _renderedRows.length
            : _expandedIndex + 1;
        final inset = tokens.pageInset;
        _schedule();
        return StableContentSurface(
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: _onSizeChanged,
            child: Scrollbar(
              controller: scrollController,
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth == 0 &&
                      notification is UserScrollNotification &&
                      notification.direction != ScrollDirection.idle) {
                    controller.acceptUserScroll();
                  }
                  return false;
                },
                child: CustomScrollView(
                  controller: scrollController,
                  primary: false,
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizeChangedLayoutNotifier(
                        child: Padding(
                          key: _headerKey,
                          padding: EdgeInsets.all(inset),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (widget.headerBuilder != null)
                                widget.headerBuilder!(
                                  context,
                                  controller,
                                  state,
                                ),
                              _defaultStatus(context, state),
                              if (widget.statusBuilder != null)
                                widget.statusBuilder!(
                                  context,
                                  controller,
                                  state,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _segment(state, 0, split, inset),
                    SliverToBoxAdapter(
                      child: SizeChangedLayoutNotifier(
                        child: Padding(
                          key: _detailsKey,
                          padding: _expandedIndex < 0
                              ? EdgeInsets.zero
                              : EdgeInsets.fromLTRB(
                                  inset,
                                  0,
                                  inset,
                                  MaterialTokens.spaceLg,
                                ),
                          child: _expandedIndex < 0
                              ? const SizedBox.shrink()
                              : widget.detailsBuilder(
                                  context,
                                  _renderedRows[_expandedIndex],
                                ),
                        ),
                      ),
                    ),
                    _segment(state, split, _renderedRows.length - split, inset),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(inset),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (state.isEmpty) const Text('此范围和筛选下没有片段。'),
                            if (state.canLoadMore || controller.isAppending)
                              TextButton(
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(44, 44),
                                ),
                                onPressed:
                                    controller.isAppending || !widget.active
                                    ? null
                                    : () => unawaited(controller.loadMore()),
                                child: Text(
                                  controller.isAppending ? '正在展开…' : '显示更多片段',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _subscription.close();
    controller.removeListener(_onControllerChanged);
    controller.dispose();
    scrollController.removeListener(_scheduleViewportSave);
    scrollController.dispose();
    _geometry = null;
    _beforeLayout = null;
    _renderedRows = const [];
    _renderedQuery = null;
    super.dispose();
  }
}

class _FeedGeometry {
  const _FeedGeometry({
    required this.query,
    required this.rows,
    required this.rowExtent,
    required this.headerHeight,
    required this.detailHeight,
    required this.expandedIndex,
    required this.width,
    required this.viewportHeight,
  });

  final BrowsingQueryIdentity query;
  final List<FeedFragment> rows;
  final double rowExtent;
  final double headerHeight;
  final double detailHeight;
  final int expandedIndex;
  final double width;
  final double viewportHeight;

  double rowStart(int index) =>
      headerHeight +
      index * rowExtent +
      (expandedIndex >= 0 && index > expandedIndex ? detailHeight : 0);

  bool layoutDiffers(_FeedGeometry other) =>
      rowExtent != other.rowExtent ||
      headerHeight != other.headerHeight ||
      detailHeight != other.detailHeight ||
      expandedIndex != other.expandedIndex ||
      width != other.width ||
      viewportHeight != other.viewportHeight;
}
