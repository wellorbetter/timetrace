/// Privacy-conscious presentation model for a persisted timeout rule.
///
/// [applicationKey] is an opaque stable identity used by callbacks. Widgets in
/// this package must never render it; only [displayName] is user-facing.
final class AppTimeoutRuleViewModel {
  const AppTimeoutRuleViewModel({
    required this.id,
    required this.applicationKey,
    required this.displayName,
    required this.thresholdMinutes,
    required this.cooldownMinutes,
    required this.enabled,
    required this.repeatEnabled,
  });

  final int id;
  final String applicationKey;
  final String displayName;
  final int thresholdMinutes;
  final int cooldownMinutes;
  final bool enabled;
  final bool repeatEnabled;
}

/// A running application offered by the rule dialog.
///
/// [safeQualifier] can contain a privacy-safe disambiguator such as an
/// executable filename. Full paths and window titles should not be supplied.
final class RunningApplicationViewModel {
  const RunningApplicationViewModel({
    required this.applicationKey,
    required this.displayName,
    this.safeQualifier,
  });

  final String applicationKey;
  final String displayName;
  final String? safeQualifier;
}

/// Editable values emitted by [AppTimeoutRuleDialog].
final class AppTimeoutRuleDraftViewModel {
  const AppTimeoutRuleDraftViewModel({
    this.id,
    required this.applicationKey,
    required this.displayName,
    required this.thresholdMinutes,
    required this.cooldownMinutes,
    required this.enabled,
    required this.repeatEnabled,
  });

  final int? id;
  final String applicationKey;
  final String displayName;
  final int thresholdMinutes;
  final int cooldownMinutes;
  final bool enabled;
  final bool repeatEnabled;
}
