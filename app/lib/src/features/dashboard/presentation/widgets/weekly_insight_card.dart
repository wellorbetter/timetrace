import 'package:flutter/material.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_color.dart';

/// Weekly insight card: total active hours this week vs last week.
class WeeklyInsightCard extends StatelessWidget {
  const WeeklyInsightCard({required this.thisWeek, required this.lastWeek, super.key});

  final int thisWeek; // active seconds this week (Mon → today)
  final int lastWeek; // active seconds last week (full week)

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = thisWeek - lastWeek;
    final pct = lastWeek > 0 ? (diff / lastWeek * 100).round() : null;

    // Compute 7-day mini bar chart (this week's days normalized)
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.trending_up, size: 18, color: scheme.primary),
                const SizedBox(width: 6),
                Text('本周洞察',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: _InsightStat(
                    label: '本周活跃',
                    value: _fmt(thisWeek),
                    color: scheme.primary,
                  ),
                ),
                Expanded(
                  child: _InsightStat(
                    label: '上周活跃',
                    value: _fmt(lastWeek),
                    color: scheme.outline,
                  ),
                ),
                if (pct != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          pct >= 0 ? '+$pct%' : '$pct%',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: pct >= 0
                                ? Colors.green.shade700
                                : scheme.error,
                          ),
                        ),
                        Text(
                          pct >= 0 ? '上升' : '下降',
                          style: TextStyle(fontSize: 11, color: scheme.outline),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Mini 7-day bar
            SizedBox(
              height: 24,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 7; i++)
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: _dayFactor(i),
                          child: Container(
                            decoration: BoxDecoration(
                              color: scheme.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Deterministic pseudo-daily factors (0.3–1.0) — placeholder for real daily data.
  double _dayFactor(int day) {
    const factors = [0.6, 0.8, 0.45, 0.9, 1.0, 0.3, 0.5];
    return factors[day % 7];
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '${h}h${m}m' : '${m}m';
  }
}

class _InsightStat extends StatelessWidget {
  const _InsightStat(
      {required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}
