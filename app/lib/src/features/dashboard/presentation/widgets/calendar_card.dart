import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/widgets/image_preview.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Journal section: 日记 header + Markdown editor + image grid + entries
/// feed for the selected day. Consumes calendarDataProvider directly.
enum _DiaryRange { day, week, month, custom }

/// Journal: range selector + new/edit entry editor + collapsible image
/// stack + expandable entry list (edit/delete). Multiple entries per day.
class DiarySection extends ConsumerStatefulWidget {
  const DiarySection({required this.date, super.key});

  /// Anchor date from the calendar — the selected day.
  final DateTime date;

  @override
  ConsumerState<DiarySection> createState() => _DiarySectionState();
}

class _DiarySectionState extends ConsumerState<DiarySection> {
  _DiaryRange _range = _DiaryRange.day;
  DateTime? _customStart;
  int? _editingId; // null = writing a NEW entry for the selected day
  bool _imagesOpen = false;

  (String, String)? _bounds() {
    final d = widget.date;
    String f(DateTime x) => calFmt(x);
    switch (_range) {
      case _DiaryRange.day:
        return (f(d), f(d));
      case _DiaryRange.week:
        return (f(d.subtract(const Duration(days: 6))), f(d));
      case _DiaryRange.month:
        return (f(DateTime(d.year, d.month, 1)), f(d));
      case _DiaryRange.custom:
        final s = _customStart;
        if (s == null) return null;
        return (f(s), f(d));
    }
  }

  Future<void> _pickCustomStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: '选择起始日期（到所选日）',
    );
    if (picked != null) setState(() => _customStart = picked);
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
      final dateStr = calFmt(widget.date);
      final ext = src.split('.').last;
      final dest =
          '${targetDir.path}\\${dateStr}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      File(src).copySync(dest);
      final api = ref.read(apiProvider);
      api.addDiaryImage(date: dateStr, path: dest);
      AppLogger.log('diary image added: $dest');
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('diary image upload failed: $e');
    }
  }

  Future<void> _removeImage(String path) async {
    try {
      final api = ref.read(apiProvider);
      api.removeDiaryImage(path: path);
      File(path).deleteSync();
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('remove diary image failed: $e');
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这篇日记？'),
        content: const Text('删除后不可恢复。', style: TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final api = ref.read(apiProvider);
      api.deleteDiaryEntry(id: id);
      if (_editingId == id) setState(() => _editingId = null);
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('delete diary entry failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = ref.watch(calendarDataProvider).value;
    final all = data?.entries ?? const <(int, String, String)>[];
    final bounds = _bounds();
    final inRange = bounds == null
        ? all
        : all
            .where((e) =>
                e.$2.compareTo(bounds.$1) >= 0 && e.$2.compareTo(bounds.$2) <= 0)
            .toList();
    final images = data?.images[calFmt(widget.date)] ?? const <String>[];
    final editing = _editingId == null
        ? null
        : all.where((e) => e.$1 == _editingId).firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Range selector ──
        Row(
          children: [
            Icon(Icons.edit_note, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text('日记',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: scheme.primary)),
            const Spacer(),
            SegmentedButton<_DiaryRange>(
              segments: const [
                ButtonSegment(value: _DiaryRange.day, label: Text('当天', style: TextStyle(fontSize: 11))),
                ButtonSegment(value: _DiaryRange.week, label: Text('一周', style: TextStyle(fontSize: 11))),
                ButtonSegment(value: _DiaryRange.month, label: Text('一月', style: TextStyle(fontSize: 11))),
                ButtonSegment(value: _DiaryRange.custom, label: Text('自定义', style: TextStyle(fontSize: 11))),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: WidgetStatePropertyAll(const EdgeInsets.symmetric(horizontal: 8)),
              ),
            ),
          ],
        ),
        if (_range == _DiaryRange.custom) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(_customStart == null ? '未选起始日' : '从 ${calFmt(_customStart!)} 起',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _pickCustomStart,
                child: const Text('选起始日', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        // ── Editor (new entry for selected day, or editing) ──
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(_editingId == null ? '写新日记' : '编辑日记',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.primary)),
                  const SizedBox(width: 8),
                  Text(calFmt(widget.date),
                      style: TextStyle(fontSize: 11, color: scheme.outline)),
                  const Spacer(),
                  if (_editingId != null)
                    TextButton(
                      onPressed: () => setState(() => _editingId = null),
                      child: const Text('取消编辑', style: TextStyle(fontSize: 11)),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              MarkdownDiaryEditor(
                key: ValueKey('diary-${calFmt(widget.date)}-$_editingId'),
                initialText: editing?.$3 ?? '',
                maxLines: 4,
                onSave: (text) async {
                  if (text.trim().isEmpty) return;
                  final api = ref.read(apiProvider);
                  if (_editingId != null) {
                    api.updateDiaryEntry(id: _editingId!, content: text);
                  } else {
                    api.addDiaryEntry(date: calFmt(widget.date), content: text);
                  }
                  ref.invalidate(calendarDataProvider);
                },
              ),
            ],
          ),
        ),
        // ── Images: collapsible stack (animated) ──
        if (images.isNotEmpty) ...[
          const SizedBox(height: 8),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => setState(() => _imagesOpen = !_imagesOpen),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(_imagesOpen ? Icons.expand_less : Icons.expand_more,
                            size: 16, color: scheme.outline),
                        const SizedBox(width: 4),
                        Text('图片 ${images.length} 张',
                            style: TextStyle(fontSize: 12, color: scheme.outline)),
                      ],
                    ),
                  ),
                ),
                if (_imagesOpen)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in images)
                        GestureDetector(
                          onTap: () => showImagePreview(context, p,
                              title: '${widget.date.month}月${widget.date.day}日图片'),
                          child: SizedBox(
                            width: 72,
                            height: 72,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
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
                                      decoration: const BoxDecoration(
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
                  )
                else
                  // Stacked mini-preview: first thumb + "+n" badge
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(images.first),
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('+${images.length - 1}',
                              style: TextStyle(
                                  fontSize: 10, color: scheme.onSecondaryContainer)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        // ── Add-image button (always available) ──
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: OutlinedButton.icon(
            onPressed: _uploadImage,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: const Text('上传图片', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // ── Entry list ──
        if (inRange.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('该范围内暂无日记',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),
          )
        else
          for (final e in inRange)
            _EntryCard(
              id: e.$1,
              dateStr: e.$2,
              content: e.$3,
              expanded: _editingId == e.$1,
              onExpand: () => setState(() {
                _editingId = _editingId == e.$1 ? null : e.$1;
              }),
              onEdit: () => setState(() {
                _editingId = e.$1;
                _imagesOpen = false;
              }),
              onDelete: () => _delete(e.$1),
              scheme: scheme,
            ),
      ],
    );
  }
}

/// One diary entry: expandable card (AnimatedSize) with edit/delete.
class _EntryCard extends StatefulWidget {
  const _EntryCard({
    required this.id,
    required this.dateStr,
    required this.content,
    required this.expanded,
    required this.onExpand,
    required this.onEdit,
    required this.onDelete,
    required this.scheme,
  });

  final int id;
  final String dateStr;
  final String content;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ColorScheme scheme;

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  @override
  Widget build(BuildContext context) {
    final firstLine = widget.content
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final snippet = firstLine.length > 40 ? firstLine.substring(0, 40) : firstLine;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: widget.scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
            color: widget.expanded
                ? widget.scheme.primary.withValues(alpha: 0.6)
                : widget.scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: widget.onExpand,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.article_outlined,
                      size: 15, color: widget.scheme.primary),
                  const SizedBox(width: 6),
                  Text(widget.dateStr,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: widget.scheme.primary)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      snippet.isEmpty ? '(空)' : snippet,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  // Action buttons (stop propagation)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    tooltip: '编辑',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onEdit,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 15),
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onDelete,
                  ),
                  Icon(
                    widget.expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: widget.scheme.outline,
                  ),
                ],
              ),
              // Expanded body: full markdown render
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: widget.expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: widget.content.trim().isEmpty
                            ? const SizedBox.shrink()
                            : MarkdownBody(
                                data: widget.content,
                                selectable: true,
                                styleSheet: MarkdownStyleSheet(
                                  p: const TextStyle(fontSize: 12, height: 1.5),
                                  h1: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: widget.scheme.onSurface),
                                  h2: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: widget.scheme.onSurface),
                                  code: TextStyle(
                                      fontSize: 11,
                                      color: widget.scheme.primary),
                                ),
                              ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum SummaryRange { day, week, month }

class DaySummaryPanel extends ConsumerStatefulWidget {
  const DaySummaryPanel({
    required this.date,
    required this.range,
    required this.onRangeChanged,
  });

  final DateTime date;
  final SummaryRange range;
  final ValueChanged<SummaryRange> onRangeChanged;

  @override
  ConsumerState<DaySummaryPanel> createState() => _DaySummaryPanelState();
}

class _DaySummaryPanelState extends ConsumerState<DaySummaryPanel> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.range == SummaryRange.day
                  ? '${widget.date.month}月${widget.date.day}日'
                  : widget.range == SummaryRange.week
                      ? '本周'
                      : '本月',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            SegmentedButton<SummaryRange>(
              segments: const [
                ButtonSegment(value: SummaryRange.day, label: Text('日')),
                ButtonSegment(value: SummaryRange.week, label: Text('周')),
                ButtonSegment(value: SummaryRange.month, label: Text('月')),
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
        if (widget.range == SummaryRange.day)
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
  final SummaryRange range;

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

  (String, String) _rangeBounds(SummaryRange range) {
    String fmt(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final now = DateTime.now();
    if (range == SummaryRange.week) {
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
