import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/material/material.dart';
import '../../../core/widgets/context_help.dart';
import '../../calendar/providers/calendar_data_provider.dart';
import '../../dashboard/domain/dashboard_state.dart';
import '../../dashboard/providers/dashboard_provider.dart';
import '../domain/diary_candidate.dart';
import '../domain/local_recap.dart';
import '../providers/ai_connection_provider.dart';
import '../providers/diary_generation_provider.dart';

class RecapButton extends ConsumerStatefulWidget {
  const RecapButton({super.key});
  @override
  ConsumerState<RecapButton> createState() => _RecapButtonState();
}

class _RecapButtonState extends ConsumerState<RecapButton> {
  String? _expandedCandidateId;

  Future<void> _confirmAndGenerate(DashboardState state) async {
    final start = state.requestedStartUtc;
    final end = state.requestedEndUtc;
    final date = calFmt(DateTime.parse(start).toLocal());
    final summary = aiDiaryFacts(state);
    final capture = MaterialOverlayCapture.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: MaterialTransientPanel(
          capture: capture,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '发送摘要给 AI 服务？',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: MaterialTokens.spaceMd),
              const Text(
                '发送应用名称、使用时长、最多 48 个有活动小时的时间分布和缺失记录提示。不发送窗口标题、日记或原始记录。调用将消耗你的 API 额度。',
              ),
              const SizedBox(height: MaterialTokens.spaceMd),
              Wrap(
                spacing: MaterialTokens.spaceSm,
                children: [
                  MaterialActionButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  MaterialActionButton(
                    role: MaterialActionRole.primary,
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('生成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    unawaited(
      ref
          .read(diaryGenerationProvider.notifier)
          .start(
            startUtc: start,
            endUtc: end,
            saveDate: date,
            summary: summary,
            key: ref.read(deepSeekKeyProvider),
            model: ref.read(deepSeekModelProvider),
          ),
    );
  }

  Future<void> _save(String id) async {
    final status = await ref.read(diarySaveProvider.notifier).saveCandidate(id);
    if (!mounted) return;
    final message = switch (status) {
      DiarySaveStatus.saved => '已保存到日记',
      DiarySaveStatus.awaitingVerification => '已写入，待核对保存',
      DiarySaveStatus.writeFailed => '保存失败，内容已保留，可重试',
      DiarySaveStatus.resultUnknown => '保存结果不明，请在日记中人工核对',
    };
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final capture = MaterialOverlayCapture.of(context);
    final snapshot = ref.watch(dashboardProvider);
    final generation = ref.watch(diaryGenerationProvider);
    final assets = ref.watch(diaryCandidatesProvider);
    final receipts = ref.watch(diarySaveProvider);
    final candidates = assets.ordered;
    final keyAvailable =
        ref.watch(deepSeekKeyProvider).isNotEmpty &&
        ref.watch(aiEnabledProvider);
    final markdownStyle = MarkdownStyleSheet.fromTheme(theme).copyWith(
      h1: theme.textTheme.titleMedium,
      h2: theme.textTheme.titleSmall,
      h3: theme.textTheme.titleSmall,
      blockSpacing: MaterialTokens.spaceSm,
    );
    return MenuAnchor(
      alignmentOffset: const Offset(-300, 8),
      style: materialMenuStyle,
      menuChildren: [
        MaterialTransientPanel(
          capture: capture,
          scrollable: false,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: max(
              MaterialTokens.minimumTarget,
              min(
                320.0,
                MediaQuery.sizeOf(context).width - MaterialTokens.spaceXxl,
              ),
            ),
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: CustomScrollView(
              primary: false,
              key: const Key('recap_candidates_scroll'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(MaterialTokens.workRadius),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '日记候选',
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            const ContextHelp(
                              message:
                                  '本地整理不联网。AI 生成发送应用、时长与最多 48 个小时的时间分布，发送前由你确认。候选保留在本机，选中后才保存为日记，不覆盖手写草稿。',
                            ),
                          ],
                        ),
                        const SizedBox(height: MaterialTokens.spaceSm),
                        snapshot.when(
                          skipLoadingOnReload: false,
                          data: (state) => Wrap(
                            spacing: MaterialTokens.spaceSm,
                            children: [
                              TextButton(
                                key: const Key('recap_generate_local'),
                                onPressed: () {
                                  ref
                                      .read(diaryCandidatesProvider.notifier)
                                      .add(
                                        source: DiaryCandidateSource.local,
                                        startUtc: state.requestedStartUtc,
                                        endUtc: state.requestedEndUtc,
                                        saveDate: calFmt(
                                          DateTime.parse(
                                            state.requestedStartUtc,
                                          ).toLocal(),
                                        ),
                                        content: programmaticDiary(state),
                                      );
                                },
                                child: const Text('本地整理'),
                              ),
                              TextButton(
                                key: const Key('recap_generate_ai'),
                                onPressed: !keyAvailable || generation.isPending
                                    ? null
                                    : () => _confirmAndGenerate(state),
                                child: Text(
                                  generation.status ==
                                          DiaryGenerationStatus.error
                                      ? '重试 AI 生成'
                                      : 'AI 生成',
                                ),
                              ),
                            ],
                          ),
                          loading: () => const Text('正在读取所选范围…'),
                          error: (_, _) => const Text('本地数据暂时不可用，请刷新后重试。'),
                        ),
                        if (!keyAvailable) ...[
                          const Text('尚未接入 AI'),
                          TextButton(
                            key: const Key('recap_open_settings'),
                            onPressed: () =>
                                context.push('/settings?section=recap'),
                            child: const Text('前往 AI 设置'),
                          ),
                        ],
                        if (generation.isPending ||
                            generation.status ==
                                DiaryGenerationStatus.error) ...[
                          Text(
                            generation.rangeLabel,
                            key: const Key('recap_request_range'),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: MaterialTokens.spaceSm),
                        ],
                        if (generation.isPending)
                          Semantics(
                            liveRegion: true,
                            label: 'AI 日记生成中',
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text('生成中'),
                                SizedBox(height: MaterialTokens.spaceSm),
                                LinearProgressIndicator(
                                  key: Key('recap_pending_progress'),
                                ),
                              ],
                            ),
                          ),
                        if (generation.status == DiaryGenerationStatus.error)
                          Text(
                            generation.error!,
                            key: const Key('recap_generation_error'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        if (assets.loading) const Text('正在读取候选…'),
                        if (assets.loadError != null) ...[
                          Text(
                            assets.loadError!,
                            style: theme.textTheme.bodySmall,
                          ),
                          TextButton(
                            key: const Key('recap_retry_history'),
                            onPressed: () => unawaited(
                              ref.read(diaryCandidatesProvider.notifier).load(),
                            ),
                            child: const Text('重试读取历史'),
                          ),
                        ],
                        if (assets.hasRecoveryIssue) const Text('部分历史需要核对'),
                        if (!assets.loading && candidates.isEmpty)
                          const Text('还没有候选，选择本地整理或 AI 生成'),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MaterialTokens.workRadius,
                  ),
                  sliver: SliverList.builder(
                    itemCount: candidates.length,
                    itemBuilder: (context, index) {
                      final candidate = candidates[index];
                      final expanded = _expandedCandidateId == candidate.id;
                      final saving = receipts[candidate.id]?.saving == true;
                      final saved =
                          candidate.publishStatus ==
                          CandidatePublishStatus.saved;
                      final check =
                          candidate.entryId != null ||
                          candidate.publishStatus ==
                              CandidatePublishStatus.appendIntent ||
                          candidate.publishStatus ==
                              CandidatePublishStatus.unknown ||
                          candidate.recoveryBlocked;
                      return Column(
                        key: ValueKey('recap_candidate_${candidate.id}'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextButton(
                            key: ValueKey(
                              'recap_candidate_toggle_${candidate.id}',
                            ),
                            onPressed: () => setState(() {
                              _expandedCandidateId = expanded
                                  ? null
                                  : candidate.id;
                            }),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${candidate.sourceLabel} · ${candidate.rangeLabel}',
                                  ),
                                ),
                                Icon(
                                  expanded
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            candidate.timeLabel,
                            style: theme.textTheme.bodySmall,
                          ),
                          if (saved) const Text('已保存'),
                          if (!saved && check)
                            Text(
                              candidate.entryId == null
                                  ? '保存结果待人工核对'
                                  : '已写入，待核对保存',
                            ),
                          if (!candidate.persisted ||
                              candidate.storageError != null) ...[
                            Text(
                              candidate.storageError ?? '尚未保留到本机',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.error,
                              ),
                            ),
                            TextButton(
                              key: ValueKey(
                                'recap_candidate_retry_${candidate.id}',
                              ),
                              onPressed: () => unawaited(
                                ref
                                    .read(diaryCandidatesProvider.notifier)
                                    .persist(candidate.id),
                              ),
                              child: const Text('重试保留'),
                            ),
                          ],
                          if (expanded) ...[
                            const SizedBox(height: MaterialTokens.spaceSm),
                            MarkdownBody(
                              data: candidate.content,
                              selectable: true,
                              styleSheet: markdownStyle,
                              sizedImageBuilder: (_) => const SizedBox.shrink(),
                            ),
                            FilledButton.tonal(
                              key: ValueKey(
                                'recap_candidate_save_${candidate.id}',
                              ),
                              onPressed: saved || saving
                                  ? null
                                  : () => _save(candidate.id),
                              child: Text(
                                saving ? '保存中' : (check ? '核对保存' : '保存为日记'),
                              ),
                            ),
                          ],
                          const SizedBox(height: MaterialTokens.spaceMd),
                          const Divider(),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, _) => Semantics(
        label: generation.isPending ? 'AI 日记生成中' : '日记候选',
        child: MaterialIconAction(
          buttonKey: const Key('workspace_recap'),
          tooltip: generation.isPending ? 'AI 日记生成中，点击查看进度' : '日记候选',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              setState(() => _expandedCandidateId = null);
              controller.open();
            }
          },
          icon: generation.isPending
              ? const SizedBox.square(
                  dimension: MaterialTokens.spaceLg,
                  child: CircularProgressIndicator(
                    key: Key('recap_entry_pending'),
                    strokeWidth: MaterialTokens.borderWidth,
                  ),
                )
              : const Icon(Icons.auto_awesome_outlined, size: 18),
        ),
      ),
    );
  }
}
