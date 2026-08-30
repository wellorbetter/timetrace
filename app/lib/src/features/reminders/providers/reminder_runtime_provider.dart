import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/notifications/notification_provider.dart';
import 'package:timetrace_app/src/features/app_limits/providers/app_timeout_rules_provider.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_sources.dart';
import 'package:timetrace_app/src/features/reminders/data/riverpod_reminder_configuration_source.dart';
import 'package:timetrace_app/src/features/reminders/data/rust_activity_snapshot_source.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

final activitySnapshotSourceProvider = Provider<ActivitySnapshotSource>((ref) {
  return RustActivitySnapshotSource(ref.watch(apiProvider));
});

final reminderConfigurationSourceProvider =
    Provider<ReminderConfigurationSource>((ref) {
      return RiverpodReminderConfigurationSource(
        readSettings: () => ref.read(persistedSettingsProvider),
        readLocale: () => ref.read(localeProvider),
        readRules: () {
          return ref.read(appTimeoutRulesProvider).value ??
              ref.read(appTimeoutRulesProvider.notifier).lastSuccessfulState;
        },
      );
    });

/// Optional deterministic clock override used by focused provider tests.
final reminderMonotonicClockProvider = Provider<ReminderMonotonicClock?>(
  (_) => null,
);

/// Optional periodic-task override used by focused provider tests.
final reminderPeriodicTaskFactoryProvider =
    Provider<ReminderPeriodicTaskFactory?>((_) => null);

/// The sole process-wide controller. It owns no plugin permission side effect.
final reminderRuntimeControllerProvider = Provider<ReminderRuntimeController>((
  ref,
) {
  final controller = ReminderRuntimeController(
    activitySource: ref.watch(activitySnapshotSourceProvider),
    configurationSource: ref.watch(reminderConfigurationSourceProvider),
    notificationPort: ref.watch(notificationPortProvider),
    clock: ref.watch(reminderMonotonicClockProvider),
    periodicTaskFactory: ref.watch(reminderPeriodicTaskFactoryProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Riverpod projection and command surface for the process-wide runtime.
class ReminderRuntimeNotifier extends Notifier<ReminderRuntimeState> {
  late ReminderRuntimeController _controller;

  @override
  ReminderRuntimeState build() {
    // Trigger each one-time persistent load without watching draft settings or
    // rebuilding the process-wide controller when those providers update.
    ref.read(settingsProvider);
    ref.read(appTimeoutRulesProvider);

    _controller = ref.watch(reminderRuntimeControllerProvider);
    _controller.addListener(_onRuntimeState);
    ref.onDispose(() => _controller.removeListener(_onRuntimeState));
    _controller.start();
    return _controller.state;
  }

  void _onRuntimeState(ReminderRuntimeState next) => state = next;

  void startPomodoro() => _controller.startPomodoro();
  void pausePomodoro() => _controller.pausePomodoro();
  void resumePomodoro() => _controller.resumePomodoro();
  void skipPomodoro() => _controller.skipPomodoro();
  void stopPomodoro() => _controller.stopPomodoro();
  void resetPomodoro() => _controller.resetPomodoro();
}

/// Watch this provider once from the application root to start the runtime.
final reminderRuntimeProvider =
    NotifierProvider<ReminderRuntimeNotifier, ReminderRuntimeState>(
      ReminderRuntimeNotifier.new,
    );
