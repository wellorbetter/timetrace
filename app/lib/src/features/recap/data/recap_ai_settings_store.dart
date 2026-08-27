import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';

class RecapAiSettingsStore {
  const RecapAiSettingsStore();

  String get path => PlatformPaths.child('recap_ai.json');

  Future<RecapAiSettings> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) return const RecapAiSettings();
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return const RecapAiSettings();
      return RecapAiSettings.fromJson(raw);
    } catch (_) {
      return const RecapAiSettings();
    }
  }

  Future<void> save(RecapAiSettings settings) async {
    PlatformPaths.ensureDirectory();
    final file = File(path);
    final temp = File('$path.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(path);
  }
}
