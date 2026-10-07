import 'package:flutter/material.dart';

import '../responsive.dart' as responsive;

enum MaterialWidthClass { compact, medium, wide }

/// Production defaults delegate to the existing centralized screenSizeOf.
/// Optional paired thresholds are retained for explicit test injection only.
@immutable
class MaterialBreakpoints {
  const MaterialBreakpoints({this.medium, this.wide})
    : assert((medium == null) == (wide == null)),
      assert(medium == null || medium > 0),
      assert(medium == null || (wide != null && wide > medium));

  const MaterialBreakpoints.forTesting({
    required double medium,
    required double wide,
  }) : this(medium: medium, wide: wide);

  /// Null means use the repository classifier, not another default threshold.
  final double? medium;
  final double? wide;

  MaterialWidthClass classify(double width) {
    if (!width.isFinite || width < 0) {
      throw ArgumentError.value(
        width,
        'width',
        'Must be finite and nonnegative',
      );
    }
    final mediumBoundary = medium;
    final wideBoundary = wide;
    if (mediumBoundary == null && wideBoundary == null) {
      return switch (responsive.screenSizeOf(BoxConstraints(maxWidth: width))) {
        responsive.ScreenSize.compact => MaterialWidthClass.compact,
        responsive.ScreenSize.medium => MaterialWidthClass.medium,
        responsive.ScreenSize.wide => MaterialWidthClass.wide,
      };
    }
    if (mediumBoundary == null ||
        wideBoundary == null ||
        !mediumBoundary.isFinite ||
        !wideBoundary.isFinite ||
        mediumBoundary <= 0 ||
        wideBoundary <= mediumBoundary) {
      throw ArgumentError(
        'Test breakpoints must be finite, positive and ordered',
      );
    }
    if (width < mediumBoundary) return MaterialWidthClass.compact;
    if (width < wideBoundary) return MaterialWidthClass.medium;
    return MaterialWidthClass.wide;
  }
}

@immutable
class MaterialTokens {
  const MaterialTokens(this.widthClass);

  factory MaterialTokens.forWidth(
    double width, {
    MaterialBreakpoints breakpoints = const MaterialBreakpoints(),
  }) => MaterialTokens(breakpoints.classify(width));

  final MaterialWidthClass widthClass;

  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 12;
  static const double spaceLg = 16;
  static const double spaceXl = 24;
  static const double spaceXxl = 32;
  static const double minimumTarget = 44;
  static const double controlRadius = 10;
  static const double contentRadius = 16;
  static const double workRadius = 20;
  static const double focusWidth = 2;
  static const double borderWidth = 1;
  static const double blurSigma = 18;
  static const double glassOpacity = 0.68;
  static const double contentOpacity = 0.88;

  double get pageInset => switch (widthClass) {
    MaterialWidthClass.compact => spaceMd,
    MaterialWidthClass.medium => 20,
    MaterialWidthClass.wide => 28,
  };

  double get sectionGap => switch (widthClass) {
    MaterialWidthClass.compact => spaceLg,
    MaterialWidthClass.medium => spaceXl,
    MaterialWidthClass.wide => spaceXxl,
  };

  static List<BoxShadow> workShadow({required bool dark}) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  static List<BoxShadow> cardShadow({
    required bool dark,
    bool lifted = false,
  }) => [
    BoxShadow(
      color: Colors.black.withValues(
        alpha: dark ? (lifted ? 0.28 : 0.20) : (lifted ? 0.16 : 0.10),
      ),
      blurRadius: lifted ? 18 : 10,
      spreadRadius: lifted ? -2 : -3,
      offset: Offset(0, lifted ? 7 : 3),
    ),
    BoxShadow(
      color: Colors.white.withValues(alpha: dark ? 0.03 : 0.26),
      blurRadius: 2,
      offset: const Offset(0, -1),
    ),
  ];
}
