import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import '../../domain/diary_entry_metadata.dart';
import 'diary_entry_metadata_controls.dart';
import 'diary_tag_items.dart';
import 'package:flutter/material.dart';

import '../../../../core/material/material.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/widgets/image_album.dart';
import 'package:timetrace_app/src/core/widgets/context_help.dart';
import 'package:timetrace_app/src/core/widgets/markdown_diary_editor.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

/// Injectable picker/copy boundary: tests supply synthetic paths without disk I/O.
typedef DiaryImageImporter =
    Future<List<String>> Function(String date, bool Function() acceptsResult);

final diaryImageImporterProvider = Provider<DiaryImageImporter>((ref) {
  return (date, acceptsResult) async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    // The composer may have been published/discarded while the picker was open.
    if (!acceptsResult() || result == null || result.files.isEmpty) return [];
    final dir = Platform.environment['APPDATA'] ?? '.';
    final separator = Platform.pathSeparator;
    final targetDir = Directory(
      '$dir${separator}TimeTrace${separator}diary_images',
    );
    targetDir.createSync(recursive: true);
    final added = <String>[];
    for (var index = 0; index < result.files.length; index++) {
      if (!acceptsResult()) break;
      final src = result.files[index].path;
      if (src == null) continue;
      final ext = src.split('.').last;
      final dest =
          '${targetDir.path}$separator${date}_${DateTime.now().microsecondsSinceEpoch}_$index.$ext';
      File(src).copySync(dest);
      added.add(dest);
    }
    return added;
  };
});

/// Journal section: 日记 header + Markdown editor + image grid + entries
/// feed for the selected day. Consumes calendarDataProvider directly.
/// Diary time range — driven by the calendar above (not the diary itself).
enum DiaryRange { day, week, month }

/// Journal — 朋友圈-style: each entry is an independent post with its own
/// text + image album. Range comes from the calendar; publish/edit/delete.
class DiarySection extends ConsumerStatefulWidget {
  const DiarySection({
    required this.date,
    this.range = DiaryRange.day,
    super.key,
  });

  /// Anchor date from the calendar — the selected day.
  final DateTime date;

  /// Diary scope, derived from the dashboard range (merged).
  final DiaryRange range;

  @override
  ConsumerState<DiarySection> createState() => _DiarySectionState();
}

class _DiarySectionState extends ConsumerState<DiarySection> {
  int? _editingId; // null = writing a NEW post for the selected day
  bool _composerOpen = false;
  final Set<String> _collapsedDays = {}; // collapsed day groups

  @override
  void didUpdateWidget(covariant DiarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Scope changes return to reading. Drafts remain bound to their original day.
    if (!isSameDayDate(oldWidget.date, widget.date) ||
        oldWidget.range != widget.range) {
      _editingId = null;
      _composerOpen = false;
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
        // 与顶部“本周”一致：周一起算。
        return (f(d.subtract(Duration(days: d.weekday - 1))), f(d));
      case DiaryRange.month:
        return (f(DateTime(d.year, d.month, 1)), f(d));
    }
  }

  Future<void> _uploadImage(DiaryComposerSession session) async {
    final importer = ref.read(diaryImageImporterProvider);
    try {
      final paths = await importer(session.date, () => session.acceptsImages);
      if (!session.acceptsImages) return;
      for (final path in paths) {
        session.addImage(path);
      }
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
    } catch (_) {
      session.error = '图片未添加，请重试';
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
    }
  }

  Future<void> _removeStaged(DiaryComposerSession session, String path) async {
    try {
      if (!session.removeImage(path)) {
        if (mounted && calFmt(widget.date) == session.date) setState(() {});
        return;
      }
      try {
        File(path).deleteSync();
      } catch (_) {}
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
    } catch (_) {
      session.error = '图片未移除，请重试';
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
    }
  }

  void _closeComposer(DiaryComposerSession session) {
    setState(() => _composerOpen = false);
    unawaited(
      session.flush().catchError((Object _) {
        if (mounted && calFmt(widget.date) == session.date) setState(() {});
      }),
    );
  }

  Future<void> _delete(int id) async {
    final capture = MaterialOverlayCapture.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(MaterialTokens.spaceLg),
        child: MaterialTransientPanel(
          capture: capture,
          maxWidth: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('删除这篇日记？', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: MaterialTokens.spaceSm),
              Text('日记及其图片将被删除。'),
              const SizedBox(height: MaterialTokens.spaceMd),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: MaterialTokens.spaceSm,
                children: [
                  MaterialActionButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  MaterialActionButton(
                    role: MaterialActionRole.destructive,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
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
      if (_editingId == id)
        setState(() {
          _editingId = null;
        });
      ref.invalidate(calendarDataProvider);
    } catch (e) {
      AppLogger.log('delete diary entry failed: $e');
    }
  }

  Future<void> _publish(DiaryComposerSession session, String text) async {
    session.updateText(text);
    final operation = session.publish();
    if (mounted && calFmt(widget.date) == session.date) setState(() {});
    try {
      await operation;
      if (mounted && calFmt(widget.date) == session.date) {
        setState(() => _composerOpen = false);
      }
    } catch (_) {
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
      rethrow;
    }
  }

  Future<void> _discardDraft(DiaryComposerSession session) async {
    final capture = MaterialOverlayCapture.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(MaterialTokens.spaceLg),
        child: MaterialTransientPanel(
          capture: capture,
          maxWidth: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('放弃草稿？', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: MaterialTokens.spaceSm),
              Text('${session.date} 的草稿将被放弃。'),
              const SizedBox(height: MaterialTokens.spaceMd),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: MaterialTokens.spaceSm,
                children: [
                  MaterialActionButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  MaterialActionButton(
                    role: MaterialActionRole.destructive,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true ||
        !mounted ||
        session.retired ||
        session.publishing ||
        !session.canEditTags)
      return;
    try {
      await session.discard();
      if (mounted && calFmt(widget.date) == session.date) {
        setState(() => _composerOpen = false);
      }
    } catch (_) {
      if (mounted && calFmt(widget.date) == session.date) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final calendar = ref.watch(calendarDataProvider);
    final data = calendar.value;
    final all = data?.entries ?? const <DiaryEntryDto>[];
    final dateKey = calFmt(widget.date);
    final draft = ref.watch(diaryDraftProvider(dateKey));
    final session = ref.watch(diaryComposerStoreProvider).read(dateKey);
    if (draft is AsyncData<String?>) session.seed(draft.value);
    session.seedImages(data);
    final ready = session.seeded;
    final hasDraft =
        session.text.trim().isNotEmpty ||
        session.staged.isNotEmpty ||
        session.tags.isNotEmpty ||
        session.hasPendingReceipt;
    final composerLabel = _composerOpen ? '收起编辑' : (hasDraft ? '继续草稿' : '写日记');
    final staged = session.staged;
    final bounds = _bounds();
    final inRange = bounds == null
        ? all
        : all
              .where(
                (e) =>
                    e.date.compareTo(bounds.$1) >= 0 &&
                    e.date.compareTo(bounds.$2) <= 0,
              )
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final secondary = constraints.maxWidth >= 380 * scale;
            return Row(
              children: [
                if (secondary) ...[
                  Text(
                    calFmt(widget.date),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(width: 8),
                  Text(switch (widget.range) {
                    DiaryRange.day => '所选日',
                    DiaryRange.week => '近一周',
                    DiaryRange.month => '本月',
                  }, style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  key: const ValueKey('diary-composer-toggle'),
                  tooltip: composerLabel,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: !ready || session.publishing
                      ? null
                      : () => _composerOpen
                            ? _closeComposer(session)
                            : setState(() => _composerOpen = true),
                  icon: Icon(
                    _composerOpen ? Icons.expand_less : Icons.edit_outlined,
                    size: 18,
                    semanticLabel: composerLabel,
                  ),
                ),
                if (!ready && draft.isLoading)
                  const Flexible(child: Text('草稿加载中')),
                if (session.publishing) const Flexible(child: Text('发布中')),
                if (!ready && draft.hasError)
                  IconButton(
                    tooltip: '重试读取草稿',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () =>
                        ref.invalidate(diaryDraftProvider(dateKey)),
                    icon: const Icon(Icons.refresh),
                  ),
                ContextHelp(
                  message:
                      '${calFmt(widget.date)}，${switch (widget.range) {
                        DiaryRange.day => "所选日",
                        DiaryRange.week => "近一周",
                        DiaryRange.month => "本月",
                      }}。输入会自动保存为草稿；收起后可继续。点击发布后才进入日记列表。',
                ),
              ],
            );
          },
        ),
        if (session.error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  session.error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
              if (!session.retired)
                TextButton(
                  onPressed: () async {
                    try {
                      await session.flush();
                    } catch (_) {}
                    if (mounted && calFmt(widget.date) == session.date)
                      setState(() {});
                  },
                  child: const Text('重试保存'),
                ),
            ],
          ),
        if (session.metadataError != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                session.metadataError!,
                key: const Key('diary-publish-metadata-error'),
                style: TextStyle(color: scheme.error),
              ),
              MaterialActionButton(
                buttonKey: const Key('diary-publish-metadata-retry'),
                onPressed: session.publishing
                    ? null
                    : () async {
                        await session.retryMetadata();
                        if (mounted && calFmt(widget.date) == session.date)
                          setState(() {});
                      },
                child: const Text('重试标签与凭据'),
              ),
            ],
          ),
        if (_composerOpen && ready)
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
                _DraftTagEditor(
                  key: ValueKey(('draft-tags', session.token)),
                  session: session,
                ),
                MarkdownDiaryEditor(
                  key: ValueKey(session.token),
                  initialText: session.text,
                  initiallyDirty: session.dirty,
                  readOnly:
                      session.retired ||
                      session.publishing ||
                      session.tagsBlocked ||
                      session.publishUnknown,
                  maxLines: 4,
                  onDraftChanged: session.updateText,
                  onAutoSave: (_) => session.flush(),
                  onPublish: (text) => _publish(session, text),
                ),
                if (!session.retired)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: session.publishing || !session.canEditTags
                          ? null
                          : () => _discardDraft(session),
                      child: const Text('放弃草稿'),
                    ),
                  ),
                // Staged images for the new post (removable)
                if (staged.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final p in staged)
                        SizedBox(
                          width: 56,
                          height: 56,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(p),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                              Positioned(
                                top: 2,
                                right: 2,
                                child: InkWell(
                                  key: ValueKey('diary-staged-remove-$p'),
                                  onTap: session.acceptsImages
                                      ? () => _removeStaged(session, p)
                                      : null,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.close,
                                      size: 10,
                                      color: Colors.white,
                                    ),
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
                    onPressed: session.acceptsImages
                        ? () => _uploadImage(session)
                        : null,
                    icon: const Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 16,
                    ),
                    tooltip: '添加图片（可多选）',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        // ── Posts — grouped by day, with explicit title reading controls ──
        if (!calendar.hasValue && calendar.isLoading)
          const _DiaryPostsLoadingPreview()
        else if (!calendar.hasValue && calendar.hasError)
          Wrap(
            key: const Key('diary-posts-load-error'),
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: MaterialTokens.spaceSm,
            children: [
              const Text('日记记录未能读取'),
              MaterialActionButton(
                buttonKey: const Key('diary-posts-load-retry'),
                onPressed: () => ref.invalidate(calendarDataProvider),
                child: const Text('重试读取记录'),
              ),
            ],
          )
        else if (inRange.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                '暂无已发布记录',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
          )
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.05, 0),
                end: Offset.zero,
              ).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Column(
              key: ValueKey((dateKey, widget.range)),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in _groupByDay(inRange))
                  _DayGroup(
                    key: ValueKey((dateKey, widget.range, group.$1)),
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
        if (calendar.hasValue && (calendar.isLoading || calendar.hasError))
          Padding(
            key: const Key('diary-posts-refresh-status'),
            padding: const EdgeInsets.only(top: MaterialTokens.spaceSm),
            child: Text(
              calendar.isLoading ? '正在更新记录' : '记录更新失败，保留上次已读取内容',
              style: Theme.of(context).textTheme.bodySmall,
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
    return [for (final d in days) (d, map[d]!)];
  }
}

/// Structural loading only: no fabricated title, source, date or diary content.
class _DiaryPostsLoadingPreview extends StatelessWidget {
  const _DiaryPostsLoadingPreview();

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('diary-posts-loading-preview'),
    label: '正在读取日记记录',
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: MaterialTokens.spaceSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final factor in const [0.7, 0.9, 0.5])
              Padding(
                padding: const EdgeInsets.only(bottom: MaterialTokens.spaceSm),
                child: FractionallySizedBox(
                  widthFactor: factor,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(
                        MaterialTokens.controlRadius,
                      ),
                    ),
                    child: const SizedBox(height: MaterialTokens.spaceMd),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Day group header: date + count, tap to collapse/expand the whole day.
class _DayGroup extends StatelessWidget {
  const _DayGroup({
    super.key,
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
                Icon(
                  Icons.calendar_today_outlined,
                  size: 14,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        dateStr,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        '${posts.length} 条',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ],
                  ),
                ),
                Icon(
                  collapsed
                      ? Icons.keyboard_arrow_right
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: scheme.outline,
                ),
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
                        key: ValueKey(e.id),
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

/// Derives a bounded reading title without building Markdown or changing text.
String _diaryEntryTitle(String content) {
  String plain(String line) {
    final text = line
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
        .replaceAll(RegExp(r'!\[[^\]]*\]\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'!\[[^\]]*\]'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\[[^\]]*\]'), (m) => m[1]!)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[\x60*_~]'), '')
        .replaceFirst(RegExp(r'^(?:>\s*)+'), '')
        .replaceFirst(RegExp(r'^(?:[-+]\s+|\d+[.)]\s+)'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return String.fromCharCodes(text.runes.take(80));
  }

  String? fallback;
  String? fence;
  var fenceLength = 0;
  final lines = content.split(RegExp(r'\r?\n'));
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    final marker = RegExp(r'^[ ]{0,3}(\x60{3,}|~{3,})(.*)$').firstMatch(line);
    if (fence != null) {
      if (marker != null &&
          marker[1]!.startsWith(fence) &&
          marker[1]!.length >= fenceLength &&
          marker[2]!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (marker != null) {
      fence = marker[1]![0];
      fenceLength = marker[1]!.length;
      continue;
    }
    if (RegExp(r'^[ ]{0,3}\[[^\]]+\]:\s*\S').hasMatch(line)) continue;
    final heading = RegExp(
      r'^[ ]{0,3}#{1,6}(?:[ \t]+(.*)|[ \t]*)$',
    ).firstMatch(line);
    if (heading != null) {
      final title = plain(
        (heading[1] ?? '').replaceFirst(RegExp(r'[ \t]+#+[ \t]*$'), ''),
      );
      if (title.isNotEmpty) return title;
      continue;
    }
    final text = plain(line);
    if (text.isEmpty || RegExp(r'^[-=]{3,}$').hasMatch(text)) continue;
    if (index + 1 < lines.length &&
        RegExp(r'^[ ]{0,3}(?:=+|-+)[ \t]*$').hasMatch(lines[index + 1])) {
      return text;
    }
    fallback ??= text;
  }
  return fallback ?? '无文字日记';
}

/// A published title opens reading; independent edit actions preserve its ID.
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
    super.key,
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
  bool _textVisible = false;
  bool _imagesVisible = false;
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
      _textVisible = false;
      _imagesVisible = false;
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
    final id = widget.id;
    final date = widget.dateStr;
    final api = ref.read(apiProvider);
    final importer = ref.read(diaryImageImporterProvider);
    bool acceptsResult() => mounted && widget.id == id && widget.editing;
    try {
      final paths = await importer(date, acceptsResult);
      if (!acceptsResult()) return;
      for (final path in paths) {
        api.addDiaryImage(date: date, path: path);
      }
      setState(() => _newImages = [..._newImages, ...paths]);
      ref.invalidate(calendarDataProvider);
    } catch (_) {
      // The existing edit remains open for retry.
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
    final title = _diaryEntryTitle(widget.content);
    final editing = widget.editing;

    return MaterialCard(
      margin: const EdgeInsets.only(bottom: 8),
      // 扁平化卡片：去掉浮动阴影改用细边框，视觉更干净，编辑态换高亮边框。
      elevation: 0,
      color: editing
          ? widget.scheme.primaryContainer.withValues(alpha: 0.45)
          : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: editing
              ? widget.scheme.primary.withValues(alpha: 0.55)
              : widget.scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Editing and reading are separate, explicit actions.
            if (editing)
              TextField(
                key: ValueKey('diary-post-editor-${widget.id}'),
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
                    fontSize: 12,
                    color: widget.scheme.outline,
                  ),
                ),
                style: const TextStyle(fontSize: 13, height: 1.5),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      key: ValueKey('diary-post-title-semantics-${widget.id}'),
                      button: true,
                      expanded: _textVisible,
                      child: TextButton(
                        key: ValueKey('diary-post-title-${widget.id}'),
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          foregroundColor: widget.scheme.onSurface,
                          minimumSize: const Size(
                            MaterialTokens.spaceXl * 2,
                            MaterialTokens.spaceXl * 2,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: MaterialTokens.spaceXs,
                          ),
                        ),
                        onPressed: () =>
                            setState(() => _textVisible = !_textVisible),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              key: ValueKey(
                                'diary-post-title-text-${widget.id}',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            DiaryEntryMetadataControls(
                              entryKey: DiaryEntryKey(
                                widget.dateStr,
                                widget.id,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      key: ValueKey('diary-post-edit-${widget.id}'),
                      tooltip: '编辑',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: widget.onEdit,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: MenuAnchor(
                      style: materialMenuStyle,
                      menuChildren: [
                        MaterialTransientPanel(
                          capture: MaterialOverlayCapture.of(context),
                          maxWidth: 280,
                          child: Builder(
                            builder: (menuContext) => Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                MaterialActionButton(
                                  buttonKey: ValueKey(
                                    'diary-post-tags-${widget.id}',
                                  ),
                                  onPressed: () {
                                    MenuController.maybeOf(
                                      menuContext,
                                    )?.close();
                                    if (!mounted) return;
                                    unawaited(
                                      showDiaryEntryMetadataEditor(
                                        context,
                                        DiaryEntryKey(
                                          widget.dateStr,
                                          widget.id,
                                        ),
                                      ),
                                    );
                                  },
                                  child: const Text('来源与标签'),
                                ),
                                const SizedBox(height: MaterialTokens.spaceSm),
                                MaterialActionButton(
                                  buttonKey: ValueKey(
                                    'diary-post-delete-${widget.id}',
                                  ),
                                  role: MaterialActionRole.destructive,
                                  onPressed: () {
                                    MenuController.maybeOf(
                                      menuContext,
                                    )?.close();
                                    if (mounted) widget.onDelete();
                                  },
                                  child: const Text('删除'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      builder: (context, controller, child) =>
                          MaterialIconAction(
                            buttonKey: ValueKey('diary-post-more-${widget.id}'),
                            tooltip: '更多操作',
                            icon: const Icon(Icons.more_vert, size: 20),
                            onPressed: () => controller.isOpen
                                ? controller.close()
                                : controller.open(),
                          ),
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: !_textVisible
                    ? const SizedBox.shrink()
                    : widget.content.trim().isEmpty
                    ? Text(
                        '无文字日记',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    : MarkdownBody(
                        key: ValueKey('diary-post-body-${widget.id}'),
                        data: widget.content,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet(
                          p: const TextStyle(fontSize: 13, height: 1.6),
                          h1: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: widget.scheme.onSurface,
                          ),
                          h2: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: widget.scheme.onSurface,
                          ),
                          code: TextStyle(
                            fontSize: 11,
                            color: widget.scheme.primary,
                          ),
                        ),
                      ),
              ),
            ],
            // ── Images: edit = expanded grid with ✕ + add; else 👁 toggle ──
            if (editing || (_textVisible && widget.images.isNotEmpty)) ...[
              const SizedBox(height: 6),
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
                          key: ValueKey('diary-post-album-${widget.id}'),
                          images: widget.images,
                          title: '${widget.images.length} 张图片',
                        )
                      : Text(
                          '图片已隐藏',
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: widget.scheme.outline,
                          ),
                        ),
                ),
            ],
            if (editing || (_textVisible && widget.images.isNotEmpty)) ...[
              // ── Actions ──
              const SizedBox(height: 4),
              Divider(
                height: 1,
                color: widget.scheme.outlineVariant.withValues(alpha: 0.35),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: editing
                    ? Row(
                        children: [
                          IconButton(
                            key: ValueKey('diary-post-delete-${widget.id}'),
                            icon: const Icon(Icons.delete_outline, size: 15),
                            tooltip: '删除',
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.onDelete,
                          ),
                          const Spacer(),
                          // Save/cancel on the RIGHT — same side as ✎
                          TextButton(
                            key: ValueKey('diary-post-cancel-${widget.id}'),
                            onPressed: widget.onEdit, // toggle off
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              '取消',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.tonal(
                            key: ValueKey('diary-post-save-${widget.id}'),
                            onPressed: _save,
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: const Text(
                              '保存',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              _imagesVisible
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 18,
                            ),
                            tooltip: _imagesVisible ? '隐藏图片' : '显示图片',
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            onPressed: () => setState(
                              () => _imagesVisible = !_imagesVisible,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
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
                  child: Image.file(
                    File(p),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: scheme.surfaceContainerHighest,
                      child: const Icon(
                        Icons.broken_image,
                        size: 16,
                        color: Colors.grey,
                      ),
                    ),
                  ),
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
                      child: const Icon(
                        Icons.close,
                        size: 11,
                        color: Colors.white,
                      ),
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
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Icon(Icons.add, size: 22, color: scheme.primary),
          ),
        ),
      ],
    );
  }
}

class DaySummaryPanel extends ConsumerWidget {
  const DaySummaryPanel({
    required this.date,
    required this.state,
    required this.singleDay,
    required this.timezoneAvailable,
  });

  final DateTime date;
  final DashboardState state;
  final bool singleDay;
  final bool timezoneAvailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${date.month}月${date.day}日 · 周${'一二三四五六日'[date.weekday - 1]}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            // 汇总页固定展示当日视图（热力图 + 使用记录），周/月由应用分布页承载。
            Text('使用汇总', style: TextStyle(fontSize: 11, color: scheme.outline)),
          ],
        ),
        const SizedBox(height: 8),
        // 内容区填满剩余高度，超长时内部滚动。
        Expanded(
          child: _DaySummary(
            date: date,
            state: state,
            singleDay: singleDay,
            timezoneAvailable: timezoneAvailable,
          ),
        ),
      ],
    );
  }
}

/// Day view projected from the same accepted accounting snapshot.
class _DaySummary extends ConsumerStatefulWidget {
  const _DaySummary({
    required this.date,
    required this.state,
    required this.singleDay,
    required this.timezoneAvailable,
  });

  final DateTime date;
  final DashboardState state;
  final bool singleDay;
  final bool timezoneAvailable;

  @override
  ConsumerState<_DaySummary> createState() => _DaySummaryState();
}

class _DaySummaryState extends ConsumerState<_DaySummary> {
  bool _showAll = false;

  @override
  void didUpdateWidget(covariant _DaySummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.date.year != oldWidget.date.year ||
        widget.date.month != oldWidget.date.month ||
        widget.date.day != oldWidget.date.day) {
      _showAll = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.singleDay) {
      return Center(
        child: Text(
          '请在日历中选择一天查看当日汇总',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      );
    }
    final h = widget.state.totalActiveSeconds ~/ 3600;
    final m = (widget.state.totalActiveSeconds % 3600) ~/ 60;
    final apps = widget.state.appAttribution;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            StatChip(label: '活跃 ${h}h${m}m', color: scheme.primary),
            StatChip(label: '${apps.length} 应用', color: scheme.tertiary),
          ],
        ),
        const SizedBox(height: 8),
        _HourlyHeatmap(
          date: widget.date,
          hours: widget.state.hours,
          timezoneAvailable: widget.timezoneAvailable,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text(
              '使用记录',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(width: 4),
            ContextHelp(message: '当天应用活跃时长汇总，不含锁屏和空闲时间。'),
          ],
        ),
        const SizedBox(height: 4),
        if (apps.isEmpty)
          Text('当天暂无记录', style: TextStyle(fontSize: 12, color: scheme.outline))
        else
          // 列表占满剩余高度：超过才隐藏，展开后内部滚动。
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const rowH = 24.0;
                // PageView can hand a page unbounded height on some
                // layout passes; never let Infinity reach toInt().
                final maxH = constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : 0.0;
                final fit = (maxH / rowH).floor().clamp(1, apps.length);
                final collapsed = apps.length > fit;
                final hideSome = !_showAll && collapsed;
                final shown = hideSome ? apps.take(fit).toList() : apps;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: [
                          for (final app in shown) _AppAttributionRow(app: app),
                        ],
                      ),
                    ),
                    if (collapsed)
                      Center(
                        child: TextButton(
                          onPressed: () => setState(() => _showAll = !_showAll),
                          child: Text(_showAll ? '收起' : '全部 ${apps.length} 应用'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

class _AppAttributionRow extends StatelessWidget {
  const _AppAttributionRow({required this.app});

  final AttributionTotalDto app;

  @override
  Widget build(BuildContext context) {
    final seconds = app.seconds.toInt();
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final dur = h > 0 ? '${h}h${m}m' : '${m}m';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: appColor(app.id),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              app.id,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text(
            dur,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

/// Diary editor (full-width, below calendar) — Material 3 style.
class _HourlyHeatmap extends ConsumerWidget {
  const _HourlyHeatmap({
    required this.date,
    required this.hours,
    required this.timezoneAvailable,
  });

  final DateTime date;
  final List<LocalHourBucketDto> hours;
  final bool timezoneAvailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    if (!timezoneAvailable) {
      return Text(
        '系统时区不可用，无法显示本地小时',
        style: TextStyle(fontSize: 11, color: scheme.outline),
      );
    }
    if (hours.isEmpty) {
      return Text(
        '当日小时数据暂不可用',
        style: TextStyle(fontSize: 11, color: scheme.outline),
      );
    }
    final max = hours
        .map((h) => h.totals.activeSeconds.toInt())
        .reduce((a, b) => a > b ? a : b)
        .clamp(1, 1 << 62);
    bool repeated(LocalHourBucketDto bucket) =>
        hours.where((h) => h.localHour == bucket.localHour).length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '当日活跃时段',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(width: 4),
            ContextHelp(message: '本地日的活跃分布，夏令时日可能有 23 或 25 个小时桶。'),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 30,
          child: Row(
            children: [
              for (var i = 0; i < hours.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 1),
                    child: Tooltip(
                      message:
                          '${hourBucketLabel(hours[i], repeated: repeated(hours[i]))} · ${formatDuration(hours[i].totals.activeSeconds.toInt())}',
                      child: GestureDetector(
                        // 联动：点击热力条→时段分布页选中该小时。
                        onTap: hours[i].totals.activeSeconds.toInt() > 0
                            ? () => ref
                                  .read(hourlyFocusProvider.notifier)
                                  .focus(date, hours[i])
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            color: hours[i].totals.activeSeconds.toInt() == 0
                                ? scheme.surfaceContainerHighest
                                : scheme.primary.withValues(
                                    alpha:
                                        0.2 +
                                        0.8 *
                                            (hours[i].totals.activeSeconds
                                                    .toInt() /
                                                max),
                                  ),
                            borderRadius: BorderRadius.circular(2),
                          ),
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
            for (var i = 0; i < hours.length; i++)
              Expanded(
                child: Text(
                  i % 4 == 0
                      ? hourBucketLabel(
                          hours[i],
                          repeated: repeated(hours[i]),
                          compact: true,
                        )
                      : '',
                  style: TextStyle(fontSize: 8, color: scheme.outline),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _DraftTagEditor extends StatefulWidget {
  const _DraftTagEditor({required this.session, super.key});
  final DiaryComposerSession session;
  @override
  State<_DraftTagEditor> createState() => _DraftTagEditorState();
}

class _DraftTagEditorState extends State<_DraftTagEditor> {
  final _input = TextEditingController();
  String? _invalid;
  bool _working = false;
  @override
  void initState() {
    super.initState();
    unawaited(
      widget.session.ensureTagsLoaded().then((_) {
        if (mounted) setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _set(List<String> values) async {
    final session = widget.session;
    if (_working || !session.canEditTags || !session.tagsLoaded) return;
    setState(() => _working = true);
    try {
      await session.setTags(values);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _add() async {
    final session = widget.session;
    if (_working || !session.canEditTags || !session.tagsLoaded) return;
    try {
      final value = _input.text.trim();
      if (value.isEmpty) return;
      if (session.tags.contains(value)) throw const FormatException('标签已存在');
      final tags = normalizedDiaryTags([...session.tags, value]);
      _input.clear();
      setState(() => _invalid = null);
      await _set(tags);
    } on FormatException catch (error) {
      if (mounted) setState(() => _invalid = error.message.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final editable = session.tagsLoaded && session.canEditTags && !_working;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DiaryTagItems(
          tags: session.tags,
          onRemove: editable
              ? (tag) => _set(session.tags.where((v) => v != tag).toList())
              : null,
        ),
        if (!session.tagsLoaded) const Text('正在读取草稿标签'),
        if (!session.retired)
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('diary-draft-tag-input'),
                  controller: _input,
                  enabled: editable,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: '添加标签',
                    errorText: _invalid,
                    errorMaxLines: 3,
                  ),
                ),
              ),
              MaterialIconAction(
                buttonKey: const Key('diary-draft-tag-add'),
                tooltip: '添加标签',
                icon: const Icon(Icons.add, size: 20),
                onPressed: editable ? _add : null,
              ),
              ContextHelp(message: 'Enter 添加标签；最多8个，每个1–20字符，按添加顺序保存。'),
            ],
          ),
        if (session.tagsError != null)
          Text(
            session.tagsError!,
            key: const Key('diary-draft-tags-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (session.tagsError != null || session.tagsDirty)
          Align(
            alignment: Alignment.centerRight,
            child: MaterialActionButton(
              buttonKey: const Key('diary-draft-tags-retry'),
              onPressed: _working
                  ? null
                  : () async {
                      if (session.tagsBlocked)
                        await session.reloadTags();
                      else
                        await session.retryTags();
                      if (mounted) setState(() {});
                    },
              child: Text(session.tagsBlocked ? '重试读取核对' : '重试保存标签'),
            ),
          ),
      ],
    );
  }
}
