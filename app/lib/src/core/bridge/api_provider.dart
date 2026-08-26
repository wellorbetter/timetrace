import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/desktop_bridge.dart';

TimeTraceApi? _api;

/// Initialize the shared Rust API before `runApp`.
///
/// Native library loading and platform paths stay inside the bridge layer so
/// feature code never needs to know about DLL/dylib locations or FFI order.
Future<void> initializeApi() async {
  if (_api != null) return;
  _api = await DesktopBridge.initialize();
}

/// Provides the shared Rust API instance to the widget tree.
final apiProvider = Provider<TimeTraceApi>((ref) {
  final api = _api;
  if (api == null) {
    throw StateError('TimeTraceApi not initialized — call initializeApi() first');
  }
  return api;
});
