import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_schedule.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_schedule_provider.dart';

class RecapScheduleScreen extends ConsumerWidget {
  const RecapScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSchedule = ref.watch(recapScheduleProvider);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        title: const Text('自动回顾'),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: TimeTraceLayout.readingWidth),
          child: asyncSchedule.when(
            loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            error: (error, _) => Center(child: Text('读取设置失败：$error')),
            data: (schedule) => ListView(
              padding: const EdgeInsets.fromLTRB(
                TimeTraceSpace.xl,
                TimeTraceSpace.lg,
                TimeTraceSpace.xl,
                TimeTraceSpace.xxl,
              ),
              children: [
                Text(
                  '让 TimeTrace 主动给你回顾',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w650,
                    letterSpacing: -0.35,
                  ),
                ),
                const SizedBox(height: TimeTraceSpace.xs),
                Text(
                  '到点后自动生成事实、观察和建议。已接入 AI 时优先使用 AI；网络、额度或模型失败会自动退回本地回顾，不会丢掉当天总结。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.55),
                ),
                const SizedBox(height: TimeTraceSpace.lg),
                _Section(
                  title: '频率',
                  subtitle: '默认关闭，只有你主动开启后才会运行。',
                  child: SegmentedButton<RecapScheduleCadence>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: RecapScheduleCadence.off,
                        icon: Icon(Icons.pause_circle_outline_rounded),
                        label: Text('关闭'),
                      ),
                      ButtonSegment(
                        value: RecapScheduleCadence.daily,
                        icon: Icon(Icons.today_outlined),
                        label: Text('每天'),
                      ),
                      ButtonSegment(
                        value: RecapScheduleCadence.weekly,
                        icon: Icon(Icons.date_range_outlined),
                        label: Text('每周'),
                      ),
                    ],
                    selected: {schedule.cadence},
                    onSelectionChanged: (values) => _save(
                      ref,
                      schedule.copyWith(
                        cadence: values.first,
                        clearLastRunKey: true,
                      ),
                    ),
                  ),
                ),
                if (schedule.enabled) ...[
                  const SizedBox(height: TimeTraceSpace.lg),
                  _Section(
                    title: '生成时间',
                    subtitle: schedule.cadence == RecapScheduleCadence.daily
                        ? 'TimeTrace 在这个时间附近生成当天回顾。'
                        : '选择每周哪一天、什么时间生成本周回顾。',
                    child: Wrap(
                      spacing: TimeTraceSpace.md,
                      runSpacing: TimeTraceSpace.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (schedule.cadence == RecapScheduleCadence.weekly)
                          DropdownMenu<int>(
                            width: 180,
                            label: const Text('星期'),
                            initialSelection: schedule.weekday,
                            dropdownMenuEntries: const [
                              DropdownMenuEntry(value: DateTime.monday, label: '周一'),
                              DropdownMenuEntry(value: DateTime.tuesday, label: '周二'),
                              DropdownMenuEntry(value: DateTime.wednesday, label: '周三'),
                              DropdownMenuEntry(value: DateTime.thursday, label: '周四'),
                              DropdownMenuEntry(value: DateTime.friday, label: '周五'),
                              DropdownMenuEntry(value: DateTime.saturday, label: '周六'),
                              DropdownMenuEntry(value: DateTime.sunday, label: '周日'),
                            ],
                            onSelected: (value) {
                              if (value != null) {
                                _save(
                                  ref,
                                  schedule.copyWith(
                                    weekday: value,
                                    clearLastRunKey: true,
                                  ),
                                );
                              }
                            },
                          ),
                        OutlinedButton.icon(
                          onPressed: () => _pickTime(context, ref, schedule),
                          icon: const Icon(Icons.schedule_rounded),
                          label: Text(
                            '${schedule.hour.toString().padLeft(2, '0')}:${schedule.minute.toString().padLeft(2, '0')}',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  _Section(
                    title: '完成后提醒',
                    subtitle: '生成完成后由系统发送一条简短通知。完整内容仍留在 TimeTrace 回顾页。',
                    child: SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('系统通知'),
                      subtitle: const Text('只展示标题和简短总结，不包含日记正文。'),
                      value: schedule.notify,
                      onChanged: (value) => _save(
                        ref,
                        schedule.copyWith(notify: value),
                      ),
                    ),
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  Container(
                    padding: const EdgeInsets.all(TimeTraceSpace.md),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 18, color: scheme.primary),
                        const SizedBox(width: TimeTraceSpace.sm),
                        Expanded(
                          child: Text(
                            '自动回顾在 TimeTrace 进程仍驻留托盘/菜单栏时运行。完全退出应用后不会偷偷唤醒电脑；以后如果需要，可再单独启用 Windows Task Scheduler / macOS LaunchAgent。',
                            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickTime(
    BuildContext context,
    WidgetRef ref,
    RecapScheduleSettings schedule,
  ) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: schedule.hour, minute: schedule.minute),
      helpText: '自动回顾时间',
    );
    if (picked == null || !context.mounted) return;
    await _save(
      ref,
      schedule.copyWith(
        hour: picked.hour,
        minute: picked.minute,
        clearLastRunKey: true,
      ),
    );
  }

  Future<void> _save(
    WidgetRef ref,
    RecapScheduleSettings schedule,
  ) => ref.read(recapScheduleProvider.notifier).save(schedule);
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: TimeTraceSpace.md),
          child,
        ],
      ),
    );
  }
}
