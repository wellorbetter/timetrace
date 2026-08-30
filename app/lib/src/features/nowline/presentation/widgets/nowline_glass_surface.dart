import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';

enum NowlineGlassRole { functional, content, accent }

/// A restrained glass surface for Nowline.
///
/// Only [NowlineGlassRole.functional] uses backdrop blur by default. Content
/// surfaces keep the translucent edge treatment without stacking many costly
/// blur filters. The outer separator and inner light reflection keep the
/// boundary readable over both wallpapers and solid app backgrounds.
class NowlineGlassSurface extends StatelessWidget {
  const NowlineGlassSurface({
    required this.child,
    this.role = NowlineGlassRole.content,
    this.padding = const EdgeInsets.all(TimeTraceSpace.md),
    this.radius = TimeTraceRadius.surface,
    this.opacity,
    this.blurSigma,
    this.shadow = false,
    super.key,
  });

  final Widget child;
  final NowlineGlassRole role;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double? opacity;
  final double? blurSigma;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final resolvedBlur = highContrast
        ? 0.0
        : (blurSigma ?? (role == NowlineGlassRole.functional ? 18.0 : 0.0));
    final requestedOpacity = opacity?.clamp(0.0, 1.0).toDouble();

    final fill = switch (role) {
      NowlineGlassRole.functional => scheme.surface.withValues(
        alpha: highContrast ? 0.98 : requestedOpacity ?? (dark ? 0.78 : 0.82),
      ),
      NowlineGlassRole.content => scheme.surfaceContainerLowest.withValues(
        alpha: highContrast ? 0.98 : (dark ? 0.82 : 0.88),
      ),
      NowlineGlassRole.accent => scheme.primaryContainer.withValues(
        alpha: highContrast ? 0.96 : (dark ? 0.58 : 0.66),
      ),
    };
    final outerBorder = highContrast
        ? scheme.outline
        : scheme.outlineVariant.withValues(
            alpha: role == NowlineGlassRole.functional ? 0.98 : 0.9,
          );
    final innerHighlight = dark
        ? Colors.white.withValues(alpha: 0.09)
        : Colors.white.withValues(alpha: 0.58);
    final outerRadius = BorderRadius.circular(radius);
    final innerRadius = BorderRadius.circular(
      (radius - 1).clamp(0.0, radius).toDouble(),
    );

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: innerRadius,
        border: Border.all(color: innerHighlight),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (resolvedBlur > 0) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: resolvedBlur, sigmaY: resolvedBlur),
        child: surface,
      );
    }

    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: outerRadius,
          border: Border.all(color: outerBorder, width: highContrast ? 1.5 : 1),
          boxShadow: shadow
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.3 : 0.14),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: dark ? 0.06 : 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipRRect(borderRadius: innerRadius, child: surface),
        ),
      ),
    );
  }
}
