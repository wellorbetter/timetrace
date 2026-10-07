import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../bridge/accounting.dart';
import '../../../bridge/api.dart';
import '../../../core/bridge/api_provider.dart';
import '../domain/canonical_feed_projection.dart';
import '../models/browsing_state.dart';

/// Test seam for calendar resolution. It is not an independent range store.
final browsingClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// Re-exported from dashboard_provider.dart for existing overrides/consumers.
final dashboardIanaTimezoneProvider = Provider<String?>((ref) {
  try {
    final timezone = TimeTraceApi.getSystemIanaTimezone().trim();
    return timezone.isEmpty ? null : timezone;
  } catch (_) {
    return null;
  }
});

class AccountingQuerySpec {
  const AccountingQuerySpec({
    required this.range,
    required this.asOf,
    required this.startUtc,
    required this.endUtc,
  });

  final AccountingRangeRequest range;
  final AccountingAsOfRequest asOf;
  final String startUtc;
  final String endUtc;

  String get key => '$startUtc|$endUtc|$range';

  BrowsingViewKey viewFor(FeedFilter filter) => BrowsingViewKey(
    range: range,
    startUtc: DateTime.parse(startUtc),
    endUtc: DateTime.parse(endUtc),
    filter: filter,
  );
}

/// Preserves the existing local-calendar conversion and as-of policy. Exact
/// canonical hour bounds bypass calendar reconstruction, including DST folds.
AccountingQuerySpec accountingQueryFor(
  DateRangeSelection selection,
  DateTime now, {
  String? timezone,
}) {
  final explicitStart = selection.startUtc;
  final explicitEnd = selection.endUtc;
  if (explicitStart != null || explicitEnd != null) {
    if (explicitStart == null ||
        explicitEnd == null ||
        !explicitStart.isUtc ||
        !explicitEnd.isUtc ||
        !explicitStart.isBefore(explicitEnd)) {
      throw ArgumentError('Invalid explicit accounting range');
    }
    final start = _utc(explicitStart);
    final end = _utc(explicitEnd);
    return AccountingQuerySpec(
      range: AccountingRangeRequest.utc(startUtc: start, endUtc: end),
      asOf: !now.isBefore(explicitStart) && now.isBefore(explicitEnd)
          ? const AccountingAsOfRequest.current()
          : AccountingAsOfRequest.at(asOfUtc: end),
      startUtc: start,
      endUtc: end,
    );
  }

  final today = DateTime(now.year, now.month, now.day);
  late final DateTime start;
  late final DateTime end;
  switch (selection.range) {
    case DateRange.today:
      start = today;
      end = DateTime(today.year, today.month, today.day + 1);
    case DateRange.yesterday:
      start = DateTime(today.year, today.month, today.day - 1);
      end = today;
    case DateRange.custom:
      final day = selection.day ?? now;
      start = DateTime(day.year, day.month, day.day);
      end = DateTime(day.year, day.month, day.day + 1);
    case DateRange.week:
      start = DateTime(today.year, today.month, today.day - today.weekday + 1);
      end = DateTime(today.year, today.month, today.day + 1);
    case DateRange.month:
      start = DateTime(today.year, today.month);
      end = DateTime(today.year, today.month, today.day + 1);
  }
  final startUtc = _utc(start);
  final endUtc = _utc(end);
  final isSingleDay =
      selection.range == DateRange.today ||
      selection.range == DateRange.yesterday ||
      selection.range == DateRange.custom;
  final range = isSingleDay && timezone != null
      ? AccountingRangeRequest.localDate(
          localDate: _date(start),
          timezone: timezone,
        )
      : AccountingRangeRequest.utc(startUtc: startUtc, endUtc: endUtc);
  final includesNow = !now.isBefore(start) && now.isBefore(end);
  return AccountingQuerySpec(
    range: range,
    asOf: includesNow
        ? const AccountingAsOfRequest.current()
        : AccountingAsOfRequest.at(
            asOfUtc: timezone == null ? endUtc : _utc(now),
          ),
    startUtc: startUtc,
    endUtc: endUtc,
  );
}

String _date(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _utc(DateTime date) =>
    date.toUtc().toIso8601String().replaceFirst('.000Z', 'Z');

/// Override with controlled Completers in runtime tests. Pages consume the feed
/// provider, not this loader. Even this seam returns only sanitized projections.
typedef AccountingSnapshotLoader =
    Future<CanonicalFeedProjection> Function(
      AccountingQuerySpec query,
      FeedFilter filter,
    );

final accountingSnapshotProvider = Provider<AccountingSnapshotLoader>((ref) {
  final api = ref.watch(apiProvider);
  return (query, filter) async {
    final snapshot = await api.getAccountingSnapshot(
      range: query.range,
      asOf: query.asOf,
    );
    _checkResponseRange(query, snapshot);
    return CanonicalFeedProjection.fromSnapshot(snapshot, filter: filter);
  };
});

void _checkResponseRange(
  AccountingQuerySpec query,
  AccountingSnapshotDto snapshot,
) {
  switch (query.range) {
    case AccountingRangeRequest_Utc(:final startUtc, :final endUtc):
      if (DateTime.parse(snapshot.requestedStartUtc) !=
              DateTime.parse(startUtc) ||
          DateTime.parse(snapshot.requestedEndUtc) != DateTime.parse(endUtc)) {
        throw const FormatException('Accounting response range mismatch');
      }
    case AccountingRangeRequest_LocalDate(:final localDate, :final timezone):
      // Local-date UTC bounds belong to Rust; do not compare them to nominal
      // Dart bounds. Validate the bridge's explicit local request metadata.
      if (snapshot.localDate != localDate || snapshot.timezone != timezone) {
        throw const FormatException('Accounting local response mismatch');
      }
  }
}
