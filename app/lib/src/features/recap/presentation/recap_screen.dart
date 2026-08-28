import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_models.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapScreen extends ConsumerStatefulWidget {
  const RecapScreen({super.key});

  @override
  ConsumerState<RecapScreen> createState() => _RecapScreenState();
}

class _RecapScreenState extends ConsumerState<RecapScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final asyncRecap = ref.watch(recapProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final aiSettings = ref.watch(recapAiSettingsProvider).value ?? const RecapAiSettings();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: const Text('AI Recap'),
        actions: [
          TextButton.icon(
            onPressed: () => _showAiSettings(context, ref),
            icon: Icon(aiSettings.enabled ? Icons.auto_awesome_rounded : Icons.tune_rounded, size: 17),
            label: Text(aiSettings.enabled ? '${aiSettings.displayProvider} · AI 设置' : '配置 AI'),
          ),
          IconButton(
            tooltip: '重新生成',
            onPressed: () => ref.read(recapProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: TimeTraceLayout.dashboardWidth),
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(TimeTraceSpace.xl, TimeTraceSpace.md, TimeTraceSpace.xl, TimeTraceSpace.xxl),
            children: [
              _RangeSelector(selection: selection),
              const SizedBox(height: TimeTraceSpace.md),
              asyncRecap.when(
                skipLoadingOnReload: true,
                loading: () => const SizedBox(height: 220, child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))),
                error: (_, _) => _RecapError(onRetry: () => ref.read(recapProvider.notifier).refresh()),
                data: (state) => _RecapContent(state: state, settings: aiSettings),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RangeSelector extends ConsumerWidget {
  const _RangeSelector({required this.selection});
  final DateRangeSelection selection;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Wrap(
    spacing: TimeTraceSpace.xs,
    runSpacing: TimeTraceSpace.xs,
    children: [
      for (final item in const [('今天', DateRange.today), ('昨天', DateRange.yesterday), ('本周', DateRange.week), ('本月', DateRange.month)])
        ChoiceChip(
          label: Text(item.$1),
          selected: selection.range == item.$2,
          onSelected: (_) => ref.read(dashboardRangeProvider.notifier).select(item.$2),
        ),
    ],
  );
}

class _RecapContent extends StatelessWidget {
  const _RecapContent({required this.state, required this.settings});
  final RecapState state;
  final RecapAiSettings settings;

  @override
  Widget build(BuildContext context) {
    final result = state.result;
    final snapshot = result.snapshot;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(TimeTraceSpace.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(result.isAiEnhanced ? Icons.auto_awesome_outlined : Icons.notes_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: TimeTraceSpace.xs),
                  Expanded(
                    child: Text(
                      result.isAiEnhanced ? 'AI ENHANCED · ${result.model ?? 'MODEL'}' : 'LOCAL FACTUAL RECAP · 免费',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700, letterSpacing: 0.65),
                    ),
                  ),
                  Text(_generatedLabel(state.generatedAt), style: theme.textTheme.labelSmall),
                ],
              ),
              const SizedBox(height: TimeTraceSpace.sm),
              Text(result.headline, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.35)),
              const SizedBox(height: TimeTraceSpace.xs),
              Text(result.summary, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55)),
              const SizedBox(height: TimeTraceSpace.sm),
              _OriginHint(result: result, settings: settings),
              if (state.aiError != null) ...[
                const SizedBox(height: TimeTraceSpace.sm),
                _InlineNotice(icon: Icons.info_outline_rounded, text: state.aiError!),
              ],
            ],
          ),
        ),
        const SizedBox(height: TimeTraceSpace.md),
        _MetricGrid(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.lg),
        _Section(
          icon: Icons.insights_outlined,
          title: '观察',
          subtitle: '只描述 TimeTrace 事实快照里实际出现的模式。',
          child: _NumberedList(items: result.insights, emptyText: '当前数据还不足以形成稳定观察。'),
        ),
        const SizedBox(height: TimeTraceSpace.lg),
        _Section(
          icon: Icons.lightbulb_outline_rounded,
          title: '建议',
          subtitle: '基于上面的模式给出可尝试的调整；建议不是事实，也不是生产力评分。',
          child: _RecommendationList(items: result.recommendations),
        ),
        const SizedBox(height: TimeTraceSpace.lg),
        _TopApps(snapshot: snapshot),
        const SizedBox(height: TimeTraceSpace.lg),
        _Section(
          icon: Icons.data_object_rounded,
          title: '事实快照',
          subtitle: '你可以检查实际提交给 AI 的结构化数据；日记文本是否包含取决于你的显式授权。',
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: TimeTraceSpace.xs),
            title: const Text('查看原始 Recap JSON'),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(TimeTraceSpace.sm),
                decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
                child: SelectableText(
                  snapshot.toPrettyJson(includeDiaryEntries: settings.includeDiaryEntries),
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OriginHint extends StatelessWidget {
  const _OriginHint({required this.result, required this.settings});
  final RecapResult result;
  final RecapAiSettings settings;

  @override
  Widget build(BuildContext context) {
    final text = result.isAiEnhanced
        ? '这次文本由 ${settings.displayProvider} 的 ${result.model ?? settings.model} 基于本地事实快照增强；原始统计不会被模型修改。'
        : '当前是完全免费的本地规则回顾，没有调用外部模型。需要更自然的分析时，可在右上角“配置 AI”选择服务商或本地 Ollama。';
    return _InlineNotice(icon: result.isAiEnhanced ? Icons.cloud_done_outlined : Icons.lock_outline_rounded, text: text);
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: scheme.onSurfaceVariant),
        const SizedBox(width: TimeTraceSpace.xs),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.4))),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.snapshot});
  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final top = snapshot.topApps.isEmpty ? null : snapshot.topApps.first;
    final metrics = [
      ('活跃时长', formatRecapDuration(snapshot.activeSeconds), '记录范围内'),
      ('最长连续段', snapshot.longestActiveStreakSeconds > 0 ? formatRecapDuration(snapshot.longestActiveStreakSeconds) : '—', snapshot.longestActiveStreakSeconds > 0 ? '连续非 Idle' : '月视图暂不计算'),
      ('应用切换', snapshot.sessionCount > 0 ? '${snapshot.contextSwitches}' : '—', snapshot.sessionCount > 0 ? '${snapshot.sessionCount} 个活跃 Session' : '月视图暂不计算'),
      ('最常用', top?.name ?? '—', top == null ? '暂无数据' : formatRecapDuration(top.activeSeconds)),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 4 : constraints.maxWidth >= 520 ? 2 : 1;
        final width = (constraints.maxWidth - (columns - 1) * TimeTraceSpace.sm) / columns;
        return Wrap(
          spacing: TimeTraceSpace.sm,
          runSpacing: TimeTraceSpace.sm,
          children: [for (final item in metrics) SizedBox(width: width, child: _MetricCard(title: item.$1, value: item.$2, detail: item.$3))],
        );
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.title, required this.value, required this.detail});
  final String title;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 98,
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(color: scheme.surfaceContainerLowest, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(TimeTraceRadius.surface)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.labelMedium),
          const Spacer(),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.subtitle, required this.child});
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      decoration: BoxDecoration(color: scheme.surfaceContainerLowest, border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(TimeTraceRadius.surface)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon, size: 17, color: scheme.primary), const SizedBox(width: TimeTraceSpace.xs), Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))]),
          const SizedBox(height: 3),
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: TimeTraceSpace.sm),
          child,
        ],
      ),
    );
  }
}

class _NumberedList extends StatelessWidget {
  const _NumberedList({required this.items, required this.emptyText});
  final List<String> items;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Text(emptyText, style: Theme.of(context).textTheme.bodySmall);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 30, child: Text((i + 1).toString().padLeft(2, '0'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700))),
              Expanded(child: Text(items[i], style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.48))),
            ],
          ),
          if (i != items.length - 1) const Divider(height: 24),
        ],
      ],
    );
  }
}

class _RecommendationList extends StatelessWidget {
  const _RecommendationList({required this.items});
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Text('当前没有足够数据形成可执行建议。', style: Theme.of(context).textTheme.bodySmall);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final text in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
                  child: Icon(Icons.arrow_forward_rounded, size: 14, color: scheme.primary),
                ),
                const SizedBox(width: TimeTraceSpace.sm),
                Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.48))),
              ],
            ),
          ),
      ],
    );
  }
}

class _TopApps extends StatelessWidget {
  const _TopApps({required this.snapshot});
  final RecapSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final apps = snapshot.topApps;
    return _Section(
      icon: Icons.bar_chart_rounded,
      title: '时间分配',
      subtitle: '按活跃时长排序的主要应用。',
      child: apps.isEmpty
          ? const Text('暂无应用数据')
          : Column(children: [for (var i = 0; i < apps.length; i++) _AppRow(app: apps[i], maxSeconds: apps.first.activeSeconds, rank: i + 1)]),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.maxSeconds, required this.rank});
  final RecapAppFact app;
  final int maxSeconds;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ratio = maxSeconds <= 0 ? 0.0 : app.activeSeconds / maxSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
      child: Row(
        children: [
          SizedBox(width: 32, child: Text(rank.toString().padLeft(2, '0'), style: theme.textTheme.labelSmall)),
          SizedBox(width: 150, child: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: TimeTraceSpace.sm),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: ratio, minHeight: 4, backgroundColor: scheme.surfaceContainerHighest))),
          const SizedBox(width: TimeTraceSpace.sm),
          SizedBox(width: 72, child: Text(formatRecapDuration(app.activeSeconds), textAlign: TextAlign.right, style: theme.textTheme.labelMedium)),
        ],
      ),
    );
  }
}

class _RecapError extends StatelessWidget {
  const _RecapError({required this.onRetry});
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.error_outline_rounded), const SizedBox(height: TimeTraceSpace.xs), const Text('生成回顾失败'), TextButton(onPressed: onRetry, child: const Text('重试'))]),
  );
}

String _generatedLabel(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 生成';

Future<void> _showAiSettings(BuildContext context, WidgetRef ref) async {
  final current = ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
  final endpoint = TextEditingController(text: current.endpoint);
  final model = TextEditingController(text: current.model);
  final keyEnv = TextEditingController(text: current.apiKeyEnv);
  final directKey = TextEditingController(text: current.runtimeApiKey);
  final prompt = TextEditingController(text: current.customSystemPrompt);
  var enabled = current.enabled;
  var provider = current.provider;
  var includeDiary = current.includeDiaryEntries;
  var style = current.responseStyle;
  var advanced = false;
  var customModel = !((recapProviderModels[provider] ?? const <String>[]).contains(current.model)) && current.model.isNotEmpty;

  void applyProvider(String value, void Function(VoidCallback fn) setState) {
    setState(() {
      provider = value;
      if (value != 'custom') endpoint.text = recapProviderEndpoints[value] ?? endpoint.text;
      final presets = recapProviderModels[value] ?? const <String>[];
      if (presets.isNotEmpty) {
        model.text = presets.first;
        customModel = false;
      } else {
        customModel = true;
      }
      if (value == 'openai' && keyEnv.text.trim().isEmpty) keyEnv.text = 'OPENAI_API_KEY';
      if (value == 'deepseek') keyEnv.text = 'DEEPSEEK_API_KEY';
      if (value == 'openrouter') keyEnv.text = 'OPENROUTER_API_KEY';
    });
  }

  final saved = await showDialog<RecapAiSettings>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final presets = recapProviderModels[provider] ?? const <String>[];
        return AlertDialog(
          title: const Text('AI Recap 设置'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用模型增强'),
                    subtitle: const Text('关闭时继续使用完全免费的本地事实回顾。'),
                    value: enabled,
                    onChanged: (value) => setState(() => enabled = value),
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  DropdownButtonFormField<String>(
                    initialValue: provider,
                    decoration: const InputDecoration(labelText: 'AI 服务'),
                    items: const [
                      DropdownMenuItem(value: 'openai', child: Text('OpenAI')),
                      DropdownMenuItem(value: 'openrouter', child: Text('OpenRouter')),
                      DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek')),
                      DropdownMenuItem(value: 'ollama', child: Text('Ollama（本地免费）')),
                      DropdownMenuItem(value: 'custom', child: Text('自定义 OpenAI-Compatible')),
                    ],
                    onChanged: (value) { if (value != null) applyProvider(value, setState); },
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  if (presets.isNotEmpty && !customModel)
                    DropdownButtonFormField<String>(
                      value: presets.contains(model.text) ? model.text : presets.first,
                      decoration: const InputDecoration(labelText: '模型'),
                      items: [for (final item in presets) DropdownMenuItem(value: item, child: Text(item)), const DropdownMenuItem(value: '__custom__', child: Text('自定义模型名…'))],
                      onChanged: (value) {
                        if (value == '__custom__') {
                          setState(() { customModel = true; model.clear(); });
                        } else if (value != null) {
                          setState(() => model.text = value);
                        }
                      },
                    )
                  else
                    TextField(
                      controller: model,
                      decoration: InputDecoration(
                        labelText: '模型名',
                        hintText: provider == 'ollama' ? '例如 qwen3:8b' : '填写服务商支持的 model id',
                        suffixIcon: presets.isEmpty ? null : IconButton(onPressed: () => setState(() { customModel = false; model.text = presets.first; }), icon: const Icon(Icons.list_rounded), tooltip: '返回模型列表'),
                      ),
                    ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  if (provider != 'ollama') ...[
                    TextField(
                      controller: directKey,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'API Key（可选，优先使用）', helperText: '为了避免明文落盘，这个值只在本次 TimeTrace 运行期间保存在内存中。'),
                    ),
                    const SizedBox(height: TimeTraceSpace.sm),
                    TextField(controller: keyEnv, decoration: const InputDecoration(labelText: '或从环境变量读取 API Key', hintText: 'OPENAI_API_KEY')),
                    const SizedBox(height: TimeTraceSpace.sm),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许 AI 使用日记文本'),
                    subtitle: const Text('默认关闭。关闭时只发送聚合活动事实，不发送日记内容。'),
                    value: includeDiary,
                    onChanged: (value) => setState(() => includeDiary = value),
                  ),
                  const SizedBox(height: TimeTraceSpace.xs),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [ButtonSegment(value: 'concise', label: Text('简洁')), ButtonSegment(value: 'balanced', label: Text('平衡')), ButtonSegment(value: 'detailed', label: Text('详细'))],
                    selected: {style},
                    onSelectionChanged: (value) => setState(() => style = value.first),
                  ),
                  const SizedBox(height: TimeTraceSpace.sm),
                  InkWell(
                    borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                    onTap: () => setState(() => advanced = !advanced),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xs),
                      child: Row(children: [const Icon(Icons.tune_rounded, size: 17), const SizedBox(width: TimeTraceSpace.xs), const Expanded(child: Text('高级设置')), Icon(advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded)]),
                    ),
                  ),
                  if (advanced) ...[
                    const SizedBox(height: TimeTraceSpace.xs),
                    TextField(controller: endpoint, decoration: const InputDecoration(labelText: 'Chat Completions Endpoint')),
                    const SizedBox(height: TimeTraceSpace.sm),
                    TextField(
                      controller: prompt,
                      minLines: 4,
                      maxLines: 8,
                      decoration: const InputDecoration(labelText: '附加 Prompt', helperText: '可自定义语气、关注点等；不能覆盖 TimeTrace 的事实与隐私约束。'),
                    ),
                  ],
                  if (provider == 'ollama') ...[
                    const SizedBox(height: TimeTraceSpace.sm),
                    const _DialogHint(text: 'Ollama 是本地免费方案：先在电脑上运行 Ollama 并下载模型，然后这里不需要 API Key。'),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                RecapAiSettings(
                  enabled: enabled,
                  provider: provider,
                  endpoint: endpoint.text.trim(),
                  model: model.text.trim(),
                  apiKeyEnv: keyEnv.text.trim(),
                  runtimeApiKey: directKey.text,
                  includeDiaryEntries: includeDiary,
                  responseStyle: style,
                  customSystemPrompt: prompt.text.trim(),
                ),
              ),
              child: const Text('保存并重新生成'),
            ),
          ],
        );
      },
    ),
  );

  endpoint.dispose();
  model.dispose();
  keyEnv.dispose();
  directKey.dispose();
  prompt.dispose();
  if (saved != null) await ref.read(recapAiSettingsProvider.notifier).save(saved);
}

class _DialogHint extends StatelessWidget {
  const _DialogHint({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(TimeTraceRadius.control)),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
