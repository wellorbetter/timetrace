import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/usage_history_provider.dart';

class UsageHistoryCard extends ConsumerWidget {
  const UsageHistoryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(dashboardRangeProvider);
    final history = ref.watch(dashboardUsageHistoryProvider);
    final showDate = switch (selection.range) {
      DateRange.week || DateRange.month => true,
      _ => false,
    };

    return history.when(
      loading: () => const _UsageHistoryFrame(
        count: null,
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (error, _) => _UsageHistoryFrame(
        count: null,
        child: _HistoryMessage(
          icon: Icons.error_outline_rounded,
          message: '使用历史加载失败',
          action: TextButton.icon(
            onPressed: () => ref.invalidate(dashboardUsageHistoryProvider),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试'),
          ),
        ),
      ),
      data: (entries) => _UsageHistoryFrame(
        count: entries.length,
        child: entries.isEmpty
            ? const _HistoryMessage(
                icon: Icons.history_toggle_off_rounded,
                message: '当前范围暂无使用历史',
              )
            : UsageHistoryList(entries: entries, showDate: showDate),
      ),
    );
  }
}

class _UsageHistoryFrame extends StatelessWidget {
  const _UsageHistoryFrame({required this.count, required this.child});

  final int? count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      key: const ValueKey('dashboard-usage-history'),
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.history_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: TimeTraceSpace.xs),
                Text(
                  '使用历史',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (count != null)
                  Text(
                    '$count 条 · 列表内滚动',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class UsageHistoryList extends StatefulWidget {
  const UsageHistoryList({
    required this.entries,
    required this.showDate,
    super.key,
  });

  final List<UsageHistoryEntry> entries;
  final bool showDate;

  @override
  State<UsageHistoryList> createState() => _UsageHistoryListState();
}

class _UsageHistoryListState extends State<UsageHistoryList> {
  final ScrollController _controller = ScrollController();

  @override
  void didUpdateWidget(covariant UsageHistoryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entries, widget.entries) &&
        _controller.hasClients) {
      _controller.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: widget.entries.length > 6,
          child: ListView.separated(
            key: const ValueKey('dashboard-usage-history-list'),
            controller: _controller,
            primary: false,
            padding: EdgeInsets.zero,
            itemCount: widget.entries.length,
            separatorBuilder: (context, index) => Divider(
              height: 1,
              indent: TimeTraceSpace.sm,
              endIndent: TimeTraceSpace.sm,
              color: scheme.outlineVariant,
            ),
            itemBuilder: (context, index) => _UsageHistoryRow(
              entry: widget.entries[index],
              showDate: widget.showDate,
            ),
          ),
        ),
      ),
    );
  }
}

class _UsageHistoryRow extends StatelessWidget {
  const _UsageHistoryRow({required this.entry, required this.showDate});

  final UsageHistoryEntry entry;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = _timeLabel(entry, showDate: showDate);
    final color = appColor(entry.appName);

    return Semantics(
      label: '$time，${entry.appName}，${formatDuration(entry.activeSeconds)}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: TimeTraceSpace.sm,
            vertical: TimeTraceSpace.xs,
          ),
          child: Row(
            children: [
              SizedBox(
                width: showDate ? 132 : 92,
                child: Tooltip(
                  message: time,
                  child: Text(
                    time,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: TimeTraceSpace.xs),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: TimeTraceSpace.xs),
              Expanded(
                child: Tooltip(
                  message: entry.appName,
                  child: Text(
                    entry.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
              if (entry.sourceCount > 1) ...[
                const SizedBox(width: TimeTraceSpace.xs),
                Text(
                  '${entry.sourceCount} 段',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(width: TimeTraceSpace.sm),
              Text(
                formatDuration(entry.activeSeconds),
                style: theme.textTheme.labelMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryMessage extends StatelessWidget {
  const _HistoryMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: scheme.outline),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

String _timeLabel(UsageHistoryEntry entry, {required bool showDate}) {
  final date = '${entry.date.month}月${entry.date.day}日';
  if (!entry.timeKnown) return showDate ? '$date · 时间未知' : '时间未知';

  final includeSeconds = entry.activeSeconds < 60;
  final start = _clock(entry.start, includeSeconds: includeSeconds);
  final end = _clock(entry.end, includeSeconds: includeSeconds);
  final range = '$start–$end';
  return showDate ? '$date · $range' : range;
}

String _clock(DateTime value, {required bool includeSeconds}) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  if (!includeSeconds) return '$hour:$minute';
  return '$hour:$minute:${value.second.toString().padLeft(2, '0')}';
}
