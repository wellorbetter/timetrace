import 'package:flutter/material.dart';

/// Material 3 theme with day/night and the approved quiet moss accent.
/// Font family is passed in from the font preference provider.
class TimetraceTheme {
  static Color _seasonalAccent() {
    return const Color(0xFF506B48);
  }

  static ThemeData _base(Brightness brightness, {required String fontFamily}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seasonalAccent(),
      brightness: brightness,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
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
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: textTheme.bodyMedium,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface.withValues(alpha: 0.78),
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
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
