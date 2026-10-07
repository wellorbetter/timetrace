import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../bridge/accounting.dart';
import '../../../core/material/material.dart';
import '../../../core/preferences/presentation_preferences_provider.dart';
import '../../../core/widgets/app_icon.dart';
import '../../../core/widgets/terminal_app_icon.dart';
import 'feed_filter_control.dart';
import '../../../core/format/app_identity.dart';
import '../../browsing/presentation/date_range_control.dart';
import '../../browsing/presentation/recap_button.dart';
import '../../browsing/providers/browsing_provider.dart';
import '../../browsing/providers/feed_projection_provider.dart';
import '../../dashboard/presentation/widgets/app_color.dart';
import '../../dashboard/providers/dashboard_provider.dart';
import '../providers/feed_preferences_provider.dart';

/// Finite seek ceiling; null rejects invalid geometry before scheduling work.
/// log2(span / .5) is computed without doubling a potentially maximal double.
int? feedAnchorSeekBudget(int segmentCount, double span) {
  if (segmentCount < 0 || !span.isFinite || span <= 0) return null;
  final levels = math.max(0, (math.log(span) / math.ln2 + 1).ceil());
  return segmentCount + 2 * levels + 4;
}

/// OpenHistory-style semantic timeline.
///
/// Canonical fragments remain the only source of truth. This screen only groups
/// adjacent, sanitized fragments for presentation so the primary object is a
/// human-readable activity period rather than a raw accounting state.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  static const _batchSize = 1200;
  static const _maxAutomaticBatches = 8;

  final _scrollController = ScrollController();
  String? _expandedKey;
  int? _temporaryBucketMinutes;
  bool _batchScheduled = false;
  int _automaticBatches = 0;
  Object? _layoutKey;
  int _layoutGeneration = 0;
  Object? _scheduledTicket;
  Object? _lastProgress;
  BrowsingQueryIdentity? _renderedQuery;
  Object? _restorationKey;
  Object? _restorationTicket;
  bool _restoring = false;
  bool _viewportSaveScheduled = false;
  final _cardKeys = <String, GlobalKey>{};
  final _cardAnchors = <String, String>{};
  List<String> _filterApps = const [];
  List<FeedFilter> _filterWindows = const [];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_restoring) return;
    final captured = _renderedQuery;
    if (captured != null &&
        _scrollController.hasClients &&
        _scrollController.position.userScrollDirection !=
            ScrollDirection.idle) {
      if (!_viewportSaveScheduled) {
        _viewportSaveScheduled = true;
        // Scroll notifications precede layout. Save boxes and pixels from the
        // same completed frame, never stale box positions against new pixels.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _viewportSaveScheduled = false;
          if (!mounted ||
              _restoring ||
              captured != _renderedQuery ||
              !_scrollController.hasClients)
            return;
          _saveViewport(captured);
        });
      }
    }
    if (!_scrollController.hasClients ||
        _scrollController.position.extentAfter >
            _scrollController.position.viewportDimension * .5) {
      return;
    }
    _scheduleMore(autoFill: true);
  }

  void _saveViewport(BrowsingQueryIdentity captured) {
    String? anchor;
    var closest = double.infinity;
    var localOffset = 0.0;
    final viewport = _scrollController.position.context.storageContext
        .findRenderObject();
    final top = viewport is RenderBox
        ? viewport.localToGlobal(Offset.zero).dy
        : 0.0;
    for (final entry in _cardKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final offset = box.localToGlobal(Offset.zero).dy - top;
      if (offset + box.size.height > 0 && offset.abs() < closest) {
        closest = offset.abs();
        anchor = _cardAnchors[entry.key];
        localOffset = -offset;
      }
    }
    ref
        .read(browsingProvider.notifier)
        .saveViewport(
          query: captured,
          fragmentKey: anchor,
          localOffset: localOffset,
          pixelOffset: _scrollController.offset,
        );
    final layout = _layoutKey;
    if (layout != null) {
      ref
          .read(feedPresentationMemoProvider)
          .rememberViewport(layout, _scrollController.offset);
    }
  }

  void _restoreAnchor(
    BrowsingQueryIdentity query,
    int epoch,
    BrowsingViewState memory,
    List<_ActivitySegment> segments,
  ) {
    final ticket = Object();
    _restorationTicket = ticket;
    _restoring = true;
    final anchor = memory.viewportAnchor;
    final index = anchor == null
        ? -1
        : segments.indexWhere(
            (segment) => segment.fragments.any(
              (fragment) => fragment.key == anchor.fragmentKey,
            ),
          );
    final indices = {
      for (var i = 0; i < segments.length; i++) segments[i].key: i,
    };
    // Pixel hints are seeds, never evidence that the canonical target was found.
    // Same query generation alone does not prove width/font/expanded geometry.
    final seed =
        memory.pixelOffsetGeneration == query.generation && _layoutKey != null
        ? ref
              .read(feedPresentationMemoProvider)
              .viewportSeed(_layoutKey!, memory.pixelOffset)
        : null;
    var attempts = 0;
    // Independent from automatic loading's eight batches. Budget is derived
    // from the finite dataset and measured pixel span at half-pixel resolution,
    // not a fixed number of viewport-size jumps. Each changing geometry/query
    // cancels this ticket; invalid/non-progressing geometry stops explicitly.
    var searchBudget = segments.length + 4;
    double lower = 0;
    double? upper;
    var stride = 0.0;
    var previousStride = 0.0;
    var lastDirection = 0;
    var started = false;
    var alignments = 0;
    var previousAlignmentError = double.infinity;
    void finish({required bool found}) {
      _restoring = false;
      ref
          .read(feedDiagnosticsProvider)
          ?.call(
            found
                ? FeedDiagnosticEvent.anchorRestored
                : FeedDiagnosticEvent.anchorUnresolved,
          );
      if (!found) {
        // Retain canonical memory. An exhausted/no-progress seek is not a
        // successful restore and must not silently replace it with wrong pixels.
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('未能还原保存的滚动位置，原位置记录已保留')));
      }
    }

    void restore(Duration _) {
      if (!mounted ||
          epoch != _layoutGeneration ||
          query != _renderedQuery ||
          !identical(_restorationTicket, ticket) ||
          !_scrollController.hasClients) {
        if (identical(_restorationTicket, ticket)) _restoring = false;
        return;
      }
      final position = _scrollController.position;
      final span = position.maxScrollExtent + position.viewportDimension + 1;
      final measuredBudget = feedAnchorSeekBudget(segments.length, span);
      if (measuredBudget == null) {
        finish(found: false);
        return;
      }
      searchBudget = math.max(searchBudget, measuredBudget);
      ref.read(feedDiagnosticsProvider)?.call(FeedDiagnosticEvent.anchorSeek);
      if (index < 0) {
        _scrollController.jumpTo(
          (seed ?? 0).clamp(0, position.maxScrollExtent),
        );
        _restoring = false;
        return;
      }
      final target = _cardKeys[segments[index].key]?.currentContext
          ?.findRenderObject();
      final viewport = position.context.storageContext.findRenderObject();
      if (target is RenderBox && target.hasSize && viewport is RenderBox) {
        final relative =
            target.localToGlobal(Offset.zero).dy -
            viewport.localToGlobal(Offset.zero).dy;
        final destination = (position.pixels + relative + memory.localOffset)
            .clamp(0, position.maxScrollExtent)
            .toDouble();
        if ((destination - position.pixels).abs() <= .5) {
          finish(found: true);
        } else if ((destination - position.pixels).abs() <
                previousAlignmentError &&
            ++alignments <= searchBudget) {
          previousAlignmentError = (destination - position.pixels).abs();
          _scrollController.jumpTo(destination);
          // Verify real mounted geometry after layout, not boxes from the
          // pre-jump frame. No callback is scheduled when already aligned.
          WidgetsBinding.instance.addPostFrameCallback(restore);
        } else {
          finish(found: false);
        }
        return;
      }
      if (++attempts > searchBudget) {
        finish(found: false);
        return;
      }
      var destination =
          seed ??
          (segments.length <= 1
              ? 0.0
              : position.maxScrollExtent * index / (segments.length - 1));
      if (started) {
        final mountedRows = <(int, double, double)>[];
        for (final entry in _cardKeys.entries) {
          final rowIndex = indices[entry.key];
          final box = entry.value.currentContext?.findRenderObject();
          if (rowIndex == null || box is! RenderBox || !box.hasSize) continue;
          final top = box.localToGlobal(Offset.zero).dy;
          mountedRows.add((rowIndex, top, box.size.height));
        }
        mountedRows.sort((a, b) => a.$1.compareTo(b.$1));
        if (mountedRows.isEmpty) {
          finish(found: false);
          return;
        }
        final first = mountedRows.first, last = mountedRows.last;
        if (index >= first.$1 && index <= last.$1) {
          finish(found: false); // Invalid/discontinuous measurements, no spin.
          return;
        }
        final direction = index < first.$1 ? -1 : 1;
        if (direction < 0) {
          upper = upper == null
              ? position.pixels
              : math.min(upper!, position.pixels);
        } else {
          lower = math.max(lower, position.pixels);
        }
        if (upper != null) {
          // Actual mounted index bounds, not maxExtent's uniform-row estimate.
          destination = (lower + upper!) / 2;
        } else {
          final measuredExtent = last.$1 == first.$1
              ? math.max(1.0, last.$3)
              : math.max(1.0, (last.$2 - first.$2) / (last.$1 - first.$1));
          final distance = direction < 0 ? first.$1 - index : index - last.$1;
          final estimate = distance * measuredExtent;
          stride = math.max(position.viewportDimension * .8, estimate);
          if (direction == lastDirection) {
            stride = math.max(stride, previousStride * 2);
          }
          destination = position.pixels + direction * stride;
        }
        lastDirection = direction;
      }
      started = true;
      destination = destination.clamp(0, position.maxScrollExtent);
      if ((destination - position.pixels).abs() < .5) {
        finish(found: false);
        return;
      }
      previousStride = (destination - position.pixels).abs();
      _scrollController.jumpTo(destination);
      WidgetsBinding.instance.addPostFrameCallback(restore);
    }

    WidgetsBinding.instance.addPostFrameCallback(restore);
  }

  void _scheduleMore({bool autoFill = false}) {
    final captured = _renderedQuery;
    final current = ref.read(feedProjectionProvider);
    if (captured == null ||
        current.displayedQuery != captured ||
        !current.canInteract ||
        current.isRefreshing ||
        current.failure != null ||
        !current.canLoadMore)
      return;
    if (_batchScheduled ||
        (autoFill && _automaticBatches >= _maxAutomaticBatches)) {
      return;
    }
    _batchScheduled = true;
    final epoch = _layoutGeneration;
    final ticket = Object();
    _scheduledTicket = ticket;
    final fingerprint = (
      captured,
      current.projection,
      current.fragments.length,
    );
    if (autoFill && fingerprint == _lastProgress) {
      _batchScheduled = false;
      _scheduledTicket = null;
      return;
    }
    void apply(Duration _) {
      if (!mounted ||
          epoch != _layoutGeneration ||
          !identical(_scheduledTicket, ticket))
        return;
      _batchScheduled = false;
      _scheduledTicket = null;
      final projection = ref.read(feedProjectionProvider);
      if (projection.displayedQuery == captured &&
          projection.requestedQuery == captured &&
          projection.canLoadMore &&
          projection.canInteract &&
          !projection.isRefreshing &&
          projection.failure == null) {
        if (autoFill) _automaticBatches++;
        _lastProgress = fingerprint;
        ref.read(feedDiagnosticsProvider)?.call(FeedDiagnosticEvent.fill);
        ref
            .read(browsingProvider.notifier)
            .loadMore(count: _batchSize, query: captured);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.postFrameCallbacks) {
      apply(Duration.zero);
    } else {
      WidgetsBinding.instance.addPostFrameCallback(apply);
      setState(() {}); // One bounded intent, never an autonomous ticker.
    }
  }

  @override
  Widget build(BuildContext context) {
    final projection = ref.watch(feedProjectionProvider);
    final diagnostics = ref.read(feedDiagnosticsProvider);
    diagnostics?.call(FeedDiagnosticEvent.build);
    ref.listen<int>(feedBucketMinutesProvider, (previous, next) {
      if (previous != next)
        setState(() {
          _temporaryBucketMinutes = null;
          _expandedKey = null;
        });
    });
    final int bucketMinutes =
        _temporaryBucketMinutes ?? ref.watch(feedBucketMinutesProvider);
    final source = projection.projection;
    final count = projection.viewState.visibleCount;
    // Canonical source already passed response validation and privacy sanitizing.
    // Include displayed identity (never the requested identity of stale data).
    final zone = (
      source?.requestedStartUtc.toLocal().timeZoneName,
      source?.requestedStartUtc.toLocal().timeZoneOffset,
      source?.requestedEndUtc.toLocal().timeZoneName,
      source?.requestedEndUtc.toLocal().timeZoneOffset,
    );
    final memo = ref.read(feedPresentationMemoProvider);
    _FeedPresentation createPresentation() {
      diagnostics?.call(FeedDiagnosticEvent.filtering);
      final apps = <String>{};
      final windows = <FeedFilter>{};
      for (final row
          in projection.choiceProjection?.allFragments ??
              const <FeedFragment>[]) {
        if (row.capabilities.filterApp) apps.add(row.appDisplayName!);
        final window = FeedFilter.forWindow(row);
        if (window != null) windows.add(window);
      }
      diagnostics?.call(FeedDiagnosticEvent.grouping);
      final rows = projection.canInteract
          ? source?.fragments.reversed.take(count).toList(growable: false) ??
                const <FeedFragment>[]
          : const <FeedFragment>[];
      return _FeedPresentation(
        developer.Timeline.timeSync(
          'TimeTrace feed grouping',
          () => _ActivitySegment.group(
            rows,
            bucketSize: Duration(minutes: bucketMinutes),
          ),
        ),
        apps.toList(growable: false),
        windows.toList(growable: false),
      );
    }

    final presentation = projection.canInteract
        ? memo.derive((
            projection.displayedQuery,
            source,
            projection.choiceProjection,
            count,
            bucketMinutes,
            zone,
          ), createPresentation)
        : createPresentation();
    final segments = presentation.segments;
    final keys = segments.map((segment) => segment.key).toSet();
    _cardKeys.removeWhere((key, _) => !keys.contains(key));
    _cardAnchors.clear();
    _filterApps = presentation.apps;
    _filterWindows = presentation.windows;
    _renderedQuery = projection.displayedQuery;
    final displayMode = ref.watch(feedDisplayModeProvider);
    final toolbarAlignment = ref.watch(feedToolbarAlignmentProvider);
    final selectedKey = projection.browsing.selectedAnchor?.fragmentKey;
    final appPaths = ref
        .watch(dashboardProvider)
        .maybeWhen(
          data: (state) {
            final current = projection.projection;
            if (current == null ||
                !projection.canInteract ||
                DateTime.tryParse(state.requestedStartUtc) !=
                    current.requestedStartUtc ||
                DateTime.tryParse(state.requestedEndUtc) !=
                    current.requestedEndUtc ||
                current.hasPrivacyExcluded)
              return const <String, String>{};
            final paths = <String, String>{};
            for (final app in state.apps) {
              final path = app.exePath;
              if (path == null || path.isEmpty) continue;
              paths[app.appName] = path;
              paths[_appKey(app.appName)] = path;
            }
            return paths;
          },
          orElse: () => const <String, String>{},
        );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final tokens = MaterialTokens.forWidth(constraints.maxWidth);
          final scaler = MediaQuery.textScalerOf(context);
          final layoutKey = (
            projection.requestedQuery,
            projection.displayedQuery,
            constraints.maxWidth,
            constraints.maxHeight,
            scaler.scale(14),
            scaler.scale(20),
            bucketMinutes,
            _expandedKey,
            toolbarAlignment,
            scaler.scale(Theme.of(context).textTheme.bodySmall?.fontSize ?? 14),
            _feedRangeLabel(projection.browsing.range),
            Theme.of(context).textTheme.bodySmall,
          );
          if (_layoutKey != layoutKey) {
            _layoutKey = layoutKey;
            _layoutGeneration++;
            _automaticBatches = 0;
            _lastProgress = null;
            _batchScheduled = false;
            _scheduledTicket = null;
            _restoring = false;
          }
          final measuredEpoch = _layoutGeneration;
          final measuredQuery = projection.displayedQuery;
          final restorationKey = (
            measuredQuery,
            constraints.maxWidth,
            constraints.maxHeight,
            scaler.scale(14),
            scaler.scale(20),
            bucketMinutes,
            toolbarAlignment,
            scaler.scale(Theme.of(context).textTheme.bodySmall?.fontSize ?? 14),
            _feedRangeLabel(projection.browsing.range),
            Theme.of(context).textTheme.bodySmall,
          );
          if (projection.canInteract &&
              measuredQuery != null &&
              _restorationKey != restorationKey) {
            _restorationKey = restorationKey;
            _restoreAnchor(
              measuredQuery,
              measuredEpoch,
              projection.viewState,
              segments,
            );
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                measuredEpoch != _layoutGeneration ||
                measuredQuery != _renderedQuery ||
                !_scrollController.hasClients)
              return;
            final position = _scrollController.position;
            // Real laid-out content (including header/expanded rows/font scale),
            // not a guessed number of buckets. The callback never schedules a frame.
            if (!_restoring &&
                position.extentBefore == 0 &&
                position.extentAfter <= .5)
              _scheduleMore(autoFill: true);
          });
          final inset =
              tokens.pageInset +
              ((constraints.maxWidth - 960).clamp(0, double.infinity) / 2);
          return CustomScrollView(
            key: const PageStorageKey('semantic-activity-feed'),
            controller: _scrollController,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  MaterialTokens.spaceSm,
                  inset,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: _FeedHeader(
                    alignment: toolbarAlignment,
                    projection: projection,
                    apps: _filterApps,
                    windows: _filterWindows,
                    onFilter: (filter) => unawaited(
                      ref.read(browsingProvider.notifier).setFilter(filter),
                    ),
                    bucketMinutes: bucketMinutes,
                    onOpenData: _openData,
                    onBucketMinutes: (minutes) {
                      setState(() {
                        _temporaryBucketMinutes = minutes;
                        _expandedKey = null;
                        _automaticBatches = 0;
                      });
                    },
                    onRange: (range) => unawaited(
                      ref
                          .read(browsingProvider.notifier)
                          .setRange(DateRangeSelection(range)),
                    ),
                    onDay: (day) => unawaited(
                      ref.read(browsingProvider.notifier).selectDay(day),
                    ),
                    onRefresh: () => unawaited(
                      ref.read(browsingProvider.notifier).refresh(),
                    ),
                    onClearFilter: () => unawaited(
                      ref.read(browsingProvider.notifier).clearFilter(),
                    ),
                  ),
                ),
              ),
              if (projection.isInitialLoading ||
                  (projection.isPreviousRange && projection.isRefreshing))
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _FeedMessage.loading(),
                )
              else if (projection.failure != null &&
                  (projection.projection == null || projection.isPreviousRange))
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _FeedMessage(
                    icon: Icons.cloud_off_outlined,
                    title: '时间流暂时无法读取',
                    description: _failureText(projection.failure!),
                    actionLabel: '重试',
                    onAction: () => unawaited(
                      ref.read(browsingProvider.notifier).refresh(),
                    ),
                  ),
                )
              else if (segments.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _FeedMessage(
                    icon: Icons.hourglass_empty_rounded,
                    title: projection.browsing.filter == const FeedFilter()
                        ? '这个范围还没有活动记录'
                        : '没有匹配筛选的活动',
                    description:
                        projection.browsing.filter == const FeedFilter()
                        ? '开始使用应用后，连续活动会在这里整理成时间段。'
                        : '可更改或清除筛选；不会生成记录来填满页面。',
                    actionLabel:
                        projection.browsing.filter == const FeedFilter()
                        ? null
                        : '清除筛选',
                    onAction: projection.browsing.filter == const FeedFilter()
                        ? null
                        : () => unawaited(
                            ref.read(browsingProvider.notifier).clearFilter(),
                          ),
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    MaterialTokens.spaceSm,
                    inset,
                    MaterialTokens.spaceXl,
                  ),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      if (index == segments.length) {
                        return Padding(
                          padding: EdgeInsets.only(
                            top: MaterialTokens.spaceSm,
                            left:
                                tokens.widthClass == MaterialWidthClass.compact
                                ? 0
                                : 94,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (projection.canLoadMore && _batchScheduled)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 8),
                                    child: SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.8,
                                      ),
                                    ),
                                  ),
                                Text(
                                  projection.canLoadMore
                                      ? _batchScheduled
                                            ? '正在准备更早记录…'
                                            : '继续向下滚动查看更早记录'
                                      : '已显示当前范围的全部记录',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                                if (projection.canLoadMore)
                                  MaterialActionButton(
                                    key: const Key('feed_load_more'),
                                    onPressed:
                                        projection.canInteract &&
                                            !_batchScheduled
                                        ? () => _scheduleMore()
                                        : null,
                                    child: const Text('加载更多'),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }
                      final segment = segments[index];
                      _cardAnchors[segment.key] = segment.anchor.key;
                      final expanded = _expandedKey == segment.key;
                      final selected = segment.fragments.any(
                        (fragment) => fragment.key == selectedKey,
                      );
                      diagnostics?.call(FeedDiagnosticEvent.cardBuild);
                      final card = _ActivityCard(
                        key: ValueKey('feed_activity:${segment.key}'),
                        segment: segment,
                        appPaths: appPaths,
                        compact:
                            tokens.widthClass == MaterialWidthClass.compact,
                        expanded: expanded,
                        selected: selected,
                        enabled: projection.canInteract,
                        displayMode: displayMode,
                        onToggle: () {
                          _selectSegment(segment, projection.displayedQuery);
                          setState(() {
                            _expandedKey = expanded ? null : segment.key;
                          });
                        },
                        onAction: (action) => _handleAction(
                          action,
                          segment,
                          projection.displayedQuery,
                        ),
                      );
                      return KeyedSubtree(
                        key: _cardKeys.putIfAbsent(segment.key, GlobalKey.new),
                        child: diagnostics == null
                            ? card
                            : _FeedPaintProbe(
                                onPaint: () =>
                                    diagnostics(FeedDiagnosticEvent.paint),
                                child: card,
                              ),
                      );
                    }, childCount: segments.length + 1),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _selectSegment(
    _ActivitySegment segment,
    BrowsingQueryIdentity? displayedQuery,
  ) {
    if (displayedQuery == null) return;
    ref
        .read(browsingProvider.notifier)
        .selectFragment(segment.anchor.key, query: displayedQuery);
  }

  Future<void> _handleAction(
    _ActivityAction action,
    _ActivitySegment segment,
    BrowsingQueryIdentity? displayedQuery,
  ) async {
    if (displayedQuery == null) return;
    final notifier = ref.read(browsingProvider.notifier);
    switch (action) {
      case _ActivityAction.openData:
        notifier.selectFragment(segment.anchor.key, query: displayedQuery);
        _openData();
    }
  }

  void _openData() {
    ref.read(browsingProvider.notifier).showPage(BrowsingPage.data);
    context.go('/dashboard');
  }
}

class _FeedHeader extends StatelessWidget {
  const _FeedHeader({
    required this.alignment,
    super.key,
    required this.projection,
    required this.apps,
    required this.windows,
    required this.onFilter,
    required this.bucketMinutes,
    required this.onOpenData,
    required this.onBucketMinutes,
    required this.onRange,
    required this.onDay,
    required this.onRefresh,
    required this.onClearFilter,
  });

  final FeedToolbarAlignment alignment;
  final FeedProjectionState projection;
  final List<String> apps;
  final List<FeedFilter> windows;
  final ValueChanged<FeedFilter> onFilter;
  final int bucketMinutes;
  final VoidCallback onOpenData;
  final ValueChanged<int> onBucketMinutes;
  final ValueChanged<DateRange> onRange;
  final ValueChanged<DateTime> onDay;
  final VoidCallback onRefresh;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: MaterialTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final label = _feedRangeLabel(projection.browsing.range);
              final style = Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant);
              final measure = TextPainter(
                text: TextSpan(text: label, style: style),
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout();
              final dateWidth = measure.width;
              measure.dispose();
              const actionsWidth = materialControlTarget * 4 +
                  MaterialTokens.spaceSm * 3;
              final inline = constraints.maxWidth >= dateWidth +
                  MaterialTokens.spaceSm + actionsWidth;
              // Keep the same parents in both modes: menu/focus state survives.
              return Wrap(
                spacing: MaterialTokens.spaceSm,
                runSpacing: MaterialTokens.spaceSm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: !inline ? constraints.maxWidth
                        : alignment == FeedToolbarAlignment.right
                            ? constraints.maxWidth - actionsWidth - MaterialTokens.spaceSm
                            : dateWidth,
                    child: Text(label, key: const Key('feed_header_date'),
                        style: style),
                  ),
                  SizedBox(
                    key: const Key('feed_header_actions'),
                    width: inline ? actionsWidth : constraints.maxWidth,
                    child: Wrap(
                      alignment: alignment == FeedToolbarAlignment.right
                          ? WrapAlignment.end : WrapAlignment.start,
                      spacing: MaterialTokens.spaceSm,
                      runSpacing: MaterialTokens.spaceSm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
              FeedFilterControl(
                filter: projection.browsing.filter,
                apps: apps,
                windows: windows,
                onChanged: onFilter,
                enabled: true,
              ),
              DateRangeControl(
                iconOnly: true,
                selection: projection.browsing.range,
                enabled: true,
                onRange: onRange,
                onDay: onDay,
              ),
              const RecapButton(),
              MaterialIconAction(
                key: const Key('feed_refresh'),
                tooltip: '刷新时间流',
                onPressed: onRefresh,
                icon: projection.isRefreshing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          Wrap(
            spacing: MaterialTokens.spaceMd,
            runSpacing: MaterialTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (projection.browsing.filter != const FeedFilter())
                MaterialActionButton(
                  child: Text(
                    '取消筛选：${projection.browsing.filter.windowId != null ? '窗口' : projection.browsing.filter.appId ?? '状态'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onPressed: onClearFilter,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _feedRangeLabel(DateRangeSelection selection) {
  final day = selection.effectiveDay;
  final end = '${day.month} 月 ${day.day} 日';
  return switch (selection.range) {
    DateRange.week => '近 7 天 · $end',
    DateRange.month => '近 30 天 · $end',
    _ => '$end · 星期${'一二三四五六日'[day.weekday - 1]}',
  };
}

class _ActivityCard extends StatefulWidget {
  const _ActivityCard({
    required this.segment,
    required this.appPaths,
    required this.compact,
    required this.expanded,
    required this.selected,
    required this.enabled,
    required this.onToggle,
    required this.onAction,
    required this.displayMode,
    super.key,
  });

  final _ActivitySegment segment;
  final Map<String, String> appPaths;
  final bool compact;
  final bool expanded;
  final bool selected;
  final bool enabled;
  final VoidCallback onToggle;
  final ValueChanged<_ActivityAction> onAction;
  final FeedDisplayMode displayMode;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final policy = MaterialScope.maybeOf(context)?.policy;
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final emphasized = _hovered || widget.selected || widget.expanded;
    final railWidth = widget.compact ? 54.0 : 68.0;
    final boundary = segment.isBoundary;
    final accent = boundary
        ? _stateColor(segment.state, scheme)
        : scheme.primary;

    if (widget.compact) return _CompactActivityCard(card: widget);

    return Padding(
      padding: const EdgeInsets.only(bottom: MaterialTokens.spaceMd),
      child: Stack(
        children: [
          Positioned(
            left: railWidth + 13.5,
            top: 0,
            bottom: 0,
            child: Container(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.75),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: railWidth,
                child: Padding(
                  padding: const EdgeInsets.only(top: 17),
                  child: Text(
                    _clock(segment.start.toLocal()),
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: widget.selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: widget.selected
                          ? FontWeight.w700
                          : FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 28,
                height: 52,
                child: Stack(
                  alignment: Alignment.topCenter,
                  children: [
                    Positioned(
                      top: 20,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: emphasized ? 12 : 9,
                        height: emphasized ? 12 : 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: emphasized
                              ? accent
                              : scheme.surfaceContainerHigh,
                          border: Border.all(color: accent, width: 2),
                          boxShadow: emphasized
                              ? [
                                  BoxShadow(
                                    color: accent.withValues(alpha: 0.28),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: MaterialTokens.spaceSm),
              Expanded(
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    transform: Matrix4.translationValues(
                      0,
                      _hovered && widget.enabled ? -2 : 0,
                      0,
                    ),
                    decoration: BoxDecoration(
                      color: widget.selected
                          ? Color.alphaBlend(
                              scheme.secondaryContainer.withValues(alpha: .25),
                              policy?.contentSurface ?? scheme.surface,
                            )
                          : policy?.contentSurface ??
                                scheme.surface.withValues(
                                  alpha: boundary ? 0.55 : 0.70,
                                ),
                      borderRadius: BorderRadius.circular(
                        boundary
                            ? MaterialTokens.controlRadius + 2
                            : MaterialTokens.contentRadius,
                      ),
                      border: Border.all(
                        color: widget.selected
                            ? accent.withValues(alpha: 0.34)
                            : scheme.outlineVariant.withValues(alpha: 0.42),
                      ),
                      boxShadow: MaterialTokens.cardShadow(
                        dark: dark,
                        lifted: emphasized,
                      ),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(
                        boundary
                            ? MaterialTokens.controlRadius + 2
                            : MaterialTokens.contentRadius,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: MaterialSheen(
                        child: InkWell(
                          onTap: widget.enabled ? widget.onToggle : null,
                          key: ValueKey('feed_segment:${segment.key}'),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              MaterialTokens.spaceLg,
                              boundary
                                  ? MaterialTokens.spaceSm
                                  : MaterialTokens.spaceMd,
                              MaterialTokens.spaceSm,
                              boundary
                                  ? MaterialTokens.spaceSm
                                  : MaterialTokens.spaceMd,
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    if (boundary)
                                      Container(
                                        width: 34,
                                        height: 34,
                                        decoration: BoxDecoration(
                                          color: accent.withValues(alpha: 0.10),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        child: Icon(
                                          _stateIcon(segment.state),
                                          size: 18,
                                          color: accent,
                                        ),
                                      )
                                    else
                                      _AppSourceStack(
                                        apps: segment.apps,
                                        appPaths: widget.appPaths,
                                      ),
                                    const SizedBox(
                                      width: MaterialTokens.spaceMd,
                                    ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            widget.displayMode ==
                                                    FeedDisplayMode.apps
                                                ? (segment.isBoundary ||
                                                          segment.apps.isEmpty
                                                      ? segment.title
                                                      : '使用 ${segment.apps.first}')
                                                : segment.title,
                                            maxLines: widget.expanded ? 2 : 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -0.1,
                                                ),
                                          ),
                                          if (widget.expanded) ...[
                                            const SizedBox(height: 3),
                                            Text(
                                              segment.summary,
                                              maxLines: widget.expanded ? 2 : 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall
                                                  ?.copyWith(
                                                    color:
                                                        scheme.onSurfaceVariant,
                                                  ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const SizedBox(
                                      width: MaterialTokens.spaceSm,
                                    ),
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          _duration(segment.duration),
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${_clock(segment.start.toLocal())}–${_clock(segment.end.toLocal())}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                      ],
                                    ),
                                    if (!widget.compact)
                                      IconButton(
                                        tooltip: widget.expanded
                                            ? '收起原始记录'
                                            : '展开原始记录',
                                        onPressed: widget.enabled
                                            ? widget.onToggle
                                            : null,
                                        icon: AnimatedRotation(
                                          turns: widget.expanded ? 0.5 : 0,
                                          duration: const Duration(
                                            milliseconds: 180,
                                          ),
                                          child: const Icon(
                                            Icons.expand_more_rounded,
                                          ),
                                        ),
                                      ),
                                    if (!boundary)
                                      PopupMenuButton<_ActivityAction>(
                                        offset: const Offset(-24, 8),
                                        constraints: const BoxConstraints(
                                          minWidth: 220,
                                          maxWidth: 260,
                                        ),
                                        tooltip: '时间段操作',
                                        enabled: widget.enabled,
                                        icon: const Icon(
                                          Icons.more_horiz_rounded,
                                        ),
                                        onSelected: widget.onAction,
                                        itemBuilder: (context) => [
                                          if (!boundary)
                                            const PopupMenuItem(
                                              value: _ActivityAction.openData,
                                              child: ListTile(
                                                contentPadding: EdgeInsets.zero,
                                                leading: Icon(
                                                  Icons.bar_chart_outlined,
                                                ),
                                                title: Text('在数据页查看'),
                                              ),
                                            ),
                                        ],
                                      ),
                                  ],
                                ),
                                AnimatedSize(
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutCubic,
                                  child: widget.expanded
                                      ? _ActivityEvidence(
                                          segment: segment,
                                          appPaths: widget.appPaths,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactActivityCard extends StatelessWidget {
  const _CompactActivityCard({required this.card});
  final _ActivityCard card;
  @override
  Widget build(BuildContext context) {
    final segment = card.segment;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: MaterialTokens.spaceMd),
      child: MaterialCard(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
          side: BorderSide(
            color: card.selected || card.expanded
                ? scheme.primary
                : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          key: ValueKey('feed_segment:${segment.key}'),
          onTap: card.enabled ? card.onToggle : null,
          child: Padding(
            padding: const EdgeInsets.all(MaterialTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      _stateIcon(segment.state),
                      size: 20,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: MaterialTokens.spaceSm),
                    Expanded(
                      child: Text(
                        card.displayMode == FeedDisplayMode.apps &&
                                segment.apps.isNotEmpty
                            ? '使用 ${segment.apps.first}'
                            : segment.title,
                        maxLines: card.expanded ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (!segment.isBoundary)
                      MaterialIconAction(
                        tooltip: '在数据页查看',
                        icon: const Icon(Icons.bar_chart_outlined),
                        onPressed: card.enabled
                            ? () => card.onAction(_ActivityAction.openData)
                            : null,
                      ),
                  ],
                ),
                const SizedBox(height: MaterialTokens.spaceSm),
                Wrap(
                  spacing: MaterialTokens.spaceSm,
                  runSpacing: MaterialTokens.spaceSm,
                  children: [
                    Text(
                      '${_clock(segment.start.toLocal())}–${_clock(segment.end.toLocal())}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      _duration(segment.duration),
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ),
                if (card.expanded) ...[
                  const SizedBox(height: MaterialTokens.spaceSm),
                  Text(
                    segment.summary,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  _ActivityEvidence(segment: segment, appPaths: card.appPaths),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedPaintProbe extends SingleChildRenderObjectWidget {
  const _FeedPaintProbe({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FeedPaintCounter(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    _FeedPaintCounter renderObject,
  ) => renderObject.onPaint = onPaint;
}

class _FeedPaintCounter extends RenderProxyBox {
  _FeedPaintCounter(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

class _ActivityEvidence extends StatefulWidget {
  const _ActivityEvidence({required this.segment, required this.appPaths});

  final _ActivitySegment segment;
  final Map<String, String> appPaths;

  @override
  State<_ActivityEvidence> createState() => _ActivityEvidenceState();
}

class _ActivityEvidenceState extends State<_ActivityEvidence> {
  int _limit = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final segment = widget.segment;
    final changes = segment.evidence.take(_limit).toList(growable: false);
    return Padding(
      padding: const EdgeInsets.only(top: MaterialTokens.spaceMd),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(MaterialTokens.spaceMd),
          child: Column(
            children: [
              for (final change in changes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth < 400
                        ? _NarrowEvidenceLine(
                            change: change,
                            appPaths: widget.appPaths,
                          )
                        : Row(
                            children: [
                              SizedBox(
                                width: 94,
                                child: Text(
                                  '${_clock(change.start.toLocal())}–${_clock(change.end.toLocal())}',
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                        fontFeatures: const [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  right: MaterialTokens.spaceSm,
                                ),
                                child: _ResolvedAppIcon(
                                  app: change.fragment.appDisplayName ?? '未知',
                                  exePath: _appPathFor(
                                    change.fragment.appDisplayName ?? '',
                                    widget.appPaths,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      appDisplayLabel(
                                        change.fragment.appDisplayName ??
                                            _boundaryTitle(
                                              change.fragment.state,
                                            ),
                                      ),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                    if (change.fragment.windowDisplayName !=
                                            null &&
                                        change.fragment.windowDisplayName !=
                                            change.fragment.appDisplayName)
                                      Tooltip(
                                        message:
                                            change.fragment.windowDisplayName!,
                                        child: Text(
                                          change.fragment.windowDisplayName!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: MaterialTokens.spaceSm),
                              Text(
                                _duration(change.duration),
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                  ),
                ),
              if (segment.evidence.length > changes.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: TextButton(
                      onPressed: () => setState(() => _limit += 16),
                      child: Text(
                        '展开更多（还有 ${segment.evidence.length - changes.length} 次变化）',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NarrowEvidenceLine extends StatelessWidget {
  const _NarrowEvidenceLine({required this.change, required this.appPaths});
  final _EvidenceChange change;
  final Map<String, String> appPaths;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: MaterialTokens.spaceSm,
        children: [
          Text(
            '${_clock(change.start.toLocal())}–${_clock(change.end.toLocal())}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          Text(
            _duration(change.duration),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      Text(
        appDisplayLabel(
          change.fragment.appDisplayName ??
              _boundaryTitle(change.fragment.state),
        ),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (change.fragment.windowDisplayName != null &&
          change.fragment.windowDisplayName != change.fragment.appDisplayName)
        Text(
          change.fragment.windowDisplayName!,
          style: Theme.of(context).textTheme.labelSmall,
        ),
    ],
  );
}

class _AppSourceStack extends StatelessWidget {
  const _AppSourceStack({required this.apps, required this.appPaths});

  final List<String> apps;
  final Map<String, String> appPaths;

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) {
      return Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: const Text('?', style: TextStyle(fontWeight: FontWeight.w700)),
      );
    }
    final shown = apps.take(3).toList(growable: false);
    return SizedBox(
      width: 32 + (shown.length - 1) * 18,
      height: 38,
      child: Stack(
        children: [
          for (var index = shown.length - 1; index >= 0; index--)
            Positioned(
              left: index * 18,
              top: 2,
              child: Tooltip(
                message: shown[index],
                child: Container(
                  width: 32,
                  height: 32,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.surface,
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 5,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: _ResolvedAppIcon(
                    app: shown[index],
                    exePath: _appPathFor(shown[index], appPaths),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ResolvedAppIcon extends StatelessWidget {
  const _ResolvedAppIcon({required this.app, this.exePath});

  final String app;
  final String? exePath;

  @override
  Widget build(BuildContext context) {
    final path = exePath;
    if (path != null && path.isNotEmpty) {
      return AppIcon(exePath: path, appName: app, size: 24);
    }
    if (isTerminalApp(app)) return const TerminalAppIcon();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: appColor(app).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Center(
        child: Text(
          _appMark(app),
          maxLines: 1,
          style: TextStyle(
            color: appColor(app),
            fontSize: _appMark(app).length > 1 ? 9 : 13,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ),
    );
  }
}

class _FeedMessage extends StatelessWidget {
  const _FeedMessage({
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  const _FeedMessage.loading()
    : icon = Icons.hourglass_top_rounded,
      title = '正在整理时间流',
      description = '原始活动正在聚合为可阅读的时间段…',
      actionLabel = null,
      onAction = null;

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceXl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onAction == null && title.startsWith('正在'))
            const CircularProgressIndicator(strokeWidth: 2)
          else
            Icon(
              icon,
              size: 34,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          const SizedBox(height: MaterialTokens.spaceMd),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: MaterialTokens.spaceSm),
          Text(
            description,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: MaterialTokens.spaceLg),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}

class _FeedPresentation {
  const _FeedPresentation(this.segments, this.apps, this.windows);
  final List<_ActivitySegment> segments;
  final List<String> apps;
  final List<FeedFilter> windows;
}

class _ActivitySegment {
  _ActivitySegment({
    required this.start,
    required this.end,
    required this.fragments,
  });

  final DateTime start;
  final DateTime end;
  final List<FeedFragment> fragments;

  String get key =>
      '${start.microsecondsSinceEpoch}:${end.microsecondsSinceEpoch}';
  Duration get duration => end.difference(start);

  Duration _overlap(FeedFragment fragment) {
    final clippedStart = fragment.visibleStartUtc.isAfter(start)
        ? fragment.visibleStartUtc
        : start;
    final clippedEnd = fragment.visibleEndUtc.isBefore(end)
        ? fragment.visibleEndUtc
        : end;
    return clippedStart.isBefore(clippedEnd)
        ? clippedEnd.difference(clippedStart)
        : Duration.zero;
  }

  late final AccountingStateDto state = _computeState();
  AccountingStateDto _computeState() {
    final totals = <AccountingStateDto, Duration>{};
    for (final fragment in fragments) {
      final overlap = _overlap(fragment);
      totals.update(
        fragment.state,
        (value) => value + overlap,
        ifAbsent: () => overlap,
      );
    }
    final ordered = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ordered.first.key;
  }

  bool get isBoundary => !fragments.any(
    (fragment) =>
        fragment.state == AccountingStateDto.active &&
        _overlap(fragment) > Duration.zero,
  );

  late final List<String> apps = _computeApps();
  List<String> _computeApps() {
    final durations = <String, Duration>{};
    for (final fragment in fragments) {
      final app = fragment.appDisplayName;
      if (app == null || fragment.state != AccountingStateDto.active) continue;
      final overlap = _overlap(fragment);
      durations.update(
        app,
        (value) => value + overlap,
        ifAbsent: () => overlap,
      );
    }
    final ordered = durations.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ordered.map((entry) => entry.key).toList(growable: false);
  }

  late final FeedFragment anchor = _computeAnchor();
  FeedFragment _computeAnchor() {
    final candidates = isBoundary
        ? fragments
        : fragments
              .where((fragment) => fragment.state == AccountingStateDto.active)
              .toList(growable: false);
    var best = candidates.first;
    for (final fragment in candidates.skip(1)) {
      if (_overlap(fragment) > _overlap(best)) best = fragment;
    }
    return best;
  }

  late final String title = _computeTitle();
  String _computeTitle() {
    if (isBoundary) return _boundaryTitle(state);
    final windows = <String, Duration>{};
    for (final fragment in fragments) {
      if (fragment.state != AccountingStateDto.active) continue;
      final window = fragment.windowDisplayName;
      if (window == null || window.trim().isEmpty) continue;
      final overlap = _overlap(fragment);
      windows.update(
        window,
        (value) => value + overlap,
        ifAbsent: () => overlap,
      );
    }
    if (windows.isNotEmpty) {
      final ordered = windows.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return appDisplayLabel(ordered.first.key);
    }
    final names = apps;
    return names.isEmpty ? '未命名活动' : '使用 ${names.first}';
  }

  String get summary {
    if (isBoundary) {
      return switch (state) {
        AccountingStateDto.idle => '这段时间没有检测到持续输入',
        AccountingStateDto.paused => '活动记录已由你暂停',
        AccountingStateDto.privacyExcluded => '应用与窗口信息已按隐私规则隐藏',
        AccountingStateDto.systemGap => '系统没有提供可用的连续记录',
        AccountingStateDto.unknown => '旧数据没有完整的状态信息',
        AccountingStateDto.active => '',
      };
    }
    final names = apps.map(appDisplayLabel).toList();
    if (names.isEmpty) return '这段活动没有可显示的应用信息';
    if (names.length == 1) return '主要在 ${names.first} 中活动';
    final extra = names.length - 1;
    return '主要使用 ${names.first}，同时涉及 ${names[1]}${extra > 1 ? ' 等 $extra 个应用' : ''}';
  }

  late final List<_EvidenceChange> evidence = _computeEvidence();
  List<_EvidenceChange> _computeEvidence() {
    final ordered = fragments.toList()
      ..sort((a, b) => a.visibleStartUtc.compareTo(b.visibleStartUtc));
    final changes = <_EvidenceChange>[];
    for (final fragment in ordered) {
      final clippedStart = fragment.visibleStartUtc.isAfter(start)
          ? fragment.visibleStartUtc
          : start;
      final clippedEnd = fragment.visibleEndUtc.isBefore(end)
          ? fragment.visibleEndUtc
          : end;
      if (!clippedStart.isBefore(clippedEnd)) continue;
      final signature = [
        fragment.state.name,
        fragment.appDisplayName ?? '',
        fragment.windowDisplayName ?? '',
      ].join('|');
      final previous = changes.isEmpty ? null : changes.last;
      if (previous != null &&
          previous.signature == signature &&
          !clippedStart.isAfter(previous.end.add(const Duration(minutes: 1)))) {
        changes[changes.length - 1] = previous.copyWith(end: clippedEnd);
      } else {
        changes.add(
          _EvidenceChange(
            signature: signature,
            fragment: fragment,
            start: clippedStart,
            end: clippedEnd,
          ),
        );
      }
    }
    return changes.reversed.toList(growable: false);
  }

  static List<_ActivitySegment> group(
    List<FeedFragment> fragments, {
    required Duration bucketSize,
  }) {
    if (fragments.isEmpty) return const [];
    final buckets =
        <int, ({DateTime start, DateTime end, List<FeedFragment> rows})>{};
    for (final fragment in fragments) {
      var cursor = _floorLocal(fragment.visibleStartUtc.toLocal(), bucketSize);
      var guard = 0;
      while (guard++ < 10000) {
        final bucketStart = cursor.toUtc();
        final bucketEnd = cursor.add(bucketSize).toUtc();
        if (!bucketStart.isBefore(fragment.visibleEndUtc)) break;
        if (bucketEnd.isAfter(fragment.visibleStartUtc)) {
          final key = bucketStart.microsecondsSinceEpoch;
          final bucket = buckets.putIfAbsent(
            key,
            () => (start: bucketStart, end: bucketEnd, rows: <FeedFragment>[]),
          );
          bucket.rows.add(fragment);
        }
        cursor = cursor.add(bucketSize);
      }
    }
    final result = [
      for (final bucket in buckets.values)
        _ActivitySegment(
          start: bucket.start,
          end: bucket.end,
          fragments: List.unmodifiable(bucket.rows),
        ),
    ]..sort((a, b) => b.start.compareTo(a.start));
    final merged = <_ActivitySegment>[];
    for (final segment in result) {
      final previous = merged.isEmpty ? null : merged.last;
      if (previous != null &&
          previous.isBoundary &&
          segment.isBoundary &&
          previous.state == segment.state &&
          previous.start == segment.end) {
        final unique = <String, FeedFragment>{
          for (final fragment in previous.fragments) fragment.key: fragment,
          for (final fragment in segment.fragments) fragment.key: fragment,
        };
        merged[merged.length - 1] = _ActivitySegment(
          start: segment.start,
          end: previous.end,
          fragments: List.unmodifiable(unique.values),
        );
      } else {
        merged.add(segment);
      }
    }
    return List.unmodifiable(merged);
  }
}

class _EvidenceChange {
  const _EvidenceChange({
    required this.signature,
    required this.fragment,
    required this.start,
    required this.end,
  });

  final String signature;
  final FeedFragment fragment;
  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
  String get title {
    final app = fragment.appDisplayName;
    final window = fragment.windowDisplayName;
    if (app != null && window != null && window != app) return '$app · $window';
    return window ?? app ?? _boundaryTitle(fragment.state);
  }

  _EvidenceChange copyWith({DateTime? end}) => _EvidenceChange(
    signature: signature,
    fragment: fragment,
    start: start,
    end: end ?? this.end,
  );
}

enum _ActivityAction { openData }

DateTime _floorLocal(DateTime value, Duration bucketSize) {
  return floorFeedBucketLocal(value, bucketSize.inMinutes);
}

String _appKey(String value) => appIdentityKey(value);

String? _appPathFor(String app, Map<String, String> paths) =>
    paths[app] ?? paths[_appKey(app)];

String _appMark(String app) {
  final key = _appKey(app);
  if (key == 'code' || key.contains('visualstudiocode')) return 'VS';
  if (key.contains('chatgpt')) return 'CG';
  if (key == 'qq') return 'QQ';
  if (key.contains('timetrace')) return 'TT';
  final trimmed = app.trim();
  return trimmed.isEmpty
      ? '?'
      : String.fromCharCode(trimmed.runes.first).toUpperCase();
}

String _boundaryTitle(AccountingStateDto state) => switch (state) {
  AccountingStateDto.active => '活动',
  AccountingStateDto.idle => '活动间歇',
  AccountingStateDto.paused => '记录暂停',
  AccountingStateDto.privacyExcluded => '隐私时段',
  AccountingStateDto.systemGap => '记录中断',
  AccountingStateDto.unknown => '未识别时段',
};

IconData _stateIcon(AccountingStateDto state) => switch (state) {
  AccountingStateDto.active => Icons.bolt_rounded,
  AccountingStateDto.idle => Icons.coffee_outlined,
  AccountingStateDto.paused => Icons.pause_circle_outline,
  AccountingStateDto.privacyExcluded => Icons.visibility_off_outlined,
  AccountingStateDto.systemGap => Icons.power_settings_new_rounded,
  AccountingStateDto.unknown => Icons.help_outline_rounded,
};

Color _stateColor(AccountingStateDto state, ColorScheme scheme) =>
    switch (state) {
      AccountingStateDto.active => scheme.primary,
      AccountingStateDto.idle => scheme.tertiary,
      AccountingStateDto.paused => scheme.secondary,
      AccountingStateDto.privacyExcluded => scheme.outline,
      AccountingStateDto.systemGap => scheme.error,
      AccountingStateDto.unknown => scheme.outline,
    };

String _failureText(BrowsingFailure failure) => switch (failure) {
  BrowsingFailure.unavailable => '本地活动服务尚未准备好。',
  BrowsingFailure.invalidSnapshot => '本地记录不完整，已停止展示以避免错误统计。',
  BrowsingFailure.queryFailed => '读取本地记录失败，请稍后重试。',
};

String _clock(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _duration(Duration value) {
  final minutes = value.inMinutes;
  if (minutes < 1) return '${value.inSeconds} 秒';
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}
