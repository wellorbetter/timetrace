import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/tray/tray_menu_model.dart';
import 'package:timetrace_app/src/features/app_limits/domain/activity_snapshot.dart';
import 'package:timetrace_app/src/features/reminders/application/reminder_runtime_controller.dart';
import 'package:timetrace_app/src/features/reminders/providers/reminder_runtime_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Cross-platform tray/menu-bar integration for Windows and macOS.
///
/// The application root owns one long-lived instance and must call [dispose].
/// [init] is idempotent, so this instance installs at most one tray listener.
class TrayService with TrayListener {
  TrayService(this._ref) {
    _menuUpdater = SerializedTrayMenuUpdater(
      write: _applyMenuModel,
      onError: (_, _) => AppLogger.log('tray menu sync failed'),
    );
  }

  final WidgetRef _ref;
  late final SerializedTrayMenuUpdater _menuUpdater;
  final TrayMenuSyncGate _menuSyncGate = TrayMenuSyncGate();

  ProviderSubscription<ReminderRuntimeState>? _runtimeSubscription;
  ProviderSubscription<AppLocale>? _localeSubscription;
  ReminderRuntimeState? _latestRuntimeState;
  AppLocale _locale = AppLocale.zh;
  Future<void>? _initialization;
  bool _listenerAttached = false;
  bool _iconSet = false;
  bool _disposed = false;
  bool _lastKnownTrackingPaused = false;

  Future<void> init() {
    if (_disposed) {
      return Future<void>.error(
        StateError('Cannot initialize a disposed TrayService.'),
      );
    }
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      if (!_listenerAttached) {
        trayManager.addListener(this);
        _listenerAttached = true;
      }

      await trayManager.setIcon(
        Platform.isWindows ? 'assets/icon.ico' : 'assets/icon_preview.png',
        // macOS menu-bar icons should behave as template images so the system
        // renders them correctly in both light and dark appearances.
        isTemplate: Platform.isMacOS,
      );
      _iconSet = true;
      if (_disposed) {
        await _destroyIcon();
        return;
      }

      final initialState = _ref.read(reminderRuntimeProvider);
      _locale = _ref.read(localeProvider);
      _latestRuntimeState = initialState;
      _runtimeSubscription = _ref.listenManual(reminderRuntimeProvider, (
        _,
        next,
      ) {
        _latestRuntimeState = next;
        unawaited(_queueMenuSync(next));
      }, fireImmediately: false);
      _localeSubscription = _ref.listenManual(localeProvider, (_, next) {
        if (_locale == next) return;
        _locale = next;
        unawaited(_syncLatestMenu(precise: true));
      }, fireImmediately: false);
      await _queueMenuSync(initialState);
      if (!_disposed) {
        AppLogger.log('tray initialized (${Platform.operatingSystem})');
      }
    } catch (_) {
      AppLogger.log('tray initialization failed');
      await dispose();
      rethrow;
    }
  }

  /// Detaches the sole listener/subscription and destroys the owned tray icon.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _runtimeSubscription?.close();
    _runtimeSubscription = null;
    _localeSubscription?.close();
    _localeSubscription = null;
    if (_listenerAttached) {
      trayManager.removeListener(this);
      _listenerAttached = false;
    }
    await _menuUpdater.dispose();
    await _destroyIcon();
  }

  Future<void> _queueMenuSync(
    ReminderRuntimeState state, {
    bool precise = false,
  }) {
    if (_disposed) {
      return Future<void>.value();
    }
    final boundary = TrayMenuSyncBoundary.fromPomodoro(
      config: state.configuration.pomodoro,
      state: state.pomodoro,
      activityPaused: state.activity?.state == ActivitySnapshotState.paused,
      locale: _locale,
    );
    if (!_menuSyncGate.shouldRequest(
      tickCount: state.tickCount,
      boundary: boundary,
      precise: precise,
    )) {
      return Future<void>.value();
    }
    return _menuUpdater.request(() => _resolveMenuModel(state));
  }

  TrayMenuModel _resolveMenuModel(ReminderRuntimeState state) {
    var trackingPaused = _lastKnownTrackingPaused;
    try {
      trackingPaused = _ref.read(apiProvider).isTrackingPaused();
      _lastKnownTrackingPaused = trackingPaused;
    } catch (_) {
      // Keep the last confirmed value and retry on the next admitted refresh.
      // The native menu is never updated from an assumed toggle.
    }
    return TrayMenuModel.fromPomodoro(
      enabled: state.configuration.pomodoro.enabled,
      state: state.pomodoro,
      trackingPaused: trackingPaused,
      strings: ReminderL10n(_locale),
    );
  }

  Future<void> _applyMenuModel(TrayMenuModel model) async {
    if (_disposed) {
      return;
    }
    await trayManager.setToolTip(model.tooltip);
    if (_disposed) {
      return;
    }
    await trayManager.setContextMenu(_buildMenu(model));
  }

  Menu _buildMenu(TrayMenuModel model) {
    return Menu(
      items: [
        MenuItem(
          key: TrayMenuKeys.pomodoroStatus,
          label: model.pomodoroStatusLabel,
          disabled: true,
        ),
        for (final action in model.pomodoroActions)
          MenuItem(key: action.key, label: action.label),
        MenuItem.separator(),
        MenuItem(
          key: TrayMenuKeys.trackingStatus,
          label: model.trackingStatusLabel,
          disabled: true,
        ),
        MenuItem(key: TrayMenuKeys.show, label: model.showActionLabel),
        MenuItem(
          key: TrayMenuKeys.trackingPause,
          label: model.trackingActionLabel,
        ),
        MenuItem.separator(),
        MenuItem(key: TrayMenuKeys.quit, label: model.quitActionLabel),
      ],
    );
  }

  Future<void> _syncLatestMenu({bool precise = false}) {
    final cached = _latestRuntimeState;
    final ReminderRuntimeState state;
    if (cached != null) {
      state = cached;
    } else {
      state = _ref.read(reminderRuntimeProvider);
    }
    _latestRuntimeState = state;
    return _queueMenuSync(state, precise: precise);
  }

  Future<void> _showWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      AppLogger.log('tray show window failed');
    }
  }

  Future<void> _openContextMenu() async {
    if (_disposed) {
      return;
    }
    try {
      // Bypass background throttling so the menu always opens with the exact
      // second and latest tracking-pause state.
      await _syncLatestMenu(precise: true);
      if (!_disposed) {
        await trayManager.popUpContextMenu();
      }
    } catch (_) {
      AppLogger.log('tray context menu failed');
    }
  }

  Future<void> _toggleTrackingPause() async {
    if (_disposed) {
      return;
    }
    try {
      final api = _ref.read(apiProvider);
      final current = api.isTrackingPaused();
      api.setTrackingPaused(paused: !current);
      _lastKnownTrackingPaused = !current;
      AppLogger.log('tracking ${current ? 'resumed' : 'paused'} via tray');
    } catch (_) {
      AppLogger.log('tray tracking pause failed');
    }
    try {
      await _syncLatestMenu(precise: true);
    } catch (_) {
      AppLogger.log('tray tracking state refresh failed');
    }
  }

  void _dispatchPomodoro(String key) {
    if (_disposed) {
      return;
    }
    try {
      final notifier = _ref.read(reminderRuntimeProvider.notifier);
      switch (key) {
        case TrayMenuKeys.pomodoroStart:
          notifier.startPomodoro();
          break;
        case TrayMenuKeys.pomodoroPause:
          notifier.pausePomodoro();
          break;
        case TrayMenuKeys.pomodoroResume:
          notifier.resumePomodoro();
          break;
        case TrayMenuKeys.pomodoroSkip:
          notifier.skipPomodoro();
          break;
        case TrayMenuKeys.pomodoroStop:
          notifier.stopPomodoro();
          break;
      }
    } catch (_) {
      AppLogger.log('tray pomodoro action failed');
    }
  }

  Future<void> _quit() async {
    AppLogger.log('quit via tray');
    await dispose();
    _ref.read(trayExitProvider.notifier).requestExit();
  }

  Future<void> _destroyIcon() async {
    if (!_iconSet) {
      return;
    }
    _iconSet = false;
    try {
      await trayManager.destroy();
    } catch (_) {
      AppLogger.log('tray destroy failed');
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (_disposed) {
      return;
    }
    // A menu-bar item conventionally opens its menu on primary click on macOS;
    // Windows keeps the existing primary-click-to-show-window behavior.
    if (Platform.isMacOS) {
      unawaited(_openContextMenu());
    } else {
      unawaited(_showWindow());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_disposed) {
      unawaited(_openContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case TrayMenuKeys.show:
        unawaited(_showWindow());
        break;
      case TrayMenuKeys.trackingPause:
        unawaited(_toggleTrackingPause());
        break;
      case TrayMenuKeys.pomodoroStart:
      case TrayMenuKeys.pomodoroPause:
      case TrayMenuKeys.pomodoroResume:
      case TrayMenuKeys.pomodoroSkip:
      case TrayMenuKeys.pomodoroStop:
        _dispatchPomodoro(menuItem.key!);
        break;
      case TrayMenuKeys.quit:
        unawaited(_quit());
        break;
    }
  }
}

class TrayExitNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void requestExit() => state = true;
}

final trayExitProvider = NotifierProvider<TrayExitNotifier, bool>(
  TrayExitNotifier.new,
);
