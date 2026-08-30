import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';
import 'package:timetrace_app/src/core/platform_paths.dart';
import 'package:timetrace_app/src/core/theme/background_provider.dart';
import 'package:timetrace_app/src/core/theme/font_provider.dart';
import 'package:timetrace_app/src/core/theme/theme_provider.dart';
import 'package:timetrace_app/src/core/theme/timetrace_tokens.dart';
import 'package:timetrace_app/src/core/widgets/app_icon.dart';
import 'package:timetrace_app/src/core/widgets/m3_widgets.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_order_provider.dart';
import 'package:timetrace_app/src/features/dashboard/providers/dashboard_provider.dart';
import 'package:timetrace_app/src/features/settings/domain/settings.dart';
import 'package:timetrace_app/src/features/settings/providers/settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = L10n(ref.watch(localeProvider));
    final dark = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final asyncSettings = ref.watch(settingsProvider);
    final backgroundArea = Platform.isMacOS ? '菜单栏' : '系统托盘';

    return Scaffold(
      appBar: AppBar(title: Text(l.settings)),
      body: LayoutBuilder(
        builder: (context, constraints) => asyncSettings.when(
          loading: () => const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Center(child: Text('加载失败: $e')),
          data: (settings) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: TimeTraceLayout.readingWidth,
              ),
              child: ListView(
                padding: TimeTraceLayout.pagePadding(constraints.maxWidth),
                children: [
                  _SettingsGroup(
                    icon: Icons.tune_rounded,
                    title: '外观与偏好',
                    subtitle: '控制主题、语言、字体和背景。',
                    children: [
                      _SettingsControlRow(
                        title: l.theme,
                        subtitle: '保持界面在不同环境下舒适易读。',
                        control: SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment<bool>(
                              value: false,
                              icon: const Icon(Icons.light_mode_outlined),
                              label: Text(l.lightMode),
                            ),
                            ButtonSegment<bool>(
                              value: true,
                              icon: const Icon(Icons.dark_mode_outlined),
                              label: Text(l.darkMode),
                            ),
                          ],
                          selected: {dark},
                          onSelectionChanged: (values) => ref
                              .read(themeModeProvider.notifier)
                              .set(values.first),
                        ),
                      ),
                      const _GroupDivider(),
                      _SettingsControlRow(
                        title: l.language,
                        subtitle: '切换界面显示语言。',
                        control: SegmentedButton<AppLocale>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment<AppLocale>(
                              value: AppLocale.zh,
                              label: Text('中文'),
                            ),
                            ButtonSegment<AppLocale>(
                              value: AppLocale.en,
                              label: Text('English'),
                            ),
                          ],
                          selected: {locale},
                          onSelectionChanged: (values) => ref
                              .read(localeProvider.notifier)
                              .set(values.first),
                        ),
                      ),
                      const _GroupDivider(),
                      _SettingsControlRow(
                        title: l.font,
                        subtitle: '优先使用当前平台原生字体，保持桌面感。',
                        control: _fontPicker(ref, context),
                      ),
                      const _GroupDivider(),
                      _SettingsBlock(
                        title: l.background,
                        subtitle: '使用低饱和背景，或选择自己的图片。',
                        child: _backgroundPicker(context, ref, l),
                      ),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  _SettingsGroup(
                    icon: Icons.view_carousel_outlined,
                    title: '概览布局',
                    subtitle: '调整数据视图在概览轮播中的顺序。',
                    children: [_dashboardOrderPicker(ref)],
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  _SettingsGroup(
                    icon: Icons.monitor_heart_outlined,
                    title: l.monitoring,
                    subtitle: '控制记录精度、后台行为和隐私边界。',
                    children: [
                      _SliderSetting<int>(
                        label: l.pollInterval,
                        value: settings.pollIntervalMs,
                        min: 500,
                        max: 5000,
                        divisions: 9,
                        display:
                            '${(settings.pollIntervalMs / 1000).toStringAsFixed(1)} ${l.seconds}',
                        description: '多久检测一次当前前台应用。越短越精确，也会增加少量开销。',
                        help: '修改后重启应用生效。',
                        onChanged: (v) => _update(
                          ref,
                          settings.copyWith(pollIntervalMs: v),
                        ),
                      ),
                      const _GroupDivider(),
                      _SliderSetting<int>(
                        label: l.idleThreshold,
                        value: settings.idleThresholdMinutes,
                        min: 1,
                        max: 60,
                        divisions: 59,
                        display: '${settings.idleThresholdMinutes} ${l.minutes}',
                        description: '键盘或鼠标停止操作多久后视为离开并暂停计时。',
                        help: '锁屏、屏幕保护或待机会立即暂停，不受此阈值影响。',
                        onChanged: (v) => _update(
                          ref,
                          settings.copyWith(idleThresholdMinutes: v),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          TimeTraceSpace.sm,
                          0,
                          TimeTraceSpace.sm,
                          TimeTraceSpace.xs,
                        ),
                        child: Text(
                          l.appliesOnRestart,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const _GroupDivider(),
                      _SettingsToggleRow(
                        title: '关闭窗口时隐藏到$backgroundArea',
                        subtitle: '主窗口关闭后继续在后台记录。',
                        value: settings.minimizeToTray,
                        onChanged: (value) => _update(
                          ref,
                          settings.copyWith(minimizeToTray: value),
                        ),
                      ),
                      const _GroupDivider(),
                      _SettingsToggleRow(
                        title: '启动时隐藏主窗口',
                        subtitle: '启动后只保留$backgroundArea入口。',
                        value: settings.startMinimized,
                        onChanged: (value) => _updateAndSave(
                          ref,
                          settings.copyWith(startMinimized: value),
                        ),
                      ),
                      const _GroupDivider(),
                      _SettingsToggleRow(
                        title: '启动后自动开始追踪',
                        subtitle: '再次启动 TimeTrace 时立即开始记录活动。',
                        value: settings.autoStartTracking,
                        onChanged: (value) => _update(
                          ref,
                          settings.copyWith(autoStartTracking: value),
                        ),
                      ),
                      const _GroupDivider(),
                      _SelfStartupTile(
                        startMinimized: settings.startMinimized,
                      ),
                      const _GroupDivider(),
                      ListTile(
                        leading: const Icon(Icons.block_outlined),
                        title: const Text('排除应用'),
                        subtitle: Text(
                          settings.excludedApps.isEmpty
                              ? '未配置排除项'
                              : settings.excludedApps.join('、'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () =>
                            _editExcludedApps(context, ref, settings),
                      ),
                      const _GroupDivider(),
                      const _PauseRecordTile(),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  _SettingsGroup(
                    icon: Icons.storage_outlined,
                    title: l.data,
                    subtitle: '查看本地存储位置，导出或清理记录。',
                    children: [
                      ListTile(
                        key: const ValueKey('data-location-tile'),
                        leading: const Icon(Icons.folder_outlined),
                        title: const Text('数据存储位置'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(_dbPath(settings)),
                            const SizedBox(height: TimeTraceSpace.xxs),
                            Text(
                              '选择文件夹后，下次启动将使用其中的 time.db；原数据库会保留。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        trailing: OutlinedButton.icon(
                          key: const ValueKey('choose-data-location'),
                          onPressed: () => _chooseDatabaseLocation(
                            context,
                            ref,
                            settings,
                          ),
                          icon: const Icon(Icons.folder_open_outlined, size: 17),
                          label: const Text('选择'),
                        ),
                      ),
                      const _GroupDivider(),
                      ListTile(
                        leading: const Icon(Icons.file_download_outlined),
                        title: Text(l.exportData),
                        subtitle: Text('CSV · ${l.appList}'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _exportCsv(context, ref, l),
                      ),
                      const _GroupDivider(),
                      ListTile(
                        leading: Icon(
                          Icons.delete_outline_rounded,
                          color: Theme.of(context).colorScheme.error,
                        ),
                        title: Text(
                          l.clearData,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                        subtitle: const Text('删除本机全部使用记录；此操作无法撤销。'),
                        onTap: () => _confirmClear(context, ref, l),
                      ),
                    ],
                  ),
                  const SizedBox(height: TimeTraceSpace.lg),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'TimeTrace v1.0.1 · Rust + Flutter · MIT',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: () async {
                          await ref.read(settingsProvider.notifier).save();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(l.saved)),
                            );
                          }
                        },
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: Text(l.save),
                      ),
                    ],
                  ),
                ],
              ),
            ),
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
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ExcludedAppsDialog(initial: settings.excludedApps),
    );
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

  Widget _fontPicker(WidgetRef ref, BuildContext context) {
    final selected = ref.watch(fontProvider);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: DropdownButton<AppFont>(
        value: selected,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(TimeTraceRadius.control),
        items: [
          for (final font in AppFont.all)
            DropdownMenuItem<AppFont>(
              value: font,
              child: Text(
                font.name,
                style: TextStyle(fontFamily: font.family),
              ),
            ),
        ],
        onChanged: (font) {
          if (font != null) ref.read(fontProvider.notifier).select(font);
        },
      ),
    );
  }

  Widget _backgroundPicker(BuildContext context, WidgetRef ref, L10n l) {
    final pref = ref.watch(backgroundProvider);
    const colors = <Color?>[
      null,
      Color(0xFFF1EFE8),
      Color(0xFFE4ECE6),
      Color(0xFFECE8DF),
      Color(0xFFE8ECE9),
      Color(0xFF252724),
    ];
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: TimeTraceSpace.xs,
          runSpacing: TimeTraceSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final color in colors)
              Tooltip(
                message: color == null ? '默认背景' : '背景颜色',
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () =>
                      ref.read(backgroundProvider.notifier).setColor(color),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: color ?? scheme.surface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: pref.color == color
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: pref.color == color ? 2 : 1,
                      ),
                    ),
                    child: color == null
                        ? Icon(
                            Icons.restart_alt_rounded,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          )
                        : null,
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () =>
                  ref.read(backgroundProvider.notifier).pickImage(),
              icon: const Icon(Icons.image_outlined, size: 17),
              label: Text(l.backgroundImage),
            ),
            if (pref.isImage || pref.color != null)
              TextButton.icon(
                onPressed: () => ref.read(backgroundProvider.notifier).clear(),
                icon: const Icon(Icons.close_rounded, size: 17),
                label: Text(l.clear),
              ),
          ],
        ),
        if (pref.isImage || pref.color != null) ...[
          const SizedBox(height: TimeTraceSpace.xs),
          Row(
            children: [
              Text('背景强度', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: TimeTraceSpace.sm),
              Expanded(
                child: Slider(
                  value: pref.opacity,
                  min: 0.15,
                  max: 1,
                  divisions: 17,
                  label: '${(pref.opacity * 100).round()}%',
                  onChanged: (value) => ref
                      .read(backgroundProvider.notifier)
                      .setOpacity(value),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${(pref.opacity * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _dbPath(AppSettings settings) =>
      settings.dbPath.isNotEmpty ? settings.dbPath : PlatformPaths.database;

  Future<void> _chooseDatabaseLocation(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final current = File(_dbPath(settings));
    final directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择 TimeTrace 数据存储文件夹',
      initialDirectory: current.parent.path,
      lockParentWindow: true,
    );
    if (directory == null || !context.mounted) return;

    final selected = Directory(directory);
    final target = File(
      '$directory${Platform.pathSeparator}time.db',
    ).absolute.path;
    if (target == current.absolute.path) return;

    try {
      final probe = File(
        '$directory${Platform.pathSeparator}.timetrace-write-check',
      );
      await selected.create(recursive: true);
      await probe.writeAsString('TimeTrace');
      await probe.delete();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('所选文件夹不可写，请选择其他位置。')),
      );
      return;
    }

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更改数据存储位置？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('新位置将在下次启动 TimeTrace 时生效。'),
            const SizedBox(height: TimeTraceSpace.sm),
            SelectableText(target),
            const SizedBox(height: TimeTraceSpace.sm),
            Text(
              '现有数据不会自动搬移或删除；需要继续使用旧记录时，请先复制原来的 time.db。',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('使用此位置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final notifier = ref.read(settingsProvider.notifier);
    notifier.preview(settings.copyWith(dbPath: target));
    await notifier.save();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('数据位置已保存，重启 TimeTrace 后生效。')),
    );
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
    BuildContext context,
    WidgetRef ref,
    L10n l,
  ) async {
    final path = PlatformPaths.csvExport;
    try {
      PlatformPaths.ensureDirectory();
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${l.exportData} ${l.cancel}')),
        );
      }
    }
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 17, color: scheme.primary),
            const SizedBox(width: TimeTraceSpace.xs),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: TimeTraceSpace.xxs),
        Text(subtitle, style: theme.textTheme.bodySmall),
        const SizedBox(height: TimeTraceSpace.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(TimeTraceSpace.xxs),
            child: Column(children: children),
          ),
        ),
      ],
    );
  }
}

class _SettingsControlRow extends StatelessWidget {
  const _SettingsControlRow({
    required this.title,
    required this.subtitle,
    required this.control,
  });

  final String title;
  final String subtitle;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final label = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: TimeTraceSpace.sm),
                Align(alignment: Alignment.centerLeft, child: control),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: label),
              const SizedBox(width: TimeTraceSpace.lg),
              Flexible(child: control),
            ],
          );
        },
      ),
    );
  }
}

class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: TimeTraceSpace.sm),
          child,
        ],
      ),
    );
  }
}

class _SettingsToggleRow extends StatelessWidget {
  const _SettingsToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: TimeTraceSpace.sm,
        vertical: TimeTraceSpace.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: TimeTraceSpace.md),
          Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      indent: TimeTraceSpace.sm,
      endIndent: TimeTraceSpace.sm,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _SliderSetting<T> extends StatelessWidget {
  const _SliderSetting({
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
    return Padding(
      padding: const EdgeInsets.all(TimeTraceSpace.sm),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            label,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (help != null) ...[
                          const SizedBox(width: TimeTraceSpace.xxs),
                          HelpIcon(message: help!, size: 13),
                        ],
                      ],
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: TimeTraceSpace.sm),
              Text(
                display,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: (value as num).toDouble().clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: (next) => onChanged(
              value is int ? next.round() as T : next as T,
            ),
          ),
        ],
      ),
    );
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
    return _SettingsToggleRow(
      title: '开机启动',
      subtitle: '使用当前用户级启动项，不需要管理员权限。',
      value: _enabled ?? false,
      enabled: !_busy && _enabled != null,
      onChanged: _toggle,
    );
  }
}

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
    return _SettingsToggleRow(
      title: '暂停记录',
      subtitle: '临时停止记录活跃时长，适合休息或隐私场景。',
      value: _paused,
      onChanged: (value) {
        try {
          ref.read(apiProvider).setTrackingPaused(paused: value);
          setState(() => _paused = value);
        } catch (e) {
          AppLogger.log('setTrackingPaused failed: $e');
        }
      },
    );
  }
}

Widget _dashboardOrderPicker(WidgetRef ref) {
  final order = ref.watch(dashboardOrderProvider);
  final notifier = ref.read(dashboardOrderProvider.notifier);
  return Column(
    children: [
      for (var i = 0; i < order.length; i++) ...[
        ListTile(
          leading: Icon(
            switch (order[i]) {
              'bar' => Icons.bar_chart_rounded,
              'pie' => Icons.donut_large_rounded,
              'hourly' => Icons.schedule_rounded,
              'summary' => Icons.summarize_outlined,
              'apps' => Icons.apps_rounded,
              _ => Icons.dashboard_outlined,
            },
          ),
          title: Text(kViews[order[i]] ?? order[i]),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up_rounded),
                tooltip: '上移',
                onPressed: i > 0 ? () => notifier.move(i, i - 1) : null,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                tooltip: '下移',
                onPressed: i < order.length - 1
                    ? () => notifier.move(i, i + 1)
                    : null,
              ),
            ],
          ),
        ),
        if (i < order.length - 1) const _GroupDivider(),
      ],
    ],
  );
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
      final entries = Platform.isWindows
          ? await _loadWindowsProcesses()
          : Platform.isMacOS
              ? await _loadMacProcesses()
              : <_ProcessEntry>[];
      if (!mounted) return;
      setState(() {
        _processes = entries..sort((a, b) => a.name.compareTo(b.name));
        _loading = false;
      });
    } catch (e) {
      AppLogger.log('load process catalog failed: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<_ProcessEntry>> _loadWindowsProcesses() async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Get-Process | Where-Object { $_.Path } | Select-Object ProcessName,Path | ConvertTo-Csv -NoTypeInformation',
    ]);
    final entries = <String, _ProcessEntry>{};
    for (final line in result.stdout.toString().split(RegExp(r'\r?\n')).skip(1)) {
      final match = RegExp(r'^"([^"]+)","(.*)"$').firstMatch(line.trim());
      if (match == null) continue;
      final name = '${match.group(1)}.exe';
      entries[name.toLowerCase()] = _ProcessEntry(name, match.group(2)!);
    }
    return entries.values.toList();
  }

  Future<List<_ProcessEntry>> _loadMacProcesses() async {
    final result = await Process.run('/bin/ps', ['-axo', 'comm=']);
    final entries = <String, _ProcessEntry>{};
    for (final raw in result.stdout.toString().split('\n')) {
      final path = raw.trim();
      if (path.isEmpty || !path.startsWith('/')) continue;
      final name = path.split('/').last;
      if (name.isEmpty) continue;
      entries[name.toLowerCase()] = _ProcessEntry(name, path);
    }
    return entries.values.toList();
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final hint = Platform.isWindows ? '例如：Code.exe' : '例如：Code 或 Safari';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动添加'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    final name = value?.trim();
    if (name != null && name.isNotEmpty) {
      setState(() => _selected.add(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _filter.text.toLowerCase();
    final visible = _processes
        .where((p) => p.name.toLowerCase().contains(query))
        .toList();
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
                prefixIcon: Icon(Icons.search_rounded),
                hintText: '搜索正在运行的应用',
              ),
            ),
            const SizedBox(height: TimeTraceSpace.xs),
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
                              secondary: AppIcon(
                                exePath: process.path,
                                size: 28,
                              ),
                              title: Text(name),
                              subtitle: Text(
                                process.path,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
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
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('手动添加其他程序'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ProcessEntry {
  const _ProcessEntry(this.name, this.path);

  final String name;
  final String path;
}
