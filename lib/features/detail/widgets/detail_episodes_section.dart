import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import '../../../domain/video.dart';
import '../../../shared/app_states.dart';
import '../detail_layout.dart';

/// 详情页「剧集」区块：排序切换、超过 100 集时按组折叠、
/// 手机用 Wrap 胶囊、平板用等宽网格（由 [DetailPageLayout] 决定）。
/// 纯展示组件；选中集/分组展开状态由详情页持有，经回调上抛。
class DetailEpisodesSection extends StatelessWidget {
  const DetailEpisodesSection({
    super.key,
    required this.video,
    required this.selected,
    required this.reversed,
    required this.expandedGroups,
    required this.layout,
    required this.onToggleReversed,
    required this.onToggleGroup,
    required this.onEpisodeTap,
  });

  /// 剧集超过该数量时按每组 100 集折叠展示。
  static const int groupSize = 100;

  final Video video;
  final int selected;
  final bool reversed;
  final Set<int> expandedGroups;
  final DetailPageLayout layout;
  final VoidCallback onToggleReversed;
  final void Function(int group) onToggleGroup;
  final void Function(int index) onEpisodeTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '剧集',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${video.episodes.length} 集',
              style: TextStyle(color: context.appColors.secondary),
            ),
            if (video.episodes.length > 1)
              TextButton.icon(
                onPressed: onToggleReversed,
                style: TextButton.styleFrom(
                  foregroundColor: context.appColors.secondary,
                ),
                icon: Icon(Icons.swap_vert, size: 18),
                label: Text(reversed ? '正序' : '倒序'),
              ),
          ],
        ),
        SizedBox(height: 12),
        if (video.episodes.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: AppEmptyView(message: '暂时没有可用剧集'),
          )
        else if (video.episodes.length <= groupSize)
          _epsWrap(context, video, 0, video.episodes.length)
        else
          _epsGroups(context, video),
      ],
    );
  }

  /// 超过 100 集时按 100 集一组折叠展示，默认只展开选中集所在分组。
  Widget _epsGroups(BuildContext context, Video video) {
    final total = video.episodes.length;
    final groupCount = (total + groupSize - 1) ~/ groupSize;
    return Column(
      children: [
        for (var g = 0; g < groupCount; g++) ...[
          _epsGroupHeader(context, total, g),
          if (expandedGroups.contains(g))
            Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: _epsWrap(
                context,
                video,
                g * groupSize,
                math.min((g + 1) * groupSize, total),
              ),
            ),
        ],
      ],
    );
  }

  Widget _epsGroupHeader(BuildContext context, int total, int group) {
    final start = group * groupSize;
    final end = math.min(start + groupSize, total);
    // 显示顺序对应的实际集号范围（倒序时组内集号从大到小）。
    final first = reversed ? total - start : start + 1;
    final last = reversed ? total - end + 1 : end;
    final lo = math.min(first, last);
    final hi = math.max(first, last);
    final isExpanded = expandedGroups.contains(group);
    return InkWell(
      onTap: () => onToggleGroup(group),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '第 $lo–$hi 集',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.appColors.secondary,
                ),
              ),
            ),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: context.appColors.secondary,
            ),
          ],
        ),
      ),
    );
  }

  /// 渲染显示顺序区间 [start, end) 内的剧集按钮。
  Widget _epsWrap(BuildContext context, Video video, int start, int end) {
    final total = video.episodes.length;
    final items = [
      for (var i = 0; i < end - start; i++)
        _episodeChip(
          context,
          video,
          reversed ? total - 1 - (start + i) : start + i,
        ),
    ];
    if (!layout.useEpisodeGrid) {
      return Wrap(spacing: 8, runSpacing: 8, children: items);
    }
    return GridView.count(
      crossAxisCount: layout.episodeColumns,
      shrinkWrap: true,
      physics: NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: layout.episodeAspectRatio,
      children: items,
    );
  }

  Widget _episodeChip(BuildContext context, Video video, int idx) {
    final episode = video.episodes[idx];
    final isSelected = selected == idx;
    if (!layout.useEpisodeGrid) {
      return ChoiceChip(
        label: Text(episode.name),
        selected: isSelected,
        selectedColor: context.appColors.accent,
        labelStyle: TextStyle(
          color: isSelected
              ? context.appColors.onAccent
              : context.appColors.secondary,
        ),
        showCheckmark: false,
        onSelected: (_) => onEpisodeTap(idx),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: StadiumBorder(),
        onTap: () => onEpisodeTap(idx),
        child: Ink(
          decoration: ShapeDecoration(
            color: isSelected
                ? context.appColors.accent
                : context.appColors.elevated.withValues(alpha: 0.6),
            shape: StadiumBorder(
              side: isSelected
                  ? BorderSide.none
                  : BorderSide(color: context.appColors.divider),
            ),
          ),
          child: Center(
            child: Text(
              episode.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected
                    ? context.appColors.onAccent
                    : context.appColors.secondary,
                fontSize: 15,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
