import 'package:flutter/material.dart';

/// Material 3 theme with day/night and seasonal adaptation.
/// Font: Segoe UI (Latin) + Microsoft YaHei UI (CJK) via fallback chain.
class TimetraceTheme {
  static const _fontFamily = 'Segoe UI';
  static const _fontFallback = ['Microsoft YaHei UI', 'Microsoft YaHei', 'sans-serif'];

  static Color _seasonalAccent() {
    final month = DateTime.now().month;
    switch (month) {
      case 3: case 4: case 5: return const Color(0xFF00897B);
      case 6: case 7: case 8: return const Color(0xFF1976D2);
      case 9: case 10: case 11: return const Color(0xFFEF6C00);
      default: return const Color(0xFF3949AB);
    }
  }

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seasonalAccent(),
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
    );
    // Typography with Segoe UI + CJK fallback
    final textTheme = base.textTheme.apply(
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallback,
    );
    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, elevation: 0),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
      // Nicer control defaults
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);
}
