import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../domain/tmdb_catalog.dart';
import 'curated_feed_controller.dart';

class CuratedUnavailableSection extends StatelessWidget {
  const CuratedUnavailableSection({
    super.key,
    required this.entries,
    required this.onSearch,
    this.searchingIds = const {},
    this.failedCount = 0,
    this.hasMore = false,
  });

  final List<CuratedFeedEntry> entries;
  final ValueChanged<CuratedFeedEntry> onSearch;
  final Set<String> searchingIds;
  final int failedCount;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    final withResults = entries
        .where((entry) => entry.rawResultCount > 0)
        .length;
    final withoutResults = entries.length - withResults;
    final title = switch ((withResults, withoutResults)) {
      (> 0, 0) => '当前来源有结果但无法确认 $withResults 部',
      (0, > 0) => '当前来源无结果 $withoutResults 部',
      _ => '${entries.length} 部需要进一步确认',
    };
    final subtitle = withResults > 0 && withoutResults > 0
        ? '有结果但无法确认 $withResults 部 · 无结果 $withoutResults 部'
        : '查看详情或继续查找其他来源';
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
            key: const ValueKey('curated-unavailable-section'),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            title: Text(title),
            subtitle: Text(
              subtitle,
              style: TextStyle(color: context.appColors.secondary),
            ),
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: entries.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: MediaQuery.sizeOf(context).width >= 700
                      ? 4
                      : 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.62,
                ),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final item = entry.catalogItem;
                  return _UnavailableCard(
                    item: item,
                    rawResultCount: entry.rawResultCount,
                    searching: searchingIds.contains(item.globalId),
                    onTap: () => onSearch(entry),
                  );
                },
              ),
              if (failedCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Text(
                    '另有 $failedCount 部当前来源请求失败，下拉刷新后重试',
                    style: TextStyle(
                      color: context.appColors.secondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (hasMore)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    '继续下滑可检索更多榜单影片',
                    style: TextStyle(
                      color: context.appColors.tertiary,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnavailableCard extends StatelessWidget {
  const _UnavailableCard({
    required this.item,
    required this.rawResultCount,
    required this.searching,
    required this.onTap,
  });

  final TmdbCatalogItem item;
  final int rawResultCount;
  final bool searching;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '查看匹配详情 ${item.localizedTitle}',
    child: InkWell(
      key: ValueKey('curated-unavailable-${item.globalId}'),
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
                    child: item.posterUrl.isEmpty
                        ? Icon(
                            Icons.movie_outlined,
                            color: context.appColors.tertiary,
                          )
                        : CachedNetworkImage(
                            imageUrl: item.posterUrl,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => Icon(
                              Icons.movie_outlined,
                              color: context.appColors.tertiary,
                            ),
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
                          searching
                              ? '正在查找…'
                              : rawResultCount > 0
                              ? '有 $rawResultCount 条结果，点击确认'
                              : '当前来源无结果',
                          textAlign: TextAlign.center,
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
            item.localizedTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            [
              item.mediaType == TmdbMediaType.movie ? '电影' : '剧集',
              if (item.releaseDate.length >= 4)
                item.releaseDate.substring(0, 4),
            ].join(' · '),
            style: TextStyle(color: context.appColors.secondary, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
