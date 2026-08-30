enum AiDiaryFailureKind {
  disabled,
  notConfigured,
  missingCredentials,
  timeout,
  provider,
  invalidResponse,
}

class AiDiaryDraft {
  const AiDiaryDraft({required this.content, required this.model});

  final String content;
  final String model;
}

class AiDiaryAttempt {
  const AiDiaryAttempt.success(this.draft) : failure = null, error = null;

  const AiDiaryAttempt.failure({required this.failure, required this.error})
    : draft = null;

  final AiDiaryDraft? draft;
  final AiDiaryFailureKind? failure;
  final String? error;

  bool get isSuccess => draft != null;
}

enum AiDiaryGenerationStatus {
  success,
  disabled,
  notConfigured,
  missingCredentials,
  noActivity,
  duplicate,
  failed,
}

/// Result of the complete generate-and-publish operation.
///
/// A [success] result means the entry has already been atomically published.
/// Every other status guarantees that this operation published nothing.
class AiDiaryGenerationOutcome {
  const AiDiaryGenerationOutcome({
    required this.status,
    this.entryId,
    this.content,
    this.model,
    this.message,
  });

  final AiDiaryGenerationStatus status;
  final int? entryId;
  final String? content;
  final String? model;
  final String? message;

  bool get isSuccess => status == AiDiaryGenerationStatus.success;
  bool get shouldRetry => switch (status) {
    AiDiaryGenerationStatus.noActivity ||
    AiDiaryGenerationStatus.failed => true,
    _ => false,
  };
}
