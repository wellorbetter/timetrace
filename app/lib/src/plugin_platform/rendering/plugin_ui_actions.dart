/// Narrow host action surface available to plugin renderers.
///
/// Implementations re-check lifecycle and permissions. A renderer never
/// receives a Riverpod container, router, database, or raw bridge API.
abstract interface class PluginUiActions {
  /// Executes one canonical command contribution through the host.
  Future<void> execute(
    String contributionId, {
    Map<String, Object?> input = const {},
  });

  /// Requests cancellation of a previously returned host operation.
  Future<void> cancel(String operationId);
}
