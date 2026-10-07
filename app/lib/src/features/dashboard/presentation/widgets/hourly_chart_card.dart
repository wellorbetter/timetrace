import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../../../core/material/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';
import 'package:timetrace_app/src/core/format.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';
import 'package:timetrace_app/src/features/dashboard/providers/hourly_focus_provider.dart';

/// Canonical local-hour buckets from the accepted accounting snapshot.
class HourlyChartCard extends ConsumerStatefulWidget {
  const HourlyChartCard({
    required this.date,
    required this.hours,
    required this.singleDay,
    required this.timezoneAvailable,
    this.selectedName,
    this.onSelectApp,
    this.onClearSelected,
    super.key,
  });

  final DateTime date;
  final List<LocalHourBucketDto> hours;
  final bool singleDay;
  final bool timezoneAvailable;
  final String? selectedName;
  final ValueChanged<String>? onSelectApp;
  final VoidCallback? onClearSelected;

  @override
  ConsumerState<HourlyChartCard> createState() => _HourlyChartCardState();
}

class _HourlyChartCardState extends ConsumerState<HourlyChartCard> {
  int _selected = -1;
  int _start = 0;
  int _end = 0;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _syncBuckets();
    ref.listenManual(hourlyFocusProvider, (_, next) {
      if (next == null || !mounted || !_sameDay(next.date, widget.date)) return;
      final index = widget.hours.indexWhere((h) => h.stableId == next.stableId);
      if (index < 0 || index < _start || index > _end) return;
      setState(() {
        _selected = index;
        _expanded = false;
      });
    });
  }

  @override
  void didUpdateWidget(covariant HourlyChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldIds = oldWidget.hours.map((h) => h.stableId).join('|');
    final newIds = widget.hours.map((h) => h.stableId).join('|');
    if (oldIds != newIds || !_sameDay(oldWidget.date, widget.date))
      _syncBuckets();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _syncBuckets() {
    _start = 0;
    _end = widget.hours.isEmpty ? 0 : widget.hours.length - 1;
    final focus = ref.read(hourlyFocusProvider);
    _selected = focus != null && _sameDay(focus.date, widget.date)
        ? widget.hours.indexWhere((h) => h.stableId == focus.stableId)
        : -1;
    if (_selected < 0) {
      _selected = widget.hours.indexWhere(
        (h) => h.totals.activeSeconds.toInt() > 0,
      );
    }
    _expanded = false;
  }

  bool _repeated(LocalHourBucketDto bucket) =>
      widget.hours.where((h) => h.localHour == bucket.localHour).length > 1;

  void _select(int index) {
    if (index < 0 ||
        index >= widget.hours.length ||
        widget.hours[index].totals.activeSeconds.toInt() <= 0)
      return;
    setState(() {
      _selected = index;
      _expanded = false;
    });
    ref
        .read(hourlyFocusProvider.notifier)
        .focus(widget.date, widget.hours[index]);
  }

  void _setRange(int start, int end) {
    if (start > end) return;
    setState(() {
      _start = start;
      _end = end;
      if (_selected < start || _selected > end) {
        _selected = -1;
        for (var i = start; i <= end; i++) {
          if (widget.hours[i].totals.activeSeconds.toInt() > 0) {
            _selected = i;
            break;
          }
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.singleDay)
      return const _Unavailable(message: '请在日历中选择一天查看时段分布');
    if (!widget.timezoneAvailable) {
      return const _Unavailable(message: '系统时区不可用，无法生成本地小时分布');
    }
    if (widget.hours.isEmpty) return const _Unavailable(message: '当日小时数据暂不可用');

    final bucket = _selected >= 0 ? widget.hours[_selected] : null;
    final selectedApps = bucket == null
        ? const <AttributionTotalDto>[]
        : bucket.apps.where((a) => a.seconds.toInt() > 0).toList();
    final selectedTotal = bucket?.totals.activeSeconds.toInt() ?? 0;
    final first = widget.hours[_start];
    final last = widget.hours[_end];

    return MaterialCard(
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
                  '${hourBucketLabel(first, repeated: _repeated(first))} – ${hourBucketLabel(last, repeated: _repeated(last))}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (widget.hours.length > 1)
              _BucketRangeSlider(
                start: _start,
                end: _end,
                count: widget.hours.length,
                startLabel: hourBucketLabel(first, repeated: _repeated(first)),
                endLabel: hourBucketLabel(last, repeated: _repeated(last)),
                onCommit: _setRange,
              ),
            if (widget.selectedName != null)
              Row(
                children: [
                  Icon(Icons.link, size: 12, color: scheme.primary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '已选应用：${widget.selectedName}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.primary),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 13,
                    onPressed: widget.onClearSelected,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            Text(
              '拖动范围筛选本地小时桶 · 点柱查看 Rust 归因明细',
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _HourlyBarChart(
                hours: widget.hours,
                selected: _selected,
                start: _start,
                end: _end,
                onSelect: _select,
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 112,
              child: SingleChildScrollView(
                child: _HourDetail(
                  apps: selectedApps,
                  total: selectedTotal,
                  expanded: _expanded,
                  highlightName: widget.selectedName,
                  onAppTap: widget.onSelectApp ?? (_) {},
                  onToggle: () => setState(() => _expanded = !_expanded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => MaterialCard(
    child: Center(
      child: Text(
        message,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    ),
  );
}

class _HourlyBarChart extends StatelessWidget {
  const _HourlyBarChart({
    required this.hours,
    required this.selected,
    required this.start,
    required this.end,
    required this.onSelect,
  });
  final List<LocalHourBucketDto> hours;
  final int selected;
  final int start;
  final int end;
  final ValueChanged<int> onSelect;
  bool _repeated(LocalHourBucketDto b) =>
      hours.where((h) => h.localHour == b.localHour).length > 1;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxY = hours
        .fold<int>(
          1,
          (m, h) => h.totals.activeSeconds.toInt() > m
              ? h.totals.activeSeconds.toInt()
              : m,
        )
        .toDouble();
    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(
          touchCallback: (event, response) {
            if (event.isInterestedForInteractions && response?.spot != null)
              onSelect(start + response!.spot!.touchedBarGroupIndex);
          },
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, _, __, ___) {
              final b = hours[group.x];
              final seconds = b.totals.activeSeconds.toInt();
              return seconds <= 0
                  ? null
                  : BarTooltipItem(
                      '${hourBucketLabel(b, repeated: _repeated(b))}\n${formatDuration(seconds)}',
                      const TextStyle(color: Colors.white, fontSize: 10),
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
                final i = value.toInt();
                if (i < start || i > end) return const SizedBox.shrink();
                final step = end - start > 12 ? 6 : 3;
                if (i != start && i != end && (i - start) % step != 0)
                  return const SizedBox.shrink();
                final b = hours[i];
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    hourBucketLabel(b, repeated: _repeated(b), compact: true),
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
          for (var i = start; i <= end; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: hours[i].totals.activeSeconds.toInt().toDouble(),
                  width: 7,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(3),
                  ),
                  color: i == selected
                      ? scheme.primary
                      : scheme.primary.withValues(alpha: 0.55),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _BucketRangeSlider extends StatefulWidget {
  const _BucketRangeSlider({
    required this.start,
    required this.end,
    required this.count,
    required this.startLabel,
    required this.endLabel,
    required this.onCommit,
  });
  final int start;
  final int end;
  final int count;
  final String startLabel;
  final String endLabel;
  final void Function(int, int) onCommit;
  @override
  State<_BucketRangeSlider> createState() => _BucketRangeSliderState();
}

class _BucketRangeSliderState extends State<_BucketRangeSlider> {
  late RangeValues _values = RangeValues(
    widget.start.toDouble(),
    widget.end.toDouble(),
  );
  @override
  void didUpdateWidget(covariant _BucketRangeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.start != widget.start || oldWidget.end != widget.end)
      _values = RangeValues(widget.start.toDouble(), widget.end.toDouble());
  }

  @override
  Widget build(BuildContext context) => RangeSlider(
    values: _values,
    min: 0,
    max: (widget.count - 1).toDouble(),
    divisions: widget.count - 1,
    labels: RangeLabels(widget.startLabel, widget.endLabel),
    onChanged: (v) => setState(() => _values = v),
    onChangeEnd: (v) => widget.onCommit(v.start.round(), v.end.round()),
  );
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
  final List<AttributionTotalDto> apps;
  final int total;
  final bool expanded;
  final String? highlightName;
  final ValueChanged<String> onAppTap;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (apps.isEmpty)
      return Text(
        '该小时暂无活跃应用',
        style: TextStyle(fontSize: 12, color: scheme.outline),
      );
    final visible = expanded ? apps.length : apps.length.clamp(0, 5);
    return Column(
      children: [
        for (var i = 0; i < visible; i++)
          _AppRow(
            app: apps[i],
            total: total,
            highlighted: apps[i].id == highlightName,
            onTap: () => onAppTap(apps[i].id),
          ),
        if (apps.length > 5)
          TextButton(
            onPressed: onToggle,
            child: Text(expanded ? '收起' : '展开全部'),
          ),
      ],
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.total,
    required this.highlighted,
    required this.onTap,
  });
  final AttributionTotalDto app;
  final int total;
  final bool highlighted;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final seconds = app.seconds.toInt();
    final fraction = total <= 0 ? 0.0 : seconds / total;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 22,
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: appColor(app.id),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                app.id,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: highlighted ? scheme.primary : null,
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 5,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${(fraction * 100).round()}%',
              style: const TextStyle(fontSize: 10),
            ),
            const SizedBox(width: 4),
            Text(
              formatDuration(seconds),
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
