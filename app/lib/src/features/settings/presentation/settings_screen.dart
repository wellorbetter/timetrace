import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
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

            // ── 字体 ──
            _SectionHeader(
                title: l.font, icon: Icons.font_download_outlined),
            ..._fontPicker(ref, l, context),
            const Divider(),

            // ── 背景 ──
            _SectionHeader(
                title: l.background, icon: Icons.wallpaper_outlined),
            ..._backgroundPicker(context, ref, l),
            const Divider(),

            // ── 仪表盘顺序 ──
            _SectionHeader(title: '仪表盘顺序', icon: Icons.view_carousel_outlined),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('调整概览轮播的展示顺序',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline)),
            ),
            ..._dashboardOrderPicker(ref),
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
              description: '多久检测一次当前前台应用（越小越精确，越费电）',
              help: '检测间隔：多久检测一次当前前台应用。越小越精确，也越耗电；修改后重启应用生效。',
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
              description: '键盘/鼠标停止操作多久后视为离开，暂停计时',
              help: '空闲阈值：键盘/鼠标停止操作多久后视为离开并暂停计时。锁屏/屏幕保护/待机会立即暂停，不受此阈值影响。',
              onChanged: (v) => _update(
                ref,
                settings.copyWith(idleThresholdMinutes: v),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l.appliesOnRestart,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline),
              ),
            ),
            const Divider(),
            const _PauseRecordTile(),
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

  /// Font picker with live previews.
  List<Widget> _fontPicker(WidgetRef ref, L10n l, BuildContext context) {
    final selected = ref.watch(fontProvider);
    return [
      for (final font in AppFont.all)
        RadioListTile<AppFont>(
          value: font,
          groupValue: selected,
          onChanged: (v) {
            if (v != null) ref.read(fontProvider.notifier).select(v);
          },
          title: Text(
            font.name,
            style: TextStyle(fontFamily: font.family),
          ),
          subtitle: Text(
            font.preview,
            style: TextStyle(
                fontFamily: font.family,
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          dense: true,
          secondary: Text(
            'Aa',
            style: TextStyle(
                fontFamily: font.family,
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
        ),
    ];
  }

  /// Background picker: preset colors + image + clear.
  List<Widget> _backgroundPicker(BuildContext context, WidgetRef ref, L10n l) {
    final pref = ref.watch(backgroundProvider);
    const colors = <Color?>[
      null,
      Color(0xFFF7F3FF),
      Color(0xFFE8F4FD),
      Color(0xFFFDF2E9),
      Color(0xFFF0F7EC),
      Color(0xFF1A1A2E),
    ];
    return [
      // Preset color swatches
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final c in colors)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  onTap: () =>
                      ref.read(backgroundProvider.notifier).setColor(c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c ?? Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: pref.color == c
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                        width: pref.color == c ? 3 : 1,
                      ),
                    ),
                    child: c == null
                        ? Icon(Icons.close,
                            size: 16,
                            color: Theme.of(context).colorScheme.outline)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
      ListTile(
        leading: const Icon(Icons.image_outlined),
        title: Text(l.backgroundImage),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => ref.read(backgroundProvider.notifier).pickImage(),
      ),
      if (pref.isImage || pref.color != null)
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: Text(l.clear,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () => ref.read(backgroundProvider.notifier).clear(),
        ),
    ];
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
    this.description,
    this.help,
  });

  final String label;
  final T value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final String? description;
  final String? help;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(label)),
          if (help != null) ...[
            const SizedBox(width: 4),
            HelpIcon(message: help!, size: 13),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: (value as num).toDouble().clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: (v) => onChanged(v as T),
          ),
          if (description != null)
            Text(description!,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline)),
        ],
      ),
      trailing: SizedBox(
        width: 70,
        child: Text(display, textAlign: TextAlign.right),
      ),
    );
  }
}

/// 暂停记录开关：直接调用 bridge 暂停/恢复后台监控（不写配置，立即生效）。
class _PauseRecordTile extends ConsumerStatefulWidget {
  const _PauseRecordTile();

  @override
  ConsumerState<_PauseRecordTile> createState() => _PauseRecordTileState();
}

class _PauseRecordTileState extends ConsumerState<_PauseRecordTile> {
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    try {
      _paused = ref.read(apiProvider).isTrackingPaused();
    } catch (e) {
      AppLogger.log('read pause state failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.pause_circle_outline),
      title: Row(
        children: [
          const Flexible(child: Text('暂停记录')),
          const SizedBox(width: 4),
          HelpIcon(
            message: '开启后暂停记录任何活跃时长（锁屏/待机本身也会自动暂停计时）。适合需要完全离线休息的场景。',
            size: 13,
          ),
        ],
      ),
      subtitle: const Text('暂停后不再记录活跃时长，适合休息/离线场景'),
      trailing: Switch(
        value: _paused,
        onChanged: (v) {
          try {
            ref.read(apiProvider).setTrackingPaused(paused: v);
          } catch (e) {
            AppLogger.log('setTrackingPaused failed: $e');
          }
          setState(() => _paused = v);
        },
      ),
    );
  }
}


/// Reorderable list of carousel views (up/down arrows, persisted).
List<Widget> _dashboardOrderPicker(WidgetRef ref) {
  final order = ref.watch(dashboardOrderProvider);
  final notifier = ref.read(dashboardOrderProvider.notifier);
  return [
    for (var i = 0; i < order.length; i++)
      Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          dense: true,
          leading: Icon(
            switch (order[i]) {
              'bar' => Icons.bar_chart,
              'pie' => Icons.pie_chart_outline,
              'summary' => Icons.summarize_outlined,
              'apps' => Icons.apps,
              _ => Icons.dashboard_outlined,
            },
          ),
          title: Text(kViews[order[i]] ?? order[i],
              style: const TextStyle(fontSize: 13)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                tooltip: '上移',
                visualDensity: VisualDensity.compact,
                onPressed: i > 0 ? () => notifier.move(i, i - 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                tooltip: '下移',
                visualDensity: VisualDensity.compact,
                onPressed: i < order.length - 1
                    ? () => notifier.move(i, i + 1)
                    : null,
              ),
            ],
          ),
        ),
      ),
  ];
}
