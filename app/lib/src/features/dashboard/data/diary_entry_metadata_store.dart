import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

import '../domain/diary_entry_metadata.dart';

enum DiaryMetadataLoadStatus { missing, loaded, unreadable, future, conflict }

class DiaryMetadataLoad {
  const DiaryMetadataLoad(this.status, {this.value});
  final DiaryMetadataLoadStatus status;
  final DiaryEntryMetadata? value;
  bool get blocked =>
      status != DiaryMetadataLoadStatus.missing &&
      status != DiaryMetadataLoadStatus.loaded;
}

abstract interface class DiaryEntryMetadataStore {
  Future<DiaryMetadataLoad> load(DiaryEntryKey key);
  Future<void> put(DiaryEntryMetadata value, {required int? expectedRevision});
}

class DiaryMetadataConflict implements Exception {
  const DiaryMetadataConflict();
}

Directory diaryEntryMetadataDirectory() {
  if (!Platform.isWindows) {
    throw const FileSystemException('Windows storage unavailable');
  }
  final base = Platform.environment['LOCALAPPDATA'];
  if (base == null ||
      !RegExp(r'^(?:[a-zA-Z]:[\\/]|\\\\)').hasMatch(base) ||
      base.contains('\u0000')) {
    throw const FileSystemException(
      'Absolute local application directory required',
    );
  }
  return Directory(
    '$base${Platform.pathSeparator}TimeTrace${Platform.pathSeparator}diary-entry-metadata-v1',
  );
}

/// Injectable file operations; the default path is never evaluated in build.
class DiaryMetadataFileBackend {
  const DiaryMetadataFileBackend();
  static const writerLockName = '.metadata-writer.lock';
  Future<bool> exists(Directory directory) => directory.exists();
  Stream<FileSystemEntity> list(Directory directory) =>
      directory.list(followLinks: false);
  Future<String> read(File file) async {
    if (await file.length() > 65536) {
      throw const FormatException('Metadata too large');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 65536) throw const FormatException('Metadata too large');
    return utf8.decode(bytes);
  }

  Future<void> create(Directory directory) => directory.create(recursive: true);
  Future<RandomAccessFile> lockWriter(Directory directory) async {
    if (!Platform.isWindows) {
      throw const FileSystemException('Windows handle locking required');
    }
    final file = File(
      '${directory.path}${Platform.pathSeparator}$writerLockName',
    );
    final kind = await FileSystemEntity.type(file.path, followLinks: false);
    if (kind != FileSystemEntityType.notFound &&
        kind != FileSystemEntityType.file) {
      throw const DiaryMetadataConflict();
    }
    // Stable coordination file, never truncated/replaced/deleted. Windows
    // locks this range on the specific handle, including between same-process
    // independent stores. Do not claim the same isolation on POSIX.
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive, 0, 1);
      return handle;
    } catch (_) {
      await handle.close();
      rethrow;
    }
  }

  Future<void> write(File file, String bytes) async {
    // A temporary-name collision must not truncate another writer's payload.
    // Only temporary files are created this way; they are not published data.
    await file.create(exclusive: true);
    await file.writeAsString(bytes, flush: true);
  }

  Future<void> commit(File temporary, File target) async {
    if (!Platform.isWindows) {
      throw const FileSystemException('No-replace commit requires Windows');
    }
    if (temporary.parent.absolute.path !=
            File(target.path).parent.absolute.path ||
        temporary.path.contains('\u0000') ||
        target.path.contains('\u0000')) {
      throw const FileSystemException(
        'Commit requires safe same-directory paths',
      );
    }
    // This early check is diagnostic only. The native move below, not this
    // asynchronous observation, is what prevents another writer being replaced.
    if (await target.exists()) throw const DiaryMetadataConflict();
    final from = temporary.absolute.path.toNativeUtf16();
    try {
      final to = File(target.path).absolute.path.toNativeUtf16();
      try {
        // No REPLACE_EXISTING, COPY_ALLOWED or deferred reboot operation. The
        // complete, flushed temporary file is atomically installed or rejected.
        // Resolve the package's lazy GetLastError FFI binding before the move:
        // looking it up for the first time after failure can change last-error.
        win32.GetLastError();
        final moved = win32.MoveFileEx(from, to, win32.MOVEFILE_WRITE_THROUGH);
        final error = moved == 0 ? win32.GetLastError() : 0;
        if (moved == 0) {
          if (error == win32.ERROR_FILE_EXISTS ||
              error == win32.ERROR_ALREADY_EXISTS) {
            throw const DiaryMetadataConflict();
          }
          throw FileSystemException(
            'Metadata no-replace commit failed',
            target.path,
            OSError('MoveFileExW', error),
          );
        }
      } finally {
        malloc.free(to);
      }
    } finally {
      malloc.free(from);
    }
  }
}

/// One private directory per (date,id), immutable revisions and verified ack.
/// All revisions and interrupted temporary files are retained.
class FileDiaryEntryMetadataStore implements DiaryEntryMetadataStore {
  FileDiaryEntryMetadataStore({
    Directory Function()? directory,
    this.backend = const DiaryMetadataFileBackend(),
    String Function()? nonce,
  }) : directory = directory ?? diaryEntryMetadataDirectory,
       nonce = nonce ?? _nonce;
  final Directory Function() directory;
  final DiaryMetadataFileBackend backend;
  final String Function() nonce;
  Future<void> _queue = Future.value();
  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Directory _entry(DiaryEntryKey key) {
    final root = directory();
    if (!root.isAbsolute) {
      throw const FileSystemException('Absolute directory required');
    }
    return Directory(
      '${root.path}${Platform.pathSeparator}${key.date}${Platform.pathSeparator}${key.entryId}',
    );
  }

  Future<DiaryMetadataLoad> _read(DiaryEntryKey key) async {
    final dir = _entry(key);
    if (!await backend.exists(dir)) {
      return const DiaryMetadataLoad(DiaryMetadataLoadStatus.missing);
    }
    DiaryEntryMetadata? best;
    var invalid = false, future = false, count = 0;
    await for (final entity in backend.list(dir)) {
      if (++count > 10000) {
        invalid = true;
        break;
      }
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == DiaryMetadataFileBackend.writerLockName && entity is File)
        continue;
      if (name.endsWith('.tmp') && entity is File) continue;
      final match = RegExp(
        r'^metadata-r(0|[1-9][0-9]*)\.json$',
      ).firstMatch(name);
      if (entity is! File || match == null) {
        invalid = true;
        continue;
      }
      try {
        final raw = jsonDecode(await backend.read(entity));
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('Invalid root');
        }
        final value = DiaryEntryMetadata.fromJson(raw);
        if (value.key != key || value.revision.toString() != match[1]) {
          throw const FormatException('Identity mismatch');
        }
        if (best == null || value.revision > best.revision) best = value;
      } on DiaryMetadataFuture {
        future = true;
      } catch (_) {
        invalid = true;
      }
    }
    return DiaryMetadataLoad(
      future
          ? DiaryMetadataLoadStatus.future
          : invalid
          ? DiaryMetadataLoadStatus.unreadable
          : best == null
          ? DiaryMetadataLoadStatus.missing
          : DiaryMetadataLoadStatus.loaded,
      value: best,
    );
  }

  @override
  Future<DiaryMetadataLoad> load(DiaryEntryKey key) async {
    await _queue;
    return _read(key);
  }

  @override
  Future<void> put(DiaryEntryMetadata value, {required int? expectedRevision}) {
    final operation = _queue.then((_) async {
      final encoded = jsonEncode(value.toJson());
      DiaryEntryMetadata.fromJson(jsonDecode(encoded));
      if (utf8.encode(encoded).length > 65536) {
        throw const FormatException('Metadata too large');
      }
      final dir = _entry(value.key);
      await backend.create(dir);
      final writer = await backend.lockWriter(dir);
      try {
        // Re-read the CAS base only after obtaining cross-handle exclusion.
        // Different target revisions must not bypass this shared transaction.
        final history = await _read(value.key);
        if (history.blocked) throw const DiaryMetadataConflict();
        final target = File(
          '${dir.path}${Platform.pathSeparator}metadata-r${value.revision}.json',
        );
        if (history.value?.revision == value.revision) {
          if (await backend.read(target) == encoded) return;
          throw const DiaryMetadataConflict();
        }
        if (history.value?.revision != expectedRevision ||
            history.value != null &&
                history.value!.revision >= value.revision) {
          throw const DiaryMetadataConflict();
        }
        final suffix = nonce();
        if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(suffix)) {
          throw const FormatException('Invalid nonce');
        }
        final temporary = File('${target.path}.$suffix.tmp');
        if (await temporary.exists()) throw const DiaryMetadataConflict();
        await backend.write(temporary, encoded);
        // Recheck all history before commit; never replace an existing target.
        final latest = await _read(value.key);
        if (latest.blocked ||
            latest.value?.revision != history.value?.revision) {
          throw const DiaryMetadataConflict();
        }
        await backend.commit(temporary, target);
        if (await backend.read(target) != encoded) {
          throw const FileSystemException('Metadata commit unverified');
        }
      } finally {
        try {
          await writer.unlock(0, 1);
        } finally {
          await writer.close();
        }
      }
    });
    _queue = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
