import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Compact Markdown diary editor for desktop.
/// Three explicit modes keep preview optional; draft autosave remains quiet and
/// publish is the only visually prominent action.
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
  final Future<void> Function(String text) onAutoSave;
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
    final ok = sel.isValid &&
        sel.start >= 0 &&
        sel.start <= text.length &&
        sel.end >= 0 &&
        sel.end <= text.length &&
        sel.start < sel.end;
    final start = ok ? sel.start : text.length;
    final end = ok ? sel.end : text.length;
    final selected = ok ? text.substring(start, end) : (placeholder ?? '');
    _ctrl.text = text.replaceRange(start, end, '$prefix$selected$suffix');
    _ctrl.selection = TextSelection.collapsed(
      offset: start + prefix.length + selected.length,
    );
    setState(() {});
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    setState(() {
      _dirty = true;
      _saved = false;
    });
    _saveTimer = Timer(
      const Duration(milliseconds: 900),
      () => _autosave(),
    );
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
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
    );
  }

  Widget _modeButton(
    ColorScheme scheme,
    _EditMode mode,
    IconData icon,
    String tooltip,
  ) {
    final selected = _mode == mode;
    return IconButton(
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      onPressed: () => setState(() => _mode = mode),
      style: IconButton.styleFrom(
        backgroundColor: selected ? scheme.primaryContainer : Colors.transparent,
        foregroundColor:
            selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.small),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canPublish = _ctrl.text.trim().isNotEmpty;

    return AnimatedContainer(
      duration: TimeTraceMotion.fast,
      curve: TimeTraceMotion.standard,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(TimeTraceRadius.card),
        border: Border.all(
          color: _dirty
              ? scheme.primary.withValues(alpha: 0.38)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.xs,
              TimeTraceSpace.xxs,
              TimeTraceSpace.xs,
              TimeTraceSpace.xxs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 0,
                    runSpacing: 0,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _toolbarBtn(
                        Icons.format_bold_rounded,
                        '加粗',
                        () => _apply('**', '**', placeholder: '粗体'),
                      ),
                      _toolbarBtn(
                        Icons.format_italic_rounded,
                        '斜体',
                        () => _apply('*', '*', placeholder: '斜体'),
                      ),
                      _toolbarBtn(
                        Icons.format_strikethrough_rounded,
                        '删除线',
                        () => _apply('~~', '~~', placeholder: '删除'),
                      ),
                      _toolbarBtn(
                        Icons.title_rounded,
                        '标题',
                        () => _apply('## ', '', placeholder: '标题'),
                      ),
                      _toolbarBtn(
                        Icons.format_list_bulleted_rounded,
                        '列表',
                        () => _apply('\n- ', '', placeholder: '项目'),
                      ),
                      _toolbarBtn(
                        Icons.format_quote_rounded,
                        '引用',
                        () => _apply('\n> ', '', placeholder: '引用'),
                      ),
                      _toolbarBtn(
                        Icons.code_rounded,
                        '代码',
                        () => _apply('`', '`', placeholder: '代码'),
                      ),
                      _toolbarBtn(
                        Icons.terminal_rounded,
                        '代码块',
                        () => _apply('\n```\n', '\n```'),
                      ),
                      const SizedBox(width: TimeTraceSpace.xxs),
                      _modeButton(
                        scheme,
                        _EditMode.edit,
                        Icons.edit_outlined,
                        '编辑',
                      ),
                      _modeButton(
                        scheme,
                        _EditMode.split,
                        Icons.vertical_split_rounded,
                        '分屏',
                      ),
                      _modeButton(
                        scheme,
                        _EditMode.preview,
                        Icons.visibility_outlined,
                        '预览',
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: TimeTraceMotion.fast,
                  child: (_dirty || _saved)
                      ? Padding(
                          key: ValueKey(_dirty),
                          padding: const EdgeInsets.symmetric(
                            horizontal: TimeTraceSpace.xs,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _dirty
                                    ? Icons.circle
                                    : Icons.check_circle_outline_rounded,
                                size: _dirty ? 6 : 13,
                                color: _dirty
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: TimeTraceSpace.xxs),
                              Text(
                                _dirty ? '输入中' : '草稿已存',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                FilledButton.icon(
                  onPressed: canPublish ? publish : null,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 15),
                  label: const Text('发布'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: TimeTraceSpace.sm,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          switch (_mode) {
            _EditMode.edit => _editor(scheme),
            _EditMode.preview => _previewPane(scheme),
            _EditMode.split => IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _editor(scheme)),
                    Container(width: 1, color: scheme.outlineVariant),
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
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.all(TimeTraceSpace.sm),
        hintStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
      ),
      style: TextStyle(fontSize: 13, height: 1.6, color: scheme.onSurface),
      onChanged: (_) => _scheduleSave(),
    );
  }

  Widget _previewPane(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      constraints: const BoxConstraints(minHeight: 120),
      child: _ctrl.text.trim().isEmpty
          ? Text(
              widget.placeholder,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            )
          : MarkdownBody(
              data: _ctrl.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(fontSize: 13, height: 1.6, color: scheme.onSurface),
                h1: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                  letterSpacing: -0.25,
                ),
                h2: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                h3: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                code: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface,
                  backgroundColor:
                      scheme.surfaceContainerHighest.withValues(alpha: 0.55),
                ),
                blockquoteDecoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.36),
                  border: Border(
                    left: BorderSide(
                      color: scheme.primary.withValues(alpha: 0.5),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
