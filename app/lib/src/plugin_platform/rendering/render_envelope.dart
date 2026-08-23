import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Immutable host context supplied to one compiled plugin renderer.
@immutable
final class RenderEnvelope {
  /// Creates a renderer request without exposing host implementation objects.
  RenderEnvelope({
    required this.contributionId,
    required this.contractId,
    required this.schemaVersion,
    Map<String, String> routeParameters = const {},
  }) : routeParameters = UnmodifiableMapView(
         Map<String, String>.of(routeParameters),
       );

  /// Canonical contribution identifier that owns this rendering request.
  final String contributionId;

  /// Canonical bundled renderer contract identifier.
  final String contractId;

  /// Renderer payload schema version expected by the contribution.
  final int schemaVersion;

  /// Host-parsed route parameters; renderers cannot access the router itself.
  final Map<String, String> routeParameters;

  @override
  bool operator ==(Object other) {
    return other is RenderEnvelope &&
        contributionId == other.contributionId &&
        contractId == other.contractId &&
        schemaVersion == other.schemaVersion &&
        mapEquals(routeParameters, other.routeParameters);
  }

  @override
  int get hashCode => Object.hash(
    contributionId,
    contractId,
    schemaVersion,
    Object.hashAll(
      (routeParameters.keys.toList()..sort()).map(
        (key) => Object.hash(key, routeParameters[key]),
      ),
    ),
  );
}
