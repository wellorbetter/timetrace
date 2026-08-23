import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'contribution_models.dart';
import 'contribution_source.dart';
import 'frb_contribution_source.dart';

/// Owns the latest accepted canonical publication for Flutter host surfaces.
final class ContributionController extends AsyncNotifier<ContributionSnapshot> {
  static const int _maxQueuedMutations = 32;

  BigInt? _acceptedRevision;
  Future<void> _mutationTail = Future<void>.value();
  bool _acceptingMutations = true;
  int _queuedMutations = 0;

  @override
  FutureOr<ContributionSnapshot> build() {
    final initial = ref.watch(contributionSourceProvider).load().then((value) {
      _acceptedRevision = value.revision;
      return value;
    });
    // Mutations never race the initial publication, including its error path.
    _mutationTail = initial.then<void>((_) {}, onError: (_, _) {});
    return initial;
  }

  /// Serially changes desired state without optimistic local projection.
  Future<void> setEnabled(String pluginId, bool enabled) {
    if (!_acceptingMutations) {
      return _rejectMutation('host_shutting_down');
    }
    if (_queuedMutations >= _maxQueuedMutations) {
      return _rejectMutation('mutation_queue_full');
    }
    _queuedMutations++;
    final operation = _mutationTail
        .then((_) => _performSetEnabled(pluginId, enabled))
        .whenComplete(() => _queuedMutations--);
    _mutationTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  /// Stops accepting UI commands and waits for the admitted mutation queue.
  Future<void> prepareShutdown() {
    _acceptingMutations = false;
    state = AsyncData(
      ContributionSnapshot.empty(
        revision: state.value?.revision ?? _acceptedRevision ?? BigInt.zero,
      ),
    );
    return _mutationTail;
  }

  Future<void> _rejectMutation(String code) {
    state = AsyncError(ContributionSourceException(code), StackTrace.current);
    return Future<void>.value();
  }

  Future<void> _performSetEnabled(String pluginId, bool enabled) async {
    try {
      final incoming = await ref
          .read(contributionSourceProvider)
          .setEnabled(pluginId, enabled);
      if (!_acceptingMutations) return;
      final accepted = _acceptedRevision;
      if (accepted == null || incoming.revision > accepted) {
        _acceptedRevision = incoming.revision;
        state = AsyncData(incoming);
      }
    } catch (error, stackTrace) {
      // Never retain an old active snapshot after a host or decode failure.
      state = AsyncError(error, stackTrace);
    }
  }
}

/// Canonical contribution state consumed by navigation and plugin UI slots.
final contributionControllerProvider =
    AsyncNotifierProvider<ContributionController, ContributionSnapshot>(
      ContributionController.new,
    );
