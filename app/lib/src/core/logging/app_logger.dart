import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:timetrace_app/src/core/platform_paths.dart';

/// Writes desktop logs to the platform-native TimeTrace data directory.
class AppLogger {
  static File? _file;

  static void init() {
    PlatformPaths.ensureDirectory();
    _file = File(PlatformPaths.appLog);

    // Capture Flutter framework errors.
    FlutterError.onError = (details) {
      log('FLUTTER ERROR: ${details.exception}');
      log('  at ${details.stack}');
      FlutterError.presentError(details);
    };

    // Capture platform/async errors.
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
      // Logging must never crash the app.
    }
  }
}
