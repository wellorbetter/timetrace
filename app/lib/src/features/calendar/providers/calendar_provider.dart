import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Day detail for the calendar view (stats + timeline + diary).
final calendarDayProvider =
    FutureProvider.autoDispose.family<DayDetailDto, DateTime>((ref, date) async {
  final api = ref.read(apiProvider);
  final d =
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  try {
    return api.getDayDetail(date: d);
  } catch (e) {
    AppLogger.log('getDayDetail failed: $e');
    rethrow;
  }
});

/// Save diary for a date and invalidate so the day view reloads.
Future<void> saveDiary(WidgetRef ref, DateTime date, String content) async {
  final api = ref.read(apiProvider);
  final d =
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  try {
    api.setDiary(date: d, content: content);
    ref.invalidate(calendarDayProvider(date));
    AppLogger.log('diary saved: $d');
  } catch (e) {
    AppLogger.log('diary save failed: $e');
    rethrow;
  }
}
