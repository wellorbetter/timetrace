import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/l10n.dart';
import 'package:timetrace_app/src/features/startup/providers/startup_provider.dart';
import 'package:timetrace_app/src/features/startup/presentation/widgets/startup_tile.dart';

enum _StartFilter { all, enabled, disabled }

class StartupScreen extends ConsumerStatefulWidget {
  const StartupScreen({super.key});

  @override
  ConsumerState<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends ConsumerState<StartupScreen> {
  _StartFilter _filter = _StartFilter.all;

  @override
  Widget build(BuildContext context) {
    final l = L10n(ref.watch(localeProvider));
    final asyncEntries = ref.watch(startupProvider);
    final enabled = ref.watch(startupEnabledCountProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: asyncEntries.maybeWhen(
          data: (entries) => Text(
              '${l.startup} (${entries.length}'
              '${l.locale == AppLocale.zh ? '项' : ' items'}, $enabled'
              '${l.locale == AppLocale.zh ? '启用' : ' enabled'})'),
          orElse: () => Text(l.startup),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(startupProvider),
            tooltip: l.locale == AppLocale.zh ? '重新扫描' : 'Rescan',
          ),
        ],
      ),
      body: asyncEntries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (entries) {
          final filtered = entries.where((e) => switch (_filter) {
                _StartFilter.all => true,
                _StartFilter.enabled => e.enabled,
                _StartFilter.disabled => !e.enabled,
              }).toList();

          // Group by source, preserving order
          final groups = <String, List<dynamic>>{};
          for (final e in filtered) {
            groups.putIfAbsent(e.source, () => []).add(e);
          }
          final sourceOrder = [
            'HKCU',
            'HKLM',
            'StartupFolder',
            'TaskScheduler',
          ];

          return Column(
            children: [
              // ── Filter chips ──
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    for (final (label, f) in [
                      (l.locale == AppLocale.zh ? '全部' : 'All', _StartFilter.all),
                      (l.locale == AppLocale.zh ? '启用' : 'Enabled', _StartFilter.enabled),
                      (l.locale == AppLocale.zh ? '禁用' : 'Disabled', _StartFilter.disabled),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(label, style: const TextStyle(fontSize: 13)),
                          selected: _filter == f,
                          onSelected: (_) => setState(() => _filter = f),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // ── Grouped list ──
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          l.locale == AppLocale.zh ? '暂无匹配项' : 'No matching entries',
                          style: TextStyle(color: scheme.outline),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 12),
                        children: [
                          for (final source in sourceOrder)
                            if (groups.containsKey(source)) ...[
                              _SourceHeader(
                                source: source,
                                count: groups[source]!.length,
                                locale: l.locale,
                              ),
                              for (final e in groups[source]!)
                                StartupTile(
                                  entry: e,
                                  onToggle: (enable) => ref
                                      .read(startupProvider.notifier)
                                      .toggle(e, enable),
                                ),
                            ],
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Section header for a startup source group.
class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.source, required this.count, required this.locale});

  final String source;
  final int count;
  final AppLocale locale;

  String get _label {
    switch (source) {
      case 'HKLM':
        return locale == AppLocale.zh ? '系统级注册表 (HKLM)' : 'System Registry (HKLM)';
      case 'HKCU':
        return locale == AppLocale.zh ? '用户注册表 (HKCU)' : 'User Registry (HKCU)';
      case 'StartupFolder':
        return locale == AppLocale.zh ? '启动文件夹' : 'Startup Folder';
      case 'TaskScheduler':
        return locale == AppLocale.zh ? '计划任务' : 'Scheduled Tasks';
      default:
        return source;
    }
  }

  IconData get _icon {
    switch (source) {
      case 'HKLM':
        return Icons.admin_panel_settings_outlined;
      case 'HKCU':
        return Icons.person_outline;
      case 'StartupFolder':
        return Icons.folder_outlined;
      case 'TaskScheduler':
        return Icons.schedule_outlined;
      default:
        return Icons.extension_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(_icon, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            _label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: TextStyle(fontSize: 11, color: scheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
