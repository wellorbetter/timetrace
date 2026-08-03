import 'package:table_calendar/table_calendar.dart';
import 'package:flutter/material.dart';

/// Weekly insight using the open-source `table_calendar` widget.
/// This week vs last week totals + calendar with day activity badges.
class WeeklyInsightCard extends StatefulWidget {
  const WeeklyInsightCard(
      {required this.thisWeek, required this.lastWeek, super.key});

  final int thisWeek; // active seconds this week (Mon → today)
  final int lastWeek; // active seconds last week (full week)

  @override
  State<WeeklyInsightCard> createState() => _WeeklyInsightCardState();
}

class _WeeklyInsightCardState extends State<WeeklyInsightCard> {
  DateTime _focusedDay = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = widget.thisWeek - widget.lastWeek;
    final hasLastWeek = widget.lastWeek > 0;

    String trend;
    IconData trendIcon;
    Color trendColor;
    if (!hasLastWeek) {
      trend = '上周无数据';
      trendIcon = Icons.info_outline;
      trendColor = scheme.outline;
    } else if (diff > 0) {
      trend = '较上周 +${_fmt(diff)} (${(diff / widget.lastWeek * 100).round()}%)';
      trendIcon = Icons.trending_up;
      trendColor = Colors.green.shade700;
    } else if (diff < 0) {
      trend = '较上周 -${_fmt(-diff)} (${(diff / widget.lastWeek * 100).round()}%)';
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
            // Header
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
            const SizedBox(height: 8),
            // Open-source calendar (table_calendar)
            TableCalendar(
              firstDay: DateTime(now.year, now.month, 1),
              lastDay: DateTime(now.year, now.month, 28),
              focusedDay: _focusedDay,
              selectedDayPredicate: (d) => isSameDay(d, now),
              onDaySelected: (selected, focused) {
                setState(() => _focusedDay = focused);
              },
              calendarFormat: CalendarFormat.week,
              availableCalendarFormats: const {CalendarFormat.week: '周'},
              headerStyle: HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
                titleTextStyle:
                    TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
              daysOfWeekStyle: DaysOfWeekStyle(
                weekdayStyle: TextStyle(fontSize: 11, color: scheme.outline),
                weekendStyle: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              calendarStyle: CalendarStyle(
                outsideDaysVisible: false,
                defaultTextStyle:
                    TextStyle(fontSize: 12, color: scheme.onSurface),
                weekendTextStyle:
                    TextStyle(fontSize: 12, color: scheme.onSurface),
                todayDecoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.25),
                  shape: BoxShape.circle,
                ),
                selectedDecoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const Divider(height: 16),
            // Totals
            Row(
              children: [
                _MiniStat(label: '本周', seconds: widget.thisWeek, color: scheme.primary),
                const SizedBox(width: 20),
                _MiniStat(label: '上周', seconds: widget.lastWeek, color: scheme.outline),
              ],
            ),
          ],
        ),
      ),
    );
  }

  DateTime get now => DateTime.now();

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
        Container(
            width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
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
