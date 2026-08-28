import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/calendar_grid.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/diary_section.dart' as diary;
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/hourly_chart_card.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/presentation/widgets/recap_preview_card.dart';

class DashboardProductScreen extends ConsumerWidget {
  const DashboardProductScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(dashboardProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('概览')),
      body: asyncState.when(
        skipLoadingOnReload: true,
        loading: () => const Center(
          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        error: (error, _) => Center(child: Text('加载失败: $error')),
        data: (state) => _OverviewBody(state: state),
      ),
    );
  }
}

class _OverviewBody extends ConsumerStatefulWidget {
  const _OverviewBody({required this.state});
  final DashboardState state;

  @override
  ConsumerState<_OverviewBody> createState() => _OverviewBodyState();
}

class _OverviewBodyState extends ConsumerState<_OverviewBody> {
  String _view = 'apps';
  int? _selectedApp;
  List<PageDto>? _pages;
  bool _loadingPages = false;
  final List<GlobalKey> _rowKeys = [];

  List<AppUsageItem> get _apps => widget.state.apps.where((app) => app.totalSeconds > 0).toList(growable: false);

  Future<void> _selectApp(int index) async {
    final apps = _apps;
    if (index < 0 || index >= apps.length) return;
    if (_selectedApp == index) {
      setState(() {
        _selectedApp = null;
        _pages = null;
      });
      return;
    }

    setState(() {
      _selectedApp = index;
      _pages = null;
      _loadingPages = true;
    });

    try {
      final day = ref.read(dashboardRangeProvider).effectiveDay;
      final date = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      final pages = ref.read(apiProvider).getWindowTitles(appName: apps[index].appName, date: date);
      if (!mounted) return;
      setState(() {
        _pages = pages;
        _loadingPages = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPages = false);
    }
  }

  diary.DiaryRange _diaryRange(DateRangeSelection selection) => switch (selection.range) {
        DateRange.today || DateRange.yesterday || DateRange.custom => diary.DiaryRange.day,
        DateRange.week => diary.DiaryRange.week,
        DateRange.month => diary.DiaryRange.month,
      };

  @override
  Widget build(BuildContext context) {
    final selection = ref.watch(dashboardRangeProvider);
    final apps = _apps;
    final day = selection.effectiveDay;
    final scheme = Theme.of(context).colorScheme;

    while (_rowKeys.length < apps.length) {
      _rowKeys.add(GlobalKey());
    }
    while (_rowKeys.length > apps.length) {
      _rowKeys.removeLast();
    }

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: TimeTraceLayout.dashboardWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(TimeTraceSpace.xl, TimeTraceSpace.md, TimeTraceSpace.xl, TimeTraceSpace.xxl),
          children: [
            _OverviewHeader(
              state: widget.state,
              apps: apps,
              selection: selection,
              onRange: (range) => ref.read(dashboardRangeProvider.notifier).select(range),
            ),
            const SizedBox(height: TimeTraceSpace.md),
            const RecapPreviewCard(),
            const SizedBox(height: TimeTraceSpace.md),
            _Workspace(
              day: day,
              apps: apps,
              selectedApp: _selectedApp,
              pages: _pages,
              loadingPages: _loadingPages,
              rowKeys: _rowKeys,
              view: _view,
              onViewChanged: (value) => setState(() => _view = value),
              onSelectApp: _selectApp,
              onSelectDay: (value) => ref.read(dashboardRangeProvider.notifier).selectDay(value),
            ),
            if (apps.isEmpty) ...[
              const SizedBox(height: TimeTraceSpace.md),
              Container(
                padding: const EdgeInsets.all(TimeTraceSpace.sm),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: const Text('暂无使用数据。继续正常使用电脑后，这里会自动形成统计与回顾。'),
              ),
            ],
            const SizedBox(height: TimeTraceSpace.md),
            diary.DiarySection(date: day, range: _diaryRange(selection)),
          ],
        ),
      ),
    );
  }
}

class _OverviewHeader extends StatelessWidget {
  const _OverviewHeader({required this.state, required this.apps, required this.selection, required this.onRange});
  final DashboardState state;
  final List<AppUsageItem> apps;
  final DateRangeSelection selection;
  final ValueChanged<DateRange> onRange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = apps.isEmpty ? null : apps.first;
    final totalTracked = state.totalActiveSeconds + state.totalIdleSeconds;
    final activeRatio = totalTracked == 0 ? 0 : (state.totalActiveSeconds / totalTracked * 100).round();
    final label = switch (selection.range) {
      DateRange.today => '今日概览',
      DateRange.yesterday => '昨日概览',
      DateRange.week => '本周概览',
      DateRange.month => '本月概览',
      DateRange.custom => '所选日期概览',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: TimeTraceSpace.xs,
          runSpacing: TimeTraceSpace.xs,
          children: [
            for (final (text, range) in const [
              ('今天', DateRange.today),
              ('昨天', DateRange.yesterday),
              ('本周', DateRange.week),
              ('本月', DateRange.month),
            ])
              ChoiceChip(
                label: Text(text),
                selected: selection.range == range,
                onSelected: (_) => onRange(range),
              ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.md),
        Container(
          padding: const EdgeInsets.all(TimeTraceSpace.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest.withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.45)),
              const SizedBox(height: 5),
              Text(
                top == null
                    ? '当前范围还没有足够的活动数据。'
                    : '活跃 ${state.totalActiveLabel}，主要使用 ${top.appName}，活跃占比约 $activeRatio%。',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
              const SizedBox(height: TimeTraceSpace.md),
              LayoutBuilder(
                builder: (context, constraints) {
                  final gap = TimeTraceSpace.sm;
                  final columns = constraints.maxWidth >= 720 ? 3 : 1;
                  final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      SizedBox(width: width, child: _MiniMetric(icon: Icons.apps_rounded, label: '应用', value: '${apps.length}', detail: '当前范围有记录')),
                      SizedBox(width: width, child: _MiniMetric(icon: Icons.track_changes_rounded, label: '活跃占比', value: '$activeRatio%', detail: '活跃 / 总追踪')),
                      SizedBox(width: width, child: _MiniMetric(icon: Icons.trending_up_rounded, label: '最常用', value: top?.appName ?? '—', detail: top?.activeLabel ?? '暂无数据')),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniMetric extends StatelessWidget {
  const _MiniMetric({required this.icon, required this.label, required this.value, required this.detail});
  final IconData icon;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      height: 94,
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.8)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon, size: 15, color: scheme.primary), const SizedBox(width: TimeTraceSpace.xs), Text(label, style: theme.textTheme.labelMedium)]),
          const Spacer(),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(fontSize: 20, fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
          Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({
    required this.day,
    required this.apps,
    required this.selectedApp,
    required this.pages,
    required this.loadingPages,
    required this.rowKeys,
    required this.view,
    required this.onViewChanged,
    required this.onSelectApp,
    required this.onSelectDay,
  });

  final DateTime day;
  final List<AppUsageItem> apps;
  final int? selectedApp;
  final List<PageDto>? pages;
  final bool loadingPages;
  final List<GlobalKey> rowKeys;
  final String view;
  final ValueChanged<String> onViewChanged;
  final ValueChanged<int> onSelectApp;
  final ValueChanged<DateTime> onSelectDay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 800;
        final calendar = _CalendarPanel(day: day, onSelectDay: onSelectDay);
        final detail = _DetailPanel(
          day: day,
          apps: apps,
          selectedApp: selectedApp,
          pages: pages,
          loadingPages: loadingPages,
          rowKeys: rowKeys,
          view: view,
          onViewChanged: onViewChanged,
          onSelectApp: onSelectApp,
        );
        if (narrow) {
          return Column(children: [calendar, const SizedBox(height: TimeTraceSpace.md), detail]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: calendar),
            const SizedBox(width: TimeTraceSpace.md),
            Expanded(flex: 7, child: detail),
          ],
        );
      },
    );
  }
}

class _CalendarPanel extends StatelessWidget {
  const _CalendarPanel({required this.day, required this.onSelectDay});
  final DateTime day;
  final ValueChanged<DateTime> onSelectDay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_month_outlined, size: 17, color: scheme.primary),
              const SizedBox(width: TimeTraceSpace.xs),
              Text('日历', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('选择日期', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          CalendarGrid(selected: day, onSelected: onSelectDay, rowHeight: 50),
        ],
      ),
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({
    required this.day,
    required this.apps,
    required this.selectedApp,
    required this.pages,
    required this.loadingPages,
    required this.rowKeys,
    required this.view,
    required this.onViewChanged,
    required this.onSelectApp,
  });

  final DateTime day;
  final List<AppUsageItem> apps;
  final int? selectedApp;
  final List<PageDto>? pages;
  final bool loadingPages;
  final List<GlobalKey> rowKeys;
  final String view;
  final ValueChanged<String> onViewChanged;
  final ValueChanged<int> onSelectApp;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labels = const {'apps': '应用排行', 'bar': '时间分布', 'hourly': '小时', 'summary': '概要'};
    Widget child;
    if (apps.isEmpty) {
      child = const _EmptyState(text: '暂无使用数据');
    } else {
      child = switch (view) {
        'bar' => AppChartSection(apps: apps, selected: selectedApp, onSelect: onSelectApp, tall: true),
        'hourly' => HourlyChartCard(
            date: day,
            apps: apps,
            selectedName: selectedApp != null && selectedApp! < apps.length ? apps[selectedApp!].appName : null,
            onSelectApp: (name) {
              final index = apps.indexWhere((app) => app.appName == name);
              if (index >= 0) onSelectApp(index);
            },
            onClearSelected: () {},
          ),
        'summary' => DaySummaryPanel(date: day),
        _ => SingleChildScrollView(
            child: AppListSection(
              apps: apps,
              selected: selectedApp,
              pages: pages,
              loading: loadingPages,
              onSelect: onSelectApp,
              rowKeys: rowKeys,
            ),
          ),
      };
    }

    return Container(
      height: 430,
      padding: const EdgeInsets.all(TimeTraceSpace.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [for (final entry in labels.entries) ButtonSegment(value: entry.key, label: Text(entry.value))],
              selected: {view},
              onSelectionChanged: (values) => onViewChanged(values.first),
            ),
          ),
          const SizedBox(height: TimeTraceSpace.sm),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
              child: KeyedSubtree(key: ValueKey(view), child: child),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insights_outlined, size: 32, color: scheme.outlineVariant),
          const SizedBox(height: TimeTraceSpace.xs),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
