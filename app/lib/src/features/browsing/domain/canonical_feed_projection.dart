import '../../../bridge/accounting.dart';
import '../models/feed_fragment.dart';

/// Pure local projection. No legacy details, attribution aggregates, gap filling,
/// name resolution, persistence, logging or remote operations are used here.
///
/// Boundary policy is [start, end): a row touching an endpoint has no visible
/// duration. Integration must verify this policy against Rust accounting tests;
/// the generated DTO alone does not document interval inclusivity.
class CanonicalFeedProjection {
  factory CanonicalFeedProjection.fromSnapshot(
    AccountingSnapshotDto snapshot, {
    FeedFilter filter = const FeedFilter(),
  }) {
    final requestedStart = _utc(snapshot.requestedStartUtc);
    final requestedEnd = _utc(snapshot.requestedEndUtc);
    final effectiveStart = _utc(snapshot.effectiveStartUtc);
    final effectiveEnd = _utc(snapshot.effectiveEndUtc);
    final observedThrough = _utc(snapshot.observedThroughUtc);
    if (!requestedStart.isBefore(requestedEnd) ||
        effectiveStart.isAfter(effectiveEnd) ||
        effectiveStart.isBefore(requestedStart) ||
        effectiveEnd.isAfter(requestedEnd)) {
      throw const FormatException('Invalid canonical snapshot boundaries');
    }

    final rows = <FeedFragment>[];
    for (final interval in snapshot.intervals) {
      final start = _utc(interval.startUtc);
      final end = _utc(interval.endUtc);
      if (!start.isBefore(end)) {
        throw const FormatException('Invalid canonical interval boundaries');
      }
      final visibleStart = start.isBefore(effectiveStart)
          ? effectiveStart
          : start;
      final visibleEnd = end.isAfter(effectiveEnd) ? effectiveEnd : end;
      if (!visibleStart.isBefore(visibleEnd)) continue;

      // Branch before reading identities, revisions or entity fields. Privacy
      // ordering and keys consequently cannot depend on excluded information.
      if (interval.state == AccountingStateDto.privacyExcluded) {
        rows.add(
          FeedFragment(
            originalStartUtc: start,
            originalEndUtc: end,
            visibleStartUtc: visibleStart,
            visibleEndUtc: visibleEnd,
            state: interval.state,
          ),
        );
      } else {
        final revision = BigInt.tryParse(interval.sourceRevision.toString());
        if (revision == null || revision.isNegative) {
          throw const FormatException('Invalid canonical source revision');
        }
        rows.add(
          FeedFragment(
            originalStartUtc: start,
            originalEndUtc: end,
            visibleStartUtc: visibleStart,
            visibleEndUtc: visibleEnd,
            state: interval.state,
            appId: interval.appId,
            windowId: interval.windowId,
            windowAppId: interval.windowAppId,
            pageId: interval.pageId,
            pageWindowId: interval.pageWindowId,
            sourceIdentity: interval.sourceIdentity,
            sourceRevision: revision,
          ),
        );
      }
    }

    rows.sort((a, b) {
      final start = a.originalStartUtc.compareTo(b.originalStartUtc);
      if (start != 0) return start;
      final end = a.originalEndUtc.compareTo(b.originalEndUtc);
      return end != 0 ? end : a.identityKey.compareTo(b.identityKey);
    });

    final numbered = <FeedFragment>[];
    var first = 0;
    while (first < rows.length) {
      var last = first + 1;
      while (last < rows.length &&
          rows[last].identityKey == rows[first].identityKey) {
        last++;
      }
      for (var index = first; index < last; index++) {
        numbered.add(
          rows[index].withMultiplicity(
            index: index - first,
            count: last - first,
          ),
        );
      }
      first = last;
    }

    return CanonicalFeedProjection._(
      requestedStartUtc: requestedStart,
      requestedEndUtc: requestedEnd,
      effectiveStartUtc: effectiveStart,
      effectiveEndUtc: effectiveEnd,
      observedThroughUtc: observedThrough,
      integrity: snapshot.integrity,
      filter: filter,
      allFragments: numbered,
    );
  }

  CanonicalFeedProjection._({
    required this.requestedStartUtc,
    required this.requestedEndUtc,
    required this.effectiveStartUtc,
    required this.effectiveEndUtc,
    required this.observedThroughUtc,
    required this.integrity,
    required this.filter,
    required List<FeedFragment> allFragments,
  }) : allFragments = List.unmodifiable(allFragments),
       fragments = List.unmodifiable(allFragments.where(filter.matches));

  final DateTime requestedStartUtc;
  final DateTime requestedEndUtc;
  final DateTime effectiveStartUtc;
  final DateTime effectiveEndUtc;
  final DateTime observedThroughUtc;

  /// Explicit snapshot-wide evidence, never inferred from row count or states.
  final SnapshotIntegrityDto integrity;
  final FeedFilter filter;

  /// In-range sanitized rows before entity/state filtering. Restoration must use
  /// this list before applying filters; filtered duplicates remain ambiguous.
  final List<FeedFragment> allFragments;
  final List<FeedFragment> fragments;

  bool get hasPrivacyExcluded =>
      allFragments.any((row) => row.isPrivacyExcluded);

  /// Replaces query metadata using the same sanitized rows and canonical
  /// evidence. It neither rereads a snapshot nor retains the previous filter.
  CanonicalFeedProjection withFilter(FeedFilter filter) =>
      CanonicalFeedProjection._(
        requestedStartUtc: requestedStartUtc,
        requestedEndUtc: requestedEndUtc,
        effectiveStartUtc: effectiveStartUtc,
        effectiveEndUtc: effectiveEndUtc,
        observedThroughUtc: observedThroughUtc,
        integrity: integrity,
        filter: filter,
        allFragments: allFragments,
      );

  /// Local display batching only. This is not a backend page or query cursor.
  /// Increasing the limit preserves every existing key and its ordering.
  List<FeedFragment> visibleBatch(int limit) {
    if (limit < 0) throw ArgumentError('Negative display limit');
    return List.unmodifiable(fragments.take(limit));
  }

  bool hasMore(int limit) {
    if (limit < 0) throw ArgumentError('Negative display limit');
    return limit < fragments.length;
  }
}

DateTime _utc(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc) {
    // Do not include input values in failures propagated into presentation state.
    throw const FormatException('Invalid canonical UTC timestamp');
  }
  return parsed;
}
