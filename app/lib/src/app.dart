import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:timetrace_app/src/core/material/material.dart';
import 'package:timetrace_app/src/core/router/app_router.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'core/theme/material_appearance_provider.dart';
import 'core/preferences/presentation_preferences_provider.dart';
import 'core/window/window_presentation.dart';
import 'core/window/window_caption.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/core/tray/tray_service.dart';
import 'package:timetrace_app/src/core/tray/tray_panel.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

final startupArgumentsProvider = Provider<List<String>>((ref) => const []);

class TimetraceApp extends ConsumerStatefulWidget {
  const TimetraceApp({super.key});

  @override
  ConsumerState<TimetraceApp> createState() => _TimetraceAppState();
}

class _TimetraceAppState extends ConsumerState<TimetraceApp>
    with WindowListener {
  MaterialSignals _materialSignals = const MaterialSignals();
  Timer? _materialSignalTimer;
  bool _readingMaterialSignals = false;
  TrayService? _tray;
  WindowPresentation? _presentation;

  @override
  void initState() {
    super.initState();
    _presentation = ref.read(windowPresentationProvider);
    _setup();
    if (Platform.isWindows) {
      unawaited(_refreshMaterialSignals());
      // Registry preferences have no Flutter notification on Windows.
      // Refresh while focused too, so changes made without switching windows
      // are eventually observed. This is sampled state, not a native watcher.
      _materialSignalTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refreshMaterialSignals()),
      );
    }
  }

  Future<void> _setup() async {
    await windowManager.ensureInitialized();
    if (!mounted) return;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    if (!mounted) return;
    await windowManager.setIcon('assets/icon.ico');
    if (!mounted) return;

    await _presentation!.activate();
    if (!mounted) return;
    final tray = TrayService(ref, presentation: _presentation);
    _tray = tray;
    await tray.init();
    if (!mounted) return;
    final config = ref.read(apiProvider).getConfig();
    final arguments = ref.read(startupArgumentsProvider);
    if (arguments.contains('--tray-panel')) {
      await tray.showPanel();
    } else if (config.startMinimized || arguments.contains('--minimized')) {
      await windowManager.hide();
    }
  }

  @override
  void onWindowFocus() {
    if (Platform.isWindows) unawaited(_refreshMaterialSignals());
  }

  @override
  void onWindowMaximize() => _presentation?.noteMaximized(true);

  @override
  void onWindowUnmaximize() => _presentation?.noteMaximized(false);

  Future<void> _refreshMaterialSignals() async {
    if (!mounted || _readingMaterialSignals) return;
    _readingMaterialSignals = true;
    try {
      final next = await _WindowsMaterialSignals.read();
      if (!mounted) return;
      if (next.reduceTransparency != _materialSignals.reduceTransparency ||
          next.highContrast != _materialSignals.highContrast) {
        setState(() => _materialSignals = next);
      }
    } finally {
      _readingMaterialSignals = false;
    }
  }

  @override
  void dispose() {
    _materialSignalTimer?.cancel();
    _tray?.dispose();
    _presentation?.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (ref.read(trayPanelVisibleProvider)) {
      await _tray?.dismissPanel();
      return;
    }
    final config = ref.read(apiProvider).getConfig();
    if (config.minimizeToTray) {
      await windowManager.hide();
    } else {
      ref.read(trayExitProvider.notifier).requestExit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final dark = ref.watch(themeModeProvider);
    final font = ref.watch(fontProvider);
    final background = ref.watch(backgroundProvider);
    final appearance = ref.watch(materialAppearanceProvider);
    final panelVisible = ref.watch(trayPanelVisibleProvider);
    final presentation = ref.watch(windowPresentationProvider);
    final immersive = ref.watch(immersiveWindowProvider);

    ref.listen(trayExitProvider, (prev, next) {
      if (next) exit(0);
    });

    return MaterialApp.router(
      title: 'TimeTrace',
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(fontFamily: font.family),
      darkTheme: TimetraceTheme.dark(fontFamily: font.family),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      routerConfig: router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final imagePath = background.imagePath;
        // A positive framework signal wins. False does not override a native
        // enabled/unknown value on platforms without framework support.
        final signals = _materialSignals.includingFrameworkHighContrast(
          media.highContrast,
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : media.size.width;
            final height = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : media.size.height;

            // Preserve the environment and router child's identity across
            // signal refreshes, image completion and continuous window resize.
            // WallpaperEnvironment resolves MaterialPolicy and owns the only
            // outer blur/work surface. No extra scroll axis is introduced.
            return SizedBox(
              width: width,
              height: height,
              child: WallpaperEnvironment(
                wallpaper: imagePath == null
                    ? null
                    : FileImage(File(imagePath)),
                backgroundColor: background.color,
                backgroundOpacity: background.opacity,
                appearance: appearance,
                signals: signals,
                availableWidth: width,
                child: WindowPresentationFrame(
                  presentation: presentation,
                  immersive: immersive,
                  panelVisible: panelVisible,
                  child: Stack(
                  children: [
                    Offstage(
                      offstage: panelVisible,
                      child: child ?? const SizedBox.shrink(),
                    ),
                    if (panelVisible && _tray != null)
                      Positioned.fill(
                        child: TrayPanel(
                          onOpenWorkspace: _tray!.openWorkspace,
                          onSettings: _tray!.openSettings,
                          onTogglePaused: _tray!.togglePaused,
                          onDismiss: _tray!.dismissPanel,
                        ),
                      ),
                  ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Reads only the two current-user preferences verified by the host.
/// Results stay in memory: no app configuration, logging or upload writes.
/// Missing keys, unexpected types/values and process failures stay unknown.
class _WindowsMaterialSignals {
  static Future<MaterialSignals> read() async {
    if (!Platform.isWindows) return const MaterialSignals();
    final values = await Future.wait<int?>([
      _readValue(
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
        'EnableTransparency',
        'REG_DWORD',
      ),
      _readValue(
        r'HKCU\Control Panel\Accessibility\HighContrast',
        'Flags',
        'REG_SZ',
      ),
    ]);
    final transparency = values[0];
    final contrastFlags = values[1];
    return MaterialSignals(
      reduceTransparency: switch (transparency) {
        0 => AccessibilitySignal.enabled,
        1 => AccessibilitySignal.disabled,
        _ => AccessibilitySignal.unknown,
      },
      // HCF_HIGHCONTRASTON is bit 0; other flags describe other capabilities.
      highContrast: contrastFlags == null
          ? AccessibilitySignal.unknown
          : (contrastFlags & 1) != 0
          ? AccessibilitySignal.enabled
          : AccessibilitySignal.disabled,
    );
  }

  static Future<int?> _readValue(String key, String name, String type) async {
    final systemRoot = Platform.environment['SystemRoot'];
    if (systemRoot == null || systemRoot.isEmpty) return null;
    Process? process;
    try {
      // Absolute system executable, fixed arguments and no command shell.
      process = await Process.start('$systemRoot\\System32\\reg.exe', [
        'query',
        key,
        '/v',
        name,
      ], runInShell: false);
      final output = process.stdout.transform(systemEncoding.decoder).join();
      final errors = process.stderr.drain<void>();
      final results = await Future.wait<dynamic>([
        process.exitCode,
        output,
        errors,
      ]).timeout(const Duration(seconds: 3));
      if (results[0] != 0) return null;
      final pattern = RegExp(
        '^\\s*${RegExp.escape(name)}\\s+${RegExp.escape(type)}'
        r'\s+(0x[0-9a-f]+|[0-9]+)\s*$',
        caseSensitive: false,
        multiLine: true,
      );
      final matches = pattern.allMatches(results[1] as String).toList();
      if (matches.length != 1) return null;
      final text = matches.single.group(1)!;
      final value = text.toLowerCase().startsWith('0x')
          ? int.tryParse(text.substring(2), radix: 16)
          : int.tryParse(text, radix: 10);
      if (value == null || value < 0 || value > 0xffffffff) return null;
      return value;
    } catch (_) {
      return null;
    } finally {
      // Also terminate a query that exceeded its deadline; do not accumulate
      // stalled registry readers across periodic refreshes.
      process?.kill();
    }
  }
}
