import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../app/theme.dart';
import '../../../data/library_repository.dart';
import '../../../domain/video.dart';
import '../../../shared/app_anchored_menu.dart';
import '../../../shared/app_toast.dart';

enum _RelationshipAction { follow, favorite, stopFollowing, remove }

/// 详情页追更/收藏按钮：支持追更的来源弹出锚定菜单（追更/收藏/取消），
/// 其余来源直接切换收藏状态。全部通过 favoriteControllerProvider 持久化。
class DetailRelationshipButton extends ConsumerStatefulWidget {
  const DetailRelationshipButton({
    super.key,
    required this.video,
    required this.isTablet,
  });

  final Video video;
  final bool isTablet;

  @override
  ConsumerState<DetailRelationshipButton> createState() =>
      _DetailRelationshipButtonState();
}

class _DetailRelationshipButtonState
    extends ConsumerState<DetailRelationshipButton> {
  Video get video => widget.video;

  @override
  Widget build(BuildContext context) {
    final favs = ref.watch(favoriteControllerProvider);
    final record = favs.value
        ?.where((item) => item.video.globalId == video.globalId)
        .firstOrNull;
    final favorite = record?.isFavorite ?? false;
    final following = record?.isFollowing ?? false;
    final supportsFollow = video.supportsFollowUpdates;
    final label = following
        ? '已追更'
        : supportsFollow
        ? (favorite ? '已收藏' : '追更')
        : (favorite ? '已收藏' : '收藏');
    final icon = following
        ? Icons.check
        : supportsFollow && !favorite
        ? Icons.add
        : favorite
        ? Icons.favorite
        : Icons.favorite_outline;
    if (supportsFollow) {
      return _menuButton(
        context,
        label: label,
        icon: icon,
        favorite: favorite,
        following: following,
        isLoading: favs.isLoading,
      );
    }
    return SizedBox(
      key: const ValueKey('detail-relationship-button'),
      width: 96,
      height: 48,
      child: OutlinedButton.icon(
        onPressed: favs.isLoading
            ? null
            : () async {
                try {
                  final controller = ref.read(
                    favoriteControllerProvider.notifier,
                  );
                  await controller.toggle(video);
                  if (mounted) {
                    showAppToast(this.context, favorite ? '已取消收藏' : '已收藏');
                  }
                } catch (_) {
                  if (mounted) {
                    showAppToast(this.context, '保存失败，请重试');
                  }
                }
              },
        style: OutlinedButton.styleFrom(
          foregroundColor: context.appColors.text,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        icon: Icon(icon, size: 18),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(label, maxLines: 1, softWrap: false),
        ),
      ),
    );
  }

  Widget _menuButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool favorite,
    required bool following,
    required bool isLoading,
  }) => SizedBox(
    key: const ValueKey('detail-relationship-button'),
    width: widget.isTablet ? 200 : 176,
    height: 48,
    child: Builder(
      builder: (anchorContext) => OutlinedButton.icon(
        onPressed: isLoading
            ? null
            : () => _openMenu(
                anchorContext,
                favorite: favorite,
                following: following,
              ),
        style: OutlinedButton.styleFrom(
          foregroundColor: anchorContext.appColors.text,
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        icon: Icon(icon, size: 18),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, maxLines: 1, softWrap: false),
              const SizedBox(width: 2),
              const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _openMenu(
    BuildContext anchorContext, {
    required bool favorite,
    required bool following,
  }) async {
    final action = await showAppAnchoredMenu<_RelationshipAction>(
      anchorContext: anchorContext,
      matchAnchorWidth: true,
      maxWidth: 280,
      builder: (menuContext) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (following) ...[
              AppAnchoredMenuItem(
                key: const ValueKey('detail-follow-menu-stop'),
                icon: Icons.notifications_off_outlined,
                title: '取消追更',
                subtitle: '停止新集提醒，保留收藏',
                onTap: () => Navigator.pop(
                  menuContext,
                  _RelationshipAction.stopFollowing,
                ),
              ),
              AppAnchoredMenuItem(
                key: const ValueKey('detail-follow-menu-remove'),
                icon: Icons.delete_outline,
                title: '取消追更并移除',
                subtitle: '同时从个人内容库移除',
                onTap: () =>
                    Navigator.pop(menuContext, _RelationshipAction.remove),
              ),
            ] else ...[
              AppAnchoredMenuItem(
                key: const ValueKey('detail-follow-menu-follow'),
                icon: Icons.add_alert_outlined,
                title: favorite ? '开启追更' : '追更并收藏',
                subtitle: '有新集时提醒',
                onTap: () =>
                    Navigator.pop(menuContext, _RelationshipAction.follow),
              ),
              AppAnchoredMenuItem(
                key: const ValueKey('detail-follow-menu-favorite'),
                icon: favorite ? Icons.delete_outline : Icons.favorite_outline,
                title: favorite ? '取消收藏' : '仅收藏',
                subtitle: favorite ? '从个人内容库移除' : '保存但不提醒',
                onTap: () => Navigator.pop(
                  menuContext,
                  favorite
                      ? _RelationshipAction.remove
                      : _RelationshipAction.favorite,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (action != null) {
      await _saveAction(action: action);
    }
  }

  Future<void> _saveAction({required _RelationshipAction action}) async {
    try {
      final controller = ref.read(favoriteControllerProvider.notifier);
      switch (action) {
        case _RelationshipAction.follow:
          await controller.follow(video);
          if (mounted) showAppToast(context, '已追更，有新集时会提醒你');
          return;
        case _RelationshipAction.favorite:
          await controller.toggle(video);
          if (mounted) showAppToast(context, '已收藏');
          return;
        case _RelationshipAction.stopFollowing:
          await controller.stopFollowing(video.globalId, keepFavorite: true);
          if (mounted) showAppToast(context, '已取消追更，收藏仍保留');
          return;
        case _RelationshipAction.remove:
          final wasFollowing = ref
              .read(favoriteControllerProvider)
              .value
              ?.where((item) => item.video.globalId == video.globalId)
              .firstOrNull
              ?.isFollowing;
          await controller.stopFollowing(video.globalId, keepFavorite: false);
          if (mounted) {
            showAppToast(
              context,
              wasFollowing == true ? '已取消追更并移除收藏' : '已取消收藏',
            );
          }
          return;
      }
    } catch (_) {
      if (mounted) {
        showAppToast(context, '保存失败，请重试');
      }
    }
  }
}
