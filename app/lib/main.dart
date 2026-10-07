import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:timetrace_app/src/bridge/frb_generated.dart' as frb;
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();
  try {
    AppLogger.log('initializing Rust bridge');
    await frb.RustLib.init(
      externalLibrary: ExternalLibrary.open('timetrace_bridge.dll'),
    );
    final dbDir = '${Platform.environment['APPDATA'] ?? '.'}\\TimeTrace';
    initializeApi(dbPath: '$dbDir\\time.db');
    AppLogger.log('TimeTraceApi initialized');
  } catch (e, st) {
    AppLogger.log('STARTUP FAILED: $e\n$st');
    runApp(_StartupFailureApp(message: e.toString()));
    return;
  }
  runApp(
    ProviderScope(
      overrides: [
        startupArgumentsProvider.overrideWithValue(
          List.unmodifiable(arguments),
        ),
      ],
      child: const TimetraceApp(),
    ),
  );
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF537A68),
          brightness: Brightness.light,
        ),
        fontFamily: 'Segoe UI',
      ),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 36),
                  const SizedBox(height: 16),
                  const Text(
                    'TimeTrace 启动失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '桌面组件没有正确加载。请关闭窗口后重新启动；若问题持续，请查看 TimeTrace/app.log。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
