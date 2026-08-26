import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/app.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/bridge/bootstrap_failure_app.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();

  try {
    AppLogger.log('initializing desktop bridge');
    await initializeApi();
    AppLogger.log('TimeTraceApi initialized');
  } catch (error, stack) {
    AppLogger.log('desktop bridge initialization FAILED: $error\n$stack');
    runApp(BootstrapFailureApp(message: error.toString()));
    return;
  }

  runApp(const ProviderScope(child: TimetraceApp()));
}
