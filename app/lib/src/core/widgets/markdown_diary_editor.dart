import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Markdown diary editor (Typora-like): toolbar + text input + preview toggle.
/// Encapsulated as a reusable component.
class MarkdownDiaryEditor extends StatefulWidget {
  const MarkdownDiaryEditor({
    required this.initialText,
    required this.onSave,
    this.placeholder = '写下今天做了什么…（支持 Markdown）',
    this.maxLines = 6,
    super.key,
  });

  final String initialText;
  final Future<void> Function(String text) onSave;
  final String placeholder;
  final int maxLines;

  @override
  State<MarkdownDiaryEditor> createState() => _MarkdownDiaryEditorState();
}

class _MarkdownDiaryEditorState extends State<MarkdownDiaryEditor> {
  late TextEditingController _ctrl;
  bool _dirty = false;
  bool _preview = false;

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
    _ctrl.dispose();
    super.dispose();
  }

  void _apply(String prefix, String suffix, {String? placeholder}) {
    final sel = _ctrl.selection;
    final text = _ctrl.text;
    final selected = sel.isValid && sel.start < sel.end
        ? text.substring(sel.start, sel.end)
        : (placeholder ?? '');
    final newText = text.replaceRange(
        sel.start, sel.end, '$prefix$selected$suffix');
    _ctrl.text = newText;
    _ctrl.selection = TextSelection.collapsed(
        offset: sel.start + prefix.length + selected.length);
    _dirty = true;
    setState(() {});
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
          // Toolbar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _toolbarBtn(Icons.format_bold, '加粗', () => _apply('**', '**', placeholder: '粗体')),
                _toolbarBtn(Icons.format_italic, '斜体', () => _apply('*', '*', placeholder: '斜体')),
                _toolbarBtn(Icons.format_strikethrough, '删除线', () => _apply('~~', '~~', placeholder: '删除')),
                _toolbarBtn(Icons.title, '标题', () => _apply('## ', '', placeholder: '标题')),
                _toolbarBtn(Icons.format_list_bulleted, '列表', () => _apply('\n- ', '', placeholder: '项目')),
                _toolbarBtn(Icons.format_quote, '引用', () => _apply('\n> ', '', placeholder: '引用')),
                _toolbarBtn(Icons.code, '代码', () => _apply('`', '`', placeholder: '代码')),
                _toolbarBtn(Icons.terminal, '代码块', () => _apply('\n```\n', '\n```')),
                const SizedBox(width: 4),
                // Preview toggle
                IconButton(
                  icon: Icon(_preview ? Icons.edit_outlined : Icons.visibility_outlined, size: 17),
                  tooltip: _preview ? '编辑' : '预览',
                  onPressed: () => setState(() => _preview = !_preview),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Editor or Preview
          if (_preview)
            Container(
              padding: const EdgeInsets.all(10),
              height: 140,
              child: _ctrl.text.trim().isEmpty
                  ? Text(widget.placeholder,
                      style: TextStyle(fontSize: 13, color: scheme.outline))
                  : MarkdownBody(
                      data: _ctrl.text,
                      selectable: true,
                    ),
            )
          else
            TextField(
              controller: _ctrl,
              maxLines: widget.maxLines,
              minLines: 3,
              decoration: InputDecoration(
                hintText: widget.placeholder,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(10),
                hintStyle: TextStyle(fontSize: 13, color: scheme.outline),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: (_) => setState(() => _dirty = true),
            ),
        ],
      ),
    );
  }

  /// Save current text. Returns success.
  Future<bool> save() async {
    try {
      await widget.onSave(_ctrl.text);
      _dirty = false;
      return true;
    } catch (e) {
      AppLogger.log('diary save failed: $e');
      return false;
    }
  }
}
