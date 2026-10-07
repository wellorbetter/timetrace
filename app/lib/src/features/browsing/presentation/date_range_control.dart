import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/material/material.dart';
import '../models/browsing_state.dart';

/// Shared date control for Feed and Data.
///
/// A single browsing range remains authoritative. The compact control keeps
/// day-to-day navigation fast while the menu exposes wider ranges without
/// turning the page header into a row of persistent chips.
class DateRangeControl extends StatefulWidget {
  const DateRangeControl({
    required this.selection,
    required this.onRange,
    required this.onDay,
    this.enabled = true,
    this.iconOnly = false,
    super.key,
  });

  final DateRangeSelection selection;
  final ValueChanged<DateRange> onRange;
  final ValueChanged<DateTime> onDay;
  final bool enabled;
  final bool iconOnly;

  @override
  State<DateRangeControl> createState() => _DateRangeControlState();
}

class _DateRangeControlState extends State<DateRangeControl> {
  final MenuController _menuController = MenuController();
  final FocusNode _triggerFocusNode = FocusNode(
    debugLabel: 'DateRangeControl menu trigger',
  );

  bool get _isSingleDay =>
      widget.selection.range == DateRange.today ||
      widget.selection.range == DateRange.yesterday ||
      widget.selection.range == DateRange.custom;

  @override
  void dispose() {
    _triggerFocusNode.dispose();
    super.dispose();
  }

  void _toggleMenu() {
    if (_menuController.isOpen) {
      _menuController.close();
      return;
    }
    _menuController.open();
    // Pointer activation must establish a keyboard focus path even on
    // platforms where tapping a button does not normally focus it.
    _triggerFocusNode.requestFocus();
  }

  KeyEventResult _handleMenuKeyEvent(FocusNode node, KeyEvent event) {
    if (_menuController.isOpen &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _menuController.close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.selection;
    final enabled = widget.enabled;
    final iconOnly = widget.iconOnly;
    final onRange = widget.onRange;
    final onDay = widget.onDay;
    final scheme = Theme.of(context).colorScheme;
    final day = _dateOnly(selection.effectiveDay);
    final today = _dateOnly(DateTime.now());
    final canMoveForward = _isSingleDay && day.isBefore(today);
    final capture = MaterialOverlayCapture.of(context);

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleMenuKeyEvent,
      child: Semantics(
        label: '当前日期范围：${_selectionLabel(selection, today)}',
        container: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.56),
            borderRadius: BorderRadius.circular(MaterialTokens.controlRadius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!iconOnly)
                IconButton(
                  tooltip: '前一天',
                  visualDensity: VisualDensity.compact,
                  style: materialActionStyle(context, padding: EdgeInsets.zero),
                  onPressed: enabled && _isSingleDay
                      ? () => onDay(day.subtract(const Duration(days: 1)))
                      : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
              // Share the finite row width with the two 48dp day actions.
              // Loose flex also preserves the shrink-wrapped toolbar contract.
              Flexible(
                child: MenuAnchor(
                  alignmentOffset: const Offset(-64, 8),
                  controller: _menuController,
                  childFocusNode: _triggerFocusNode,
                  style: materialMenuStyle,
                  menuChildren: [
                    MaterialTransientPanel(
                      capture: capture,
                      maxWidth: 240,
                      padding: const EdgeInsets.all(MaterialTokens.spaceXs),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _rangeItem(
                            context,
                            label: '今天',
                            selected: selection.range == DateRange.today,
                            onPressed: enabled
                                ? () => onRange(DateRange.today)
                                : null,
                          ),
                          _rangeItem(
                            context,
                            label: '昨天',
                            selected: selection.range == DateRange.yesterday,
                            onPressed: enabled
                                ? () => onRange(DateRange.yesterday)
                                : null,
                          ),
                          _rangeItem(
                            context,
                            label: '近 7 天',
                            selected: selection.range == DateRange.week,
                            onPressed: enabled
                                ? () => onRange(DateRange.week)
                                : null,
                          ),
                          _rangeItem(
                            context,
                            label: '近 30 天',
                            selected: selection.range == DateRange.month,
                            onPressed: enabled
                                ? () => onRange(DateRange.month)
                                : null,
                          ),
                          const Divider(
                            height: 12,
                            indent: MaterialTokens.spaceSm,
                            endIndent: MaterialTokens.spaceSm,
                          ),
                          _rangeItem(
                            context,
                            label: '选择日期…',
                            selected: false,
                            onPressed: enabled
                                ? () => _pickDay(context, day)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                  builder: (context, controller, child) => iconOnly
                      ? IconButton(
                          focusNode: _triggerFocusNode,
                          style: materialActionStyle(
                            context,
                            padding: EdgeInsets.zero,
                          ),
                          tooltip: '选择日期：${_selectionLabel(selection, today)}',
                          icon: const Icon(
                            Icons.calendar_month_outlined,
                            size: 20,
                          ),
                          onPressed: enabled ? _toggleMenu : null,
                        )
                      : TextButton(
                          focusNode: _triggerFocusNode,
                          onPressed: enabled ? _toggleMenu : null,
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurface,
                            minimumSize: const Size(164, materialControlTarget),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: const RoundedRectangleBorder(),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.calendar_month_outlined,
                                size: 18,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _selectionLabel(selection, today),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              if (!iconOnly)
                IconButton(
                  tooltip: '后一天',
                  visualDensity: VisualDensity.compact,
                  style: materialActionStyle(context, padding: EdgeInsets.zero),
                  onPressed: enabled && canMoveForward
                      ? () => onDay(day.add(const Duration(days: 1)))
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rangeItem(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return scheme.onSurface.withValues(alpha: 0.38);
      }
      return scheme.onSurface;
    });

    return Semantics(
      selected: selected,
      child: MenuItemButton(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(
            selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
          ),
          foregroundColor: foreground,
          iconColor: foreground,
          minimumSize: const WidgetStatePropertyAll(
            Size(176, materialControlTarget),
          ),
          visualDensity: VisualDensity.standard,
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: MaterialTokens.spaceMd,
              vertical: MaterialTokens.spaceSm,
            ),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(
                Radius.circular(MaterialTokens.controlRadius),
              ),
            ),
          ),
        ),
        trailingIcon: selected
            ? const Icon(Icons.check_rounded, size: 18)
            : null,
        onPressed: onPressed,
        child: Text(
          label,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Future<void> _pickDay(BuildContext context, DateTime initialDay) async {
    final today = _dateOnly(DateTime.now());
    final capture = MaterialOverlayCapture.of(context);
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDay.isAfter(today) ? today : initialDay,
      firstDate: DateTime(today.year - 20),
      lastDate: today,
      helpText: '选择查看日期',
      cancelText: '取消',
      confirmText: '查看',
      builder: (context, child) => capture.wrap(
        Theme(
          data: Theme.of(context).copyWith(
            datePickerTheme: Theme.of(context).datePickerTheme.copyWith(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              shadowColor: Colors.transparent,
              elevation: 0,
            ),
          ),
          child: Center(
            child: MaterialTransientPanel(
              maxWidth: 520,
              maxHeightFraction: .95,
              scrollable: false,
              padding: EdgeInsets.zero,
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    if (picked != null && mounted) widget.onDay(_dateOnly(picked));
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _selectionLabel(DateRangeSelection selection, DateTime today) {
  switch (selection.range) {
    case DateRange.today:
      return '今天 · ${today.month}月${today.day}日';
    case DateRange.yesterday:
      final day = today.subtract(const Duration(days: 1));
      return '昨天 · ${day.month}月${day.day}日';
    case DateRange.week:
      return '近 7 天';
    case DateRange.month:
      return '近 30 天';
    case DateRange.custom:
      final day = selection.effectiveDay;
      return '${day.month}月${day.day}日 · 周${'一二三四五六日'[day.weekday - 1]}';
  }
}
