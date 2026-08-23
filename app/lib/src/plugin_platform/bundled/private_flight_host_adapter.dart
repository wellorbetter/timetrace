import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/features/flight/domain/private_flight_models.dart';
import 'package:timetrace_app/src/features/flight/presentation/flight_screen.dart';
import 'package:timetrace_app/src/features/flight/presentation/private_flight_contract.dart';
import 'package:timetrace_app/src/features/flight/providers/flight_controller_provider.dart';
import 'package:timetrace_app/src/plugin_platform/host/host.dart';

const _privateFlightPageContributionId = 'private-flight.page';

/// Trusted host boundary that projects Riverpod state into a pure renderer.
///
/// This is the only private-flight renderer component allowed to resolve host
/// providers or the raw bridge API. Descendant widgets receive immutable data
/// and [PrivateFlightActions] only.
final class PrivateFlightHostAdapter extends ConsumerWidget {
  /// Creates the bundled private-flight host adapter.
  const PrivateFlightHostAdapter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(flightControllerProvider);
    final today = ref.watch(flightTodayStatsProvider);
    final recent = ref.watch(flightRecentProvider);
    return FlightScreen(
      model: PrivateFlightViewModel(
        controller: controller,
        today: _projectLoad(today, 'today_stats_unavailable'),
        recent: _projectLoad(recent, 'recent_flights_unavailable'),
      ),
      actions: _PrivateFlightHostActions(ref),
    );
  }
}

PrivateFlightLoad<T> _projectLoad<T>(AsyncValue<T> source, String errorCode) {
  return source.when(
    data: PrivateFlightLoad<T>.data,
    error: (_, _) => PrivateFlightLoad<T>.error(errorCode),
    loading: PrivateFlightLoad<T>.loading,
  );
}

final class _PrivateFlightHostActions implements PrivateFlightActions {
  const _PrivateFlightHostActions(this._ref);

  final WidgetRef _ref;

  @override
  Future<void> start() async {
    if (!_isProjectable()) return;
    await _ref.read(flightControllerProvider.notifier).start();
  }

  @override
  Future<void> discard() async {
    if (!_isProjectable()) return;
    await _ref.read(flightControllerProvider.notifier).discard();
  }

  @override
  Future<bool> complete(
    PrivateFlightSession session,
    FlightCompletionDraft draft,
  ) async {
    if (!_isProjectable()) return false;
    final active = _ref.read(flightControllerProvider).activeSession;
    if (active == null || active.id != session.id) return false;
    try {
      final sourceUrl = draft.materialUrl.isEmpty ? null : draft.materialUrl;
      final material = !draft.skipMaterial && draft.materialTitle.isNotEmpty
          ? FlightCompletionMaterialDto(
              title: draft.materialTitle,
              kind: draft.materialKind.isEmpty ? 'article' : draft.materialKind,
              sourceUrl: sourceUrl,
              domain: _domain(sourceUrl),
              localAssetPath: null,
              tags: draft.materialTags,
              rating: draft.satisfaction,
            )
          : null;
      return await _ref
          .read(flightControllerProvider.notifier)
          .completeWithMaterial(
            satisfaction: draft.satisfaction,
            note: draft.note,
            material: material,
          );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<PrivateFlightMaterialLink>> loadMaterials(
    PrivateFlightSession session,
  ) async {
    if (!_isProjectable()) {
      throw StateError('plugin_not_projectable');
    }
    try {
      return (await _ref
              .read(apiProvider)
              .flightGetMaterials(flightId: session.id))
          .map(_materialLinkFromDto)
          .toList(growable: false);
    } catch (_) {
      throw StateError('materials_unavailable');
    }
  }

  @override
  void refreshToday() {
    if (_isProjectable()) _ref.invalidate(flightTodayStatsProvider);
  }

  @override
  void refreshRecent() {
    if (_isProjectable()) _ref.invalidate(flightRecentProvider);
  }

  bool _isProjectable() {
    final snapshot = _ref.read(contributionControllerProvider).value;
    return snapshot?.pages.any(
          (page) => page.contributionId == _privateFlightPageContributionId,
        ) ??
        false;
  }
}

String? _domain(String? sourceUrl) {
  if (sourceUrl == null) return null;
  final uri = Uri.tryParse(sourceUrl);
  return uri == null || uri.host.isEmpty ? null : uri.host.toLowerCase();
}

PrivateFlightMaterialLink _materialLinkFromDto(FlightMaterialDto value) {
  final material = value.material;
  return PrivateFlightMaterialLink(
    flightId: value.flightId,
    sortOrder: value.sortOrder,
    material: PrivateFlightMaterial(
      id: material.id,
      title: material.title,
      kind: material.kind,
      sourceUrl: material.sourceUrl,
      domain: material.domain,
      localAssetPath: material.localAssetPath,
      tags: material.tags,
      rating: material.rating,
    ),
  );
}
