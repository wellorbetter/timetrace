import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/bridge/api.dart';
import 'package:timetrace_app/src/core/bridge/api_provider.dart';

/// Startup entries state (Riverpod 3 syntax).
class StartupNotifier extends AsyncNotifier<List<StartupDto>> {
  @override
  Future<List<StartupDto>> build() => _load();

  Future<List<StartupDto>> _load() async {
    final api = ref.read(apiProvider);
    return api.getStartupEntries();
  }

  Future<void> toggle(StartupDto entry, bool enable) async {
    final api = ref.read(apiProvider);
    api.toggleStartup(id: entry.id, enable: enable);
    state = AsyncData(await _load());
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
