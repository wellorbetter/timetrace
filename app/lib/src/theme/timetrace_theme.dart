import 'dart:io';
import 'package:flutter/material.dart';

/// Material 3 theme with day/night and seasonal adaptation.
class TimetraceTheme {
  static Color _seasonalAccent() {
    final month = DateTime.now().month;
    // Spring: teal-green, Summer: blue, Autumn: amber, Winter: indigo
    switch (month) {
      case 3: case 4: case 5: return const Color(0xFF00897B);
      case 6: case 7: case 8: return const Color(0xFF1976D2);
      case 9: case 10: case 11: return const Color(0xFFEF6C00);
      default: return const Color(0xFF3949AB);
    }
  }

  static Color _warmTint() {
    final hour = DateTime.now().hour;
    // Warmer at night to reduce blue light
    if (hour >= 22 || hour < 6) return const Color(0xFFFFB74D);
    if (hour >= 19) return const Color(0xFFFFCC80);
    return const Color(0xFFFFFFFF);
  }

  static ThemeData light() {
    final seed = _seasonalAccent();
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, elevation: 0),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
      navigationRailTheme: const NavigationRailThemeData(),
    );
  }

  static ThemeData dark() {
    final seed = _seasonalAccent();
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, elevation: 0),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
    );
  }
}
