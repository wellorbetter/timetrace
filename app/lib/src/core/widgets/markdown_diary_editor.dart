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

  /// Unboxed mode icons (编辑/分屏/预览) — the selected one is highlighted.
  List<Widget> _modeIcons(ColorScheme scheme) {
    Widget item(_EditMode m, IconData icon, String tip) => IconButton(
          icon: Icon(icon, size: 16),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _mode = m),
          style: IconButton.styleFrom(
            backgroundColor: _mode == m
                ? scheme.primaryContainer
                : Colors.transparent,
            foregroundColor: _mode == m
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        );
    return [
      item(_EditMode.edit, Icons.edit_outlined, '编辑'),
      item(_EditMode.split, Icons.vertical_split, '分屏'),
      item(_EditMode.preview, Icons.visibility_outlined, '预览'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toolbar: format/mode on the left, draft-status + 发布 pinned right.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left: format buttons (wrap) + unboxed mode icons
                Expanded(
                  child: Wrap(
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
                      const SizedBox(width: 4),
                      // Mode switch — no box; selected icon highlighted.
                      ..._modeIcons(scheme),
                    ],
                  ),
                ),
                // Right: draft status (bigger text) + 发布
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _dirty
                        ? scheme.surfaceContainerHighest
                        : scheme.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _dirty ? '输入中' : (_saved ? '✓ 草稿已存' : ''),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _dirty
                            ? scheme.outline
                            : scheme.onPrimaryContainer),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: _ctrl.text.trim().isEmpty ? null : publish,
                  icon: const Icon(Icons.publish, size: 16),
                  tooltip:
                      _ctrl.text.trim().isEmpty ? '先写点什么再发布' : '发布',
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  padding: EdgeInsets.zero,
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
