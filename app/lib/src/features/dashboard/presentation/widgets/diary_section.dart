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
import 'package:timetrace_app/src/features/recap/domain/ai_diary_models.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

enum DiaryRange { day, week, month }

/// Main-dashboard diary, enhanced with an optional AI writing action.
///
/// The visual and interaction model intentionally follows the original diary:
/// one editor surface followed by collapsible day groups of independent posts.
/// AI is only another way to create a post; it does not replace the diary UI.
class DiarySection extends ConsumerStatefulWidget {
  const DiarySection({
    required this.date,
    this.range = DiaryRange.day,
    this.onContentChanged,
    super.key,
  });

  final DateTime date;
  final DiaryRange range;
  final VoidCallback? onContentChanged;

  @override
  ConsumerState<DiarySection> createState() => _DiarySectionState();
}

class _DiarySectionState extends ConsumerState<DiarySection> {
  int? _editingId;
  List<String> _staged = [];
  final Set<String> _collapsedDays = {};
  int _aiRequestToken = 0;
  bool _isAiGenerating = false;
  AiDiaryGenerationOutcome? _aiOutcome;
  String? _aiOutcomeDate;

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
    if (!_sameDay(oldWidget.date, widget.date) ||
        oldWidget.range != widget.range) {
      // AI feedback belongs to the date that started the request. Invalidating
      // the token also prevents a late Future from painting onto a new date.
      _aiRequestToken++;
      _isAiGenerating = false;
      _aiOutcome = null;
      _aiOutcomeDate = null;
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
        setState(
          () => _staged = _staged.where((item) => item != path).toList(),
        );
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
    widget.onContentChanged?.call();
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
      widget.onContentChanged?.call();
    } catch (error) {
      AppLogger.log('delete diary entry failed: $error');
    }
  }

  bool _isCurrentAiRequest(int token, String date, DiaryRange range) =>
      mounted &&
      token == _aiRequestToken &&
      date == calFmt(widget.date) &&
      range == widget.range;

  Future<void> _generateAiDiary({bool allowDuplicate = false}) async {
    if (widget.range != DiaryRange.day || _isAiGenerating) return;

    final requestDate = calFmt(widget.date);
    final requestRange = widget.range;
    final requestToken = ++_aiRequestToken;
    setState(() {
      _isAiGenerating = true;
      _aiOutcome = null;
      _aiOutcomeDate = requestDate;
    });

    AiDiaryGenerationOutcome outcome;
    try {
      outcome = await ref
          .read(aiDiaryGenerationProvider.notifier)
          .generateForDate(widget.date, allowDuplicate: allowDuplicate);
    } catch (error) {
      AppLogger.log('AI diary generation failed: $error');
      outcome = const AiDiaryGenerationOutcome(
        status: AiDiaryGenerationStatus.failed,
        message: '日记未能生成，可以稍后重试。',
      );
    }

    if (!_isCurrentAiRequest(requestToken, requestDate, requestRange)) return;
    if (!mounted) return;

    if (outcome.status == AiDiaryGenerationStatus.duplicate &&
        !allowDuplicate) {
      setState(() {
        _isAiGenerating = false;
        _aiOutcome = null;
      });
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('这一天已有 AI 日记'),
          content: const Text('再次生成会新增一篇，不会覆盖已有内容。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续生成'),
            ),
          ],
        ),
      );
      if (!_isCurrentAiRequest(requestToken, requestDate, requestRange)) {
        return;
      }
      if (confirmed == true) {
        await _generateAiDiary(allowDuplicate: true);
      }
      return;
    }

    setState(() {
      _isAiGenerating = false;
      _aiOutcome = outcome;
      _aiOutcomeDate = requestDate;
    });

    if (!outcome.isSuccess) return;
    if (!mounted) return;

    ref.invalidate(calendarDataProvider);
    ref.invalidate(diaryDraftProvider(requestDate));
    widget.onContentChanged?.call();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('AI 日记已生成并发布')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final date = calFmt(widget.date);
    final draft = ref.watch(diaryDraftProvider(date)).value;
    final data = ref.watch(calendarDataProvider).value;
    final aiSettings = ref.watch(recapAiSettingsProvider).value;
    final showAiAction =
        widget.range == DiaryRange.day &&
        aiSettings != null &&
        aiSettings.isConfigured;
    final visibleAiOutcome = _aiOutcomeDate == date ? _aiOutcome : null;
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
            Icon(Icons.edit_note_rounded, size: 16, color: scheme.primary),
            const SizedBox(width: TimeTraceSpace.xs),
            Text(
              '日记',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            if (showAiAction) ...[
              const SizedBox(width: TimeTraceSpace.sm),
              TextButton.icon(
                key: const ValueKey('ai-diary-generate'),
                onPressed: _isAiGenerating ? null : _generateAiDiary,
                icon: _isAiGenerating
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(Icons.auto_awesome_outlined, size: 15),
                label: Text(_isAiGenerating ? '正在写…' : 'AI 写今日日记'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: scheme.primaryContainer,
                  padding: const EdgeInsets.symmetric(
                    horizontal: TimeTraceSpace.sm,
                    vertical: TimeTraceSpace.xxs,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
            const Spacer(),
            Text(
              date,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: TimeTraceSpace.xs,
                vertical: TimeTraceSpace.xxs,
              ),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(TimeTraceRadius.control),
              ),
              child: Text(
                switch (widget.range) {
                  DiaryRange.day => '所选日',
                  DiaryRange.week => '近一周',
                  DiaryRange.month => '本月',
                },
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
        if (showAiAction && _isAiGenerating) ...[
          const SizedBox(height: TimeTraceSpace.xxs),
          Text(
            '正在根据当天使用记录整理日记…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ] else if (showAiAction &&
            visibleAiOutcome != null &&
            !visibleAiOutcome.isSuccess) ...[
          const SizedBox(height: TimeTraceSpace.xxs),
          _AiDiaryInlineFeedback(
            message: visibleAiOutcome.message ?? '日记未能生成。',
            canRetry: visibleAiOutcome.shouldRetry,
            onRetry: _generateAiDiary,
          ),
        ],
        const SizedBox(height: TimeTraceSpace.sm),
        Container(
          key: const ValueKey('diary-editor-surface'),
          padding: const EdgeInsets.all(TimeTraceSpace.xs),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(TimeTraceRadius.card),
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
                key: ValueKey('diary-$date'),
                initialText: draft ?? '',
                maxLines: 4,
                onAutoSave: _autosave,
                onPublish: _publish,
              ),
              if (_editingId == null &&
                  draft != null &&
                  draft.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: TimeTraceSpace.xxs),
                  child: Row(
                    children: [
                      Container(
                        key: const ValueKey('diary-draft-badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: TimeTraceSpace.xs,
                          vertical: TimeTraceSpace.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(
                            TimeTraceRadius.control,
                          ),
                        ),
                        child: Text(
                          '草稿',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onTertiaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: TimeTraceSpace.sm),
                      Expanded(
                        child: Text(
                          '已自动保存，发布后才会出现在日记列表',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _discardDraft,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('放弃草稿'),
                      ),
                    ],
                  ),
                ),
              if (_staged.isNotEmpty) ...[
                const SizedBox(height: TimeTraceSpace.sm),
                Wrap(
                  spacing: TimeTraceSpace.sm,
                  runSpacing: TimeTraceSpace.sm,
                  children: [
                    for (final path in _staged)
                      _StagedImage(
                        path: path,
                        onRemove: () => _removeStaged(path),
                      ),
                  ],
                ),
              ],
              IconButton(
                key: const ValueKey('diary-add-images'),
                onPressed: _pickImages,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                tooltip: '添加图片（可多选）',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.lg),
            child: Center(
              child: Text('该范围内暂无日记', style: theme.textTheme.bodySmall),
            ),
          )
        else
          AnimatedSwitcher(
            duration: TimeTraceMotion.normal,
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.05, 0),
                end: Offset.zero,
              ).animate(animation),
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Column(
              key: ValueKey(
                'posts-${entries.map((entry) => entry.id).join(',')}',
              ),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in _groupByDay(entries))
                  _DayGroup(
                    date: group.$1,
                    entries: group.$2,
                    imageLookup: (id) =>
                        data?.entryImages[id] ?? const <String>[],
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
                    onContentChanged: widget.onContentChanged,
                  ),
              ],
            ),
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

class _AiDiaryInlineFeedback extends StatelessWidget {
  const _AiDiaryInlineFeedback({
    required this.message,
    required this.canRetry,
    required this.onRetry,
  });

  final String message;
  final bool canRetry;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.info_outline_rounded, size: 14, color: scheme.error),
        const SizedBox(width: TimeTraceSpace.xs),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (canRetry)
          TextButton(
            key: const ValueKey('ai-diary-retry'),
            onPressed: onRetry,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('重试'),
          ),
      ],
    );
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

class _DayGroup extends StatelessWidget {
  const _DayGroup({
    required this.date,
    required this.entries,
    required this.imageLookup,
    required this.collapsed,
    required this.editingId,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    this.onContentChanged,
  });

  final String date;
  final List<DiaryEntryDto> entries;
  final List<String> Function(int id) imageLookup;
  final bool collapsed;
  final int? editingId;
  final VoidCallback onToggle;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;
  final VoidCallback? onContentChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      key: ValueKey('diary-day-$date'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('diary-day-toggle-$date'),
          onTap: onToggle,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
            child: Row(
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  size: 14,
                  color: scheme.primary,
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Text(
                  date,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Text(
                  '${entries.length} 条',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Icon(
                  collapsed
                      ? Icons.keyboard_arrow_right_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: TimeTraceMotion.normal,
          curve: Curves.easeOut,
          child: collapsed
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    for (final entry in entries)
                      _PostCard(
                        entry: entry,
                        images: imageLookup(entry.id),
                        editing: editingId == entry.id,
                        onEdit: () => onEdit(entry.id),
                        onDelete: () => onDelete(entry.id),
                        onContentChanged: onContentChanged,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _PostCard extends ConsumerStatefulWidget {
  const _PostCard({
    required this.entry,
    required this.images,
    required this.editing,
    required this.onEdit,
    required this.onDelete,
    this.onContentChanged,
  });

  final DiaryEntryDto entry;
  final List<String> images;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onContentChanged;

  @override
  ConsumerState<_PostCard> createState() => _PostCardState();
}

class _PostCardState extends ConsumerState<_PostCard> {
  bool _textVisible = true;
  bool _imagesVisible = true;
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
  void didUpdateWidget(covariant _PostCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.entry.id != widget.entry.id) {
      _textVisible = true;
      _imagesVisible = true;
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
    widget.onContentChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final firstLine = widget.entry.content
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    final visibleImages = widget.editing
        ? [..._existingImages, ..._newImages]
        : widget.images;
    final provenance = _DiaryProvenance.fromEntry(widget.entry);

    return Card(
      key: ValueKey('diary-post-${widget.entry.id}'),
      margin: const EdgeInsets.only(bottom: TimeTraceSpace.sm),
      elevation: 0,
      color: widget.editing
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TimeTraceRadius.card),
        side: BorderSide(
          color: widget.editing
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          TimeTraceSpace.sm,
          TimeTraceSpace.sm,
          TimeTraceSpace.sm,
          TimeTraceSpace.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (provenance != null) ...[
              _DiaryProvenanceBadge(provenance: provenance),
              const SizedBox(height: TimeTraceSpace.xs),
            ],
            if (widget.editing)
              TextField(
                controller: _controller,
                minLines: 2,
                maxLines: 10,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.all(TimeTraceSpace.sm),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                      TimeTraceRadius.control,
                    ),
                  ),
                  hintText: '写点什么…',
                ),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              )
            else
              AnimatedSize(
                duration: TimeTraceMotion.fast,
                curve: Curves.easeOut,
                child: _textVisible
                    ? (widget.entry.content.trim().isEmpty
                          ? Text('(无文字)', style: theme.textTheme.bodySmall)
                          : MarkdownBody(
                              data: widget.entry.content,
                              selectable: true,
                              styleSheet: MarkdownStyleSheet(
                                p: theme.textTheme.bodyMedium?.copyWith(
                                  height: 1.6,
                                ),
                                h1: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                                h2: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                                code: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ))
                    : Text(
                        firstLine.isEmpty ? '内容已隐藏' : '内容已隐藏 · $firstLine',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
            if (visibleImages.isNotEmpty || widget.editing) ...[
              const SizedBox(height: TimeTraceSpace.xs),
              if (widget.editing)
                _EditableImageStrip(
                  images: visibleImages,
                  onRemove: _removeImage,
                  onAdd: _addImages,
                )
              else
                AnimatedSize(
                  duration: TimeTraceMotion.normal,
                  curve: Curves.easeOut,
                  child: _imagesVisible
                      ? ImageAlbum(
                          images: visibleImages,
                          title: '${visibleImages.length} 张图片',
                        )
                      : Text(
                          '图片已隐藏',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                ),
            ],
            const SizedBox(height: TimeTraceSpace.xs),
            Divider(
              height: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
            Padding(
              padding: const EdgeInsets.only(top: TimeTraceSpace.xxs),
              child: widget.editing
                  ? Row(
                      children: [
                        IconButton(
                          key: ValueKey('diary-delete-${widget.entry.id}'),
                          icon: const Icon(Icons.delete_outline, size: 15),
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onDelete,
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _cancelEditing,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: TimeTraceSpace.xxs),
                        FilledButton.tonal(
                          onPressed: _save,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: TimeTraceSpace.md,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('保存'),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton(
                          key: ValueKey(
                            'diary-text-visibility-${widget.entry.id}',
                          ),
                          icon: Icon(
                            _textVisible
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 16,
                          ),
                          tooltip: _textVisible ? '隐藏文字' : '显示文字',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _textVisible = !_textVisible),
                        ),
                        if (widget.images.isNotEmpty)
                          IconButton(
                            key: ValueKey(
                              'diary-image-visibility-${widget.entry.id}',
                            ),
                            icon: Icon(
                              _imagesVisible
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 16,
                            ),
                            tooltip: _imagesVisible ? '隐藏图片' : '显示图片',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => setState(
                              () => _imagesVisible = !_imagesVisible,
                            ),
                          ),
                        const Spacer(),
                        IconButton(
                          key: ValueKey('diary-edit-${widget.entry.id}'),
                          icon: const Icon(Icons.edit_outlined, size: 15),
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onEdit,
                        ),
                        IconButton(
                          key: ValueKey('diary-delete-${widget.entry.id}'),
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

class _DiaryProvenance {
  const _DiaryProvenance({required this.label, this.model});

  final String label;
  final String? model;

  static _DiaryProvenance? fromEntry(DiaryEntryDto entry) {
    final label = switch (entry.source) {
      'ai_generated' => 'AI 生成',
      'ai_assisted' => 'AI 辅助',
      _ => null,
    };
    if (label == null) return null;
    final model = entry.sourceModel?.trim();
    return _DiaryProvenance(
      label: label,
      model: model == null || model.isEmpty ? null : model,
    );
  }
}

class _DiaryProvenanceBadge extends StatelessWidget {
  const _DiaryProvenanceBadge({required this.provenance});

  final _DiaryProvenance provenance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = provenance.model == null
        ? provenance.label
        : '${provenance.label} · ${provenance.model}';

    return Chip(
      avatar: Icon(Icons.auto_awesome_rounded, size: 13, color: scheme.primary),
      label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      labelStyle: theme.textTheme.labelSmall?.copyWith(
        color: scheme.primary,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xxs),
      labelPadding: const EdgeInsets.only(right: TimeTraceSpace.xxs),
      side: BorderSide(color: scheme.primary.withValues(alpha: 0.12)),
      backgroundColor: scheme.primaryContainer.withValues(alpha: 0.55),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
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
