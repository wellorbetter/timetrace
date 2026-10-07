import '../models/feed_fragment.dart';
import '../models/selection_anchor.dart';
import 'canonical_feed_projection.dart';

class SelectionReconciliation {
  const SelectionReconciliation._({
    this.fragment,
    this.anchor,
    this.invalidationReason,
    this.migrated = false,
  });

  final FeedFragment? fragment;
  final SelectionAnchor? anchor;
  final SelectionInvalidationReason? invalidationReason;
  final bool migrated;

  bool get isInvalidated => invalidationReason != null;
}

/// Run only on an accepted successful snapshot, not on loading/error placeholders
/// or a display batch. The same function can reconcile a viewport anchor, but its
/// result must not itself issue a scroll/locate request.
///
/// Exact duplicates and revision splits never choose an arbitrary occurrence.
/// A revision merge may migrate only if one same-source row contains the whole
/// old interval and retains its state and entities. A shorter interval cannot
/// prove a unique split lineage from a range-limited snapshot.
///
/// The current AccountingSnapshotDto exposes no explicit source-deletion
/// evidence. Snapshot integrity and absence from the range-limited projection
/// cannot establish deletion, so this function never emits deleted. Supporting
/// that reason requires a verified accounting contract with explicit deletion
/// evidence and query coverage sufficient to rule out range clipping.
SelectionReconciliation reconcileSelection(
  SelectionAnchor? previous,
  CanonicalFeedProjection projection,
) {
  if (previous == null) return const SelectionReconciliation._();
  final rows = projection.allFragments;
  if (!previous.originalStartUtc.isBefore(projection.effectiveEndUtc) ||
      !projection.effectiveStartUtc.isBefore(previous.originalEndUtc)) {
    return _invalid(SelectionInvalidationReason.outsideRange);
  }
  if (previous.duplicateCount != 1) {
    return _invalid(SelectionInvalidationReason.ambiguous);
  }

  if (previous.isPrivacyExcluded) {
    final candidates = rows
        .where(
          (row) =>
              row.isPrivacyExcluded &&
              row.originalStartUtc == previous.originalStartUtc &&
              row.originalEndUtc == previous.originalEndUtc,
        )
        .toList();
    if (candidates.length > 1) {
      return _invalid(SelectionInvalidationReason.ambiguous);
    }
    if (candidates.isEmpty) {
      return _invalid(SelectionInvalidationReason.privacyCannotConfirm);
    }
    return _finish(previous, candidates.single, projection.filter);
  }

  final source = previous.sourceIdentity;
  final revision = previous.sourceRevision;
  if (source == null || source.isEmpty || revision == null) {
    return _invalid(SelectionInvalidationReason.insufficientEvidence);
  }
  final sameSource = rows
      .where((row) => !row.isPrivacyExcluded && row.sourceIdentity == source)
      .toList();
  final candidates = sameSource
      .where((row) => _overlaps(previous, row))
      .toList();
  if (candidates.length > 1) {
    return _invalid(SelectionInvalidationReason.ambiguous);
  }
  if (candidates.isEmpty) {
    // A privacy row cannot prove that a missing source was deleted or renamed.
    if (rows.any((row) => row.isPrivacyExcluded && _overlaps(previous, row))) {
      return _invalid(SelectionInvalidationReason.privacyCannotConfirm);
    }
    // allFragments contains only rows intersecting the effective range. A
    // revised source may still exist entirely outside that range, even when
    // snapshot integrity is complete. Non-overlapping same-source rows also
    // cannot establish what happened to this particular interval.
    return _invalid(SelectionInvalidationReason.insufficientEvidence);
  }

  final candidate = candidates.single;
  final incomingRevision = candidate.sourceRevision;
  if (incomingRevision == null) {
    return _invalid(SelectionInvalidationReason.insufficientEvidence);
  }
  if (incomingRevision < revision) {
    return _invalid(SelectionInvalidationReason.staleRevision);
  }
  if (!previous.hasSameEntities(candidate)) {
    return _invalid(SelectionInvalidationReason.entityChanged);
  }
  final sameBounds =
      candidate.originalStartUtc == previous.originalStartUtc &&
      candidate.originalEndUtc == previous.originalEndUtc;
  if (incomingRevision == revision && !sameBounds) {
    return _invalid(SelectionInvalidationReason.intervalChanged);
  }
  final containsPrevious =
      !candidate.originalStartUtc.isAfter(previous.originalStartUtc) &&
      !candidate.originalEndUtc.isBefore(previous.originalEndUtc);
  if (!containsPrevious) {
    return _invalid(SelectionInvalidationReason.intervalChanged);
  }
  return _finish(previous, candidate, projection.filter);
}

bool _overlaps(SelectionAnchor anchor, FeedFragment fragment) =>
    anchor.originalStartUtc.isBefore(fragment.originalEndUtc) &&
    fragment.originalStartUtc.isBefore(anchor.originalEndUtc);

SelectionReconciliation _invalid(SelectionInvalidationReason reason) =>
    SelectionReconciliation._(invalidationReason: reason);

SelectionReconciliation _finish(
  SelectionAnchor previous,
  FeedFragment candidate,
  FeedFilter filter,
) {
  if (candidate.duplicateCount != 1) {
    return _invalid(SelectionInvalidationReason.ambiguous);
  }
  if (!filter.matches(candidate)) {
    return _invalid(SelectionInvalidationReason.filteredOut);
  }
  return SelectionReconciliation._(
    fragment: candidate,
    anchor: SelectionAnchor.fromFragment(candidate),
    migrated: candidate.identityKey != previous.identityKey,
  );
}
