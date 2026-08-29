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

    // Match Rust `dirs::config_dir()` on Linux so the UI log/preferences,
    // diary assets, and the Rust-owned database all live under one TimeTrace
    // root instead of splitting state across ~/.config and ~/.local/share.
    final home = Platform.environment['HOME'] ?? '.';
    final root = Platform.environment['XDG_CONFIG_HOME'] ?? '$home/.config';
    return '$root/TimeTrace';
  }

  static String child(String name) =>
      '$appSupportDirectory${Platform.pathSeparator}$name';

  static String get database => child('time.db');
  static String get appLog => child('app.log');
  static String get uiPreferences => child('ui_config.json');
  static String get csvExport => child('export.csv');
  static String get diaryImagesDirectory => child('diary_images');

  static String diaryImage(String fileName) =>
      '$diaryImagesDirectory${Platform.pathSeparator}$fileName';

  static void ensureDirectory() {
    Directory(appSupportDirectory).createSync(recursive: true);
  }

  static void ensureDiaryImagesDirectory() {
    ensureDirectory();
    Directory(diaryImagesDirectory).createSync(recursive: true);
  }
}
