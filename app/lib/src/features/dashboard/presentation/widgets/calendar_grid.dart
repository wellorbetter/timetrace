import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timetrace_app/src/core/chinese_calendar.dart';
import 'package:timetrace_app/src/features/calendar/providers/calendar_data_provider.dart';

/// Month calendar grid — reused by the 日历日记 tab and the overview
/// carousel page. Xiaomi-style cells: festivals red, lunar grey,
/// today/selected circles, plus diary and image markers.
class CalendarGrid extends ConsumerStatefulWidget {
  const CalendarGrid({
    required this.selected,
    required this.onSelected,
    this.rowHeight = 50,
    this.fillHeight = false,
    this.boundedFit = false,
    super.key,
  });

  final DateTime selected;
  final ValueChanged<DateTime> onSelected;
  final double rowHeight;
  final bool fillHeight;
  final bool boundedFit;

  @override
  ConsumerState<CalendarGrid> createState() => _CalendarGridState();
}

class _CalendarGridState extends ConsumerState<CalendarGrid> {
  DateTime _focused = DateTime.now();
  @override
  void initState() {
    super.initState();
    if (widget.boundedFit) _focused = widget.selected;
  }

  @override
  void didUpdateWidget(CalendarGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.boundedFit && !isSameDay(oldWidget.selected, widget.selected)) {
      _focused = widget.selected;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final data = ref.watch(calendarDataProvider).value;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    if (widget.boundedFit) return _fit(context, scheme, data, today);
    return _table(context, scheme, data, today);
  }

  Widget _fit(
    BuildContext context,
    ColorScheme scheme,
    CalendarData? data,
    DateTime today,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final available = math.max(0.0, constraints.maxHeight - 48);
      final weekdayHeight = math.min(
        available / 7,
        _textSize(context, 'Wed', 11).height + 4,
      );
      final rowHeight = math.max(0.0, (available - weekdayHeight) / 6);
      final geometry = _CalendarCellGeometry.measure(
        context,
        width / 7,
        rowHeight,
      );
      void month(int delta) => setState(() {
        _focused = DateTime(_focused.year, _focused.month + delta);
      });
      return Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    key: const Key('calendar_month_previous'),
                    tooltip: '上个月',
                    onPressed: _focused.month == 1 ? null : () => month(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
                Expanded(
                  child: FittedBox(
                    key: const Key('calendar_month_title_fit'),
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      // Keep glyph rounding inside the scaled title bounds.
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Text(
                        '${_focused.year}年${_focused.month}月',
                        key: const Key('calendar_month_title'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        softWrap: false,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    key: const Key('calendar_month_next'),
                    tooltip: '下个月',
                    onPressed: _focused.month == 12 ? null : () => month(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SizedBox(
              key: const Key('calendar_fit_body'),
              width: width,
              child: _table(
                context,
                scheme,
                data,
                today,
                fit: true,
                fittedWeekdayHeight: weekdayHeight,
                geometry: geometry,
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _table(
    BuildContext context,
    ColorScheme scheme,
    CalendarData? data,
    DateTime today, {
    bool fit = false,
    double? fittedWeekdayHeight,
    _CalendarCellGeometry? geometry,
  }) => TableCalendar(
    firstDay: DateTime(_focused.year, 1, 1),
    lastDay: DateTime(_focused.year, 12, 31),
    focusedDay: _focused,
    headerVisible: !fit,
    onPageChanged: (focused) => setState(() => _focused = focused),
    selectedDayPredicate: (d) => isSameDay(d, widget.selected),
    enabledDayPredicate: (day) =>
        !DateTime(day.year, day.month, day.day).isAfter(today),
    onDaySelected: (selected, focused) {
      setState(() => _focused = focused);
      widget.onSelected(selected);
    },
    calendarFormat: CalendarFormat.month,
    availableGestures: fit ? AvailableGestures.none : AvailableGestures.all,
    // The finite fit viewport determines rendered row geometry independently
    // of the public nominal rowHeight contract (including caller text scaling).
    shouldFillViewport: fit || widget.fillHeight,
    sixWeekMonthsEnforced: fit || widget.fillHeight,
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
    daysOfWeekHeight: fittedWeekdayHeight ?? 22,
    rowHeight: fit
        ? MediaQuery.textScalerOf(context).scale(widget.rowHeight)
        : widget.rowHeight,
    daysOfWeekStyle: DaysOfWeekStyle(
      weekdayStyle: TextStyle(fontSize: 11, color: scheme.outline),
      weekendStyle: TextStyle(fontSize: 11, color: scheme.outline),
    ),
    calendarStyle: CalendarStyle(
      outsideDaysVisible: false,
      cellMargin: fit ? EdgeInsets.zero : const EdgeInsets.all(6),
      defaultTextStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
    ),
    calendarBuilders: CalendarBuilders(
      defaultBuilder: (context, day, focused) =>
          _dayCell(day, scheme, data, selected: false, geometry: geometry),
      selectedBuilder: (context, day, focused) =>
          _dayCell(day, scheme, data, selected: true, geometry: geometry),
      todayBuilder: (context, day, focused) =>
          _dayCell(day, scheme, data, today: true, geometry: geometry),
      disabledBuilder: fit
          ? (context, day, focused) =>
                _dayCell(day, scheme, data, geometry: geometry)
          : null,
      outsideBuilder: (context, day, focused) => const SizedBox.shrink(),
    ),
  );

  /// Xiaomi-style clean cells: festivals red, lunar grey, today/selected
  /// circles and mini image/diary markers. Usage heat is intentionally absent
  /// until the canonical accounting API exposes a local-day series projection.
  Widget _dayCell(
    DateTime day,
    ColorScheme scheme,
    CalendarData? data, {
    bool selected = false,
    bool today = false,
    _CalendarCellGeometry? geometry,
  }) {
    final images = data?.images ?? const {};
    final diaryDays = data?.diaryDays ?? const <String>{};
    final dateStr = calFmt(day);
    final imgs = images[dateStr] ?? [];
    final hasDiary = diaryDays.contains(dateStr);
    final info = lunarInfo(day);
    final isFestival = info.festival != null;

    String? sub;
    if (info.hasMarker) {
      sub = info.festival ?? info.solarTerm;
    } else if (info.day.isNotEmpty) {
      sub = info.day;
    }

    Color dayColor = scheme.onSurface;
    if (isFestival) dayColor = Colors.red.shade600;
    if (selected) {
      dayColor = scheme.onPrimary;
    } else if (today) {
      dayColor = scheme.primary;
    }

    final scale = 1.0;
    final cell = Center(
      child: Container(
        key: geometry == null ? null : ValueKey('calendar_cell_' + dateStr),
        width: geometry == null ? 40 * scale : geometry.width,
        height: geometry == null ? 42 * scale : geometry.height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary
              : (today ? scheme.primaryContainer : null),
          shape: BoxShape.circle,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              key: geometry == null
                  ? null
                  : ValueKey('calendar_date_' + dateStr),
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: geometry?.primaryFont ?? 15,
                fontWeight: (today || selected)
                    ? FontWeight.bold
                    : FontWeight.w500,
                color: dayColor,
                height: 1.1,
              ),
            ),
            SizedBox(
              height: geometry?.secondaryHeight ?? 12 * scale,
              child: sub != null
                  ? Text(
                      sub,
                      key: geometry == null
                          ? null
                          : ValueKey('calendar_lunar_' + dateStr),
                      style: TextStyle(
                        fontSize: geometry?.secondaryFont ?? 8,
                        height: 1,
                        color: (selected || today)
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                            ],
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
    if (!widget.boundedFit) return cell;
    final now = DateTime.now();
    final enabled = !DateTime(
      day.year,
      day.month,
      day.day,
    ).isAfter(DateTime(now.year, now.month, now.day));
    void select() {
      if (!enabled) return;
      setState(() => _focused = day);
      widget.onSelected(day);
    }

    return Semantics(
      label: calFmt(day),
      value: [
        if (sub != null) sub,
        if (hasDiary) '有日记',
        if (imgs.isNotEmpty) '有图片',
      ].join('，'),
      button: true,
      enabled: enabled,
      selected: selected,
      onTap: enabled ? select : null,
      child: FocusableActionDetector(
        enabled: enabled,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              select();
              return null;
            },
          ),
        },
        child: cell,
      ),
    );
  }
}

Size _textSize(
  BuildContext context,
  String text,
  double font, {
  double height = 1.1,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: font, height: height),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final size = painter.size;
  painter.dispose();
  return size;
}

/// Only text sizes adapt; cells retain the parent's seven-column/six-row geometry.
class _CalendarCellGeometry {
  const _CalendarCellGeometry(
    this.width,
    this.height,
    this.primaryFont,
    this.secondaryFont,
    this.secondaryHeight,
  );
  final double width, height, primaryFont, secondaryFont, secondaryHeight;
  static _CalendarCellGeometry measure(
    BuildContext context,
    double width,
    double height,
  ) {
    final primary = (height * .5).clamp(15.0, 24.0).toDouble();
    final secondary = (height * .24).clamp(8.0, 11.0).toDouble();
    double low = 0, high = 1;
    for (var n = 0; n < 18; n++) {
      final factor = (low + high) / 2;
      final p = _textSize(context, '28', primary * factor);
      final q = _textSize(context, '廿八', secondary * factor, height: 1);
      if (p.width <= math.max(0, width - 4) &&
          p.height + q.height + 2 <= math.max(0, height - 4)) {
        low = factor;
      } else {
        high = factor;
      }
    }
    return _CalendarCellGeometry(
      width,
      height,
      primary * low,
      secondary * low,
      _textSize(context, '廿八', secondary * low, height: 1).height + 2,
    );
  }
}
