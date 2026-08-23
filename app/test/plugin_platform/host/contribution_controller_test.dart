import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

void main() {
  ContributionSnapshot snapshot(int revision) =>
      ContributionSnapshot.empty(revision: BigInt.from(revision));

  ProviderContainer containerFor(ContributionSource source) {
    final container = ProviderContainer(
      overrides: [contributionSourceProvider.overrideWithValue(source)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'initial source error publishes AsyncError with no old snapshot',
    () async {
      final source = _FakeContributionSource(
        onLoad: () async =>
            throw const ContributionSourceException('snapshot_unavailable'),
      );
      final container = containerFor(source);
      final errorState = Completer<AsyncValue<ContributionSnapshot>>();
      container.listen(contributionControllerProvider, (_, next) {
        if (next.hasError && !errorState.isCompleted) {
          errorState.complete(next);
        }
      }, fireImmediately: true);

      final state = await errorState.future.timeout(const Duration(seconds: 2));
      expect(state.hasError, isTrue);
      expect(state.error, isA<ContributionSourceException>());
      expect(state.value, isNull);
    },
  );

  test('enable success publishes only the returned newer snapshot', () async {
    final source = _FakeContributionSource(
      onLoad: () async => snapshot(1),
      onSetEnabled: (pluginId, enabled) async {
        expect(pluginId, 'private-flight');
        expect(enabled, isTrue);
        return snapshot(2);
      },
    );
    final container = containerFor(source);
    await container.read(contributionControllerProvider.future);

    await container
        .read(contributionControllerProvider.notifier)
        .setEnabled('private-flight', true);

    expect(
      container.read(contributionControllerProvider).requireValue.revision,
      BigInt.from(2),
    );
  });

  test('concurrent enable mutations are serialized', () async {
    final firstGate = Completer<ContributionSnapshot>();
    final secondGate = Completer<ContributionSnapshot>();
    var calls = 0;
    var inFlight = 0;
    var maxInFlight = 0;
    final source = _FakeContributionSource(
      onLoad: () async => snapshot(1),
      onSetEnabled: (pluginId, enabled) async {
        calls++;
        inFlight++;
        maxInFlight = maxInFlight < inFlight ? inFlight : maxInFlight;
        try {
          return await (calls == 1 ? firstGate.future : secondGate.future);
        } finally {
          inFlight--;
        }
      },
    );
    final container = containerFor(source);
    await container.read(contributionControllerProvider.future);
    final notifier = container.read(contributionControllerProvider.notifier);

    final first = notifier.setEnabled('private-flight', true);
    final second = notifier.setEnabled('private-flight', false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);

    firstGate.complete(snapshot(2));
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);

    secondGate.complete(snapshot(3));
    await second;
    expect(maxInFlight, 1);
    expect(
      container.read(contributionControllerProvider).requireValue.revision,
      BigInt.from(3),
    );
  });

  test(
    'older and equal mutation responses never roll state backward',
    () async {
      var calls = 0;
      final initial = snapshot(5);
      final source = _FakeContributionSource(
        onLoad: () async => initial,
        onSetEnabled: (pluginId, enabled) async {
          calls++;
          return calls == 1 ? snapshot(4) : snapshot(5);
        },
      );
      final container = containerFor(source);
      await container.read(contributionControllerProvider.future);
      final notifier = container.read(contributionControllerProvider.notifier);

      await notifier.setEnabled('private-flight', true);
      expect(
        container.read(contributionControllerProvider).requireValue,
        initial,
      );

      await notifier.setEnabled('private-flight', false);
      expect(
        container.read(contributionControllerProvider).requireValue,
        initial,
      );
    },
  );

  test(
    'prepareShutdown drains admitted work and rejects new mutations',
    () async {
      final gate = Completer<ContributionSnapshot>();
      final source = _FakeContributionSource(
        onLoad: () async => snapshot(1),
        onSetEnabled: (_, _) => gate.future,
      );
      final container = containerFor(source);
      await container.read(contributionControllerProvider.future);
      final notifier = container.read(contributionControllerProvider.notifier);

      final admitted = notifier.setEnabled('private-flight', true);
      final shutdown = notifier.prepareShutdown();
      expect(
        container.read(contributionControllerProvider).requireValue.active,
        isEmpty,
      );
      var shutdownCompleted = false;
      unawaited(shutdown.then((_) => shutdownCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);
      await notifier.setEnabled('private-flight', false);
      expect(
        container.read(contributionControllerProvider).error,
        isA<ContributionSourceException>().having(
          (error) => error.code,
          'code',
          'host_shutting_down',
        ),
      );

      gate.complete(snapshot(2));
      await admitted;
      await shutdown;
      expect(shutdownCompleted, isTrue);
    },
  );

  test('mutation admission queue is bounded', () async {
    final gate = Completer<ContributionSnapshot>();
    final source = _FakeContributionSource(
      onLoad: () async => snapshot(1),
      onSetEnabled: (_, _) => gate.future,
    );
    final container = containerFor(source);
    await container.read(contributionControllerProvider.future);
    final notifier = container.read(contributionControllerProvider.notifier);

    final admitted = [
      for (var index = 0; index < 32; index++)
        notifier.setEnabled('private-flight', index.isEven),
    ];
    await notifier.setEnabled('private-flight', true);
    expect(
      container.read(contributionControllerProvider).error,
      isA<ContributionSourceException>().having(
        (error) => error.code,
        'code',
        'mutation_queue_full',
      ),
    );

    gate.complete(snapshot(2));
    await Future.wait(admitted);
  });
}

final class _FakeContributionSource implements ContributionSource {
  _FakeContributionSource({required this.onLoad, this.onSetEnabled});

  final Future<ContributionSnapshot> Function() onLoad;
  final Future<ContributionSnapshot> Function(String pluginId, bool enabled)?
  onSetEnabled;

  @override
  Future<ContributionSnapshot> load() => onLoad();

  @override
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled) {
    final handler = onSetEnabled;
    if (handler == null) {
      throw StateError('unexpected setEnabled');
    }
    return handler(pluginId, enabled);
  }
}
