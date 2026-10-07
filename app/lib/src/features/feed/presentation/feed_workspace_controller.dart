import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../browsing/providers/browsing_provider.dart';
import '../../browsing/providers/feed_projection_provider.dart';

export '../../browsing/models/browsing_state.dart';
export '../../browsing/providers/feed_projection_provider.dart'
    show FeedProjectionState;

/// Transient measurements of the rendered, sanitized projection. Durable view
/// memory belongs exclusively to BrowsingNotifier.saveViewport.
class FeedViewportCapture {
  const FeedViewportCapture({
    required this.query,
    required this.fragmentKey,
    required this.localOffset,
    required this.pixelOffset,
  });

  final BrowsingQueryIdentity query;
  final String? fragmentKey;
  final double localOffset;
  final double pixelOffset;
}

/// A null index denotes a pixel fallback, never an inferred fragment identity.
class FeedViewportTarget {
  const FeedViewportTarget({
    required this.query,
    this.index,
    this.localOffset = 0,
    this.pixelOffset = 0,
  });

  final BrowsingQueryIdentity query;
  final int? index;
  final double localOffset;
  final double pixelOffset;
}

/// Test seam: a fake port can delay layout and record attempted movements.
/// Implementations must check isCurrent immediately before EVERY scroll write.
abstract interface class FeedViewportPort {
  FeedViewportCapture? capture();
  bool isReadyFor(BrowsingQueryIdentity query);
  Future<bool> restore(FeedViewportTarget target, bool Function() isCurrent);
}

enum FeedWorkspaceNoticeKind {
  firstVisit,
  restored,
  viewportUnavailable,
  locateNotMatched,
  selectionInvalidated,
  operationFailed,
}

class FeedWorkspaceNotice {
  const FeedWorkspaceNotice(this.kind, {this.reason});

  final FeedWorkspaceNoticeKind kind;
  final SelectionInvalidationReason? reason;

  String get message => switch (kind) {
    FeedWorkspaceNoticeKind.firstVisit => '首次浏览此范围和筛选，从开头显示。',
    FeedWorkspaceNoticeKind.restored => '已恢复此范围和筛选的浏览位置。',
    FeedWorkspaceNoticeKind.viewportUnavailable => '原浏览位置无法恢复，已保留当前范围。',
    FeedWorkspaceNoticeKind.locateNotMatched => '此范围没有匹配的片段，已保留当前范围。',
    FeedWorkspaceNoticeKind.selectionInvalidated =>
      selectionInvalidationMessage(reason),
    FeedWorkspaceNoticeKind.operationFailed => '此次操作未完成，范围和已有选择仍保留，可重试。',
  };
}

String selectionInvalidationMessage(SelectionInvalidationReason? reason) =>
    switch (reason) {
      SelectionInvalidationReason.userCleared => '已清除选择。',
      SelectionInvalidationReason.outsideRange => '原片段不在当前范围内。',
      SelectionInvalidationReason.filteredOut => '原片段不符合当前筛选。',
      SelectionInvalidationReason.deleted => '原片段已不存在。',
      SelectionInvalidationReason.ambiguous => '存在多个匹配片段，无法唯一定位。',
      SelectionInvalidationReason.insufficientEvidence => '来源证据不足，无法恢复原片段。',
      SelectionInvalidationReason.staleRevision => '来源修订已变化，无法确认原片段。',
      SelectionInvalidationReason.intervalChanged => '片段时间已变化，无法确认原片段。',
      SelectionInvalidationReason.entityChanged => '片段归属已变化，无法确认原片段。',
      SelectionInvalidationReason.privacyCannotConfirm =>
        '隐私状态变化，原片段或筛选无法继续确认。',
      null => '原选择无法恢复，已保留当前范围。',
    };

/// Presentation coordinator; does not own a second range/filter/selection store.
/// Create once per frame State, never inside a responsive layout branch.
/// Call synchronize after layout/provider changes. Notifications also request a
/// new pass when an asynchronous operation was superseded while awaiting layout.
class FeedWorkspaceController extends ChangeNotifier {
  FeedWorkspaceController({
    required FeedProjectionState Function() readProjection,
    required BrowsingNotifier Function() readBrowsing,
    required VoidCallback onOpenData,
  }) : _readProjection = readProjection,
       _readBrowsing = readBrowsing,
       _onOpenData = onOpenData;

  final FeedProjectionState Function() _readProjection;
  final BrowsingNotifier Function() _readBrowsing;
  final VoidCallback _onOpenData;
  FeedViewportPort? _port;
  BrowsingQueryIdentity? _settledQuery;
  BrowsingQueryIdentity? _userControlledQuery;
  FeedViewportCapture? _geometryRestore;
  FeedWorkspaceNotice? _notice;
  int? _preferSavedViewRequest;
  int _epoch = 0;
  bool _active = false;
  bool _disposed = false;
  bool _busy = false;
  bool _synchronizeAgain = false;
  bool _detailsOpen = false;
  bool _appending = false;

  FeedProjectionState get projection => _readProjection();
  FeedWorkspaceNotice? get notice => _notice;
  bool get isAppending => _appending;
  bool get isMoving => _busy;
  bool get isActive =>
      !_disposed && _active && projection.browsing.page == BrowsingPage.feed;

  /// Expansion follows the shared reconciled selection, not a cached row key.
  FeedFragment? get expandedFragment {
    if (!_detailsOpen) return null;
    final row = projection.selectedFragment;
    return row != null &&
            !row.isPrivacyExcluded &&
            (row.capabilities.inspectSource ||
                row.capabilities.showEntityDetails)
        ? row
        : null;
  }

  void attach(FeedViewportPort port) => _port = port;

  void setActive(bool value) {
    if (_disposed || value == _active) return;
    if (value) {
      invalidateRestoration();
      _active = true;
      _readBrowsing().showPage(BrowsingPage.feed);
    } else {
      rememberViewport();
      cancelAutomaticScroll();
      _active = false;
    }
  }

  void dismissNotice() {
    if (_disposed || _notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void _show(FeedWorkspaceNotice next) {
    if (_disposed ||
        (_notice?.kind == next.kind && _notice?.reason == next.reason))
      return;
    _notice = next;
    notifyListeners();
  }

  FeedFragment? _row(String key, BrowsingQueryIdentity query) {
    final current = projection;
    if (!isActive || !current.browsing.canInteractWithDisplayedQuery(query))
      return null;
    for (final row in current.projection?.fragments ?? const <FeedFragment>[]) {
      if (row.key == key) return row;
    }
    return null;
  }

  bool rememberViewport() {
    if (_busy || _geometryRestore != null) return false;
    return _saveViewport();
  }

  bool _saveViewport() {
    if (!isActive) return false;
    final captured = _port?.capture();
    if (captured == null ||
        (captured.query != _settledQuery &&
            captured.query != _userControlledQuery))
      return false;
    // A new projection's inherited pixels are not a restored viewport. In
    // particular, layout clamping on re-entry must not overwrite shared memory.
    return _readBrowsing().saveViewport(
      query: captured.query,
      fragmentKey: captured.fragmentKey,
      localOffset: captured.localOffset,
      pixelOffset: captured.pixelOffset,
    );
  }

  /// Queued by the frame after measuring a geometry change. No provider writes
  /// or notifications occur here, so capture may also be prepared during build.
  void queueGeometryRestore(FeedViewportCapture capture) {
    if (_disposed ||
        _busy ||
        !isActive ||
        capture.query != projection.displayedQuery ||
        !projection.browsing.canInteractWithDisplayedQuery(capture.query))
      return;
    _geometryRestore ??= capture;
  }

  /// Cancellation invalidates guards; it is not evidence of successful restore.
  /// Safe to call from didUpdateWidget: no provider writes or notifications.
  void cancelAutomaticScroll() {
    if (_disposed) return;
    _epoch++;
    _geometryRestore = null;
  }

  /// Re-entry must restore shared memory even if the query was handled before
  /// leaving. No controller, ScrollController or shared selection is replaced.
  void invalidateRestoration() {
    if (_disposed) return;
    cancelAutomaticScroll();
    _settledQuery = null;
    _userControlledQuery = null;
  }

  /// User movement is a separate reason to stop automatic restoration. It does
  /// not claim that an interrupted restore succeeded. New locate outcomes and
  /// geometry changes still receive their own synchronization pass.
  void acceptUserScroll() {
    if (!isActive) return;
    cancelAutomaticScroll();
    final current = projection;
    final query = current.displayedQuery;
    _userControlledQuery =
        query != null && current.browsing.canInteractWithDisplayedQuery(query)
        ? query
        : null;
  }

  bool selectFragment(String key, BrowsingQueryIdentity query) {
    if (_row(key, query) == null) return false;
    rememberViewport();
    return _readBrowsing().selectFragment(key, query: query);
  }

  bool toggleDetails(String key, BrowsingQueryIdentity query) {
    final row = _row(key, query);
    if (row == null ||
        row.isPrivacyExcluded ||
        !(row.capabilities.inspectSource ||
            row.capabilities.showEntityDetails)) {
      return false;
    }
    rememberViewport();
    final close =
        _detailsOpen && projection.browsing.selectedAnchor?.fragmentKey == key;
    if (!_readBrowsing().selectFragment(key, query: query)) return false;
    _detailsOpen = !close;
    notifyListeners();
    return true;
  }

  /// The callback receives no URL parameters or raw window titles. The existing
  /// ProviderScope is the navigation context and must survive the route change.
  bool openData({String? fragmentKey, BrowsingQueryIdentity? query}) {
    if (!isActive) return false;
    if (fragmentKey != null) {
      if (query == null || !selectFragment(fragmentKey, query)) return false;
    }
    rememberViewport();
    cancelAutomaticScroll();
    _readBrowsing().showPage(BrowsingPage.data);
    _onOpenData();
    return true;
  }

  /// Only requests created through these Feed controls prefer saved view memory.
  /// Data workspace calendar/hour/app/window requests retain explicit locating.
  Future<void> setRange(DateRangeSelection range) async {
    if (!isActive) return;
    await _changeView(() => _readBrowsing().setRange(range));
  }

  Future<void> filterApp(String key, BrowsingQueryIdentity query) async {
    final row = _row(key, query);
    if (row == null || row.isPrivacyExcluded || !row.capabilities.filterApp)
      return;
    await _changeView(
      () => _readBrowsing().filterFragmentApp(key, query: query),
    );
  }

  Future<void> filterWindow(String key, BrowsingQueryIdentity query) async {
    final row = _row(key, query);
    if (row == null || row.isPrivacyExcluded || !row.capabilities.filterWindow)
      return;
    await _changeView(
      () => _readBrowsing().filterFragmentWindow(key, query: query),
    );
  }

  Future<void> clearFilter() async {
    if (!isActive) return;
    await _changeView(() => _readBrowsing().clearFilter());
  }

  Future<void> _changeView(Future<dynamic> Function() action) async {
    rememberViewport();
    cancelAutomaticScroll();
    _userControlledQuery = null;
    _preferSavedViewRequest = null;
    try {
      final beforeId = projection.browsing.locateRequest?.id;
      // The supplied BrowsingNotifier publishes the new request synchronously,
      // before awaiting its loader. Capture that exact id before yielding.
      final pending = action();
      final request = projection.browsing.locateRequest;
      if (request != null && request.id != beforeId) {
        _preferSavedViewRequest = request.id;
      }
      await pending;
      // Do not assign a preference here: a newer data-page intent may now exist.
    } catch (_) {
      _show(const FeedWorkspaceNotice(FeedWorkspaceNoticeKind.operationFailed));
    }
  }

  Future<void> refresh() async {
    if (!isActive) return;
    rememberViewport();
    await _guard(() => _readBrowsing().refresh());
  }

  Future<void> _guard(Future<dynamic> Function() action) async {
    try {
      await action();
    } catch (_) {
      _show(const FeedWorkspaceNotice(FeedWorkspaceNoticeKind.operationFailed));
    }
  }

  Future<void> loadMore({int count = 100}) async {
    final current = projection;
    final query = current.displayedQuery;
    if (!isActive ||
        _appending ||
        count <= 0 ||
        query == null ||
        !current.canLoadMore)
      return;
    rememberViewport();
    _appending = true;
    notifyListeners();
    try {
      // Extends a prefix of the existing projection; never starts a query.
      _readBrowsing().loadMore(count: count, query: query);
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {
      _show(const FeedWorkspaceNotice(FeedWorkspaceNoticeKind.operationFailed));
    } finally {
      _appending = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Explicit locating requires the current successful generation. Passive
  /// viewport restoration only operates on the exact displayed projection, and
  /// can therefore preserve geometry during a same-view refresh or failure.
  /// Neither path reconciles identities; that remains shared-browsing's job.
  Future<void> synchronize() async {
    final port = _port;
    if (!isActive || port == null) return;
    if (_busy) {
      _synchronizeAgain = true;
      return;
    }
    var current = projection;
    var outcome = current.pendingLocateOutcome;
    var terminalFeedback = false;
    if (outcome != null && outcome.status != BrowsingLocateStatus.matched) {
      final consumed = _readBrowsing().consumeLocateOutcome(outcome.requestId);
      if (consumed != null) {
        terminalFeedback = true;
        if (_preferSavedViewRequest == consumed.requestId) {
          _preferSavedViewRequest = null;
        }
        _show(
          FeedWorkspaceNotice(
            consumed.status == BrowsingLocateStatus.notMatched
                ? FeedWorkspaceNoticeKind.locateNotMatched
                : FeedWorkspaceNoticeKind.selectionInvalidated,
            reason: consumed.invalidationReason,
          ),
        );
      }
      current = projection;
      outcome = current.pendingLocateOutcome;
    }

    final query = current.displayedQuery;
    if (query == null ||
        !current.browsing.canInteractWithDisplayedQuery(query) ||
        !port.isReadyFor(query))
      return;
    if (_geometryRestore != null && _geometryRestore!.query != query) {
      _geometryRestore = null;
    }
    final explicitLocate = outcome != null;
    if (explicitLocate && !current.browsing.resultMatchesRequest) return;
    if ((query == _settledQuery || query == _userControlledQuery) &&
        outcome == null &&
        _geometryRestore == null)
      return;

    final all = current.projection!.fragments;
    final memory = current.viewState;
    final enteringView = _settledQuery?.view != query.view;
    final preferSaved =
        outcome != null && outcome.requestId == _preferSavedViewRequest;
    int? index;
    var localOffset = 0.0;
    var pixels = 0.0;
    FeedWorkspaceNotice? feedback;

    if (outcome != null && !preferSaved) {
      final targetKey = outcome.fragmentKey;
      final found = all.indexWhere((row) => row.key == targetKey);
      if (found < 0) return;
      index = found;
    } else {
      final capture = _geometryRestore;
      final key = capture?.fragmentKey ?? memory.viewportAnchor?.fragmentKey;
      final found = key == null ? -1 : all.indexWhere((row) => row.key == key);
      if (found >= 0) {
        index = found;
        localOffset = capture?.localOffset ?? memory.localOffset;
        if (enteringView || preferSaved) {
          feedback = const FeedWorkspaceNotice(
            FeedWorkspaceNoticeKind.restored,
          );
        }
      } else if (capture != null) {
        // Capture was checked against this exact displayed generation above.
        pixels = capture.pixelOffset;
      } else if (memory.pixelOffsetGeneration == query.generation &&
          memory.pixelOffset != null) {
        pixels = memory.pixelOffset!;
        if (enteringView || preferSaved) {
          feedback = const FeedWorkspaceNotice(
            FeedWorkspaceNoticeKind.restored,
          );
        }
      } else if (enteringView ||
          preferSaved ||
          memory.viewportInvalidationReason != null) {
        feedback = FeedWorkspaceNotice(
          memory.viewportInvalidationReason != null || key != null
              ? FeedWorkspaceNoticeKind.viewportUnavailable
              : FeedWorkspaceNoticeKind.firstVisit,
          reason: memory.viewportInvalidationReason,
        );
      }
    }

    if (index != null && index >= current.fragments.length) {
      _readBrowsing().loadMore(
        count: index + 1 - current.fragments.length,
        query: query,
      );
      return;
    }
    // Keep a matched locate request alive until the viewport move finishes.
    // A same-view refresh can then carry the request into its new generation
    // instead of losing the explicit target while layout is still settling.
    // The intent fence below still prevents an older move from winning after a
    // newer locate request or projection replaces it.
    final intent = projection.browsing;
    final requestId = intent.locateRequest?.id;
    final outcomeId = intent.locateOutcome?.requestId;
    final consumedId = intent.consumedLocateId;
    final epoch = ++_epoch;
    _geometryRestore = null;
    _busy = true;
    bool stillCurrent() {
      if (_disposed || !_active || epoch != _epoch) return false;
      final latest = projection;
      final browsing = latest.browsing;
      return browsing.page == BrowsingPage.feed &&
          latest.displayedQuery == query &&
          browsing.canInteractWithDisplayedQuery(query) &&
          (!explicitLocate || browsing.resultMatchesRequest) &&
          browsing.locateRequest?.id == requestId &&
          browsing.locateOutcome?.requestId == outcomeId &&
          browsing.consumedLocateId == consumedId;
    }

    try {
      final restored = await port.restore(
        FeedViewportTarget(
          query: query,
          index: index,
          localOffset: localOffset,
          pixelOffset: pixels,
        ),
        stillCurrent,
      );
      if (!stillCurrent()) return;
      if (outcome != null) {
        if (_readBrowsing().consumeLocateOutcome(outcome.requestId) == null) {
          return;
        }
        if (preferSaved) _preferSavedViewRequest = null;
      }
      // Only a completed restore or an explicitly reported failure settles it.
      _settledQuery = query;
      _userControlledQuery = null;
      if (restored) {
        _saveViewport();
        if (!terminalFeedback && feedback != null) _show(feedback);
      } else {
        _show(
          const FeedWorkspaceNotice(
            FeedWorkspaceNoticeKind.viewportUnavailable,
          ),
        );
      }
    } catch (_) {
      if (stillCurrent()) {
        if (outcome != null &&
            _readBrowsing().consumeLocateOutcome(outcome.requestId) == null) {
          return;
        }
        if (preferSaved) _preferSavedViewRequest = null;
        _settledQuery = query;
        _userControlledQuery = null;
        _show(
          const FeedWorkspaceNotice(
            FeedWorkspaceNoticeKind.viewportUnavailable,
          ),
        );
      }
    } finally {
      _busy = false;
      final again = _synchronizeAgain;
      _synchronizeAgain = false;
      // The frame schedules after layout, rather than recursively scrolling.
      // Its provider listener also marks a pass pending while this one is busy.
      if (isActive && (again || !stillCurrent())) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _port = null;
    _geometryRestore = null;
    _settledQuery = null;
    _userControlledQuery = null;
    _preferSavedViewRequest = null;
    super.dispose();
  }
}
