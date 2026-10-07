import 'package:flutter/material.dart';

enum SurfaceStyle { glass, blend, solid }

@immutable
class MaterialAppearance {
  const MaterialAppearance({
    this.style = SurfaceStyle.glass,
    this.workOpacity = .52,
    this.contentOpacity = .84,
    this.blur = 24,
    this.tint = .15,
    this.cardEffects = true,
    this.light = .35,
    this.cardStyle = SurfaceStyle.glass,
    this.cardBlur = 3,
    this.refraction = .55,
    this.cardTint = .12,
    this.interactiveRefraction = false,
  });
  final SurfaceStyle style;
  final double workOpacity, contentOpacity, blur, tint;
  final bool cardEffects;
  // Design default, not a measured power-saving claim.
  final bool interactiveRefraction;
  final double light;
  final SurfaceStyle cardStyle;
  final double cardBlur, refraction, cardTint;
  MaterialAppearance copyWith({
    SurfaceStyle? style,
    double? workOpacity,
    double? contentOpacity,
    double? blur,
    double? tint,
    bool? cardEffects,
    double? light,
    SurfaceStyle? cardStyle,
    double? cardBlur,
    double? refraction,
    double? cardTint,
    bool? interactiveRefraction,
  }) => MaterialAppearance(
    style: style ?? this.style,
    workOpacity: workOpacity ?? this.workOpacity,
    contentOpacity: contentOpacity ?? this.contentOpacity,
    blur: blur ?? this.blur,
    tint: tint ?? this.tint,
    cardEffects: cardEffects ?? this.cardEffects,
    light: light ?? this.light,
    cardStyle: cardStyle ?? this.cardStyle,
    cardBlur: cardBlur ?? this.cardBlur,
    refraction: refraction ?? this.refraction,
    cardTint: cardTint ?? this.cardTint,
    interactiveRefraction: interactiveRefraction ?? this.interactiveRefraction,
  );
  static double bounded(
    Object? value,
    double fallback,
    double min,
    double max,
  ) => value is num && value.isFinite
      ? value.toDouble().clamp(min, max)
      : fallback;
  factory MaterialAppearance.fromPreferences(Map<String, dynamic> values) =>
      MaterialAppearance(
        style: SurfaceStyle.values.firstWhere(
          (style) => style.name == values['surfaceStyle'],
          orElse: () => SurfaceStyle.glass,
        ),
        workOpacity: bounded(values['surfaceOpacity'], .52, .2, 1),
        contentOpacity: bounded(values['contentOpacity'], .84, .6, 1),
        blur: bounded(values['surfaceBlur'], 24, 0, 40),
        tint: bounded(values['surfaceTint'], .15, 0, 1),
        cardEffects: values['cardEffects'] is bool
            ? values['cardEffects'] as bool
            : true,
        light: bounded(values['surfaceLight'], .35, 0, 1),
        cardStyle: SurfaceStyle.values.firstWhere(
          (value) => value.name == values['cardStyle'],
          orElse: () => SurfaceStyle.glass,
        ),
        cardBlur: bounded(values['cardBlur'], 3, 0, 12),
        refraction: bounded(values['cardRefraction'], .55, 0, 1),
        cardTint: bounded(values['cardTint'], .12, 0, 1),
        interactiveRefraction: values['interactiveRefraction'] == true,
      );
  Map<String, dynamic> toPreferences() => {
    'surfaceStyle': style.name,
    'surfaceOpacity': workOpacity,
    'contentOpacity': contentOpacity,
    'surfaceBlur': blur,
    'surfaceTint': tint,
    'cardEffects': cardEffects,
    'surfaceLight': light,
    'cardStyle': cardStyle.name,
    'cardBlur': cardBlur,
    'cardRefraction': refraction,
    'cardTint': cardTint,
    'interactiveRefraction': interactiveRefraction,
  };
}
