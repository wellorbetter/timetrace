import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/core/chinese_calendar.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';

/// Month calendar grid — reused by the Overview workspace.
/// Xiaomi-style cells: festivals red, lunar grey, today/selected circles,
/// subtle usage heat tint.
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
  void initState() {
    super.initState();
    _focused = widget.selected;
  }

  @override
  void didUpdateWidget(covariant CalendarGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!isSameDay(oldWidget.selected, widget.selected)) {
      _focused = widget.selected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = ref.watch(calendarDataProvider).value;

    return TableCalendar(
      firstDay: DateTime(_focused.year, 1, 1),
      lastDay: DateTime(_focused.year, 12, 31),
      focusedDay: _focused,
      selectedDayPredicate: (day) => isSameDay(day, widget.selected),
      onDaySelected: (selected, focused) {
        setState(() => _focused = focused);
        widget.onSelected(selected);
      },
      calendarFormat: CalendarFormat.month,
      headerStyle: HeaderStyle(
        titleCentered: true,
        formatButtonVisible: false,
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        leftChevronIcon: Icon(
          Icons.chevron_left,
          size: 20,
          color: scheme.primary,
        ),
        rightChevronIcon: Icon(
          Icons.chevron_right,
          size: 20,
          color: scheme.primary,
        ),
      ),
      daysOfWeekHeight: 22,
      rowHeight: widget.rowHeight,
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle: TextStyle(fontSize: 11, color: scheme.outline),
        weekendStyle: TextStyle(fontSize: 11, color: scheme.outline),
      ),
      calendarStyle: CalendarStyle(
        outsideDaysVisible: false,
        defaultTextStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      calendarBuilders: CalendarBuilders(
        defaultBuilder: (context, day, focused) => _dayCell(day, scheme, data),
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
        ? scheme.primary.withValues(alpha: 0.05 + 0.15 * intensity)
        : null;

    String? sub;
    if (info.hasMarker) {
      sub = info.festival ?? info.solarTerm;
    } else if (info.day.isNotEmpty) {
      sub = info.day;
    }

    var dayColor = scheme.onSurface;
    if (isFestival) dayColor = Colors.red.shade600;
    if (selected) {
      dayColor = scheme.onPrimary;
    } else if (today) {
      dayColor = scheme.primary;
    }

    return Center(
      child: Container(
        width: 40,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary
              : (heat ?? (today ? scheme.primaryContainer : null)),
          shape: BoxShape.circle,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: today || selected
                    ? FontWeight.bold
                    : FontWeight.w500,
                color: dayColor,
                height: 1.1,
              ),
            ),
            SizedBox(
              height: 12,
              child: sub != null
                  ? Text(
                      sub,
                      style: TextStyle(
                        fontSize: 8,
                        color: selected || today
                            ? dayColor.withValues(alpha: 0.85)
                            : (isFestival
                                  ? Colors.red.shade600
                                  : scheme.outline),
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    )
                  : (imgs.isNotEmpty || hasDiary)
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (imgs.isNotEmpty)
                          for (final path in imgs.take(2))
                            Padding(
                              padding: const EdgeInsets.only(left: 1),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: Image.file(
                                  File(path),
                                  width: 7,
                                  height: 7,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const SizedBox.shrink(),
                                ),
                              ),
                            ),
                        if (hasDiary && imgs.isEmpty)
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: scheme.primary,
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
