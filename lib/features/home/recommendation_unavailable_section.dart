import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/tmdb_catalog.dart';
import 'recommended_feed_controller.dart';

class RecommendationUnavailableSection extends StatelessWidget {
  const RecommendationUnavailableSection({
    super.key,
    required this.slots,
    required this.playableCount,
    required this.onTap,
    this.searchingIds = const {},
  });

  final List<RecommendedCandidateSlot> slots;
  final int playableCount;
  final ValueChanged<RecommendedCandidateSlot> onTap;
  final Set<String> searchingIds;

  @override
  Widget build(BuildContext context) {
    final ambiguous = slots
        .where((slot) => slot.status == RecommendedCandidateStatus.ambiguous)
        .length;
    final notFound = slots
        .where((slot) => slot.status == RecommendedCandidateStatus.notFound)
        .length;
    final failed = slots
        .where((slot) => slot.status == RecommendedCandidateStatus.failed)
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.appColors.elevated.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const ValueKey('recommendation-unavailable-section'),
            initiallyExpanded: playableCount == 0 || slots.length <= 4,
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            title: Text('${slots.length} 部需要手动确认'),
            subtitle: Text(
              [
                if (ambiguous > 0) '有歧义 $ambiguous',
                if (notFound > 0) '未找到 $notFound',
                if (failed > 0) '失败 $failed',
              ].join(' · '),
              style: TextStyle(color: context.appColors.secondary),
            ),
            children: [
              GridView.builder(
                primary: false,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: slots.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: MediaQuery.sizeOf(context).width >= 700
                      ? 4
                      : 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.62,
                ),
                itemBuilder: (context, index) {
                  final slot = slots[index];
                  final searching = searchingIds.contains(
                    slot.candidate.identity,
                  );
                  return _RecommendationUnavailableCard(
                    slot: slot,
                    searching: searching,
                    onTap: () => onTap(slot),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecommendationUnavailableCard extends StatelessWidget {
  const _RecommendationUnavailableCard({
    required this.slot,
    required this.searching,
    required this.onTap,
  });

  final RecommendedCandidateSlot slot;
  final bool searching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final candidate = slot.candidate;
    return Semantics(
      button: true,
      label: '手动确认 ${candidate.title}',
      child: InkWell(
        key: ValueKey('recommendation-unavailable-${candidate.identity}'),
        borderRadius: BorderRadius.circular(12),
        onTap: searching ? null : onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: context.appColors.surface,
                      child: Icon(
                        Icons.movie_outlined,
                        size: 44,
                        color: context.appColors.tertiary,
                      ),
                    ),
                    Positioned(
                      left: 7,
                      right: 7,
                      bottom: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.76),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 4,
                          ),
                          child: Text(
                            searching ? '正在查找…' : _statusLabel(slot),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (searching)
                      const Center(child: CircularProgressIndicator()),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              candidate.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              [
                candidate.mediaType == TmdbMediaType.movie ? '电影' : '剧集',
                if (candidate.year.isNotEmpty) candidate.year,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.appColors.secondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(RecommendedCandidateSlot slot) => switch (slot.status) {
  RecommendedCandidateStatus.ambiguous => '有 ${slot.rawResultCount} 条结果，点击确认',
  RecommendedCandidateStatus.notFound => '当前来源无结果',
  RecommendedCandidateStatus.failed => '搜索失败，点击处理',
  _ => '需要手动确认',
};
