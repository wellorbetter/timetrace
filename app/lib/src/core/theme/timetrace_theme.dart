import 'package:flutter/material.dart';

/// Material 3 theme with day/night + seasonal accent.
/// Font family is passed in from the font preference provider.
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

  static ThemeData _base(Brightness brightness, {required String fontFamily}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seasonalAccent(),
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
    );
    // Apply chosen font + CJK fallback chain.
    final textTheme = base.textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: const [
        'Microsoft YaHei UI',
        'Microsoft YaHei',
        'Segoe UI',
        'sans-serif',
      ],
    );
    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(backgroundColor: scheme.surface, elevation: 0),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
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

  static ThemeData light({String fontFamily = 'Segoe UI'}) =>
      _base(Brightness.light, fontFamily: fontFamily);
  static ThemeData dark({String fontFamily = 'Segoe UI'}) =>
      _base(Brightness.dark, fontFamily: fontFamily);
}
