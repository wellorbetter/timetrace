import 'dart:convert';

import '../../../bridge/accounting.dart';

/// Snapshot integrity does not establish the completeness of an individual
/// source. The current bridge has no source-level completeness evidence.
enum SourceCompleteness { unknown }

class FragmentCapabilities {
  const FragmentCapabilities({
    required this.inspectSource,
    required this.showEntityDetails,
    required this.filterApp,
    required this.filterWindow,
    required this.copy,
  });

  final bool inspectSource;
  final bool showEntityDetails;
  final bool filterApp;
  final bool filterWindow;
  final bool copy;
}

/// Only canonical identifiers are available; these are not resolved names.
/// Privacy rows never match an entity filter, including a partial parent filter.
class FeedFilter {
  const FeedFilter({this.appId, this.windowId, this.windowAppId, this.state});

  final String? appId;
  final String? windowId;
  final String? windowAppId;
  final AccountingStateDto? state;

  bool get hasEntityFilter =>
      appId != null || windowId != null || windowAppId != null;

  bool matches(FeedFragment fragment) {
    if (state != null && state != fragment.state) return false;
    if (hasEntityFilter && fragment.isPrivacyExcluded) return false;
    return (appId == null || appId == fragment.appDisplayName) &&
        (windowId == null || windowId == fragment.windowId) &&
        (windowAppId == null || windowAppId == fragment.windowAppId);
  }

  static FeedFilter? forApp(FeedFragment fragment) =>
      fragment.capabilities.filterApp
      ? FeedFilter(appId: fragment.appDisplayName)
      : null;

  static FeedFilter? forWindow(FeedFragment fragment) =>
      fragment.capabilities.filterWindow
      ? FeedFilter(
          windowId: fragment.windowId,
          windowAppId: fragment.windowAppId,
        )
      : null;

  @override
  bool operator ==(Object other) =>
      other is FeedFilter &&
      appId == other.appId &&
      windowId == other.windowId &&
      windowAppId == other.windowAppId &&
      state == other.state;

  @override
  int get hashCode => Object.hash(appId, windowId, windowAppId, state);
}

/// A sanitized canonical interval, not a reconstructed usage session.
///
/// originalDuration is the duration of the interval supplied by accounting; it
/// is not evidence of the duration of its underlying source event. visibleDuration
/// is the intersection with the snapshot's requested/effective bounds. Neither
/// duration is a replacement for accounting totals or rounded seconds.
class FeedFragment {
  factory FeedFragment({
    required DateTime originalStartUtc,
    required DateTime originalEndUtc,
    required DateTime visibleStartUtc,
    required DateTime visibleEndUtc,
    required AccountingStateDto state,
    String? appId,
    String? windowId,
    String? windowAppId,
    String? pageId,
    String? pageWindowId,
    String? sourceIdentity,
    BigInt? sourceRevision,
    int duplicateIndex = 0,
    int duplicateCount = 1,
  }) {
    if (!originalStartUtc.isUtc ||
        !originalEndUtc.isUtc ||
        !visibleStartUtc.isUtc ||
        !visibleEndUtc.isUtc ||
        !originalStartUtc.isBefore(originalEndUtc) ||
        !visibleStartUtc.isBefore(visibleEndUtc) ||
        visibleStartUtc.isBefore(originalStartUtc) ||
        visibleEndUtc.isAfter(originalEndUtc)) {
      throw ArgumentError('Invalid UTC fragment boundaries');
    }
    if (duplicateCount < 1 ||
        duplicateIndex < 0 ||
        duplicateIndex >= duplicateCount) {
      throw ArgumentError('Invalid fragment multiplicity');
    }

    // Erase before constructing any display object or identity encoding.
    // Do not replace these fields with hashes: those remain linkable identities.
    if (state == AccountingStateDto.privacyExcluded) {
      appId = null;
      windowId = null;
      windowAppId = null;
      pageId = null;
      pageWindowId = null;
      sourceIdentity = null;
      sourceRevision = null;
    }
    if (sourceRevision != null && sourceRevision.isNegative) {
      throw ArgumentError('Invalid source revision');
    }
    final identityKey = jsonEncode([
      originalStartUtc.toIso8601String(),
      originalEndUtc.toIso8601String(),
      state.name,
      appId,
      windowId,
      windowAppId,
      pageId,
      pageWindowId,
      sourceIdentity,
      sourceRevision?.toString(),
    ]);
    return FeedFragment._(
      originalStartUtc: originalStartUtc,
      originalEndUtc: originalEndUtc,
      visibleStartUtc: visibleStartUtc,
      visibleEndUtc: visibleEndUtc,
      state: state,
      appId: appId,
      windowId: windowId,
      windowAppId: windowAppId,
      pageId: pageId,
      pageWindowId: pageWindowId,
      sourceIdentity: sourceIdentity,
      sourceRevision: sourceRevision,
      identityKey: identityKey,
      duplicateIndex: duplicateIndex,
      duplicateCount: duplicateCount,
    );
  }

  const FeedFragment._({
    required this.originalStartUtc,
    required this.originalEndUtc,
    required this.visibleStartUtc,
    required this.visibleEndUtc,
    required this.state,
    required this.appId,
    required this.windowId,
    required this.windowAppId,
    required this.pageId,
    required this.pageWindowId,
    required this.sourceIdentity,
    required this.sourceRevision,
    required this.identityKey,
    required this.duplicateIndex,
    required this.duplicateCount,
  });

  final DateTime originalStartUtc;
  final DateTime originalEndUtc;
  final DateTime visibleStartUtc;
  final DateTime visibleEndUtc;
  final AccountingStateDto state;
  final String? appId;
  final String? windowId;
  final String? windowAppId;
  final String? pageId;
  final String? pageWindowId;
  final String? sourceIdentity;
  final BigInt? sourceRevision;
  final String identityKey;

  /// Occurrences distinguish identical rows in one projection. They do not
  /// establish lineage, and must never resolve a duplicate during restoration.
  final int duplicateIndex;
  final int duplicateCount;

  String get key => '$identityKey:$duplicateIndex';
  bool get isPrivacyExcluded => state == AccountingStateDto.privacyExcluded;
  Duration get originalDuration => originalEndUtc.difference(originalStartUtc);
  Duration get visibleDuration => visibleEndUtc.difference(visibleStartUtc);
  String? get appDisplayName => appId ?? windowAppId;
  String? get windowDisplayName => windowId;
  SourceCompleteness get sourceCompleteness => SourceCompleteness.unknown;

  FragmentCapabilities get capabilities => FragmentCapabilities(
    inspectSource: !isPrivacyExcluded && (sourceIdentity?.isNotEmpty ?? false),
    showEntityDetails: !isPrivacyExcluded,
    filterApp: !isPrivacyExcluded && appDisplayName != null,
    filterWindow: !isPrivacyExcluded && windowId != null,
    copy: !isPrivacyExcluded,
  );

  FeedFragment withMultiplicity({required int index, required int count}) =>
      FeedFragment(
        originalStartUtc: originalStartUtc,
        originalEndUtc: originalEndUtc,
        visibleStartUtc: visibleStartUtc,
        visibleEndUtc: visibleEndUtc,
        state: state,
        appId: appId,
        windowId: windowId,
        windowAppId: windowAppId,
        pageId: pageId,
        pageWindowId: pageWindowId,
        sourceIdentity: sourceIdentity,
        sourceRevision: sourceRevision,
        duplicateIndex: index,
        duplicateCount: count,
      );
}
