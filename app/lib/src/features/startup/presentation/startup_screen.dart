import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/features/startup/providers/startup_provider.dart';
import 'package:timetrace_app/src/features/startup/presentation/widgets/startup_tile.dart';

class StartupScreen extends ConsumerWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncEntries = ref.watch(startupProvider);
    final enabled = ref.watch(startupEnabledCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: asyncEntries.maybeWhen(
          data: (entries) =>
              Text('自启动 (${entries.length}项, $enabled启用)'),
          orElse: () => const Text('自启动'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(startupProvider),
            tooltip: '重新扫描',
          ),
        ],
      ),
      body: asyncEntries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (entries) => ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: entries.length,
          itemBuilder: (context, i) => StartupTile(
            entry: entries[i],
            onToggle: (enable) =>
                ref.read(startupProvider.notifier).toggle(entries[i], enable),
          ),
        ),
      ),
    );
  }
}
