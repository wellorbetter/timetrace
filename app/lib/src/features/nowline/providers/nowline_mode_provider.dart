import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/features/nowline/domain/nowline_preferences.dart';
import 'package:timetrace_app/src/features/nowline/providers/nowline_provider.dart';
import 'package:window_manager/window_manager.dart';

class NowlineModeState {
  const NowlineModeState({
    this.active = false,
    this.clickThrough = false,
    this.busy = false,
    this.error,
  });

  final bool active;
  final bool clickThrough;
  final bool busy;
  final String? error;

  NowlineModeState copyWith({
    bool? active,
    bool? clickThrough,
    bool? busy,
    String? error,
    bool clearError = false,
  }) => NowlineModeState(
    active: active ?? this.active,
    clickThrough: clickThrough ?? this.clickThrough,
    busy: busy ?? this.busy,
    error: clearError ? null : error ?? this.error,
  );
}

class NowlineModeNotifier extends Notifier<NowlineModeState> {
  Size? _restoreSize;
  Offset? _restorePosition;
  bool _wasMaximized = false;

  @override
  NowlineModeState build() => const NowlineModeState();

  Future<void> enter() async {
    if (state.active || state.busy) return;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final preferences = await ref.read(nowlinePreferencesProvider.future);
      _restoreSize = await windowManager.getSize();
      _restorePosition = await windowManager.getPosition();
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) await windowManager.unmaximize();

      // Switch the Flutter surface before shrinking the native window, so the
      // full dashboard never flashes inside the compact overlay bounds.
      state = NowlineModeState(
        active: true,
        clickThrough: preferences.clickThroughOnStart,
        busy: true,
      );
      await windowManager.setIgnoreMouseEvents(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setResizable(false);
      await windowManager.setMinimumSize(const Size(440, 150));
      await windowManager.setSize(
        Size(720, 112 + preferences.lineCount * 38),
        animate: true,
      );
      await windowManager.setAlignment(
        _alignment(preferences.placement),
        animate: true,
      );
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setIgnoreMouseEvents(
        preferences.clickThroughOnStart,
        forward: Platform.isMacOS,
      );
      await windowManager.show(inactive: true);
      if (Platform.isWindows || Platform.isMacOS) {
        await windowManager.blur();
      }
      state = state.copyWith(busy: false, clearError: true);
      AppLogger.log('Nowline overlay enabled');
    } catch (error, stack) {
      AppLogger.log('Nowline overlay setup failed: $error\n$stack');
      state = NowlineModeState(error: error.toString());
      await _restoreWindow(focus: true);
    }
  }

  Future<void> exit({bool focus = true}) async {
    if ((!state.active && !state.busy) || state.busy) {
      if (focus) {
        await windowManager.show();
        await windowManager.focus();
      }
      return;
    }
    state = state.copyWith(busy: true, clickThrough: false);
    try {
      await _restoreWindow(focus: focus);
      state = const NowlineModeState();
      AppLogger.log('Nowline overlay disabled');
    } catch (error, stack) {
      AppLogger.log('Nowline overlay restore failed: $error\n$stack');
      state = NowlineModeState(error: error.toString());
    }
  }

  Future<void> toggle() => state.active ? exit() : enter();

  Future<void> toggleClickThrough() async {
    if (!state.active || state.busy) return;
    final next = !state.clickThrough;
    await windowManager.setIgnoreMouseEvents(next, forward: Platform.isMacOS);
    if (!next) {
      await windowManager.show();
      await windowManager.focus();
    } else if (Platform.isWindows || Platform.isMacOS) {
      await windowManager.blur();
    }
    state = state.copyWith(clickThrough: next);
  }

  Future<void> _restoreWindow({required bool focus}) async {
    await windowManager.setIgnoreMouseEvents(false);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.setResizable(true);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setMinimumSize(const Size(940, 620));
    if (_restoreSize case final size?) {
      await windowManager.setSize(size, animate: true);
    }
    if (_restorePosition case final position?) {
      await windowManager.setPosition(position, animate: true);
    }
    if (_wasMaximized) await windowManager.maximize();
    await windowManager.show(inactive: !focus);
    if (focus) await windowManager.focus();
  }

  Alignment _alignment(NowlinePlacement placement) => switch (placement) {
    NowlinePlacement.top => Alignment.topCenter,
    NowlinePlacement.center => Alignment.center,
    NowlinePlacement.bottom => Alignment.bottomCenter,
  };
}

final nowlineModeProvider =
    NotifierProvider<NowlineModeNotifier, NowlineModeState>(
      NowlineModeNotifier.new,
    );
