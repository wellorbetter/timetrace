import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/presentation/ai_recap_settings_section.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';
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
        data: (settings) => ListTileTheme(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          minVerticalPadding: 2,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
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
              display: '${(settings.pollIntervalMs / 1000).toStringAsFixed(1)} ${l.seconds}',
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
            SwitchListTile(
              title: const Row(children: [
                Text('关闭窗口时最小化到托盘'),
                SizedBox(width: 6),
                HelpIcon(message: '关闭窗口后隐藏到系统托盘，后台继续记录。'),
              ]),
              value: settings.minimizeToTray,
              onChanged: (value) => _update(
                ref,
                settings.copyWith(minimizeToTray: value),
              ),
            ),
            SwitchListTile(
              title: const Row(children: [
                Text('启动时最小化'),
                SizedBox(width: 6),
                HelpIcon(message: '应用启动后隐藏主窗口，只保留托盘图标。'),
              ]),
              value: settings.startMinimized,
              onChanged: (value) => _updateAndSave(
                ref,
                settings.copyWith(startMinimized: value),
              ),
            ),
            SwitchListTile(
              title: const Row(children: [
                Text('启动后自动开始追踪'),
                SizedBox(width: 6),
                HelpIcon(message: '关闭后再次启动应用时，是否立即记录活动。'),
              ]),
              value: settings.autoStartTracking,
              onChanged: (value) => _update(
                ref,
                settings.copyWith(autoStartTracking: value),
              ),
            ),
            _SelfStartupTile(startMinimized: settings.startMinimized),
            ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('排除应用'),
              subtitle: Text(settings.excludedApps.isEmpty
                  ? '未配置'
                  : settings.excludedApps.join('、')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editExcludedApps(context, ref, settings),
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

            // ── AI 服务 ──
            const AiRecapSettingsSection(),
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
              child: Text('TimeTrace v1.0.1 · Rust + Flutter · MIT'),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editExcludedApps(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final controller = TextEditingController(
      text: settings.excludedApps.join('\n'),
    );
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ExcludedAppsDialog(initial: settings.excludedApps),
      /* AlertDialog(
        title: const Text('排除应用'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: '每行填写一个应用名或 exe 路径',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final apps = controller.text
                  .split(RegExp(r'[\r\n,，]+'))
                  .map((value) => value.trim())
                  .where((value) => value.isNotEmpty)
                  .toSet()
                  .toList();
              Navigator.pop(context, apps);
            },
            child: const Text('保存'),
          ),
        ],
      ),*/
    );
    controller.dispose();
    if (result != null) {
      final notifier = ref.read(settingsProvider.notifier);
      notifier.preview(settings.copyWith(excludedApps: result));
      await notifier.save();
    }
  }

  void _update(WidgetRef ref, AppSettings next) {
    ref.read(settingsProvider.notifier).preview(next);
  }

  Future<void> _updateAndSave(WidgetRef ref, AppSettings next) async {
    final notifier = ref.read(settingsProvider.notifier);
    notifier.preview(next);
    await notifier.save();
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
      Card(
        color: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Column(
            children: [
              Row(
                children: [
                  for (final c in colors)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => ref.read(backgroundProvider.notifier).setColor(c),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: c ?? Theme.of(context).colorScheme.surface,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: pref.color == c
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.outlineVariant,
                              width: pref.color == c ? 2.5 : 1,
                            ),
                          ),
                          child: c == null
                              ? Icon(Icons.close, size: 15,
                                  color: Theme.of(context).colorScheme.outline)
                              : null,
                        ),
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    tooltip: l.backgroundImage,
                    icon: const Icon(Icons.image_outlined),
                    onPressed: () => ref.read(backgroundProvider.notifier).pickImage(),
                  ),
                  if (pref.isImage || pref.color != null)
                    IconButton(
                      tooltip: l.clear,
                      icon: Icon(Icons.refresh, color: Theme.of(context).colorScheme.error),
                      onPressed: () => ref.read(backgroundProvider.notifier).clear(),
                    ),
                ],
              ),
              if (pref.isImage || pref.color != null)
                Row(
                  children: [
                    const Icon(Icons.opacity_outlined, size: 16),
                    Expanded(
                      child: Slider(
                        value: pref.opacity,
                        min: 0.15,
                        max: 1,
                        divisions: 17,
                        label: '${(pref.opacity * 100).round()}%',
                        onChanged: (v) => ref.read(backgroundProvider.notifier).setOpacity(v),
                      ),
                    ),
                    SizedBox(width: 38, child: Text('${(pref.opacity * 100).round()}%')),
                  ],
                ),
            ],
          ),
        ),
      ),
    ];
  }

  String _dbPath(AppSettings s) {
    if (s.dbPath.isNotEmpty) return s.dbPath;
    final appData = Platform.environment['APPDATA'];
    return appData == null ? 'AppData/Roaming/TimeTrace/time.db' : '$appData\\TimeTrace\\time.db';
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
                final cleared = ref.read(apiProvider).clearData();
                ref.invalidate(settingsProvider);
                ref.invalidate(dashboardProvider);
                // Invalidate cached UI state without forcing a first native AI
                // initialization when the feature has never been opened.
                ref.invalidate(aiRecapControllerProvider);
                if (cleared) {
                  AppLogger.log('data cleared via settings');
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.saved)),
                  );
                } else {
                  AppLogger.log('data clear incomplete: AI report storage');
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('使用记录已清除，但 AI 报告未能清除，请稍后重试。'),
                    ),
                  );
                }
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

class _SelfStartupTile extends ConsumerStatefulWidget {
  const _SelfStartupTile({required this.startMinimized});

  final bool startMinimized;

  @override
  ConsumerState<_SelfStartupTile> createState() => _SelfStartupTileState();
}

class _SelfStartupTileState extends ConsumerState<_SelfStartupTile> {
  bool? _enabled;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      setState(() => _enabled = ref.read(apiProvider).isSelfStartEnabled());
    } catch (e) {
      AppLogger.log('read self startup failed: $e');
    }
  }

  void _toggle(bool enabled) {
    setState(() => _busy = true);
    try {
      ref.read(apiProvider).setSelfStartEnabled(
            enabled: enabled,
            minimized: widget.startMinimized,
          );
      setState(() => _enabled = enabled);
    } catch (e) {
      AppLogger.log('set self startup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Row(children: [
        Text('开机启动'),
        SizedBox(width: 6),
        HelpIcon(message: '写入当前用户的启动项，不需要管理员权限。'),
      ]),
      value: _enabled ?? false,
      onChanged: _busy || _enabled == null ? null : _toggle,
    );
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
            onChanged: (v) => onChanged(
              value is int ? v.round() as T : v as T,
            ),
          ),
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
        color: Colors.transparent,
        elevation: 0,
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

class _ExcludedAppsDialog extends StatefulWidget {
  const _ExcludedAppsDialog({required this.initial});

  final List<String> initial;

  @override
  State<_ExcludedAppsDialog> createState() => _ExcludedAppsDialogState();
}

class _ExcludedAppsDialogState extends State<_ExcludedAppsDialog> {
  final _filter = TextEditingController();
  late final Set<String> _selected = widget.initial.toSet();
  List<_ProcessEntry> _processes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProcesses();
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _loadProcesses() async {
    try {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-Process | Where-Object { $_.Path } | Select-Object ProcessName,Path | ConvertTo-Csv -NoTypeInformation',
      ]);
      final entries = <String, _ProcessEntry>{};
      for (final line in result.stdout.toString().split(RegExp(r'\r?\n')).skip(1)) {
        final match = RegExp(r'^"([^"]+)","(.*)"$').firstMatch(line.trim());
        if (match != null) {
          final name = '${match.group(1)}.exe';
          entries[name.toLowerCase()] = _ProcessEntry(name, match.group(2)!);
        }
      }
      if (mounted) {
        setState(() {
          _processes = entries.values.toList()..sort((a, b) => a.name.compareTo(b.name));
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动添加'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：Code.exe'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('添加')),
        ],
      ),
    );
    controller.dispose();
    final name = value?.trim();
    if (name != null && name.isNotEmpty) setState(() => _selected.add(name));
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.toLowerCase();
    final visible = _processes.where((p) => p.name.toLowerCase().contains(query)).toList();
    return AlertDialog(
      title: const Text('排除应用'),
      content: SizedBox(
        width: 430,
        height: 430,
        child: Column(
          children: [
            TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索正在运行的应用',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                      ? const Center(child: Text('没有找到正在运行的应用'))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, index) {
                            final process = visible[index];
                            final name = process.name;
                            return CheckboxListTile(
                              dense: true,
                              value: _selected.contains(name),
                              secondary: AppIcon(exePath: process.path, size: 28),
                              title: Text(name),
                              onChanged: (checked) => setState(() {
                                if (checked == true) {
                                  _selected.add(name);
                                } else {
                                  _selected.remove(name);
                                }
                              }),
                            );
                          },
                        ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addManually,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('手动添加其他程序'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _selected.toList()), child: const Text('保存')),
      ],
    );
  }
}

class _ProcessEntry {
  const _ProcessEntry(this.name, this.path);

  final String name;
  final String path;
}
