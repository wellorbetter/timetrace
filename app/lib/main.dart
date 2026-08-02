import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;
import 'package:timetrace_app/src/bridge/api_holder.dart';
import 'package:timetrace_app/src/screens/home_screen.dart';
import 'package:timetrace_app/src/theme/timetrace_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the Flutter Rust Bridge
  await frb.RustLib.init(
    externalLibrary: ExternalLibrary.open('timetrace_bridge.dll'),
  );
  // Create the API with a default DB path (sync via FRB)
  final dbDir = '${Platform.environment['APPDATA'] ?? '.'}\\TimeTrace';
  Api.init(dbPath: '$dbDir\\time.db');
  runApp(const TimetraceApp());
}

class TimetraceApp extends StatelessWidget {
  const TimetraceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TimeTrace',
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(),
      darkTheme: TimetraceTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
