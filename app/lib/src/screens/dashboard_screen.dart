import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import "package:timetrace_app/src/bridge/api.dart" as api;
import "package:timetrace_app/src/bridge/api_holder.dart";

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<api.AppUsageDto> _apps = [];
  api.StatsDto? _stats;
  int _preset = 0; // 0=today 1=yesterday 2=week 3=month
  bool _loading = true;
  Timer? _timer;

  // Preset date ranges
  (String, String) _rangeFor(int preset) {
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    switch (preset) {
      case 1: // yesterday
        final y = now.subtract(const Duration(days: 1));
        final ys = '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
        return (ys, ys);
      case 2: // this week (Monday)
        final monday = now.subtract(Duration(days: now.weekday - 1));
        final ms = '${monday.year}-${monday.month.toString().padLeft(2, '0')}-${monday.day.toString().padLeft(2, '0')}';
        return (ms, today);
      case 3: // this month
        final ms = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
        return (ms, today);
      default: return (today, today);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final (start, end) = _rangeFor(_preset);
      final apps = Api.instance.getUsageSplit(start: start, end: end);
      final stats = Api.instance.getStats(start: start, end: end);
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _stats = stats;
        _loading = false;
      });
    } catch (e) {
      if (!quiet) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    }
  }

  Color _appColor(String name) {
    final colors = [
      const Color(0xFF6750A4), const Color(0xFF1976D2), const Color(0xFF388E3C),
      const Color(0xFFED6C02), const Color(0xFF009688), const Color(0xFFD32F2F),
      const Color(0xFF9C27B0), const Color(0xFF795548),
    ];
    var h = 0;
    for (final c in name.codeUnits) { h = (h * 31 + c) & 0x7fffffff; }
    return colors[h % colors.length];
  }

  String _fmt(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return h > 0 ? '$h时$m分' : '$m分';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final apps = _apps.where((a) => a.activeSeconds + a.idleSeconds > 0).toList();
    final stats = _stats;

    return Scaffold(
      appBar: AppBar(
        title: const Text('使用统计'),
        actions: [
          // Date range presets
          for (final (label, idx) in [('今天', 0), ('昨天', 1), ('本周', 2), ('本月', 3)])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: _preset == idx,
                onSelected: (_) { setState(() { _preset = idx; }); _load(); },
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : apps.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.insights, size: 64, color: scheme.outlineVariant),
                      const SizedBox(height: 16),
                      const Text('暂无数据，切换应用后回来查看'),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // ── Header stats ──
                    Row(
                      children: [
                        _StatCard(
                          icon: Icons.timer_outlined,
                          label: '活跃',
                          value: _fmt(stats?.activeSeconds ?? 0),
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          icon: Icons.pause_circle_outline,
                          label: '挂机',
                          value: _fmt(stats?.idleSeconds ?? 0),
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 12),
                        _StatCard(
                          icon: Icons.history,
                          label: '总时长',
                          value: _fmt(stats?.totalSeconds ?? 0),
                          color: scheme.tertiary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ── Bar chart + Pie chart ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Stacked bar chart
                        Expanded(
                          child: _BarChartCard(apps: apps, colorOf: _appColor, fmt: _fmt),
                        ),
                        const SizedBox(width: 16),
                        // Pie chart with leader labels
                        Expanded(
                          child: _PieChartCard(apps: apps, colorOf: _appColor),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(),

                    // ── App list ──
                    Text('应用列表', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final app in apps)
                      _AppListTile(app: app, color: _appColor(app.appName), fmt: _fmt),
                  ],
                ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon; final String label, value; final Color color;
  const _StatCard({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarChartCard extends StatelessWidget {
  final List<api.AppUsageDto> apps; final Color Function(String) colorOf; final String Function(int) fmt;
  const _BarChartCard({required this.apps, required this.colorOf, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final maxTotal = apps.map((a) => a.activeSeconds + a.idleSeconds).fold<int>(1, (m, v) => v > m ? v : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('按应用'),
            const SizedBox(height: 12),
            SizedBox(
              height: 150,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final app in apps.take(8))
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            // Value label
                            Text(fmt(app.activeSeconds + app.idleSeconds),
                                style: const TextStyle(fontSize: 10)),
                            // Idle segment (hatched via lighter color)
                            if (app.idleSeconds > 0)
                              Container(
                                height: (app.idleSeconds / maxTotal) * 100,
                                decoration: BoxDecoration(
                                  color: Colors.grey.withOpacity(0.35),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                ),
                              ),
                            // Active segment
                            if (app.activeSeconds > 0)
                              Expanded(
                                child: Container(
                                  width: double.infinity,
                                  decoration: BoxDecoration(
                                    color: colorOf(app.appName),
                                    borderRadius: app.idleSeconds > 0
                                        ? BorderRadius.zero
                                        : const BorderRadius.vertical(top: Radius.circular(4)),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 4),
                            // Name label
                            Text(app.appName.length > 6 ? app.appName.substring(0, 6) : app.appName,
                                style: const TextStyle(fontSize: 9), overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PieChartCard extends StatelessWidget {
  final List<api.AppUsageDto> apps; final Color Function(String) colorOf;
  const _PieChartCard({required this.apps, required this.colorOf});

  @override
  Widget build(BuildContext context) {
    final total = apps.fold<int>(0, (s, a) => s + a.activeSeconds).clamp(1, 1 << 62);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('占比'),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 20,
                  sections: apps.take(8).map((app) {
                    return PieChartSectionData(
                      value: app.activeSeconds.toDouble(),
                      color: colorOf(app.appName),
                      radius: 40,
                      title: '',
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Legend
            Wrap(
              spacing: 10, runSpacing: 4,
              children: apps.take(8).map((app) {
                final pct = (app.activeSeconds / total * 100).round();
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: colorOf(app.appName), shape: BoxShape.circle)),
                  const SizedBox(width: 4),
                  Text('${app.appName} $pct%', style: const TextStyle(fontSize: 11)),
                ]);
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppListTile extends StatelessWidget {
  final api.AppUsageDto app; final Color color; final String Function(int) fmt;
  const _AppListTile({required this.app, required this.color, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final total = app.activeSeconds + app.idleSeconds;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.apps, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(app.appName, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 12),
            if (app.idleSeconds > 0)
              Text('${fmt(app.idleSeconds)} 挂机', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            Text(fmt(app.activeSeconds), style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
