import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../app/theme.dart';
import '../../../data/download/download_task_manager.dart';
import '../../../domain/playback_status.dart';
import '../../../domain/video.dart';
import '../../../shared/playback_scrubber.dart';
import 'playback_status_indicator.dart';

/// 播放器底部控制条：进度 scrubber、播放/暂停、上下集、音量、
/// 播放状态指示、下载、倍速、选集、铺满与全屏按钮。
/// 状态全部由宿主页面通过参数/回调传入。
class PlayerControlsBar extends StatelessWidget {
  const PlayerControlsBar({
    super.key,
    required this.controller,
    required this.previewPosition,
    required this.seekClock,
    required this.seekCommitting,
    required this.controlsVisible,
    required this.failed,
    required this.fullScreen,
    required this.overlayLayout,
    required this.compactControls,
    required this.showEpisodeNav,
    required this.fillScreen,
    required this.isPortraitVideo,
    required this.playbackStatus,
    required this.playbackSpeed,
    required this.downloadStatus,
    required this.episodes,
    required this.isCurrentEpisode,
    required this.onShowControls,
    required this.onTogglePlayback,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.onVolumeButton,
    required this.onVolumeLongPress,
    required this.onDownload,
    required this.onSpeedSelected,
    required this.onStatusLongPress,
    required this.onEpisodeMenuOpened,
    required this.onEpisodeMenuCanceled,
    required this.onEpisodeSelected,
    required this.onFillScreenToggle,
    required this.onFullScreenToggle,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onSeekCancel,
    this.episodeMenuKey,
    this.speedMenuKey,
  });

  final VideoPlayerController controller;
  final ValueNotifier<Duration?> previewPosition;

  /// 拖动/提交期间冻结的时长；为 null 时回退到播放器 duration。
  final ValueNotifier<Duration?> seekClock;
  final ValueNotifier<bool> seekCommitting;
  final bool controlsVisible;
  final bool failed;
  final bool fullScreen;
  final bool overlayLayout;
  final bool compactControls;
  final bool showEpisodeNav;
  final bool fillScreen;
  final bool isPortraitVideo;
  final PlaybackStatus playbackStatus;
  final double playbackSpeed;

  /// 当前剧集的下载状态；为 null 表示未下载。
  final DownloadTaskStatus? downloadStatus;

  /// 选集菜单展示的剧集（当前线路）。
  final List<Episode> episodes;

  /// 判断菜单项是否为当前播放剧集。
  final bool Function(Episode episode) isCurrentEpisode;

  final VoidCallback onShowControls;
  final VoidCallback onTogglePlayback;

  /// 上一集/下一集按钮回调；为 null 时按钮禁用。
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;

  final VoidCallback onVolumeButton;
  final VoidCallback onVolumeLongPress;

  /// 下载按钮回调；已完成下载时为 null（按钮禁用）。
  final VoidCallback? onDownload;
  final ValueChanged<double> onSpeedSelected;
  final VoidCallback onStatusLongPress;
  final VoidCallback onEpisodeMenuOpened;
  final VoidCallback onEpisodeMenuCanceled;
  final ValueChanged<Episode> onEpisodeSelected;
  final VoidCallback onFillScreenToggle;
  final VoidCallback onFullScreenToggle;
  final ValueChanged<Duration> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;
  final VoidCallback onSeekCancel;

  /// 选集/倍速菜单按钮的 GlobalKey，供遥控器菜单键程序化打开菜单；
  /// 按钮在测试中仍通过原 ValueKey 定位。
  final GlobalKey<PopupMenuButtonState<Episode>>? episodeMenuKey;
  final GlobalKey<PopupMenuButtonState<double>>? speedMenuKey;

  @override
  Widget build(BuildContext context) {
    // 控制条隐藏时不允许焦点遍历进入其中的按钮，
    // 避免遥控器焦点落在不可见控件上。
    return ExcludeFocus(
      excluding: !controlsVisible,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          left: false,
          right: false,
          bottom: false,
          child: AnimatedOpacity(
            opacity: controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !controlsVisible,
              child: Listener(
                onPointerDown: (_) => onShowControls(),
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xCC000000)],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: AnimatedBuilder(
                      animation: Listenable.merge([
                        controller,
                        previewPosition,
                        seekClock,
                        seekCommitting,
                      ]),
                      builder: (_, _) {
                        final clock =
                            seekClock.value ?? controller.value.duration;
                        final timeAboveScrubber =
                            fullScreen &&
                            MediaQuery.orientationOf(context) ==
                                Orientation.portrait;
                        final positionLabel = Text(
                          key: const ValueKey('player-position-label'),
                          '${formatPlaybackTime(previewPosition.value ?? controller.value.position)} / ${formatPlaybackTime(clock)}',
                          maxLines: 1,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        );
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (timeAboveScrubber)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  0,
                                ),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: positionLabel,
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: PlaybackScrubber(
                                position:
                                    previewPosition.value ??
                                    controller.value.position,
                                duration: clock,
                                buffered: [
                                  for (final range in controller.value.buffered)
                                    (start: range.start, end: range.end),
                                ],
                                enabled:
                                    !failed &&
                                    controller.value.isInitialized &&
                                    controller.value.duration > Duration.zero &&
                                    !seekCommitting.value,
                                committing: seekCommitting.value,
                                showTime: false,
                                onSeekStart: onSeekStart,
                                onSeekUpdate: onSeekUpdate,
                                onSeekEnd: onSeekEnd,
                                onSeekCancel: onSeekCancel,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                              child: Row(
                                children: [
                                  if (showEpisodeNav)
                                    IconButton(
                                      key: const ValueKey(
                                        'player-previous-episode',
                                      ),
                                      tooltip: '上一集',
                                      onPressed: onPreviousEpisode,
                                      icon: const Icon(Icons.skip_previous),
                                    ),
                                  IconButton(
                                    onPressed: onTogglePlayback,
                                    tooltip: controller.value.isPlaying
                                        ? '暂停'
                                        : controller.value.isCompleted
                                        ? '重新播放'
                                        : '播放',
                                    iconSize: 30,
                                    icon: Icon(
                                      controller.value.isPlaying
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                    ),
                                  ),
                                  if (showEpisodeNav)
                                    IconButton(
                                      key: const ValueKey(
                                        'player-next-episode',
                                      ),
                                      tooltip: '下一集',
                                      onPressed: onNextEpisode,
                                      icon: const Icon(Icons.skip_next),
                                    ),
                                  if (!compactControls)
                                    IconButton(
                                      onPressed: onVolumeButton,
                                      onLongPress: onVolumeLongPress,
                                      tooltip: '音量（长按静音）',
                                      icon: Icon(
                                        controller.value.volume > 0.5
                                            ? Icons.volume_up
                                            : controller.value.volume > 0
                                            ? Icons.volume_down
                                            : Icons.volume_off,
                                      ),
                                    ),
                                  if (timeAboveScrubber)
                                    const Spacer()
                                  else
                                    Expanded(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: positionLabel,
                                      ),
                                    ),
                                  const SizedBox(width: 6),
                                  PlaybackStatusIndicator(
                                    key: const ValueKey(
                                      'playback-status-indicator',
                                    ),
                                    status: playbackStatus,
                                    onLongPress: onStatusLongPress,
                                  ),
                                  if (!fullScreen)
                                    IconButton(
                                      key: const ValueKey(
                                        'player-download-button',
                                      ),
                                      tooltip:
                                          downloadStatus ==
                                              DownloadTaskStatus.completed
                                          ? '已下载'
                                          : '下载本集',
                                      onPressed: onDownload,
                                      icon: Icon(switch (downloadStatus) {
                                        DownloadTaskStatus.completed =>
                                          Icons.download_done,
                                        DownloadTaskStatus.downloading =>
                                          Icons.downloading,
                                        DownloadTaskStatus.queued =>
                                          Icons.schedule,
                                        DownloadTaskStatus.paused =>
                                          Icons.pause_circle_outline,
                                        DownloadTaskStatus.failed =>
                                          Icons.refresh,
                                        DownloadTaskStatus.cancelled ||
                                        null => Icons.download_outlined,
                                      }),
                                    ),
                                  // ValueKey 留在 KeyedSubtree 上供测试定位，
                                  // GlobalKey 交给按钮本体以支持菜单键程序化打开。
                                  KeyedSubtree(
                                    key: const ValueKey('playback-speed-menu'),
                                    child: PopupMenuButton<double>(
                                      key: speedMenuKey,
                                      tooltip: '播放速度',
                                      initialValue: playbackSpeed,
                                      onSelected: onSpeedSelected,
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 0.5,
                                          child: Text('0.5×'),
                                        ),
                                        PopupMenuItem(
                                          value: 0.75,
                                          child: Text('0.75×'),
                                        ),
                                        PopupMenuItem(
                                          value: 1.0,
                                          child: Text('正常'),
                                        ),
                                        PopupMenuItem(
                                          value: 1.25,
                                          child: Text('1.25×'),
                                        ),
                                        PopupMenuItem(
                                          value: 1.5,
                                          child: Text('1.5×'),
                                        ),
                                        PopupMenuItem(
                                          value: 2.0,
                                          child: Text('2×'),
                                        ),
                                      ],
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 10,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.speed, size: 21),
                                            const SizedBox(width: 3),
                                            Text(
                                              '${playbackSpeed.toStringAsFixed(playbackSpeed % 1 == 0 ? 0 : 2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}×',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (showEpisodeNav)
                                    KeyedSubtree(
                                      key: const ValueKey(
                                        'player-episode-menu',
                                      ),
                                      child: PopupMenuButton<Episode>(
                                        key: episodeMenuKey,
                                        tooltip: '选集',
                                        constraints: const BoxConstraints(
                                          maxHeight: 320,
                                          minWidth: 128,
                                        ),
                                        onOpened: onEpisodeMenuOpened,
                                        onCanceled: onEpisodeMenuCanceled,
                                        onSelected: onEpisodeSelected,
                                        itemBuilder: (_) {
                                          return [
                                            for (final item in episodes)
                                              PopupMenuItem(
                                                value: item,
                                                child: Text(
                                                  item.name,
                                                  style: TextStyle(
                                                    fontWeight:
                                                        isCurrentEpisode(item)
                                                        ? FontWeight.w700
                                                        : FontWeight.w400,
                                                    color:
                                                        isCurrentEpisode(item)
                                                        ? AppColors.accent
                                                        : null,
                                                  ),
                                                ),
                                              ),
                                          ];
                                        },
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 10,
                                          ),
                                          child: Text(
                                            '选集',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (overlayLayout &&
                                      !compactControls &&
                                      !(fullScreen && isPortraitVideo))
                                    IconButton(
                                      onPressed: onFillScreenToggle,
                                      tooltip: fillScreen ? '适应' : '铺满',
                                      icon: Icon(
                                        fillScreen
                                            ? Icons.fit_screen
                                            : Icons.crop_free,
                                      ),
                                    ),
                                  // 横屏片在 iPad 横屏已经是横屏布局，全屏按钮没有作用。
                                  // 竖屏片即使当前是设备横屏，全屏也会转到竖屏展开。
                                  if (fullScreen ||
                                      MediaQuery.orientationOf(context) ==
                                          Orientation.portrait ||
                                      isPortraitVideo)
                                    IconButton(
                                      tooltip: fullScreen ? '退出全屏' : '进入全屏',
                                      onPressed: onFullScreenToggle,
                                      icon: Icon(
                                        fullScreen
                                            ? Icons.fullscreen_exit
                                            : Icons.fullscreen,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
