import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Markdown diary editor, UI modeled after open-source editors (Typora/StackEdit):
/// three explicit modes via a segmented control — 编辑 / 分屏 / 预览.
/// Preview is therefore an OPTION, not forced.
/// Debounced auto-save → onAutoSave (draft); explicit 发布 → onPublish.
class MarkdownDiaryEditor extends StatefulWidget {
  const MarkdownDiaryEditor({
    required this.initialText,
    required this.onAutoSave,
    required this.onPublish,
    this.placeholder = '写下今天做了什么…（支持 Markdown）',
    this.maxLines = 6,
    super.key,
  });

  final String initialText;

  /// Called by the debounce after typing pauses — saves a DRAFT.
  final Future<void> Function(String text) onAutoSave;

  /// Called by the 发布 button — publishes (draft → published).
  final Future<void> Function(String text) onPublish;
  final String placeholder;
  final int maxLines;

  @override
  State<MarkdownDiaryEditor> createState() => _MarkdownDiaryEditorState();
}

enum _EditMode { edit, split, preview }

class _MarkdownDiaryEditorState extends State<MarkdownDiaryEditor> {
  late TextEditingController _ctrl;
  bool _dirty = false;
  Timer? _saveTimer;
  bool _saved = false;
  _EditMode _mode = _EditMode.edit;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialText);
  }

  @override
  void didUpdateWidget(covariant MarkdownDiaryEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only sync when the external text changes AND the editor is empty —
    // never mid-typing (avoids refresh resetting the input).
    if (oldWidget.initialText != widget.initialText &&
        _ctrl.text.trim().isEmpty) {
      _ctrl.text = widget.initialText;
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _apply(String prefix, String suffix, {String? placeholder}) {
    final sel = _ctrl.selection;
    final text = _ctrl.text;
    // Selection may be invalid (-1) when the field was never focused —
    // fall back to appending at the end instead of crashing.
    final ok = sel.isValid &&
        sel.start >= 0 &&
        sel.start <= text.length &&
        sel.end >= 0 &&
        sel.end <= text.length &&
        sel.start < sel.end;
    final start = ok ? sel.start : text.length;
    final end = ok ? sel.end : text.length;
    final selected = ok ? text.substring(start, end) : (placeholder ?? '');
    final newText =
        text.replaceRange(start, end, '$prefix$selected$suffix');
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(
        offset: start + prefix.length + selected.length);
    setState(() {});
    _scheduleSave();
  }

  /// Debounced auto-save: saves a DRAFT after typing pauses.
  void _scheduleSave() {
    _saveTimer?.cancel();
    setState(() {
      _dirty = true;
      _saved = false;
    });
    _saveTimer = Timer(const Duration(milliseconds: 900), () => _autosave());
  }

  Future<void> _autosave() async {
    _saveTimer?.cancel();
    try {
      await widget.onAutoSave(_ctrl.text);
      if (mounted) {
        setState(() {
          _dirty = false;
          _saved = true;
        });
      }
    } catch (e) {
      AppLogger.log('diary draft save failed: $e');
    }
  }

  /// Explicit publish (发布 button) — draft becomes published.
  Future<void> publish() async {
    _saveTimer?.cancel();
    try {
      await widget.onPublish(_ctrl.text);
      if (mounted) {
        setState(() {
          _dirty = false;
          _saved = true;
        });
      }
    } catch (e) {
      AppLogger.log('diary publish failed: $e');
    }
  }

  Widget _toolbarBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(
      icon: Icon(icon, size: 17),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toolbar — two rows so the status/publish never crowd the buttons:
          // row 1 = format buttons (wrap), row 2 = mode switch + status + 发布
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Row 1: format buttons
                Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _toolbarBtn(Icons.format_bold, '加粗',
                        () => _apply('**', '**', placeholder: '粗体')),
                    _toolbarBtn(Icons.format_italic, '斜体',
                        () => _apply('*', '*', placeholder: '斜体')),
                    _toolbarBtn(Icons.format_strikethrough, '删除线',
                        () => _apply('~~', '~~', placeholder: '删除')),
                    _toolbarBtn(Icons.title, '标题',
                        () => _apply('## ', '', placeholder: '标题')),
                    _toolbarBtn(Icons.format_list_bulleted, '列表',
                        () => _apply('\n- ', '', placeholder: '项目')),
                    _toolbarBtn(Icons.format_quote, '引用',
                        () => _apply('\n> ', '', placeholder: '引用')),
                    _toolbarBtn(Icons.code, '代码',
                        () => _apply('`', '`', placeholder: '代码')),
                    _toolbarBtn(Icons.terminal, '代码块',
                        () => _apply('\n```\n', '\n```')),
                  ],
                ),
                // Row 2: mode switch + status + publish (VS Code corner style)
                Row(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, con) {
                          final compact = con.maxWidth < 420;
                          return SegmentedButton<_EditMode>(
                            segments: [
                              ButtonSegment(
                                  value: _EditMode.edit,
                                  icon: const Icon(Icons.edit_outlined,
                                      size: 13),
                                  label: compact
                                      ? null
                                      : const Text('编辑',
                                          style: TextStyle(fontSize: 10))),
                              ButtonSegment(
                                  value: _EditMode.split,
                                  icon: const Icon(Icons.vertical_split,
                                      size: 13),
                                  label: compact
                                      ? null
                                      : const Text('分屏',
                                          style: TextStyle(fontSize: 10))),
                              ButtonSegment(
                                  value: _EditMode.preview,
                                  icon: const Icon(Icons.visibility_outlined,
                                      size: 13),
                                  label: compact
                                      ? null
                                      : const Text('预览',
                                          style: TextStyle(fontSize: 10))),
                            ],
                            selected: {_mode},
                            onSelectionChanged: (s) =>
                                setState(() => _mode = s.first),
                            showSelectedIcon: false,
                            style: ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: WidgetStatePropertyAll(
                                  const EdgeInsets.symmetric(horizontal: 6)),
                            ),
                          );
                        },
                      ),
                    ),
                    // Save status (compact chip — no overlap with 发布)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: _dirty
                            ? scheme.surfaceContainerHighest
                            : scheme.primaryContainer.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _dirty ? '输入中' : (_saved ? '✓ 草稿已存' : ''),
                        style: TextStyle(
                            fontSize: 9,
                            color: _dirty
                                ? scheme.outline
                                : scheme.onPrimaryContainer),
                      ),
                    ),
                    // ── 发布 ──
                    FilledButton.tonalIcon(
                      onPressed: () => publish(),
                      icon: const Icon(Icons.publish, size: 14),
                      label: const Text('发布', style: TextStyle(fontSize: 11)),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Body by mode ──
          switch (_mode) {
            _EditMode.edit => _editor(scheme),
            _EditMode.preview => _previewPane(scheme),
            _EditMode.split => IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _editor(scheme)),
                    Container(
                      width: 1,
                      color: scheme.outlineVariant.withValues(alpha: 0.6),
                    ),
                    Expanded(child: _previewPane(scheme)),
                  ],
                ),
              ),
          },
        ],
      ),
    );
  }

  Widget _editor(ColorScheme scheme) {
    return TextField(
      controller: _ctrl,
      maxLines: widget.maxLines,
      minLines: 4,
      decoration: InputDecoration(
        hintText: widget.placeholder,
        border: InputBorder.none,
        contentPadding: const EdgeInsets.all(10),
        hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
      ),
      style: const TextStyle(fontSize: 13, height: 1.6),
      onChanged: (_) => _scheduleSave(),
    );
  }

  Widget _previewPane(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(10),
      constraints: const BoxConstraints(minHeight: 120),
      child: _ctrl.text.trim().isEmpty
          ? Text(widget.placeholder,
              style: TextStyle(fontSize: 13, color: scheme.outline))
          : MarkdownBody(
              data: _ctrl.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 13, height: 1.6),
                h1: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface),
                h2: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface),
                h3: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface),
                code: TextStyle(fontSize: 11, color: scheme.primary),
                blockquoteDecoration: BoxDecoration(
                  color: scheme.secondaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
    );
  }
}
