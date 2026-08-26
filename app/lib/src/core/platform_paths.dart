import 'dart:io';

/// Platform-native storage paths shared by the desktop UI.
class PlatformPaths {
  const PlatformPaths._();

  static String get appSupportDirectory {
    if (Platform.isWindows) {
      final root = Platform.environment['APPDATA'] ?? '.';
      return '$root${Platform.pathSeparator}TimeTrace';
    }
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '.';
      return '$home/Library/Application Support/TimeTrace';
    }
    final home = Platform.environment['HOME'] ?? '.';
    final root = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
    return '$root/TimeTrace';
  }

  static String child(String name) =>
      '$appSupportDirectory${Platform.pathSeparator}$name';

  static String get database => child('time.db');
  static String get appLog => child('app.log');
  static String get uiPreferences => child('ui_config.json');
  static String get csvExport => child('export.csv');

  static void ensureDirectory() {
    Directory(appSupportDirectory).createSync(recursive: true);
  }
}
