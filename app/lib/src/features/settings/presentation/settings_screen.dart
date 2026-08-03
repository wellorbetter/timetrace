import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(ref.watch(localeProvider));
    final dark = ref.watch(themeModeProvider);
    final asyncSettings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: asyncSettings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (settings) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── 主题 ──
            _SectionHeader(title: l.theme, icon: Icons.palette_outlined),
            ListTile(
              leading: const Icon(Icons.light_mode_outlined),
              title: Text(l.lightMode),
              trailing: Radio<bool>(
                value: false,
                groupValue: dark,
                onChanged: (v) =>
                    ref.read(themeModeProvider.notifier).set(v ?? false),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: Text(l.darkMode),
              trailing: Radio<bool>(
                value: true,
                groupValue: dark,
                onChanged: (v) =>
                    ref.read(themeModeProvider.notifier).set(v ?? false),
              ),
            ),
            const Divider(),

            // ── 语言 ──
            _SectionHeader(title: l.language, icon: Icons.translate),
            ListTile(
              leading: const Text('中', style: TextStyle(fontWeight: FontWeight.bold)),
              title: const Text('中文'),
              trailing: Radio<AppLocale>(
                value: AppLocale.zh,
                groupValue: ref.watch(localeProvider),
                onChanged: (v) =>
                    ref.read(localeProvider.notifier).set(v ?? AppLocale.zh),
              ),
            ),
            ListTile(
              leading: const Text('EN', style: TextStyle(fontWeight: FontWeight.bold)),
              title: const Text('English'),
              trailing: Radio<AppLocale>(
                value: AppLocale.en,
                groupValue: ref.watch(localeProvider),
                onChanged: (v) =>
                    ref.read(localeProvider.notifier).set(v ?? AppLocale.zh),
              ),
            ),
            const Divider(),

            // ── 监控 ──
            _SectionHeader(title: l.monitoring, icon: Icons.monitor_heart_outlined),
            _SliderTile<int>(
              label: l.pollInterval,
              value: settings.pollIntervalMs,
              min: 500,
              max: 5000,
              divisions: 9,
              display: '${settings.pollIntervalMs} ${l.seconds}',
              onChanged: (v) => _update(
                ref,
                settings.copyWith(pollIntervalMs: v),
              ),
            ),
            _SliderTile<int>(
              label: l.idleThreshold,
              value: settings.idleThresholdMinutes,
              min: 1,
              max: 60,
              divisions: 59,
              display: '${settings.idleThresholdMinutes} ${l.minutes}',
              onChanged: (v) => _update(
                ref,
                settings.copyWith(idleThresholdMinutes: v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l.appliesOnRestart,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
            const Divider(),

            // ── 数据 ──
            _SectionHeader(title: l.data, icon: Icons.storage_outlined),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(l.recordingSince),
              subtitle: Text(_dbPath(settings)),
            ),
            // Export CSV
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: Text(l.exportData),
              subtitle: Text('CSV — ${l.appList}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _exportCsv(context, ref, l),
            ),
            // Clear data
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text(l.clearData,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () => _confirmClear(context, ref, l),
            ),
            const Divider(),

            // ── 保存 ──
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FilledButton.icon(
                onPressed: () async {
                  await ref.read(settingsProvider.notifier).save();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.saved)),
                    );
                  }
                },
                icon: const Icon(Icons.save_outlined),
                label: Text(l.save),
              ),
            ),
            const SizedBox(height: 16),

            // ── 关于 ──
            _SectionHeader(title: l.about, icon: Icons.info_outline),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('TimeTrace v0.2.0 · Rust + Flutter · MIT'),
            ),
          ],
        ),
      ),
    );
  }

  void _update(WidgetRef ref, AppSettings next) {
    ref.read(settingsProvider.notifier).preview(next);
  }

  String _dbPath(AppSettings s) {
    if (s.dbPath.isNotEmpty) return s.dbPath;
    return 'AppData/Local/TimeTrace/time.db';
  }

  void _confirmClear(BuildContext context, WidgetRef ref, L10n l) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.clearData),
        content: Text(l.clearDataConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              try {
                ref.read(apiProvider).clearData();
                ref.invalidate(settingsProvider);
                ref.invalidate(dashboardProvider);
                AppLogger.log('data cleared via settings');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.saved)),
                );
              } catch (e) {
                AppLogger.log('clear data failed: $e');
              }
            },
            child: Text(l.confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(
      BuildContext context, WidgetRef ref, L10n l) async {
    final dir = Platform.environment['APPDATA'] ?? '.';
    final path = '$dir\\TimeTrace\\export.csv';
    try {
      final now = DateTime.now();
      final start =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final end =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final csv = ref.read(apiProvider).exportCsv(start: start, end: end);
      File(path).writeAsStringSync(csv);
      AppLogger.log('exported CSV to $path');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.exportData}: $path')),
        );
      }
    } catch (e) {
      AppLogger.log('export failed: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${l.exportData} ${l.cancel}')));
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _SliderTile<T> extends StatelessWidget {
  const _SliderTile({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final T value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        value: (value as num).toDouble().clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: display,
        onChanged: (v) => onChanged(v as T),
      ),
      trailing: SizedBox(
        width: 70,
        child: Text(display, textAlign: TextAlign.right),
      ),
    );
  }
}
