import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  AppLogger.log('initializing Rust bridge');
  await frb.RustLib.init(
    externalLibrary: ExternalLibrary.open('timetrace_bridge.dll'),
  );
  final dbDir = '${Platform.environment['APPDATA'] ?? '.'}\\TimeTrace';
  try {
    initializeApi(dbPath: '$dbDir\\time.db');
    AppLogger.log('TimeTraceApi initialized');
  } catch (e, st) {
    AppLogger.log('API init FAILED: $e\n$st');
  }
  runApp(const ProviderScope(child: TimetraceApp()));
}
