import 'package:flutter/material.dart';

/// Shared visual primitives for the TimeTrace desktop UI.
///
/// Keep these values deliberately small in number. The design language is
/// restrained: hierarchy comes from alignment, typography and whitespace,
/// not from many radii, shadows or decorative colors.
abstract final class TimeTraceSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

abstract final class TimeTraceRadius {
  static const double control = 9;
  static const double surface = 14;
}

abstract final class TimeTraceLayout {
  /// Comfortable line length for settings and other text-heavy pages.
  static const double readingWidth = 920;

  /// Main dashboard canvas. Large enough for desktop data visualizations,
  /// while still keeping related information visually grouped.
  static const double dashboardWidth = 1180;

  static const double railWidth = 96;
  static const double compactBreakpoint = 760;

  static EdgeInsets pagePadding(double availableWidth) => EdgeInsets.fromLTRB(
        availableWidth < compactBreakpoint ? TimeTraceSpace.sm : TimeTraceSpace.lg,
        TimeTraceSpace.md,
        availableWidth < compactBreakpoint ? TimeTraceSpace.sm : TimeTraceSpace.lg,
        TimeTraceSpace.xl,
      );
}

abstract final class TimeTraceMotion {
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration normal = Duration(milliseconds: 220);
  static const Curve standard = Curves.easeOutCubic;
}
