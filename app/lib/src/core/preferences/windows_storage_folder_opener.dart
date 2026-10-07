import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

import 'local_storage_folder_action.dart';

// These shell flags are documented by Microsoft but absent in win32 5.15.0.
// https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shellexecuteinfow
const windowsFolderNoAsync = 0x00000100;
const windowsFolderNoUi = 0x00000400;
const windowsFolderInvalidAttributes = 0xffffffff;

typedef WindowsFolderWorker = Future<FolderActionResult> Function(String directory);

class WindowsStorageFolderOpener implements FolderAction {
  const WindowsStorageFolderOpener({this.worker, this.isWindows});
  final WindowsFolderWorker? worker;
  final bool? isWindows;

  @override
  Future<FolderActionResult> open(String directory) async {
    if (!isAbsoluteStorageFolder(directory)) {
      return const FolderActionResult(
        FolderActionStatus.requestFailed,
        stage: FolderActionStage.validation,
      );
    }
    if (!(isWindows ?? Platform.isWindows)) {
      return const FolderActionResult(
        FolderActionStatus.unsupported,
        stage: FolderActionStage.validation,
      );
    }
    try {
      return await (worker ?? _runWindowsFolderWorker)(directory);
    } catch (_) {
      return const FolderActionResult(
        FolderActionStatus.requestFailed,
        stage: FolderActionStage.worker,
      );
    }
  }
}

// Only the immutable directory string crosses the isolate boundary. Native
// objects are constructed inside the worker, and its native section has no await.
Future<FolderActionResult> _runWindowsFolderWorker(String directory) =>
    Isolate.run(() => requestWindowsStorageFolder(
      directory,
      api: const _Win32FolderApi(),
      memory: const _Win32FolderMemory(),
    ));

/// Opaque allocations let strict fakes use Dart tokens without any DLL/heap IO.
abstract interface class WindowsFolderMemory {
  Object utf16(String value);
  Object shellInfo();
  void configure(Object info, WindowsFolderShellRequest request);
  void free(Object allocation);
}

class WindowsFolderShellRequest {
  const WindowsFolderShellRequest({required this.file, required this.verb});
  final Object file, verb;
  int get cbSize => sizeOf<win32.SHELLEXECUTEINFO>();
  int get fMask => windowsFolderNoUi | windowsFolderNoAsync;
  int get hwnd => 0;
  Object? get parameters => null;
  Object? get workingDirectory => null;
  int get nShow => win32.SW_SHOWNORMAL;
}

abstract interface class WindowsFolderApi {
  int attributes(Object path);
  int createFile(Object path, int access, int share, int disposition, int flags);
  int closeHandle(int handle);
  int initializeCom(int flags);
  void uninitializeCom();
  int shellExecute(Object info);
  int lastError();
}

FolderActionResult _nativeFailure(int code, FolderActionStage stage) =>
    FolderActionResult(
      switch (code) {
        2 || 3 => FolderActionStatus.missing,
        5 => FolderActionStatus.inaccessible,
        _ => stage == FolderActionStage.probe
            ? FolderActionStatus.inaccessible
            : FolderActionStatus.requestFailed,
      },
      stage: stage,
      nativeCode: code,
    );

/// Synchronous probe, COM and ShellExecuteEx lifecycle on one worker thread.
/// Does not enumerate, read, create, delete or fall back to another directory.
FolderActionResult requestWindowsStorageFolder(
  String directory, {
  required WindowsFolderApi api,
  required WindowsFolderMemory memory,
}) {
  if (!isAbsoluteStorageFolder(directory)) {
    return const FolderActionResult(
      FolderActionStatus.requestFailed,
      stage: FolderActionStage.validation,
    );
  }
  Object? path, verb, info;
  int? handle;
  var initialized = false;
  var stage = FolderActionStage.allocation;
  FolderActionResult? result;
  var cleanupFailed = false;
  int? cleanupCode;

  FolderActionResult execute() {
    path = memory.utf16(directory);
    stage = FolderActionStage.probe;
    final attributes = api.attributes(path!);
    if (attributes == windowsFolderInvalidAttributes || attributes == -1) {
      final code = api.lastError(); // Save before any release or other API call.
      return _nativeFailure(code, stage);
    }
    if ((attributes & win32.FILE_ATTRIBUTE_DIRECTORY) == 0) {
      return const FolderActionResult(
        FolderActionStatus.inaccessible,
        stage: FolderActionStage.probe,
      );
    }
    final opened = api.createFile(
      path!,
      win32.FILE_LIST_DIRECTORY,
      win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
      win32.OPEN_EXISTING,
      win32.FILE_FLAG_BACKUP_SEMANTICS,
    );
    if (opened == win32.INVALID_HANDLE_VALUE || opened == 0) {
      final code = api.lastError();
      return _nativeFailure(code, stage);
    }
    handle = opened;
    stage = FolderActionStage.com;
    final com = api.initializeCom(
      win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE,
    );
    if (com != win32.S_OK && com != win32.S_FALSE) {
      return FolderActionResult(
        FolderActionStatus.requestFailed,
        stage: stage,
        nativeCode: com,
      );
    }
    initialized = true;
    stage = FolderActionStage.allocation;
    verb = memory.utf16('open');
    info = memory.shellInfo();
    memory.configure(info!, WindowsFolderShellRequest(file: path!, verb: verb!));
    stage = FolderActionStage.request;
    final accepted = api.shellExecute(info!);
    if (accepted == 0) {
      final code = api.lastError();
      return _nativeFailure(code, stage);
    }
    return const FolderActionResult(
      FolderActionStatus.accepted,
      stage: FolderActionStage.request,
    );
  }

  void release(void Function() action) {
    try {
      action();
    } catch (_) {
      cleanupFailed = true;
    }
  }

  try {
    result = execute();
  } catch (_) {
    result = FolderActionResult(
      stage == FolderActionStage.probe
          ? FolderActionStatus.inaccessible
          : FolderActionStatus.requestFailed,
      stage: stage,
    );
  } finally {
    // Each acquired resource gets an independent release attempt. A cleanup
    // error must not mask the original request/probe/COM failure and its code.
    if (handle != null) {
      release(() {
        if (api.closeHandle(handle!) == 0) {
          final code = api.lastError();
          cleanupCode = code;
          cleanupFailed = true;
        }
      });
    }
    if (initialized) release(api.uninitializeCom);
    if (info != null) release(() => memory.free(info!));
    if (verb != null) release(() => memory.free(verb!));
    if (path != null) release(() => memory.free(path!));
  }
  final outcome = result;
  if (!cleanupFailed) return outcome;
  return FolderActionResult(
    outcome.status == FolderActionStatus.accepted
        ? FolderActionStatus.requestFailed
        : outcome.status,
    stage: outcome.status == FolderActionStatus.accepted
        ? FolderActionStage.cleanup
        : outcome.stage,
    nativeCode: outcome.status == FolderActionStatus.accepted
        ? cleanupCode
        : outcome.nativeCode,
    cleanupFailed: true,
  );
}

class _Win32FolderMemory implements WindowsFolderMemory {
  const _Win32FolderMemory();
  @override
  Object utf16(String value) => value.toNativeUtf16(allocator: calloc);
  @override
  Object shellInfo() => calloc<win32.SHELLEXECUTEINFO>();
  @override
  void configure(Object info, WindowsFolderShellRequest request) {
    final fields = (info as Pointer<win32.SHELLEXECUTEINFO>).ref;
    fields
      ..cbSize = request.cbSize
      ..fMask = request.fMask
      ..hwnd = request.hwnd
      ..lpVerb = request.verb as Pointer<Utf16>
      ..lpFile = request.file as Pointer<Utf16>
      ..lpParameters = nullptr
      ..lpDirectory = nullptr
      ..nShow = request.nShow;
  }
  @override
  void free(Object allocation) => calloc.free(allocation as Pointer);
}

class _Win32FolderApi implements WindowsFolderApi {
  const _Win32FolderApi();
  @override
  int attributes(Object path) => win32.GetFileAttributes(path as Pointer<Utf16>);
  @override
  int createFile(Object path, int access, int share, int disposition, int flags) =>
      win32.CreateFile(path as Pointer<Utf16>, access, share, nullptr,
          disposition, flags, 0);
  @override
  int closeHandle(int handle) => win32.CloseHandle(handle);
  @override
  int initializeCom(int flags) => win32.CoInitializeEx(nullptr, flags);
  @override
  void uninitializeCom() => win32.CoUninitialize();
  @override
  int shellExecute(Object info) =>
      win32.ShellExecuteEx(info as Pointer<win32.SHELLEXECUTEINFO>);
  @override
  int lastError() => win32.GetLastError();
}
