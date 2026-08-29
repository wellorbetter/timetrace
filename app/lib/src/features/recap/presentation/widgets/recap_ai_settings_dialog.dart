import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';

typedef RecapAiConnectionTest = Future<String?> Function(
  RecapAiSettings settings,
);

/// Contextual AI Recap setup kept out of the app-wide Settings route.
///
/// The dialog reuses the strongest parts of the earlier AI service guide:
/// explicit generation mode, model choice, credential status, a step-by-step
/// environment-variable guide, a privacy boundary and a no-usage-data
/// connection check.
class RecapAiSettingsDialog extends StatefulWidget {
  const RecapAiSettingsDialog({
    super.key,
    required this.initial,
    required this.onTestConnection,
    this.environment,
  });

  final RecapAiSettings initial;
  final RecapAiConnectionTest onTestConnection;
  final Map<String, String>? environment;

  static Future<RecapAiSettings?> show(
    BuildContext context, {
    required RecapAiSettings initial,
    required RecapAiConnectionTest onTestConnection,
  }) => showDialog<RecapAiSettings>(
    context: context,
    builder: (_) => RecapAiSettingsDialog(
      initial: initial,
      onTestConnection: onTestConnection,
    ),
  );

  @override
  State<RecapAiSettingsDialog> createState() => _RecapAiSettingsDialogState();
}

class _RecapAiSettingsDialogState extends State<RecapAiSettingsDialog> {
  late final TextEditingController _endpoint;
  late final TextEditingController _model;
  late final TextEditingController _keyEnv;
  late bool _enabled;
  late bool _includeDiaryEntries;
  bool _testing = false;
  String? _testMessage;
  bool? _testSucceeded;

  Map<String, String> get _environment =>
      widget.environment ?? Platform.environment;

  @override
  void initState() {
    super.initState();
    _endpoint = TextEditingController(text: widget.initial.endpoint);
    _model = TextEditingController(text: widget.initial.model);
    _keyEnv = TextEditingController(text: widget.initial.apiKeyEnv)
      ..addListener(_handleFieldChanged);
    _enabled = widget.initial.enabled;
    _includeDiaryEntries = widget.initial.includeDiaryEntries;
  }

  @override
  void dispose() {
    _keyEnv.removeListener(_handleFieldChanged);
    _endpoint.dispose();
    _model.dispose();
    _keyEnv.dispose();
    super.dispose();
  }

  void _handleFieldChanged() {
    if (mounted) setState(() {});
  }

  RecapAiSettings get _value => RecapAiSettings(
    enabled: _enabled,
    endpoint: _endpoint.text.trim(),
    model: _model.text.trim(),
    apiKeyEnv: _keyEnv.text.trim(),
    includeDiaryEntries: _includeDiaryEntries,
  );

  bool get _hasApiKey {
    final name = _keyEnv.text.trim();
    return name.isNotEmpty && (_environment[name]?.trim().isNotEmpty ?? false);
  }

  _ModelPreset get _preset => switch (_model.text.trim()) {
    'deepseek-v4-flash' => _ModelPreset.flash,
    'deepseek-v4-pro' => _ModelPreset.pro,
    _ => _ModelPreset.custom,
  };

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final colors = Theme.of(context).colorScheme;
    final contentWidth = math.max(
      0.0,
      math.min(700.0, media.width - 80),
    );
    return AlertDialog(
      key: const ValueKey('recap-ai-settings-dialog'),
      insetPadding: const EdgeInsets.all(TimeTraceSpace.md),
      titlePadding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.lg,
        TimeTraceSpace.lg,
        TimeTraceSpace.lg,
        TimeTraceSpace.xs,
      ),
      contentPadding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.lg,
        TimeTraceSpace.xs,
        TimeTraceSpace.lg,
        0,
      ),
      actionsPadding: const EdgeInsets.all(TimeTraceSpace.md),
      title: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.secondaryContainer,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            ),
            child: Icon(
              Icons.auto_awesome_outlined,
              size: 19,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: TimeTraceSpace.sm),
          const Expanded(child: Text('AI Recap 设置')),
        ],
      ),
      content: SizedBox(
        width: contentWidth,
        height: media.height * 0.72,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '配置默认回顾方式。AI 设置只在这里出现，不占用主导航。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: TimeTraceSpace.lg),
              _SectionLabel(title: '生成方式', subtitle: 'AI 总结为默认；本地总结始终作为离线回退。'),
              const SizedBox(height: TimeTraceSpace.xs),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = [
                    _GenerationModeCard(
                      key: const ValueKey('recap-ai-mode-cloud'),
                      icon: Icons.cloud_outlined,
                      title: 'AI 总结',
                      badge: '默认',
                      description: '发送聚合后的应用名与时长，生成更自然的回顾。',
                      selected: _enabled,
                      onTap: () => setState(() => _enabled = true),
                    ),
                    _GenerationModeCard(
                      key: const ValueKey('recap-ai-mode-local'),
                      icon: Icons.offline_bolt_outlined,
                      title: '本地总结',
                      badge: '免费 · 离线',
                      description: '使用固定规则生成事实回顾，数据完全不离开设备。',
                      selected: !_enabled,
                      onTap: () => setState(() => _enabled = false),
                    ),
                  ];
                  if (constraints.maxWidth >= 600) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards.first),
                        const SizedBox(width: TimeTraceSpace.xs),
                        Expanded(child: cards.last),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      cards.first,
                      const SizedBox(height: TimeTraceSpace.xs),
                      cards.last,
                    ],
                  );
                },
              ),
              if (_enabled) ...[
                const SizedBox(height: TimeTraceSpace.lg),
                const _SectionLabel(
                  title: '模型',
                  subtitle: 'Flash 适合日常回顾；Pro 更深入，但生成稍慢。',
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                _ModelSelector(selected: _preset, onSelected: _selectPreset),
                const SizedBox(height: TimeTraceSpace.lg),
                _CredentialSection(
                  environmentController: _keyEnv,
                  hasApiKey: _hasApiKey,
                  platform: Platform.operatingSystem,
                ),
                const SizedBox(height: TimeTraceSpace.sm),
                _ConnectionTestTile(
                  testing: _testing,
                  enabled: !_testing && _hasApiKey,
                  succeeded: _testSucceeded,
                  message: _testMessage,
                  onPressed: _testConnection,
                ),
                const SizedBox(height: TimeTraceSpace.sm),
                _DataScopeTile(
                  includeDiaryEntries: _includeDiaryEntries,
                  onChanged: (value) =>
                      setState(() => _includeDiaryEntries = value),
                ),
                const SizedBox(height: TimeTraceSpace.sm),
                _AdvancedSettings(endpoint: _endpoint, model: _model),
              ] else ...[
                const SizedBox(height: TimeTraceSpace.md),
                _LocalModeNotice(colors: colors),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('recap-ai-save-settings'),
          onPressed: () => Navigator.pop(context, _value),
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _selectPreset(_ModelPreset preset) {
    setState(() {
      switch (preset) {
        case _ModelPreset.flash:
          _endpoint.text = 'https://api.deepseek.com/chat/completions';
          _model.text = 'deepseek-v4-flash';
          if (_keyEnv.text.trim().isEmpty) {
            _keyEnv.text = 'DEEPSEEK_API_KEY';
          }
        case _ModelPreset.pro:
          _endpoint.text = 'https://api.deepseek.com/chat/completions';
          _model.text = 'deepseek-v4-pro';
          if (_keyEnv.text.trim().isEmpty) {
            _keyEnv.text = 'DEEPSEEK_API_KEY';
          }
        case _ModelPreset.custom:
          _model.text = 'custom-model';
      }
    });
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testMessage = null;
      _testSucceeded = null;
    });
    final error = await widget.onTestConnection(_value);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSucceeded = error == null;
      _testMessage = error ?? '连接成功，可以生成 AI 回顾。';
    });
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: TimeTraceSpace.xxs),
      Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );
}

class _GenerationModeCard extends StatelessWidget {
  const _GenerationModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.badge,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String badge;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '生成方式：$title',
      child: Material(
        color: selected
            ? colors.secondaryContainer.withValues(alpha: 0.62)
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primaryContainer
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(
                      TimeTraceRadius.control,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: selected ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              badge,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: TimeTraceSpace.xxs),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: TimeTraceSpace.xs),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 21,
                  color: selected ? colors.primary : colors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _ModelPreset { flash, pro, custom }

class _ModelSelector extends StatelessWidget {
  const _ModelSelector({required this.selected, required this.onSelected});

  final _ModelPreset selected;
  final ValueChanged<_ModelPreset> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final items = [
        (
          _ModelPreset.flash,
          Icons.bolt_outlined,
          'DeepSeek Flash',
          '更快，适合每日回顾',
        ),
        (
          _ModelPreset.pro,
          Icons.psychology_outlined,
          'DeepSeek Pro',
          '更深入，适合周月回顾',
        ),
        (_ModelPreset.custom, Icons.tune_rounded, '兼容模型', '自定义 Endpoint 与模型名'),
      ];
      final cards = [
        for (final item in items)
          _ModelCard(
            key: ValueKey('recap-ai-model-${item.$1.name}'),
            icon: item.$2,
            title: item.$3,
            subtitle: item.$4,
            selected: selected == item.$1,
            onTap: () => onSelected(item.$1),
          ),
      ];
      if (constraints.maxWidth >= 640) {
        return Row(
          children: [
            for (var i = 0; i < cards.length; i++) ...[
              Expanded(child: cards[i]),
              if (i != cards.length - 1)
                const SizedBox(width: TimeTraceSpace.xs),
            ],
          ],
        );
      }
      return Column(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            cards[i],
            if (i != cards.length - 1)
              const SizedBox(height: TimeTraceSpace.xs),
          ],
        ],
      );
    },
  );
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.secondaryContainer.withValues(alpha: 0.54)
          : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(TimeTraceSpace.sm),
          child: Row(
            children: [
              Icon(icon, size: 19, color: colors.primary),
              const SizedBox(width: TimeTraceSpace.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: selected ? colors.primary : colors.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CredentialSection extends StatelessWidget {
  const _CredentialSection({
    required this.environmentController,
    required this.hasApiKey,
    required this.platform,
  });

  final TextEditingController environmentController;
  final bool hasApiKey;
  final String platform;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final variable = environmentController.text.trim().isEmpty
        ? 'DEEPSEEK_API_KEY'
        : environmentController.text.trim();
    final command = platform == 'windows'
        ? 'setx $variable "sk-..."'
        : 'export $variable="sk-..."';
    return Material(
      key: const ValueKey('recap-ai-credential-section'),
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: Icon(
              hasApiKey ? Icons.verified_user_outlined : Icons.key_off_outlined,
              color: hasApiKey ? colors.primary : colors.onSurfaceVariant,
            ),
            title: const Text('API Key'),
            subtitle: Text(
              hasApiKey
                  ? '已检测到 $variable；TimeTrace 不会显示或记录密钥内容。'
                  : '尚未检测到 $variable，完成下面的步骤后重启应用。',
            ),
            trailing: _StatusBadge(configured: hasApiKey),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.sm),
            child: TextField(
              key: const ValueKey('recap-ai-key-env'),
              controller: environmentController,
              decoration: const InputDecoration(
                labelText: 'API Key 环境变量',
                helperText: '只保存变量名，不保存 Key。',
                prefixIcon: Icon(Icons.terminal_outlined),
              ),
            ),
          ),
          ExpansionTile(
            key: const ValueKey('recap-ai-key-guide'),
            initiallyExpanded: !hasApiKey,
            leading: const Icon(Icons.route_outlined),
            title: Text(hasApiKey ? '更换 API Key' : '配置引导'),
            subtitle: const Text('三步完成，不需要把密钥写入 TimeTrace 配置文件。'),
            childrenPadding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.sm,
              0,
              TimeTraceSpace.sm,
              TimeTraceSpace.sm,
            ),
            children: [
              _GuideStep(
                number: '1',
                title: '创建 API Key',
                description: '在模型服务商控制台创建一枚仅供 TimeTrace 使用的 Key。',
              ),
              _GuideStep(
                number: '2',
                title: '写入系统环境变量',
                description: platform == 'windows'
                    ? '打开 PowerShell 或 CMD，替换 sk-... 后运行：'
                    : '打开终端，替换 sk-... 后运行，并写入你的 shell 配置：',
                child: Container(
                  margin: const EdgeInsets.only(top: TimeTraceSpace.xs),
                  padding: const EdgeInsets.fromLTRB(
                    TimeTraceSpace.sm,
                    TimeTraceSpace.xs,
                    TimeTraceSpace.xs,
                    TimeTraceSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    border: Border.all(color: colors.outlineVariant),
                    borderRadius: BorderRadius.circular(
                      TimeTraceRadius.control,
                    ),
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
                        key: const ValueKey('recap-ai-copy-command'),
                        tooltip: '复制命令',
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: command));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('命令已复制')),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
              const _GuideStep(
                number: '3',
                title: '重启 TimeTrace',
                description: '完全退出后重新打开，回到这里即可看到“环境变量”状态。',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.configured});

  final bool configured;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: configured ? 'API Key 状态：环境变量' : 'API Key 状态：未配置',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: configured
              ? colors.secondaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              configured ? Icons.terminal_outlined : Icons.key_off_outlined,
              size: 14,
              color: configured
                  ? colors.onSecondaryContainer
                  : colors.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              configured ? '环境变量' : '未配置',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: configured
                    ? colors.onSecondaryContainer
                    : colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
    this.child,
  });

  final String number;
  final String title;
  final String description;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: TimeTraceSpace.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: TimeTraceSpace.xxs),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant),
                ),
                if (child != null) child!,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionTestTile extends StatelessWidget {
  const _ConnectionTestTile({
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
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: ListTile(
        leading: Icon(
          succeeded == true
              ? Icons.check_circle_outline
              : succeeded == false
              ? Icons.error_outline
              : Icons.wifi_tethering_outlined,
          color: succeeded == false ? colors.error : colors.primary,
        ),
        title: const Text('连接检查'),
        subtitle: Text(message ?? '只验证服务连接，不发送任何 TimeTrace 使用数据。'),
        trailing: OutlinedButton.icon(
          key: const ValueKey('recap-ai-test-connection'),
          onPressed: enabled ? onPressed : null,
          icon: testing
              ? const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering_outlined, size: 17),
          label: Text(testing ? '测试中…' : '测试连接'),
        ),
      ),
    );
  }
}

class _DataScopeTile extends StatelessWidget {
  const _DataScopeTile({
    required this.includeDiaryEntries,
    required this.onChanged,
  });

  final bool includeDiaryEntries;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
    ),
    child: SwitchListTile(
      key: const ValueKey('recap-ai-diary-toggle'),
      secondary: const Icon(Icons.shield_outlined),
      title: const Text('允许使用日记文字'),
      subtitle: const Text('默认关闭。开启后，已发布日记会随聚合事实一起发送给模型。'),
      value: includeDiaryEntries,
      onChanged: onChanged,
    ),
  );
}

class _AdvancedSettings extends StatelessWidget {
  const _AdvancedSettings({required this.endpoint, required this.model});

  final TextEditingController endpoint;
  final TextEditingController model;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
    ),
    child: ExpansionTile(
      key: const ValueKey('recap-ai-advanced-settings'),
      leading: const Icon(Icons.tune_rounded),
      title: const Text('高级选项'),
      subtitle: const Text('OpenAI-compatible Endpoint 与模型名'),
      childrenPadding: const EdgeInsets.fromLTRB(
        TimeTraceSpace.sm,
        0,
        TimeTraceSpace.sm,
        TimeTraceSpace.sm,
      ),
      children: [
        TextField(
          controller: endpoint,
          decoration: const InputDecoration(
            labelText: 'Chat Completions Endpoint',
          ),
        ),
        const SizedBox(height: TimeTraceSpace.sm),
        TextField(
          controller: model,
          decoration: const InputDecoration(labelText: 'Model'),
        ),
      ],
    ),
  );
}

class _LocalModeNotice extends StatelessWidget {
  const _LocalModeNotice({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(TimeTraceSpace.sm),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      border: Border.all(color: colors.outlineVariant),
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 18, color: colors.primary),
        const SizedBox(width: TimeTraceSpace.xs),
        Expanded(
          child: Text(
            '本地总结不需要 API Key。AI Recap 仍会展示同一份事实快照、指标和时间分配，只是总结文字由本地规则生成。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );
}
