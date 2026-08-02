import 'dart:io';
import 'package:flutter/material.dart';
import "package:timetrace_app/src/bridge/api.dart" as api;
import 'package:timetrace_app/src/bridge/api_holder.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  List<api.StartupDto> _entries = [];
  bool _loading = true;
  int _filter = 0; // 0=all 1=enabled 2=disabled

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = Api.instance.getStartupEntries();
      if (!mounted) return;
      setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
    }
  }

  Future<void> _toggle(api.StartupDto entry, bool enable) async {
    try {
      Api.instance.toggleStartup(id: entry.id, enable: enable);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('操作失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = _entries.where((e) {
      if (_filter == 1) return e.enabled;
      if (_filter == 2) return !e.enabled;
      return true;
    }).toList();
    final enabledCount = _entries.where((e) => e.enabled).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('自启动 (${_entries.length}项, $enabledCount启用)'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load, tooltip: '重新扫描'),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                for (final (label, idx) in [('全部', 0), ('启用', 1), ('禁用', 2)])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      selected: _filter == idx,
                      onSelected: (_) => setState(() => _filter = idx),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // List
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final e = filtered[i];
                      final isSys = e.source == 'HKLM' || e.exePath.contains('System32') || e.exePath.contains('Windows');
                      final name = _exeName(e.exePath) ?? e.name;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        child: ListTile(
                          leading: _AppIcon(exePath: e.exePath, name: name, isSys: isSys),
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            isSys ? '系统级 · ${e.source}' : '用户级 · ${e.source}',
                            style: TextStyle(fontSize: 12, color: isSys ? Colors.orange : Colors.blueGrey),
                          ),
                          trailing: Switch(
                            value: e.enabled,
                            onChanged: (v) => _toggle(e, v),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String? _exeName(String cmd) {
    final lower = cmd.toLowerCase();
    final idx = lower.indexOf('.exe');
    if (idx < 0) return null;
    final end = idx + 4;
    var start = cmd.lastIndexOf('"', end);
    start = start < 0 ? cmd.lastIndexOf(' ', end) : start;
    if (start < 0) start = 0;
    final path = cmd.substring(start + (cmd[start] == '"' || cmd[start] == ' ' ? 1 : 0), end);
    final slash = path.lastIndexOf('\\');
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

class _AppIcon extends StatelessWidget {
  final String exePath, name; final bool isSys;
  const _AppIcon({required this.exePath, required this.name, required this.isSys});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = isSys ? Colors.orange : Colors.blueGrey;
    // Try to load the exe icon file if it exists
    final first = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      width: 36, height: 36,
      decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(first, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}
