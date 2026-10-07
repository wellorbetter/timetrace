import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../bridge/accounting.dart';
import '../../../core/refresh/data_refresh_policy.dart';
import '../domain/canonical_feed_projection.dart';
import '../domain/selection_reconciliation.dart';
import '../models/browsing_state.dart';
import 'accounting_snapshot_provider.dart';

export '../models/browsing_state.dart';

/// Kept alive across Feed/data/settings routes within the same ProviderScope.
/// Navigation must not create a new scope or invalidate this provider.
final browsingProvider = NotifierProvider<BrowsingNotifier, BrowsingState>(
  BrowsingNotifier.new,
);

/// Compatibility reads derive from the sole authoritative range.
class DateRangeNotifier extends Notifier<DateRangeSelection> {
  @override
  DateRangeSelection build() =>
      ref.watch(browsingProvider.select((value) => value.range));

  void select(DateRange range) =>
      unawaited(ref.read(browsingProvider.notifier).selectRange(range));

  void selectDay(DateTime day) =>
      unawaited(ref.read(browsingProvider.notifier).selectDay(day));
}

final dashboardRangeProvider =
    NotifierProvider<DateRangeNotifier, DateRangeSelection>(
      DateRangeNotifier.new,
    );

/// Integration:
/// - Capture feedProjectionProvider.displayedQuery with the rendered list and
///   pass it to selection, entity-filter, viewport and batching actions.
/// - Legacy calls without a query require a current successful result.
/// - Explicit fragment locating requires a current successful result.
/// - Navigation records the page without clearing browsing context.
/// - Atomically consume an outcome before acting on it. Matched outcomes require
///   the current successful projection. Terminal failures do not scroll and may
///   be consumed during same-view loading or failure, without retaining a request.
///
/// Privacy policy: current sanitized public rows can confirm entity filters.
/// Anchors additionally require unique source/revision/interval reconciliation.
/// Other-range entity caches and unconfirmed public anchors are revoked. No
/// excluded identity, identity hash or denylist is retained.
class BrowsingNotifier extends Notifier<BrowsingState> {
  Object? _lifecycle;
  DataRefreshLoop? _loop;
  Future<void>? _pending;
  BrowsingViewKey? _pendingView;
  Object? _pendingToken;
  DateTime? _acceptedAt;
  int _generation = 0;
  int _locateId = 0;

  @override
  BrowsingState build() {
    final lifecycle = Object();
    _lifecycle = lifecycle;
    // Watching the loader/timezone revokes prior sanitized context on API changes.
    ref.watch(accountingSnapshotProvider);
    ref.watch(dashboardIanaTimezoneProvider);
    final policy = ref.watch(dataRefreshPolicyProvider);
    final visibility = ref.watch(dataRefreshVisibilityProvider);
    _loop?.dispose();
    _pending = null;
    _pendingView = null;
    _pendingToken = null;
    _acceptedAt = null;
    _loop = DataRefreshLoop(
      policy: policy,
      visible: visibility,
      onRefresh: refresh,
      canRefresh: () => _isLive(lifecycle) && _pending == null,
    );
    ref.onCancel(() => _loop?.cancel());
    ref.onResume(() {
      final loop = _loop;
      final epoch = loop?.resume();
      scheduleMicrotask(() {
        if (!_isLive(lifecycle)) return;
        final accepted = _acceptedAt;
        if (accepted != null &&
            ref.read(browsingClockProvider)().difference(accepted) >=
                policy.interval) {
          if (loop != null && epoch != null) {
            unawaited(loop.checkNow(expectedEpoch: epoch));
          }
        }
      });
    });
    ref.onDispose(() {
      if (identical(_lifecycle, lifecycle)) {
        _lifecycle = null;
        _loop?.dispose();
      }
    });
    scheduleMicrotask(() {
      if (_isLive(lifecycle) && state.query == null) {
        unawaited(refresh());
      }
    });
    return BrowsingState();
  }

  bool _isLive(Object lifecycle) =>
      identical(_lifecycle, lifecycle) && ref.mounted;

  Future<void> refresh() => _launch(range: state.range, filter: state.filter);

  Future<void> selectRange(DateRange range) =>
      setRange(DateRangeSelection(range));

  Future<void> selectDay(DateTime day) => setRange(
    DateRangeSelection(
      DateRange.custom,
      day: DateTime(day.year, day.month, day.day),
    ),
  );

  Future<void> setRange(DateRangeSelection range) => _launch(
    range: range,
    filter: state.filter,
    origin: LocateOrigin.calendar,
  );

  /// Canonical bucket boundaries distinguish both occurrences of a folded hour.
  Future<void> selectHour(LocalHourBucketDto hour) {
    final start = DateTime.parse(hour.startUtc);
    final end = DateTime.parse(hour.endUtc);
    if (!start.isUtc || !end.isUtc || !start.isBefore(end)) {
      throw ArgumentError('Invalid canonical hour');
    }
    return _launch(
      range: DateRangeSelection(
        DateRange.custom,
        day: start.toLocal(),
        startUtc: start,
        endUtc: end,
      ),
      filter: state.filter,
      origin: LocateOrigin.hour,
      targetUtc: start,
    );
  }

  Future<void> selectApp(String appId) =>
      setFilter(FeedFilter(appId: appId), origin: LocateOrigin.app);

  Future<void> selectWindow(String windowId, {String? appId}) => setFilter(
    FeedFilter(windowId: windowId, windowAppId: appId),
    origin: LocateOrigin.window,
  );

  Future<void> setFilter(
    FeedFilter filter, {
    LocateOrigin origin = LocateOrigin.app,
  }) => _launch(range: state.range, filter: filter, origin: origin);

  Future<void> clearFilter() => setFilter(const FeedFilter());

  Future<bool> filterFragmentApp(
    String key, {
    BrowsingQueryIdentity? query,
  }) async {
    final row = _currentFragment(key, query: query);
    if (row == null) return false;
    final filter = FeedFilter.forApp(row);
    if (filter == null) return false;
    await setFilter(filter, origin: LocateOrigin.app);
    return true;
  }

  Future<bool> filterFragmentWindow(
    String key, {
    BrowsingQueryIdentity? query,
  }) async {
    final row = _currentFragment(key, query: query);
    if (row == null) return false;
    final filter = FeedFilter.forWindow(row);
    if (filter == null) return false;
    await setFilter(filter, origin: LocateOrigin.window);
    return true;
  }

  void showPage(BrowsingPage page) => state = state.copyWith(page: page);

  bool selectFragment(String key, {BrowsingQueryIdentity? query}) {
    final row = _currentFragment(key, query: query);
    if (row == null) return false;
    state = state.copyWith(
      selectedAnchor: SelectionAnchor.fromFragment(row),
      selectionInvalidationReason: null,
    );
    return true;
  }

  void clearSelection() {
    state = state.copyWith(
      selectedAnchor: null,
      selectionInvalidationReason: SelectionInvalidationReason.userCleared,
    );
  }

  /// Explicit navigation requires the current successful generation.
  bool locateFragment(String key, {BrowsingQueryIdentity? query}) {
    if (!state.resultMatchesRequest) return false;
    final row = _currentFragment(key, query: query);
    final currentQuery = state.query;
    if (row == null || currentQuery == null) return false;
    state = _resolveLocate(
      state.copyWith(
        locateRequest: BrowsingLocateRequest(
          id: ++_locateId,
          view: currentQuery.view,
          targetUtc: row.visibleStartUtc,
          origin: LocateOrigin.fragment,
          fragment: SelectionAnchor.fromFragment(row),
        ),
        locateOutcome: null,
      ),
    );
    return true;
  }

  BrowsingLocateOutcome? consumeLocateOutcome(int id) {
    final outcome = state.locateOutcome;
    final request = state.locateRequest;
    if (outcome == null ||
        outcome.requestId != id ||
        (request != null && request.id != id) ||
        state.consumedLocateId == id ||
        outcome.view != state.query?.view ||
        outcome.generation != state.query?.generation ||
        (outcome.status == BrowsingLocateStatus.matched &&
            !state.resultMatchesRequest)) {
      return null;
    }
    state = state.copyWith(
      locateRequest: null,
      locateOutcome: null,
      consumedLocateId: id,
    );
    return outcome;
  }

  /// Saving a viewport preserves loading/error and locating state.
  bool saveViewport({
    required BrowsingQueryIdentity query,
    String? fragmentKey,
    double localOffset = 0,
    double? pixelOffset,
  }) {
    if (!state.canInteractWithDisplayedQuery(query)) return false;
    final row = fragmentKey == null
        ? null
        : _currentFragment(fragmentKey, query: query);
    if (fragmentKey != null && row == null) return false;
    final previous = state.views[query.view] ?? BrowsingViewState();
    final views = Map<BrowsingViewKey, BrowsingViewState>.of(state.views);
    views[query.view] = BrowsingViewState(
      viewportAnchor: row == null ? null : SelectionAnchor.fromFragment(row),
      localOffset: localOffset,
      pixelOffset: pixelOffset,
      pixelOffsetGeneration: pixelOffset == null ? null : query.generation,
      visibleCount: previous.visibleCount,
    );
    state = state.copyWith(views: views);
    return true;
  }

  /// Pass the rendered displayedQuery, including while a refresh has failed.
  void loadMore({int count = 100, BrowsingQueryIdentity? query}) {
    if (count <= 0) throw ArgumentError('Display increment must be positive');
    final displayed = _interactionQuery(query);
    if (displayed == null) return;
    final view = state.views[displayed.view] ?? BrowsingViewState();
    final views = Map<BrowsingViewKey, BrowsingViewState>.of(state.views);
    views[displayed.view] = _withCount(view, view.visibleCount + count);
    state = state.copyWith(views: views);
  }

  BrowsingQueryIdentity? _interactionQuery(BrowsingQueryIdentity? captured) {
    final displayed =
        captured ?? (state.resultMatchesRequest ? state.displayedQuery : null);
    if (displayed == null || !state.canInteractWithDisplayedQuery(displayed))
      return null;
    return displayed;
  }

  FeedFragment? _currentFragment(String key, {BrowsingQueryIdentity? query}) {
    if (_interactionQuery(query) == null) return null;
    for (final row in state.result!.projection.fragments) {
      if (row.key == key) return row;
    }
    return null;
  }

  Future<void> _launch({
    required DateRangeSelection range,
    required FeedFilter filter,
    LocateOrigin? origin,
    DateTime? targetUtc,
  }) {
    final lifecycle = _lifecycle;
    if (lifecycle == null || !_isLive(lifecycle)) return Future<void>.value();
    final query = accountingQueryFor(
      range,
      ref.read(browsingClockProvider)(),
      timezone: ref.read(dashboardIanaTimezoneProvider),
    );
    final view = query.viewFor(filter);
    if (origin == null && _pendingView == view && _pending != null) {
      return _pending!;
    }
    final token = Object();
    final completion = Completer<void>();
    _pendingToken = token;
    _pendingView = view;
    _pending = completion.future;
    final identity = BrowsingQueryIdentity(
      view: view,
      asOf: query.asOf,
      generation: ++_generation,
    );
    final previousLocate = state.locateRequest;
    final sameView = state.query?.view == view;
    final locate = origin != null
        ? BrowsingLocateRequest(
            id: ++_locateId,
            view: view,
            targetUtc: targetUtc ?? view.startUtc,
            origin: origin,
          )
        : sameView && previousLocate?.view == view
        ? previousLocate
        : null;
    final previousOutcome = state.locateOutcome;
    // Terminal feedback has its own lifetime. It is not conditional on the
    // request surviving, nor on a subsequent query succeeding. Rebinding only
    // safe terminal feedback makes same-view retries atomically consumable.
    final retainFailure =
        origin == null &&
        sameView &&
        previousOutcome != null &&
        previousOutcome.view == view &&
        previousOutcome.status != BrowsingLocateStatus.matched &&
        state.consumedLocateId != previousOutcome.requestId;
    state = state.copyWith(
      range: range,
      filter: filter,
      query: identity,
      phase: BrowsingLoadPhase.loading,
      failure: null,
      locateRequest: locate,
      locateOutcome: retainFailure
          ? _rebindFailure(previousOutcome, identity)
          : null,
    );
    _loop?.configure(query.asOf is AccountingAsOfRequest_Current);
    unawaited(
      _read(query, identity, lifecycle).whenComplete(() {
        if (identical(_pendingToken, token)) {
          _pending = null;
          _pendingView = null;
          _pendingToken = null;
        }
        completion.complete();
      }),
    );
    return completion.future;
  }

  Future<void> _read(
    AccountingQuerySpec query,
    BrowsingQueryIdentity identity,
    Object lifecycle,
  ) async {
    try {
      final loader = ref.read(accountingSnapshotProvider);
      final projection = await loader(query, identity.view.filter);
      if (!_isLive(lifecycle) || state.query != identity) return;
      final incoming = BrowsingResult(query: identity, projection: projection);
      if (!state.canAccept(incoming)) {
        state = state.copyWith(
          phase: BrowsingLoadPhase.failed,
          failure: BrowsingFailure.invalidSnapshot,
        );
        return;
      }

      // Validate ownership and freshness first. Rebuild the complete safe state
      // locally and publish once, including removal of old encoded cache keys.
      var acceptedIdentity = identity;
      var acceptedProjection = projection;
      var base = state;
      if (projection.hasPrivacyExcluded) {
        final safeFilter = _filterConfirmed(identity.view.filter, projection)
            ? identity.view.filter
            : FeedFilter(state: identity.view.filter.state);
        acceptedIdentity = BrowsingQueryIdentity(
          view: BrowsingViewKey(
            range: identity.view.range,
            startUtc: identity.view.startUtc,
            endUtc: identity.view.endUtc,
            filter: safeFilter,
          ),
          asOf: identity.asOf,
          generation: identity.generation,
        );
        acceptedProjection = projection.withFilter(safeFilter);
        base = _revokePrivateContext(
          base,
          acceptedIdentity,
          acceptedProjection,
        );
      }
      final selection = reconcileSelection(
        base.selectedAnchor,
        acceptedProjection,
      );
      final views = _reconcileViews(
        base.views,
        acceptedIdentity,
        acceptedProjection,
      );
      final next = base.copyWith(
        query: acceptedIdentity,
        filter: acceptedIdentity.view.filter,
        result: BrowsingResult(
          query: acceptedIdentity,
          projection: acceptedProjection,
        ),
        phase: BrowsingLoadPhase.ready,
        failure: null,
        selectedAnchor: selection.anchor,
        selectionInvalidationReason: base.selectedAnchor == null
            ? base.selectionInvalidationReason
            : selection.invalidationReason,
        views: views,
      );
      _acceptedAt = ref.read(browsingClockProvider)();
      state = _resolveLocate(next);
    } catch (error) {
      if (!_isLive(lifecycle) || state.query != identity) return;
      // Never retain raw exception messages, stacks or bridge DTOs.
      state = state.copyWith(
        phase: BrowsingLoadPhase.failed,
        failure: error is FormatException || error is ArgumentError
            ? BrowsingFailure.invalidSnapshot
            : BrowsingFailure.queryFailed,
      );
    }
  }
}

bool _sameRange(BrowsingViewKey a, BrowsingViewKey b) =>
    a.range == b.range && a.startUtc == b.startUtc && a.endUtc == b.endUtc;

/// Filters describe entities, not source lineage. A currently public matching
/// row confirms the permitted entity values; restoring an anchor still requires
/// the stronger source/revision/interval checks in reconcileSelection.
bool _filterConfirmed(FeedFilter filter, CanonicalFeedProjection projection) {
  if (!filter.hasEntityFilter) return true;
  return projection.allFragments.any(
    (row) =>
        !row.isPrivacyExcluded &&
        filter.matches(row) &&
        (filter.appId == null || row.capabilities.filterApp) &&
        (filter.windowId == null || row.capabilities.filterWindow),
  );
}

/// Called only for an accepted privacy-bearing projection. Current-range public
/// context is revalidated against sanitized evidence. Other ranges cannot be
/// certified by this snapshot; their entity keys and public anchors are erased.
BrowsingState _revokePrivateContext(
  BrowsingState before,
  BrowsingQueryIdentity safeQuery,
  CanonicalFeedProjection projection,
) {
  final views = <BrowsingViewKey, BrowsingViewState>{};
  for (final entry in before.views.entries) {
    final sameRange = _sameRange(entry.key, safeQuery.view);
    if (entry.key.filter.hasEntityFilter &&
        (!sameRange || !_filterConfirmed(entry.key.filter, projection))) {
      continue;
    }
    if (sameRange) {
      views[entry.key] = _restoreView(
        entry.value,
        projection.withFilter(entry.key.filter),
      );
      continue;
    }
    final anchor = entry.value.viewportAnchor;
    views[entry.key] = anchor != null && !anchor.isPrivacyExcluded
        ? BrowsingViewState(
            viewportInvalidationReason:
                SelectionInvalidationReason.privacyCannotConfirm,
            visibleCount: entry.value.visibleCount,
          )
        : entry.value;
  }

  final oldView = before.query?.view;
  final filterRevoked =
      oldView != null && oldView.filter != safeQuery.view.filter;
  if (filterRevoked) {
    // Preserve the display budget but never transplant the old entity key or
    // viewport identity into the newly unfiltered view.
    final oldMemory = before.views[oldView];
    final safeMemory = views[safeQuery.view];
    views[safeQuery.view] = BrowsingViewState(
      viewportAnchor: safeMemory?.viewportAnchor,
      viewportInvalidationReason: safeMemory?.viewportAnchor != null
          ? null
          : SelectionInvalidationReason.privacyCannotConfirm,
      localOffset: safeMemory?.localOffset ?? 0,
      visibleCount: math.max(
        oldMemory?.visibleCount ?? 100,
        safeMemory?.visibleCount ?? 100,
      ),
    );
  }

  // Reconcile before filtering so that a public-but-filtered-out selection is
  // distinguished from one whose source can no longer be confirmed.
  final selected = reconcileSelection(
    before.selectedAnchor,
    projection.withFilter(const FeedFilter()),
  );
  final request = before.locateRequest;
  BrowsingLocateRequest? safeRequest;
  BrowsingLocateOutcome? safeOutcome;
  if (request != null && request.view == oldView) {
    final restored = reconcileSelection(request.fragment, projection);
    final reason = filterRevoked
        ? SelectionInvalidationReason.privacyCannotConfirm
        : restored.invalidationReason;
    if (reason != null) {
      safeOutcome = BrowsingLocateOutcome(
        requestId: request.id,
        view: safeQuery.view,
        generation: safeQuery.generation,
        status: BrowsingLocateStatus.selectionInvalidated,
        invalidationReason: reason,
      );
    } else {
      safeRequest = BrowsingLocateRequest(
        id: request.id,
        view: safeQuery.view,
        targetUtc: request.targetUtc,
        origin: request.origin,
        fragment: restored.anchor,
      );
    }
  } else if (request == null) {
    final outcome = before.locateOutcome;
    if (outcome != null &&
        outcome.view == oldView &&
        before.consumedLocateId != outcome.requestId) {
      if (filterRevoked || outcome.status == BrowsingLocateStatus.matched) {
        // An orphan success has no lineage evidence. Never preserve its key.
        safeOutcome = BrowsingLocateOutcome(
          requestId: outcome.requestId,
          view: safeQuery.view,
          generation: safeQuery.generation,
          status: BrowsingLocateStatus.selectionInvalidated,
          invalidationReason: SelectionInvalidationReason.privacyCannotConfirm,
        );
      } else {
        safeOutcome = _rebindFailure(outcome, safeQuery);
      }
    }
  }

  return before.copyWith(
    filter: safeQuery.view.filter,
    query: safeQuery,
    result: null,
    selectedAnchor: selected.anchor,
    selectionInvalidationReason: before.selectedAnchor == null
        ? before.selectionInvalidationReason
        : selected.invalidationReason,
    views: views,
    locateRequest: safeRequest,
    locateOutcome: safeOutcome,
  );
}

/// Terminal outcomes carry no fragment key or anchor. The view must already be
/// the unchanged active view or a privacy-sanitized replacement of that view.
BrowsingLocateOutcome _rebindFailure(
  BrowsingLocateOutcome outcome,
  BrowsingQueryIdentity query,
) => BrowsingLocateOutcome(
  requestId: outcome.requestId,
  view: query.view,
  generation: query.generation,
  status: outcome.status,
  invalidationReason: outcome.invalidationReason,
);

Map<BrowsingViewKey, BrowsingViewState> _reconcileViews(
  Map<BrowsingViewKey, BrowsingViewState> saved,
  BrowsingQueryIdentity query,
  CanonicalFeedProjection projection,
) {
  final views = Map<BrowsingViewKey, BrowsingViewState>.of(saved);
  views[query.view] = _restoreView(
    views[query.view] ?? BrowsingViewState(),
    projection,
  );
  return views;
}

BrowsingViewState _restoreView(
  BrowsingViewState view,
  CanonicalFeedProjection projection,
) {
  final restored = reconcileSelection(view.viewportAnchor, projection);
  final restoredKey = restored.anchor?.fragmentKey;
  final index = restoredKey == null
      ? -1
      : projection.fragments.indexWhere((row) => row.key == restoredKey);
  return BrowsingViewState(
    viewportAnchor: restored.anchor,
    viewportInvalidationReason: view.viewportAnchor == null
        ? view.viewportInvalidationReason
        : restored.invalidationReason,
    localOffset: restored.anchor == null ? 0 : view.localOffset,
    // Absolute pixels belong to an old generation. Expand the prefix to mount
    // the restored anchor without issuing an explicit navigation request.
    visibleCount: math.max(view.visibleCount, index + 1),
  );
}

BrowsingViewState _withCount(BrowsingViewState view, int count) =>
    BrowsingViewState(
      viewportAnchor: view.viewportAnchor,
      viewportInvalidationReason: view.viewportInvalidationReason,
      localOffset: view.localOffset,
      pixelOffset: view.pixelOffset,
      pixelOffsetGeneration: view.pixelOffsetGeneration,
      visibleCount: count,
    );

BrowsingState _resolveLocate(BrowsingState state) {
  final request = state.locateRequest;
  final result = state.result;
  if (request == null ||
      result == null ||
      !state.resultMatchesRequest ||
      request.view != result.query.view)
    return state;
  final projection = result.projection;
  FeedFragment? target;
  SelectionInvalidationReason? reason;
  if (request.fragment != null) {
    final restored = reconcileSelection(request.fragment, projection);
    target = restored.fragment;
    reason = restored.invalidationReason;
  } else {
    // Explicit navigation finds the containing row or first following row.
    // This is never used as a fallback for failed selection restoration.
    var candidates = projection.fragments
        .where(
          (row) =>
              !request.targetUtc.isBefore(row.visibleStartUtc) &&
              request.targetUtc.isBefore(row.visibleEndUtc),
        )
        .toList();
    if (candidates.isEmpty) {
      final following = projection.fragments
          .where((row) => !row.visibleStartUtc.isBefore(request.targetUtc))
          .toList();
      if (following.isNotEmpty) {
        final firstStart = following.first.visibleStartUtc;
        candidates = following
            .where((row) => row.visibleStartUtc == firstStart)
            .toList();
      }
    }
    if (candidates.length == 1 && candidates.single.duplicateCount == 1) {
      target = candidates.single;
    } else if (candidates.isNotEmpty) {
      reason = SelectionInvalidationReason.ambiguous;
    }
  }
  final outcome = BrowsingLocateOutcome(
    requestId: request.id,
    view: request.view,
    generation: result.query.generation,
    status: target != null
        ? BrowsingLocateStatus.matched
        : reason != null
        ? BrowsingLocateStatus.selectionInvalidated
        : BrowsingLocateStatus.notMatched,
    fragmentKey: target?.key,
    invalidationReason: reason,
  );
  if (target == null) {
    // A terminal failure retains neither its old anchor nor an encoded key.
    return state.copyWith(locateRequest: null, locateOutcome: outcome);
  }
  final index = projection.fragments.indexWhere(
    (row) => row.key == target!.key,
  );
  final view = state.views[request.view] ?? BrowsingViewState();
  final views = Map<BrowsingViewKey, BrowsingViewState>.of(state.views);
  views[request.view] = _withCount(
    view,
    math.max(view.visibleCount, index + 1),
  );
  return state.copyWith(locateOutcome: outcome, views: views);
}
