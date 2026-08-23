/// A resource that can be released by a host-owned renderer lease.
abstract interface class Disposable {
  /// Releases the resource. Implementations should be idempotent.
  void dispose();
}

/// Owns renderer subscriptions and releases them at most once.
final class RenderLease implements Disposable {
  /// Creates a lease over a fixed set of host-approved resources.
  RenderLease(Iterable<Disposable> resources)
    : _resources = List<Disposable>.unmodifiable(resources);

  final List<Disposable> _resources;
  bool _disposed = false;

  /// Whether this lease has already released its resources.
  bool get isDisposed => _disposed;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final resource in _resources.reversed) {
      try {
        resource.dispose();
      } catch (_) {
        // Renderer teardown is best-effort and isolated per resource.
      }
    }
  }
}
