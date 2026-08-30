import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

/// 24-hour activity distribution with a compact detail list for the selected
/// hour. The visual hierarchy stays deliberately quiet: controls are secondary,
/// the chart is the focus, and accent color is reserved for selection.
class HourlyChartCard extends ConsumerStatefulWidget {
  const HourlyChartCard({
    required this.date,
    required this.apps,
    this.rangeStart,
    this.rangeEnd,
    this.rangeLabel,
    this.selectedName,
    this.onSelectApp,
    this.onClearSelected,
    super.key,
  });

  final DateTime date;
  final List<AppUsageItem> apps;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final String? rangeLabel;
  final String? selectedName;
  final ValueChanged<String>? onSelectApp;
  final VoidCallback? onClearSelected;

  @override
  ConsumerState<HourlyChartCard> createState() => _HourlyChartCardState();
}

class _HourlyChartCardState extends ConsumerState<HourlyChartCard> {
  List<int> _hourly = List.filled(24, 0);
  final Map<int, List<AppUsageDto>> _hourApps = {};

  int _selectedHour = -1;
  int _startHour = 0;
  int _endHour = 23;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
    ref.listenManual(hourlyFocusProvider, (prev, next) {
      if (next == null || !mounted) return;
      _applyFocus(next);
    });
  }

  @override
  void didUpdateWidget(covariant HourlyChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dateKey(_startOf(oldWidget)) != _dateKey(startDate) ||
        _dateKey(_endOf(oldWidget)) != _dateKey(endDate)) {
      _load();
    }
  }

  DateTime get startDate => widget.rangeStart ?? widget.date;
  DateTime get endDate => widget.rangeEnd ?? widget.date;

  DateTime _startOf(HourlyChartCard value) => value.rangeStart ?? value.date;
  DateTime _endOf(HourlyChartCard value) => value.rangeEnd ?? value.date;

  bool get isSingleDay => _sameDay(startDate, endDate);

  String _dateKey(DateTime date) => '${date.year}-${date.month}-${date.day}';

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _load() {
    final api = ref.read(apiProvider);
    final hourly = List<int>.filled(24, 0);
    for (final date in _datesInRange()) {
      final day = api.getDayHourly(date: _fmt(date));
      for (var hour = 0; hour < hourly.length && hour < day.length; hour++) {
        hourly[hour] += day[hour].toInt();
      }
    }
    _hourApps.clear();
    final focus = ref.read(hourlyFocusProvider);
    var sel = -1;
    if (isSingleDay && focus != null && _sameDay(focus.date, startDate)) {
      sel = focus.hour;
    }
    if (sel < 0 || sel >= hourly.length || hourly[sel] == 0) {
      sel = hourly.indexWhere((v) => v > 0);
    }
    if (sel >= 0 && sel < hourly.length) {
      _hourApps[sel] = _appsOf(sel);
    }
    _hourly = hourly;
    _selectedHour = sel;
    _expanded = false;
  }

  void _applyFocus(HourlyFocus focus) {
    if (!isSingleDay || !_sameDay(focus.date, startDate)) return;
    final h = focus.hour;
    if (h < 0 || h >= _hourly.length || _hourly[h] == 0) return;
    if (h < _startHour || h > _endHour) return;
    if (h == _selectedHour) return;
    setState(() {
      _selectedHour = h;
      _expanded = false;
      _hourApps.putIfAbsent(h, () => _appsOf(h));
    });
  }

  void _selectHour(int hour) {
    if (hour < 0 || hour >= _hourly.length || _hourly[hour] == 0) return;
    if (hour == _selectedHour) return;
    setState(() {
      _selectedHour = hour;
      _expanded = false;
      _hourApps.putIfAbsent(hour, () => _appsOf(hour));
    });
  }

  void _setRange(int start, int end) {
    if (start > end) return;
    setState(() {
      _startHour = start;
      _endHour = end;
      if (_selectedHour < start || _selectedHour > end) {
        _selectedHour = -1;
        for (var h = start; h <= end; h++) {
          if (_hourly[h] > 0) {
            _selectedHour = h;
            break;
          }
        }
      }
    });
  }

  List<AppUsageDto> _appsOf(int hour) {
    final cached = _hourApps[hour];
    if (cached != null) return cached;
    final api = ref.read(apiProvider);
    final raw = <AppUsageDto>[
      for (final date in _datesInRange())
        ...api.getHourApps(date: _fmt(date), hour: hour),
    ];
    final merged = _mergeByName(raw);
    _hourApps[hour] = merged;
    return merged;
  }

  Iterable<DateTime> _datesInRange() sync* {
    for (
      var day = DateTime(startDate.year, startDate.month, startDate.day);
      !day.isAfter(endDate);
      day = day.add(const Duration(days: 1))
    ) {
      yield day;
    }
  }

  List<AppUsageDto> _mergeByName(List<AppUsageDto> raw) {
    final totals = <String, int>{};
    final executables = <String, String>{};
    for (final a in raw) {
      final name = a.appName;
      totals[name] = (totals[name] ?? 0) + a.activeSeconds.toInt();
      if (a.exePath.isNotEmpty) executables.putIfAbsent(name, () => a.exePath);
    }
    final list =
        totals.entries
            .map(
              (e) => AppUsageDto(
                appName: e.key,
                activeSeconds: e.value,
                idleSeconds: 0,
                exePath: executables[e.key] ?? '',
              ),
            )
            .toList()
          ..sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasData = widget.apps.isNotEmpty && _hourly.any((v) => v > 0);
    final rangeTotal = _hourly
        .sublist(_startHour, _endHour + 1)
        .fold<int>(0, (s, v) => s + v);
    final selName = widget.selectedName;

    final hourApps = _selectedHour >= 0
        ? _appsOf(
            _selectedHour,
          ).where((a) => a.activeSeconds.toInt() > 0).toList()
        : const <AppUsageDto>[];
    final hourTotal = _selectedHour >= 0
        ? hourApps.fold<int>(0, (s, a) => s + a.activeSeconds.toInt())
        : 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(TimeTraceSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  widget.rangeLabel == null
                      ? '时段分布'
                      : '时段分布 · ${widget.rangeLabel}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$_startHour:00 – $_endHour:00',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            _RangeSlider(start: _startHour, end: _endHour, onCommit: _setRange),
            if (selName != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: TimeTraceSpace.xs,
                  vertical: TimeTraceSpace.xxs,
                ),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.46),
                  borderRadius: BorderRadius.circular(TimeTraceRadius.small),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.link_rounded,
                      size: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: TimeTraceSpace.xxs),
                    Flexible(
                      child: Text(
                        selName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.onClearSelected != null) ...[
                      const SizedBox(width: TimeTraceSpace.xxs),
                      InkWell(
                        onTap: widget.onClearSelected,
                        borderRadius: BorderRadius.circular(
                          TimeTraceRadius.small,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(1),
                          child: Icon(
                            Icons.close_rounded,
                            size: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: TimeTraceSpace.xxs),
            ],
            Text(
              '点击柱查看该小时 · 当前区间活跃 ${formatDuration(rangeTotal)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xs),
            if (!hasData)
              Expanded(
                child: Center(
                  child: Text(
                    isSingleDay ? '该日暂无活跃数据' : '该范围暂无活跃数据',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else ...[
              Expanded(
                child: _HourlyBarChart(
                  hourly: _hourly,
                  selectedHour: _selectedHour,
                  startHour: _startHour,
                  endHour: _endHour,
                  onSelect: _selectHour,
                ),
              ),
              const SizedBox(height: TimeTraceSpace.xs),
              SizedBox(
                height: 112,
                child: SingleChildScrollView(
                  child: _HourDetail(
                    apps: hourApps,
                    total: hourTotal,
                    expanded: _expanded,
                    highlightName: selName,
                    onAppTap: widget.onSelectApp ?? (_) {},
                    onToggle: () => setState(() => _expanded = !_expanded),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HourlyBarChart extends StatelessWidget {
  const _HourlyBarChart({
    required this.hourly,
    required this.selectedHour,
    required this.startHour,
    required this.endHour,
    required this.onSelect,
  });

  final List<int> hourly;
  final int selectedHour;
  final int startHour;
  final int endHour;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxY = hourly.fold<int>(1, (m, v) => v > m ? v : m).toDouble();

    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(
          touchCallback: (event, response) {
            if (!event.isInterestedForInteractions) return;
            final spot = response?.spot;
            if (spot == null) return;
            onSelect(startHour + spot.touchedBarGroupIndex);
          },
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final v = hourly[group.x];
              if (v <= 0) return null;
              return BarTooltipItem(
                '${group.x}时\n${formatDuration(v)}',
                const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 18,
              getTitlesWidget: (value, meta) {
                final h = value.toInt();
                if (h < startHour || h > endHour)
                  return const SizedBox.shrink();
                final span = endHour - startHour;
                final step = span > 12 ? 6 : 3;
                final show =
                    h == startHour ||
                    h == endHour ||
                    (h - startHour) % step == 0;
                if (!show) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    '$h',
                    style: TextStyle(
                      fontSize: 9,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var h = startHour; h <= endHour; h++)
            BarChartGroupData(
              x: h,
              barRods: [
                BarChartRodData(
                  toY: hourly[h].toDouble(),
                  width: 6,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                  color: h == selectedHour
                      ? scheme.primary
                      : scheme.primary.withValues(alpha: 0.34),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RangeSlider extends StatefulWidget {
  const _RangeSlider({
    required this.start,
    required this.end,
    required this.onCommit,
  });

  final int start;
  final int end;
  final void Function(int start, int end) onCommit;

  @override
  State<_RangeSlider> createState() => _RangeSliderState();
}

class _RangeSliderState extends State<_RangeSlider> {
  late RangeValues _values;

  @override
  void initState() {
    super.initState();
    _values = RangeValues(widget.start.toDouble(), widget.end.toDouble());
  }

  @override
  void didUpdateWidget(covariant _RangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.start != widget.start || oldWidget.end != widget.end) {
      _values = RangeValues(widget.start.toDouble(), widget.end.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        activeTrackColor: scheme.primary.withValues(alpha: 0.7),
        inactiveTrackColor: scheme.outlineVariant,
        overlayColor: scheme.primary.withValues(alpha: 0.08),
      ),
      child: RangeSlider(
        values: _values,
        min: 0,
        max: 23,
        divisions: 23,
        labels: RangeLabels(
          '${_values.start.round()}时',
          '${_values.end.round()}时',
        ),
        onChanged: (v) => setState(() => _values = v),
        onChangeEnd: (v) => widget.onCommit(v.start.round(), v.end.round()),
      ),
    );
  }
}

class _HourDetail extends StatelessWidget {
  const _HourDetail({
    required this.apps,
    required this.total,
    required this.expanded,
    required this.highlightName,
    required this.onAppTap,
    required this.onToggle,
  });

  final List<AppUsageDto> apps;
  final int total;
  final bool expanded;
  final String? highlightName;
  final ValueChanged<String> onAppTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (apps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: TimeTraceSpace.xxs),
        child: Text(
          '该小时暂无活跃应用',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final visible = expanded
        ? apps.length
        : (apps.length > 5 ? 5 : apps.length);
    final hasMore = apps.length > 5;
    final pct = total <= 0 ? 0.0 : (100.0 / total);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < visible; i++)
          _AppRow(
            app: apps[i],
            pctFactor: pct,
            highlighted: apps[i].appName == highlightName,
            onTap: () => onAppTap(apps[i].appName),
          ),
        if (hasMore)
          TextButton.icon(
            onPressed: onToggle,
            icon: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 15,
            ),
            label: Text(expanded ? '收起' : '展开全部'),
            style: TextButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              textStyle: theme.textTheme.labelSmall,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(
                horizontal: TimeTraceSpace.xs,
              ),
            ),
          ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.pctFactor,
    required this.highlighted,
    required this.onTap,
  });

  final AppUsageDto app;
  final double pctFactor;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seconds = app.activeSeconds.toInt();
    final color = appColor(app.appName);
    final pct = (seconds * pctFactor).round();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TimeTraceRadius.small),
      child: AnimatedContainer(
        duration: TimeTraceMotion.fast,
        curve: TimeTraceMotion.standard,
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xxs),
        decoration: BoxDecoration(
          color: highlighted
              ? scheme.primaryContainer.withValues(alpha: 0.52)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(TimeTraceRadius.small),
        ),
        child: Row(
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Expanded(
              child: Text(
                app.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: highlighted ? FontWeight.w600 : FontWeight.w500,
                  color: scheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            Container(
              width: 52,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (pct / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.82),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xs),
            SizedBox(
              width: 30,
              child: Text(
                '$pct%',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: TimeTraceSpace.xxs),
            SizedBox(
              width: 48,
              child: Text(
                formatDuration(seconds),
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
