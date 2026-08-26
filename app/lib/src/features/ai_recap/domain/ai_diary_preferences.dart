import 'package:flutter/foundation.dart';

const kDefaultAiDiaryBuiltInCoverId = 'night_focus';

const kAiDiaryBuiltInCoverIds = <String>{
  kDefaultAiDiaryBuiltInCoverId,
  'warm_afternoon',
  'rainy_evening',
  'spring_morning',
};

enum AiDiaryCoverSource {
  builtIn('built_in'),
  custom('custom'),
  none('none');

  const AiDiaryCoverSource(this.storageValue);

  final String storageValue;

  static AiDiaryCoverSource fromStorage(Object? value) {
    return switch (value) {
      'custom' => AiDiaryCoverSource.custom,
      'none' => AiDiaryCoverSource.none,
      _ => AiDiaryCoverSource.builtIn,
    };
  }
}

@immutable
class AiDiaryPreferences {
  const AiDiaryPreferences({
    this.enabled = false,
    this.coverSource = AiDiaryCoverSource.builtIn,
    this.builtInCoverId = kDefaultAiDiaryBuiltInCoverId,
    this.customCoverPath,
  });

  static const enabledKey = 'aiDiaryEnabled';
  static const coverSourceKey = 'aiDiaryCoverSource';
  static const builtInCoverIdKey = 'aiDiaryBuiltInCoverId';
  static const customCoverPathKey = 'aiDiaryCustomCoverPath';

  final bool enabled;
  final AiDiaryCoverSource coverSource;
  final String builtInCoverId;
  final String? customCoverPath;

  factory AiDiaryPreferences.fromStorage(Map<String, dynamic> values) {
    final rawCoverId = values[builtInCoverIdKey];
    final coverId =
        rawCoverId is String && kAiDiaryBuiltInCoverIds.contains(rawCoverId)
        ? rawCoverId
        : kDefaultAiDiaryBuiltInCoverId;
    final rawCustomPath = values[customCoverPathKey];
    final customPath =
        rawCustomPath is String && rawCustomPath.trim().isNotEmpty
        ? rawCustomPath
        : null;
    final requestedSource = AiDiaryCoverSource.fromStorage(
      values[coverSourceKey],
    );
    final source =
        requestedSource == AiDiaryCoverSource.custom && customPath == null
        ? AiDiaryCoverSource.builtIn
        : requestedSource;

    return AiDiaryPreferences(
      enabled: values[enabledKey] == true,
      coverSource: source,
      builtInCoverId: coverId,
      customCoverPath: source == AiDiaryCoverSource.custom ? customPath : null,
    );
  }

  Map<String, dynamic> toStorage() => <String, dynamic>{
    enabledKey: enabled,
    coverSourceKey: coverSource.storageValue,
    builtInCoverIdKey: builtInCoverId,
    customCoverPathKey: customCoverPath,
  };

  AiDiaryPreferences copyWith({
    bool? enabled,
    AiDiaryCoverSource? coverSource,
    String? builtInCoverId,
    Object? customCoverPath = _unchanged,
  }) {
    return AiDiaryPreferences(
      enabled: enabled ?? this.enabled,
      coverSource: coverSource ?? this.coverSource,
      builtInCoverId: builtInCoverId ?? this.builtInCoverId,
      customCoverPath: identical(customCoverPath, _unchanged)
          ? this.customCoverPath
          : customCoverPath as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AiDiaryPreferences &&
            other.enabled == enabled &&
            other.coverSource == coverSource &&
            other.builtInCoverId == builtInCoverId &&
            other.customCoverPath == customCoverPath;
  }

  @override
  int get hashCode =>
      Object.hash(enabled, coverSource, builtInCoverId, customCoverPath);
}

const _unchanged = Object();
