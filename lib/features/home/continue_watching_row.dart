import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/history_repository.dart';
import '../../domain/watch_record.dart';
import '../player/resume_watch.dart';

/// 本进程内隐藏首页续播条：点关闭或打开其他影片后不再出现，直到 App 重启。
class ContinueWatchingSessionHidden extends Notifier<bool> {
  @override
  bool build() => false;

  void hide() => state = true;
}

final continueWatchingSessionHiddenProvider =
    NotifierProvider<ContinueWatchingSessionHidden, bool>(
      ContinueWatchingSessionHidden.new,
    );

class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(continueWatchingSessionHiddenProvider);
    final record = hidden
        ? null
        : homeContinueWatchingRecord(
            ref.watch(watchHistoryProvider).value ?? [],
          );
    return AnimatedSize(
      duration: Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: record == null
          ? SizedBox(width: double.infinity)
          : Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: _ContinueWatchingBar(record: record),
            ),
    );
  }
}

class _ContinueWatchingBar extends ConsumerWidget {
  const _ContinueWatchingBar({required this.record});

  final WatchRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FocusableActionDetector(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            resumeWatchRecord(context: context, ref: ref, record: record);
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        label: '继续观看 ${record.video.title}',
        child: Material(
          color: context.appColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: context.appColors.divider.withValues(alpha: 0.8),
            ),
          ),
          child: InkWell(
            key: ValueKey('continue-watching-bar'),
            borderRadius: BorderRadius.circular(12),
            onTap: () =>
                resumeWatchRecord(context: context, ref: ref, record: record),
            child: SizedBox(
              height: 72,
              child: Row(
                children: [
                  SizedBox(width: 4),
                  _Poster(url: record.video.posterUrl),
                  SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            record.video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            record.resumeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.appColors.secondary,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          ),
                          Spacer(),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(1),
                            child: LinearProgressIndicator(
                              value: record.progress.clamp(0.0, 1.0),
                              minHeight: 3,
                              backgroundColor: context.appColors.divider,
                              color: context.appColors.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    key: ValueKey('continue-watching-dismiss'),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref
                        .read(continueWatchingSessionHiddenProvider.notifier)
                        .hide(),
                    icon: Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 64,
        child: ColoredBox(
          color: context.appColors.elevated,
          child: url.isEmpty
              ? Icon(
                  Icons.movie_outlined,
                  size: 22,
                  color: context.appColors.tertiary,
                )
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      ColoredBox(color: context.appColors.surface),
                  errorWidget: (_, _, _) => Icon(
                    Icons.movie_outlined,
                    size: 22,
                    color: context.appColors.tertiary,
                  ),
                ),
        ),
      ),
    );
  }
}
