import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/tray/tray_service.dart';

class TimetraceApp extends ConsumerStatefulWidget {
  const TimetraceApp({super.key});

  @override
  ConsumerState<TimetraceApp> createState() => _TimetraceAppState();
}

class _TimetraceAppState extends ConsumerState<TimetraceApp>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    // Window manager: prevent close → hide to tray instead
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    // Set taskbar/title-bar icon (RC compiler is broken on this machine,
    // so we set it at runtime from the bundled asset).
    await windowManager.setIcon('assets/icon.ico');

    // System tray
    final tray = TrayService(ref);
    await tray.init();
  }

  @override
  void onWindowClose() async {
    // Hide to tray instead of quitting
    await windowManager.hide();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final dark = ref.watch(themeModeProvider);

    // Watch quit signal from tray
    ref.listen(trayExitProvider, (prev, next) {
      if (next) exit(0);
    });

    return MaterialApp.router(
      title: 'TimeTrace',
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(),
      darkTheme: TimetraceTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
    );
  }
}
