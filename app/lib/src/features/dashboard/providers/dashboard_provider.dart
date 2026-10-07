import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import '../../../core/format/app_identity.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import '../../../core/refresh/data_refresh_policy.dart';

import '../../browsing/providers/accounting_snapshot_provider.dart';
import '../../browsing/providers/browsing_provider.dart'
    show dashboardRangeProvider;

export '../../browsing/providers/accounting_snapshot_provider.dart'
    show AccountingQuerySpec, accountingQueryFor, dashboardIanaTimezoneProvider;
export '../../browsing/providers/browsing_provider.dart'
    show
        DateRange,
        DateRangeSelection,
        DateRangeNotifier,
        dashboardRangeProvider;

/// Existing consumers retain their import path, enum identity, provider reads,
/// timezone overrides and notifier select/selectDay calls. The range authority
/// now lives in browsingProvider; this module does not own another range.

bool snapshotIsNewer(DashboardState incoming, DashboardState current) {
  if (incoming.requestedStartUtc != current.requestedStartUtc ||
      incoming.requestedEndUtc != current.requestedEndUtc) {
    return false;
  }
  return incoming.effectiveEndUtc.compareTo(current.effectiveEndUtc) >= 0 &&
      incoming.observedThroughUtc.compareTo(current.observedThroughUtc) >= 0;
}

bool shouldAcceptSnapshot({
  required AccountingQuerySpec query,
  required AccountingQuerySpec selected,
  required DashboardState incoming,
  DashboardState? current,
}) =>
    selected.key == query.key &&
    (current == null || snapshotIsNewer(incoming, current));

/// Existing aggregate semantics are preserved; Feed never reconstructs its
/// intervals from these dashboard totals or legacy details.
DashboardState projectAccountingSnapshot(
  AccountingSnapshotDto snapshot, {
  bool databaseDegraded = false,
  Map<String, String> exePaths = const {},
}) {
  final totals = snapshot.totals;
  return DashboardState(
    apps: [
      for (final app in snapshot.apps)
        AppUsageItem(
          appName: app.id,
          activeSeconds: app.seconds.toInt(),
          idleSeconds: 0,
          exePath: exePaths[app.id] ?? exePaths[_appIdentityKey(app.id)],
        ),
    ],
    appAttribution: snapshot.apps,
    windows: snapshot.windows,
    pages: snapshot.pages,
    hours: snapshot.hours,
    totalActiveSeconds: totals.activeSeconds.toInt(),
    totalIdleSeconds: totals.idleSeconds.toInt(),
    pausedSeconds: totals.pausedSeconds.toInt(),
    privacyExcludedSeconds: totals.privacyExcludedSeconds.toInt(),
    systemGapSeconds: totals.systemGapSeconds.toInt(),
    unknownSeconds: totals.unknownSeconds.toInt(),
    accountedSeconds: totals.accountedSeconds.toInt(),
    integrity: snapshot.integrity,
    requestedStartUtc: snapshot.requestedStartUtc,
    requestedEndUtc: snapshot.requestedEndUtc,
    effectiveStartUtc: snapshot.effectiveStartUtc,
    effectiveEndUtc: snapshot.effectiveEndUtc,
    observedThroughUtc: snapshot.observedThroughUtc,
    databaseDegraded: databaseDegraded,
  );
}

typedef DashboardSnapshotLoader =
    Future<AccountingSnapshotDto> Function(AccountingQuerySpec query);
final dashboardSnapshotLoaderProvider = Provider<DashboardSnapshotLoader>((
  ref,
) {
  final api = ref.watch(apiProvider);
  return (query) =>
      api.getAccountingSnapshot(range: query.range, asOf: query.asOf);
});

class DashboardMetadata {
  const DashboardMetadata({
    this.exePaths = const {},
    this.databaseDegraded = false,
  });
  final Map<String, String> exePaths;
  final bool databaseDegraded;
}

typedef DashboardMetadataLoader =
    FutureOr<DashboardMetadata> Function(AccountingQuerySpec query);
final dashboardMetadataLoaderProvider = Provider<DashboardMetadataLoader>((
  ref,
) {
  final api = ref.watch(apiProvider);
  return (query) {
    // These optional Rust methods are synchronous. Caching reduces repetition,
    // but this wrapper does NOT move cold bridge work off the UI isolate.
    final paths = <String, String>{};
    try {
      final start = DateTime.parse(query.startUtc).toLocal();
      final end = DateTime.parse(
        query.endUtc,
      ).toLocal().subtract(const Duration(microseconds: 1));
      for (final app in api.getUsageSplit(
        start: _localDate(start),
        end: _localDate(end),
      )) {
        if (app.exePath.isEmpty) continue;
        paths[app.appName] = app.exePath;
        paths[_appIdentityKey(app.appName)] = app.exePath;
      }
    } catch (_) {}
    bool degraded = false;
    try {
      degraded = api.isDatabaseDegraded();
    } catch (_) {}
    return DashboardMetadata(exePaths: paths, databaseDegraded: degraded);
  };
});

class DashboardRefreshStatus {
  const DashboardRefreshStatus({
    this.queryKey,
    this.acceptedQueryKey,
    this.refreshing = false,
    this.error,
  });
  final String? queryKey;

  /// Query whose validated data may be rendered; never inferred from previous data.
  final String? acceptedQueryKey;
  final bool refreshing;
  final String? error;
}

class DashboardRefreshStatusNotifier extends Notifier<DashboardRefreshStatus> {
  @override
  DashboardRefreshStatus build() => const DashboardRefreshStatus();
  void update(DashboardRefreshStatus next) => state = next;
}

final dashboardRefreshStatusProvider =
    NotifierProvider<DashboardRefreshStatusNotifier, DashboardRefreshStatus>(
      DashboardRefreshStatusNotifier.new,
    );

class DashboardNotifier extends AsyncNotifier<DashboardState> {
  Object? _lifecycle;
  DataRefreshLoop? _loop;
  Future<DashboardState>? _flight;
  String? _flightKey;
  Object? _flightToken;
  DashboardState? _accepted;
  String? _acceptedKey;
  DateTime? _acceptedAt;
  DashboardSnapshotLoader? _source;
  DashboardMetadataLoader? _metadataSource;
  String? _timezone;
  DashboardMetadata? _metadata;
  String? _metadataKey;
  DateTime? _metadataAt;
  int _generation = 0;

  bool _live(Object life) => ref.mounted && identical(_lifecycle, life);

  void _status(Object life, int generation, DashboardRefreshStatus value) {
    // A build may publish to sibling providers only after its build frame.
    scheduleMicrotask(() {
      if (_live(life) && generation == _generation) {
        ref.read(dashboardRefreshStatusProvider.notifier).update(value);
      }
    });
  }

  @override
  Future<DashboardState> build() async {
    final selection = ref.watch(dashboardRangeProvider);
    final timezone = ref.watch(dashboardIanaTimezoneProvider);
    final loader = ref.watch(dashboardSnapshotLoaderProvider);
    final metadata = ref.watch(dashboardMetadataLoaderProvider);
    final policy = ref.watch(dataRefreshPolicyProvider);
    final visible = ref.watch(dataRefreshVisibilityProvider);
    if (!identical(_source, loader) ||
        !identical(_metadataSource, metadata) ||
        _timezone != timezone) {
      _accepted = null;
      _acceptedKey = null;
      _acceptedAt = null;
      _metadata = null;
      _metadataKey = null;
      _metadataAt = null;
    }
    _source = loader;
    _metadataSource = metadata;
    _timezone = timezone;
    final life = Object();
    _lifecycle = life;
    _flight = null;
    _flightKey = null;
    _flightToken = null;
    final generation = ++_generation;
    _loop?.dispose();
    _loop = DataRefreshLoop(
      policy: policy,
      visible: visible,
      onRefresh: refresh,
      canRefresh: () => _live(life) && _flight == null,
    );
    ref.onCancel(() => _loop?.cancel());
    ref.onResume(() {
      final loop = _loop;
      final epoch = loop?.resume();
      scheduleMicrotask(() {
        if (!_live(life)) return;
        final at = _acceptedAt;
        if (at != null &&
            ref.read(browsingClockProvider)().difference(at) >=
                policy.interval) {
          if (loop != null && epoch != null) {
            unawaited(loop.checkNow(expectedEpoch: epoch));
          }
        }
      });
    });
    ref.onDispose(() {
      if (identical(_lifecycle, life)) {
        _lifecycle = null;
        _loop?.dispose();
      }
    });
    final query = accountingQueryFor(
      selection,
      ref.read(browsingClockProvider)(),
      timezone: timezone,
    );
    _loop?.configure(query.asOf is AccountingAsOfRequest_Current);
    if (_acceptedKey == query.key &&
        _accepted != null &&
        _acceptedAt != null &&
        ref.read(browsingClockProvider)().difference(_acceptedAt!) <
            policy.interval) {
      _status(
        life,
        generation,
        DashboardRefreshStatus(
          queryKey: query.key,
          acceptedQueryKey: _acceptedKey,
        ),
      );
      return _accepted!;
    }
    if (_acceptedKey != query.key) {
      _accepted = null;
      _acceptedKey = null;
      _metadata = null;
      _metadataKey = null;
      _metadataAt = null;
    }
    return _request(query, life, generation);
  }

  /// Same-query manual calls share the exact Future; never invalidate the tree.
  Future<void> refresh() {
    final life = _lifecycle;
    if (life == null || !_live(life)) return Future<void>.value();
    final query = accountingQueryFor(
      ref.read(dashboardRangeProvider),
      ref.read(browsingClockProvider)(),
      timezone: ref.read(dashboardIanaTimezoneProvider),
    );
    final existing = _flight;
    if (existing != null && _flightKey == query.key) return _voidFlight!;
    if (_acceptedKey != query.key) {
      _accepted = null;
      _acceptedKey = null;
      _acceptedAt = null;
      _metadata = null;
      _metadataKey = null;
      _metadataAt = null;
      state = const AsyncLoading();
    }
    _loop?.configure(query.asOf is AccountingAsOfRequest_Current);
    final generation = ++_generation;
    final request = _request(query, life, generation);
    final operation = request.then<void>(
      (loaded) {
        if (_live(life) && generation == _generation) state = AsyncData(loaded);
      },
      onError: (Object _, StackTrace stack) {
        if (_live(life) &&
            generation == _generation &&
            (_acceptedKey != query.key || _accepted == null)) {
          state = AsyncError(
            StateError('Accounting snapshot unavailable'),
            StackTrace.empty,
          );
        }
      },
    );
    _voidFlight = operation;
    return operation;
  }

  Future<void>? _voidFlight;

  Future<DashboardState> _request(
    AccountingQuerySpec query,
    Object life,
    int generation,
  ) {
    final token = Object();
    _flightToken = token;
    _flightKey = query.key;
    _status(
      life,
      generation,
      DashboardRefreshStatus(
        queryKey: query.key,
        acceptedQueryKey: _acceptedKey == query.key ? _acceptedKey : null,
        refreshing: true,
      ),
    );
    final future = _load(query, life, generation)
        .then((incoming) {
          if (!_live(life) || generation != _generation) {
            throw StateError('Accounting result is no longer current');
          }
          final selected = accountingQueryFor(
            ref.read(dashboardRangeProvider),
            ref.read(browsingClockProvider)(),
            timezone: ref.read(dashboardIanaTimezoneProvider),
          );
          if (!shouldAcceptSnapshot(
            query: query,
            selected: selected,
            incoming: incoming,
            current: _acceptedKey == query.key ? _accepted : null,
          )) {
            throw StateError('Accounting snapshot unavailable');
          }
          _accepted = incoming;
          _acceptedKey = query.key;
          _acceptedAt = ref.read(browsingClockProvider)();
          _status(
            life,
            generation,
            DashboardRefreshStatus(
              queryKey: query.key,
              acceptedQueryKey: _acceptedKey,
            ),
          );
          return incoming;
        })
        .catchError((Object _, StackTrace stack) {
          _status(
            life,
            generation,
            DashboardRefreshStatus(
              queryKey: query.key,
              acceptedQueryKey: _acceptedKey == query.key ? _acceptedKey : null,
              error: '数据刷新失败，可重试',
            ),
          );
          throw StateError('Accounting snapshot unavailable');
        })
        .whenComplete(() {
          if (identical(_flightToken, token)) {
            _flight = null;
            _flightKey = null;
            _flightToken = null;
            _voidFlight = null;
          }
        });
    _flight = future;
    // Cold-build manual refresh also coalesces instead of returning null.
    _voidFlight = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return future;
  }

  Future<DashboardState> _load(
    AccountingQuerySpec query,
    Object life,
    int generation,
  ) async {
    final snapshot = await _source!(query);
    if (!_live(life) || generation != _generation)
      throw StateError('Superseded');
    // Validate request ownership before optional identities can enter memory.
    switch (query.range) {
      case AccountingRangeRequest_Utc(:final startUtc, :final endUtc):
        if (DateTime.parse(snapshot.requestedStartUtc) !=
                DateTime.parse(startUtc) ||
            DateTime.parse(snapshot.requestedEndUtc) !=
                DateTime.parse(endUtc)) {
          throw StateError('Accounting snapshot unavailable');
        }
      case AccountingRangeRequest_LocalDate(:final localDate, :final timezone):
        if (snapshot.localDate != localDate || snapshot.timezone != timezone) {
          throw StateError('Accounting snapshot unavailable');
        }
    }
    final private = snapshot.intervals.any(
      (row) => row.state == AccountingStateDto.privacyExcluded,
    );
    final now = ref.read(browsingClockProvider)();
    if (private) {
      _metadata = null;
      _metadataKey = null;
      _metadataAt = null;
    } else if (_metadataKey != query.key ||
        _metadata == null ||
        _metadataAt == null ||
        now.difference(_metadataAt!) >=
            ref.read(dataRefreshPolicyProvider).interval) {
      DashboardMetadata loaded;
      try {
        loaded = await _metadataSource!(query);
      } catch (_) {
        loaded = const DashboardMetadata();
      }
      if (!_live(life) || generation != _generation)
        throw StateError('Superseded');
      _metadata = loaded;
      _metadataKey = query.key;
      _metadataAt = now;
    }
    final metadata = private
        ? const DashboardMetadata()
        : _metadata ?? const DashboardMetadata();
    return projectAccountingSnapshot(
      snapshot,
      exePaths: metadata.exePaths,
      databaseDegraded: metadata.databaseDegraded,
    );
  }
}

/// App-scope accepted snapshot survives short route unsubscriptions.
final dashboardProvider =
    AsyncNotifierProvider<DashboardNotifier, DashboardState>(
      DashboardNotifier.new,
    );

String _localDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _appIdentityKey(String value) => appIdentityKey(value);
