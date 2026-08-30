import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/core/chinese_calendar.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';

/// Quiet desktop month calendar reused by the dashboard and journal views.
/// Usage is shown as a restrained accent tint; selection relies on border and
/// soft fill instead of large saturated circles.
class CalendarGrid extends ConsumerStatefulWidget {
  const CalendarGrid({
    required this.selected,
    required this.onSelected,
    this.rowHeight = 50,
    super.key,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final double rowHeight;

  @override
  ConsumerState<CalendarGrid> createState() => _CalendarGridState();
}

class _CalendarGridState extends ConsumerState<CalendarGrid> {
  DateTime _focused = DateTime.now();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final data = ref.watch(calendarDataProvider).value;

    return TableCalendar(
      firstDay: DateTime(_focused.year, 1, 1),
      lastDay: DateTime(_focused.year, 12, 31),
      focusedDay: _focused,
      selectedDayPredicate: (d) => isSameDay(d, widget.selected),
      onDaySelected: (selected, focused) {
        setState(() => _focused = focused);
        widget.onSelected(selected);
      },
      calendarFormat: CalendarFormat.month,
      headerStyle: HeaderStyle(
        titleCentered: true,
        formatButtonVisible: false,
        headerPadding: const EdgeInsets.only(bottom: TimeTraceSpace.xs),
        leftChevronPadding: const EdgeInsets.all(TimeTraceSpace.xxs),
        rightChevronPadding: const EdgeInsets.all(TimeTraceSpace.xxs),
        titleTextStyle: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ) ??
            TextStyle(color: scheme.onSurface),
        leftChevronIcon: Icon(
          Icons.chevron_left_rounded,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
        rightChevronIcon: Icon(
          Icons.chevron_right_rounded,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ),
      daysOfWeekHeight: 24,
      rowHeight: widget.rowHeight,
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ) ??
            TextStyle(color: scheme.onSurfaceVariant),
        weekendStyle: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ) ??
            TextStyle(color: scheme.onSurfaceVariant),
      ),
      calendarStyle: CalendarStyle(
        outsideDaysVisible: false,
        cellMargin: EdgeInsets.zero,
        defaultTextStyle: theme.textTheme.bodyMedium ?? const TextStyle(),
      ),
      calendarBuilders: CalendarBuilders(
        defaultBuilder: (context, day, focused) =>
            _dayCell(day, scheme, data),
        selectedBuilder: (context, day, focused) =>
            _dayCell(day, scheme, data, selected: true),
        todayBuilder: (context, day, focused) =>
            _dayCell(day, scheme, data, today: true),
        outsideBuilder: (context, day, focused) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _dayCell(
    DateTime day,
    ColorScheme scheme,
    CalendarData? data, {
    bool selected = false,
    bool today = false,
  }) {
    final images = data?.images ?? const {};
    final diaryDays = data?.diaryDays ?? const <String>{};
    final usage = data?.usage ?? const <String, int>{};
    final maxUsage = data?.maxUsage ?? 0;
    final dateStr = calFmt(day);
    final imgs = images[dateStr] ?? [];
    final hasDiary = diaryDays.contains(dateStr);
    final info = lunarInfo(day);
    final usageSec = usage[dateStr] ?? 0;
    final intensity = maxUsage == 0
        ? 0.0
        : (usageSec / maxUsage).clamp(0.0, 1.0).toDouble();

    final isFestival = info.festival != null;
    final heat = usageSec > 0
        ? scheme.primary.withValues(alpha: 0.035 + 0.10 * intensity)
        : Colors.transparent;

    String? sub;
    if (info.hasMarker) {
      sub = info.festival ?? info.solarTerm;
    } else if (info.day.isNotEmpty) {
      sub = info.day;
    }

    final foreground = selected
        ? scheme.onPrimaryContainer
        : isFestival
            ? scheme.tertiary
            : today
                ? scheme.primary
                : scheme.onSurface;
    final secondaryForeground = selected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.72)
        : isFestival
            ? scheme.tertiary.withValues(alpha: 0.82)
            : scheme.onSurfaceVariant;

    return Center(
      child: AnimatedContainer(
        duration: TimeTraceMotion.fast,
        curve: TimeTraceMotion.standard,
        width: 42,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : today
                  ? scheme.primaryContainer.withValues(alpha: 0.42)
                  : heat,
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.68)
                : today
                    ? scheme.primary.withValues(alpha: 0.35)
                    : Colors.transparent,
            width: selected ? 1.2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected || today ? FontWeight.w600 : FontWeight.w500,
                color: foreground,
                height: 1.05,
              ),
            ),
            SizedBox(
              height: 12,
              child: sub != null
                  ? Text(
                      sub,
                      style: TextStyle(
                        fontSize: 8,
                        color: secondaryForeground,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    )
                  : (imgs.isNotEmpty || hasDiary)
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (imgs.isNotEmpty)
                              for (final p in imgs.take(2))
                                Padding(
                                  padding: const EdgeInsets.only(left: 1),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: Image.file(
                                      File(p),
                                      width: 7,
                                      height: 7,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          const SizedBox.shrink(),
                                    ),
                                  ),
                                ),
                            if (hasDiary && imgs.isEmpty)
                              Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: selected ? scheme.onPrimaryContainer : scheme.primary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                          ],
                        )
                      : const SizedBox(height: 9),
            ),
          ],
        ),
      ),
    );
  }
}
