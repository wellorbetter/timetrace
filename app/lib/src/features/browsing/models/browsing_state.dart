import '../../../bridge/accounting.dart';
import '../domain/canonical_feed_projection.dart';
import 'feed_fragment.dart';
import 'selection_anchor.dart';

export 'feed_fragment.dart';
export 'selection_anchor.dart';

/// Also exported from the original dashboard provider import path.
enum DateRange { today, yesterday, week, month, custom }

class DateRangeSelection {
  const DateRangeSelection(this.range, {this.day, this.startUtc, this.endUtc});

  final DateRange range;
  final DateTime? day;

  /// Optional exact bounds, used for canonical local-hour buckets. Both must
  /// be present, UTC and increasing; accountingQueryFor validates the pair.
  /// Keeping these bounds avoids guessing DST folds from a local hour number.
  final DateTime? startUtc;
  final DateTime? endUtc;

  DateTime get effectiveDay {
    final now = DateTime.now();
    switch (range) {
      case DateRange.today:
        return now;
      case DateRange.yesterday:
        return DateTime(now.year, now.month, now.day - 1);
      case DateRange.custom:
        return day ?? startUtc?.toLocal() ?? now;
      case DateRange.week:
      case DateRange.month:
        return now;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DateRangeSelection &&
      range == other.range &&
      day == other.day &&
      startUtc == other.startUtc &&
      endUtc == other.endUtc;

  @override
  int get hashCode => Object.hash(range, day, startUtc, endUtc);
}

/// Resolved request bounds and filter partition in-memory view state. An as-of
/// value or retry generation does not create a different view.
class BrowsingViewKey {
  BrowsingViewKey({
    required this.range,
    required this.startUtc,
    required this.endUtc,
    this.filter = const FeedFilter(),
  }) {
    if (!startUtc.isUtc || !endUtc.isUtc || !startUtc.isBefore(endUtc)) {
      throw ArgumentError('Invalid browsing range');
    }
  }

  final AccountingRangeRequest range;

  /// Nominal request bounds. Rust owns the actual local-date response bounds.
  final DateTime startUtc;
  final DateTime endUtc;
  final FeedFilter filter;

  @override
  bool operator ==(Object other) =>
      other is BrowsingViewKey &&
      range == other.range &&
      startUtc == other.startUtc &&
      endUtc == other.endUtc &&
      filter == other.filter;

  @override
  int get hashCode => Object.hash(range, startUtc, endUtc, filter);
}

class BrowsingQueryIdentity {
  BrowsingQueryIdentity({
    required this.view,
    required this.asOf,
    required this.generation,
  }) {
    if (generation < 0) throw ArgumentError('Negative query generation');
  }

  final BrowsingViewKey view;
  final AccountingAsOfRequest asOf;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is BrowsingQueryIdentity &&
      view == other.view &&
      asOf == other.asOf &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(view, asOf, generation);
}

enum BrowsingLoadPhase { idle, loading, ready, failed }

enum BrowsingFailure { unavailable, invalidSnapshot, queryFailed }

enum BrowsingPage { feed, data, settings }

enum LocateOrigin { calendar, hour, app, window, fragment }

enum BrowsingLocateStatus { matched, notMatched, selectionInvalidated }

/// Created only by explicit navigation/locating intent, never by refresh,
/// detail selection, viewport recording, or display batching.
/// Failed requests are discarded; their safe outcome remains consumable.
class BrowsingLocateRequest {
  BrowsingLocateRequest({
    required this.id,
    required this.view,
    required this.targetUtc,
    required this.origin,
    this.fragment,
  }) {
    if (id < 0 || !targetUtc.isUtc) {
      throw ArgumentError('Invalid locate request');
    }
  }

  final int id;
  final BrowsingViewKey view;
  final DateTime targetUtc;
  final LocateOrigin origin;
  final SelectionAnchor? fragment;
}

/// Consumers must atomically consume the id before scrolling, and must use the
/// matching projection generation. Failure outcomes contain no fragment key;
/// privacy revocation also removes entity filters from their view metadata.
class BrowsingLocateOutcome {
  BrowsingLocateOutcome({
    required this.requestId,
    required this.view,
    required this.generation,
    required this.status,
    this.fragmentKey,
    this.invalidationReason,
  }) {
    if (requestId < 0 ||
        generation < 0 ||
        (status == BrowsingLocateStatus.matched && fragmentKey == null) ||
        (status != BrowsingLocateStatus.matched && fragmentKey != null) ||
        (status == BrowsingLocateStatus.selectionInvalidated &&
            invalidationReason == null)) {
      throw ArgumentError('Invalid locate outcome');
    }
  }

  final int requestId;
  final BrowsingViewKey view;
  final int generation;
  final BrowsingLocateStatus status;
  final String? fragmentKey;
  final SelectionInvalidationReason? invalidationReason;
}

/// Selection and viewport are independent. Pixels can only be restored against
/// pixelOffsetGeneration; otherwise use the reconciled anchor/local offset.
class BrowsingViewState {
  BrowsingViewState({
    this.viewportAnchor,
    this.viewportInvalidationReason,
    this.localOffset = 0,
    this.pixelOffset,
    this.pixelOffsetGeneration,
    this.visibleCount = 100,
  }) {
    if (!localOffset.isFinite ||
        visibleCount < 0 ||
        (viewportAnchor != null && viewportInvalidationReason != null) ||
        (pixelOffset != null && (!pixelOffset!.isFinite || pixelOffset! < 0)) ||
        (pixelOffset != null && pixelOffsetGeneration == null) ||
        (pixelOffsetGeneration != null && pixelOffsetGeneration! < 0)) {
      throw ArgumentError('Invalid browsing view state');
    }
  }

  final SelectionAnchor? viewportAnchor;
  final SelectionInvalidationReason? viewportInvalidationReason;
  final double localOffset;
  final double? pixelOffset;
  final int? pixelOffsetGeneration;
  final int visibleCount;
}

class BrowsingResult {
  BrowsingResult({required this.query, required this.projection}) {
    if (query.view.filter != projection.filter) {
      throw ArgumentError('Projection filter does not match query identity');
    }
  }

  final BrowsingQueryIdentity query;
  final CanonicalFeedProjection projection;
}

const _unchanged = Object();

/// The sole writable range is owned by BrowsingNotifier. The dashboard range
/// notifier is a derived compatibility adapter, not another range authority.
/// Raw snapshots and exception text must never enter this state.
class BrowsingState {
  BrowsingState({
    this.range = const DateRangeSelection(DateRange.today),
    this.filter = const FeedFilter(),
    this.page = BrowsingPage.feed,
    this.query,
    this.result,
    this.phase = BrowsingLoadPhase.idle,
    this.failure,
    this.selectedAnchor,
    this.selectionInvalidationReason,
    this.locateRequest,
    this.locateOutcome,
    this.consumedLocateId,
    Map<BrowsingViewKey, BrowsingViewState> views = const {},
  }) : views = Map.unmodifiable(views) {
    if (selectedAnchor != null && selectionInvalidationReason != null) {
      throw ArgumentError('Selection cannot be both present and invalidated');
    }
    if (query != null && query!.view.filter != filter) {
      throw ArgumentError('Active query does not match the selected filter');
    }
  }

  final DateRangeSelection range;
  final FeedFilter filter;
  final BrowsingPage page;
  final BrowsingQueryIdentity? query;
  final BrowsingResult? result;
  final BrowsingLoadPhase phase;
  final BrowsingFailure? failure;
  final SelectionAnchor? selectedAnchor;
  final SelectionInvalidationReason? selectionInvalidationReason;
  final BrowsingLocateRequest? locateRequest;
  final BrowsingLocateOutcome? locateOutcome;
  final int? consumedLocateId;
  final Map<BrowsingViewKey, BrowsingViewState> views;

  BrowsingQueryIdentity? get displayedQuery => result?.query;
  bool get isRefreshing => phase == BrowsingLoadPhase.loading && result != null;
  bool get isShowingPreviousView =>
      result != null && result!.query.view != query?.view;
  bool get resultMatchesRequest => result != null && result!.query == query;

  /// Local interactions may use the last accepted generation while its exact
  /// view is refreshing or failed. They must identify the displayed generation.
  /// This permission does not authorize reconciliation or pending navigation.
  bool canInteractWithDisplayedQuery(BrowsingQueryIdentity displayed) =>
      result?.query == displayed && query?.view == displayed.view;

  bool get canInteractWithDisplayedResult {
    final displayed = displayedQuery;
    return displayed != null && canInteractWithDisplayedQuery(displayed);
  }

  bool canAccept(BrowsingResult incoming) {
    if (query != incoming.query) return false;
    final current = result;
    if (current == null || current.query.view != incoming.query.view)
      return true;
    final before = current.projection;
    final after = incoming.projection;
    return before.requestedStartUtc == after.requestedStartUtc &&
        before.requestedEndUtc == after.requestedEndUtc &&
        !after.effectiveEndUtc.isBefore(before.effectiveEndUtc) &&
        !after.observedThroughUtc.isBefore(before.observedThroughUtc);
  }

  BrowsingState copyWith({
    DateRangeSelection? range,
    FeedFilter? filter,
    BrowsingPage? page,
    Object? query = _unchanged,
    Object? result = _unchanged,
    BrowsingLoadPhase? phase,
    Object? failure = _unchanged,
    Object? selectedAnchor = _unchanged,
    Object? selectionInvalidationReason = _unchanged,
    Object? locateRequest = _unchanged,
    Object? locateOutcome = _unchanged,
    Object? consumedLocateId = _unchanged,
    Map<BrowsingViewKey, BrowsingViewState>? views,
  }) => BrowsingState(
    range: range ?? this.range,
    filter: filter ?? this.filter,
    page: page ?? this.page,
    query: identical(query, _unchanged)
        ? this.query
        : query as BrowsingQueryIdentity?,
    result: identical(result, _unchanged)
        ? this.result
        : result as BrowsingResult?,
    phase: phase ?? this.phase,
    failure: identical(failure, _unchanged)
        ? this.failure
        : failure as BrowsingFailure?,
    selectedAnchor: identical(selectedAnchor, _unchanged)
        ? this.selectedAnchor
        : selectedAnchor as SelectionAnchor?,
    selectionInvalidationReason:
        identical(selectionInvalidationReason, _unchanged)
        ? this.selectionInvalidationReason
        : selectionInvalidationReason as SelectionInvalidationReason?,
    locateRequest: identical(locateRequest, _unchanged)
        ? this.locateRequest
        : locateRequest as BrowsingLocateRequest?,
    locateOutcome: identical(locateOutcome, _unchanged)
        ? this.locateOutcome
        : locateOutcome as BrowsingLocateOutcome?,
    consumedLocateId: identical(consumedLocateId, _unchanged)
        ? this.consumedLocateId
        : consumedLocateId as int?,
    views: views ?? this.views,
  );
}
