import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';

void main() {
  group('AiDiaryPreferences', () {
    test('uses safe defaults for missing or malformed values', () {
      expect(
        AiDiaryPreferences.fromStorage(const <String, dynamic>{}),
        const AiDiaryPreferences(),
      );

      final preferences =
          AiDiaryPreferences.fromStorage(const <String, dynamic>{
            AiDiaryPreferences.enabledKey: 'yes',
            AiDiaryPreferences.coverSourceKey: 'custom',
            AiDiaryPreferences.builtInCoverIdKey: 'unknown',
            AiDiaryPreferences.customCoverPathKey: '   ',
          });

      expect(preferences.enabled, isFalse);
      expect(preferences.coverSource, AiDiaryCoverSource.builtIn);
      expect(preferences.builtInCoverId, kDefaultAiDiaryBuiltInCoverId);
      expect(preferences.customCoverPath, isNull);
    });

    test('round-trips the persisted representation', () {
      const preferences = AiDiaryPreferences(
        enabled: true,
        coverSource: AiDiaryCoverSource.custom,
        builtInCoverId: 'rainy_evening',
        customCoverPath: r'C:\managed\cover.webp',
      );

      expect(
        AiDiaryPreferences.fromStorage(preferences.toStorage()),
        preferences,
      );
    });
  });

  group('AiDiaryPreferencesNotifier', () {
    late Directory root;
    late Directory managedDirectory;
    late _MemoryStorage storage;
    late ProviderContainer container;

    setUp(() {
      root = Directory.systemTemp.createTempSync('timetrace_ai_diary_test_');
      managedDirectory = Directory(
        '${root.path}${Platform.pathSeparator}managed',
      );
      storage = _MemoryStorage();
      container = _createContainer(storage, managedDirectory);
    });

    tearDown(() {
      container.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('loads defaults and persists enable and built-in cover changes', () {
      expect(
        container.read(aiDiaryPreferencesProvider),
        const AiDiaryPreferences(),
      );

      final notifier = container.read(aiDiaryPreferencesProvider.notifier);
      notifier.setEnabled(true);
      expect(notifier.selectBuiltIn('rainy_evening'), isTrue);

      final state = container.read(aiDiaryPreferencesProvider);
      expect(state.enabled, isTrue);
      expect(state.coverSource, AiDiaryCoverSource.builtIn);
      expect(state.builtInCoverId, 'rainy_evening');
      expect(storage.values[AiDiaryPreferences.enabledKey], isTrue);
      expect(storage.values[AiDiaryPreferences.coverSourceKey], 'built_in');
      expect(
        storage.values[AiDiaryPreferences.builtInCoverIdKey],
        'rainy_evening',
      );
    });

    test('rejects an unknown built-in cover without changing state', () {
      final notifier = container.read(aiDiaryPreferencesProvider.notifier);
      final before = container.read(aiDiaryPreferencesProvider);

      expect(notifier.selectBuiltIn('not-a-cover'), isFalse);

      expect(container.read(aiDiaryPreferencesProvider), before);
      expect(storage.updateCount, 0);
    });

    test('imports a valid cover into the managed directory', () async {
      final source = File('${root.path}${Platform.pathSeparator}my-cover.PNG')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);

      final notifier = container.read(aiDiaryPreferencesProvider.notifier);
      expect(await notifier.importCustomCover(source.path), isTrue);

      final state = container.read(aiDiaryPreferencesProvider);
      expect(state.coverSource, AiDiaryCoverSource.custom);
      expect(state.customCoverPath, isNotNull);
      final managedCover = File(state.customCoverPath!);
      expect(managedCover.existsSync(), isTrue);
      expect(managedCover.parent.absolute.path, managedDirectory.absolute.path);
      expect(managedCover.readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(
        storage.values[AiDiaryPreferences.customCoverPathKey],
        managedCover.path,
      );
    });

    test(
      'replaces and removes only old covers inside the managed directory',
      () async {
        final firstSource = File(
          '${root.path}${Platform.pathSeparator}first.jpg',
        )..writeAsBytesSync(<int>[1]);
        final secondSource = File(
          '${root.path}${Platform.pathSeparator}second.webp',
        )..writeAsBytesSync(<int>[2]);
        final notifier = container.read(aiDiaryPreferencesProvider.notifier);

        expect(await notifier.importCustomCover(firstSource.path), isTrue);
        final firstManaged = File(
          container.read(aiDiaryPreferencesProvider).customCoverPath!,
        );
        expect(await notifier.importCustomCover(secondSource.path), isTrue);

        final secondManaged = File(
          container.read(aiDiaryPreferencesProvider).customCoverPath!,
        );
        expect(firstManaged.existsSync(), isFalse);
        expect(secondManaged.existsSync(), isTrue);

        notifier.setNone();
        expect(secondManaged.existsSync(), isFalse);
        expect(
          container.read(aiDiaryPreferencesProvider).coverSource,
          AiDiaryCoverSource.none,
        );
        expect(storage.values[AiDiaryPreferences.customCoverPathKey], isNull);
      },
    );

    test('never deletes a custom path outside the managed directory', () {
      final external = File('${root.path}${Platform.pathSeparator}external.png')
        ..writeAsBytesSync(<int>[9]);
      managedDirectory.createSync(recursive: true);
      container.dispose();
      storage = _MemoryStorage(<String, dynamic>{
        AiDiaryPreferences.coverSourceKey: 'custom',
        AiDiaryPreferences.customCoverPathKey: external.path,
      });
      container = _createContainer(storage, managedDirectory);

      container
          .read(aiDiaryPreferencesProvider.notifier)
          .selectBuiltIn('spring_morning');

      expect(external.existsSync(), isTrue);
    });

    test('rejects unsupported, empty, and oversized files', () async {
      final unsupported = File('${root.path}${Platform.pathSeparator}cover.gif')
        ..writeAsBytesSync(<int>[1]);
      final empty = File('${root.path}${Platform.pathSeparator}empty.png')
        ..createSync();
      final oversized = File(
        '${root.path}${Platform.pathSeparator}oversized.jpg',
      );
      final oversizedHandle = oversized.openSync(mode: FileMode.write);
      oversizedHandle.truncateSync(10 * 1024 * 1024 + 1);
      oversizedHandle.closeSync();
      final notifier = container.read(aiDiaryPreferencesProvider.notifier);

      expect(await notifier.importCustomCover(unsupported.path), isFalse);
      expect(await notifier.importCustomCover(empty.path), isFalse);
      expect(await notifier.importCustomCover(oversized.path), isFalse);
      expect(
        container.read(aiDiaryPreferencesProvider),
        const AiDiaryPreferences(),
      );
      expect(storage.updateCount, 0);
      expect(managedDirectory.existsSync(), isFalse);
    });
  });
}

ProviderContainer _createContainer(
  AiDiaryPreferencesStorage storage,
  Directory managedDirectory,
) {
  return ProviderContainer(
    overrides: [
      aiDiaryPreferencesStorageProvider.overrideWithValue(storage),
      aiDiaryManagedCoverDirectoryProvider.overrideWithValue(managedDirectory),
    ],
  );
}

class _MemoryStorage implements AiDiaryPreferencesStorage {
  _MemoryStorage([Map<String, dynamic>? initialValues])
    : values = <String, dynamic>{...?initialValues};

  final Map<String, dynamic> values;
  int updateCount = 0;

  @override
  Map<String, dynamic> read() => Map<String, dynamic>.of(values);

  @override
  void update(Map<String, dynamic> newValues) {
    updateCount++;
    values.addAll(newValues);
  }
}
