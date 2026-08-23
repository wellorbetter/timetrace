import 'dart:collection';

import 'package:flutter/widgets.dart';

import 'plugin_ui_actions.dart';
import 'render_envelope.dart';
import 'renderer_error_boundary.dart';

/// One compile-time renderer registration keyed by canonical contract id.
final class PluginRendererRegistration {
  /// Creates a typed compiled renderer registration.
  const PluginRendererRegistration({
    required this.contractId,
    required this.schemaVersion,
    required this.builder,
    this.createLease,
  });

  /// Canonical renderer contract id, never a plugin id.
  final String contractId;

  /// Exact schema version accepted by this renderer.
  final int schemaVersion;

  /// Lazily invoked compiled widget builder.
  final PluginRendererBuilder builder;

  /// Optional factory for host-owned renderer resources.
  final RenderLeaseFactory? createLease;
}

/// Invalid or duplicate compile-time renderer registration.
final class PluginRendererRegistrationException implements Exception {
  /// Creates a stable registration failure.
  const PluginRendererRegistrationException(this.code);

  /// Stable non-sensitive failure code.
  final String code;

  @override
  String toString() => 'PluginRendererRegistrationException: $code';
}

/// Immutable registry of host-compiled plugin renderers.
final class PluginRendererRegistry {
  /// Builds and validates a fixed renderer registry.
  factory PluginRendererRegistry(
    Iterable<PluginRendererRegistration> registrations,
  ) {
    final indexed = <String, PluginRendererRegistration>{};
    for (final registration in registrations) {
      if (!_validContractId.hasMatch(registration.contractId)) {
        throw const PluginRendererRegistrationException('invalid_contract_id');
      }
      if (registration.schemaVersion <= 0) {
        throw const PluginRendererRegistrationException(
          'invalid_schema_version',
        );
      }
      if (indexed.containsKey(registration.contractId)) {
        throw const PluginRendererRegistrationException(
          'duplicate_contract_id',
        );
      }
      indexed[registration.contractId] = registration;
    }
    return PluginRendererRegistry._(UnmodifiableMapView(indexed));
  }

  const PluginRendererRegistry._(this._registrations);

  static final RegExp _validContractId = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );

  final Map<String, PluginRendererRegistration> _registrations;

  /// Whether this host contains the exact renderer contract and schema.
  bool supports(String contractId, int schemaVersion) {
    return _registrations[contractId]?.schemaVersion == schemaVersion;
  }

  /// Returns a lazy renderer boundary or a safe host-owned placeholder.
  Widget render(RenderEnvelope envelope, {PluginUiActions? actions}) {
    final registration = _registrations[envelope.contractId];
    if (registration == null) {
      return const PluginRendererErrorPlaceholder(
        failure: RendererFailure.unknownContract,
      );
    }
    if (registration.schemaVersion != envelope.schemaVersion) {
      return const PluginRendererErrorPlaceholder(
        failure: RendererFailure.schemaMismatch,
      );
    }
    return RendererErrorBoundary(
      envelope: envelope,
      actions: actions,
      builder: registration.builder,
      createLease: registration.createLease,
    );
  }
}
