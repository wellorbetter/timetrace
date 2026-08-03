import 'package:lunar/lunar.dart';

/// Chinese lunar + festival info for a Gregorian date.
class LunarInfo {
  LunarInfo({this.day = '', this.festival, this.solarTerm});

  final String day; // e.g. 初一, 十五
  final String? festival; // e.g. 春节, 国庆节
  final String? solarTerm; // e.g. 立春

  bool get hasMarker => festival != null || solarTerm != null;
}

/// Compute lunar day + festivals for a date (pure Dart, no IO).
LunarInfo lunarInfo(DateTime d) {
  try {
    final solar = Solar.fromYmd(d.year, d.month, d.day);
    final lunar = solar.getLunar();
    final day = lunar.getDayInChinese();

    // Prefer solar term, then festival
    String? term;
    try {
      final t = lunar.getJieQi();
      if (t.isNotEmpty) term = t;
    } catch (_) {}

    String? festival;
    final solarFest = solar.getFestivals();
    final lunarFest = lunar.getFestivals();
    if (solarFest.isNotEmpty) {
      festival = solarFest.first;
    } else if (lunarFest.isNotEmpty) {
      festival = lunarFest.first;
    }

    return LunarInfo(day: day, festival: festival, solarTerm: term);
  } catch (_) {
    return LunarInfo(day: '');
  }
}
