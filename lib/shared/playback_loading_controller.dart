import 'package:flutter_riverpod/flutter_riverpod.dart';

enum PlaybackLoadingPhase {
  playbackInfo,
  preparingVideo,
  loadingPicture,
  restoringPosition,
  skippingIntro,
  refreshingAddress,
  expiredAddress,
  alternatePlayback,
  reconnecting;

  String get label => switch (this) {
    playbackInfo => '正在获取播放信息…',
    preparingVideo => '正在准备视频…',
    loadingPicture => '正在加载画面…',
    restoringPosition => '正在恢复播放进度…',
    skippingIntro => '正在跳过片头…',
    refreshingAddress => '正在重新获取播放地址…',
    expiredAddress => '播放地址已失效，正在重新获取…',
    alternatePlayback => '正在尝试其他播放方式…',
    reconnecting => '视频加载较慢，正在尝试重新连接…',
  };

  int get step => switch (this) {
    playbackInfo || refreshingAddress || expiredAddress => 0,
    preparingVideo => 1,
    _ => 2,
  };
}

typedef PlaybackLoadingState = ({PlaybackLoadingPhase phase, bool visible});

/// Identity keys keep concurrent detail/player routes independent. A page's
/// listenManual subscription retains its state until that page is disposed.
final playbackLoadingProvider = NotifierProvider.autoDispose
    .family<PlaybackLoadingController, PlaybackLoadingState, Object>(
      PlaybackLoadingController.new,
    );

class PlaybackLoadingController extends Notifier<PlaybackLoadingState> {
  PlaybackLoadingController(this.owner);

  final Object owner;

  @override
  PlaybackLoadingState build() =>
      (phase: PlaybackLoadingPhase.preparingVideo, visible: false);

  void setPhase(PlaybackLoadingPhase phase) {
    if (state.phase == phase) return;
    state = (phase: phase, visible: state.visible);
  }

  void show(PlaybackLoadingPhase phase) {
    if (state.visible && state.phase == phase) return;
    state = (phase: phase, visible: true);
  }

  void hide() {
    if (!state.visible) return;
    state = (phase: state.phase, visible: false);
  }
}
