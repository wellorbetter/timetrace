import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/image_album.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';

enum DiaryRange { day, week, month }

/// Flat, document-like desktop diary feed.
///
/// The editor is a single bordered surface. Published entries are grouped by
/// date and rendered as document blocks on a subtle timeline instead of cards.
class DiarySection extends ConsumerStatefulWidget {
  const DiarySection({
    required this.date,
    this.range = DiaryRange.day,
    super.key,
  });

  final DateTime date;
  final DiaryRange range;

  @override
  ConsumerState<DiarySection> createState() => _DiarySectionState();
}

class _DiarySectionState extends ConsumerState<DiarySection> {
  int? _editingId;
  List<String> _staged = [];
  final Set<String> _collapsedDays = {};

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  void didUpdateWidget(covariant DiarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameDay(oldWidget.date, widget.date)) {
      _editingId = null;
      _staged = [];
      _collapsedDays.clear();
    }
  }

  (String, String) _bounds() {
    final date = widget.date;
    switch (widget.range) {
      case DiaryRange.day:
        return (calFmt(date), calFmt(date));
      case DiaryRange.week:
        final monday = date.subtract(Duration(days: date.weekday - 1));
        return (calFmt(monday), calFmt(date));
      case DiaryRange.month:
        return (calFmt(DateTime(date.year, date.month, 1)), calFmt(date));
    }
  }

  Future<void> _pickImages() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      PlatformPaths.ensureDiaryImagesDirectory();
      final api = ref.read(apiProvider);
      final date = calFmt(widget.date);
      final added = <String>[];

      for (var index = 0; index < result.files.length; index++) {
        final source = result.files[index].path;
        if (source == null) continue;
        final extension = source.split('.').last;
        final name =
            '${date}_${DateTime.now().microsecondsSinceEpoch}_$index.$extension';
        final destination = PlatformPaths.diaryImage(name);
        File(source).copySync(destination);
        api.addDiaryImage(date: date, path: destination);
        added.add(destination);
      }

      if (mounted) setState(() => _staged = [..._staged, ...added]);
      ref.invalidate(calendarDataProvider);
    } catch (error) {
      AppLogger.log('diary image upload failed: $error');
    }
  }

  Future<void> _removeStaged(String path) async {
    try {
      ref.read(apiProvider).removeDiaryImage(path: path);
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() => _staged = _staged.where((item) => item != path).toList());
      }
      ref.invalidate(calendarDataProvider);
    } catch (error) {
      AppLogger.log('remove staged image failed: $error');
    }
  }

  Future<void> _publish(String text) async {
    if (text.trim().isEmpty) return;
    final api = ref.read(apiProvider);
    final date = calFmt(widget.date);
    final id = api.publishDiary(date: date, content: text);

    for (final path in _staged) {
      try {
        api.setDiaryImageEntry(path: path, entryId: id);
      } catch (error) {
        AppLogger.log('link diary image failed: $error');
      }
    }

    if (mounted) setState(() => _staged = []);
    ref.invalidate(calendarDataProvider);
    ref.invalidate(diaryDraftProvider(date));
  }

  Future<void> _autosave(String text) async {
    final date = calFmt(widget.date);
    ref.read(apiProvider).saveDiaryDraft(date: date, content: text);
    ref.invalidate(diaryDraftProvider(date));
    ref.invalidate(calendarDataProvider);
  }

  Future<void> _discardDraft() async {
    final date = calFmt(widget.date);
    final draft = ref.read(diaryDraftProvider(date)).value;
    if (draft == null || draft.trim().isEmpty) return;

    try {
      final api = ref.read(apiProvider);
      final entries = api.getDiaryEntriesDetailed(
        start: calFmt(DateTime(widget.date.year, 1, 1)),
        end: calFmt(DateTime(widget.date.year, 12, 31)),
      );
      for (final entry in entries) {
        if (entry.status == 'draft' && entry.date == date) {
          api.deleteDiaryEntry(id: entry.id);
        }
      }
    } catch (error) {
      AppLogger.log('discard diary draft failed: $error');
    }

    ref.invalidate(diaryDraftProvider(date));
    ref.invalidate(calendarDataProvider);
  }

  Future<void> _delete(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这篇日记？'),
        content: const Text('日记及其图片将被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final api = ref.read(apiProvider);
      for (final path in api.getDiaryImagesForEntry(entryId: id)) {
        try {
          File(path).deleteSync();
        } catch (_) {}
        api.removeDiaryImage(path: path);
      }
      api.deleteDiaryEntry(id: id);
      if (_editingId == id && mounted) setState(() => _editingId = null);
      ref.invalidate(calendarDataProvider);
    } catch (error) {
      AppLogger.log('delete diary entry failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = calFmt(widget.date);
    final draft = ref.watch(diaryDraftProvider(date)).value;
    final data = ref.watch(calendarDataProvider).value;
    final all = data?.entries ?? const <DiaryEntryDto>[];
    final bounds = _bounds();
    final entries = all
        .where(
          (entry) =>
              entry.date.compareTo(bounds.$1) >= 0 &&
              entry.date.compareTo(bounds.$2) <= 0,
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '日记',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Text(
              switch (widget.range) {
                DiaryRange.day => '所选日',
                DiaryRange.week => '本周',
                DiaryRange.month => '本月',
              },
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              date,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        MarkdownDiaryEditor(
          key: ValueKey('desktop-diary-$date'),
          initialText: draft ?? '',
          maxLines: 4,
          onAutoSave: _autosave,
          onPublish: _publish,
        ),
        if (draft != null && draft.trim().isNotEmpty) ...[
          const SizedBox(height: TimeTraceSpace.xxs),
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: scheme.tertiary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: TimeTraceSpace.xs),
              Expanded(
                child: Text(
                  '草稿已自动保存，发布后会进入下方时间线。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: _discardDraft,
                child: const Text('放弃草稿'),
              ),
            ],
          ),
        ],
        if (_staged.isNotEmpty) ...[
          const SizedBox(height: TimeTraceSpace.xs),
          Wrap(
            spacing: TimeTraceSpace.xs,
            runSpacing: TimeTraceSpace.xs,
            children: [
              for (final path in _staged)
                _StagedImage(path: path, onRemove: () => _removeStaged(path)),
            ],
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _pickImages,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
            label: const Text('添加图片'),
          ),
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.lg),
            child: Center(
              child: Text(
                '该范围内暂无日记',
                style: theme.textTheme.bodySmall,
              ),
            ),
          )
        else
          for (final group in _groupByDay(entries))
            _DayTimelineGroup(
              date: group.$1,
              entries: group.$2,
              imageLookup: (id) => data?.entryImages[id] ?? const [],
              collapsed: _collapsedDays.contains(group.$1),
              editingId: _editingId,
              onToggle: () => setState(() {
                if (!_collapsedDays.add(group.$1)) {
                  _collapsedDays.remove(group.$1);
                }
              }),
              onEdit: (id) => setState(
                () => _editingId = _editingId == id ? null : id,
              ),
              onDelete: _delete,
            ),
      ],
    );
  }

  List<(String, List<DiaryEntryDto>)> _groupByDay(List<DiaryEntryDto> entries) {
    final grouped = <String, List<DiaryEntryDto>>{};
    for (final entry in entries) {
      grouped.putIfAbsent(entry.date, () => []).add(entry);
    }
    final dates = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final date in dates) (date, grouped[date]!)];
  }
}

class _StagedImage extends StatelessWidget {
  const _StagedImage({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 58,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton.filledTonal(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 11),
              constraints: const BoxConstraints.tightFor(width: 22, height: 22),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _DayTimelineGroup extends StatelessWidget {
  const _DayTimelineGroup({
    required this.date,
    required this.entries,
    required this.imageLookup,
    required this.collapsed,
    required this.editingId,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final String date;
  final List<DiaryEntryDto> entries;
  final List<String> Function(int id) imageLookup;
  final bool collapsed;
  final int? editingId;
  final VoidCallback onToggle;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: TimeTraceSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Padding(
              padding: const EdgeInsets.only(top: TimeTraceSpace.xxs),
              child: Text(
                date.substring(5),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 18,
            child: Column(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                Container(
                  width: 1,
                  height: collapsed ? 18 : 70,
                  margin: const EdgeInsets.only(top: TimeTraceSpace.xxs),
                  color: scheme.outlineVariant,
                ),
              ],
            ),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: TimeTraceSpace.xs,
                      vertical: TimeTraceSpace.xxs,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${entries.length} 条记录',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          collapsed
                              ? Icons.keyboard_arrow_right_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: TimeTraceMotion.normal,
                  curve: TimeTraceMotion.standard,
                  child: collapsed
                      ? const SizedBox.shrink()
                      : Column(
                          children: [
                            for (final entry in entries)
                              _DiaryDocumentBlock(
                                entry: entry,
                                images: imageLookup(entry.id),
                                editing: editingId == entry.id,
                                onEdit: () => onEdit(entry.id),
                                onDelete: () => onDelete(entry.id),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DiaryDocumentBlock extends ConsumerStatefulWidget {
  const _DiaryDocumentBlock({
    required this.entry,
    required this.images,
    required this.editing,
    required this.onEdit,
    required this.onDelete,
  });

  final DiaryEntryDto entry;
  final List<String> images;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  ConsumerState<_DiaryDocumentBlock> createState() => _DiaryDocumentBlockState();
}

class _DiaryDocumentBlockState extends ConsumerState<_DiaryDocumentBlock> {
  late final TextEditingController _controller;
  List<String> _existingImages = [];
  final List<String> _newImages = [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.entry.content);
    _existingImages = List.of(widget.images);
  }

  @override
  void didUpdateWidget(covariant _DiaryDocumentBlock oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.entry.id != widget.entry.id) {
      _controller.text = widget.entry.content;
      _existingImages = List.of(widget.images);
      _newImages.clear();
      return;
    }

    if (widget.editing && !oldWidget.editing) {
      _controller.text = widget.entry.content;
      _existingImages = List.of(widget.images);
      _newImages.clear();
    } else if (!widget.editing && oldWidget.editing) {
      _existingImages = List.of(widget.images);
      _newImages.clear();
    } else if (!widget.editing && oldWidget.images != widget.images) {
      _existingImages = List.of(widget.images);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _removeImage(String path) async {
    final api = ref.read(apiProvider);
    try {
      api.removeDiaryImage(path: path);
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _existingImages.remove(path);
          _newImages.remove(path);
        });
      }
      ref.invalidate(calendarDataProvider);
    } catch (error) {
      AppLogger.log('remove diary image failed: $error');
    }
  }

  Future<void> _addImages() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;
      PlatformPaths.ensureDiaryImagesDirectory();
      final api = ref.read(apiProvider);

      for (var index = 0; index < result.files.length; index++) {
        final source = result.files[index].path;
        if (source == null) continue;
        final extension = source.split('.').last;
        final name =
            '${widget.entry.date}_${DateTime.now().microsecondsSinceEpoch}_$index.$extension';
        final destination = PlatformPaths.diaryImage(name);
        File(source).copySync(destination);
        api.addDiaryImage(date: widget.entry.date, path: destination);
        _newImages.add(destination);
      }
      if (mounted) setState(() {});
    } catch (error) {
      AppLogger.log('add images to diary post failed: $error');
    }
  }

  Future<void> _cancelEditing() async {
    final api = ref.read(apiProvider);
    for (final path in List<String>.of(_newImages)) {
      try {
        api.removeDiaryImage(path: path);
        try {
          File(path).deleteSync();
        } catch (_) {}
      } catch (error) {
        AppLogger.log('cleanup unsaved diary image failed: $error');
      }
    }
    _newImages.clear();
    _existingImages = List.of(widget.images);
    _controller.text = widget.entry.content;
    if (mounted) {
      setState(() {});
      widget.onEdit();
    }
  }

  Future<void> _save() async {
    final api = ref.read(apiProvider);
    api.updateDiaryEntry(id: widget.entry.id, content: _controller.text);
    for (final path in _newImages) {
      api.setDiaryImageEntry(path: path, entryId: widget.entry.id);
    }
    _newImages.clear();
    ref.invalidate(calendarDataProvider);
    if (mounted) widget.onEdit();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visibleImages = widget.editing
        ? [..._existingImages, ..._newImages]
        : widget.images;

    return AnimatedContainer(
      duration: TimeTraceMotion.fast,
      curve: TimeTraceMotion.standard,
      margin: const EdgeInsets.only(top: TimeTraceSpace.xs),
      padding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.sm,
        TimeTraceSpace.sm,
        TimeTraceSpace.sm,
        TimeTraceSpace.xs,
      ),
      decoration: BoxDecoration(
        color: widget.editing
            ? scheme.primaryContainer.withValues(alpha: 0.28)
            : Colors.transparent,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.editing)
            TextField(
              controller: _controller,
              minLines: 3,
              maxLines: 12,
              decoration: const InputDecoration(hintText: '写点什么…'),
            )
          else if (widget.entry.content.trim().isEmpty)
            Text('(无文字)', style: theme.textTheme.bodySmall)
          else
            MarkdownBody(
              data: widget.entry.content,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                h1: theme.textTheme.titleLarge,
                h2: theme.textTheme.titleMedium,
                h3: theme.textTheme.titleSmall,
                code: theme.textTheme.bodySmall?.copyWith(
                  backgroundColor:
                      scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                ),
              ),
            ),
          if (widget.editing) ...[
            const SizedBox(height: TimeTraceSpace.xs),
            _EditableImageStrip(
              images: visibleImages,
              onRemove: _removeImage,
              onAdd: _addImages,
            ),
          ] else if (visibleImages.isNotEmpty) ...[
            const SizedBox(height: TimeTraceSpace.xs),
            ImageAlbum(
              images: visibleImages,
              title: '${visibleImages.length} 张图片',
            ),
          ],
          const SizedBox(height: TimeTraceSpace.xs),
          Row(
            children: [
              if (widget.editing) ...[
                TextButton(
                  onPressed: widget.onDelete,
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                  child: const Text('删除日记'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => _cancelEditing(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: TimeTraceSpace.xxs),
                FilledButton(onPressed: _save, child: const Text('保存')),
              ] else ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  label: const Text('编辑'),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _EditableImageStrip extends StatelessWidget {
  const _EditableImageStrip({
    required this.images,
    required this.onRemove,
    required this.onAdd,
  });

  final List<String> images;
  final ValueChanged<String> onRemove;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: TimeTraceSpace.xs,
      runSpacing: TimeTraceSpace.xs,
      children: [
        for (final path in images)
          _StagedImage(path: path, onRemove: () => onRemove(path)),
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          child: Container(
            width: 58,
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Icon(
              Icons.add_photo_alternate_outlined,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
