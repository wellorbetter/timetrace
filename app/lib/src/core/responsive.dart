import 'package:flutter/material.dart';

/// Responsive screen-size tiers based on available width.
enum ScreenSize { compact, medium, wide }

ScreenSize screenSizeOf(BoxConstraints c) {
  if (c.maxWidth < 720) return ScreenSize.compact;
  if (c.maxWidth < 1100) return ScreenSize.medium;
  return ScreenSize.wide;
}

/// Adaptive visibility helpers (only what's actually used).
extension ScreenSizeX on ScreenSize {
  /// Whether the layout has room for the full-width wide layout.
  bool get twoColumn => this == ScreenSize.wide;
}
