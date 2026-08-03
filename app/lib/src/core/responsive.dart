import 'package:flutter/material.dart';

/// Responsive screen-size tiers based on available width.
enum ScreenSize { compact, medium, wide }

ScreenSize screenSizeOf(BoxConstraints c) {
  if (c.maxWidth < 720) return ScreenSize.compact;
  if (c.maxWidth < 1100) return ScreenSize.medium;
  return ScreenSize.wide;
}

/// Adaptive visibility helpers.
extension ScreenSizeX on ScreenSize {
  /// Whether to show the full bar+pie charts row.
  bool get showChartsRow => this != ScreenSize.compact;

  /// Whether to show the full calendar (with diary).
  bool get showFullCalendar => this != ScreenSize.compact;

  /// Whether to show the two-column layout (charts left, calendar right).
  bool get twoColumn => this == ScreenSize.wide;

  /// Whether to show stat cards in a 3-up row (vs 2-up compact).
  bool get threeStats => this != ScreenSize.compact;

  /// Default visible app-list rows before "show more".
  int get defaultAppRows => this == ScreenSize.compact ? 4 : 8;

  /// Default session rows before "show more".
  int get defaultSessionRows => this == ScreenSize.compact ? 4 : 8;
}
