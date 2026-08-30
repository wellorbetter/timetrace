import 'package:flutter/material.dart';

/// Deterministic, muted color per app name.
///
/// Data visualizations still need distinct series, but the palette stays close
/// to TimeTrace's warm neutral / restrained accent direction instead of using
/// saturated Material rainbow colors.
Color appColor(String name) {
  const colors = [
    Color(0xFF6F857A), // sage
    Color(0xFF71818C), // slate
    Color(0xFF927C61), // ochre
    Color(0xFF956F65), // clay
    Color(0xFF7B846B), // moss
    Color(0xFF6A8585), // muted teal
    Color(0xFF927378), // dusty rose
    Color(0xFF817A72), // warm stone
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}
