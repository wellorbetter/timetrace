import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

class TimetraceTheme {
  static const _accent = Color(0xFF5F7668);
  static const _darkAccent = Color(0xFFA7BEAE);

  static ThemeData _base(Brightness brightness, {required String fontFamily}) {
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF181917) : const Color(0xFFF7F6F3);
    final card = dark ? const Color(0xFF20211F) : const Color(0xFFFCFBF8);
    final text = dark ? const Color(0xFFF0EFEA) : const Color(0xFF232420);
    final secondary = dark ? const Color(0xFFBBBAB3) : const Color(0xFF65655F);
    final border = dark ? const Color(0xFF393A36) : const Color(0xFFE1DED6);
    final accent = dark ? _darkAccent : _accent;
    final accentSoft = dark ? const Color(0xFF2D3931) : const Color(0xFFDDE7E0);

    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: dark ? const Color(0xFF172019) : Colors.white,
      primaryContainer: accentSoft,
      onPrimaryContainer: dark ? text : const Color(0xFF27332B),
      secondary: dark ? const Color(0xFFCAC9C2) : const Color(0xFF666862),
      onSecondary: dark ? const Color(0xFF1B1C1A) : Colors.white,
      secondaryContainer: dark ? const Color(0xFF2C2D2A) : const Color(0xFFECEBE6),
      onSecondaryContainer: text,
      tertiary: dark ? const Color(0xFFCABFA6) : const Color(0xFF8A7756),
      onTertiary: dark ? const Color(0xFF211D15) : Colors.white,
      tertiaryContainer: dark ? const Color(0xFF3A3428) : const Color(0xFFF0E8D7),
      onTertiaryContainer: text,
      error: dark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A),
      onError: dark ? const Color(0xFF690005) : Colors.white,
      errorContainer: dark ? const Color(0xFF5B1F1F) : const Color(0xFFFFDAD6),
      onErrorContainer: dark ? const Color(0xFFFFDAD6) : const Color(0xFF410002),
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: dark ? const Color(0xFF2A2B28) : const Color(0xFFEDEBE5),
      onSurfaceVariant: secondary,
      outline: dark ? const Color(0xFF85867F) : const Color(0xFF8E8D86),
      outlineVariant: border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? const Color(0xFFEDECE7) : const Color(0xFF30312E),
      onInverseSurface: dark ? const Color(0xFF282925) : const Color(0xFFF4F3EF),
      inversePrimary: dark ? _accent : _darkAccent,
    );

    final seed = ThemeData(useMaterial3: true, brightness: brightness, colorScheme: scheme, visualDensity: VisualDensity.compact);
    final baseText = seed.textTheme.apply(
      fontFamily: fontFamily,
      fontFamilyFallback: const ['.AppleSystemUIFont', 'SF Pro Text', 'PingFang SC', 'Segoe UI', 'Microsoft YaHei UI', 'sans-serif'],
      bodyColor: text,
      displayColor: text,
    );
    final textTheme = baseText.copyWith(
      headlineMedium: baseText.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.6, color: text),
      titleLarge: baseText.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.25, color: text),
      titleMedium: baseText.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: text),
      titleSmall: baseText.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: text),
      bodyLarge: baseText.bodyLarge?.copyWith(color: text, height: 1.45),
      bodyMedium: baseText.bodyMedium?.copyWith(color: text, height: 1.45),
      bodySmall: baseText.bodySmall?.copyWith(color: secondary, height: 1.45),
      labelLarge: baseText.labelLarge?.copyWith(color: text),
      labelMedium: baseText.labelMedium?.copyWith(color: secondary),
      labelSmall: baseText.labelSmall?.copyWith(color: secondary),
    );

    final surfaceShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(TimeTraceRadius.surface), side: BorderSide(color: border));
    final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(TimeTraceRadius.control));

    return seed.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: textTheme,
      dividerColor: border,
      hoverColor: accent.withValues(alpha: 0.055),
      focusColor: accent.withValues(alpha: 0.10),
      highlightColor: Colors.transparent,
      appBarTheme: AppBarTheme(backgroundColor: surface.withValues(alpha: 0.96), foregroundColor: text, elevation: 0, scrolledUnderElevation: 0, centerTitle: false, toolbarHeight: 50, titleSpacing: TimeTraceSpace.lg, titleTextStyle: textTheme.titleLarge, surfaceTintColor: Colors.transparent),
      cardTheme: CardThemeData(color: card.withValues(alpha: 0.97), elevation: 0, margin: EdgeInsets.zero, shape: surfaceShape, clipBehavior: Clip.antiAlias),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: TimeTraceSpace.lg),
      listTileTheme: ListTileThemeData(dense: true, iconColor: secondary, textColor: text, contentPadding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm, vertical: TimeTraceSpace.xxs), minLeadingWidth: 24, minVerticalPadding: TimeTraceSpace.xxs, shape: controlShape),
      navigationRailTheme: NavigationRailThemeData(backgroundColor: dark ? const Color(0xFF151614) : const Color(0xFFF2F1ED), indicatorColor: accentSoft, indicatorShape: controlShape, selectedIconTheme: IconThemeData(color: accent, size: 21), unselectedIconTheme: IconThemeData(color: secondary, size: 20), selectedLabelTextStyle: TextStyle(color: text, fontSize: 12, fontWeight: FontWeight.w600), unselectedLabelTextStyle: TextStyle(color: secondary, fontSize: 12, fontWeight: FontWeight.w500)),
      segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(visualDensity: VisualDensity.compact, minimumSize: const WidgetStatePropertyAll(Size(0, 34)), padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm)), side: WidgetStatePropertyAll(BorderSide(color: border)), shape: WidgetStatePropertyAll(controlShape), backgroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accentSoft : Colors.transparent), foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? scheme.onPrimaryContainer : secondary), textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12, fontWeight: FontWeight.w500)))),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(elevation: 0, minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm), shape: controlShape, textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm), side: BorderSide(color: border), shape: controlShape, textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.xs), shape: controlShape)),
      iconButtonTheme: IconButtonThemeData(style: ButtonStyle(minimumSize: const WidgetStatePropertyAll(Size(34, 34)), iconColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? secondary.withValues(alpha: 0.42) : secondary), shape: WidgetStatePropertyAll(controlShape))),
      chipTheme: seed.chipTheme.copyWith(backgroundColor: Colors.transparent, selectedColor: accentSoft, side: BorderSide(color: border), shape: controlShape, labelStyle: TextStyle(color: secondary, fontSize: 12), secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer, fontSize: 12, fontWeight: FontWeight.w600)),
      switchTheme: SwitchThemeData(thumbColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? scheme.onPrimary : states.contains(WidgetState.disabled) ? secondary.withValues(alpha: 0.55) : scheme.outline), trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected) ? accent : states.contains(WidgetState.disabled) ? scheme.surfaceContainerHighest.withValues(alpha: 0.55) : scheme.surfaceContainerHighest), trackOutlineColor: WidgetStatePropertyAll(border)),
      sliderTheme: seed.sliderTheme.copyWith(activeTrackColor: accent, inactiveTrackColor: border, thumbColor: accent, overlayColor: accent.withValues(alpha: 0.08), trackHeight: 3),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: card, isDense: true, labelStyle: TextStyle(color: secondary), helperStyle: TextStyle(color: secondary), hintStyle: TextStyle(color: secondary.withValues(alpha: 0.82)), contentPadding: const EdgeInsets.symmetric(horizontal: TimeTraceSpace.sm, vertical: 11), border: OutlineInputBorder(borderRadius: BorderRadius.circular(TimeTraceRadius.control), borderSide: BorderSide(color: border)), enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(TimeTraceRadius.control), borderSide: BorderSide(color: border)), focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(TimeTraceRadius.control), borderSide: BorderSide(color: accent, width: 1.25))),
      dialogTheme: DialogThemeData(backgroundColor: card, surfaceTintColor: Colors.transparent, elevation: 0, shape: surfaceShape, titleTextStyle: textTheme.titleLarge),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: card, surfaceTintColor: Colors.transparent, showDragHandle: true),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: dark ? const Color(0xFF2B2C29) : const Color(0xFF333430), shape: controlShape),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent, linearTrackColor: border),
      scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(scheme.outline.withValues(alpha: 0.50)), thickness: const WidgetStatePropertyAll(6.0), radius: const Radius.circular(8), crossAxisMargin: 2, mainAxisMargin: 4),
      textSelectionTheme: TextSelectionThemeData(cursorColor: accent, selectionColor: accent.withValues(alpha: 0.18), selectionHandleColor: accent),
      tooltipTheme: TooltipThemeData(waitDuration: const Duration(milliseconds: 350), decoration: BoxDecoration(color: dark ? const Color(0xFFE8E7E2) : const Color(0xFF2D2E2B), borderRadius: BorderRadius.circular(TimeTraceRadius.control)), textStyle: TextStyle(color: dark ? const Color(0xFF232421) : const Color(0xFFF5F4EF), fontSize: 12)),
    );
  }

  static ThemeData light({String fontFamily = '.AppleSystemUIFont'}) => _base(Brightness.light, fontFamily: fontFamily);
  static ThemeData dark({String fontFamily = '.AppleSystemUIFont'}) => _base(Brightness.dark, fontFamily: fontFamily);
}
