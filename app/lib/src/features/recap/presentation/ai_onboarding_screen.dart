import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class AiOnboardingScreen extends ConsumerStatefulWidget {
  const AiOnboardingScreen({super.key});

  @override
  ConsumerState<AiOnboardingScreen> createState() => _AiOnboardingScreenState();
}

class _AiOnboardingScreenState extends ConsumerState<AiOnboardingScreen> {
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _endpoint = TextEditingController();
  final _prompt = TextEditingController();
  String _provider = 'gemini-free';
  String _style = 'balanced';
  bool _includeDiary = false;
  bool _advanced = false;
  bool _testing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final current = ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
    _provider = current.provider;
    _style = current.responseStyle;
    _includeDiary = current.includeDiaryEntries;
    _key.text = current.runtimeApiKey;
    _model.text = current.model;
    _endpoint.text = current.endpoint;
    _prompt.text = current.customSystemPrompt;
    if (_model.text.isEmpty) _applyPreset(_provider);
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _endpoint.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _applyPreset(String provider) {
    _provider = provider;
    _endpoint.text = recapProviderEndpoints[provider] ?? '';
    final models = recapProviderModels[provider] ?? const <String>[];
    _model.text = models.isEmpty ? '' : models.first;
    _status = null;
  }

  RecapAiSettings _settings({bool enabled = true}) => RecapAiSettings(
        enabled: enabled,
        provider: _provider,
        endpoint: _endpoint.text.trim(),
        model: _model.text.trim(),
        apiKeyEnv: recapProviderKeyEnvs[_provider] ?? '',
        runtimeApiKey: _key.text.trim(),
        includeDiaryEntries: _includeDiary,
        responseStyle: _style,
        customSystemPrompt: _prompt.text.trim(),
      );

  Future<void> _save() async {
    final settings = _settings();
    await ref.read(recapAiSettingsProvider.notifier).save(settings);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${settings.displayProvider} 已启用')),
    );
    context.go('/recap');
  }

  Future<void> _useLocalOnly() async {
    final current = ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
    await ref.read(recapAiSettingsProvider.notifier).save(current.copyWith(enabled: false));
    if (mounted) context.go('/recap');
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _status = null;
    });
    final now = DateTime.now();
    final sample = RecapResult(
      headline: '连接测试',
      summary: '这是一份不包含真实用户数据的测试请求。',
      insights: const ['测试 AI 是否能正确返回结构化内容。'],
      recommendations: const ['连接成功后即可用于真实回顾。'],
      snapshot: RecapSnapshot(
        label: '测试',
        start: now,
        end: now,
        activeSeconds: 600,
        idleSeconds: 120,
        previousActiveSeconds: 480,
        topApps: const [RecapAppFact(name: 'TimeTrace Test', activeSeconds: 600, idleSeconds: 0)],
        sessionCount: 2,
        contextSwitches: 1,
        longestActiveStreakSeconds: 420,
        peakHour: now.hour,
        peakHourActiveSeconds: 420,
        diaryEntries: const [],
      ),
      origin: RecapOrigin.local,
    );
    final result = await const RecapAiClient().enhance(local: sample, settings: _settings());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _status = result.error ?? '连接成功 · ${_settings().displayProvider} / ${_model.text.trim()}';
    });
  }

  Future<void> _importOpenCode() async {
    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      final appData = Platform.environment['APPDATA'];
      final candidates = <String>[
        if (Platform.environment['XDG_DATA_HOME'] case final xdg?) '$xdg/opencode/auth.json',
        if (home != null) '$home/.local/share/opencode/auth.json',
        if (appData != null) '$appData/opencode/auth.json',
      ];
      File? found;
      for (final path in candidates) {
        final file = File(path);
        if (await file.exists()) {
          found = file;
          break;
        }
      }
      if (found == null) throw const FileSystemException('未找到 OpenCode auth.json');
      final decoded = jsonDecode(await found.readAsString());
      if (decoded is! Map<String, dynamic>) throw const FormatException('OpenCode 凭据格式无法识别');
      final aliases = switch (_provider) {
        'deepseek' => const ['deepseek'],
        'openai' => const ['openai'],
        'openrouter' || 'openrouter-free' => const ['openrouter'],
        'gemini-free' => const ['google', 'gemini'],
        _ => const <String>[],
      };
      Map<String, dynamic>? entry;
      for (final name in aliases) {
        final value = decoded[name];
        if (value is Map<String, dynamic> && value['type'] == 'api' && value['key'] is String) {
          entry = value;
          break;
        }
      }
      if (entry == null) throw const FormatException('当前 AI 服务没有可导入的 API Key');
      setState(() {
        _key.text = entry!['key'] as String;
        _status = '已从 OpenCode 导入 API Key；TimeTrace 不会把它明文写入配置文件。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'OpenCode 导入失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: const Text('AI 接入'),
        leading: IconButton(
          tooltip: '返回回顾',
          onPressed: () => context.go('/recap'),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              TimeTraceSpace.xl,
              TimeTraceSpace.lg,
              TimeTraceSpace.xl,
              TimeTraceSpace.xxl,
            ),
            children: [
              Text('选择你想使用 AI 的方式', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: TimeTraceSpace.xs),
              Text(
                'TimeTrace 不要求绑定某一家服务。你可以用免费在线 AI、自己的 API、OpenCode 已有凭据、自定义兼容接口，或者完全不使用外部 AI。',
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: TimeTraceSpace.lg),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth >= 900
                      ? (constraints.maxWidth - TimeTraceSpace.sm * 2) / 3
                      : constraints.maxWidth >= 560
                          ? (constraints.maxWidth - TimeTraceSpace.sm) / 2
                          : constraints.maxWidth;
                  return Wrap(
                    spacing: TimeTraceSpace.sm,
                    runSpacing: TimeTraceSpace.sm,
                    children: [
                      _ChoiceCard(width: width, selected: _provider == 'gemini-free', icon: Icons.auto_awesome_rounded, title: 'Gemini Free', badge: '推荐', subtitle: 'Google 官方免费层。需要登录 Google AI Studio 创建 API Key。', onTap: () => setState(() => _applyPreset('gemini-free'))),
                      _ChoiceCard(width: width, selected: _provider == 'openrouter-free', icon: Icons.route_rounded, title: 'OpenRouter Free', badge: '免费模型', subtitle: '需要 OpenRouter 账号和 Key；自动使用当前免费模型路由。', onTap: () => setState(() => _applyPreset('openrouter-free'))),
                      _ChoiceCard(width: width, selected: _provider == 'deepseek', icon: Icons.bolt_rounded, title: 'DeepSeek', subtitle: '使用自己的 DeepSeek API Key，模型和 Endpoint 已预设。', onTap: () => setState(() => _applyPreset('deepseek'))),
                      _ChoiceCard(width: width, selected: _provider == 'openai', icon: Icons.cloud_outlined, title: 'OpenAI', subtitle: '使用自己的 OpenAI API Key，也可以手动填写模型。', onTap: () => setState(() => _applyPreset('openai'))),
                      _ChoiceCard(width: width, selected: _provider == 'openrouter', icon: Icons.hub_outlined, title: 'OpenRouter', subtitle: '使用自己的 OpenRouter Key，自由选择路由后的模型。', onTap: () => setState(() => _applyPreset('openrouter'))),
                      _ChoiceCard(width: width, selected: _provider == 'custom', icon: Icons.tune_rounded, title: '自定义兼容 API', subtitle: '任何 OpenAI-compatible Chat Completions 服务都可以接入。', onTap: () => setState(() => _applyPreset('custom'))),
                    ],
                  );
                },
              ),
              const SizedBox(height: TimeTraceSpace.lg),
              _SetupPanel(
                provider: _provider,
                keyController: _key,
                modelController: _model,
                endpointController: _endpoint,
                promptController: _prompt,
                style: _style,
                includeDiary: _includeDiary,
                advanced: _advanced,
                testing: _testing,
                status: _status,
                onStyle: (value) => setState(() => _style = value),
                onDiary: (value) => setState(() => _includeDiary = value),
                onAdvanced: () => setState(() => _advanced = !_advanced),
                onTest: _test,
                onImportOpenCode: _importOpenCode,
                onOpenSignup: () => _openSignup(_provider),
              ),
              const SizedBox(height: TimeTraceSpace.md),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _useLocalOnly,
                    icon: const Icon(Icons.lock_outline_rounded),
                    label: const Text('只使用本地免费回顾'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('保存并启用 AI'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSignup(String provider) async {
    final url = switch (provider) {
      'gemini-free' => 'https://aistudio.google.com/apikey',
      'openrouter-free' || 'openrouter' => 'https://openrouter.ai/settings/keys',
      'deepseek' => 'https://platform.deepseek.com/api_keys',
      'openai' => 'https://platform.openai.com/api-keys',
      _ => null,
    };
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({required this.width, required this.selected, required this.icon, required this.title, required this.subtitle, required this.onTap, this.badge});
  final double width;
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.55) : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 1.4 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(icon, size: 20, color: selected ? scheme.primary : scheme.onSurfaceVariant),
                  const Spacer(),
                  if (badge != null) Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(99)),
                    child: Text(badge!, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: TimeTraceSpace.sm),
                Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SetupPanel extends StatelessWidget {
  const _SetupPanel({
    required this.provider,
    required this.keyController,
    required this.modelController,
    required this.endpointController,
    required this.promptController,
    required this.style,
    required this.includeDiary,
    required this.advanced,
    required this.testing,
    required this.status,
    required this.onStyle,
    required this.onDiary,
    required this.onAdvanced,
    required this.onTest,
    required this.onImportOpenCode,
    required this.onOpenSignup,
  });

  final String provider;
  final TextEditingController keyController;
  final TextEditingController modelController;
  final TextEditingController endpointController;
  final TextEditingController promptController;
  final String style;
  final bool includeDiary;
  final bool advanced;
  final bool testing;
  final String? status;
  final ValueChanged<String> onStyle;
  final ValueChanged<bool> onDiary;
  final VoidCallback onAdvanced;
  final VoidCallback onTest;
  final VoidCallback onImportOpenCode;
  final VoidCallback onOpenSignup;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final models = recapProviderModels[provider] ?? const <String>[];
    final canSignup = const {'gemini-free', 'openrouter-free', 'openrouter', 'deepseek', 'openai'}.contains(provider);
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Text('完成接入', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (canSignup) OutlinedButton.icon(onPressed: onOpenSignup, icon: const Icon(Icons.open_in_new_rounded, size: 16), label: const Text('登录 / 获取 API Key')),
          ]),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(
            provider == 'gemini-free'
                ? '登录 Google AI Studio 创建免费 Key，然后粘贴到下方。免费层的数据政策与付费层不同，TimeTrace 默认不发送日记正文。'
                : provider == 'openrouter-free'
                    ? '创建 OpenRouter Key 后即可使用 free router。免费模型与限流由 OpenRouter 当前策略决定。'
                    : '你可以直接粘贴 Key，也可以从 OpenCode 已有 API 凭据中主动导入。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: TimeTraceSpace.md),
          TextField(
            controller: keyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'API Key',
              helperText: '只保存在当前 TimeTrace 进程内存中，不写入 recap_ai.json。',
              suffixIcon: IconButton(onPressed: onImportOpenCode, tooltip: '从 OpenCode 导入', icon: const Icon(Icons.file_download_outlined)),
            ),
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          if (models.isNotEmpty)
            DropdownButtonFormField<String>(
              value: models.contains(modelController.text) ? modelController.text : models.first,
              decoration: const InputDecoration(labelText: '模型'),
              items: [
                for (final model in models) DropdownMenuItem(value: model, child: Text(model)),
                const DropdownMenuItem(value: '__custom__', child: Text('自定义模型名…')),
              ],
              onChanged: (value) {
                if (value == null) return;
                if (value == '__custom__') {
                  modelController.clear();
                } else {
                  modelController.text = value;
                }
              },
            )
          else
            TextField(controller: modelController, decoration: const InputDecoration(labelText: '模型名')),
          const SizedBox(height: TimeTraceSpace.sm),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'concise', label: Text('简洁')),
              ButtonSegment(value: 'balanced', label: Text('平衡')),
              ButtonSegment(value: 'detailed', label: Text('详细')),
            ],
            selected: {style},
            onSelectionChanged: (value) => onStyle(value.first),
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('允许 AI 使用日记正文'),
            subtitle: const Text('默认关闭。关闭时只发送聚合使用事实。'),
            value: includeDiary,
            onChanged: onDiary,
          ),
          InkWell(
            borderRadius: BorderRadius.circular(TimeTraceRadius.control),
            onTap: onAdvanced,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
              child: Row(children: [const Icon(Icons.tune_rounded, size: 17), const SizedBox(width: TimeTraceSpace.xs), const Expanded(child: Text('高级设置')), Icon(advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded)]),
            ),
          ),
          if (advanced) ...[
            const SizedBox(height: TimeTraceSpace.xs),
            TextField(controller: endpointController, decoration: const InputDecoration(labelText: 'Chat Completions Endpoint')),
            const SizedBox(height: TimeTraceSpace.sm),
            TextField(controller: modelController, decoration: const InputDecoration(labelText: '自定义模型名')),
            const SizedBox(height: TimeTraceSpace.sm),
            TextField(controller: promptController, minLines: 4, maxLines: 8, decoration: const InputDecoration(labelText: '附加 Prompt', helperText: '可调整语气和关注点，但不能覆盖事实与隐私约束。')),
          ],
          const SizedBox(height: TimeTraceSpace.md),
          Row(children: [
            OutlinedButton.icon(
              onPressed: testing ? null : onTest,
              icon: testing
                  ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 1.7))
                  : const Icon(Icons.wifi_tethering_rounded, size: 16),
              label: Text(testing ? '正在测试…' : '测试连接'),
            ),
            const SizedBox(width: TimeTraceSpace.sm),
            if (status != null) Expanded(child: Text(status!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: status!.startsWith('连接成功') || status!.startsWith('已从') ? scheme.primary : scheme.onSurfaceVariant))),
          ]),
        ],
      ),
    );
  }
}
