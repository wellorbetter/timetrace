import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_mode_provider.dart';

/// Cross-platform tray/menu-bar integration for Windows and macOS.
class TrayService with TrayListener {
  TrayService(this._ref);

  final WidgetRef _ref;
  bool _paused = false;
  bool _nowlineActive = false;
  bool _nowlineClickThrough = false;
  ProviderSubscription<NowlineModeState>? _nowlineSubscription;

  Future<void> init() async {
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows ? 'assets/icon.ico' : 'assets/icon_preview.png',
      // macOS menu-bar icons should behave as template images so the system
      // renders them correctly in both light and dark appearances.
      isTemplate: Platform.isMacOS,
    );
    await trayManager.setToolTip('TimeTrace — 应用使用追踪');
    try {
      _paused = _ref.read(apiProvider).isTrackingPaused();
    } catch (_) {}
    final initialNowline = _ref.read(nowlineModeProvider);
    _nowlineActive = initialNowline.active;
    _nowlineClickThrough = initialNowline.clickThrough;
    _nowlineSubscription = _ref.listenManual(nowlineModeProvider, (
      previous,
      next,
    ) {
      _nowlineActive = next.active;
      _nowlineClickThrough = next.clickThrough;
      unawaited(_updateMenu());
    });
    await _updateMenu();
    AppLogger.log('tray initialized (${Platform.operatingSystem})');
  }

  Future<void> _updateMenu() async {
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            key: 'status',
            label: _paused ? '已暂停追踪' : '正在追踪使用时间',
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(key: 'show', label: '显示 TimeTrace'),
          MenuItem(
            key: 'nowline',
            label: _nowlineActive ? '关闭 Nowline' : '显示 Nowline',
          ),
          if (_nowlineActive)
            MenuItem(
              key: 'nowline-lock',
              label: _nowlineClickThrough ? '解锁 Nowline' : '锁定并点击穿透',
            ),
          MenuItem(key: 'pause', label: _paused ? '恢复追踪' : '暂停追踪'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: '退出 TimeTrace'),
        ],
      ),
    );
  }

  Future<void> _showWindow() async {
    if (_nowlineActive) {
      await _ref.read(nowlineModeProvider.notifier).exit();
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _toggleNowline() =>
      _ref.read(nowlineModeProvider.notifier).toggle();

  Future<void> _toggleNowlineLock() =>
      _ref.read(nowlineModeProvider.notifier).toggleClickThrough();

  Future<void> _togglePause() async {
    _paused = !_paused;
    try {
      _ref.read(apiProvider).setTrackingPaused(paused: _paused);
      AppLogger.log('tracking ${_paused ? 'paused' : 'resumed'} via tray');
    } catch (e) {
      _paused = !_paused;
      AppLogger.log('tray pause failed: $e');
    }
    await trayManager.setToolTip(
      _paused ? 'TimeTrace — 已暂停' : 'TimeTrace — 应用使用追踪',
    );
    await _updateMenu();
  }

  Future<void> _quit() async {
    AppLogger.log('quit via tray');
    _nowlineSubscription?.close();
    await trayManager.destroy();
    _ref.read(trayExitProvider.notifier).requestExit();
  }

  @override
  void onTrayIconMouseDown() {
    // A menu-bar item conventionally opens its menu on primary click on macOS;
    // Windows keeps the existing primary-click-to-show-window behavior.
    if (Platform.isMacOS) {
      trayManager.popUpContextMenu();
    } else {
      _showWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
        break;
      case 'pause':
        _togglePause();
        break;
      case 'nowline':
        _toggleNowline();
        break;
      case 'nowline-lock':
        _toggleNowlineLock();
        break;
      case 'quit':
        _quit();
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
