import 'package:flutter/material.dart';

/// Deterministic color per app name (Material 3 palette).
Color appColor(String name) {
  const colors = [
    Color(0xFF6750A4), Color(0xFF1976D2), Color(0xFF388E3C),
    Color(0xFFED6C02), Color(0xFF009688), Color(0xFFD32F2F),
    Color(0xFF9C27B0), Color(0xFF795548),
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}
