/// Returns a presentation-safe application label or a neutral fallback.
///
/// Executable paths and control characters must never cross into ordinary UI
/// or desktop notifications. Callers should still avoid passing window titles
/// or document names; this function is the final defensive boundary for values
/// that are expected to already be display names.
/// Legacy neutral-at-the-domain-boundary fallback.
///
/// Presentation code should replace this with the current locale's fallback
/// through `ReminderL10n.applicationName` before rendering it.
const defaultSafeDisplayLabelFallback = '未命名应用';

String safeDisplayLabel(
  String value, {
  String fallback = defaultSafeDisplayLabelFallback,
}) {
  final trimmed = value.trim();
  if (value.runes.any(_isControlCharacter) ||
      trimmed.isEmpty ||
      trimmed.contains('/') ||
      trimmed.contains('\\') ||
      _windowsDrivePrefix.hasMatch(trimmed)) {
    return fallback;
  }
  return trimmed;
}

final RegExp _windowsDrivePrefix = RegExp(r'^[A-Za-z]:');

bool _isControlCharacter(int rune) {
  return rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);
}
