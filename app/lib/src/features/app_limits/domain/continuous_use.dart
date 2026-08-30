import '../../reminders/domain/reminder_timing.dart';
import 'activity_snapshot.dart';

/// An immutable application timeout rule consumed by the evaluator.
///
/// [executablePath] must already be normalized by the Rust boundary.
final class AppTimeoutRule {
  const AppTimeoutRule({
    required this.id,
    required this.executablePath,
    required this.displayName,
    required this.threshold,
    required this.cooldown,
    required this.enabled,
    required this.repeatEnabled,
  });

  final int id;
  final String executablePath;
  final String displayName;
  final Duration threshold;
  final Duration cooldown;
  final bool enabled;
  final bool repeatEnabled;

  bool get isValid =>
      id > 0 &&
      executablePath.isNotEmpty &&
      displayName.trim().isNotEmpty &&
      threshold > Duration.zero &&
      cooldown > Duration.zero;

  bool matches(ActivityApplication application) {
    return enabled && isValid && executablePath == application.executablePath;
  }

  /// Whether both rules represent the same notification decision behavior.
  ///
  /// Display-name changes update presentation without rearming a notification.
  bool hasSameDecisionAs(AppTimeoutRule other) {
    return id == other.id &&
        executablePath == other.executablePath &&
        threshold == other.threshold &&
        cooldown == other.cooldown &&
        enabled == other.enabled &&
        repeatEnabled == other.repeatEnabled;
  }

  @override
  bool operator ==(Object other) {
    return other is AppTimeoutRule &&
        other.id == id &&
        other.executablePath == executablePath &&
        other.displayName == displayName &&
        other.threshold == threshold &&
        other.cooldown == cooldown &&
        other.enabled == enabled &&
        other.repeatEnabled == repeatEnabled;
  }

  @override
  int get hashCode => Object.hash(
    id,
    executablePath,
    displayName,
    threshold,
    cooldown,
    enabled,
    repeatEnabled,
  );
}

/// Immutable transient state for one strict foreground-use segment.
final class ContinuousUseState {
  const ContinuousUseState({
    required this.application,
    required this.elapsed,
    required this.rulesRevision,
    required this.matchedRule,
    required this.lastNotificationElapsed,
  });

  const ContinuousUseState.empty({this.rulesRevision = 0})
    : application = null,
      elapsed = Duration.zero,
      matchedRule = null,
      lastNotificationElapsed = null;

  final ActivityApplication? application;
  final Duration elapsed;
  final int rulesRevision;
  final AppTimeoutRule? matchedRule;
  final Duration? lastNotificationElapsed;

  bool get hasSegment => application != null;

  @override
  bool operator ==(Object other) {
    return other is ContinuousUseState &&
        other.application == application &&
        other.elapsed == elapsed &&
        other.rulesRevision == rulesRevision &&
        other.matchedRule == matchedRule &&
        other.lastNotificationElapsed == lastNotificationElapsed;
  }

  @override
  int get hashCode => Object.hash(
    application,
    elapsed,
    rulesRevision,
    matchedRule,
    lastNotificationElapsed,
  );
}

/// A side effect requested by [ContinuousUseEvaluator].
sealed class ContinuousUseEffect {
  const ContinuousUseEffect();
}

/// Requests an application timeout notification with privacy-safe content.
///
/// Executable paths and window titles are intentionally absent.
final class AppTimeoutNotificationEffect extends ContinuousUseEffect {
  const AppTimeoutNotificationEffect({
    required this.applicationName,
    required this.roundedMinutes,
  });

  final String applicationName;
  final int roundedMinutes;

  @override
  bool operator ==(Object other) {
    return other is AppTimeoutNotificationEffect &&
        other.applicationName == applicationName &&
        other.roundedMinutes == roundedMinutes;
  }

  @override
  int get hashCode => Object.hash(applicationName, roundedMinutes);
}

/// The immutable result of one continuous-use evaluation.
final class ContinuousUseTransition {
  ContinuousUseTransition({
    required this.state,
    List<ContinuousUseEffect> effects = const [],
  }) : effects = List.unmodifiable(effects);

  final ContinuousUseState state;
  final List<ContinuousUseEffect> effects;
}

/// Pure evaluator for strict per-executable foreground-use segments.
final class ContinuousUseEvaluator {
  const ContinuousUseEvaluator();

  ContinuousUseTransition advance({
    required ContinuousUseState state,
    required ActivitySnapshot snapshot,
    required Iterable<AppTimeoutRule> rules,
    required Duration elapsed,
    required int rulesRevision,
    bool isGap = false,
  }) {
    final application = snapshot.application;
    if (!snapshot.isActive ||
        application == null ||
        application.executablePath.trim().isEmpty) {
      return _transition(
        ContinuousUseState.empty(rulesRevision: rulesRevision),
      );
    }

    final rule = _matchingRule(application, rules);
    final callbackGap =
        isGap || elapsed.isNegative || elapsed > reminderCallbackGapTolerance;
    final pathChanged =
        state.application?.executablePath != application.executablePath;
    if (callbackGap || pathChanged) {
      return _transition(
        _newSegment(
          application: application,
          rule: rule,
          rulesRevision: rulesRevision,
        ),
      );
    }

    final nextElapsed = reminderDeltaContributes(elapsed)
        ? state.elapsed + elapsed
        : state.elapsed;

    if (rule == null) {
      return _transition(
        ContinuousUseState(
          application: application,
          elapsed: nextElapsed,
          rulesRevision: rulesRevision,
          matchedRule: null,
          lastNotificationElapsed: null,
        ),
      );
    }

    final decisionUnchanged =
        state.matchedRule?.hasSameDecisionAs(rule) ?? false;
    var notificationMarker = decisionUnchanged
        ? state.lastNotificationElapsed
        : null;
    final shouldNotify = notificationMarker == null
        ? nextElapsed >= rule.threshold
        : rule.repeatEnabled &&
              nextElapsed >= notificationMarker + rule.cooldown;

    final effects = <ContinuousUseEffect>[];
    if (shouldNotify) {
      notificationMarker = nextElapsed;
      effects.add(
        AppTimeoutNotificationEffect(
          applicationName: rule.displayName,
          roundedMinutes: _roundedMinutes(nextElapsed),
        ),
      );
    }

    return ContinuousUseTransition(
      state: ContinuousUseState(
        application: application,
        elapsed: nextElapsed,
        rulesRevision: rulesRevision,
        matchedRule: rule,
        lastNotificationElapsed: notificationMarker,
      ),
      effects: effects,
    );
  }

  AppTimeoutRule? _matchingRule(
    ActivityApplication application,
    Iterable<AppTimeoutRule> rules,
  ) {
    for (final rule in rules) {
      if (rule.matches(application)) {
        return rule;
      }
    }
    return null;
  }

  ContinuousUseState _newSegment({
    required ActivityApplication application,
    required AppTimeoutRule? rule,
    required int rulesRevision,
  }) {
    return ContinuousUseState(
      application: application,
      elapsed: Duration.zero,
      rulesRevision: rulesRevision,
      matchedRule: rule,
      lastNotificationElapsed: null,
    );
  }

  int _roundedMinutes(Duration elapsed) {
    final rounded = (elapsed.inSeconds / Duration.secondsPerMinute).round();
    return rounded < 1 ? 1 : rounded;
  }

  ContinuousUseTransition _transition(ContinuousUseState state) {
    return ContinuousUseTransition(state: state);
  }
}
