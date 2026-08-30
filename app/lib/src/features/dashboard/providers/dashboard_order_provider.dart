import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/core/i18n/reminder_l10n.dart';
import 'package:timetrace_app/src/core/preferences/ui_preferences_store.dart';

/// Carousel view keys — user-reorderable.
const kViews = <String, String>{
  'bar': '柱状图',
  'pie': '饼图',
  'hourly': '时段',
  'summary': '汇总',
  'focus': '专注提醒',
  'apps': '应用列表',
  'history': '使用历史',
};
const kDefaultOrder = [
  'bar',
  'pie',
  'summary',
  'focus',
  'apps',
  'hourly',
  'history',
];

/// Every carousel page can be enabled or disabled from Overview settings.
///
/// The original pages plus history and focus reminders are enabled by default.
/// [dashboardVisibleOrder] keeps a safe fallback if a stale settings file
/// happens to hide every page.
const kOptionalViews = {
  'bar',
  'pie',
  'summary',
  'focus',
  'apps',
  'hourly',
  'history',
};
const kDefaultHiddenViews = <String>{};

String dashboardViewLabel(String view, ReminderL10n strings) {
  if (view == 'focus') return strings.focusCarouselLabel;
  return kViews[view] ?? strings.dataView;
}

List<String> dashboardVisibleOrder(
  List<String> order,
  Set<String> hiddenViews,
) {
  final visible = order
      .where((view) => kViews.containsKey(view) && !hiddenViews.contains(view))
      .toList(growable: false);
  return visible.isEmpty ? const ['summary'] : visible;
}

/// Persisted dashboard carousel order (local JSON, UI-only — no Rust change).
class DashboardOrderNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => _load();

  List<String> _load() {
    try {
      final raw = UiPreferencesStore.read();
      if (raw['order'] is! List) return List.of(kDefaultOrder);
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

  void reset() {
    final order = List<String>.of(kDefaultOrder);
    state = order;
    _persist(order);
  }

  void _persist(List<String> order) {
    try {
      UiPreferencesStore.update({'order': order});
    } catch (e) {
      // Non-fatal: order just won't persist.
    }
  }
}

final dashboardOrderProvider =
    NotifierProvider<DashboardOrderNotifier, List<String>>(
      DashboardOrderNotifier.new,
    );

class DashboardHiddenViewsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    try {
      final stored = UiPreferencesStore.read()['hidden_views'];
      if (stored is! List) return Set.of(kDefaultHiddenViews);
      return stored.whereType<String>().where(kOptionalViews.contains).toSet();
    } catch (_) {
      return Set.of(kDefaultHiddenViews);
    }
  }

  void setHidden(String view, {required bool hidden}) {
    if (!kOptionalViews.contains(view)) return;
    final next = Set<String>.of(state);
    hidden ? next.add(view) : next.remove(view);
    state = next;
    try {
      UiPreferencesStore.update({'hidden_views': next.toList()..sort()});
    } catch (_) {
      // UI preference persistence is best-effort.
    }
  }

  void reset() {
    state = Set<String>.of(kDefaultHiddenViews);
    try {
      UiPreferencesStore.update({'hidden_views': const <String>[]});
    } catch (_) {
      // UI preference persistence is best-effort.
    }
  }
}

final dashboardHiddenViewsProvider =
    NotifierProvider<DashboardHiddenViewsNotifier, Set<String>>(
      DashboardHiddenViewsNotifier.new,
    );
