import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/theme/timetrace_theme.dart';
import 'package:timetrace_app/src/features/dashboard/domain/dashboard_state.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_chart_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/app_list_section.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/dashboard_summary_strip.dart';
import 'package:timetrace_app/src/features/dashboard/presentation/widgets/pie_chart_card.dart';

@Preview(name: '概览可选视图 · 桌面交互', size: Size(1120, 650))
Widget dashboardVisualsDesktopPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.light(),
  home: const Scaffold(body: _DashboardVisualPreview()),
);

@Preview(name: '概览可选视图 · 窄窗交互', size: Size(430, 760))
Widget dashboardVisualsCompactPreview() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: TimetraceTheme.dark(),
  home: const Scaffold(body: _DashboardVisualPreview()),
);

class _DashboardVisualPreview extends StatefulWidget {
  const _DashboardVisualPreview();

  @override
  State<_DashboardVisualPreview> createState() =>
      _DashboardVisualPreviewState();
}

class _DashboardVisualPreviewState extends State<_DashboardVisualPreview> {
  String _view = 'apps';
  int? _selected;
  late final List<GlobalKey> _rowKeys = List.generate(
    _previewApps.length,
    (_) => GlobalKey(),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          DashboardSummaryStrip(
            state: _previewState,
            apps: _previewApps,
            compact: constraints.maxHeight < 700,
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'apps', label: Text('应用详情')),
              ButtonSegment(value: 'bar', label: Text('可选柱状图')),
              ButtonSegment(value: 'pie', label: Text('可选饼图')),
            ],
            selected: {_view},
            onSelectionChanged: (value) => setState(() => _view = value.first),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: switch (_view) {
              'pie' => PieChartCard(
                apps: _previewApps,
                selectedIndex: _selected,
                onSelectApp: (index) => setState(() => _selected = index),
              ),
              'apps' => SingleChildScrollView(
                child: AppListSection(
                  apps: _previewApps,
                  selected: _selected,
                  pages: _previewPages,
                  loading: false,
                  onSelect: (index) => setState(
                    () => _selected = _selected == index ? null : index,
                  ),
                  rowKeys: _rowKeys,
                ),
              ),
              _ => AppChartSection(
                apps: _previewApps,
                selected: _selected,
                onSelect: (index) => setState(() => _selected = index),
                tall: true,
              ),
            },
          ),
        ],
      ),
    ),
  );
}

const _previewApps = [
  AppUsageItem(
    appName: 'TFTTencentClient-Win64-Shipping',
    activeSeconds: 14940,
    idleSeconds: 0,
  ),
  AppUsageItem(appName: 'Microsoft Edge', activeSeconds: 1269, idleSeconds: 0),
  AppUsageItem(appName: '英雄联盟', activeSeconds: 939, idleSeconds: 0),
  AppUsageItem(appName: 'TimeTrace', activeSeconds: 253, idleSeconds: 0),
  AppUsageItem(appName: '资源管理器', activeSeconds: 141, idleSeconds: 0),
  AppUsageItem(appName: 'QQ', activeSeconds: 131, idleSeconds: 0),
  AppUsageItem(appName: 'Terminal', activeSeconds: 64, idleSeconds: 0),
  AppUsageItem(appName: 'Figma', activeSeconds: 31, idleSeconds: 0),
];

const _previewState = DashboardState(
  apps: _previewApps,
  totalActiveSeconds: 17768,
  totalIdleSeconds: 320,
  lifetimeSeconds: 62000,
);

const _previewPages = [
  PageDto(title: 'TimeTrace · 回顾页面', seconds: 241),
  PageDto(title: 'timetrace_app', seconds: 92),
  PageDto(title: '设置 · AI 增强', seconds: 71),
  PageDto(title: 'GitHub · wellorbetter/timetrace', seconds: 54),
  PageDto(title: 'Flutter Widget Preview', seconds: 48),
  PageDto(title: 'Windows Terminal', seconds: 31),
];
