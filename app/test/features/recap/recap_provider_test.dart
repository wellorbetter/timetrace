import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_settings_store.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

void main() {
  test('settings state changes only after persistence succeeds', () async {
    const initial = RecapAiSettings(model: 'old-model');
    const next = RecapAiSettings(enabled: true, model: 'new-model');
    final store = _ControlledSettingsStore(initial);
    final container = ProviderContainer(
      overrides: [recapAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(await container.read(recapAiSettingsProvider.future), initial);
    final save = container.read(recapAiSettingsProvider.notifier).save(next);
    await store.saveStarted.future;

    expect(container.read(recapAiSettingsProvider).value, initial);
    store.allowSave.complete();
    await save;

    expect(container.read(recapAiSettingsProvider).value, next);
    expect(store.persisted, next);
  });

  test('failed settings write preserves previous in-memory state', () async {
    const initial = RecapAiSettings(model: 'old-model');
    const next = RecapAiSettings(enabled: true, model: 'new-model');
    final store = _ControlledSettingsStore(initial, fail: true);
    final container = ProviderContainer(
      overrides: [recapAiSettingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(await container.read(recapAiSettingsProvider.future), initial);
    await expectLater(
      container.read(recapAiSettingsProvider.notifier).save(next),
      throwsA(isA<StateError>()),
    );

    expect(container.read(recapAiSettingsProvider).value, initial);
    expect(store.persisted, isNull);
  });
}

class _ControlledSettingsStore extends RecapAiSettingsStore {
  _ControlledSettingsStore(this.initial, {this.fail = false});

  final RecapAiSettings initial;
  final bool fail;
  final saveStarted = Completer<void>();
  final allowSave = Completer<void>();
  RecapAiSettings? persisted;

  @override
  Future<RecapAiSettings> load() async => initial;

  @override
  Future<void> save(RecapAiSettings settings) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    if (fail) throw StateError('disk write failed');
    await allowSave.future;
    persisted = settings;
  }
}
