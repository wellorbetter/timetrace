import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

import 'contribution_models.dart';
import 'contribution_source.dart';

/// The only contribution adapter that owns a raw Flutter-Rust bridge API.
final class FrbContributionSource implements ContributionSource {
  /// Creates the production adapter around the process-wide bridge API.
  const FrbContributionSource(this._api);

  final TimeTraceApi _api;

  @override
  Future<ContributionSnapshot> load() async {
    try {
      final wire = await _api.pluginSnapshot();
      return await Isolate.run(
        () => ContributionSnapshot.fromHostDto(wire),
        debugName: 'timetrace-plugin-snapshot-decode',
      );
    } catch (_) {
      throw const ContributionSourceException('snapshot_unavailable');
    }
  }

  @override
  Future<ContributionSnapshot> setEnabled(String pluginId, bool enabled) async {
    try {
      final wire = await _api.setPluginEnabled(
        pluginId: pluginId,
        enabled: enabled,
      );
      return await Isolate.run(
        () => ContributionSnapshot.fromHostDto(wire),
        debugName: 'timetrace-plugin-mutation-decode',
      );
    } catch (_) {
      throw const ContributionSourceException('mutation_failed');
    }
  }
}

/// Override seam for widget and controller tests.
///
/// UI consumers depend on [contributionControllerProvider], not this provider,
/// so neither the bridge API nor transport details cross the host boundary.
final contributionSourceProvider = Provider<ContributionSource>((ref) {
  return FrbContributionSource(ref.watch(apiProvider));
});
