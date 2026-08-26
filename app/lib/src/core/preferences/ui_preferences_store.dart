import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';

/// Small versioned JSON store for desktop UI preferences.
class UiPreferencesStore {
  static const _version = 1;

  static File get _file => File(PlatformPaths.uiPreferences);

  static Map<String, dynamic> read() {
    try {
      final file = _file;
      if (!file.existsSync()) return <String, dynamic>{};
      return decode(file.readAsStringSync());
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Map<String, dynamic> decode(String source) {
    try {
      final raw = jsonDecode(source);
      if (raw is! Map) return <String, dynamic>{};
      return Map<String, dynamic>.from(raw);
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static void update(Map<String, dynamic> values) {
    try {
      final current = read();
      current['version'] = _version;
      current.addAll(values);
      PlatformPaths.ensureDirectory();
      _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(current));
    } catch (_) {
      // Preferences are non-critical; the app continues with in-memory state.
    }
  }
}
