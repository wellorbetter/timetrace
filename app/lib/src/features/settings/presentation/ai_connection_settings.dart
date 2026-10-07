import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/material/material.dart';
import '../../../core/preferences/ui_preferences_controller.dart';
import '../../../core/widgets/context_help.dart';
import '../../browsing/providers/ai_connection_provider.dart';

class AiConnectionSettings extends ConsumerStatefulWidget {
  const AiConnectionSettings({this.onDraftStatusChanged, this.isSectionExpanded = true, super.key});
  final void Function({required bool dirty, required bool invalid, required bool pending})? onDraftStatusChanged;
  final bool isSectionExpanded;
  @override
  ConsumerState<AiConnectionSettings> createState() =>
      _AiConnectionSettingsState();
}

class _AiConnectionSettingsState extends ConsumerState<AiConnectionSettings> {
  final _input = TextEditingController();
  final _menu = MenuController();
  final _focus = FocusNode();
  bool _hidden = true, _busy = false, _failed = false, _failedClear = false;
  String? _feedback;

  bool _statusQueued = false;
  ({bool dirty, bool invalid, bool pending})? _reportedStatus;
  void _scheduleDraftStatus() {
    if (widget.onDraftStatusChanged == null || _statusQueued) return;
    _statusQueued = true;
    // Coalesce actual events; never call a parent from build or expose values.
    scheduleMicrotask(() {
      _statusQueued = false;
      if (!mounted) return;
      final next = (dirty: _input.text.isNotEmpty, invalid: _failed, pending: _busy);
      if (_reportedStatus == next) return;
      _reportedStatus = next;
      widget.onDraftStatusChanged?.call(
        dirty: next.dirty, invalid: next.invalid, pending: next.pending);
    });
  }

  @override
  void initState() { super.initState(); _input.addListener(_scheduleDraftStatus); }

  @override
  void didUpdateWidget(AiConnectionSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSectionExpanded && !widget.isSectionExpanded) {
      scheduleMicrotask(() {
        if (mounted && !widget.isSectionExpanded) _menu.close();
      });
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _changeKey({bool clear = false}) async {
    if (_busy) return;
    final submitted = _input.text;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    _scheduleDraftStatus();
    try {
      final notifier = ref.read(savedDeepSeekKeyProvider.notifier);
      if (clear) {
        await notifier.clear();
      } else {
        await notifier.save(submitted);
      }
      if (!mounted) return;
      if (_input.text == submitted) _input.clear();
      setState(() {
        _hidden = true;
        _failed = false;
        _feedback = clear ? '已清除手动 Key' : '已保存；生成时验证连接';
      });
    } on AiConnectionFailure catch (error) {
      if (mounted)
        setState(() {
          _failed = true;
          _failedClear = clear;
          _feedback = error.message;
        });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scheduleDraftStatus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedDeepSeekKeyProvider);
    final hasSaved = saved.asData?.value.isNotEmpty == true;
    final hasEnvironment = ref.watch(deepSeekEnvironmentKeyProvider).isNotEmpty;
    final ready = !saved.isLoading && !_busy;
    final model = ref.watch(deepSeekModelProvider);
    final capture = MaterialOverlayCapture.of(context);
    final source = saved.isLoading
        ? '正在读取配置…'
        : hasSaved
        ? '使用已保存 Key'
        : hasEnvironment
        ? '使用环境 Key'
        : '未配置 Key';
    return Padding(
      padding: const EdgeInsets.all(MaterialTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * .35,
                  ),
                  child: MenuAnchor(
                    controller: _menu,
                    childFocusNode: _focus,
                    style: materialMenuStyle,
                    onClose: () {
                      if (mounted && widget.isSectionExpanded) _focus.requestFocus();
                    },
                    menuChildren: [
                      MaterialTransientPanel(
                        capture: capture,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(source, key: const Key('ai_key_source')),
                            const Text('模型'),
                            for (final value in {
                              'deepseek-flash',
                              'deepseek-v4-pro',
                              model,
                            })
                              MenuItemButton(
                                onPressed: ready
                                    ? () {
                                        _menu.close();
                                        ref
                                            .read(
                                              deepSeekModelProvider.notifier,
                                            )
                                            .setModel(value);
                                      }
                                    : null,
                                trailingIcon: value == model
                                    ? const Icon(Icons.check, size: 18)
                                    : null,
                                child: Text(value),
                              ),
                            if (hasSaved)
                              MenuItemButton(
                                key: const Key('ai_clear_key'),
                                onPressed: ready
                                    ? () {
                                        _menu.close();
                                        _changeKey(clear: true);
                                      }
                                    : null,
                                child: const Text('清除手动 Key'),
                              ),
                            if (saved.hasError)
                              MenuItemButton(
                                onPressed: !_busy
                                    ? () {
                                        _menu.close();
                                        ref.invalidate(
                                          savedDeepSeekKeyProvider,
                                        );
                                      }
                                    : null,
                                child: const Text('重新读取'),
                              ),
                          ],
                        ),
                      ),
                    ],
                    builder: (context, controller, _) => TextButton(
                      key: const Key('ai_provider_details'),
                      focusNode: _focus,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.only(right: 8),
                      ),
                      onPressed: () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
                      child: const Text(
                        'DeepSeek',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('ai_api_key_input'),
                    controller: _input,
                    enabled: ready,
                    obscureText: _hidden,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: InputDecoration(
                      hintText: hasSaved ? '替换 Key' : 'API Key',
                      border: const UnderlineInputBorder(),
                      suffixIcon: IconButton(
                        key: const Key('ai_key_visibility'),
                        tooltip: _hidden ? '显示输入内容' : '隐藏输入内容',
                        onPressed: ready
                            ? () => setState(() => _hidden = !_hidden)
                            : null,
                        icon: Icon(
                          _hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    onSubmitted: ready ? (_) => _changeKey() : null,
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('启用 AI 生成'),
              Switch(
                key: const Key('ai_enabled'),
                value: ref.watch(aiEnabledProvider),
                onChanged: ready
                    ? ref.read(aiEnabledProvider.notifier).setEnabled
                    : null,
              ),
              const ContextHelp(
                message:
                    '在右侧粘贴 API Key 后按 Enter，保存到系统安全存储，不写入普通配置。点击 DeepSeek 查看 Key 来源、模型或清除手动 Key。手动 Key 优先于 DEEPSEEK_API_KEY；清除后使用环境来源。Windows 用户环境变量设置 DEEPSEEK_API_KEY 后须重启应用以继承；环境来源在 provider 首次读取时获取，不显示其值，也不填入输入框。启用 AI 是独立偏好，不选择 Key 来源。保存不联网，不表示连接已验证。仅用户确认生成时发送应用名称、时长与小时分布摘要，不发送窗口标题、日记或原始记录。',
              ),
            ],
          ),
          const UiPreferencesFeedback('aiEnabled'),
          const UiPreferencesFeedback('aiModel'),
          if (_feedback != null || saved.hasError)
            Text(
              _feedback ?? '安全存储读取失败；点击 DeepSeek 可重新读取',
              key: const Key('ai_key_feedback'),
              style: TextStyle(
                color: _failed || saved.hasError
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          if (_failed)
            TextButton(
              key: const Key('ai_save_key'),
              onPressed: ready ? () => _changeKey(clear: _failedClear) : null,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
