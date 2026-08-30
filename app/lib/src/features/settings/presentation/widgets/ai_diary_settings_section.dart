import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';

typedef AiDiarySettingsConnectionTest =
    Future<String?> Function(RecapAiSettings settings);
typedef AiDiarySettingsSave = Future<void> Function(RecapAiSettings settings);

class AiDiarySettingsSection extends StatefulWidget {
  const AiDiarySettingsSection({
    super.key,
    required this.initial,
    required this.defaultPrompt,
    required this.onSave,
    required this.onTestConnection,
    this.environment,
    this.platform,
  });

  final RecapAiSettings initial;
  final String defaultPrompt;
  final AiDiarySettingsSave onSave;
  final AiDiarySettingsConnectionTest onTestConnection;
  final Map<String, String>? environment;
  final String? platform;

  @override
  State<AiDiarySettingsSection> createState() => _AiDiarySettingsSectionState();
}

class _AiDiarySettingsSectionState extends State<AiDiarySettingsSection> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _endpoint;
  late final TextEditingController _model;
  late final TextEditingController _keyEnvironment;
  late final TextEditingController _prompt;
  late bool _enabled;
  late bool _includeDiaryEntries;
  late bool _includeHabitReflection;
  late bool _includeImprovementSuggestion;
  late bool _automaticGenerationEnabled;
  late int _automaticGenerationTimeMinutes;
  bool _dirty = false;
  bool _saving = false;
  bool _testing = false;
  bool? _testSucceeded;
  String? _feedback;

  Map<String, String> get _environment =>
      widget.environment ?? Platform.environment;
  String get _platform => widget.platform ?? Platform.operatingSystem;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _endpoint = TextEditingController(text: initial.endpoint);
    _model = TextEditingController(text: initial.model);
    _keyEnvironment = TextEditingController(text: initial.apiKeyEnv);
    _prompt = TextEditingController(text: initial.customPrompt);
    for (final controller in [_endpoint, _model, _keyEnvironment, _prompt]) {
      controller.addListener(_markDirty);
    }
    _enabled = initial.enabled;
    _includeDiaryEntries = initial.includeDiaryEntries;
    _includeHabitReflection = initial.includeHabitReflection;
    _includeImprovementSuggestion = initial.includeImprovementSuggestion;
    _automaticGenerationEnabled = initial.automaticGenerationEnabled;
    _automaticGenerationTimeMinutes = initial.automaticGenerationTimeMinutes
        .clamp(0, 1439);
  }

  @override
  void dispose() {
    for (final controller in [_endpoint, _model, _keyEnvironment, _prompt]) {
      controller
        ..removeListener(_markDirty)
        ..dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!mounted || _dirty) return;
    setState(() {
      _dirty = true;
      _feedback = null;
      _testSucceeded = null;
    });
  }

  void _change(VoidCallback update) {
    setState(() {
      _dirty = true;
      _feedback = null;
      _testSucceeded = null;
      update();
    });
  }

  RecapAiSettings get _value => widget.initial.copyWith(
    enabled: _enabled,
    endpoint: _endpoint.text.trim(),
    model: _model.text.trim(),
    apiKeyEnv: _keyEnvironment.text.trim(),
    includeDiaryEntries: _includeDiaryEntries,
    customPrompt: _prompt.text.trim(),
    includeHabitReflection: _includeHabitReflection,
    includeImprovementSuggestion: _includeImprovementSuggestion,
    automaticGenerationEnabled: _automaticGenerationEnabled,
    automaticGenerationTimeMinutes: _automaticGenerationTimeMinutes,
  );

  bool get _hasApiKey {
    final variable = _keyEnvironment.text.trim();
    return variable.isNotEmpty &&
        (_environment[variable]?.trim().isNotEmpty ?? false);
  }

  bool get _credentialReady =>
      _keyEnvironment.text.trim().isEmpty || _hasApiKey;

  _AiProvider get _provider => _endpoint.text.contains('api.deepseek.com')
      ? _AiProvider.deepSeek
      : _AiProvider.compatible;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Form(
      key: _formKey,
      child: Column(
        key: const ValueKey('ai-diary-settings-inline'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('ai-diary-enabled-switch'),
            secondary: Icon(
              _enabled
                  ? Icons.auto_awesome_rounded
                  : Icons.lock_outline_rounded,
              color: colors.primary,
            ),
            title: const Text('启用 AI 日记'),
            subtitle: Text(
              _enabled
                  ? 'AI 根据当天真实使用记录协助写日记；生成内容会标注来源。'
                  : '关闭时无需 API Key，也不会向模型服务发送使用记录或日记。',
            ),
            value: _enabled,
            onChanged: (value) => _change(() => _enabled = value),
          ),
          if (!_enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TimeTraceSpace.sm,
                0,
                TimeTraceSpace.sm,
                TimeTraceSpace.sm,
              ),
              child: _Notice(
                key: const ValueKey('ai-diary-disabled-notice'),
                icon: Icons.shield_outlined,
                text: '手写日记保持完整可用。只有你主动开启并保存后，AI 功能才会生效。',
              ),
            )
          else ...[
            const _SectionDivider(),
            _InlineSection(
              icon: Icons.cloud_outlined,
              title: '模型服务',
              subtitle: '支持 DeepSeek 与 OpenAI-compatible Chat Completions 接口。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<_AiProvider>(
                    key: ValueKey('ai-diary-provider-${_provider.name}'),
                    initialValue: _provider,
                    decoration: const InputDecoration(
                      labelText: '服务类型',
                      prefixIcon: Icon(Icons.hub_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: _AiProvider.deepSeek,
                        child: Text('DeepSeek'),
                      ),
                      DropdownMenuItem(
                        value: _AiProvider.compatible,
                        child: Text('OpenAI-compatible'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) _selectProvider(value);
                    },
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 580;
                      final endpoint = TextFormField(
                        key: const ValueKey('ai-diary-endpoint'),
                        controller: _endpoint,
                        decoration: const InputDecoration(
                          labelText: 'Endpoint',
                          helperText: 'Chat Completions 地址',
                        ),
                        validator: _validateEndpoint,
                      );
                      final model = TextFormField(
                        key: const ValueKey('ai-diary-model'),
                        controller: _model,
                        decoration: const InputDecoration(
                          labelText: '模型',
                          helperText: '例如 deepseek-v4-flash',
                        ),
                        validator: (value) =>
                            value?.trim().isEmpty ?? true ? '请输入模型名称' : null,
                      );
                      if (compact) {
                        return Column(
                          children: [
                            endpoint,
                            const SizedBox(height: TimeTraceSpace.sm),
                            model,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: endpoint),
                          const SizedBox(width: TimeTraceSpace.sm),
                          Expanded(flex: 2, child: model),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  _CredentialGuide(
                    controller: _keyEnvironment,
                    hasApiKey: _hasApiKey,
                    platform: _platform,
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  _ConnectionCheck(
                    testing: _testing,
                    enabled: !_testing && _credentialReady,
                    succeeded: _testSucceeded,
                    message: _testSucceeded == null ? null : _feedback,
                    onPressed: _testConnection,
                  ),
                ],
              ),
            ),
            const _SectionDivider(),
            _InlineSection(
              icon: Icons.edit_note_rounded,
              title: '写作方式',
              subtitle: '自定义语气与结构；事实约束和隐私边界不会被覆盖。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const ValueKey('ai-diary-custom-prompt'),
                    controller: _prompt,
                    minLines: 4,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: '自定义写作要求',
                      alignLabelWithHint: true,
                      helperText: '只决定日记的语气、篇幅和关注重点。',
                    ),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? '请填写写作要求，或恢复默认提示词'
                        : null,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('ai-diary-reset-prompt'),
                      onPressed: _resetPrompt,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('恢复默认提示词'),
                    ),
                  ),
                  _CompactToggle(
                    key: const ValueKey('ai-diary-habit-reflection'),
                    title: '包含习惯反思',
                    subtitle: '有充分记录时，简短反思时间使用习惯。',
                    value: _includeHabitReflection,
                    onChanged: (value) =>
                        _change(() => _includeHabitReflection = value),
                  ),
                  _CompactToggle(
                    key: const ValueKey('ai-diary-improvement-suggestion'),
                    title: '包含改进建议',
                    subtitle: '最多给出一条有事实依据、可以执行的温和建议。',
                    value: _includeImprovementSuggestion,
                    onChanged: (value) =>
                        _change(() => _includeImprovementSuggestion = value),
                  ),
                  _CompactToggle(
                    key: const ValueKey('ai-diary-include-existing'),
                    title: '允许参考已有日记',
                    subtitle: '默认关闭；开启后，已发布日记可能随使用事实发送给模型。',
                    value: _includeDiaryEntries,
                    onChanged: (value) =>
                        _change(() => _includeDiaryEntries = value),
                  ),
                ],
              ),
            ),
            const _SectionDivider(),
            _InlineSection(
              icon: Icons.schedule_outlined,
              title: '生成方式',
              subtitle: '手动生成始终由你触发；也可在每天指定时间自动写入。',
              child: Column(
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.touch_app_outlined),
                    title: Text('手动生成'),
                    subtitle: Text('在概览的日记区域点击“AI 写今日日记”。'),
                    trailing: _StatusPill(label: '始终可用'),
                  ),
                  const Divider(height: 1),
                  _CompactToggle(
                    key: const ValueKey('ai-diary-auto-generation'),
                    title: '每日自动生成',
                    subtitle: '应用在系统托盘运行时仍会执行；错过时间会在当天恢复后补执行。',
                    value: _automaticGenerationEnabled,
                    onChanged: (value) =>
                        _change(() => _automaticGenerationEnabled = value),
                  ),
                  if (_automaticGenerationEnabled)
                    ListTile(
                      key: const ValueKey('ai-diary-auto-time'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.alarm_outlined),
                      title: const Text('自动生成时间'),
                      subtitle: const Text('按电脑当前本地时间，每个日期最多自动生成一次。'),
                      trailing: OutlinedButton.icon(
                        onPressed: _pickAutomaticTime,
                        icon: const Icon(Icons.schedule_rounded, size: 17),
                        label: Text(_formattedAutomaticTime),
                      ),
                    ),
                ],
              ),
            ),
            const _SectionDivider(),
            const Padding(
              padding: EdgeInsets.all(TimeTraceSpace.sm),
              child: _Notice(
                icon: Icons.privacy_tip_outlined,
                text: '连接测试不会发送 TimeTrace 数据。生成时仅发送所选日期的必要使用事实，以及你明确允许参考的日记文字。',
              ),
            ),
          ],
          _SaveBar(
            dirty: _dirty,
            saving: _saving,
            succeeded: _feedback == '设置已保存',
            message: _testSucceeded == null ? _feedback : null,
            onSave: _save,
          ),
        ],
      ),
    );
  }

  String? _validateEndpoint(String? value) {
    final raw = value?.trim() ?? '';
    final uri = Uri.tryParse(raw);
    if (raw.isEmpty || uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return '请输入完整的 HTTP(S) Endpoint';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'Endpoint 仅支持 HTTP 或 HTTPS';
    }
    return null;
  }

  void _selectProvider(_AiProvider provider) {
    _change(() {
      if (provider == _AiProvider.deepSeek) {
        _endpoint.text = 'https://api.deepseek.com/chat/completions';
        if (_model.text.trim().isEmpty || _model.text == 'custom-model') {
          _model.text = 'deepseek-v4-flash';
        }
        if (_keyEnvironment.text.trim().isEmpty) {
          _keyEnvironment.text = 'DEEPSEEK_API_KEY';
        }
      } else {
        _endpoint.text = 'https://api.openai.com/v1/chat/completions';
        _model.text = 'gpt-4.1-mini';
        _keyEnvironment.text = 'OPENAI_API_KEY';
      }
    });
  }

  void _resetPrompt() {
    _prompt.text = widget.defaultPrompt;
    _markDirty();
  }

  Future<void> _pickAutomaticTime() async {
    final initial = TimeOfDay(
      hour: _automaticGenerationTimeMinutes ~/ 60,
      minute: _automaticGenerationTimeMinutes % 60,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    _change(
      () => _automaticGenerationTimeMinutes = picked.hour * 60 + picked.minute,
    );
  }

  String get _formattedAutomaticTime {
    final hour = (_automaticGenerationTimeMinutes ~/ 60).toString().padLeft(
      2,
      '0',
    );
    final minute = (_automaticGenerationTimeMinutes % 60).toString().padLeft(
      2,
      '0',
    );
    return '$hour:$minute';
  }

  Future<void> _testConnection() async {
    if (_testing || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _testSucceeded = null;
      _feedback = null;
    });
    final error = await widget.onTestConnection(_value);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSucceeded = error == null;
      _feedback = error ?? '连接成功，可以生成 AI 日记。';
    });
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _feedback = null;
      _testSucceeded = null;
    });
    try {
      await widget.onSave(_value);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _feedback = '设置已保存';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _feedback = '保存失败，请重试。';
      });
    }
  }
}

enum _AiProvider { deepSeek, compatible }

class _InlineSection extends StatelessWidget {
  const _InlineSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(TimeTraceSpace.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        child,
      ],
    ),
  );
}

class _CompactToggle extends StatelessWidget {
  const _CompactToggle({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );
}

class _CredentialGuide extends StatelessWidget {
  const _CredentialGuide({
    required this.controller,
    required this.hasApiKey,
    required this.platform,
  });

  final TextEditingController controller;
  final bool hasApiKey;
  final String platform;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final variable = controller.text.trim().isEmpty
        ? 'DEEPSEEK_API_KEY'
        : controller.text.trim();
    final command = platform == 'windows'
        ? 'setx $variable "sk-..."'
        : 'export $variable="sk-..."';
    return Material(
      key: const ValueKey('ai-diary-credential-section'),
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: TextFormField(
              key: const ValueKey('ai-diary-key-env'),
              controller: controller,
              decoration: InputDecoration(
                labelText: 'API Key 环境变量',
                helperText: '只保存变量名，不保存密钥内容。',
                prefixIcon: const Icon(Icons.terminal_outlined),
                suffixIcon: Tooltip(
                  message: hasApiKey ? '已检测到环境变量' : '尚未检测到环境变量',
                  child: Icon(
                    hasApiKey
                        ? Icons.check_circle_outline
                        : Icons.key_off_outlined,
                    color: hasApiKey ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          ExpansionTile(
            key: const ValueKey('ai-diary-key-guide'),
            initiallyExpanded: !hasApiKey,
            leading: const Icon(Icons.route_outlined),
            title: Text(hasApiKey ? '更换 API Key' : 'API Key 配置引导'),
            subtitle: const Text('写入系统环境变量后，完全退出并重启 TimeTrace。'),
            childrenPadding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.sm,
              0,
              TimeTraceSpace.sm,
              TimeTraceSpace.sm,
            ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '在服务商控制台创建专用 Key，然后运行：',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: TimeTraceSpace.xs),
              Container(
                padding: const EdgeInsets.only(left: TimeTraceSpace.sm),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        command,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                    ),
                    IconButton(
                      tooltip: '复制命令',
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: command));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('命令已复制')));
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionCheck extends StatelessWidget {
  const _ConnectionCheck({
    required this.testing,
    required this.enabled,
    required this.succeeded,
    required this.message,
    required this.onPressed,
  });

  final bool testing;
  final bool enabled;
  final bool? succeeded;
  final String? message;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        succeeded == true
            ? Icons.check_circle_outline
            : succeeded == false
            ? Icons.error_outline
            : Icons.wifi_tethering_outlined,
        color: succeeded == false ? colors.error : colors.primary,
      ),
      title: const Text('连接检查'),
      subtitle: Text(message ?? '只验证模型服务，不发送使用记录或日记正文。'),
      trailing: OutlinedButton.icon(
        key: const ValueKey('ai-diary-test-connection'),
        onPressed: enabled ? onPressed : null,
        icon: testing
            ? const SizedBox.square(
                dimension: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_tethering_outlined, size: 17),
        label: Text(testing ? '测试中…' : '测试连接'),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.dirty,
    required this.saving,
    required this.succeeded,
    required this.message,
    required this.onSave,
  });

  final bool dirty;
  final bool saving;
  final bool succeeded;
  final String? message;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(TimeTraceSpace.sm),
    child: Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: Text(
              message ??
                  (dirty
                      ? '有尚未保存的更改'
                      : succeeded
                      ? '设置已保存'
                      : ''),
              key: ValueKey('$dirty-$succeeded-$message'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        FilledButton.icon(
          key: const ValueKey('ai-diary-save-settings'),
          onPressed: saving || !dirty ? null : onSave,
          icon: saving
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded, size: 18),
          label: Text(saving ? '保存中…' : '保存 AI 日记设置'),
        ),
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: colors.onSecondaryContainer),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: TimeTraceSpace.sm,
    endIndent: TimeTraceSpace.sm,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}
