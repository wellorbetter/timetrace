import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/canonical_feed_projection.dart';
import '../models/browsing_state.dart';
import 'browsing_provider.dart';

/// Optional anonymous counters for synthetic diagnostics; never business data.
enum FeedDiagnosticEvent {
  build,
  grouping,
  filtering,
  cardBuild,
  paint,
  fill,
  anchorSeek,
  anchorRestored,
  anchorUnresolved,
}

final feedDiagnosticsProvider = Provider<void Function(FeedDiagnosticEvent)?>(
  (ref) => null,
);

/// One current sanitized presentation, not a page State or raw bridge cache.
/// Query/source revocation also applies while the page is away from the route.
class FeedPresentationMemo {
  Object? _key;
  Object? _value;
  Object? _viewportLayout;
  double? _viewportPixels;

  /// One geometry proof only, never a history of page States or raw snapshots.
  /// The caller's key includes query generation and actual viewport/font/layout.
  void rememberViewport(Object layout, double pixels) {
    _viewportLayout = layout;
    _viewportPixels = pixels;
  }

  double? viewportSeed(Object layout, double? savedPixels) =>
      _viewportLayout == layout && _viewportPixels == savedPixels
      ? _viewportPixels
      : null;
  T derive<T>(Object key, T Function() create) {
    if (_key == key && _value is T) return _value as T;
    final value = create();
    _key = key;
    _value = value;
    return value;
  }

  void clear() {
    _key = null;
    _value = null;
    _viewportLayout = null;
    _viewportPixels = null;
  }
}

final feedPresentationMemoProvider = Provider<FeedPresentationMemo>((ref) {
  final memo = FeedPresentationMemo();
  ref.listen(
    feedProjectionProvider,
    (before, after) {
      if (!after.canInteract ||
          before?.displayedQuery != after.displayedQuery ||
          !identical(before?.projection, after.projection))
        memo.clear();
    },
    weak: true,
  ); // Observability must not keep an off-route refresh lease alive.
  ref.onDispose(memo.clear);
  return memo;
});

/// Presentation-only envelope. A previous projection is deliberately accompanied
/// by its own view and query identity; it must never be labeled as the new range.
/// There is no raw snapshot or independently resolved detail data in this API.
class FeedProjectionState {
  const FeedProjectionState(this.browsing);

  final BrowsingState browsing;

  BrowsingQueryIdentity? get requestedQuery => browsing.query;
  BrowsingQueryIdentity? get displayedQuery => browsing.displayedQuery;
  BrowsingViewKey? get requestedView => requestedQuery?.view;
  BrowsingViewKey? get displayedView => displayedQuery?.view;
  CanonicalFeedProjection? get projection => browsing.result?.projection;
  CanonicalFeedProjection? get currentProjection =>
      browsing.resultMatchesRequest ? projection : null;

  /// Same-view choices survive loading/failure, but never cross a view boundary.
  /// allFragments is already sanitized and unfiltered by the canonical loader.
  CanonicalFeedProjection? get choiceProjection =>
      browsing.canInteractWithDisplayedResult ? projection : null;

  bool get isInitialLoading =>
      browsing.phase == BrowsingLoadPhase.loading && browsing.result == null;
  bool get isRefreshing => browsing.isRefreshing;
  bool get isStale => browsing.result != null && !browsing.resultMatchesRequest;
  bool get isPreviousRange => browsing.isShowingPreviousView;
  bool get isEmpty => currentProjection?.fragments.isEmpty ?? false;
  BrowsingFailure? get failure => browsing.failure;
  SelectionInvalidationReason? get selectionInvalidationReason =>
      browsing.selectionInvalidationReason;

  BrowsingViewState get viewState =>
      browsing.views[displayedView] ?? BrowsingViewState();

  List<FeedFragment> get fragments =>
      projection?.visibleBatch(viewState.visibleCount) ??
      const <FeedFragment>[];

  /// Capture displayedQuery with this envelope and pass it to notifier actions.
  /// This remains true during same-view refresh/failure, but false while showing
  /// another range/filter. It does not authorize restoration or navigation.
  bool get canInteract => browsing.canInteractWithDisplayedResult;

  bool get canLoadMore =>
      canInteract && (projection?.hasMore(viewState.visibleCount) ?? false);

  /// Detail evidence comes from exactly the displayed sanitized projection.
  /// During an error the envelope remains stale and retains its displayed range.
  FeedFragment? get selectedFragment {
    final key = browsing.selectedAnchor?.fragmentKey;
    if (key == null) return null;
    for (final row in projection?.fragments ?? const <FeedFragment>[]) {
      if (row.key == key) return row;
    }
    return null;
  }

  /// Matched outcomes require the current successful projection before scrolling.
  /// Terminal failures carry no fragment key and remain actionable during a
  /// same-view refresh or failed retry. Both are consumed atomically once via
  /// consumeLocateOutcome(id); a new intent or view discards old feedback.
  BrowsingLocateOutcome? get pendingLocateOutcome {
    final outcome = browsing.locateOutcome;
    final request = browsing.locateRequest;
    if (outcome == null ||
        (request != null && request.id != outcome.requestId) ||
        browsing.consumedLocateId == outcome.requestId ||
        outcome.generation != requestedQuery?.generation ||
        outcome.view != requestedView ||
        (outcome.status == BrowsingLocateStatus.matched &&
            !browsing.resultMatchesRequest))
      return null;
    return outcome;
  }
}

final feedProjectionProvider = Provider<FeedProjectionState>(
  (ref) => FeedProjectionState(ref.watch(browsingProvider)),
);
