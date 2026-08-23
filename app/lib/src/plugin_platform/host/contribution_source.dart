import 'contribution_models.dart';

/// Stable privacy-safe contribution transport failure.
final class ContributionSourceException implements Exception {
  /// Creates a source failure with a non-sensitive stable code.
  const ContributionSourceException(this.code);

  /// Stable failure code suitable for host diagnostics.
  final String code;

  @override
  String toString() => 'ContributionSourceException: $code';
}

/// Narrow transport-independent source of complete host publications.
abstract interface class ContributionSource {
  /// Loads the latest complete canonical contribution snapshot.
  Future<ContributionSnapshot> load();

  /// Changes one desired enable state and returns a complete host publication.
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled);
}
