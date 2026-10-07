import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

abstract interface class AiKeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// Secrets never go into ordinary UI preferences or the project.
class SecureAiKeyStore implements AiKeyStore {
  const SecureAiKeyStore() : _name = 'TimeTrace/DeepSeek/APIKey';
  const SecureAiKeyStore.testFixture(String suffix)
    : _name = 'TimeTrace/Tests/DeepSeek/$suffix';
  final String _name;
  void _requireWindows() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows credential storage required');
    }
    // Resolve the lazy kernel32 binding before a failing credential call;
    // symbol loading itself can overwrite the thread's last-error value.
    GetLastError();
  }

  @override
  Future<String?> read() async {
    _requireWindows();
    final target = _name.toNativeUtf16();
    final result = calloc<Pointer<CREDENTIAL>>();
    try {
      if (CredRead(target, CRED_TYPE_GENERIC, 0, result) == 0) {
        if (GetLastError() == ERROR_NOT_FOUND) return null;
        throw StateError('Credential read failed');
      }
      final entry = result.value.ref;
      if (entry.CredentialBlobSize == 0) return null;
      if (entry.CredentialBlobSize > 2560) {
        throw StateError('Invalid credential size');
      }
      return utf8.decode(
        entry.CredentialBlob.asTypedList(entry.CredentialBlobSize),
      );
    } finally {
      if (result.value != nullptr) CredFree(result.value);
      calloc.free(result);
      calloc.free(target);
    }
  }

  @override
  Future<void> write(String value) async {
    _requireWindows();
    final bytes = utf8.encode(value);
    if (bytes.isEmpty || bytes.length > 2560) {
      throw ArgumentError('Invalid credential size');
    }
    final target = _name.toNativeUtf16();
    final user = 'TimeTrace'.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.length);
    final entry = calloc<CREDENTIAL>();
    try {
      blob.asTypedList(bytes.length).setAll(0, bytes);
      entry.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = target
        ..UserName = user
        ..CredentialBlobSize = bytes.length
        ..CredentialBlob = blob
        ..Persist = CRED_PERSIST_LOCAL_MACHINE;
      if (CredWrite(entry, 0) == 0) throw StateError('Credential write failed');
    } finally {
      blob.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(entry);
      calloc.free(blob);
      calloc.free(user);
      calloc.free(target);
    }
  }

  @override
  Future<void> clear() async {
    _requireWindows();
    final target = _name.toNativeUtf16();
    try {
      if (CredDelete(target, CRED_TYPE_GENERIC, 0) == 0 &&
          GetLastError() != ERROR_NOT_FOUND) {
        throw StateError('Credential removal failed');
      }
    } finally {
      calloc.free(target);
    }
  }
}
