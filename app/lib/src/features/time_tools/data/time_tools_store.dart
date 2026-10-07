import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

import '../domain/time_tool_state.dart';

class TimeToolsLoad {
  const TimeToolsLoad({this.value, this.blocked = false, this.message});
  final TimeToolsState? value;
  final bool blocked;
  final String? message;
  bool get missing => value == null && !blocked;
}

abstract interface class TimeToolsStore {
  Future<TimeToolsLoad> load();
  Future<void> put(
    TimeToolsState value, {
    TimeToolsState? expectedBase,
    bool checkBase = false,
  });
}

String newTimeToolId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Directory timeToolsDirectory() {
  if (!Platform.isWindows)
    throw UnsupportedError('Windows storage unavailable');
  final base = Platform.environment['LOCALAPPDATA'];
  if (base == null ||
      !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(base) ||
      base.contains('\u0000')) {
    throw const FileSystemException('No absolute local application directory');
  }
  return Directory(
    base +
        Platform.pathSeparator +
        'TimeTrace' +
        Platform.pathSeparator +
        'workspace-time-tools-v1',
  );
}

/// Immutable revision files. Interrupted tmp files and old commits are retained.
class FileTimeToolsStore implements TimeToolsStore {
  FileTimeToolsStore({
    Directory Function()? directory,
    String Function()? nonce,
    Future<void> Function(File temporary, File target)? beforeCommit,
    Future<void> Function(File target)? beforeReadback,
    Future<void> Function(File temporary, File target)? beforePublish,
    Future<void> Function(File temporary, String encoded)? writeTemporary,
  }) : _directory = directory ?? timeToolsDirectory,
       _nonce = nonce ?? newTimeToolId,
       _beforeCommit = beforeCommit,
       _beforeReadback = beforeReadback,
       _beforePublish = beforePublish,
       _writeTemporary = writeTemporary;
  final Directory Function() _directory;
  final String Function() _nonce;
  // Controlled interleaving after flush; production never injects this hook.
  final Future<void> Function(File temporary, File target)? _beforeCommit;
  final Future<void> Function(File target)? _beforeReadback;
  final Future<void> Function(File temporary, File target)? _beforePublish;
  final Future<void> Function(File temporary, String encoded)? _writeTemporary;
  static const writerLockName = 'writer.lock';
  Future<void> _queue = Future.value();
  Future<TimeToolsLoad> _read(Directory dir) async {
    if (!dir.isAbsolute)
      throw const FileSystemException('Absolute directory required');
    if (!await dir.exists()) return const TimeToolsLoad();
    TimeToolsState? best;
    var highest = -1, blocked = false;
    await for (final item in dir.list(followLinks: false)) {
      final name = item.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name == writerLockName && item is File) continue;
      if (name.endsWith('.tmp')) continue;
      if (item is! File) {
        blocked = true;
        continue;
      }
      final match = RegExp(r'^state-r([0-9]+)\.json$').firstMatch(name);
      if (match == null) {
        blocked = true;
        continue;
      }
      final revision = int.tryParse(match.group(1)!);
      if (revision == null) {
        blocked = true;
        continue;
      }
      highest = max(highest, revision);
      try {
        final raw = jsonDecode(await item.readAsString());
        if (raw is! Map) throw const FormatException('Invalid root');
        final value = TimeToolsState.fromJson(Map<String, dynamic>.from(raw));
        if (value.revision != revision)
          throw const FormatException('Revision mismatch');
        if (best == null || value.revision > best.revision) best = value;
      } catch (_) {
        blocked = true;
      }
    }
    if ((highest >= 0 && best == null) ||
        (best != null && highest > best.revision))
      blocked = true;
    return TimeToolsLoad(
      value: best,
      blocked: blocked,
      message: blocked ? '历史存在不可读取的版本，内容已保留；请检查后重试读取' : null,
    );
  }

  @override
  Future<TimeToolsLoad> load() => _read(_directory());
  @override
  Future<void> put(
    TimeToolsState value, {
    TimeToolsState? expectedBase,
    bool checkBase = false,
  }) {
    final operation = _queue.then((_) async {
      final dir = _directory();
      if (!dir.isAbsolute)
        throw const FileSystemException('Absolute directory required');
      await dir.create(recursive: true);
      final lock = await File(
        '${dir.path}${Platform.pathSeparator}$writerLockName',
      ).open(mode: FileMode.append);
      var locked = false;
      try {
        // Stable cross-handle identity; never truncate/remove the lock file.
        // A competing writer fails closed, rather than blocking the UI isolate.
        await lock.lock(FileLock.exclusive, 0, 1);
        locked = true;
        final history = await _read(dir);
        if (history.blocked)
          throw const FileSystemException('History requires recovery');
        final encoded = jsonEncode(value.toJson());
        TimeToolsState.fromJson(
          Map<String, dynamic>.from(jsonDecode(encoded) as Map),
        );
        final target = File(
          dir.path +
              Platform.pathSeparator +
              'state-r' +
              value.revision.toString() +
              '.json',
        );
        if (await target.exists()) {
          if (history.value?.revision == value.revision &&
              await target.readAsString() == encoded)
            return;
          throw const FileSystemException('Revision already occupied');
        }
        if (checkBase &&
            jsonEncode(history.value?.toJson()) !=
                jsonEncode(expectedBase?.toJson()))
          throw const FileSystemException('Time history base conflict');
        if (history.value != null && history.value!.revision >= value.revision)
          throw const FileSystemException('Stale revision');
        await dir.create(recursive: true);
        final nonce = _nonce();
        if (!validTimeToolId(nonce))
          throw const FormatException('Invalid nonce');
        final temporary = File(
          dir.path +
              Platform.pathSeparator +
              'state-r' +
              value.revision.toString() +
              '-' +
              nonce +
              '.tmp',
        );
        // Only this writer may populate its staging name. This is not the
        // revision commit: the flushed file is published by no-replace move.
        await temporary.create(exclusive: true);
        if (_writeTemporary == null) {
          await temporary.writeAsString(encoded, flush: true);
        } else {
          await _writeTemporary(temporary, encoded);
        }
        await _beforeCommit?.call(temporary, target);
        final latest = await _read(dir);
        if (latest.blocked ||
            jsonEncode(latest.value?.toJson()) !=
                jsonEncode(history.value?.toJson()))
          throw const FileSystemException(
            'Time history changed during staging',
          );
        try {
          await _beforePublish?.call(temporary, target);
          _commitNoReplace(temporary, target);
        } on FileSystemException catch (error) {
          // A matching durable snapshot is an idempotent retry/competing ACK,
          // never permission to replace different content.
          if (error.osError?.errorCode == win32.ERROR_FILE_EXISTS ||
              error.osError?.errorCode == win32.ERROR_ALREADY_EXISTS) {
            try {
              if (await target.readAsString() == encoded) return;
            } on FileSystemException {
              // Failure to verify retains the original failure and dirty intent.
            }
          }
          rethrow;
        }
        await _beforeReadback?.call(target);
        if (await target.readAsString() != encoded)
          throw const FileSystemException('Time history commit not verified');
        final verified = await _read(dir);
        if (verified.blocked || jsonEncode(verified.value?.toJson()) != encoded)
          throw const FileSystemException(
            'Time history canonical readback not verified',
          );
      } finally {
        try {
          if (locked) await lock.unlock(0, 1);
        } finally {
          await lock.close();
        }
      }
    });
    _queue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }
}

/// Windows same-directory atomic move, explicitly without REPLACE_EXISTING,
/// COPY_ALLOWED or DELAY_UNTIL_REBOOT. Exists checks are not the safety boundary.
/// Unsupported platforms fail closed instead of falling back to Dart rename.
void _commitNoReplace(File temporary, File target) {
  if (!Platform.isWindows) {
    throw UnsupportedError('Atomic no-replace Windows commit unavailable');
  }
  // Resolve the lazy GetLastError binding before the operation it must inspect.
  win32.GetLastError();
  final from = temporary.path.toNativeUtf16();
  try {
    final to = target.path.toNativeUtf16();
    try {
      final ok = win32.MoveFileEx(from, to, win32.MOVEFILE_WRITE_THROUGH);
      if (ok == 0) {
        final code = win32.GetLastError();
        throw FileSystemException(
          'Atomic revision commit failed',
          target.path,
          OSError('MoveFileExW without replacement failed', code),
        );
      }
    } finally {
      malloc.free(to);
    }
  } finally {
    malloc.free(from);
  }
}
