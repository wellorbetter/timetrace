import 'package:flutter/material.dart';

import 'plugin_ui_actions.dart';
import 'render_envelope.dart';
import 'render_lease.dart';

/// Compiled renderer builder with no access to host implementation objects.
typedef PluginRendererBuilder =
    Widget Function(
      BuildContext context,
      RenderEnvelope envelope,
      PluginUiActions? actions,
    );

/// Creates optional host-owned resources for one renderer instance.
typedef RenderLeaseFactory =
    RenderLease Function(RenderEnvelope envelope, PluginUiActions? actions);

/// Stable failure categories rendered without exception or contract details.
enum RendererFailure {
  /// No compiled renderer is registered for the requested contract.
  unknownContract,

  /// The contribution and compiled renderer use different schema versions.
  schemaMismatch,

  /// Renderer or lease construction threw an exception.
  renderFailed,
}

/// Safe, host-owned placeholder for an unavailable plugin renderer.
final class PluginRendererErrorPlaceholder extends StatelessWidget {
  /// Creates a non-sensitive renderer failure placeholder.
  const PluginRendererErrorPlaceholder({required this.failure, super.key});

  /// Stable failure category used for testing and diagnostics mapping.
  final RendererFailure failure;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Plugin content unavailable',
      child: DecoratedBox(
        key: ValueKey('plugin-renderer-error-${failure.name}'),
        decoration: BoxDecoration(
          color: colors.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.extension_off_outlined,
                color: colors.onErrorContainer,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Plugin content unavailable',
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lazily constructs one renderer and owns its disposable lease.
///
/// Synchronous renderer and subscription construction failures are converted
/// to a safe local placeholder. Flutter also isolates later descendant build
/// failures to that descendant element, so sibling host surfaces remain alive.
final class RendererErrorBoundary extends StatefulWidget {
  /// Creates a boundary around one already schema-checked registration.
  const RendererErrorBoundary({
    required this.envelope,
    required this.builder,
    this.actions,
    this.createLease,
    super.key,
  });

  /// Immutable contribution render request.
  final RenderEnvelope envelope;

  /// Compiled renderer callback.
  final PluginRendererBuilder builder;

  /// Optional narrow command surface.
  final PluginUiActions? actions;

  /// Optional host-owned subscription factory.
  final RenderLeaseFactory? createLease;

  @override
  State<RendererErrorBoundary> createState() => _RendererErrorBoundaryState();
}

final class _RendererErrorBoundaryState extends State<RendererErrorBoundary> {
  RenderLease? _lease;
  bool _leaseInitialized = false;
  bool _renderFailed = false;

  @override
  void didUpdateWidget(RendererErrorBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.envelope != widget.envelope ||
        oldWidget.builder != widget.builder ||
        oldWidget.createLease != widget.createLease ||
        !identical(oldWidget.actions, widget.actions)) {
      _release();
      _leaseInitialized = false;
      _renderFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_renderFailed) {
      return const PluginRendererErrorPlaceholder(
        failure: RendererFailure.renderFailed,
      );
    }
    if (!_leaseInitialized) {
      _leaseInitialized = true;
      try {
        _lease = widget.createLease?.call(widget.envelope, widget.actions);
      } catch (_) {
        _renderFailed = true;
        return const PluginRendererErrorPlaceholder(
          failure: RendererFailure.renderFailed,
        );
      }
    }
    try {
      return widget.builder(context, widget.envelope, widget.actions);
    } catch (_) {
      _renderFailed = true;
      _release();
      return const PluginRendererErrorPlaceholder(
        failure: RendererFailure.renderFailed,
      );
    }
  }

  void _release() {
    final lease = _lease;
    _lease = null;
    lease?.dispose();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }
}
