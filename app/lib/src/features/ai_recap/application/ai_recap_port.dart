import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';

/// Narrow UI-facing boundary for the built-in AI recap feature.
///
/// [status] and [latest] are local synchronous reads. Only [generate] may
/// perform network I/O, and callers invoke it exclusively from an explicit
/// user action.
abstract interface class AiRecapPort {
  AiRecapProviderStatus status();

  AiRecapResult? latest(AiRecapRangeKey key);

  Future<AiRecapResult> generate(AiRecapRangeKey key, AiRecapModel model);
}
