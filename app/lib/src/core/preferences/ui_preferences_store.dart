import 'dart:convert';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

String uiPreferencesTargetToken(Map<String, dynamic> root) => jsonEncode({
  for (final key in const [
    'version',
    'workspaceLayoutV3',
    'workspaceGroupsV2',
    'workspaceComponentsV1',
    'order',
  ])
    if (root.containsKey(key)) key: root[key],
});

String uiPreferencesFieldToken(Map<String, dynamic> root, String key) =>
    jsonEncode([root.containsKey(key), root[key]]);

sealed class UiPreferencesReadOutcome {
  const UiPreferencesReadOutcome();
}

class UiPreferencesMissing extends UiPreferencesReadOutcome {
  const UiPreferencesMissing();
  String get token => uiPreferencesTargetToken({});
}

class UiPreferencesLoaded extends UiPreferencesReadOutcome {
  UiPreferencesLoaded(Map<String, dynamic> root, this.originalBytes)
    : root = _freeze(root) as Map<String, dynamic>;
  final Map<String, dynamic> root;
  final String originalBytes;
  String get token => uiPreferencesTargetToken(root);
}

class UiPreferencesUnreadable extends UiPreferencesReadOutcome {
  const UiPreferencesUnreadable(
    this.reason, {
    this.recoverable,
    this.backupPath,
  });
  final String reason;
  final UiPreferencesLoaded? recoverable;
  final String? backupPath;
}

class UiPreferencesFuture extends UiPreferencesReadOutcome {
  const UiPreferencesFuture(this.version, this.originalBytes);
  final int version;
  final String originalBytes;
}

sealed class UiPreferencesWriteOutcome {
  const UiPreferencesWriteOutcome();
}

class UiPreferencesCommitted extends UiPreferencesWriteOutcome {
  const UiPreferencesCommitted(this.snapshot);
  final UiPreferencesLoaded snapshot;
}

class UiPreferencesBlocked extends UiPreferencesWriteOutcome {
  const UiPreferencesBlocked(this.reason);
  final UiPreferencesReadOutcome reason;
}

class UiPreferencesConflict extends UiPreferencesWriteOutcome {
  const UiPreferencesConflict();
}

class UiPreferencesFailed extends UiPreferencesWriteOutcome {
  const UiPreferencesFailed(
    this.stage,
    this.error, {
    this.recoverablePreimage,
    this.unverifiedSnapshot,
  });
  final String stage, error;
  final String? recoverablePreimage;
  final UiPreferencesLoaded? unverifiedSnapshot;
}

/// Fakes implement every stage; they never inherit a default private path.
abstract interface class UiPreferencesFileBackend {
  String get canonicalPath;
  bool exists(String path);
  String read(String path);
  List<String> backups();
  void ensureParent();
  void writeAndFlush(String path, String bytes);
  void rename(String source, String target);
  String nonce();
}

/// Optional safety capability. Legacy read backends remain source-compatible,
/// but cannot claim a durable write without cross-handle coordination.
abstract interface class UiPreferencesAtomicBackend {
  T withWriterLock<T>(T Function() action);
  void renameNoReplace(String source, String target);
}

class WindowsUiPreferencesFileBackend
    implements UiPreferencesFileBackend, UiPreferencesAtomicBackend {
  const WindowsUiPreferencesFileBackend();
  static int _sequence = 0;
  @override
  String get canonicalPath {
    final base = Platform.environment['APPDATA'];
    if (base == null || !Directory(base).isAbsolute) {
      throw const FileSystemException('APPDATA must be an absolute directory');
    }
    return base +
        Platform.pathSeparator +
        'TimeTrace' +
        Platform.pathSeparator +
        'ui_config.json';
  }

  @override
  bool exists(String path) => File(path).existsSync();
  @override
  String read(String path) => File(path).readAsStringSync();
  @override
  List<String> backups() {
    final file = File(canonicalPath);
    if (!file.parent.existsSync()) return [];
    return file.parent
        .listSync(followLinks: false)
        .whereType<File>()
        .map((entry) => entry.path)
        .where((path) => path.startsWith('$canonicalPath.timetrace-backup-'))
        .toList()
      ..sort();
  }

  @override
  void ensureParent() => File(canonicalPath).parent.createSync(recursive: true);
  @override
  void writeAndFlush(String path, String bytes) {
    File(path).createSync(exclusive: true);
    File(path).writeAsStringSync(bytes, flush: true);
  }

  @override
  void rename(String source, String target) => renameNoReplace(source, target);

  @override
  T withWriterLock<T>(T Function() action) {
    if (!Platform.isWindows) {
      throw const FileSystemException('Windows handle locking required');
    }
    ensureParent();
    final lock = File('$canonicalPath.timetrace-writer.lock');
    final kind = FileSystemEntity.typeSync(lock.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.file) {
      throw const FileSystemException('Unsafe preferences lock');
    }
    // Stable file: never truncated, renamed or removed. Use a non-blocking
    // handle lock: contention is a failed intent, not a synchronous UI wait.
    final handle = lock.openSync(mode: FileMode.append);
    var locked = false;
    try {
      handle.lockSync(FileLock.exclusive, 0, 1);
      locked = true;
      return action();
    } finally {
      if (locked) handle.unlockSync(0, 1);
      handle.closeSync();
    }
  }

  @override
  void renameNoReplace(String source, String target) {
    if (!Platform.isWindows ||
        File(source).parent.absolute.path.toLowerCase() !=
            File(target).parent.absolute.path.toLowerCase() ||
        source.contains('\u0000') ||
        target.contains('\u0000')) {
      throw const FileSystemException('Safe same-directory move required');
    }
    final from = File(source).absolute.path.toNativeUtf16();
    final to = File(target).absolute.path.toNativeUtf16();
    try {
      win32.GetLastError();
      final moved = win32.MoveFileEx(from, to, win32.MOVEFILE_WRITE_THROUGH);
      final error = moved == 0 ? win32.GetLastError() : 0;
      if (moved == 0) {
        throw FileSystemException(
          'Preferences no-replace move failed',
          target,
          OSError('MoveFileExW', error),
        );
      }
    } finally {
      malloc.free(to);
      malloc.free(from);
    }
  }

  @override
  String nonce() =>
      DateTime.now().microsecondsSinceEpoch.toString() +
      '-$pid-' +
      (++_sequence).toString();
}

/// Compatible read projections remain. Writes never use that permissive
/// projection and never open/truncate an existing canonical document.
class UiPreferencesStore {
  static const _defaultBackend = WindowsUiPreferencesFileBackend();
  static final _writing = <String>{};

  static UiPreferencesReadOutcome decodeOutcome(String source) {
    try {
      final raw = jsonDecode(source);
      if (raw is! Map<String, dynamic>) {
        return const UiPreferencesUnreadable('nonObject');
      }
      if (raw.containsKey('version')) {
        final version = raw['version'];
        if (version is! int || version < 1) {
          return const UiPreferencesUnreadable('invalidVersion');
        }
        if (version > 1) return UiPreferencesFuture(version, source);
      }
      return UiPreferencesLoaded(raw, source);
    } catch (_) {
      return const UiPreferencesUnreadable('corruptJson');
    }
  }

  static UiPreferencesReadOutcome readOutcome({
    UiPreferencesFileBackend? backend,
  }) {
    final io = backend ?? _defaultBackend;
    try {
      final path = io.canonicalPath;
      if (io.exists(path)) return decodeOutcome(io.read(path));
      final backups = io.backups();
      if (backups.isEmpty) return const UiPreferencesMissing();
      UiPreferencesLoaded? recovered;
      String? recoveredPath;
      for (final backup in backups.reversed) {
        final decoded = decodeOutcome(io.read(backup));
        if (decoded is UiPreferencesLoaded) {
          recovered = decoded;
          recoveredPath = backup;
          break;
        }
      }
      return UiPreferencesUnreadable(
        'recoveryRequired',
        recoverable: recovered,
        backupPath: recoveredPath,
      );
    } catch (_) {
      return const UiPreferencesUnreadable('io');
    }
  }

  static Map<String, dynamic> read({UiPreferencesFileBackend? backend}) {
    final result = readOutcome(backend: backend);
    if (result is UiPreferencesLoaded) return Map.of(result.root);
    if (result is UiPreferencesUnreadable && result.recoverable != null) {
      return Map.of(result.recoverable!.root);
    }
    return {};
  }

  static Map<String, dynamic> decode(String source) {
    // Historic decode is read-only, not a writable proof.
    try {
      final raw = jsonDecode(source);
      return raw is Map<String, dynamic> ? Map.of(raw) : {};
    } catch (_) {
      return {};
    }
  }

  static UiPreferencesWriteOutcome tryPatch(
    Map<String, dynamic> values, {
    required Object? expectedTargetToken,
    UiPreferencesFileBackend? backend,
    bool Function(Map<String, dynamic>)? validateRoot,
    Set<String> removeKeys = const {},
    Map<String, String>? expectedFields,
  }) {
    final io = backend ?? _defaultBackend;
    if (io is! UiPreferencesAtomicBackend) {
      return const UiPreferencesFailed('capability', 'Atomic backend required');
    }
    try {
      return (io as UiPreferencesAtomicBackend).withWriterLock(
        () => _patchLocked(
          values,
          expectedTargetToken: expectedTargetToken,
          backend: io,
          validateRoot: validateRoot,
          removeKeys: removeKeys,
          expectedFields: expectedFields,
        ),
      );
    } catch (error) {
      return UiPreferencesFailed('lock', error.runtimeType.toString());
    }
  }

  static UiPreferencesWriteOutcome _patchLocked(
    Map<String, dynamic> values, {
    required Object? expectedTargetToken,
    required UiPreferencesFileBackend backend,
    bool Function(Map<String, dynamic>)? validateRoot,
    required Set<String> removeKeys,
    Map<String, String>? expectedFields,
  }) {
    final io = backend;
    final atomic = io as UiPreferencesAtomicBackend;
    String? path, backup;
    var stage = 'read';
    var movedOriginal = false, acquired = false;
    try {
      path = io.canonicalPath;
      if (!_writing.add(path)) return const UiPreferencesConflict();
      acquired = true;
      final initial = readOutcome(backend: io);
      if (initial is! UiPreferencesLoaded && initial is! UiPreferencesMissing) {
        return UiPreferencesBlocked(initial);
      }
      final current = initial is UiPreferencesLoaded
          ? initial.root
          : <String, dynamic>{};
      if (uiPreferencesTargetToken(current) != expectedTargetToken) {
        return const UiPreferencesConflict();
      }
      if (validateRoot != null && !validateRoot(current)) {
        return const UiPreferencesBlocked(
          UiPreferencesUnreadable('invalidLayout'),
        );
      }
      final alreadyMatches =
          values.entries.every(
            (entry) =>
                current.containsKey(entry.key) &&
                jsonEncode(current[entry.key]) == jsonEncode(entry.value),
          ) &&
          removeKeys.every((key) => !current.containsKey(key));
      if (!alreadyMatches &&
          expectedFields != null &&
          expectedFields.entries.any(
            (entry) =>
                uiPreferencesFieldToken(current, entry.key) != entry.value,
          )) {
        return const UiPreferencesConflict();
      }
      // No generic erase API: only the known, typed disposable quote field.
      if (removeKeys.any((key) => key != 'dailyQuoteV2') ||
          removeKeys.any(values.containsKey)) {
        return const UiPreferencesFailed('scope', 'Unknown removal scope');
      }
      final next = <String, dynamic>{...current, ...values, 'version': 1};
      for (final key in removeKeys) {
        next.remove(key);
      }
      final encoded = const JsonEncoder.withIndent('  ').convert(next);
      final decoded = decodeOutcome(encoded);
      if (decoded is! UiPreferencesLoaded ||
          validateRoot != null && !validateRoot(decoded.root)) {
        return const UiPreferencesBlocked(
          UiPreferencesUnreadable('invalidPatch'),
        );
      }
      // Reliable current bytes already match this legal patch. A previous
      // commit whose readback failed can now be acknowledged without rewriting.
      if (initial is UiPreferencesLoaded &&
          current['version'] == 1 &&
          removeKeys.every((key) => !current.containsKey(key)) &&
          values.entries.every(
            (entry) =>
                jsonEncode(current[entry.key]) == jsonEncode(entry.value),
          )) {
        return UiPreferencesCommitted(initial);
      }
      stage = 'prepare';
      io.ensureParent();
      final suffix = io.nonce();
      final temporary = '$path.timetrace-tmp-$suffix';
      backup = '$path.timetrace-backup-$suffix';
      if (io.exists(temporary) || io.exists(backup)) {
        return const UiPreferencesFailed('prepare', 'Unique path collision');
      }
      stage = 'writeAndFlush';
      io.writeAndFlush(temporary, encoded);
      stage = 'recheck';
      final finalRead = readOutcome(backend: io);
      if (initial is UiPreferencesMissing) {
        if (finalRead is! UiPreferencesMissing)
          return const UiPreferencesConflict();
      } else if (finalRead is! UiPreferencesLoaded ||
          finalRead.originalBytes !=
              (initial as UiPreferencesLoaded).originalBytes) {
        return const UiPreferencesConflict();
      }
      if (initial is UiPreferencesLoaded) {
        stage = 'backup';
        atomic.renameNoReplace(path, backup);
        movedOriginal = true;
        // Verify the bytes actually captured by the rename, not only the
        // earlier read. A writer racing the last recheck must not be lost.
        stage = 'recheckBackup';
        if (io.read(backup) != initial.originalBytes) {
          if (!io.exists(path)) atomic.renameNoReplace(backup, path);
          return const UiPreferencesConflict();
        }
      }
      stage = 'commit';
      atomic.renameNoReplace(temporary, path);
      stage = 'verify';
      final committed = readOutcome(backend: io);
      if (committed is! UiPreferencesLoaded ||
          committed.originalBytes != encoded) {
        return UiPreferencesFailed(
          stage,
          'Committed document cannot be verified',
          recoverablePreimage: movedOriginal ? backup : null,
          unverifiedSnapshot: decoded,
        );
      }
      return UiPreferencesCommitted(committed);
    } catch (error) {
      if (movedOriginal && path != null && backup != null) {
        try {
          if (!io.exists(path) && io.exists(backup)) {
            atomic.renameNoReplace(backup, path);
          }
        } catch (_) {
          // A complete preimage survives; missing+backup remains read-only.
        }
      }
      return UiPreferencesFailed(
        stage,
        error.runtimeType.toString(),
        recoverablePreimage: movedOriginal ? backup : null,
      );
    } finally {
      if (acquired && path != null) _writing.remove(path);
    }
  }

  /// Explicit recovery, never called by read/build/update. Never overwrites
  /// a later file and verifies the retained bytes before moving the backup.
  static UiPreferencesWriteOutcome restoreRecovery(
    UiPreferencesUnreadable recovery, {
    UiPreferencesFileBackend? backend,
  }) {
    final io = backend ?? _defaultBackend;
    if (io is! UiPreferencesAtomicBackend) {
      return const UiPreferencesFailed('capability', 'Atomic backend required');
    }
    try {
      return (io as UiPreferencesAtomicBackend).withWriterLock(
        () => _restoreLocked(recovery, io),
      );
    } catch (error) {
      return UiPreferencesFailed('lock', error.runtimeType.toString());
    }
  }

  static UiPreferencesWriteOutcome _restoreLocked(
    UiPreferencesUnreadable recovery,
    UiPreferencesFileBackend io,
  ) {
    try {
      final current = readOutcome(backend: io);
      if (current is! UiPreferencesUnreadable ||
          current.reason != 'recoveryRequired' ||
          recovery.recoverable == null ||
          current.backupPath != recovery.backupPath ||
          current.recoverable?.originalBytes !=
              recovery.recoverable!.originalBytes ||
          io.exists(io.canonicalPath)) {
        return const UiPreferencesConflict();
      }
      (io as UiPreferencesAtomicBackend).renameNoReplace(
        recovery.backupPath!,
        io.canonicalPath,
      );
      final restored = readOutcome(backend: io);
      return restored is UiPreferencesLoaded
          ? UiPreferencesCommitted(restored)
          : UiPreferencesBlocked(restored);
    } catch (error) {
      return UiPreferencesFailed(
        'restore',
        error.runtimeType.toString(),
        recoverablePreimage: recovery.backupPath,
      );
    }
  }

  static void update(
    Map<String, dynamic> values, {
    UiPreferencesFileBackend? backend,
  }) {
    final snapshot = readOutcome(backend: backend);
    final token = switch (snapshot) {
      UiPreferencesMissing() => snapshot.token,
      UiPreferencesLoaded() => snapshot.token,
      _ => null,
    };
    if (token == null) return;
    // Legacy void callers retain memory on error. It is never an ack.
    tryPatch(values, expectedTargetToken: token, backend: backend);
  }
}
