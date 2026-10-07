enum FolderActionStatus { accepted, missing, inaccessible, requestFailed, unsupported }

enum FolderActionStage { validation, allocation, probe, com, request, cleanup, worker }

/// Acceptance means that the OS accepted a request, not that a window is visible.
class FolderActionResult {
  const FolderActionResult(
    this.status, {
    required this.stage,
    this.nativeCode,
    this.cleanupFailed = false,
  });
  final FolderActionStatus status;
  final FolderActionStage stage;
  final int? nativeCode;
  final bool cleanupFailed;
}

abstract interface class FolderAction {
  Future<FolderActionResult> open(String directory);
}

typedef FolderActionPrimitive = Future<FolderActionResult> Function(String directory);

/// A pure validation leaf. Never resolves environment variables or touches disk.
bool isAbsoluteStorageFolder(String directory) =>
    !directory.contains('\u0000') &&
    (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(directory) ||
        RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+').hasMatch(directory));

/// Injectable primitives for callers that already own the platform boundary.
class LocalStorageFolderAction implements FolderAction {
  const LocalStorageFolderAction({required this.probe, required this.request});
  final FolderActionPrimitive probe;
  final FolderActionPrimitive request;

  @override
  Future<FolderActionResult> open(String directory) async {
    if (!isAbsoluteStorageFolder(directory)) {
      return const FolderActionResult(
        FolderActionStatus.requestFailed,
        stage: FolderActionStage.validation,
      );
    }
    var stage = FolderActionStage.probe;
    try {
      final checked = await probe(directory);
      if (checked.status != FolderActionStatus.accepted) return checked;
      stage = FolderActionStage.request;
      return await request(directory);
    } catch (_) {
      return FolderActionResult(
        stage == FolderActionStage.probe
            ? FolderActionStatus.inaccessible
            : FolderActionStatus.requestFailed,
        stage: stage,
      );
    }
  }
}
