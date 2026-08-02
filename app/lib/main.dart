import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await frb.RustLib.init(
    externalLibrary: ExternalLibrary.open('timetrace_bridge.dll'),
  );
  final dbDir = '${Platform.environment['APPDATA'] ?? '.'}\\TimeTrace';
  initializeApi(dbPath: '$dbDir\\time.db');
  runApp(const ProviderScope(child: TimetraceApp()));
}
