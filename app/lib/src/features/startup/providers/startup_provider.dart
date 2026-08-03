import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';
import 'package:timetrace_app/src/core/logging/app_logger.dart';

/// Startup entries state (Riverpod 3 syntax).
class StartupNotifier extends AsyncNotifier<List<StartupDto>> {
  @override
  Future<List<StartupDto>> build() => _load();

  Future<List<StartupDto>> _load() async {
    try {
      final api = ref.read(apiProvider);
      final entries = api.getStartupEntries();
      AppLogger.log('startup loaded: ${entries.length} entries');
      return entries;
    } catch (e, st) {
      AppLogger.log('startup load FAILED: $e\n$st');
      rethrow;
    }
  }

  Future<void> toggle(StartupDto entry, bool enable) async {
    try {
      final api = ref.read(apiProvider);
      api.toggleStartup(id: entry.id, enable: enable);
      AppLogger.log('toggled startup ${entry.name} -> ${enable ? 'on' : 'off'}');
      state = AsyncData(await _load());
    } catch (e, st) {
      AppLogger.log('startup toggle FAILED ${entry.name}: $e\n$st');
      rethrow;
    }
  }
}

final startupProvider =
    AsyncNotifierProvider<StartupNotifier, List<StartupDto>>(
        StartupNotifier.new);

/// Enabled count, derived from the current entries.
final startupEnabledCountProvider = Provider<int>((ref) {
  return ref.watch(startupProvider).maybeWhen(
        data: (entries) => entries.where((e) => e.enabled).length,
        orElse: () => 0,
      );
});
