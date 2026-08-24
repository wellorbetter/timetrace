import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Narrow UI-facing boundary for manual AI time reports.
///
/// [status] and [latestReports] are local synchronous reads. Only [generate] may
/// perform network I/O, and callers invoke it exclusively from an explicit
/// user action.
abstract interface class AiRecapPort {
  AiRecapProviderStatus status();

  /// Returns at most one persisted report for each closed report type.
  List<AiRecapResult> latestReports();

  /// Generates one report using the default model configured in Settings.
  Future<AiRecapResult> generate(AiRecapRangeKey key);
}
