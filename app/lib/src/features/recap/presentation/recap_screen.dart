import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/data/recap_ai_client.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_ai_settings.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_ai_settings_dialog.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_report_view.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';

class RecapScreen extends ConsumerWidget {
  const RecapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncRecap = ref.watch(recapProvider);
    final selection = ref.watch(dashboardRangeProvider);
    final aiSettings =
        ref.watch(recapAiSettingsProvider).value ?? const RecapAiSettings();

    return Scaffold(
      appBar: AppBar(
        title: const Text('回顾'),
        actions: [
          IconButton(
            tooltip: '回顾设置',
            onPressed: () => _showAiSettings(context, ref),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '重新生成',
            onPressed: () => ref.read(recapProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: TimeTraceSpace.xs),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: TimeTraceLayout.dashboardWidth,
            ),
            child: ListView(
              padding: TimeTraceLayout.pagePadding(constraints.maxWidth),
              children: [
                _RangeSelector(selection: selection),
                const SizedBox(height: TimeTraceSpace.sm),
                asyncRecap.when(
                  skipLoadingOnReload: true,
                  loading: () => const SizedBox(
                    height: 220,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                  error: (error, _) => _RecapError(
                    onRetry: () => ref.read(recapProvider.notifier).refresh(),
                  ),
                  data: (state) => RecapReportView(
                    result: state.result,
                    generatedAt: state.generatedAt,
                    aiEnabled: aiSettings.enabled,
                    diaryIncludedInAi: aiSettings.includeDiaryEntries,
                    aiError: state.aiError,
                    onOpenSettings: () => _showAiSettings(context, ref),
                  ),
                ),
              ],
            ),
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
      for (final item in const [
        ('今天', DateRange.today),
        ('昨天', DateRange.yesterday),
        ('本周', DateRange.week),
        ('本月', DateRange.month),
      ])
        ChoiceChip(
          label: Text(item.$1),
          selected: selection.range == item.$2,
          onSelected: (_) =>
              ref.read(dashboardRangeProvider.notifier).select(item.$2),
        ),
    ],
  );
}

class _RecapError extends StatelessWidget {
  const _RecapError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline_rounded),
        const SizedBox(height: TimeTraceSpace.xs),
        const Text('生成回顾失败'),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

Future<void> _showAiSettings(BuildContext context, WidgetRef ref) async {
  final current =
      ref.read(recapAiSettingsProvider).value ?? const RecapAiSettings();
  final saved = await RecapAiSettingsDialog.show(
    context,
    initial: current,
    onTestConnection: const RecapAiClient().testConnection,
  );
  if (saved != null) {
    await ref.read(recapAiSettingsProvider.notifier).save(saved);
  }
}
