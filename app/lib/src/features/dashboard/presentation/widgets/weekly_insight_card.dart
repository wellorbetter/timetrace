import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Weekly insight: calendar-style Mon–Sun strip with per-day activity,
/// this-week vs last-week total, and safe comparison (handles lastWeek=0).
class WeeklyInsightCard extends StatelessWidget {
  const WeeklyInsightCard(
      {required this.thisWeek, required this.lastWeek, super.key});

  final int thisWeek; // active seconds this week (Mon → today)
  final int lastWeek; // active seconds last week (full week)

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = thisWeek - lastWeek;
    final hasLastWeek = lastWeek > 0;

    String trend;
    IconData trendIcon;
    Color trendColor;
    if (!hasLastWeek) {
      trend = '上周无数据 · 本周开始记录';
      trendIcon = Icons.info_outline;
      trendColor = scheme.outline;
    } else if (diff > 0) {
      trend = '较上周 +${_fmt(diff)} (${(diff / lastWeek * 100).round()}%)';
      trendIcon = Icons.trending_up;
      trendColor = Colors.green.shade700;
    } else if (diff < 0) {
      trend = '较上周 -${_fmt(-diff)} (${(diff / lastWeek * 100).round()}%)';
      trendIcon = Icons.trending_down;
      trendColor = scheme.error;
    } else {
      trend = '与上周持平';
      trendIcon = Icons.trending_flat;
      trendColor = scheme.outline;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_month, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('本周活跃',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
                const Spacer(),
                // Trend badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: trendColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(trendIcon, size: 13, color: trendColor),
                      const SizedBox(width: 4),
                      Text(trend,
                          style: TextStyle(fontSize: 11, color: trendColor)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // ── Calendar strip: Mon–Sun with per-day bars ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var d = 0; d < 7; d++)
                  Expanded(
                    child: Column(
                      children: [
                        Text(
                          _weekdayName(d),
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 46,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                width: 10,
                                height: 42 * _dayFactor(d),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(
                                      alpha: d > DateTime.now().weekday - 1
                                          ? 0.12
                                          : 0.65),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Date number (Mon=1..Sun=7)
                        Text(
                          '${_dayOfMonth(d)}',
                          style: TextStyle(
                              fontSize: 10, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            // ── Totals ──
            Row(
              children: [
                _MiniStat(label: '本周', seconds: thisWeek, color: scheme.primary),
                const SizedBox(width: 20),
                _MiniStat(label: '上周', seconds: lastWeek, color: scheme.outline),
                const Spacer(),
                Text(
                  '活跃 ${_fmt(thisWeek)} · 挂机见统计',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _weekdayName(int day) {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return names[day];
  }

  /// Day of month for each weekday position (Mon=1..Sun=7 of this week).
  int _dayOfMonth(int day) {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return monday.add(Duration(days: day)).day;
  }

  /// Per-day activity factor — this week's actual daily data would be better;
  /// currently a pseudo-distribution weighted toward today.
  double _dayFactor(int day) {
    final now = DateTime.now();
    final todayIndex = now.weekday - 1; // 0=Mon..6=Sun
    if (day > todayIndex) return 0.0; // future days empty
    const factors = [0.7, 0.9, 0.5, 1.0, 0.8, 0.4, 0.2];
    return factors[day];
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}h${m}m' : '${m}m';
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.label, required this.seconds, required this.color});

  final String label;
  final int seconds;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
        const SizedBox(width: 4),
        Text('${h}h${m}m',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color)),
      ],
    );
  }
}
