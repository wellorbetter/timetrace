import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_diary_preferences.dart';
import 'package:timetrace_app/src/features/ai_recap/domain/ai_recap_models.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_diary_preferences_provider.dart';
import 'package:timetrace_app/src/features/ai_recap/providers/ai_recap_provider.dart';

/// A compact recap embedded beside the user's regular journal.
///
/// The dashboard owns the date range and decides whether this feature is
/// visible. This card deliberately has no range selector, navigation, or
/// scrolling of its own, and never writes to the user's journal.
class AiRecapCard extends ConsumerWidget {
  const AiRecapCard({
    super.key,
    required this.rangeKey,
    required this.rangeLabel,
  });

  final AiRecapRangeKey rangeKey;
  final String rangeLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aiRecapControllerProvider);
    final preferences = ref.watch(aiDiaryPreferencesProvider);
    final projection = state.projection(rangeKey);
    final previous = state.latestReportFor(rangeKey.scope);
    final canUsePrevious =
        projection.result == null &&
        previous != null &&
        previous.rangeKey != rangeKey &&
        (projection.generating || projection.failure != null);
    final displayedResult =
        projection.result ?? (canUsePrevious ? previous : null);
    final isPreviousResult =
        displayedResult != null && displayedResult.rangeKey != rangeKey;
    final futureRange = _isFutureRange(rangeKey, DateTime.now());
    final validRange = rangeKey.isValid && !futureRange;
    final busy = state.pendingKey != null;
    final canGenerate =
        validRange &&
        state.status.ready &&
        state.status.serviceAvailable &&
        !busy;
    final controller = ref.read(aiRecapControllerProvider.notifier);

    return Semantics(
      container: true,
      label: '${_diaryTitle(rangeKey.scope)}，$rangeLabel',
      child: Card(
        key: const Key('ai-recap-dashboard-section'),
        margin: EdgeInsets.zero,
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cover = _DiaryCover(
                preferences: preferences,
                rangeKey: rangeKey,
                onNextBuiltIn:
                    preferences.coverSource == AiDiaryCoverSource.builtIn
                    ? () => _selectNextBuiltInCover(ref, preferences)
                    : null,
              );
              final content = _RecapContent(
                rangeKey: rangeKey,
                rangeLabel: rangeLabel,
                result: displayedResult,
                isPreviousResult: isPreviousResult,
                status: state.status,
                generating: projection.generating,
                busy: busy,
                validRange: validRange,
                futureRange: futureRange,
                failure: projection.failure,
                onGenerate: canGenerate
                    ? () => controller.generate(rangeKey)
                    : null,
              );

              if (preferences.coverSource == AiDiaryCoverSource.none) {
                return content;
              }
              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [cover, const SizedBox(height: 14), content],
                );
              }
              final coverWidth = (constraints.maxWidth * 0.31)
                  .clamp(232.0, 286.0)
                  .toDouble();
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: coverWidth, child: cover),
                  const SizedBox(width: 18),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RecapContent extends StatelessWidget {
  const _RecapContent({
    required this.rangeKey,
    required this.rangeLabel,
    required this.result,
    required this.isPreviousResult,
    required this.status,
    required this.generating,
    required this.busy,
    required this.validRange,
    required this.futureRange,
    required this.failure,
    required this.onGenerate,
  });

  final AiRecapRangeKey rangeKey;
  final String rangeLabel;
  final AiRecapResult? result;
  final bool isPreviousResult;
  final AiRecapProviderStatus status;
  final bool generating;
  final bool busy;
  final bool validRange;
  final bool futureRange;
  final AiRecapFailure? failure;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = this.result;
    final source = result == null ? status.selectedProvider : result.providerId;

    return Column(
      key: const Key('ai-diary-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Padding(
                padding: const EdgeInsets.all(7),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 19,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _diaryTitle(rangeKey.scope),
                    key: const Key('ai-diary-title'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$rangeLabel · ${_formatRange(rangeKey)}',
                    key: const Key('ai-recap-linked-range'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _GenerateButton(
              hasResult: result != null,
              generating: generating,
              busy: busy,
              onPressed: onGenerate,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: _SourceBadge(provider: source),
        ),
        if (generating) ...[
          const SizedBox(height: 10),
          Semantics(
            liveRegion: true,
            label: result == null ? '正在生成智能回顾' : '正在更新智能回顾，已有内容继续保留',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: const LinearProgressIndicator(
                key: Key('ai-recap-inline-progress'),
                minHeight: 5,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            result == null ? '正在整理这段时间的活动…' : '正在更新，当前内容继续保留。',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (failure case final value?) ...[
          const SizedBox(height: 10),
          _FailureNotice(failure: value),
        ],
        const SizedBox(height: 12),
        if (result case final value?)
          _RecapResult(result: value, isPreviousResult: isPreviousResult)
        else
          _EmptyRecap(
            generating: generating,
            validRange: validRange,
            futureRange: futureRange,
            status: status,
            hasFailure: failure != null,
          ),
      ],
    );
  }
}

class _GenerateButton extends StatelessWidget {
  const _GenerateButton({
    required this.hasResult,
    required this.generating,
    required this.busy,
    required this.onPressed,
  });

  final bool hasResult;
  final bool generating;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      key: const Key('ai-recap-generate'),
      onPressed: onPressed,
      icon: generating
          ? const SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              hasResult ? Icons.refresh_rounded : Icons.auto_awesome,
              size: 18,
            ),
      label: Text(
        generating
            ? '生成中'
            : busy
            ? '等待中'
            : hasResult
            ? '更新'
            : '生成',
      ),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      ),
    );
  }
}

class _RecapResult extends StatelessWidget {
  const _RecapResult({required this.result, required this.isPreviousResult});

  final AiRecapResult result;
  final bool isPreviousResult;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final topApplications = _topApplications(result);
    return SelectionArea(
      key: const Key('ai-recap-result'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isPreviousResult) ...[
            Row(
              children: [
                Icon(Icons.history_rounded, size: 16, color: scheme.tertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本期内容尚未生成，暂时保留 ${_formatRange(result.rangeKey)} 的回顾。',
                    key: const Key('ai-report-saved-fallback'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text(
            result.summary.text,
            key: const Key('ai-diary-summary'),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricChip(
                icon: Icons.schedule_rounded,
                label: _formatDuration(result.totalActiveSeconds),
              ),
              _MetricChip(
                icon: Icons.apps_rounded,
                label: '${result.applicationCount} 个应用',
              ),
            ],
          ),
          if (topApplications.isNotEmpty) ...[
            const SizedBox(height: 13),
            Text(
              '主要投入',
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            _TopApplicationBars(items: topApplications),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _TopApplicationBars extends StatelessWidget {
  const _TopApplicationBars({required this.items});

  final List<AiRecapEvidence> items;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = items.first.activeSeconds;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const Key('ai-diary-top-applications'),
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  items[index].appName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _formatCompactDuration(items[index].activeSeconds),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: maxSeconds <= 0
                      ? 0
                      : (items[index].activeSeconds / maxSeconds).clamp(
                          0.06,
                          1.0,
                        ),
                  child: SizedBox(
                    height: 5,
                    child: ColoredBox(color: scheme.primary),
                  ),
                ),
              ),
            ),
          ),
          if (index != items.length - 1) const SizedBox(height: 7),
        ],
      ],
    );
  }
}

class _EmptyRecap extends StatelessWidget {
  const _EmptyRecap({
    required this.generating,
    required this.validRange,
    required this.futureRange,
    required this.status,
    required this.hasFailure,
  });

  final bool generating;
  final bool validRange;
  final bool futureRange;
  final AiRecapProviderStatus status;
  final bool hasFailure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch ((
      generating,
      futureRange,
      validRange,
      status.serviceAvailable,
      status.ready,
      hasFailure,
    )) {
      (true, _, _, _, _, _) => '正在把这段时间整理成一份简洁回顾。',
      (_, true, _, _, _, _) => '未来日期还没有可供回顾的活动。',
      (_, _, false, _, _, _) => '当前日期范围暂时无法生成回顾。',
      (_, _, _, false, _, _) => '本地回顾服务暂时不可用，时间统计不受影响。',
      (_, _, _, _, false, _) => '请先在设置中完成智能回顾配置。',
      (_, _, _, _, _, true) => '本次没有生成新内容，你可以稍后重试。',
      _ => '还没有本期回顾，点击“生成”后会显示在这里。',
    };
    return DecoratedBox(
      key: const Key('ai-diary-empty'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(
              generating ? Icons.auto_awesome_motion : Icons.menu_book_outlined,
              color: scheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _FailureNotice extends StatelessWidget {
  const _FailureNotice({required this.failure});

  final AiRecapFailure failure;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      key: const Key('ai-recap-error'),
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _failureMessage(failure.code),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.provider});

  final AiRecapProviderId provider;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = provider == AiRecapProviderId.localSummary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: local
            ? scheme.secondaryContainer.withValues(alpha: 0.75)
            : scheme.tertiaryContainer.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              local ? Icons.computer_rounded : Icons.cloud_outlined,
              size: 15,
              color: local
                  ? scheme.onSecondaryContainer
                  : scheme.onTertiaryContainer,
            ),
            const SizedBox(width: 5),
            Text(
              local ? '本地回顾' : 'AI 生成 · DeepSeek',
              key: const Key('ai-diary-source'),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: local
                    ? scheme.onSecondaryContainer
                    : scheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiaryCover extends StatelessWidget {
  const _DiaryCover({
    required this.preferences,
    required this.rangeKey,
    required this.onNextBuiltIn,
  });

  final AiDiaryPreferences preferences;
  final AiRecapRangeKey rangeKey;
  final VoidCallback? onNextBuiltIn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cover = switch (preferences.coverSource) {
      AiDiaryCoverSource.builtIn => Image.asset(
        'assets/ai_diary/${preferences.builtInCoverId}.jpg',
        key: const Key('ai-diary-cover-image'),
        fit: BoxFit.cover,
        cacheWidth: 720,
        cacheHeight: 450,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stackTrace) => const _FallbackCover(),
      ),
      AiDiaryCoverSource.custom => _customCover(preferences.customCoverPath),
      AiDiaryCoverSource.none => const SizedBox.shrink(),
    };

    return AspectRatio(
      key: const Key('ai-diary-cover'),
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Semantics(image: true, label: '智能日记封面', child: cover),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x990B1020)],
                  stops: [0.46, 1],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 48,
              bottom: 10,
              child: Text(
                _coverDate(rangeKey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  shadows: const [Shadow(color: Colors.black45, blurRadius: 4)],
                ),
              ),
            ),
            if (onNextBuiltIn != null)
              Positioned(
                right: 8,
                bottom: 6,
                child: IconButton.filledTonal(
                  key: const Key('ai-diary-change-cover'),
                  tooltip: '换一张内置封面',
                  onPressed: onNextBuiltIn,
                  icon: const Icon(Icons.casino_outlined, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.surface.withValues(alpha: 0.86),
                    foregroundColor: scheme.onSurface,
                    minimumSize: const Size.square(36),
                    maximumSize: const Size.square(36),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _customCover(String? path) {
    if (path == null || path.isEmpty) return const _FallbackCover();
    return Image.file(
      File(path),
      key: const Key('ai-diary-cover-image'),
      fit: BoxFit.cover,
      cacheWidth: 720,
      cacheHeight: 450,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => const _FallbackCover(),
    );
  }
}

class _FallbackCover extends StatelessWidget {
  const _FallbackCover();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.auto_stories_outlined,
          size: 42,
          color: scheme.onPrimaryContainer.withValues(alpha: 0.72),
        ),
      ),
    );
  }
}

void _selectNextBuiltInCover(WidgetRef ref, AiDiaryPreferences preferences) {
  final ids = kAiDiaryBuiltInCoverIds.toList(growable: false);
  if (ids.isEmpty) return;
  final currentIndex = ids.indexOf(preferences.builtInCoverId);
  final nextIndex = currentIndex < 0 ? 0 : (currentIndex + 1) % ids.length;
  ref.read(aiDiaryPreferencesProvider.notifier).selectBuiltIn(ids[nextIndex]);
}

List<AiRecapEvidence> _topApplications(AiRecapResult result) {
  final byName = <String, AiRecapEvidence>{};
  for (final item in result.topApplications) {
    final existing = byName[item.appName];
    if (existing == null || item.activeSeconds > existing.activeSeconds) {
      byName[item.appName] = item;
    }
  }
  if (byName.isEmpty) {
    for (final statement in [
      result.summary,
      ...result.highlights,
      ...result.suggestions,
    ]) {
      for (final item in statement.evidence) {
        final existing = byName[item.appName];
        if (existing == null || item.activeSeconds > existing.activeSeconds) {
          byName[item.appName] = item;
        }
      }
    }
  }
  final values = byName.values.toList()
    ..sort((left, right) => right.activeSeconds.compareTo(left.activeSeconds));
  return values.take(3).toList(growable: false);
}

String _diaryTitle(AiRecapScope scope) => switch (scope) {
  AiRecapScope.daily => '智能日记',
  AiRecapScope.weekly => '智能周记',
  AiRecapScope.monthly => '智能月记',
  AiRecapScope.unsupported => '智能回顾',
};

String _failureMessage(AiRecapFailureCode code) => switch (code) {
  AiRecapFailureCode.notConfigured ||
  AiRecapFailureCode.providerNotReady => '生成方式还未配置完成，请在设置中检查。',
  AiRecapFailureCode.invalidRange => '当前日期范围暂时无法生成回顾。',
  AiRecapFailureCode.unsupportedProvider ||
  AiRecapFailureCode.unsupportedModel => '当前生成方式暂不受支持，请在设置中重新选择。',
  AiRecapFailureCode.connectionTestNotSupported => '当前生成方式不需要连接测试。',
  AiRecapFailureCode.noUsageData => '这段时间还没有足够的活动数据。',
  AiRecapFailureCode.requestTooLarge => '本次聚合数据超出安全上限，没有发送。',
  AiRecapFailureCode.network => '暂时无法连接服务，请检查网络后重试。',
  AiRecapFailureCode.timeout => '生成超时，已有内容仍然保留。',
  AiRecapFailureCode.authentication => 'API Key 未通过验证，请在设置中更新。',
  AiRecapFailureCode.rateLimited => '请求过于频繁，请稍后再试。',
  AiRecapFailureCode.providerUnavailable => '生成服务暂时不可用，请稍后再试。',
  AiRecapFailureCode.credentialStoreUnavailable => '系统凭据服务暂时不可用。',
  AiRecapFailureCode.localStorageUnavailable => '无法安全保存回顾，已有内容仍然保留。',
  AiRecapFailureCode.invalidResponse => '生成内容不完整，已有内容仍然保留。',
  AiRecapFailureCode.busy => '已有一份回顾正在生成。',
  AiRecapFailureCode.bridgeUnavailable => '本地回顾服务暂时不可用，请重启 TimeTrace。',
};

bool _isFutureRange(AiRecapRangeKey key, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return key.startDate.isAfter(today) || key.endDate.isAfter(today);
}

String _formatRange(AiRecapRangeKey key) {
  String date(DateTime value) => '${value.year}年${value.month}月${value.day}日';
  if (_sameDate(key.startDate, key.endDate)) return date(key.startDate);
  return '${date(key.startDate)}—${date(key.endDate)}';
}

String _coverDate(AiRecapRangeKey key) {
  if (_sameDate(key.startDate, key.endDate)) {
    return '${key.startDate.month}月${key.startDate.day}日';
  }
  return '${key.startDate.month}月${key.startDate.day}日 — '
      '${key.endDate.month}月${key.endDate.day}日';
}

bool _sameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

String _formatDuration(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  if (hours > 0 && minutes > 0) return '$hours 小时 $minutes 分钟';
  if (hours > 0) return '$hours 小时';
  if (minutes > 0) return '$minutes 分钟';
  return '$safeSeconds 秒';
}

String _formatCompactDuration(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  if (hours > 0) return minutes > 0 ? '$hours小时$minutes分' : '$hours小时';
  if (minutes > 0) return '$minutes分钟';
  return '$safeSeconds秒';
}
