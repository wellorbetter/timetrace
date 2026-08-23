import 'private_flight_models.dart';

/// Compute the elapsed seconds for a flight session.
///
/// If the session has an [endedAt], uses that as the end time; otherwise
/// uses the current time (for active sessions).
int elapsedSeconds(PrivateFlightSession session) {
  final start = DateTime.tryParse(session.startedAt);
  if (start == null) return 0;
  final end = session.endedAt != null
      ? DateTime.tryParse(session.endedAt!)
      : null;
  final now = end ?? DateTime.now();
  return now.difference(start).inSeconds;
}

/// Format an ISO timestamp as a local "HH:mm" string.
///
/// Returns the original string if parsing fails.
String formatTime(String iso) {
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  final local = dt.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
