import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';

class NowlinePreferencesStore {
  const NowlinePreferencesStore();

  String get path => PlatformPaths.child('nowline.json');

  Future<NowlinePreferences> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) return const NowlinePreferences();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const NowlinePreferences();
      return NowlinePreferences.fromJson(decoded);
    } catch (_) {
      return const NowlinePreferences();
    }
  }

  Future<void> save(NowlinePreferences preferences) async {
    PlatformPaths.ensureDirectory();
    final file = File(path);
    final temporary = File('$path.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(preferences.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(path);
  }
}
