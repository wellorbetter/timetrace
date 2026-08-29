import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_schedule.dart';

class RecapScheduleStore {
  const RecapScheduleStore();

  File get _file => File(PlatformPaths.child('recap_schedule.json'));

  Future<RecapScheduleSettings> load() async {
    try {
      if (!await _file.exists()) return const RecapScheduleSettings();
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return const RecapScheduleSettings();
      return RecapScheduleSettings.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return const RecapScheduleSettings();
    }
  }

  Future<void> save(RecapScheduleSettings settings) async {
    PlatformPaths.ensureDirectory();
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    if (await _file.exists()) await _file.delete();
    await temp.rename(_file.path);
  }
}
