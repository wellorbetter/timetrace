import 'dart:io';

import 'package:flutter/foundation.dart';

/// Writes logs + captures unhandled errors to %APPDATA%\TimeTrace\app.log.
class AppLogger {
  static File? _file;

  static void init() {
    final dir = Platform.environment['APPDATA'] ?? '.';
    final logDir = Directory('$dir\\TimeTrace');
    logDir.createSync(recursive: true);
    _file = File('${logDir.path}\\app.log');

    // Capture Flutter framework errors
    FlutterError.onError = (details) {
      log('FLUTTER ERROR: ${details.exception}');
      log('  at ${details.stack}');
      // Keep default behavior
      FlutterError.presentError(details);
    };

    // Capture platform/async errors
    PlatformDispatcher.instance.onError = (error, stack) {
      log('PLATFORM ERROR: $error');
      log('  $stack');
      return true;
    };

    log('--- app started ---');
  }

  static void log(String message) {
    final f = _file;
    if (f == null) return;
    try {
      final line = '[${DateTime.now().toIso8601String()}] $message\n';
      f.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never crash the app
    }
  }
}
