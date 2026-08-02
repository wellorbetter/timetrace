import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';

TimeTraceApi? _api;

/// Initialize the shared [TimeTraceApi] before runApp.
void initializeApi({required String dbPath}) {
  _api = TimeTraceApi.create(dbPath: dbPath);
}

/// Provides the shared Rust API instance to the widget tree.
final apiProvider = Provider<TimeTraceApi>((ref) {
  final api = _api;
  if (api == null) {
    throw StateError('TimeTraceApi not initialized — call initializeApi() in main()');
  }
  return api;
});
