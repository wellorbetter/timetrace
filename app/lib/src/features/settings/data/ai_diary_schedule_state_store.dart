import 'dart:convert';
import 'dart:io';

import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/features/settings/application/ai_diary_daily_scheduler.dart';

class FileAiDiaryScheduleStateStore implements AiDiaryScheduleStateStore {
  const FileAiDiaryScheduleStateStore();

  String get path => PlatformPaths.child('ai_diary_schedule.json');

  @override
  Future<DateTime?> readLastCompletedLocalDate() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final raw = decoded['last_completed_local_date'];
      if (raw is! String) return null;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) return null;
      return DateTime(parsed.year, parsed.month, parsed.day);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeLastCompletedLocalDate(DateTime localDate) async {
    PlatformPaths.ensureDirectory();
    final file = File(path);
    final temp = File('$path.tmp');
    final normalized = DateTime(localDate.year, localDate.month, localDate.day);
    await temp.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'last_completed_local_date': _date(normalized)}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temp.rename(path);
  }
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
