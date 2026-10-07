import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/accounting.dart';

/// 联动焦点：日历热力条点击一个 Rust 本地小时桶后，时段分布页选中同一桶。
class HourlyFocus {
  const HourlyFocus({
    required this.date,
    required this.stableId,
    required this.localHour,
    required this.fold,
    required this.utcOffsetSeconds,
  });

  final DateTime date;
  final String stableId;
  final int localHour;
  final int fold;
  final int utcOffsetSeconds;
}

class HourlyFocusNotifier extends Notifier<HourlyFocus?> {
  @override
  HourlyFocus? build() => null;

  void focus(DateTime date, LocalHourBucketDto bucket) {
    state = HourlyFocus(
      date: date,
      stableId: bucket.stableId,
      localHour: bucket.localHour,
      fold: bucket.fold,
      utcOffsetSeconds: bucket.utcOffsetSeconds,
    );
  }
}

final hourlyFocusProvider = NotifierProvider<HourlyFocusNotifier, HourlyFocus?>(
  HourlyFocusNotifier.new,
);

String formatUtcOffset(int seconds) {
  final sign = seconds < 0 ? '-' : '+';
  final absolute = seconds.abs();
  final hours = absolute ~/ 3600;
  final minutes = (absolute % 3600) ~/ 60;
  return '$sign${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
}

/// Human-readable label that keeps repeated DST hours distinguishable.
String hourBucketLabel(
  LocalHourBucketDto bucket, {
  required bool repeated,
  bool compact = false,
}) {
  final hour = bucket.localHour.toString().padLeft(2, '0');
  if (!repeated) return compact ? hour : '$hour:00';
  if (compact) return '$hour²${bucket.fold + 1}';
  return '$hour:00 · 第${bucket.fold + 1}次 · UTC${formatUtcOffset(bucket.utcOffsetSeconds)}';
}
