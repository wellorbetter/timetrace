import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/nowline/presentation/widgets/nowline_timeline_view.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_mode_provider.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_provider.dart';

class NowlineScreen extends ConsumerWidget {
  const NowlineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncPreferences = ref.watch(nowlinePreferencesProvider);
    final mode = ref.watch(nowlineModeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Nowline')),
      body: asyncPreferences.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('设置加载失败：$error')),
        data: (preferences) => LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: TimeTraceLayout.readingWidth,
              ),
              child: ListView(
                padding: TimeTraceLayout.pagePadding(constraints.maxWidth),
                children: [
                  _IntroCard(
                    preferences: preferences,
                    mode: mode,
                    onLaunch: () async {
                      await ref.read(nowlineModeProvider.notifier).enter();
                      final error = ref.read(nowlineModeProvider).error;
                      if (error != null && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法打开 Nowline：$error')),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  const _TodayLedgerCard(),
                  const SizedBox(height: TimeTraceSpace.lg),
                  _PreferencesCard(preferences: preferences),
                  const SizedBox(height: TimeTraceSpace.lg),
                  const _PrivacyCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TodayLedgerCard extends ConsumerWidget {
  const _TodayLedgerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preferences =
        ref.watch(nowlinePreferencesProvider).value ??
        const NowlinePreferences();
    final timeline = ref.watch(todayNowlineProvider);
    return Container(
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('今日流水', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '从本地会话恢复最近 12 段；关闭应用后仍会保留。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: () => ref.invalidate(todayNowlineProvider),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          timeline.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text('今日流水读取失败：$error'),
            data: (value) => value.lines.isEmpty
                ? Text('今天还没有已完成的活动片段。', style: theme.textTheme.bodySmall)
                : NowlineTimelineView(
                    timeline: value,
                    preferences: preferences,
                    fadeHistory: false,
                  ),
          ),
        ],
      ),
    );
  }
}

class _IntroCard extends ConsumerWidget {
  const _IntroCard({
    required this.preferences,
    required this.mode,
    required this.onLaunch,
  });

  final NowlinePreferences preferences;
  final NowlineModeState mode;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final timeline = ref.watch(nowlineTimelineProvider);
    return Container(
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
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(TimeTraceRadius.control),
                ),
                child: Icon(Icons.graphic_eq_rounded, color: scheme.primary),
              ),
              const SizedBox(width: TimeTraceSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('电脑活动，像歌词一样经过', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    Text(
                      '把前台活动合并成语义片段，安静地挂在桌面边缘。',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: mode.busy ? null : onLaunch,
                icon: mode.busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('打开悬浮字幕'),
              ),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.lg),
          Container(
            constraints: const BoxConstraints(minHeight: 180),
            padding: const EdgeInsets.all(TimeTraceSpace.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(TimeTraceRadius.control),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.8),
              ),
            ),
            child: timeline.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('实时预览暂时不可用'),
                    TextButton(
                      onPressed: () => ref.invalidate(nowlineTimelineProvider),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
              data: (value) => NowlineTimelineView(
                timeline: value,
                preferences: preferences,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferencesCard extends ConsumerWidget {
  const _PreferencesCard({required this.preferences});

  final NowlinePreferences preferences;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notifier = ref.read(nowlinePreferencesProvider.notifier);
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('显示方式', style: theme.textTheme.titleMedium),
          const SizedBox(height: TimeTraceSpace.md),
          _SettingRow(
            title: '屏幕位置',
            subtitle: '打开时自动贴近所选区域，之后仍可拖动。',
            control: SegmentedButton<NowlinePlacement>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: NowlinePlacement.top, label: Text('顶部')),
                ButtonSegment(
                  value: NowlinePlacement.center,
                  label: Text('居中'),
                ),
                ButtonSegment(
                  value: NowlinePlacement.bottom,
                  label: Text('底部'),
                ),
              ],
              selected: {preferences.placement},
              onSelectionChanged: (values) =>
                  notifier.save(preferences.copyWith(placement: values.first)),
            ),
          ),
          const Divider(),
          _SliderRow(
            title: '历史行数',
            valueLabel: '${preferences.lineCount} 行',
            value: preferences.lineCount.toDouble(),
            min: 2,
            max: 6,
            divisions: 4,
            onChanged: (value) => notifier.preview(
              preferences.copyWith(lineCount: value.round()),
            ),
            onChangeEnd: (value) =>
                notifier.save(preferences.copyWith(lineCount: value.round())),
          ),
          const Divider(),
          _SliderRow(
            title: '面板透明度',
            valueLabel: '${(preferences.panelOpacity * 100).round()}%',
            value: preferences.panelOpacity,
            min: 0.5,
            max: 0.96,
            divisions: 23,
            onChanged: (value) =>
                notifier.preview(preferences.copyWith(panelOpacity: value)),
            onChangeEnd: (value) =>
                notifier.save(preferences.copyWith(panelOpacity: value)),
          ),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示时间'),
            subtitle: const Text('在每段活动左侧显示开始时间。'),
            value: preferences.showTimestamps,
            onChanged: (value) =>
                notifier.save(preferences.copyWith(showTimestamps: value)),
          ),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('显示窗口标题'),
            subtitle: const Text('默认关闭；标题可能包含文档名或网页信息。敏感应用仍会隐藏。'),
            value: preferences.showWindowTitles,
            onChanged: (value) =>
                notifier.save(preferences.copyWith(showWindowTitles: value)),
          ),
          const Divider(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('打开后立即点击穿透'),
            subtitle: const Text('鼠标操作会落到下方应用；可从系统托盘解锁。'),
            value: preferences.clickThroughOnStart,
            onChanged: (value) =>
                notifier.save(preferences.copyWith(clickThroughOnStart: value)),
          ),
        ],
      ),
    );
  }
}

class _PrivacyCard extends StatelessWidget {
  const _PrivacyCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 19, color: scheme.primary),
          const SizedBox(width: TimeTraceSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('实时层保持本地', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '复用 AI Recap 的活动事实来源和应用排除边界，但实时字幕只运行本地规则：不等待 Agent、不调用模型、不产生 token，也不记录按键。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.control,
  });

  final String title;
  final String subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: TimeTraceSpace.md),
        control,
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title)),
        Text(valueLabel, style: Theme.of(context).textTheme.labelMedium),
        SizedBox(
          width: 240,
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
      ],
    );
  }
}
