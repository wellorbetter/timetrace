import 'package:flutter/material.dart';

/// Material 3 theme with day/night and seasonal adaptation.
class TimetraceTheme {
  static Color _seasonalAccent() {
    final month = DateTime.now().month;
    switch (month) {
      case 3: case 4: case 5: return const Color(0xFF00897B);
      case 6: case 7: case 8: return const Color(0xFF1976D2);
      case 9: case 10: case 11: return const Color(0xFFEF6C00);
      default: return const Color(0xFF3949AB);
    }
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seasonalAccent(),
      brightness: Brightness.light,
    );
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

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seasonalAccent(),
      brightness: Brightness.dark,
    );
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
