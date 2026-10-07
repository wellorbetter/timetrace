import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'workspace_layout_provider.dart';

const kViews = <String, String>{
  'bar': '应用时长',
  'hourly': '时段分布',
  'summary': '使用汇总',
  'apps': '应用明细',
};
const kDefaultOrder = ['bar', 'summary', 'apps', 'hourly'];

/// Read projection only. Layout and legacy order commit in the same core patch.
class DashboardOrderNotifier extends Notifier<List<String>> {
  @override
  List<String> build() {
    final document = ref.watch(workspaceDocumentProvider).document;
    return List.unmodifiable(<String>{
      ...document.groups.expand((group) => group).where(kViews.containsKey),
      ...kDefaultOrder,
    });
  }

  Future<void> move(int from, int to) async {
    final order = List.of(state);
    if (from < 0 || from >= order.length || to < 0 || to >= order.length)
      return;
    order.insert(to, order.removeAt(from));
    await ref.read(workspaceDocumentProvider.notifier).reorderData(order);
  }
}

final dashboardOrderProvider =
    NotifierProvider<DashboardOrderNotifier, List<String>>(
      DashboardOrderNotifier.new,
    );
