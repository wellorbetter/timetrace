import 'package:flutter/material.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';

/// Minimal fallback UI shown when the native Rust backend cannot start.
/// Keeping this in Flutter makes bridge/load failures diagnosable instead of
/// terminating with an invisible desktop process crash.
class BootstrapFailureApp extends StatelessWidget {
  const BootstrapFailureApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TimetraceTheme.light(),
      darkTheme: TimetraceTheme.dark(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 28),
                    const SizedBox(height: 16),
                    Text(
                      'TimeTrace 无法启动',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Rust 后端初始化失败。详细信息已写入 app.log。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 14),
                    SelectableText(
                      message,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
