import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/refresh/data_refresh_policy.dart';
import 'package:timetrace_app/src/features/browsing/providers/accounting_snapshot_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/browsing_provider.dart';
import 'package:timetrace_app/src/features/browsing/providers/feed_projection_provider.dart';
import 'package:timetrace_app/src/features/browsing/domain/canonical_feed_projection.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';

AccountingSnapshotDto snap(
  AccountingQuerySpec q, {
  bool private = false,
  bool older = false,
}) {
  return AccountingSnapshotDto(
    requestedStartUtc: q.startUtc,
    requestedEndUtc: q.endUtc,
    effectiveStartUtc: q.startUtc,
    effectiveEndUtc: older ? q.startUtc : q.endUtc,
    observedThroughUtc: older ? q.startUtc : q.endUtc,
    totals: const AccountingTotalsDto(
      activeSeconds: 0,
      idleSeconds: 0,
      pausedSeconds: 0,
      privacyExcludedSeconds: 0,
      systemGapSeconds: 0,
      unknownSeconds: 0,
      accountedSeconds: 0,
    ),
    intervals: [
      AccountingIntervalDto(
        startUtc: q.startUtc,
        endUtc: q.endUtc,
        state: private
            ? AccountingStateDto.privacyExcluded
            : AccountingStateDto.active,
        appId: 'synthetic-public',
        sourceIdentity: 'synthetic-source',
        sourceRevision: 1,
      ),
    ],
    apps: private
        ? const []
        : const [AttributionTotalDto(id: 'synthetic-public', seconds: 1)],
    windows: const [],
    pages: const [],
    hours: const [],
    integrity: SnapshotIntegrityDto.complete,
  );
}

class PassiveBrowsing extends BrowsingNotifier {
  @override
  BrowsingState build() => BrowsingState();
  void choose(DateRangeSelection range) => state = state.copyWith(range: range);
}

void main() {
  for (final dashboard in [false, true]) {
    for (final paused in [false, true]) {
      testWidgets(
        'expired resume retains automatic gates dashboard=$dashboard paused=$paused',
        (tester) async {
          var now = DateTime(2026, 10, 3, 12);
          var calls = 0;
          var visible = true;
          final c = ProviderContainer(
            overrides: [
              browsingClockProvider.overrideWithValue(() => now),
              dashboardIanaTimezoneProvider.overrideWithValue(null),
              dataRefreshVisibilityProvider.overrideWithValue(() => visible),
              if (dashboard) browsingProvider.overrideWith(PassiveBrowsing.new),
              accountingSnapshotProvider.overrideWithValue((q, f) async {
                calls++;
                return CanonicalFeedProjection.fromSnapshot(snap(q), filter: f);
              }),
              dashboardSnapshotLoaderProvider.overrideWithValue((q) async {
                calls++;
                return snap(q);
              }),
              dashboardMetadataLoaderProvider.overrideWithValue(
                (q) => const DashboardMetadata(),
              ),
            ],
          );
          ProviderSubscription<dynamic> listen() => dashboard
              ? c.listen(dashboardProvider, (_, _) {})
              : c.listen(browsingProvider, (_, _) {});
          var sub = listen();
          await tester.pump();
          expect(calls, 1);
          sub.close();
          await tester.pump();
          now = now.add(const Duration(seconds: 31));
          visible = false;
          if (paused) {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
          }
          sub = listen();
          await tester.pump();
          expect(
            calls,
            1,
            reason:
                'Automatic resume is not a manual refresh and must retain visibility gating',
          );
          sub.close();
          await tester.pump();
          visible = true;
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          sub = listen();
          await tester.pump();
          expect(calls, 2);
          sub.close();
          sub = listen();
          await tester.pump();
          expect(
            calls,
            2,
            reason: 'Repeated resume must not refresh fresh data',
          );
          sub.close();
          c.dispose();
        },
      );
    }
  }

  testWidgets(
    'catch-up epochs reject late visibility without clearing newer flight',
    (tester) async {
      final checks = <Completer<bool>>[];
      var calls = 0;
      final loop = DataRefreshLoop(
        policy: const DataRefreshPolicy(),
        visible: () {
          final check = Completer<bool>();
          checks.add(check);
          return check.future;
        },
        onRefresh: () async {
          calls++;
        },
        canRefresh: () => true,
      );
      loop.configure(true);
      final first = loop.checkNow(expectedEpoch: loop.resume());
      loop.cancel();
      final secondEpoch = loop.resume();
      final second = loop.checkNow(expectedEpoch: secondEpoch);
      checks[0].complete(true);
      await first;
      expect(calls, 0);
      await loop.checkNow(expectedEpoch: secondEpoch);
      expect(
        checks,
        hasLength(2),
        reason: 'Old finally must not clear the new check',
      );
      checks[1].complete(true);
      await second;
      expect(calls, 1);
      final duplicate = loop.checkNow(expectedEpoch: loop.resume());
      // A query reconfiguration invalidates an awaited visibility result.
      loop.configure(false);
      checks[2].complete(true);
      await duplicate;
      expect(calls, 1);
      loop.configure(true);
      final finalCheck = loop.checkNow(expectedEpoch: loop.resume());
      loop.dispose();
      checks[3].complete(true);
      await finalCheck;
      expect(calls, 1);
    },
  );

  testWidgets('cancel before deferred catch-up cannot revive consumers', (
    tester,
  ) async {
    var calls = 0;
    final loop = DataRefreshLoop(
      policy: const DataRefreshPolicy(),
      visible: () => true,
      onRefresh: () async {
        calls++;
      },
      canRefresh: () => true,
    );
    loop.configure(true);
    final epoch = loop.resume();
    loop.cancel();
    await loop.checkNow(expectedEpoch: epoch);
    expect(calls, 0);
    loop.didChangeAppLifecycleState(AppLifecycleState.paused);
    await loop.checkNow(expectedEpoch: loop.resume());
    expect(calls, 0);
    loop.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await loop.checkNow(expectedEpoch: loop.resume());
    expect(calls, 1);
    loop.dispose();
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'dashboard monotonic refusal clears busy and midnight never relabels old data',
    (tester) async {
      var now = DateTime(2026, 10, 3, 12);
      final req = <(AccountingQuerySpec, Completer<AccountingSnapshotDto>)>[];
      final c = ProviderContainer(
        overrides: [
          browsingProvider.overrideWith(PassiveBrowsing.new),
          browsingClockProvider.overrideWithValue(() => now),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue((q) {
            final d = Completer<AccountingSnapshotDto>();
            req.add((q, d));
            return d.future;
          }),
          dashboardMetadataLoaderProvider.overrideWithValue(
            (_) => const DashboardMetadata(),
          ),
        ],
      );
      final sub = c.listen(dashboardProvider, (_, _) {});
      await tester.pump();
      req[0].$2.complete(snap(req[0].$1));
      await tester.pump();
      final accepted = c.read(dashboardProvider).requireValue;
      final stale = c.read(dashboardProvider.notifier).refresh();
      req[1].$2.complete(snap(req[1].$1, older: true));
      await stale;
      await tester.pump();
      expect(c.read(dashboardProvider).requireValue, same(accepted));
      expect(c.read(dashboardRefreshStatusProvider).refreshing, isFalse);
      expect(c.read(dashboardRefreshStatusProvider).error, isNotNull);
      now = DateTime(2026, 10, 4, 0, 1);
      final next = c.read(dashboardProvider.notifier).refresh();
      expect(c.read(dashboardProvider).isLoading, isTrue);
      // Riverpod retains previous data in AsyncLoading. It remains owned by
      // the old request and reload presentation must not relabel it as today.
      expect(c.read(dashboardProvider).isReloading, isTrue);
      expect(
        c
            .read(dashboardProvider)
            .when(
              skipLoadingOnReload: false,
              data: (_) => 'old data',
              error: (_, _) => 'error',
              loading: () => 'loading',
            ),
        'loading',
      );
      req[2].$2.complete(snap(req[2].$1));
      await next;
      await tester.pump();
      expect(
        c.read(dashboardProvider).requireValue.requestedStartUtc,
        req[2].$1.startUtc,
      );
      expect(req[2].$1.key, isNot(req[0].$1.key));
      sub.close();
      c.dispose();
    },
  );
  testWidgets(
    'browsing subscription resume only refreshes at 30s and API loader rebuild revokes memory',
    (tester) async {
      var now = DateTime(2026, 10, 3, 12), reads = 0;
      Future<CanonicalFeedProjection> load(
        AccountingQuerySpec q,
        FeedFilter f,
      ) async {
        reads++;
        return CanonicalFeedProjection.fromSnapshot(snap(q), filter: f);
      }

      final c = ProviderContainer(
        overrides: [
          browsingClockProvider.overrideWithValue(() => now),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          accountingSnapshotProvider.overrideWithValue(load),
        ],
      );
      var sub = c.listen(browsingProvider, (_, _) {});
      await tester.pump();
      expect(reads, 1);
      sub.close();
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      expect(reads, 1);
      now = now.add(const Duration(seconds: 29));
      sub = c.listen(browsingProvider, (_, _) {});
      await tester.pump();
      expect(reads, 1);
      sub.close();
      await tester.pump();
      now = now.add(const Duration(seconds: 1));
      sub = c.listen(browsingProvider, (_, _) {});
      await tester.pump();
      expect(reads, 2);
      final pending = Completer<CanonicalFeedProjection>();
      c.updateOverrides([
        browsingClockProvider.overrideWithValue(() => now),
        dashboardIanaTimezoneProvider.overrideWithValue(null),
        dataRefreshVisibilityProvider.overrideWithValue(() => true),
        accountingSnapshotProvider.overrideWithValue((q, f) => pending.future),
      ]);
      expect(c.read(browsingProvider).result, isNull);
      await tester.pump();
      sub.close();
      c.dispose();
      pending.completeError(StateError('synthetic after dispose'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dashboard loader identity clears matching cache and private snapshot clears icon metadata',
    (tester) async {
      var reads = 0, meta = 0, private = false;
      Future<AccountingSnapshotDto> load(AccountingQuerySpec q) async {
        reads++;
        return snap(q, private: private);
      }

      final metadata = (AccountingQuerySpec q) {
        meta++;
        return const DashboardMetadata(
          exePaths: {'synthetic-public': 'synthetic-path'},
        );
      };
      final c = ProviderContainer(
        overrides: [
          browsingProvider.overrideWith(PassiveBrowsing.new),
          browsingClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3, 12),
          ),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue(load),
          dashboardMetadataLoaderProvider.overrideWithValue(metadata),
        ],
      );
      final sub = c.listen(dashboardProvider, (_, _) {});
      await tester.pump();
      expect(
        c.read(dashboardProvider).requireValue.apps.single.exePath,
        'synthetic-path',
      );
      private = true;
      await c.read(dashboardProvider.notifier).refresh();
      await tester.pump();
      expect(c.read(dashboardProvider).requireValue.apps, isEmpty);
      expect(meta, 1);
      private = false;
      await c.read(dashboardProvider.notifier).refresh();
      await tester.pump();
      expect(meta, 2);
      c.updateOverrides([
        browsingProvider.overrideWith(PassiveBrowsing.new),
        browsingClockProvider.overrideWithValue(
          () => DateTime(2026, 10, 3, 12),
        ),
        dashboardIanaTimezoneProvider.overrideWithValue(null),
        dataRefreshVisibilityProvider.overrideWithValue(() => true),
        dashboardSnapshotLoaderProvider.overrideWithValue((q) async {
          reads++;
          return snap(q);
        }),
        dashboardMetadataLoaderProvider.overrideWithValue(metadata),
      ]);
      c.read(dashboardProvider);
      await tester.pump();
      expect(reads, 4);
      expect(meta, 3);
      sub.close();
      c.dispose();
    },
  );
  testWidgets(
    'pending visibility from old query and disposed loop cannot refresh later',
    (tester) async {
      final visible = Completer<bool>();
      var reads = 0;
      final loop = DataRefreshLoop(
        policy: const DataRefreshPolicy(),
        visible: () => visible.future,
        onRefresh: () async {
          reads++;
        },
        canRefresh: () => true,
      );
      loop.configure(true);
      await tester.pump(const Duration(seconds: 30));
      loop.configure(false);
      loop.configure(true);
      visible.complete(true);
      await tester.pump();
      expect(reads, 0);
      loop.dispose();
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 0);
    },
  );
  testWidgets(
    'one 30s loop skips flight invisible cancel background and dispose',
    (tester) async {
      var calls = 0, can = true, visible = true;
      final pending = Completer<void>();
      final loop = DataRefreshLoop(
        policy: const DataRefreshPolicy(),
        visible: () => visible,
        canRefresh: () => can,
        onRefresh: () {
          calls++;
          return pending.future;
        },
      );
      loop.configure(true);
      await tester.pump(const Duration(seconds: 29));
      expect(calls, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 1);
      pending.complete();
      await tester.pump();
      visible = false;
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 1);
      visible = true;
      can = false;
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 1);
      can = true;
      loop.cancel();
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 1);
      loop.resume();
      loop.resume();
      loop.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 1);
      loop.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 2);
      loop.dispose();
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 2);
    },
  );

  testWidgets(
    'browsing refresh shares Future and new filter supersedes old failure',
    (tester) async {
      final requests =
          <
            (
              AccountingQuerySpec,
              FeedFilter,
              Completer<CanonicalFeedProjection>,
            )
          >[];
      final container = ProviderContainer(
        overrides: [
          browsingClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3, 12),
          ),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          accountingSnapshotProvider.overrideWithValue((q, f) {
            final done = Completer<CanonicalFeedProjection>();
            requests.add((q, f, done));
            return done.future;
          }),
        ],
      );
      final sub = container.listen(browsingProvider, (_, _) {});
      await tester.pump();
      expect(requests.length, 1);
      final n = container.read(browsingProvider.notifier);
      final one = n.refresh(), two = n.refresh();
      expect(identical(one, two), isTrue);
      expect(requests.length, 1);
      final next = n.setFilter(const FeedFilter(appId: 'new'));
      expect(requests.length, 2);
      requests[0].$3.completeError(StateError('PRIVATE-ERROR'));
      await tester.pump();
      expect(container.read(browsingProvider).phase, BrowsingLoadPhase.loading);
      requests[1].$3.complete(
        CanonicalFeedProjection.fromSnapshot(
          snap(requests[1].$1),
          filter: requests[1].$2,
        ),
      );
      await next;
      await tester.pump();
      expect(container.read(browsingProvider).filter.appId, 'new');
      expect(container.read(browsingProvider).failure, isNull);
      sub.close();
      container.dispose();
    },
  );

  testWidgets(
    'same-view choices selection and viewport retained, private acceptance revokes',
    (tester) async {
      final requests =
          <
            (
              AccountingQuerySpec,
              FeedFilter,
              Completer<CanonicalFeedProjection>,
            )
          >[];
      final c = ProviderContainer(
        overrides: [
          browsingClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3, 12),
          ),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          accountingSnapshotProvider.overrideWithValue((q, f) {
            final done = Completer<CanonicalFeedProjection>();
            requests.add((q, f, done));
            return done.future;
          }),
        ],
      );
      final sub = c.listen(feedProjectionProvider, (_, _) {});
      await tester.pump();
      requests[0].$3.complete(
        CanonicalFeedProjection.fromSnapshot(snap(requests[0].$1)),
      );
      await tester.pump();
      final before = c.read(feedProjectionProvider),
          row = before.fragments.single;
      final n = c.read(browsingProvider.notifier);
      expect(n.selectFragment(row.key, query: before.displayedQuery), isTrue);
      expect(
        n.saveViewport(
          query: before.displayedQuery!,
          fragmentKey: row.key,
          localOffset: 7,
        ),
        isTrue,
      );
      final refresh = n.refresh();
      final busy = c.read(feedProjectionProvider);
      expect(busy.canInteract, isTrue);
      expect(
        busy.choiceProjection!.allFragments.single.appId,
        'synthetic-public',
      );
      expect(busy.browsing.selectedAnchor!.fragmentKey, row.key);
      requests[1].$3.completeError(StateError('PRIVATE-path'));
      await refresh;
      await tester.pump();
      expect(c.read(feedProjectionProvider).choiceProjection, isNotNull);
      final retry = n.refresh();
      requests[2].$3.complete(
        CanonicalFeedProjection.fromSnapshot(
          snap(requests[2].$1, private: true),
        ),
      );
      await retry;
      await tester.pump();
      expect(
        c
            .read(feedProjectionProvider)
            .choiceProjection!
            .allFragments
            .single
            .appId,
        isNull,
      );
      expect(c.read(browsingProvider).selectedAnchor, isNull);
      final changing = n.selectDay(DateTime(2026, 10, 2));
      expect(c.read(feedProjectionProvider).canInteract, isFalse);
      expect(c.read(feedProjectionProvider).choiceProjection, isNull);
      requests[3].$3.complete(
        CanonicalFeedProjection.fromSnapshot(snap(requests[3].$1)),
      );
      await changing;
      sub.close();
      c.dispose();
    },
  );

  testWidgets(
    'dashboard cold/manual coalesce, same-data refresh, route cache, failure retry',
    (tester) async {
      var now = DateTime(2026, 10, 3, 12), metadataCalls = 0;
      final requests =
          <(AccountingQuerySpec, Completer<AccountingSnapshotDto>)>[];
      final c = ProviderContainer(
        overrides: [
          browsingProvider.overrideWith(PassiveBrowsing.new),
          browsingClockProvider.overrideWithValue(() => now),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue((q) {
            final done = Completer<AccountingSnapshotDto>();
            requests.add((q, done));
            return done.future;
          }),
          dashboardMetadataLoaderProvider.overrideWithValue((q) {
            metadataCalls++;
            return const DashboardMetadata();
          }),
        ],
      );
      var sub = c.listen(dashboardProvider, (_, _) {});
      await tester.pump();
      final n = c.read(dashboardProvider.notifier);
      final cold1 = n.refresh(), cold2 = n.refresh();
      expect(identical(cold1, cold2), isTrue);
      expect(requests.length, 1);
      requests[0].$2.complete(snap(requests[0].$1));
      await cold1;
      await tester.pump();
      final accepted = c.read(dashboardProvider).requireValue;
      expect(metadataCalls, 1);
      final a = n.refresh(), b = n.refresh();
      expect(identical(a, b), isTrue);
      expect(c.read(dashboardProvider).requireValue, same(accepted));
      await tester.pump();
      expect(c.read(dashboardRefreshStatusProvider).refreshing, isTrue);
      requests[1].$2.completeError(StateError('PRIVATE'));
      await a;
      await tester.pump();
      expect(c.read(dashboardProvider).requireValue, same(accepted));
      expect(c.read(dashboardRefreshStatusProvider).error, '数据刷新失败，可重试');
      final retry = n.refresh();
      requests[2].$2.complete(snap(requests[2].$1));
      await retry;
      await tester.pump();
      expect(metadataCalls, 1);
      sub.close();
      await tester.pump();
      now = now.add(const Duration(seconds: 29));
      sub = c.listen(dashboardProvider, (_, _) {});
      await tester.pump();
      expect(requests.length, 3);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 30));
      expect(requests.length, 4);
      requests[3].$2.complete(snap(requests[3].$1));
      await tester.pump();
      expect(metadataCalls, 2);
      sub.close();
      c.dispose();
    },
  );

  testWidgets(
    'dashboard different range rejects late success and finally, scope pending dispose',
    (tester) async {
      final req = <(AccountingQuerySpec, Completer<AccountingSnapshotDto>)>[];
      final c = ProviderContainer(
        overrides: [
          browsingProvider.overrideWith(PassiveBrowsing.new),
          browsingClockProvider.overrideWithValue(
            () => DateTime(2026, 10, 3, 12),
          ),
          dashboardIanaTimezoneProvider.overrideWithValue(null),
          dataRefreshVisibilityProvider.overrideWithValue(() => true),
          dashboardSnapshotLoaderProvider.overrideWithValue((q) {
            final d = Completer<AccountingSnapshotDto>();
            req.add((q, d));
            return d.future;
          }),
          dashboardMetadataLoaderProvider.overrideWithValue(
            (q) => const DashboardMetadata(),
          ),
        ],
      );
      final sub = c.listen(dashboardProvider, (_, _) {});
      await tester.pump();
      (c.read(browsingProvider.notifier) as PassiveBrowsing).choose(
        DateRangeSelection(DateRange.custom, day: DateTime(2026, 10, 2)),
      );
      c.read(dashboardProvider);
      await tester.pump();
      expect(req.length, 2);

      req[0].$2.complete(snap(req[0].$1));
      await tester.pump();
      expect(c.read(dashboardRefreshStatusProvider).refreshing, isTrue);
      expect(c.read(dashboardProvider).isLoading, isTrue);
      req[1].$2.complete(snap(req[1].$1));
      await tester.pump();
      expect(
        c.read(dashboardProvider).requireValue.requestedStartUtc,
        req[1].$1.startUtc,
      );
      final flight = c.read(dashboardProvider.notifier).refresh();
      sub.close();
      c.dispose();
      req[2].$2.completeError(StateError('PRIVATE'));
      await flight;
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
