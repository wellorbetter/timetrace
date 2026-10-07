import 'package:flutter/material.dart';

import 'material_tokens.dart';
import 'material_appearance.dart';

/// Unknown is deliberately distinct from a verified disabled signal.
enum AccessibilitySignal { unknown, disabled, enabled }

enum WallpaperLoadState { absent, loading, ready, failed }

enum MaterialOpaqueReason {
  solidStyle,
  highContrast,
  reducedTransparency,
  unknownHighContrast,
  unknownReducedTransparency,
  noWallpaper,
  wallpaperLoading,
  wallpaperFailed,
}

@immutable
class MaterialSignals {
  const MaterialSignals({
    this.reduceTransparency = AccessibilitySignal.unknown,
    this.highContrast = AccessibilitySignal.unknown,
  });

  final AccessibilitySignal reduceTransparency;
  final AccessibilitySignal highContrast;

  /// A positive framework signal is honored. A false/missing framework signal
  /// does not establish that the operating-system preference is disabled.
  MaterialSignals includingFrameworkHighContrast(bool enabled) => enabled
      ? MaterialSignals(
          reduceTransparency: reduceTransparency,
          highContrast: AccessibilitySignal.enabled,
        )
      : this;
}

/// Pure policy: injectable load state, signals, background and theme, no I/O.
@immutable
class MaterialPolicy {
  const MaterialPolicy._({
    required this.colorScheme,
    required this.wallpaper,
    required this.signals,
    required this.backgroundColor,
    required this.backgroundOpacity,
    required this.opaqueReason,
    required this.fallbackSurface,
    required this.appearance,
  });

  factory MaterialPolicy.resolve({
    required ColorScheme colorScheme,
    required WallpaperLoadState wallpaper,
    MaterialSignals signals = const MaterialSignals(),
    Color? backgroundColor,
    double backgroundOpacity = 0.5,
    MaterialAppearance appearance = const MaterialAppearance(),
  }) {
    final highContrast = signals.highContrast == AccessibilitySignal.enabled;
    final MaterialOpaqueReason? reason;
    if (highContrast) {
      reason = MaterialOpaqueReason.highContrast;
    } else if (signals.reduceTransparency == AccessibilitySignal.enabled) {
      reason = MaterialOpaqueReason.reducedTransparency;
    } else if (signals.highContrast == AccessibilitySignal.unknown) {
      reason = MaterialOpaqueReason.unknownHighContrast;
    } else if (signals.reduceTransparency == AccessibilitySignal.unknown) {
      reason = MaterialOpaqueReason.unknownReducedTransparency;
    } else if (appearance.style == SurfaceStyle.solid) {
      reason = MaterialOpaqueReason.solidStyle;
    } else {
      // The environment always paints an ambient color field, so glass remains
      // meaningful without a selected image and while an image is loading. The
      // wallpaper state is still exposed for diagnostics; accessibility
      // preferences remain the only authority that disables transparency.
      reason = null;
    }
    final scheme = highContrast ? _contrastScheme(colorScheme) : colorScheme;
    final opacity = backgroundOpacity.isFinite
        ? backgroundOpacity.clamp(0.0, 1.0).toDouble()
        : 0.5;
    final base = scheme.surface.withValues(alpha: 1);
    // Bake the selected tint into an opaque surface independently of glass
    // permission. Explicit high contrast always overrides the selected tint.
    final fallback =
        wallpaper == WallpaperLoadState.absent &&
            !highContrast &&
            backgroundColor != null
        ? _solidSurface(scheme, backgroundColor, opacity)
        : base;
    return MaterialPolicy._(
      colorScheme: scheme,
      wallpaper: wallpaper,
      signals: signals,
      backgroundColor: backgroundColor,
      backgroundOpacity: opacity,
      opaqueReason: reason,
      fallbackSurface: fallback,
      appearance: MaterialAppearance.fromPreferences(
        appearance.toPreferences(),
      ),
    );
  }

  final ColorScheme colorScheme;
  final WallpaperLoadState wallpaper;
  final MaterialSignals signals;
  final MaterialAppearance appearance;
  final Color? backgroundColor;
  final double backgroundOpacity;
  final MaterialOpaqueReason? opaqueReason;

  /// Fully opaque, already composited color. Do not apply opacity again.
  /// With transparency disabled or unknown, this includes a readability-
  /// constrained selected color.
  /// The tint guard preserves onSurface, onSurfaceVariant, primary and error
  /// and requires each to reach 4.5:1 against the returned tinted surface.
  /// An already unreadable theme baseline is retained without certification.
  /// Otherwise this is the theme fallback. Content and Scaffold share it.
  final Color fallbackSurface;

  bool get allowsGlass => opaqueReason == null;
  bool get allowsBlur =>
      allowsGlass &&
      appearance.style == SurfaceStyle.glass &&
      appearance.blur > 0;
  bool get highContrast => signals.highContrast == AccessibilitySignal.enabled;
  bool get allowsAmbient =>
      signals.highContrast == AccessibilitySignal.disabled &&
      signals.reduceTransparency == AccessibilitySignal.disabled;
  bool get allowsCardGlass =>
      allowsAmbient &&
      appearance.cardEffects &&
      appearance.cardStyle != SurfaceStyle.solid;
  bool get allowsCardSampling =>
      allowsCardGlass && appearance.cardStyle == SurfaceStyle.glass;
  bool get allowsRefraction => allowsCardSampling && appearance.refraction > 0;

  Color get opaqueSurface => colorScheme.surface.withValues(alpha: 1);
  Color get foreground => colorScheme.onSurface.withValues(alpha: 1);
  Color get focusColor => highContrast ? foreground : colorScheme.primary;

  // Preserve the existing environment mask meaning: 1 - selected opacity.
  Color get environmentOverlay => opaqueSurface.withValues(
    alpha: allowsAmbient ? 1 - backgroundOpacity : 1,
  );

  Color get tintedSurface =>
      Color.lerp(opaqueSurface, colorScheme.primary, appearance.tint * .25)!;
  Color get cardTintedSurface => Color.lerp(
    opaqueSurface,
    colorScheme.primary,
    appearance.cardTint * .25,
  )!;
  Color get workSurface => allowsGlass
      ? tintedSurface.withValues(alpha: appearance.workOpacity)
      : fallbackSurface;

  Color get contentSurface => allowsCardGlass
      ? cardTintedSurface.withValues(alpha: appearance.contentOpacity)
      : fallbackSurface;

  /// Estimate the visible environment; photo contrast is reinforced locally by
  /// a small rim on each indicator, never a full-width navigation plate.
  Color get navigationForeground {
    final background = Color.alphaBlend(
      workSurface,
      Color.alphaBlend(environmentOverlay, backgroundColor ?? opaqueSurface),
    );
    if (_contrast(colorScheme.primary, background) >= 3) {
      return colorScheme.primary;
    }
    if (_contrast(foreground, background) >= 3) return foreground;
    return background.computeLuminance() > .179 ? Colors.black : Colors.white;
  }

  Color get boundary => highContrast
      ? foreground
      : colorScheme.outlineVariant.withValues(alpha: 1);

  Color get glassHighlight => highContrast
      ? foreground
      : Color.alphaBlend(
          Colors.white.withValues(
            alpha: colorScheme.brightness == Brightness.dark ? 0.22 : 0.65,
          ),
          boundary,
        );

  /// Adapts component themes as well as ColorScheme. In particular, the
  /// existing AppBar background is an explicit translucent color, and M3
  /// cards consume CardThemeData rather than relying on ThemeData.cardColor.
  /// In ordinary opaque mode, onSurface, onSurfaceVariant, primary and error
  /// retain their theme values; the solid-color guard constrains the background
  /// for all four roles, including semantic text painted directly on it.
  /// Explicit colors on individual widgets remain the consumer's responsibility.
  ThemeData applyTo(ThemeData theme) {
    final appBar = theme.appBarTheme;
    final adapted = theme.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: allowsGlass
          ? Colors.transparent
          : fallbackSurface,
      canvasColor: opaqueSurface,
      cardColor: contentSurface,
      dividerColor: boundary,
      appBarTheme: appBar.copyWith(
        backgroundColor: workSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        shadowColor: Colors.transparent,
      ),
      cardTheme: theme.cardTheme.copyWith(
        color: contentSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shadowColor: Colors.black.withValues(
          alpha: colorScheme.brightness == Brightness.dark ? 0.34 : 0.18,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MaterialTokens.contentRadius),
          side: BorderSide(
            color: boundary,
            width: highContrast
                ? MaterialTokens.focusWidth
                : MaterialTokens.borderWidth,
          ),
        ),
      ),
    );
    if (!highContrast) return adapted;
    return adapted.copyWith(
      textTheme: theme.textTheme.apply(
        bodyColor: foreground,
        displayColor: foreground,
      ),
      iconTheme: theme.iconTheme.copyWith(color: foreground),
      appBarTheme: adapted.appBarTheme.copyWith(
        foregroundColor: foreground,
        iconTheme: (appBar.iconTheme ?? theme.iconTheme).copyWith(
          color: foreground,
        ),
        actionsIconTheme:
            (appBar.actionsIconTheme ?? appBar.iconTheme ?? theme.iconTheme)
                .copyWith(color: foreground),
        titleTextStyle:
            (appBar.titleTextStyle ??
                    theme.textTheme.titleLarge ??
                    const TextStyle())
                .copyWith(color: foreground),
        toolbarTextStyle:
            (appBar.toolbarTextStyle ??
                    theme.textTheme.bodyMedium ??
                    const TextStyle())
                .copyWith(color: foreground),
        shape: Border(
          bottom: BorderSide(color: boundary, width: MaterialTokens.focusWidth),
        ),
      ),
      focusColor: foreground.withValues(alpha: 0.18),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: boundary),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(
            color: focusColor,
            width: MaterialTokens.focusWidth,
          ),
        ),
      ),
    );
  }

  static Color _solidSurface(
    ColorScheme scheme,
    Color selected,
    double opacity,
  ) {
    final base = scheme.surface.withValues(alpha: 1);
    // Same paint ordering as the existing environment: selected color over
    // the base, then the theme mask with alpha (1 - configured opacity).
    final selectedOverBase = Color.alphaBlend(selected, base);
    final composed = Color.alphaBlend(
      base.withValues(alpha: 1 - opacity),
      selectedOverBase,
    ).withValues(alpha: 1);

    // These roles are used directly on the themed Scaffold/AppBar/Card and
    // stable content, not only on their corresponding colored containers.
    // In particular, settings paints its destructive action with error.
    // Preserve semantic inks and constrain tint instead of recoloring them.
    bool readable(Color surface) =>
        _contrast(scheme.onSurface, surface) >= 4.5 &&
        _contrast(scheme.onSurfaceVariant, surface) >= 4.5 &&
        _contrast(scheme.primary, surface) >= 4.5 &&
        _contrast(scheme.error, surface) >= 4.5;

    if (readable(composed)) return composed;
    // Preserve the existing foreground roles. An unreadable theme baseline
    // still needs a separate theme audit; this guard does not repair it.
    if (!readable(base)) return base;
    var accepted = base;
    var low = 0.0;
    var high = 1.0;
    for (var step = 0; step < 16; step++) {
      final amount = (low + high) / 2;
      final candidate = Color.lerp(
        base,
        composed,
        amount,
      )!.withValues(alpha: 1);
      if (readable(candidate)) {
        accepted = candidate;
        low = amount;
      } else {
        high = amount;
      }
    }
    return accepted;
  }

  static double _contrast(Color ink, Color surface) {
    final inkLuminance = Color.alphaBlend(ink, surface).computeLuminance();
    final surfaceLuminance = surface.computeLuminance();
    final lighter = inkLuminance > surfaceLuminance
        ? inkLuminance
        : surfaceLuminance;
    final darker = inkLuminance < surfaceLuminance
        ? inkLuminance
        : surfaceLuminance;
    return (lighter + 0.05) / (darker + 0.05);
  }

  static ColorScheme _contrastScheme(ColorScheme source) {
    final dark = source.brightness == Brightness.dark;
    final surface = dark ? Colors.black : Colors.white;
    final ink = dark ? Colors.white : Colors.black;
    final error = dark ? const Color(0xFFFFB4AB) : const Color(0xFF8B0000);
    return source.copyWith(
      surface: surface,
      surfaceDim: surface,
      surfaceBright: surface,
      surfaceContainerLowest: surface,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surface,
      surfaceContainerHighest: surface,
      onSurface: ink,
      onSurfaceVariant: ink,
      outline: ink,
      outlineVariant: ink,
      primary: ink,
      onPrimary: surface,
      primaryContainer: surface,
      onPrimaryContainer: ink,
      secondary: ink,
      onSecondary: surface,
      secondaryContainer: surface,
      onSecondaryContainer: ink,
      tertiary: ink,
      onTertiary: surface,
      tertiaryContainer: surface,
      onTertiaryContainer: ink,
      inverseSurface: ink,
      onInverseSurface: surface,
      inversePrimary: surface,
      error: error,
      onError: surface,
      errorContainer: surface,
      onErrorContainer: error,
      surfaceTint: Colors.transparent,
    );
  }
}
