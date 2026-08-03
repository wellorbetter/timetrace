import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/chinese_calendar.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/widgets/image_preview.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Dashboard calendar: compact calendar (left) + day/week/month summary
/// (right) + journal (full-width, below) with image upload.
class CalendarCard extends ConsumerStatefulWidget {
  const CalendarCard({super.key, this.compact = false});

  final bool compact;

  @override
  ConsumerState<CalendarCard> createState() => _CalendarCardState();
}

enum _SummaryRange { day, week, month }

class _CalendarCardState extends ConsumerState<CalendarCard> {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  _SummaryRange _range = _SummaryRange.day;
  Map<String, List<String>> _dayImages = {};
  Set<String> _diaryDays = {};
  Map<String, int> _dayUsage = {}; // date -> active seconds (heatmap)
  int _maxDayUsage = 0;
  List<(String, String)> _diaryEntries = []; // (date, content) newest last

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    try {
      final api = ref.read(apiProvider);
      final now = DateTime.now();
      final entries = api.getDiaryImages(
        start: _fmt(DateTime(now.year, 1, 1)),
        end: _fmt(DateTime(now.year, 12, 31)),
      );
      // Diary dates (days with journal content)
      final diaryEntries = api.getDiaryEntries(
        start: _fmt(DateTime(now.year, 1, 1)),
        end: _fmt(DateTime(now.year, 12, 31)),
      );
      final diaryDays = diaryEntries
          .where((e) => e.$2.isNotEmpty)
          .map((e) => e.$1)
          .toSet();
      final entriesList = diaryEntries
          .where((e) => e.$2.isNotEmpty)
          .toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
      // Per-day active seconds (heatmap intensity) — one CSV query, parsed locally
      final usage = <String, int>{};
      try {
        final csv = api.exportCsv(
          start: _fmt(DateTime(now.year, 1, 1)),
          end: _fmt(DateTime(now.year, 12, 31)),
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
      if (mounted) {
        setState(() {
          _dayImages = {};
          for (final (date, path) in entries) {
            _dayImages.putIfAbsent(date, () => []).add(path);
          }
          _diaryDays = diaryDays;
          _dayUsage = usage;
          _maxDayUsage = maxUsage;
          _diaryEntries = entriesList;
        });
      }
    } catch (e) {
      AppLogger.log('load diary images failed: $e');
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Header ──
        Row(
          children: [
            Icon(Icons.calendar_month, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('日历',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              tooltip: '刷新图片',
              onPressed: _loadImages,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const SizedBox(height: 8),

        // ── Calendar (left) + Summary (right) ──
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: TableCalendar(
                firstDay: DateTime(_focused.year, 1, 1),
                lastDay: DateTime(_focused.year, 12, 31),
                focusedDay: _focused,
                selectedDayPredicate: (d) => isSameDay(d, _selected),
                onDaySelected: (selected, focused) {
                  setState(() {
                    _selected = selected;
                    _focused = focused;
                  });
                },
                calendarFormat: CalendarFormat.month,
                headerStyle: HeaderStyle(
                  titleCentered: true,
                  formatButtonVisible: false,
                  titleTextStyle: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface),
                  leftChevronIcon:
                      Icon(Icons.chevron_left, size: 20, color: scheme.primary),
                  rightChevronIcon:
                      Icon(Icons.chevron_right, size: 20, color: scheme.primary),
                ),
                daysOfWeekHeight: 24,
                rowHeight: 54,
                daysOfWeekStyle: DaysOfWeekStyle(
                  weekdayStyle: TextStyle(fontSize: 11, color: scheme.outline),
                  weekendStyle: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                calendarStyle: CalendarStyle(
                  outsideDaysVisible: false,
                  defaultTextStyle:
                      TextStyle(fontSize: 13, color: scheme.onSurface),
                ),
                calendarBuilders: CalendarBuilders(
                  defaultBuilder: (context, day, focused) =>
                      _dayCell(day, scheme),
                  selectedBuilder: (context, day, focused) =>
                      _dayCell(day, scheme, selected: true),
                  todayBuilder: (context, day, focused) =>
                      _dayCell(day, scheme, today: true),
                  outsideBuilder: (context, day, focused) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 4,
              child: _SummaryPanel(
                date: _selected,
                range: _range,
                onRangeChanged: (r) => setState(() => _range = r),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 10),

        // ── Diary (full width, below, separated from calendar) ──
        _DiaryEditor(
          date: _selected,
          images: _dayImages[_fmt(_selected)] ?? [],
          onImagesChanged: _loadImages,
        ),
        // Recent diary entries feed (list items) — tap jumps to that day
        if (_diaryEntries.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('最近记录',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final e in _diaryEntries.reversed.take(5))
            _DiaryEntryTile(
              dateStr: e.$1,
              content: e.$2,
              selected: e.$1 == _fmt(_selected),
              onTap: () {
                final dt = DateTime.parse(e.$1);
                setState(() {
                  _selected = dt;
                  _focused = dt;
                });
              },
            ),
        ],
      ],
    );

    if (widget.compact) {
      content = SizedBox(
        height: MediaQuery.of(context).size.height - 150,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: content,
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(padding: const EdgeInsets.all(12), child: content),
    );
  }

  /// Day cell: 3D gradient block + usage heatmap background + markers.
  Widget _dayCell(DateTime day, ColorScheme scheme,
      {bool selected = false, bool today = false}) {
    final dateStr = _fmt(day);
    final imgs = _dayImages[dateStr] ?? [];
    final hasDiary = _diaryDays.contains(dateStr);
    final info = lunarInfo(day);
    final usage = _dayUsage[dateStr] ?? 0;
    final intensity = _maxDayUsage == 0
        ? 0.0
        : (usage / _maxDayUsage).clamp(0.0, 1.0).toDouble();

    // Xiaomi-style clean cells: no busy blocks.
    // Selected = filled primary circle; today = light container circle;
    // festivals = red text; lunar = small grey text; usage = tiny dot.
    final isFestival = info.festival != null;

    // Subtle heat background only for high-usage days (never muddy)
    final heat = usage > 0
        ? scheme.primary.withValues(alpha: 0.05 + 0.15 * intensity)
        : null;

    String? sub;
    if (info.hasMarker) {
      sub = info.festival ?? info.solarTerm;
    } else if (info.day.isNotEmpty) {
      sub = info.day;
    }

    Color dayColor = scheme.onSurface;
    if (isFestival) {
      dayColor = Colors.red.shade600;
    }
    if (selected) {
      dayColor = scheme.onPrimary;
    } else if (today) {
      dayColor = scheme.primary;
    }

    return Center(
      child: Container(
        width: 40,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary
              : (heat ?? (today ? scheme.primaryContainer : null)),
          shape: BoxShape.circle,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Day number
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 15,
                fontWeight:
                    (today || selected) ? FontWeight.bold : FontWeight.w500,
                color: dayColor,
                height: 1.1,
              ),
            ),
            // Festival / lunar label
            SizedBox(
              height: 12,
              child: sub != null
                  ? Text(
                      sub,
                      style: TextStyle(
                        fontSize: 8,
                        color: (selected || today)
                            ? dayColor.withValues(alpha: 0.85)
                            : (isFestival
                                ? Colors.red.shade600
                                : scheme.outline),
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    )
                  : (imgs.isNotEmpty || hasDiary)
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (imgs.isNotEmpty)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final p in imgs.take(2))
                                    Padding(
                                      padding: const EdgeInsets.only(left: 1),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(2),
                                        child: Image.file(
                                          File(p),
                                          width: 7,
                                          height: 7,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              const SizedBox.shrink(),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            if (hasDiary && imgs.isEmpty)
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        )
                      : const SizedBox(height: 9),
            ),
          ],
        ),
      ),
    );
  }
}

/// Right panel: day/week/month summary with aggregated sessions.
class _SummaryPanel extends ConsumerStatefulWidget {
  const _SummaryPanel({
    required this.date,
    required this.range,
    required this.onRangeChanged,
  });

  final DateTime date;
  final _SummaryRange range;
  final ValueChanged<_SummaryRange> onRangeChanged;

  @override
  ConsumerState<_SummaryPanel> createState() => _SummaryPanelState();
}

class _SummaryPanelState extends ConsumerState<_SummaryPanel> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.range == _SummaryRange.day
                  ? '${widget.date.month}月${widget.date.day}日'
                  : widget.range == _SummaryRange.week
                      ? '本周'
                      : '本月',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            SegmentedButton<_SummaryRange>(
              segments: const [
                ButtonSegment(value: _SummaryRange.day, label: Text('日')),
                ButtonSegment(value: _SummaryRange.week, label: Text('周')),
                ButtonSegment(value: _SummaryRange.month, label: Text('月')),
              ],
              selected: {widget.range},
              onSelectionChanged: (s) => widget.onRangeChanged(s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.range == _SummaryRange.day)
          _DaySummary(date: widget.date)
        else
          _RangeSummary(date: widget.date, range: widget.range),
      ],
    );
  }
}

/// Day view: AGGREGATED sessions (same app merged) + heatmap.
class _DaySummary extends ConsumerStatefulWidget {
  const _DaySummary({required this.date});

  final DateTime date;

  @override
  ConsumerState<_DaySummary> createState() => _DaySummaryState();
}

class _DaySummaryState extends ConsumerState<_DaySummary> {
  bool _showAll = false;

  /// Merge consecutive same-app sessions into one aggregated row.
  List<_AggRow> _aggregate(List<DaySessionDto> sessions) {
    final rows = <String, _AggRow>{};
    for (final s in sessions) {
      if (s.isIdle) continue; // drop away/empty
      final agg = rows[s.appName] ?? _AggRow(
          appName: s.appName,
          firstStart: s.startedAt,
          seconds: 0,
          sessions: 0);
      agg.seconds += s.durationSecs.toInt();
      agg.sessions += 1;
      rows[s.appName] = agg;
    }
    final list = rows.values.toList()
      ..sort((a, b) => b.seconds.compareTo(a.seconds));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final asyncDay = ref.watch(calendarDayProvider(widget.date));

    return asyncDay.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) =>
          Text('加载失败: $e', style: const TextStyle(fontSize: 12)),
      data: (day) {
        final h = day.activeSeconds ~/ 3600;
        final m = (day.activeSeconds % 3600) ~/ 60;
        final agg = _aggregate(day.sessions);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                StatChip(label: '活跃 ${h}h${m}m', color: scheme.primary),
                StatChip(label: '${agg.length} 应用', color: scheme.tertiary),
              ],
            ),
            const SizedBox(height: 8),
            _HourlyHeatmap(date: widget.date),
            const SizedBox(height: 8),
            Text('使用记录',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            if (agg.isEmpty)
              Text('当天暂无记录',
                  style: TextStyle(fontSize: 12, color: scheme.outline))
            else ...[
              for (final a in agg.take(_showAll ? 20 : 6))
                _AggRowTile(row: a),
              if (agg.length > 6)
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(_showAll ? '收起' : '全部 ${agg.length} 应用'),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// Aggregated session row (app + first start + total duration + count).
class _AggRow {
  _AggRow({
    required this.appName,
    required this.firstStart,
    required this.seconds,
    required this.sessions,
  });

  final String appName;
  String firstStart;
  int seconds;
  int sessions;
}

class _AggRowTile extends StatelessWidget {
  const _AggRowTile({required this.row});

  final _AggRow row;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = row.seconds ~/ 3600;
    final m = (row.seconds % 3600) ~/ 60;
    final dur = h > 0 ? '${h}h${m}m' : '${m}m';

    String time = '';
    try {
      final dt = DateTime.parse(row.firstStart).toLocal();
      time =
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {}

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: appColor(row.appName), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          SizedBox(
              width: 42,
              child: Text(time,
                  style: TextStyle(fontSize: 10, color: scheme.outline))),
          Expanded(
            child: Text(row.appName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          Text(dur,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Week/Month range: aggregated top apps.
class _RangeSummary extends ConsumerWidget {
  const _RangeSummary({required this.date, required this.range});

  final DateTime date;
  final _SummaryRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (start, end) = _rangeBounds(range);
    final asyncSplit = ref.watch(rangeSummaryProvider((start, end)));

    return asyncSplit.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) =>
          Text('加载失败: $e', style: const TextStyle(fontSize: 12)),
      data: (sessions) {
        final total =
            sessions.fold<int>(0, (s, e) => s + e.durationSecs.toInt());
        final h = total ~/ 3600;
        final m = (total % 3600) ~/ 60;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                StatChip(label: '活跃 ${h}h${m}m', color: scheme.primary),
                StatChip(label: '${sessions.length} 应用', color: scheme.tertiary),
              ],
            ),
            const SizedBox(height: 8),
            Text('Top 应用',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            if (sessions.isEmpty)
              Text('暂无记录',
                  style: TextStyle(fontSize: 12, color: scheme.outline))
            else
              for (final s in sessions.take(8))
                _SessionRowSimple(name: s.appName, seconds: s.durationSecs.toInt()),
          ],
        );
      },
    );
  }

  (String, String) _rangeBounds(_SummaryRange range) {
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    if (range == _SummaryRange.week) {
      final monday = now.subtract(Duration(days: now.weekday - 1));
      return (fmt(monday), fmt(now));
    }
    return ('${now.year}-${now.month.toString().padLeft(2, '0')}-01', fmt(now));
  }
}

class _SessionRowSimple extends StatelessWidget {
  const _SessionRowSimple({required this.name, required this.seconds});

  final String name;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: appColor(name), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
          Text(h > 0 ? '${h}h${m}m' : '${m}m',
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

/// Diary editor (full-width, below calendar) — Material 3 style.
class _DiaryEditor extends ConsumerStatefulWidget {
  const _DiaryEditor({
    required this.date,
    required this.images,
    required this.onImagesChanged,
  });

  final DateTime date;
  final List<String> images;
  final VoidCallback onImagesChanged;

  @override
  ConsumerState<_DiaryEditor> createState() => _DiaryEditorState();
}

class _DiaryEditorState extends ConsumerState<_DiaryEditor> {
  TextEditingController? _diaryCtrl;
  bool _dirty = false;

  @override
  void didUpdateWidget(covariant _DiaryEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date != widget.date) _dirty = false;
  }

  Future<void> _uploadImage() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      if (result == null || result.files.isEmpty) return;
      final src = result.files.single.path;
      if (src == null) return;

      final dir = Platform.environment['APPDATA'] ?? '.';
      final targetDir = Directory('$dir\\TimeTrace\\diary_images');
      targetDir.createSync(recursive: true);
      final dateStr =
          '${widget.date.year}-${widget.date.month.toString().padLeft(2, '0')}-${widget.date.day.toString().padLeft(2, '0')}';
      final ext = src.split('.').last;
      final dest =
          '${targetDir.path}\\${dateStr}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      File(src).copySync(dest);

      final api = ref.read(apiProvider);
      api.addDiaryImage(date: dateStr, path: dest);
      AppLogger.log('diary image added: $dest');
      widget.onImagesChanged();
    } catch (e) {
      AppLogger.log('diary image upload failed: $e');
    }
  }

  Future<void> _removeImage(String path) async {
    try {
      final api = ref.read(apiProvider);
      api.removeDiaryImage(path: path);
      File(path).deleteSync();
      widget.onImagesChanged();
    } catch (e) {
      AppLogger.log('remove diary image failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final asyncDay = ref.watch(calendarDayProvider(widget.date));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header: title + add-image button grouped on the left
        Row(
          children: [
            Icon(Icons.edit_note, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('日记',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: scheme.primary)),
            const SizedBox(width: 10),
            IconButton(
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 19),
              tooltip: '添加图片',
              onPressed: _uploadImage,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            if (widget.images.isNotEmpty) ...[
              const SizedBox(width: 2),
              Text('${widget.images.length} 图',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ],
        ),
        const SizedBox(height: 6),
        // Markdown editor (Typora-like) with toolbar + preview
        asyncDay.when(
          loading: () => const SizedBox(height: 140),
          error: (_, __) => const SizedBox(height: 140),
          data: (day) => MarkdownDiaryEditor(
            initialText: day.diary,
            maxLines: 5,
            onSave: (text) async {
              await saveDiary(ref, widget.date, text);
              // Refresh the entries feed + diary markers
              if (mounted) widget.onImagesChanged();
            },
          ),
        ),
        // Image grid - tap to fullscreen preview
        if (widget.images.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in widget.images)
                  GestureDetector(
                    onTap: () => showImagePreview(context, p,
                        title: '${widget.date.month}月${widget.date.day}日图片'),
                    child: SizedBox(
                      width: 84,
                      height: 84,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(p),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: scheme.surfaceContainerHighest,
                                child: const Icon(Icons.broken_image,
                                    color: Colors.grey),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 3,
                            right: 3,
                            child: InkWell(
                              onTap: () => _removeImage(p),
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.close,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One diary entry in the feed: date + first-line snippet.
class _DiaryEntryTile extends StatelessWidget {
  const _DiaryEntryTile({
    required this.dateStr,
    required this.content,
    required this.selected,
    required this.onTap,
  });

  final String dateStr;
  final String content;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firstLine = content.split('\n').firstWhere(
        (l) => l.trim().isNotEmpty,
        orElse: () => '');
    final snippet = firstLine.length > 40
        ? firstLine.substring(0, 40)
        : firstLine;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: selected
              ? scheme.secondaryContainer.withValues(alpha: 0.5)
              : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Text(dateStr.substring(5),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                snippet.isEmpty ? '(空)' : snippet,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
            Icon(Icons.chevron_right, size: 14, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

class _HourlyHeatmap extends ConsumerWidget {
  const _HourlyHeatmap({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final d =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final hourly = ref.watch(dayHourlyProvider(d));

    return hourly.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (hours) {
        final max = hours.reduce((a, b) => a > b ? a : b).clamp(1, 1 << 62);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当日活跃时段',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 4),
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  for (var i = 0; i < 24; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 1),
                        child: Tooltip(
                          message: '${i}时 · ${_mm(hours[i])}',
                          child: Container(
                            decoration: BoxDecoration(
                              color: hours[i] == 0
                                  ? scheme.surfaceContainerHighest
                                  : scheme.primary.withValues(
                                      alpha: 0.2 + 0.8 * (hours[i] / max)),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                for (var i = 0; i < 24; i++)
                  Expanded(
                    child: Text(
                      i % 4 == 0 ? '$i' : '',
                      style: TextStyle(fontSize: 8, color: scheme.outline),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  String _mm(int secs) {
    final m = secs ~/ 60;
    return m > 0 ? '${m}分' : '0分';
  }
}
