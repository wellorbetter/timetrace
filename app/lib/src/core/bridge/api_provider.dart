import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';

TimeTraceApi? _api;

/// Initialize the shared [TimeTraceApi] before runApp.
TimeTraceApi initializeApi({required String dbPath}) {
  final api = TimeTraceApi.create(dbPath: dbPath);
  _api = api;
  return api;
}

/// Provides the shared Rust API instance to the widget tree.
final apiProvider = Provider<TimeTraceApi>((ref) {
  final api = _api;
  if (api == null) {
    throw StateError(
      'TimeTraceApi not initialized — call initializeApi() in main()',
    );
  }
  return api;
});
