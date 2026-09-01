import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/tray/tray_menu_model.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/focus/application/focus_runtime_projection.dart';
import 'package:timetrace_app/src/features/focus/domain/pomodoro.dart';

void main() {
  group('TrayMenuModel', () {
    test('disabled timer preserves the existing tracking controls', () {
      final active = TrayMenuModel.fromPomodoro(
        enabled: false,
        state: const PomodoroState.initial(),
        trackingPaused: false,
      );
      final paused = TrayMenuModel.fromPomodoro(
        enabled: false,
        state: const PomodoroState.initial(),
        trackingPaused: true,
      );

      expect(active.tooltip, 'TimeTrace — 应用使用追踪');
      expect(active.pomodoroStatusLabel, '番茄钟未启用');
      expect(active.pomodoroActions, isEmpty);
      expect(active.trackingStatusLabel, '正在追踪使用时间');
      expect(active.trackingActionLabel, '暂停追踪');
      expect(paused.tooltip, 'TimeTrace — 已暂停追踪');
      expect(paused.trackingActionLabel, '恢复追踪');
    });

    test('idle timer exposes only start', () {
      final model = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: const PomodoroState.initial(),
        trackingPaused: false,
      );

      expect(model.pomodoroStatusLabel, '番茄钟 · 准备开始');
      expect(model.tooltip, 'TimeTrace — 番茄钟 · 准备开始');
      expect(model.pomodoroActions.map((action) => action.key), [
        TrayMenuKeys.pomodoroStart,
      ]);
    });

    test('running timer displays phase and second-level remaining time', () {
      final model = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: const PomodoroState(
          phase: PomodoroPhase.focus,
          intent: PomodoroIntent.running,
          remaining: Duration(minutes: 18, seconds: 4),
          completedFocusCount: 2,
        ),
        trackingPaused: false,
      );

      expect(model.pomodoroStatusLabel, '专注 · 18:04');
      expect(model.tooltip, 'TimeTrace — 专注 · 18:04');
      expect(model.pomodoroActions.map((action) => action.key), [
        TrayMenuKeys.pomodoroPause,
        TrayMenuKeys.pomodoroSkip,
        TrayMenuKeys.pomodoroStop,
      ]);
    });

    test('system-frozen status uses the shared privacy-minimal projection', () {
      const state = PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 18, seconds: 4),
        completedFocusCount: 2,
      );
      final systemFrozen = isPomodoroSystemFrozen(
        pomodoro: state,
        activityState: ActivitySnapshotState.idle,
      );
      final model = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state,
        trackingPaused: false,
        systemFrozen: systemFrozen,
      );
      final english = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state,
        trackingPaused: false,
        systemFrozen: systemFrozen,
        strings: ReminderL10n.en,
      );
      final eligible = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state,
        trackingPaused: false,
      );

      expect(systemFrozen, isTrue);
      expect(model.pomodoroStatusLabel, '专注 · 18:04 · 计时暂停');
      expect(model.tooltip, 'TimeTrace — 专注 · 18:04 · 计时暂停');
      expect(english.pomodoroStatusLabel, 'Focus · 18:04 · Timer paused');
      expect(model.pomodoroActions.first.key, TrayMenuKeys.pomodoroPause);
      expect(model, isNot(eligible));
    });

    test(
      'paused and ready phases expose resume without losing phase state',
      () {
        final paused = TrayMenuModel.fromPomodoro(
          enabled: true,
          state: const PomodoroState(
            phase: PomodoroPhase.shortBreak,
            intent: PomodoroIntent.userPaused,
            remaining: Duration(minutes: 4),
            completedFocusCount: 1,
          ),
          trackingPaused: true,
        );
        final ready = TrayMenuModel.fromPomodoro(
          enabled: true,
          state: const PomodoroState(
            phase: PomodoroPhase.longBreak,
            intent: PomodoroIntent.ready,
            remaining: Duration(hours: 1, seconds: 2),
            completedFocusCount: 4,
          ),
          trackingPaused: false,
        );

        expect(paused.pomodoroStatusLabel, '短休息 · 04:00 · 已暂停');
        expect(paused.tooltip, 'TimeTrace — 已暂停追踪 · 短休息 · 04:00 · 已暂停');
        expect(paused.pomodoroActions.first.key, TrayMenuKeys.pomodoroResume);
        expect(paused.pomodoroActions.first.label, '继续番茄钟');
        expect(ready.pomodoroStatusLabel, '长休息 · 01:00:02 · 等待开始');
        expect(ready.pomodoroActions.first.key, TrayMenuKeys.pomodoroResume);
        expect(ready.pomodoroActions.first.label, '开始当前阶段');
      },
    );

    test('equivalent projections compare equal for native-update deduping', () {
      const state = PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 12),
        completedFocusCount: 0,
      );
      final first = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state,
        trackingPaused: false,
      );
      final same = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state,
        trackingPaused: false,
      );
      final nextSecond = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: state.copyWith(
          remaining: const Duration(minutes: 11, seconds: 59),
        ),
        trackingPaused: false,
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(nextSecond));
      for (final label in <String>[
        first.tooltip,
        first.pomodoroStatusLabel,
        first.trackingStatusLabel,
        first.trackingActionLabel,
        ...first.pomodoroActions.map((action) => action.label),
      ]) {
        expect(label, isNot(contains(r'C:\Users\private\secret.exe')));
        expect(label, isNot(contains('private-document.txt')));
      }
    });

    test('English locale projects every tray label without privacy input', () {
      final model = TrayMenuModel.fromPomodoro(
        enabled: true,
        state: const PomodoroState(
          phase: PomodoroPhase.shortBreak,
          intent: PomodoroIntent.userPaused,
          remaining: Duration(minutes: 4),
          completedFocusCount: 1,
        ),
        trackingPaused: true,
        strings: ReminderL10n.en,
      );

      expect(
        model.tooltip,
        'TimeTrace — Tracking paused · Short break · 04:00 · Paused',
      );
      expect(model.pomodoroStatusLabel, 'Short break · 04:00 · Paused');
      expect(model.trackingActionLabel, 'Resume tracking');
      expect(model.showActionLabel, 'Show TimeTrace');
      expect(model.quitActionLabel, 'Quit TimeTrace');
      expect(model.pomodoroActions.first.label, 'Resume Pomodoro');
      expect(model.tooltip, isNot(contains(r'C:\Users')));
    });
  });

  group('TrayMenuSyncGate', () {
    test('locale boundary bypasses background cadence immediately', () {
      final gate = TrayMenuSyncGate();
      const state = PomodoroState.initial();
      expect(
        gate.shouldRequest(
          tickCount: 1,
          boundary: TrayMenuSyncBoundary.fromPomodoro(
            config: _enabledConfig,
            state: state,
            activityPaused: false,
            systemFrozen: false,
          ),
        ),
        isTrue,
      );
      expect(
        gate.shouldRequest(
          tickCount: 1,
          boundary: TrayMenuSyncBoundary.fromPomodoro(
            config: _enabledConfig,
            state: state,
            activityPaused: false,
            systemFrozen: false,
            locale: AppLocale.en,
          ),
        ),
        isTrue,
      );
    });

    test(
      'steady background countdown admits one FFI request per ten ticks',
      () async {
        final gate = TrayMenuSyncGate();
        var pauseReads = 0;
        var nativeWrites = 0;
        final acceptedTicks = <int>[];
        final updater = SerializedTrayMenuUpdater(
          write: (_) async => nativeWrites += 2,
        );

        for (var tick = 0; tick <= 30; tick++) {
          final state = PomodoroState(
            phase: PomodoroPhase.focus,
            intent: PomodoroIntent.running,
            remaining: Duration(seconds: 100 - tick),
            phaseDuration: const Duration(seconds: 100),
            completedFocusCount: 0,
          );
          final admitted = gate.shouldRequest(
            tickCount: tick,
            boundary: TrayMenuSyncBoundary.fromPomodoro(
              config: _enabledConfig,
              state: state,
              activityPaused: false,
              systemFrozen: false,
            ),
          );
          if (!admitted) continue;
          acceptedTicks.add(tick);
          await updater.request(() {
            pauseReads++;
            return TrayMenuModel.fromPomodoro(
              enabled: true,
              state: state,
              trackingPaused: false,
            );
          });
        }

        expect(acceptedTicks, [0, 10, 20, 30]);
        expect(pauseReads, acceptedTicks.length);
        expect(nativeWrites, acceptedTicks.length * 2);
        await updater.dispose();
      },
    );

    test('boundaries and precise menu opens bypass the background cadence', () {
      final gate = TrayMenuSyncGate();
      const running = PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 25),
        phaseDuration: Duration(minutes: 25),
        completedFocusCount: 0,
      );

      bool request({
        required PomodoroConfig config,
        required PomodoroState state,
        bool activityPaused = false,
        bool systemFrozen = false,
        bool precise = false,
      }) {
        return gate.shouldRequest(
          tickCount: 1,
          boundary: TrayMenuSyncBoundary.fromPomodoro(
            config: config,
            state: state,
            activityPaused: activityPaused,
            systemFrozen: systemFrozen,
          ),
          precise: precise,
        );
      }

      expect(request(config: _enabledConfig, state: running), isTrue);
      expect(request(config: _enabledConfig, state: running), isFalse);
      expect(
        request(
          config: _enabledConfig,
          state: running.copyWith(intent: PomodoroIntent.userPaused),
        ),
        isTrue,
      );
      expect(
        request(
          config: const PomodoroConfig(
            enabled: true,
            focusDuration: Duration(minutes: 30),
          ),
          state: running.copyWith(intent: PomodoroIntent.userPaused),
        ),
        isTrue,
      );
      expect(
        request(
          config: const PomodoroConfig(
            enabled: true,
            focusDuration: Duration(minutes: 30),
          ),
          state: running.copyWith(
            phase: PomodoroPhase.shortBreak,
            intent: PomodoroIntent.ready,
          ),
        ),
        isTrue,
      );
      expect(
        request(
          config: const PomodoroConfig(
            enabled: true,
            focusDuration: Duration(minutes: 30),
          ),
          state: running.copyWith(
            phase: PomodoroPhase.shortBreak,
            intent: PomodoroIntent.ready,
          ),
          activityPaused: true,
        ),
        isTrue,
      );
      expect(
        request(
          config: const PomodoroConfig(
            enabled: true,
            focusDuration: Duration(minutes: 30),
          ),
          state: running.copyWith(
            phase: PomodoroPhase.shortBreak,
            intent: PomodoroIntent.ready,
          ),
          activityPaused: true,
          precise: true,
        ),
        isTrue,
      );
      expect(
        request(
          config: const PomodoroConfig(
            enabled: true,
            focusDuration: Duration(minutes: 30),
          ),
          state: running.copyWith(
            phase: PomodoroPhase.shortBreak,
            intent: PomodoroIntent.ready,
          ),
          activityPaused: true,
        ),
        isFalse,
      );
    });

    test('system freeze boundaries bypass the background cadence', () {
      final gate = TrayMenuSyncGate();
      const state = PomodoroState(
        phase: PomodoroPhase.focus,
        intent: PomodoroIntent.running,
        remaining: Duration(minutes: 25),
        phaseDuration: Duration(minutes: 25),
        completedFocusCount: 0,
      );

      bool request({required bool systemFrozen, required int tick}) {
        return gate.shouldRequest(
          tickCount: tick,
          boundary: TrayMenuSyncBoundary.fromPomodoro(
            config: _enabledConfig,
            state: state,
            activityPaused: false,
            systemFrozen: systemFrozen,
          ),
        );
      }

      expect(request(systemFrozen: false, tick: 1), isTrue);
      expect(request(systemFrozen: false, tick: 2), isFalse);
      expect(request(systemFrozen: true, tick: 2), isTrue);
      expect(request(systemFrozen: true, tick: 3), isFalse);
      expect(request(systemFrozen: false, tick: 3), isTrue);
    });
  });

  group('SerializedTrayMenuUpdater', () {
    test(
      'resolves every settled sync but skips an identical native write',
      () async {
        var resolutions = 0;
        final writes = <TrayMenuModel>[];
        final updater = SerializedTrayMenuUpdater(
          write: (model) async => writes.add(model),
        );
        final model = TrayMenuModel.fromPomodoro(
          enabled: false,
          state: const PomodoroState.initial(),
          trackingPaused: false,
        );

        await updater.request(() {
          resolutions++;
          return model;
        });
        await updater.request(() {
          resolutions++;
          return model;
        });

        expect(resolutions, 2);
        expect(writes, [model]);
        expect(updater.appliedModel, model);
        await updater.dispose();
      },
    );

    test(
      'serializes writes and coalesces pending requests to the latest',
      () async {
        final firstStarted = Completer<void>();
        final releaseFirst = Completer<void>();
        final writes = <TrayMenuModel>[];
        var activeWrites = 0;
        var maximumActiveWrites = 0;
        var resolutions = 0;
        final updater = SerializedTrayMenuUpdater(
          write: (model) async {
            activeWrites++;
            maximumActiveWrites = activeWrites > maximumActiveWrites
                ? activeWrites
                : maximumActiveWrites;
            writes.add(model);
            if (writes.length == 1) {
              firstStarted.complete();
              await releaseFirst.future;
            }
            activeWrites--;
          },
        );
        final first = _modelWithRemaining(3);
        final replaced = _modelWithRemaining(2);
        final latest = _modelWithRemaining(1);

        final firstDone = updater.request(() {
          resolutions++;
          return first;
        });
        await firstStarted.future;
        final replacedDone = updater.request(() {
          resolutions++;
          return replaced;
        });
        final latestDone = updater.request(() {
          resolutions++;
          return latest;
        });
        releaseFirst.complete();
        await Future.wait([firstDone, replacedDone, latestDone]);

        expect(writes, [first, latest]);
        expect(resolutions, 2);
        expect(maximumActiveWrites, 1);
        await updater.dispose();
      },
    );

    test(
      'a failed write does not mark the model applied or deadlock retries',
      () async {
        var attempts = 0;
        var errors = 0;
        final model = _modelWithRemaining(1);
        final updater = SerializedTrayMenuUpdater(
          write: (_) async {
            attempts++;
            if (attempts == 1) {
              throw StateError('simulated native failure');
            }
          },
          onError: (_, _) => errors++,
        );

        await updater.request(() => model);
        expect(updater.appliedModel, isNull);
        await updater.request(() => model);

        expect(attempts, 2);
        expect(errors, 1);
        expect(updater.appliedModel, model);
        await updater.dispose();
      },
    );
  });
}

const _enabledConfig = PomodoroConfig(enabled: true);

TrayMenuModel _modelWithRemaining(int seconds) {
  return TrayMenuModel.fromPomodoro(
    enabled: true,
    state: PomodoroState(
      phase: PomodoroPhase.focus,
      intent: PomodoroIntent.running,
      remaining: Duration(seconds: seconds),
      completedFocusCount: 0,
    ),
    trackingPaused: false,
  );
}
