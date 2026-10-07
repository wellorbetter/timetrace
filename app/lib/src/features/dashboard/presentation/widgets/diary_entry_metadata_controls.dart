import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/material/material.dart';
import '../../../../core/widgets/context_help.dart';
import '../../../browsing/providers/diary_generation_provider.dart';
import '../../domain/diary_entry_metadata.dart';
import '../../providers/diary_entry_metadata_provider.dart';
import 'diary_tag_items.dart';

/// Inline, noninteractive provenance. The existing More menu owns tag editing.
class DiaryEntryMetadataControls extends ConsumerWidget {
  const DiaryEntryMetadataControls({required this.entryKey, super.key});
  final DiaryEntryKey entryKey;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(diaryEntryMetadataProvider(entryKey));
    final assets = ref.watch(diaryCandidatesProvider);
    final source = diaryEntrySource(entryKey, view, assets.items.values);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                source.label,
                key: ValueKey('diary-metadata-source-${entryKey.entryId}'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (view.error != null || view.dirty)
              Tooltip(
                message: view.error ?? '元数据尚未保存',
                child: Icon(
                  Icons.error_outline,
                  size: 16,
                  semanticLabel: '元数据尚未保存',
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
          ],
        ),
        if (view.value.tags.isNotEmpty) DiaryTagItems(tags: view.value.tags),
      ],
    );
  }
}

Future<void> showDiaryEntryMetadataEditor(
  BuildContext context,
  DiaryEntryKey key,
) {
  final capture = MaterialOverlayCapture.of(context);
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(MaterialTokens.spaceLg),
      child: MaterialTransientPanel(
        capture: capture,
        maxWidth: 440,
        child: DiaryEntryMetadataEditor(entryKey: key),
      ),
    ),
  );
}

class DiaryEntryMetadataEditor extends ConsumerStatefulWidget {
  const DiaryEntryMetadataEditor({required this.entryKey, super.key});
  final DiaryEntryKey entryKey;
  @override
  ConsumerState<DiaryEntryMetadataEditor> createState() =>
      _DiaryEntryMetadataEditorState();
}

class _DiaryEntryMetadataEditorState
    extends ConsumerState<DiaryEntryMetadataEditor> {
  final _input = TextEditingController();
  bool _seeded = false, _saving = false;
  String? _invalid;
  List<String> _tags = [];
  void _addTag() {
    final view = ref.read(diaryEntryMetadataProvider(widget.entryKey));
    if (_saving || !view.loaded || view.loading || view.blocked) return;
    try {
      final value = _input.text.trim();
      if (value.isEmpty) return;
      final tags = normalizedDiaryTags([..._tags, value]);
      if (_tags.contains(value)) throw const FormatException('标签已存在');
      setState(() {
        _tags = tags;
        _input.clear();
        _invalid = null;
      });
    } on FormatException catch (e) {
      setState(() => _invalid = e.message.toString());
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final raw = _input.text.trim();
    try {
      final tags = raw.isEmpty
          ? _tags
          : normalizedDiaryTags([..._tags, ...raw.split(RegExp('[,，]'))]);
      setState(() {
        _saving = true;
        _invalid = null;
      });
      final saved = await ref
          .read(diaryEntryMetadataProvider(widget.entryKey).notifier)
          .setTags(tags);
      if (!mounted) return;
      setState(() => _saving = false);
      if (saved) Navigator.pop(context);
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _invalid = error.message.toString();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(diaryEntryMetadataProvider(widget.entryKey));
    final assets = ref.watch(diaryCandidatesProvider);
    final source = diaryEntrySource(widget.entryKey, view, assets.items.values);
    if (!_seeded && view.loaded) {
      _tags = view.value.tags;
      _input.clear();
      _seeded = true;
    }
    return SingleChildScrollView(
      key: ValueKey('diary-metadata-panel-${widget.entryKey.entryId}'),
      primary: false,
      padding: const EdgeInsets.all(MaterialTokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('来源与标签', style: Theme.of(context).textTheme.titleMedium),
          Text(source.label),
          DiaryTagItems(
            tags: _tags,
            onRemove: view.loaded && !view.loading && !view.blocked && !_saving
                ? (tag) => setState(
                    () => _tags = normalizedDiaryTags(
                      _tags.where((v) => v != tag),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: MaterialTokens.spaceSm),
          TextField(
            key: const Key('diary_metadata_tags_input'),
            controller: _input,
            enabled: view.loaded && !view.loading && !view.blocked && !_saving,
            onSubmitted: (_) => _addTag(),
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: '自定义标签',
              hintText: '输入标签，Enter 添加',
              helperMaxLines: 3,
              errorText: _invalid,
              errorMaxLines: 3,
            ),
          ),
          if (view.error != null)
            Text(
              view.error!,
              key: const Key('diary_metadata_error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (view.loading || !view.loaded) const Text('正在读取元数据…'),
          if (view.blocked)
            TextButton(
              key: const Key('diary_metadata_reload'),
              onPressed: view.loading
                  ? null
                  : () => ref
                        .read(
                          diaryEntryMetadataProvider(widget.entryKey).notifier,
                        )
                        .reload(),
              child: const Text('重试读取'),
            ),
          const Align(
            alignment: Alignment.centerRight,
            child: ContextHelp(message: '最多8个标签，每个1–20字符，按添加顺序保存'),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              MaterialActionButton(
                buttonKey: const Key('diary_metadata_cancel'),
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              MaterialActionButton(
                buttonKey: const Key('diary_metadata_save'),
                role: MaterialActionRole.primary,
                onPressed:
                    view.loaded && !view.loading && !view.blocked && !_saving
                    ? _save
                    : null,
                child: Text(
                  _saving
                      ? '保存中'
                      : view.dirty
                      ? '重试保存元数据'
                      : '保存标签',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
