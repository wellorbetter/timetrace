import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui_preferences_store.dart';

enum UiPreferencesOperationStatus { pending, dirty, failed, verifiedAck }

Object? _immutable(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, _immutable(item))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_immutable));
  return value;
}

/// An immutable user intent. Retry never takes values from a later preview.
class UiPreferencesOperation {
  UiPreferencesOperation({
    required this.id,
    required this.group,
    required this.generation,
    required Map<String, dynamic> target,
    required this.layoutToken,
    required Map<String, String> preimage,
    this.removeKeys = const {},
    this.status = UiPreferencesOperationStatus.dirty,
    this.outcome,
  }) : target =
           _immutable(jsonDecode(jsonEncode(target))) as Map<String, dynamic>,
       preimage = Map.unmodifiable(preimage);
  final String id, group;
  final int generation;
  final Map<String, dynamic> target;
  final Object? layoutToken;
  final Map<String, String> preimage;
  final Set<String> removeKeys;
  final UiPreferencesOperationStatus status;
  final UiPreferencesWriteOutcome? outcome;
  UiPreferencesOperation result(UiPreferencesWriteOutcome value) =>
      UiPreferencesOperation(
        id: id,
        group: group,
        generation: generation,
        target: target,
        layoutToken: layoutToken,
        preimage: preimage,
        removeKeys: removeKeys,
        outcome: value,
        status: value is UiPreferencesCommitted
            ? UiPreferencesOperationStatus.verifiedAck
            : UiPreferencesOperationStatus.failed,
      );
}

final uiPreferencesBackendProvider = Provider<UiPreferencesFileBackend>(
  (ref) => const WindowsUiPreferencesFileBackend(),
);
final uiPreferencesControllerProvider =
    NotifierProvider<
      UiPreferencesController,
      Map<String, UiPreferencesOperation>
    >(UiPreferencesController.new);

class UiPreferencesController
    extends Notifier<Map<String, UiPreferencesOperation>> {
  int _generation = 0;
  @override
  Map<String, UiPreferencesOperation> build() => const {};
  UiPreferencesReadOutcome readOutcome() => UiPreferencesStore.readOutcome(
    backend: ref.read(uiPreferencesBackendProvider),
  );
  Map<String, dynamic> read() {
    final snapshot = readOutcome();
    return snapshot is UiPreferencesLoaded ? Map.of(snapshot.root) : {};
  }

  UiPreferencesOperation patch(
    String group,
    Map<String, dynamic> target, {
    Set<String> removeKeys = const {},
    bool Function(Map<String, dynamic>)? validateRoot,
    UiPreferencesReadOutcome? capturedSnapshot,
    UiPreferencesOperation? continuation,
  }) {
    final snapshot = capturedSnapshot ?? readOutcome();
    final root = snapshot is UiPreferencesLoaded
        ? snapshot.root
        : <String, dynamic>{};
    if (continuation != null &&
        (continuation.group != group || state[group]?.id != continuation.id)) {
      throw ArgumentError('Continuation must be the current field intent');
    }
    // An opacity adjustment continues an unacknowledged complete background.
    // Preserve its original CAS preimage unless reliable current bytes match
    // every old target field (the lost-readback ACK case). Explicit new color,
    // image or clear operations do not use this continuation seam.
    final retainPreimage =
        continuation != null &&
        continuation.status != UiPreferencesOperationStatus.verifiedAck &&
        !(snapshot is UiPreferencesLoaded &&
            continuation.target.entries.every(
              (entry) =>
                  root.containsKey(entry.key) &&
                  jsonEncode(root[entry.key]) == jsonEncode(entry.value),
            ) &&
            continuation.removeKeys.every((key) => !root.containsKey(key)));
    final generation = ++_generation;
    final intent = UiPreferencesOperation(
      id: '$group:$generation',
      group: group,
      generation: generation,
      target: target,
      removeKeys: Set.unmodifiable(removeKeys),
      layoutToken: retainPreimage
          ? continuation.layoutToken
          : switch (snapshot) {
              UiPreferencesLoaded(:final token) => token,
              UiPreferencesMissing(:final token) => token,
              _ => null,
            },
      preimage: {
        for (final key in {...target.keys, ...removeKeys})
          key: retainPreimage && continuation.preimage.containsKey(key)
              ? continuation.preimage[key]!
              : uiPreferencesFieldToken(root, key),
      },
    );
    final previous = state[group];
    if (previous != null) _validators.remove(previous.id);
    state = Map.unmodifiable({...state, group: intent});
    return _execute(intent, validateRoot);
  }

  final _validators = <String, bool Function(Map<String, dynamic>)>{};
  UiPreferencesOperation _execute(
    UiPreferencesOperation intent,
    bool Function(Map<String, dynamic>)? validateRoot,
  ) {
    if (validateRoot != null) _validators[intent.id] = validateRoot;
    final outcome = UiPreferencesStore.tryPatch(
      intent.target,
      expectedTargetToken: intent.layoutToken,
      expectedFields: intent.preimage,
      removeKeys: intent.removeKeys,
      backend: ref.read(uiPreferencesBackendProvider),
      validateRoot: validateRoot,
    );
    final completed = intent.result(outcome);
    if (ref.mounted && state[intent.group]?.id == intent.id) {
      state = Map.unmodifiable({...state, intent.group: completed});
    }
    return completed;
  }

  UiPreferencesOperation? retry(String operationId) {
    final matches = state.values.where((op) => op.id == operationId);
    if (matches.isEmpty) return null;
    final intent = matches.single;
    if (intent.status == UiPreferencesOperationStatus.verifiedAck)
      return intent;
    return _execute(intent, _validators[intent.id]);
  }
}

/// Field-bound feedback; preview is deliberately not represented as saved.
class UiPreferencesFeedback extends ConsumerWidget {
  const UiPreferencesFeedback(this.group, {super.key});
  final String group;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final operation = ref.watch(uiPreferencesControllerProvider)[group];
    if (operation == null ||
        operation.status == UiPreferencesOperationStatus.verifiedAck) {
      return const SizedBox.shrink();
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('尚未保存；当前仅为预览。'),
        TextButton(
          key: ValueKey('preferences_retry_$group'),
          onPressed: () => ref
              .read(uiPreferencesControllerProvider.notifier)
              .retry(operation.id),
          child: const Text('重试'),
        ),
      ],
    );
  }
}
