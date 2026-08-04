import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Shared calendar data (images / diary days / usage heatmap / entries),
/// loaded once per year for the calendar grid, diary image grid and
/// entries feed. Consumed by both the 日历日记 tab and the overview
/// carousel page.
class CalendarData {
  const CalendarData({
    required this.images,
    required this.entryImages,
    required this.diaryDays,
    required this.usage,
    required this.maxUsage,
    required this.entries,
  });

  final Map<String, List<String>> images; // date -> image paths (markers)
  final Map<int, List<String>> entryImages; // entry_id -> image paths (album)
  final Set<String> diaryDays; // dates with non-empty journal
  final Map<String, int> usage; // date -> active seconds (heatmap)
  final int maxUsage;
  final List<DiaryEntryDto> entries; // published entries, newest first
}

String calFmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final calendarDataProvider =
    FutureProvider.autoDispose<CalendarData>((ref) async {
  final api = ref.read(apiProvider);
  final now = DateTime.now();

  // Image paths for the whole year + per-entry album map
  final detailedImgs = api.getDiaryImagesDetailed(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  final images = <String, List<String>>{};
  final entryImages = <int, List<String>>{};
  for (final (date, entryId, path) in detailedImgs) {
    images.putIfAbsent(date, () => []).add(path);
    if (entryId != null) {
      entryImages.putIfAbsent(entryId, () => []).add(path);
    }
  }

  // Diary days (markers) + entries feed with ids
  final diaryEntries = api.getDiaryEntries(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  final diaryDays = diaryEntries
      .where((e) => e.$2.isNotEmpty)
      .map((e) => e.$1)
      .toSet();
  final detailed = api.getDiaryEntriesDetailed(
    start: calFmt(DateTime(now.year, 1, 1)),
    end: calFmt(DateTime(now.year, 12, 31)),
  );
  // Only published entries in the feed; drafts stay in the editor.
  final published = detailed.where((e) => e.status == 'published').toList();
  // Cap to the most recent 100 (memory: avoid holding long texts)
  final capped = published.length > 100
      ? published.sublist(0, 100)
      : published;

  // Per-day active seconds (heatmap) — one CSV query, parsed locally
  final usage = <String, int>{};
  try {
    final csv = api.exportCsv(
      start: calFmt(DateTime(now.year, 1, 1)),
      end: calFmt(DateTime(now.year, 12, 31)),
    );
    final re = RegExp(r',(\d{4}-\d{2}-\d{2}),(\d+),(\d+)');
    for (final m in re.allMatches(csv)) {
      final date = m.group(1)!;
      final active = int.tryParse(m.group(2)!) ?? 0;
      usage[date] = (usage[date] ?? 0) + active;
    }
  } catch (e) {
    AppLogger.log('load daily usage failed: $e');
  }
  final maxUsage = usage.values.fold<int>(0, (m, v) => v > m ? v : m);

  return CalendarData(
    images: images,
    entryImages: entryImages,
    diaryDays: diaryDays,
    usage: usage,
    maxUsage: maxUsage,
    entries: capped,
  );
});


/// The selected day's draft content (autosaved, not yet published).
final diaryDraftProvider = FutureProvider.autoDispose.family<String?, String>(
    (ref, date) async {
  final api = ref.read(apiProvider);
  return api.getDiaryDraft(date: date);
});
