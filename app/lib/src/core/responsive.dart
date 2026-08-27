import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Responsive screen-size tiers based on the content canvas width.
enum ScreenSize { compact, medium, wide }

ScreenSize screenSizeOf(BoxConstraints c) {
  if (c.maxWidth < TimeTraceLayout.compactBreakpoint) {
    return ScreenSize.compact;
  }
  if (c.maxWidth < 1100) return ScreenSize.medium;
  return ScreenSize.wide;
}

extension ScreenSizeX on ScreenSize {
  /// Whether the layout has room for the full two-column data canvas.
  bool get twoColumn => this == ScreenSize.wide;

  /// Compact layouts stack sections vertically; medium and wide layouts can
  /// keep desktop-oriented horizontal controls.
  bool get stacked => this == ScreenSize.compact;
}
