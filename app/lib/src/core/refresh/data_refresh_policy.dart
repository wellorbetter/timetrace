import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// Data polling is independent of time-tool display ticks.
class DataRefreshPolicy {
  const DataRefreshPolicy({this.interval = const Duration(seconds: 30)});
  final Duration interval;
}

final dataRefreshPolicyProvider = Provider<DataRefreshPolicy>(
  (ref) => const DataRefreshPolicy(),
);

typedef DataRefreshVisibility = FutureOr<bool> Function();
final dataRefreshVisibilityProvider = Provider<DataRefreshVisibility>(
  (ref) =>
      () => windowManager.isVisible(),
);

/// One timer per owner; no consumers or background lifecycle means no polling.
/// Visibility awaits never queue work and disposal invalidates pending checks.
class DataRefreshLoop with WidgetsBindingObserver {
  DataRefreshLoop({
    required this.policy,
    required this.visible,
    required this.onRefresh,
    required this.canRefresh,
  }) {
    try {
      _binding = WidgetsBinding.instance;
    } catch (_) {}
    _binding?.addObserver(this);
    final initial = _binding?.lifecycleState;
    _foreground = initial == null || initial == AppLifecycleState.resumed;
  }
  WidgetsBinding? _binding;
  final DataRefreshPolicy policy;
  final DataRefreshVisibility visible;
  final Future<void> Function() onRefresh;
  final bool Function() canRefresh;
  Timer? _timer;
  bool _consumers = true;
  bool _enabled = false;
  bool _foreground = true;
  bool _disposed = false;
  Object? _checking;
  int _epoch = 0;

  void configure(bool enabled) {
    _enabled = enabled;
    _sync();
  }

  void cancel() {
    _consumers = false;
    _sync();
  }

  int resume() {
    _consumers = true;
    _sync();
    return _epoch;
  }

  /// Catch-up is automatic polling, so it obeys exactly the same gates.
  Future<void> checkNow({required int expectedEpoch}) async {
    if (expectedEpoch != _epoch) return;
    await _tick();
  }

  void _sync() {
    _epoch++;
    _checking = null;
    _timer?.cancel();
    _timer = null;
    if (!_disposed &&
        _consumers &&
        _foreground &&
        _enabled &&
        policy.interval > Duration.zero) {
      _timer = Timer.periodic(policy.interval, (_) => unawaited(_tick()));
    }
  }

  Future<void> _tick() async {
    if (_disposed ||
        _checking != null ||
        !_consumers ||
        !_foreground ||
        !_enabled ||
        policy.interval <= Duration.zero ||
        !canRefresh())
      return;
    final check = Object();
    _checking = check;
    final epoch = _epoch;
    try {
      final shown = await visible();
      if (epoch == _epoch &&
          shown &&
          !_disposed &&
          _consumers &&
          _foreground &&
          _enabled &&
          canRefresh()) {
        await onRefresh();
      }
    } catch (_) {
      // Visibility failures are not evidence that the window is visible.
    } finally {
      if (identical(_checking, check)) _checking = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _binding?.removeObserver(this);
  }
}
