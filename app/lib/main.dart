import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformPaths.ensureDirectory();
  AppLogger.init();
  AppLogger.log('initializing Rust bridge');

  final libraryPath = _bridgeLibraryPath();
  await frb.RustLib.init(
    externalLibrary: ExternalLibrary.open(libraryPath),
  );

  try {
    initializeApi(dbPath: PlatformPaths.database);
    AppLogger.log('TimeTraceApi initialized');
  } catch (e, st) {
    AppLogger.log('API init FAILED: $e\n$st');
  }

  runApp(const ProviderScope(child: TimetraceApp()));
}

String _bridgeLibraryPath() {
  if (Platform.isWindows) return 'timetrace_bridge.dll';
  if (Platform.isMacOS) {
    final executable = File(Platform.resolvedExecutable);
    final bundled = File(
      '${executable.parent.parent.path}/Frameworks/libtimetrace_bridge.dylib',
    );
    if (bundled.existsSync()) return bundled.path;

    // Developer fallback: scripts/build_macos.sh bundles the dylib for release,
    // while local flutter run can use a previously built Rust debug artifact.
    final cwdFallback = File('../target/debug/libtimetrace_bridge.dylib');
    if (cwdFallback.existsSync()) return cwdFallback.absolute.path;
    return 'libtimetrace_bridge.dylib';
  }
  return 'libtimetrace_bridge.so';
}
