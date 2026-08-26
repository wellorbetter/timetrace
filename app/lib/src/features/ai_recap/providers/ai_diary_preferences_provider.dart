import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';

const _maxCustomCoverBytes = 10 * 1024 * 1024;
const _allowedCustomCoverExtensions = <String>{'png', 'jpg', 'jpeg', 'webp'};

abstract interface class AiDiaryPreferencesStorage {
  Map<String, dynamic> read();

  void update(Map<String, dynamic> values);
}

class UiAiDiaryPreferencesStorage implements AiDiaryPreferencesStorage {
  const UiAiDiaryPreferencesStorage();

  @override
  Map<String, dynamic> read() => UiPreferencesStore.read();

  @override
  void update(Map<String, dynamic> values) {
    UiPreferencesStore.update(values);
  }
}

final aiDiaryPreferencesStorageProvider = Provider<AiDiaryPreferencesStorage>((
  ref,
) {
  return const UiAiDiaryPreferencesStorage();
});

final aiDiaryManagedCoverDirectoryProvider = Provider<Directory>((ref) {
  final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  return Directory(
    '$base${Platform.pathSeparator}TimeTrace${Platform.pathSeparator}diary_covers',
  );
});

class AiDiaryPreferencesNotifier extends Notifier<AiDiaryPreferences> {
  late AiDiaryPreferencesStorage _storage;
  late Directory _managedCoverDirectory;

  @override
  AiDiaryPreferences build() {
    _storage = ref.watch(aiDiaryPreferencesStorageProvider);
    _managedCoverDirectory = ref.watch(aiDiaryManagedCoverDirectoryProvider);
    try {
      return AiDiaryPreferences.fromStorage(_storage.read());
    } catch (_) {
      return const AiDiaryPreferences();
    }
  }

  void setEnabled(bool enabled) {
    if (state.enabled == enabled) return;
    _commit(state.copyWith(enabled: enabled));
  }

  bool selectBuiltIn(String coverId) {
    if (!kAiDiaryBuiltInCoverIds.contains(coverId)) return false;
    final oldCustomPath = state.coverSource == AiDiaryCoverSource.custom
        ? state.customCoverPath
        : null;
    _commit(
      state.copyWith(
        coverSource: AiDiaryCoverSource.builtIn,
        builtInCoverId: coverId,
        customCoverPath: null,
      ),
    );
    _deleteManagedCover(oldCustomPath);
    return true;
  }

  void setNone() {
    final oldCustomPath = state.coverSource == AiDiaryCoverSource.custom
        ? state.customCoverPath
        : null;
    _commit(
      state.copyWith(
        coverSource: AiDiaryCoverSource.none,
        customCoverPath: null,
      ),
    );
    _deleteManagedCover(oldCustomPath);
  }

  Future<bool> importCustomCover(String sourcePath) async {
    File? temporaryFile;
    File? destinationFile;
    try {
      final source = File(sourcePath);
      if (!await source.exists()) return false;

      final extension = _extensionOf(source.path);
      if (!_allowedCustomCoverExtensions.contains(extension)) return false;
      final length = await source.length();
      if (length <= 0 || length > _maxCustomCoverBytes) return false;

      await _managedCoverDirectory.create(recursive: true);
      destinationFile = _uniqueDestination(extension);
      temporaryFile = File('${destinationFile.path}.tmp');
      await source.copy(temporaryFile.path);
      await temporaryFile.rename(destinationFile.path);
      temporaryFile = null;

      final oldCustomPath = state.coverSource == AiDiaryCoverSource.custom
          ? state.customCoverPath
          : null;
      _commit(
        state.copyWith(
          coverSource: AiDiaryCoverSource.custom,
          customCoverPath: destinationFile.path,
        ),
      );
      if (oldCustomPath != destinationFile.path) {
        _deleteManagedCover(oldCustomPath);
      }
      return true;
    } catch (_) {
      _deleteFileIfManaged(temporaryFile);
      _deleteFileIfManaged(destinationFile);
      return false;
    }
  }

  void _commit(AiDiaryPreferences preferences) {
    state = preferences;
    try {
      _storage.update(preferences.toStorage());
    } catch (_) {
      // UI preferences remain usable in memory if persistence is unavailable.
    }
  }

  File _uniqueDestination(String extension) {
    final stem = DateTime.now().toUtc().microsecondsSinceEpoch;
    for (var suffix = 0; suffix < 100; suffix++) {
      final name = suffix == 0 ? 'cover_$stem' : 'cover_${stem}_$suffix';
      final candidate = File(
        '${_managedCoverDirectory.path}${Platform.pathSeparator}$name.$extension',
      );
      if (!candidate.existsSync() &&
          !File('${candidate.path}.tmp').existsSync()) {
        return candidate;
      }
    }
    throw const FileSystemException('Unable to allocate a managed cover file');
  }

  void _deleteManagedCover(String? path) {
    if (path == null || path.isEmpty) return;
    _deleteFileIfManaged(File(path));
  }

  void _deleteFileIfManaged(File? file) {
    if (file == null || !file.existsSync()) return;
    try {
      if (!_managedCoverDirectory.existsSync()) return;
      final resolvedManagedDirectory = _normalizePath(
        _managedCoverDirectory.resolveSymbolicLinksSync(),
      );
      final resolvedFile = File(file.resolveSymbolicLinksSync());
      final resolvedParent = _normalizePath(resolvedFile.parent.path);
      if (resolvedParent != resolvedManagedDirectory) return;
      resolvedFile.deleteSync();
    } catch (_) {
      // Cover cleanup is best-effort and never affects the active preference.
    }
  }
}

String _extensionOf(String path) {
  final fileName = path.replaceAll('\\', '/').split('/').last;
  final separator = fileName.lastIndexOf('.');
  if (separator <= 0 || separator == fileName.length - 1) return '';
  return fileName.substring(separator + 1).toLowerCase();
}

String _normalizePath(String path) {
  var result = path.replaceAll('/', Platform.pathSeparator);
  while (result.endsWith(Platform.pathSeparator)) {
    result = result.substring(0, result.length - 1);
  }
  return Platform.isWindows ? result.toLowerCase() : result;
}

final aiDiaryPreferencesProvider =
    NotifierProvider<AiDiaryPreferencesNotifier, AiDiaryPreferences>(
      AiDiaryPreferencesNotifier.new,
    );
