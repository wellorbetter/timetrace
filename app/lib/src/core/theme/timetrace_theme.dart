import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

/// Quiet, refined desktop theme for TimeTrace.
///
/// Design goals:
/// - warm neutral surfaces instead of pure white/black
/// - one restrained accent color
/// - hierarchy through spacing/typography before decoration
/// - borders before shadows
/// - compact desktop controls and consistent radii
class TimetraceTheme {
  static const _lightSurface = Color(0xFFF7F6F3);
  static const _lightCard = Color(0xFFFCFBF8);
  static const _lightText = Color(0xFF242421);
  static const _lightMuted = Color(0xFF77766F);
  static const _lightBorder = Color(0xFFE6E3DC);
  static const _accent = Color(0xFF5F7668);
  static const _accentSoft = Color(0xFFDDE7E0);

  static const _darkSurface = Color(0xFF181917);
  static const _darkCard = Color(0xFF20211F);
  static const _darkText = Color(0xFFECEBE6);
  static const _darkMuted = Color(0xFFA6A59E);
  static const _darkBorder = Color(0xFF343531);
  static const _darkAccent = Color(0xFF9CB4A4);
  static const _darkAccentSoft = Color(0xFF2D3931);

  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme(
      brightness: brightness,
      primary: dark ? _darkAccent : _accent,
      onPrimary: dark ? const Color(0xFF172019) : Colors.white,
      primaryContainer: dark ? _darkAccentSoft : _accentSoft,
      onPrimaryContainer: dark ? _darkText : const Color(0xFF27332B),
      secondary: dark ? const Color(0xFFB8B8B0) : const Color(0xFF696B65),
      onSecondary: dark ? const Color(0xFF1B1C1A) : Colors.white,
      secondaryContainer:
          dark ? const Color(0xFF2C2D2A) : const Color(0xFFECEBE6),
      onSecondaryContainer: dark ? _darkText : _lightText,
      tertiary: dark ? const Color(0xFFC2B79D) : const Color(0xFF8A7756),
      onTertiary: dark ? const Color(0xFF211D15) : Colors.white,
      tertiaryContainer:
          dark ? const Color(0xFF3A3428) : const Color(0xFFF0E8D7),
      onTertiaryContainer: dark ? _darkText : const Color(0xFF3B3122),
      error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
      onError: dark ? const Color(0xFF690005) : Colors.white,
      errorContainer:
          dark ? const Color(0xFF5B1F1F) : const Color(0xFFFFDAD6),
      onErrorContainer:
          dark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
      surface: dark ? _darkSurface : _lightSurface,
      onSurface: dark ? _darkText : _lightText,
      surfaceContainerHighest:
          dark ? const Color(0xFF292A27) : const Color(0xFFEDEBE5),
      onSurfaceVariant: dark ? _darkMuted : _lightMuted,
      outline: dark ? const Color(0xFF777872) : const Color(0xFF9A9890),
      outlineVariant: dark ? _darkBorder : _lightBorder,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? _lightText : const Color(0xFF30312E),
      onInverseSurface: dark ? _lightText : const Color(0xFFF4F3EF),
      inversePrimary: dark ? _accent : _darkAccent,
    );
  }

  static ThemeData _base(Brightness brightness, {required String fontFamily}) {
    final scheme = _scheme(brightness);
    final dark = brightness == Brightness.dark;
    final cardColor = dark ? _darkCard : _lightCard;

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      dividerColor: scheme.outlineVariant,
      visualDensity: VisualDensity.compact,
    );

    final textTheme = base.textTheme
        .apply(
          fontFamily: fontFamily,
          fontFamilyFallback: const [
            '.AppleSystemUIFont',
            'SF Pro Text',
            'PingFang SC',
            'Segoe UI',
            'Microsoft YaHei UI',
            'sans-serif',
          ],
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        )
        .copyWith(
          headlineMedium: base.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        );

    final surfaceShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(TimeTraceRadius.surface),
      side: BorderSide(color: scheme.outlineVariant),
    );
    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(TimeTraceRadius.control),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface.withValues(alpha: 0.94),
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 54,
        titleSpacing: TimeTraceSpace.lg,
        titleTextStyle: textTheme.titleLarge,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: surfaceShape,
        clipBehavior: Clip.antiAlias,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: TimeTraceSpace.lg,
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: TimeTraceSpace.sm,
          vertical: TimeTraceSpace.xxs,
        ),
        minLeadingWidth: 24,
        minVerticalPadding: TimeTraceSpace.xxs,
        shape: controlShape,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor:
            dark ? const Color(0xFF151614) : const Color(0xFFF2F1ED),
        indicatorColor: scheme.primaryContainer,
        indicatorShape: controlShape,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 21),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 20),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm),
          shape: controlShape,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm),
          side: BorderSide(color: scheme.outlineVariant),
          shape: controlShape,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xs),
          shape: controlShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(34, 34)),
          iconColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return scheme.onSurfaceVariant.withValues(alpha: 0.38);
            }
            return scheme.onSurfaceVariant;
          }),
          shape: WidgetStatePropertyAll(controlShape),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: controlShape,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        secondaryLabelStyle: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xxs),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.outline;
        }),
        visualDensity: VisualDensity.compact,
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.outlineVariant,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.08),
        trackHeight: 3,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: TimeTraceSpace.sm,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
          borderSide: BorderSide(color: scheme.primary, width: 1.25),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: surfaceShape,
        titleTextStyle: textTheme.titleLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            dark ? const Color(0xFF2B2C29) : const Color(0xFF333430),
        shape: controlShape,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.outlineVariant,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 350),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE8E7E2) : const Color(0xFF2D2E2B),
          borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        ),
        textStyle: TextStyle(
          color: dark ? const Color(0xFF232421) : const Color(0xFFF5F4EF),
          fontSize: 12,
        ),
      ),
    );
  }

  static ThemeData light({String fontFamily = '.AppleSystemUIFont'}) =>
      _base(Brightness.light, fontFamily: fontFamily);

  static ThemeData dark({String fontFamily = '.AppleSystemUIFont'}) =>
      _base(Brightness.dark, fontFamily: fontFamily);
}
