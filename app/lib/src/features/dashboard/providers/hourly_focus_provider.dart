import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 联动焦点：日历 24h 热力条点击某小时后，时段分布页选中该小时。
class HourlyFocus {
  const HourlyFocus({required this.date, required this.hour});

  final DateTime date;
  final int hour;
}

class HourlyFocusNotifier extends Notifier<HourlyFocus?> {
  @override
  HourlyFocus? build() => null;

  void focus(DateTime date, int hour) {
    state = HourlyFocus(date: date, hour: hour);
  }
}

final hourlyFocusProvider =
    NotifierProvider<HourlyFocusNotifier, HourlyFocus?>(
      HourlyFocusNotifier.new,
    );
