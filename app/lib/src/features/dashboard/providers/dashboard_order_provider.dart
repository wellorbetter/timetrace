import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Carousel view keys — user-reorderable.
const kViews = <String, String>{
  'bar': '柱状图',
  'pie': '饼图',
  'summary': '汇总',
  'apps': '应用列表',
};
const kDefaultOrder = ['bar', 'pie', 'summary', 'apps'];

File _uiConfigFile() {
  final dir = Platform.environment['APPDATA'] ?? '.';
  return File('$dir\\TimeTrace\\ui_config.json');
}

/// Persisted dashboard carousel order (local JSON, UI-only — no Rust change).
class DashboardOrderNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => _load();

  List<String> _load() {
    try {
      final f = _uiConfigFile();
      if (!f.existsSync()) return List.of(kDefaultOrder);
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map || raw['order'] is! List) return List.of(kDefaultOrder);
      final order = (raw['order'] as List)
          .whereType<String>()
          .where(kViews.containsKey)
          .toList();
      // Always keep every known view (missing ones appended at the end).
      for (final v in kDefaultOrder) {
        if (!order.contains(v)) order.add(v);
      }
      return order;
    } catch (e) {
      return List.of(kDefaultOrder);
    }
  }

  void move(int from, int to) {
    final order = List.of(state);
    if (from < 0 || from >= order.length || to < 0 || to >= order.length) {
      return;
    }
    final item = order.removeAt(from);
    order.insert(to, item);
    state = order;
    _persist(order);
  }

  void _persist(List<String> order) {
    try {
      final f = _uiConfigFile();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({'order': order}));
    } catch (e) {
      // Non-fatal: order just won't persist.
    }
  }
}

final dashboardOrderProvider =
    NotifierProvider<DashboardOrderNotifier, List<String>>(
        DashboardOrderNotifier.new);
