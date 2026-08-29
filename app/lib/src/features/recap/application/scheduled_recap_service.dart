import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/recap/domain/recap_schedule.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_provider.dart';
import 'package:timetrace_app/src/features/recap/providers/recap_schedule_provider.dart';

/// Lightweight in-process scheduler. TimeTrace normally remains alive in the
/// tray/menu bar, so this gives users automatic daily/weekly recaps without an
/// OS service or account. If the process is completely quit, no background
/// work is attempted; OS-level wake scheduling can be layered on later.
class ScheduledRecapService {
  ScheduledRecapService(this.ref);

  final WidgetRef ref;
  Timer? _timer;
  bool _running = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => unawaited(checkNow()));
    unawaited(checkNow());
  }

  void dispose() => _timer?.cancel();

  Future<void> checkNow() async {
    if (_running) return;
    final schedule = ref.read(recapScheduleProvider).value;
    if (schedule == null || !schedule.enabled) return;

    final now = DateTime.now();
    if (!_isDue(schedule, now)) return;
    final runKey = _runKey(schedule, now);
    if (schedule.lastRunKey == runKey) return;

    _running = true;
    try {
      final range = schedule.cadence == RecapScheduleCadence.weekly
          ? DateRange.week
          : DateRange.today;
      final recap = await ref.read(recapProvider.notifier).generateScheduled(range);
      await ref.read(recapScheduleProvider.notifier).markRun(runKey);
      AppLogger.log('scheduled recap generated ($runKey, ${recap.result.origin.name})');
      if (schedule.notify) {
        await _showNotification(
          'TimeTrace · ${range == DateRange.week ? '每周回顾' : '今日回顾'}',
          '${recap.result.headline}\n${recap.result.summary}',
        );
      }
    } catch (error, stack) {
      AppLogger.log('scheduled recap failed: $error\n$stack');
    } finally {
      _running = false;
    }
  }

  static bool _isDue(RecapScheduleSettings settings, DateTime now) {
    if (settings.cadence == RecapScheduleCadence.off) return false;
    if (settings.cadence == RecapScheduleCadence.weekly && now.weekday != settings.weekday) {
      return false;
    }
    final scheduledMinutes = settings.hour * 60 + settings.minute;
    final nowMinutes = now.hour * 60 + now.minute;
    // A 59-minute grace window means sleep/resume or a busy model request does
    // not silently lose the day's recap, while lastRunKey prevents duplicates.
    return nowMinutes >= scheduledMinutes && nowMinutes < scheduledMinutes + 60;
  }

  static String _runKey(RecapScheduleSettings settings, DateTime now) {
    if (settings.cadence == RecapScheduleCadence.daily) {
      return '${now.year}-${_two(now.month)}-${_two(now.day)}';
    }
    final thursday = now.add(Duration(days: DateTime.thursday - now.weekday));
    final firstThursday = DateTime(thursday.year, 1, 4);
    final firstWeekThursday = firstThursday.add(
      Duration(days: DateTime.thursday - firstThursday.weekday),
    );
    final week = 1 + thursday.difference(firstWeekThursday).inDays ~/ 7;
    return '${thursday.year}-W${_two(week)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static Future<void> _showNotification(String title, String body) async {
    final compactBody = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    try {
      if (Platform.isMacOS) {
        final escapedTitle = title.replaceAll('"', '\\"');
        final escapedBody = compactBody.replaceAll('"', '\\"');
        await Process.run('osascript', [
          '-e',
          'display notification "$escapedBody" with title "$escapedTitle"',
        ]);
        return;
      }
      if (Platform.isLinux) {
        final result = await Process.run('which', ['notify-send']);
        if (result.exitCode == 0) {
          await Process.run('notify-send', [title, compactBody]);
        }
        return;
      }
      if (Platform.isWindows) {
        final safeTitle = title.replaceAll("'", "''");
        final safeBody = compactBody.replaceAll("'", "''");
        final script = r'''[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null; [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null; $xml = New-Object Windows.Data.Xml.Dom.XmlDocument; $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>''' + safeTitle + r'''</text><text>''' + safeBody + r'''</text></binding></visual></toast>"); $toast = [Windows.UI.Notifications.ToastNotification]::new($xml); [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('TimeTrace').Show($toast);''';
        await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ]);
      }
    } catch (error) {
      AppLogger.log('scheduled recap notification unavailable: $error');
    }
  }
}
