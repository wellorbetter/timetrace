import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui_preferences_controller.dart';
import 'ui_preferences_store.dart';

/// Only this exact versioned, disposable field is eligible. No paths, folders,
/// history, diary, images, tags or task state are accepted by this API.
enum SafeCacheScope { dailyQuoteV2 }

class SafeCacheTicket {
  SafeCacheTicket._(this.snapshot);
  final UiPreferencesLoaded snapshot;
  UiPreferencesOperation? _operation;
  bool _consumed = false;
}

class SafeCacheEpoch extends Notifier<int> {
  @override
  int build() => 0;
  void verifiedClear() => state++;
}

final safeCacheEpochProvider = NotifierProvider<SafeCacheEpoch, int>(
  SafeCacheEpoch.new,
);
final safeCacheServiceProvider = Provider<SafeCacheService>(
  (ref) => SafeCacheService(
    controller: ref.read(uiPreferencesControllerProvider.notifier),
    onVerifiedClear: () =>
        ref.read(safeCacheEpochProvider.notifier).verifiedClear(),
  ),
);

/// Later quote consumers capture this epoch before fetching and compare before
/// publishing/cache writes. A failed or cancelled clear never advances it.
class SafeCacheService {
  SafeCacheService({required this.controller, required this.onVerifiedClear});
  final UiPreferencesController controller;
  final void Function() onVerifiedClear;
  SafeCacheTicket? capture(SafeCacheScope scope) {
    final root = controller.readOutcome();
    if (root is! UiPreferencesLoaded ||
        !root.root.containsKey('dailyQuoteV2') ||
        !validDailyQuoteCache(root.root['dailyQuoteV2']))
      return null;
    return SafeCacheTicket._(root);
  }

  UiPreferencesOperation? clear(
    SafeCacheTicket ticket, {
    required bool confirmed,
  }) {
    if (!confirmed ||
        ticket._consumed ||
        !validDailyQuoteCache(ticket.snapshot.root['dailyQuoteV2']))
      return null;
    final operation = ticket._operation == null
        ? controller.patch(
            'safeCache',
            const {},
            removeKeys: const {'dailyQuoteV2'},
            capturedSnapshot: ticket.snapshot,
            validateRoot: (root) =>
                !root.containsKey('dailyQuoteV2') ||
                validDailyQuoteCache(root['dailyQuoteV2']),
          )
        : controller.retry(ticket._operation!.id);
    ticket._operation = operation;
    if (operation?.status == UiPreferencesOperationStatus.verifiedAck) {
      ticket._consumed = true;
      onVerifiedClear();
    }
    return operation;
  }
}

bool validDailyQuoteCache(Object? value) {
  if (value is! Map ||
      value['schemaVersion'] != 2 ||
      value['day'] is! String ||
      value['online'] is! bool)
    return false;
  const keys = {
    'schemaVersion',
    'day',
    'text',
    'source',
    'online',
    'author',
    'work',
    'dynasty',
    'fullContent',
    'sourceUrl',
  };
  if (value.length != keys.length || !value.keys.every(keys.contains))
    return false;
  final day = value['day'] as String;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) return false;
  final parsed = DateTime.tryParse(day);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != day)
    return false;
  bool field(String key, int max, {bool empty = false}) {
    final item = value[key];
    return item is String &&
        item.length <= max &&
        (empty || item.trim().isNotEmpty);
  }

  if (!field('text', 120) ||
      !field('source', 256, empty: true) ||
      !field('author', 120) ||
      !field('work', 120) ||
      !field('dynasty', 120) ||
      !field('sourceUrl', 512))
    return false;
  final uri = Uri.tryParse(value['sourceUrl'] as String);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty)
    return false;
  final lines = value['fullContent'];
  if (lines is! List ||
      lines.isEmpty ||
      lines.length > 128 ||
      lines.any(
        (line) => line is! String || line.trim().isEmpty || line.length > 512,
      ))
    return false;
  if (lines.fold<int>(0, (sum, line) => sum + (line as String).length) > 16384)
    return false;
  String compact(String text) => text.replaceAll(RegExp(r'\s+'), '');
  return compact(lines.join()).contains(compact(value['text'] as String));
}
