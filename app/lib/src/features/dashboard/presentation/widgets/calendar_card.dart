import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/widgets/image_album.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_provider.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Journal section: 日记 header + Markdown editor + image grid + entries
/// feed for the selected day. Consumes calendarDataProvider directly.
/// Diary time range — driven by the calendar above (not the diary itself).
enum DiaryRange { day, week, month, custom }

/// Journal — 朋友圈-style: each entry is an independent post with its own
/// text + image album. Range comes from the calendar; publish/edit/delete.
class DiarySection extends ConsumerStatefulWidget {
  const DiarySection({
    required this.date,
    this.range = DiaryRange.day,
    this.customStart,
    this.onRangeChanged,
    this.onCustomStart,
    super.key,
  });

  /// Anchor date from the calendar — the selected day.
  final DateTime date;

  /// Shared range selected at the calendar level.
  final DiaryRange range;

  /// Custom range start date (null until picked).
  final DateTime? customStart;

  final ValueChanged<DiaryRange>? onRangeChanged;
  final VoidCallback? onCustomStart;

  @override
  ConsumerState<DiarySection> createState() => _DiarySectionState();
}

class _DiarySectionState extends ConsumerState<DiarySection> {
  int? _editingId; // null = writing a NEW post for the selected day
  List<String> _staged = []; // new images to attach on publish
  final Set<String> _collapsedDays = {}; // collapsed day groups

  @override
  void didUpdateWidget(covariant DiarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switching the calendar day must clear any in-progress edit,
    // staged images and collapsed groups — otherwise "编辑中" sticks.
    if (!isSameDayDate(oldWidget.date, widget.date)) {
      _editingId = null;
      _staged = [];
      _collapsedDays.clear();
    }
  }

  /// Date equality helper (time ignored).
  static bool isSameDayDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Toggle inline editing for a post (images are managed inside the card).
  void _startEdit(int id) {
    setState(() => _editingId = _editingId == id ? null : id);
  }

  (String, String)? _bounds() {
    final d = widget.date;
    String f(DateTime x) => calFmt(x);
    switch (widget.range) {
      case DiaryRange.day:
        return (f(d), f(d));
      case DiaryRange.week:
        return (f(d.subtract(const Duration(days: 6))), f(d));
      case DiaryRange.month:
        return (f(DateTime(d.year, d.month, 1)), f(d));
      case DiaryRange.custom:
        final s = widget.customStart;
        if (s == null) return null;
        return (f(s), f(d));
    }
  }

  Future<void> _uploadImage() async {
    try {
      final result =
          await FilePicker.pickFiles(type: FileType.image, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final dir = Platform.environment['APPDATA'] ?? '.';
      final targetDir = Directory('$dir\\TimeTrace\\diary_images');
      targetDir.createSync(recursive: true);
      final dateStr = calFmt(widget.date);
      final api = ref.read(apiProvider);
      final added = <String>[];
      for (final f in result.files) {
        final src = f.path;
        if (src == null) continue;
        final ext = src.split('.').last;
        final dest =
            '${targetDir.path}\\${dateStr}_${DateTime.now().millisecondsSinceEpoch}.$ext';
        File(src).copySync(dest);
        api.addDiaryImage(date: dateStr, path: dest);
        added.add(dest);
      }
      if (mounted) setState(() => _staged = [..._staged, ...added]);
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('diary image upload failed: $e');
    }
  }

  Future<void> _removeStaged(String path) async {
    try {
      final api = ref.read(apiProvider);
      api.removeDiaryImage(path: path);
      try {
        File(path).deleteSync();
      } catch (_) {}
      setState(() => _staged = _staged.where((p) => p != path).toList());
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('remove staged image failed: $e');
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这篇日记？'),
        content: const Text('日记及其图片将被删除。', style: TextStyle(fontSize: 13)),
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
      // Delete the entry's own images too (file + DB row)
      for (final p in api.getDiaryImagesForEntry(entryId: id)) {
        try {
          File(p).deleteSync();
        } catch (_) {}
        api.removeDiaryImage(path: p);
      }
      api.deleteDiaryEntry(id: id);
      if (_editingId == id) setState(() {
        _editingId = null;
        _staged = [];
      });
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('delete diary entry failed: $e');
    }
  }

  /// Publish: draft → published (or update the entry being edited),
  /// then attach staged images.
  Future<void> _publish(String text) async {
    if (text.trim().isEmpty) return;
    final api = ref.read(apiProvider);
    final id = api.publishDiary(date: calFmt(widget.date), content: text);
    for (final p in _staged) {
      try {
        api.setDiaryImageEntry(path: p, entryId: id);
      } catch (e) {
        AppLogger.log('link image failed: $e');
      }
    }
    if (mounted) setState(() => _staged = []);
    ref.invalidate(calendarDataProvider);
    ref.invalidate(diaryDraftProvider(calFmt(widget.date)));
  }

  /// Autosave (debounced): new post → draft for the day.
  Future<void> _autosave(String text) async {
    final api = ref.read(apiProvider);
    api.saveDiaryDraft(date: calFmt(widget.date), content: text);
    ref.invalidate(diaryDraftProvider(calFmt(widget.date)));
    ref.invalidate(calendarDataProvider);
  }

  /// Discard the day's draft.
  Future<void> _discardDraft() async {
    final api = ref.read(apiProvider);
    final draft = ref.read(diaryDraftProvider(calFmt(widget.date))).value;
    if (draft == null || draft.trim().isEmpty) return;
    try {
      final entries = api.getDiaryEntriesDetailed(
        start: calFmt(DateTime(widget.date.year, 1, 1)),
        end: calFmt(DateTime(widget.date.year, 12, 31)),
      );
      for (final e in entries) {
        if (e.status == 'draft' && e.date == calFmt(widget.date)) {
          api.deleteDiaryEntry(id: e.id);
        }
      }
    } catch (e) {
      AppLogger.log('discard draft failed: $e');
    }
    ref.invalidate(diaryDraftProvider(calFmt(widget.date)));
    ref.invalidate(calendarDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = ref.watch(calendarDataProvider).value;
    final all = data?.entries ?? const <DiaryEntryDto>[];
    final draft = ref.watch(diaryDraftProvider(calFmt(widget.date))).value;
    final bounds = _bounds();
    final inRange = bounds == null
        ? all
        : all
            .where((e) =>
                e.date.compareTo(bounds.$1) >= 0 && e.date.compareTo(bounds.$2) <= 0)
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Diary: single title row (title · date · range label) ──
        Row(
          children: [
            Icon(Icons.edit_note, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text('日记',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: scheme.primary)),
            const SizedBox(width: 8),
            Text('· ${calFmt(widget.date)}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            const Spacer(),
            Text(
              switch (widget.range) {
                DiaryRange.day => '所选日',
                DiaryRange.week => '近一周',
                DiaryRange.month => '本月',
                DiaryRange.custom => '自定义',
              },
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // ── Editor: tone + soft shadow instead of a hard border ──
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarkdownDiaryEditor(
                key: ValueKey('diary-${calFmt(widget.date)}'),
                initialText: draft ?? '',
                maxLines: 4,
                onAutoSave: _autosave,
                onPublish: _publish,
              ),
              // Draft badge: autosaved but not published yet
              if (_editingId == null &&
                  draft != null &&
                  draft.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('草稿',
                            style: TextStyle(
                                fontSize: 10,
                                color: scheme.onTertiaryContainer)),
                      ),
                      const SizedBox(width: 8),
                      Text('已自动保存，发布后才会出现在日记列表',
                          style: TextStyle(
                              fontSize: 10, color: scheme.outline)),
                      const Spacer(),
                      TextButton(
                        onPressed: _discardDraft,
                        child: const Text('放弃草稿',
                            style: TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                ),
              // Staged images for the new post (removable)
              if (_staged.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _staged)
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(p), fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox.shrink()),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: InkWell(
                                onTap: () => _removeStaged(p),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close,
                                      size: 10, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              // Add image — small icon button, tooltip on hover
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: IconButton(
                  onPressed: _uploadImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                  tooltip: '添加图片（可多选）',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // ── Posts — grouped by day (collapsible), each item has 👁 toggles ──
        if (inRange.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('该范围内暂无日记',
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
            ),
          )
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => SlideTransition(
              position: Tween<Offset>(begin: const Offset(0.05, 0), end: Offset.zero)
                  .animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Column(
              key: ValueKey('posts-${inRange.map((e) => e.id).join(',')}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in _groupByDay(inRange))
                  _DayGroup(
                    dateStr: group.$1,
                    posts: group.$2,
                    images: (id) => data?.entryImages[id] ?? const [],
                    collapsed: _collapsedDays.contains(group.$1),
                    onToggleGroup: () => setState(() {
                      if (_collapsedDays.contains(group.$1)) {
                        _collapsedDays.remove(group.$1);
                      } else {
                        _collapsedDays.add(group.$1);
                      }
                    }),
                    editingId: _editingId,
                    onEdit: _startEdit,
                    onDelete: _delete,
                    scheme: scheme,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Group posts by day, days newest first, posts newest first.
  List<(String, List<DiaryEntryDto>)> _groupByDay(List<DiaryEntryDto> posts) {
    final map = <String, List<DiaryEntryDto>>{};
    for (final e in posts) {
      map.putIfAbsent(e.date, () => []).add(e);
    }
    final days = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final d in days) (d, map[d]!),
    ];
  }
}

/// Day group header: date + count, tap to collapse/expand the whole day.
class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.dateStr,
    required this.posts,
    required this.images,
    required this.collapsed,
    required this.onToggleGroup,
    required this.editingId,
    required this.onEdit,
    required this.onDelete,
    required this.scheme,
  });

  final String dateStr;
  final List<DiaryEntryDto> posts;
  final List<String> Function(int id) images;
  final bool collapsed;
  final VoidCallback onToggleGroup;
  final int? editingId;
  final void Function(int id) onEdit;
  final void Function(int id) onDelete;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — tap to collapse/expand
        InkWell(
          onTap: onToggleGroup,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 14, color: scheme.primary),
                const SizedBox(width: 6),
                Text(dateStr,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface)),
                const SizedBox(width: 8),
                Text('${posts.length} 条',
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
                const Spacer(),
                Icon(
                    collapsed
                        ? Icons.keyboard_arrow_right
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: scheme.outline),
              ],
            ),
          ),
        ),
        // Day's posts (collapse animation)
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          child: collapsed
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    for (final e in posts)
                      _PostCard(
                        id: e.id,
                        dateStr: e.date,
                        content: e.content,
                        images: images(e.id),
                        editing: editingId == e.id,
                        onEdit: () => onEdit(e.id),
                        onDelete: () => onDelete(e.id),
                        scheme: scheme,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One diary post: text + its own images, each with an 👁 toggle
/// (visibility / visibility_off) — hide/show independently.
/// One diary post (朋友圈): text + own images. Tapping ✎ edits INLINE —
/// text becomes a field, images expand as a grid with per-image ✕ and a
/// trailing + to add more. 👁 toggles hide/show when not editing.
class _PostCard extends ConsumerStatefulWidget {
  const _PostCard({
    required this.id,
    required this.dateStr,
    required this.content,
    required this.images,
    required this.editing,
    required this.onEdit,
    required this.onDelete,
    required this.scheme,
  });

  final int id;
  final String dateStr;
  final String content;
  final List<String> images;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ColorScheme scheme;

  @override
  ConsumerState<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<_PostCard> {
  bool _textVisible = true;
  bool _imagesVisible = true;
  late TextEditingController _editCtrl;
  List<String> _editImages = []; // existing images (removable while editing)
  List<String> _newImages = []; // uploaded during this edit session

  @override
  void initState() {
    super.initState();
    _editCtrl = TextEditingController(text: widget.content);
    _editImages = List.of(widget.images);
  }

  @override
  void didUpdateWidget(covariant _PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _textVisible = true;
      _imagesVisible = true;
    }
    // Entering edit mode: snapshot images for inline management.
    if (widget.editing && !oldWidget.editing) {
      _editCtrl.text = widget.content;
      _editImages = List.of(widget.images);
      _newImages = [];
    }
    // Exiting edit mode (saved/cancelled elsewhere): reset new additions.
    if (!widget.editing && oldWidget.editing) {
      _newImages = [];
    }
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    super.dispose();
  }

  Future<void> _removeEditImage(String path) async {
    final api = ref.read(apiProvider);
    api.removeDiaryImage(path: path);
    try {
      File(path).deleteSync();
    } catch (_) {}
    setState(() => _editImages = _editImages.where((p) => p != path).toList());
    ref.invalidate(calendarDataProvider);
  }

  Future<void> _addImages() async {
    try {
      final result =
          await FilePicker.pickFiles(type: FileType.image, allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      final dir = Platform.environment['APPDATA'] ?? '.';
      final targetDir = Directory('$dir\\TimeTrace\\diary_images');
      targetDir.createSync(recursive: true);
      final api = ref.read(apiProvider);
      final added = <String>[];
      for (final f in result.files) {
        final src = f.path;
        if (src == null) continue;
        final ext = src.split('.').last;
        final dest =
            '${targetDir.path}\\${widget.dateStr}_${DateTime.now().millisecondsSinceEpoch}.$ext';
        File(src).copySync(dest);
        api.addDiaryImage(date: widget.dateStr, path: dest);
        added.add(dest);
      }
      setState(() => _newImages = [..._newImages, ...added]);
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('add images to post failed: $e');
    }
  }

  Future<void> _save() async {
    final api = ref.read(apiProvider);
    api.updateDiaryEntry(id: widget.id, content: _editCtrl.text);
    for (final p in _newImages) {
      try {
        api.setDiaryImageEntry(path: p, entryId: widget.id);
      } catch (e) {
        AppLogger.log('link image failed: $e');
      }
    }
    ref.invalidate(calendarDataProvider);
    if (mounted) widget.onEdit(); // toggles edit off (same id)
  }

  @override
  Widget build(BuildContext context) {
    final firstLine = widget.content
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final editing = widget.editing;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: widget.scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: editing
            ? BorderSide(
                color: widget.scheme.primary.withValues(alpha: 0.6))
            : BorderSide.none,
      ),
      elevation: editing ? 2 : 1,
      shadowColor:
          editing ? widget.scheme.primary.withValues(alpha: 0.2) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Text: inline field while editing, 👁 toggle otherwise ──
            if (editing)
              TextField(
                controller: _editCtrl,
                minLines: 2,
                maxLines: 10,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.all(8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  hintText: '写点什么…',
                  hintStyle: TextStyle(
                      fontSize: 12, color: widget.scheme.outline),
                ),
                style: const TextStyle(fontSize: 13, height: 1.5),
              )
            else
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: _textVisible
                    ? (widget.content.trim().isEmpty
                        ? Text('(无文字)',
                            style: TextStyle(
                                fontSize: 12, color: widget.scheme.outline))
                        : MarkdownBody(
                            data: widget.content,
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              p: const TextStyle(fontSize: 13, height: 1.6),
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
                          ))
                    : Text(
                        firstLine.isEmpty ? '内容已隐藏' : '内容已隐藏 · $firstLine',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: widget.scheme.outline)),
              ),
            // ── Images: edit = expanded grid with ✕ + add; else 👁 toggle ──
            if (widget.images.isNotEmpty || editing) ...[
              const SizedBox(height: 8),
              if (editing)
                _EditImageGrid(
                  images: [..._editImages, ..._newImages],
                  onRemove: _removeEditImage,
                  onAdd: _addImages,
                  scheme: widget.scheme,
                )
              else
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: _imagesVisible
                      ? ImageAlbum(
                          images: widget.images,
                          title: '${widget.images.length} 张图片',
                        )
                      : Text('图片已隐藏',
                          style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: widget.scheme.outline)),
                ),
            ],
            // ── Actions ──
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: editing
                  ? Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 15),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onDelete,
                        ),
                        const Spacer(),
                        // Save/cancel on the RIGHT — same side as ✎
                        TextButton(
                          onPressed: widget.onEdit, // toggle off
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('取消',
                              style: TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 4),
                        FilledButton.tonal(
                          onPressed: _save,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('保存',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          icon: Icon(
                              _textVisible
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 16),
                          tooltip: _textVisible ? '隐藏文字' : '显示文字',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(
                              () => _textVisible = !_textVisible),
                        ),
                        if (widget.images.isNotEmpty)
                          IconButton(
                            icon: Icon(
                                _imagesVisible
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                                size: 16),
                            tooltip: _imagesVisible ? '隐藏图片' : '显示图片',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(
                                () => _imagesVisible = !_imagesVisible),
                          ),
                        const Spacer(),
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
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editing image grid: expanded thumbnails with per-image ✕ + trailing add.
class _EditImageGrid extends StatelessWidget {
  const _EditImageGrid({
    required this.images,
    required this.onRemove,
    required this.onAdd,
    required this.scheme,
  });

  final List<String> images;
  final ValueChanged<String> onRemove;
  final VoidCallback onAdd;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final p in images)
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(p), fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                            color: scheme.surfaceContainerHighest,
                            child: const Icon(Icons.broken_image,
                                size: 16, color: Colors.grey),
                          )),
                ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: InkWell(
                    onTap: () => onRemove(p),
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child:
                          const Icon(Icons.close, size: 11, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Add-more tile
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border:
                  Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Icon(Icons.add, size: 22, color: scheme.primary),
          ),
        ),
      ],
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
                          message: '${i}时 · ${formatDuration(hours[i])}',
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

}
