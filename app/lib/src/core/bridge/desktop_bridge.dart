import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;

/// Owns the platform-specific bootstrap details required to reach the Rust
/// backend. Feature/UI code should depend on [TimeTraceApi] only.
class DesktopBridge {
  const DesktopBridge._();

  static Future<TimeTraceApi> initialize() async {
    await frb.RustLib.init(
      externalLibrary: ExternalLibrary.open(libraryPath()),
    );

    // Empty means "use the platform-native TimeTrace database path". The
    // filesystem policy belongs to Rust core, not to Flutter feature code.
    return TimeTraceApi.create(dbPath: '');
  }

  /// Resolved bridge path shared by generated FRB bindings and small native
  /// read-only ports such as Nowline's live snapshot.
  static String libraryPath() {
    if (Platform.isWindows) return 'timetrace_bridge.dll';

    if (Platform.isMacOS) {
      final executable = File(Platform.resolvedExecutable);
      final bundled = File(
        '${executable.parent.parent.path}/Frameworks/libtimetrace_bridge.dylib',
      );
      if (bundled.existsSync()) return bundled.path;

      // Local `flutter run` fallback after building the Rust bridge manually.
      for (final candidate in [
        File('../target/debug/libtimetrace_bridge.dylib'),
        File('../target/release/libtimetrace_bridge.dylib'),
      ]) {
        if (candidate.existsSync()) return candidate.absolute.path;
      }
      return 'libtimetrace_bridge.dylib';
    }

    return 'libtimetrace_bridge.so';
  }
}
