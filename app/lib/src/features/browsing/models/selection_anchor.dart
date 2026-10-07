import '../../../bridge/accounting.dart';
import 'feed_fragment.dart';

enum SelectionInvalidationReason {
  userCleared,
  outsideRange,
  filteredOut,
  deleted,
  ambiguous,
  insufficientEvidence,
  staleRevision,
  intervalChanged,
  entityChanged,
  privacyCannotConfirm,
}

/// Constructible only from a sanitized fragment. No raw DTO or source reference
/// is retained. Privacy anchors contain time, state and safe occurrence metadata
/// only; occurrence metadata is never used as proof of identity.
class SelectionAnchor {
  factory SelectionAnchor.fromFragment(FeedFragment fragment) =>
      SelectionAnchor._(
        fragmentKey: fragment.key,
        identityKey: fragment.identityKey,
        originalStartUtc: fragment.originalStartUtc,
        originalEndUtc: fragment.originalEndUtc,
        state: fragment.state,
        appId: fragment.appId,
        windowId: fragment.windowId,
        windowAppId: fragment.windowAppId,
        pageId: fragment.pageId,
        pageWindowId: fragment.pageWindowId,
        sourceIdentity: fragment.sourceIdentity,
        sourceRevision: fragment.sourceRevision,
        duplicateCount: fragment.duplicateCount,
      );

  const SelectionAnchor._({
    required this.fragmentKey,
    required this.identityKey,
    required this.originalStartUtc,
    required this.originalEndUtc,
    required this.state,
    required this.appId,
    required this.windowId,
    required this.windowAppId,
    required this.pageId,
    required this.pageWindowId,
    required this.sourceIdentity,
    required this.sourceRevision,
    required this.duplicateCount,
  });

  final String fragmentKey;
  final String identityKey;
  final DateTime originalStartUtc;
  final DateTime originalEndUtc;
  final AccountingStateDto state;
  final String? appId;
  final String? windowId;
  final String? windowAppId;
  final String? pageId;
  final String? pageWindowId;
  final String? sourceIdentity;
  final BigInt? sourceRevision;
  final int duplicateCount;

  bool get isPrivacyExcluded => state == AccountingStateDto.privacyExcluded;

  bool hasSameEntities(FeedFragment fragment) =>
      state == fragment.state &&
      appId == fragment.appId &&
      windowId == fragment.windowId &&
      windowAppId == fragment.windowAppId &&
      pageId == fragment.pageId &&
      pageWindowId == fragment.pageWindowId;
}
