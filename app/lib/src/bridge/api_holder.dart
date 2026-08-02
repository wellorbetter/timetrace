import 'package:timetrace_app/src/bridge/api.dart';

/// Singleton holder for the shared TimeTraceApi instance.
class Api {
  static TimeTraceApi? _instance;

  static TimeTraceApi get instance {
    final api = _instance;
    if (api == null) {
      throw StateError('TimeTraceApi not initialized. Call Api.init() first.');
    }
    return api;
  }

  static void init({required String dbPath}) {
    _instance = TimeTraceApi.create(dbPath: dbPath);
  }
}
