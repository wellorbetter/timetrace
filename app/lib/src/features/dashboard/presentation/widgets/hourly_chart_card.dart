import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

/// 时段分布 — 24h 活跃柱状图 + 选中小时的 App 占比明细。
/// - 支持自定义起/止小时区间，图表只画区间内的柱；
/// - 明细固定高度（内部滚动），切换小时/展开不再挤压图表；
/// - 明细按归一化应用名合并（与仪表盘其它图表一致），点击行联动
///   选中该应用并跳转应用列表；与日历 24h 热力条双向联动。
class HourlyChartCard extends ConsumerStatefulWidget {
  const HourlyChartCard({
    required this.date,
    required this.apps,
    this.selectedName,
    this.onSelectApp,
    this.onClearSelected,
    super.key,
  });

  /// 所选日历日（决定 getDayHourly / getHourApps 的查询日期）。
  final DateTime date;

  /// 当日应用列表，用于空数据占位判断。
  final List<AppUsageItem> apps;

  /// 当前选中的应用名（柱状图/应用列表联动），高亮对应明细行。
  final String? selectedName;

  /// 点击某应用明细行：选中该应用并跳转到应用列表页。
  final ValueChanged<String>? onSelectApp;

  /// 清除已选应用联动。
  final VoidCallback? onClearSelected;

  @override
  ConsumerState<HourlyChartCard> createState() => _HourlyChartCardState();
}

class _HourlyChartCardState extends ConsumerState<HourlyChartCard> {
  List<int> _hourly = List.filled(24, 0);

  /// hour -> 该小时 App 活跃数据（归一化合并后，同步 FFI 缓存）。
  final Map<int, List<AppUsageDto>> _hourApps = {};

  int _selectedHour = -1;
  int _startHour = 0;
  int _endHour = 23;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _load();
    // 日历 24h 热力条 → 选中该小时（页面已构建时即时响应）。
    ref.listenManual(hourlyFocusProvider, (prev, next) {
      if (next == null || !mounted) return;
      _applyFocus(next);
    });
  }

  @override
  void didUpdateWidget(covariant HourlyChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.date.year != widget.date.year ||
        oldWidget.date.month != widget.date.month ||
        oldWidget.date.day != widget.date.day) {
      _load();
    }
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// 同步加载当日 24h 数据；优先热力条焦点小时，否则当前小时，
  /// 再否则第一个有数据的小时。
  void _load() {
    final api = ref.read(apiProvider);
    final date = _fmt(widget.date);
    // FRB maps i64 lists to BigInt on native; normalize to int buckets.
    final hourly = api.getDayHourly(date: date).map((v) => v.toInt()).toList();
    _hourApps.clear();
    final focus = ref.read(hourlyFocusProvider);
    var sel = -1;
    if (focus != null && _sameDay(focus.date, widget.date)) {
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
    if (!_sameDay(focus.date, widget.date)) return;
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

  /// 该小时 App 数据，按归一化应用名合并，缓存。
  List<AppUsageDto> _appsOf(int hour) {
    final cached = _hourApps[hour];
    if (cached != null) return cached;
    final raw = ref
        .read(apiProvider)
        .getHourApps(date: _fmt(widget.date), hour: hour);
    final merged = _mergeByName(raw);
    _hourApps[hour] = merged;
    return merged;
  }

  List<AppUsageDto> _mergeByName(List<AppUsageDto> raw) {
    final totals = <String, int>{};
    String exe = '';
    for (final a in raw) {
      final name = normalizeAppName(a.appName);
      totals[name] = (totals[name] ?? 0) + a.activeSeconds.toInt();
      if (exe.isEmpty && a.exePath.isNotEmpty) exe = a.exePath;
    }
    final list = totals.entries
        .map(
          (e) => AppUsageDto(
            appName: e.key,
            activeSeconds: e.value,
            idleSeconds: 0,
            exePath: exe,
          ),
        )
        .toList()
      ..sort((a, b) => b.activeSeconds.compareTo(a.activeSeconds));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasData = widget.apps.isNotEmpty && _hourly.any((v) => v > 0);
    final rangeTotal = _hourly
        .sublist(_startHour, _endHour + 1)
        .fold<int>(0, (s, v) => s + v);
    final selName = widget.selectedName;

    final hourApps = _selectedHour >= 0
        ? _appsOf(_selectedHour)
              .where((a) => a.activeSeconds.toInt() > 0)
              .toList()
        : const <AppUsageDto>[];
    final hourTotal = _selectedHour >= 0
        ? hourApps.fold<int>(0, (s, a) => s + a.activeSeconds.toInt())
        : 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '时段分布',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '$_startHour:00–$_endHour:00',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            // 24h 区间滑杆：当天 0–23 点任意起止。
            _RangeSlider(
              start: _startHour,
              end: _endHour,
              onCommit: (s, e) => _setRange(s, e),
            ),
            if (selName != null) ...[
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.link, size: 12, color: scheme.primary),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '已选应用：$selName',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.onClearSelected != null) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: widget.onClearSelected,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.close,
                          size: 13,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
            const SizedBox(height: 2),
            Text(
              '点柱查看该小时占比 · 当前区间活跃 ${formatDuration(rangeTotal)}',
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
            const SizedBox(height: 6),
            if (!hasData)
              Expanded(
                child: Center(
                  child: Text(
                    '该日暂无活跃数据',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
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
              const SizedBox(height: 6),
              // 固定高度明细：切换小时/展开不再改变图表区域大小，避免伸缩抖动。
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

/// 24h 柱状图（仅画 [startHour, endHour] 区间）。
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
            // barGroups 只含 [startHour, endHour]，索引需换算回真实小时。
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
                if (h < startHour || h > endHour) return const SizedBox.shrink();
                final span = endHour - startHour;
                final step = span > 12 ? 6 : 3;
                final show =
                    h == startHour || h == endHour || (h - startHour) % step == 0;
                if (!show) return const SizedBox.shrink();
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    '$h',
                    style: TextStyle(fontSize: 9, color: scheme.outline),
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
                  width: 7,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: h == selectedHour
                        ? [
                            scheme.primary,
                            scheme.primary.withValues(alpha: 0.7),
                          ]
                        : [
                            scheme.primary.withValues(alpha: 0.35),
                            scheme.primary.withValues(alpha: 0.7),
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

/// 24h 区间滑杆：拖拽时本地更新，松手才提交，避免图表逐帧重建。
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
      _values =
          RangeValues(widget.start.toDouble(), widget.end.toDouble());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RangeSlider(
      values: _values,
      min: 0,
      max: 23,
      divisions: 23,
      labels: RangeLabels(
        '${_values.start.round()}时',
        '${_values.end.round()}时',
      ),
      activeColor: scheme.primary,
      inactiveColor: scheme.surfaceContainerHighest,
      onChanged: (v) => setState(() => _values = v),
      onChangeEnd: (v) => widget.onCommit(v.start.round(), v.end.round()),
    );
  }
}

/// 选中小时的应用占比列表：色点 + 名称 + 进度条 + 百分比 + 时长。
/// 最多显示 5 行，超出可"展开全部"；已选应用高亮，点击行联动。
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
    final scheme = Theme.of(context).colorScheme;
    if (apps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '该小时暂无活跃应用',
          style: TextStyle(fontSize: 12, color: scheme.outline),
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
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    expanded ? '收起' : '展开全部',
                    style: TextStyle(fontSize: 11, color: scheme.primary),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: scheme.primary,
                  ),
                ],
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
    final scheme = Theme.of(context).colorScheme;
    final seconds = app.activeSeconds.toInt();
    final color = appColor(app.appName);
    final pct = (seconds * pctFactor).round();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: highlighted ? scheme.primary.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                app.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: highlighted ? FontWeight.w600 : FontWeight.normal,
                  color: highlighted ? scheme.primary : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 56,
              height: 6,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: (pct / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$pct%',
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            Text(
              formatDuration(seconds),
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
            if (highlighted) ...[
              const SizedBox(width: 4),
              Icon(Icons.check_circle, size: 12, color: scheme.primary),
            ],
          ],
        ),
      ),
    );
  }
}
