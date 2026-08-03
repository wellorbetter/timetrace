/// Compact duration formatting with granular units:
/// 1h30min / 45min20s / 12s — readable at a glance in small cards.
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  if (h > 0) return m > 0 ? '${h}h${m}min' : '${h}h';
  if (m > 0) return s > 0 ? '${m}min${s}s' : '${m}min';
  return '${s}s';
}
