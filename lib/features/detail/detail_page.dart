import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/theme.dart';
import '../../shared/app_states.dart';
import '../../data/download/download_providers.dart';
import '../../data/download/download_task_manager.dart';
import '../../data/playback/trace/playback_startup_trace.dart';
import '../../data/playback/trace/playback_trace_stage.dart';
import '../../data/video_repository.dart';
import '../../data/library_repository.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/video.dart';
import '../../domain/playback_selection.dart';
import '../../domain/vod_source.dart';
import '../../shared/app_toast.dart';
import '../../shared/playback_loading_view.dart';
import '../../shared/playback_loading_controller.dart';
import '../../shared/is_tv.dart';
import '../../shared/skip_settings.dart';
import './detail_source_controller.dart';
import './detail_layout.dart';
import './detail_more_sources_sheet.dart';
import './widgets/detail_download_sheet.dart';
import './widgets/detail_episodes_section.dart';
import './widgets/detail_relationship_button.dart';
import './widgets/detail_source_section.dart';
import '../download/download_management_page.dart';
import '../player/player_page.dart';

// 响应式布局指标独立成 detail_layout.dart；此处 re-export 保留
// detail_page_test.dart 等既有引用路径。
export 'detail_layout.dart';

class VideoDetailPage extends ConsumerStatefulWidget {
  const VideoDetailPage({super.key, required this.video});
  final Video video;
  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> {
  Video? detail;
  String? error;
  bool loading = true, resolving = false, expanded = false;
  Timer? _playbackProgressTimer;
  bool _preparingPlayback = false;
  final Object _loadingOwner = Object();
  late final PlaybackLoadingController _loadingController;
  bool reversed = false;
  int selected = 0;
  DetailSourceController? sc;
  bool downloadResolving = false;
  final Set<int> _expandedEpsGroups = {0};

  /// TV 端进入详情页时默认聚焦"播放"按钮（D-pad 起点）。
  /// 仅 isTvProvider 为 true 时请求一次，手机端不抢焦点、无视觉变化。
  final FocusNode _playFocusNode = FocusNode();
  bool _didFocusPlay = false;
  late DetailPageLayout _layout;

  @override
  void initState() {
    super.initState();
    ref.listenManual(playbackLoadingProvider(_loadingOwner), (_, _) {});
    _loadingController = ref.read(
      playbackLoadingProvider(_loadingOwner).notifier,
    );
  }

  @override
  void dispose() {
    _playbackProgressTimer?.cancel();
    sc?.dispose();
    _playFocusNode.dispose();
    super.dispose();
  }

  VodSource? _src(String id) => ref
      .read(vodSourceRegistryProvider)
      .maybeWhen(data: (r) => r.findById(id), orElse: () => null);

  void _init() {
    if (sc != null) return;
    final reg = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (reg == null) return;
    sc = DetailSourceController(
      repository: ref.read(videoRepositoryProvider),
      registry: reg,
      initialVideo: widget.video,
    )..addListener(_onChanged);
    _load();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (sc == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final source = _src(sc!.activeVideo.sourceId);
      if (source == null) throw VideoDataException('未知来源');
      final v = await ref
          .read(videoRepositoryProvider)
          .fetchDetail(source, sc!.activeVideo.ref);
      if (!mounted) return;
      final merged = _withListMetadata(widget.video, v);
      setState(() {
        detail = merged;
      });
      sc!.markActiveLoaded(merged);
      unawaited(
        ref
            .read(favoriteControllerProvider.notifier)
            .markViewed(merged.globalId),
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  /// List cards already have a title/cover; plugin adapters often only get a
  /// URL on the detail request and would otherwise show a raw id.
  Video _withListMetadata(Video listed, Video fetched) {
    final fetchedTitle = fetched.title.trim();
    final useListedTitle =
        listed.title.trim().isNotEmpty &&
        (fetchedTitle.isEmpty ||
            fetchedTitle == listed.sourceVideoId ||
            fetchedTitle.startsWith('http') ||
            RegExp(r'^\d+$').hasMatch(fetchedTitle));
    return fetched.copyWith(
      title: useListedTitle ? listed.title : fetched.title,
      posterUrl: fetched.posterUrl.isEmpty
          ? listed.posterUrl
          : fetched.posterUrl,
      remarks: fetched.remarks.isEmpty ? listed.remarks : fetched.remarks,
      description: fetched.description.isEmpty
          ? listed.description
          : fetched.description,
    );
  }

  Future<void> _play({int? episodeIndex}) async {
    if (sc == null || resolving) return;
    setState(() {
      resolving = true;
      _preparingPlayback = true;
      if (episodeIndex != null) selected = episodeIndex;
    });
    _playbackProgressTimer?.cancel();
    _playbackProgressTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted && _preparingPlayback) {
        _loadingController.show(PlaybackLoadingPhase.playbackInfo);
      }
    });
    final overlay = Overlay.of(context);
    final active = sc!.activeVideo;
    final requestedEpisode = active.episodes.isEmpty
        ? const Episode(id: '', name: '', url: '')
        : active.episodes[selected.clamp(0, active.episodes.length - 1)];
    final startupTrace = PlaybackStartupTrace.maybeStart(
      videoTitle: active.title,
      sourceId: active.sourceId,
      sourceVideoId: active.sourceVideoId,
      episode: requestedEpisode,
      offlineOnly: false,
    );
    try {
      final downloadLookup = startupTrace?.startStage(
        PlaybackTraceStage.downloadSelectionLookup,
      );
      final cachedSelection = await _cachedSelectionForCurrentEpisode();
      startupTrace?.finishStage(
        downloadLookup,
        result: cachedSelection == null ? 'miss' : 'hit',
      );
      if (cachedSelection != null) {
        if (!mounted) return;
        _finishPlaybackPreparation();
        final played = await Navigator.of(context).push<Episode>(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              video: sc!.activeVideo,
              episode: cachedSelection.episode,
              selection: cachedSelection,
              startupTrace: startupTrace,
            ),
          ),
        );
        if (mounted) _syncSelectedFromPlayer(played);
        return;
      }
      final source = _src(sc!.activeVideo.sourceId);
      if (source == null) throw VideoDataException('未知来源');
      final detailResolve = startupTrace?.startStage(
        PlaybackTraceStage.detailResolvePlayback,
      );
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, sc!.activeVideo.ref);
      startupTrace?.finishStage(detailResolve);
      final favoriteRefresh = startupTrace?.startStage(
        PlaybackTraceStage.favoriteSnapshotRefresh,
      );
      await ref
          .read(favoriteControllerProvider.notifier)
          .refreshSnapshot(fresh);
      startupTrace?.finishStage(favoriteRefresh);
      if (fresh.episodes.isEmpty) {
        throw VideoDataException('该视频暂时没有可用播放地址');
      }
      final ep = playbackEpisodeFor(fresh, requestedEpisode);
      if (ep == null) {
        throw const VideoDataException('该剧集暂时没有可用播放地址');
      }
      final selection = selectionFor(fresh, ep);
      if (!mounted) return;
      setState(() => detail = fresh);
      _finishPlaybackPreparation();
      final played = await Navigator.of(context).push<Episode>(
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            video: fresh,
            episode: ep,
            selection: selection,
            startupTrace: startupTrace,
          ),
        ),
      );
      if (mounted) _syncSelectedFromPlayer(played);
    } catch (e) {
      startupTrace?.fail(e);
      if (mounted) {
        showAppToastVia(overlay, '$e（可尝试查找其他来源）');
      }
    } finally {
      _finishPlaybackPreparation();
      if (mounted) setState(() => resolving = false);
    }
  }

  void _finishPlaybackPreparation() {
    _playbackProgressTimer?.cancel();
    if (!mounted) return;
    _preparingPlayback = false;
    _loadingController.hide();
  }

  void _syncSelectedFromPlayer(Episode? played) {
    if (played == null || sc == null) return;
    final episodes = sc!.activeVideo.episodes;
    final index = indexOfEpisode(episodes, played);
    if (index == null) return;
    selected = index;
    if (episodes.length > DetailEpisodesSection.groupSize) {
      final displayIdx = reversed ? episodes.length - 1 - index : index;
      _expandedEpsGroups
        ..clear()
        ..add(displayIdx ~/ DetailEpisodesSection.groupSize);
    }
    setState(() {});
  }

  Future<PlaybackSelection?> _cachedSelectionForCurrentEpisode() async {
    final active = sc?.activeVideo;
    if (active == null || active.episodes.isEmpty) return null;
    final requested =
        active.episodes[selected.clamp(0, active.episodes.length - 1)];
    final current = playbackEpisodeFor(active, requested) ?? requested;
    final lineIdentity = preferredPlaybackLine(active)?.identity;
    try {
      final manager = await ref.read(downloadManagerProvider.future);
      final task = manager.tasks
          .where(
            (item) =>
                item.status == DownloadTaskStatus.completed &&
                item.sourceId == active.sourceId &&
                item.sourceVideoId == active.sourceVideoId &&
                item.playbackLineIdentity == lineIdentity &&
                (item.episodeIdentity == current.identity ||
                    (current.identity.isEmpty &&
                        (item.episodeId == current.id ||
                            item.episodeName == current.name))),
          )
          .firstOrNull;
      if (task == null) return null;
      return manager.selectionForTask(task);
    } catch (_) {
      return null;
    }
  }

  Future<void> _chooseDownloads() async {
    if (sc == null || downloadResolving || sc!.activeVideo.episodes.isEmpty) {
      return;
    }
    final source = _src(sc!.activeVideo.sourceId);
    if (source?.disablesDownload == true) {
      showAppToast(context, '该来源暂不支持下载');
      return;
    }
    final current = selected.clamp(0, sc!.activeVideo.episodes.length - 1);
    final selectedIndexes = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      // 宽屏（电视/平板横屏）下收敛宽度居中，不随屏幕拉满。
      constraints: BoxConstraints(maxWidth: 600),
      builder: (context) => DetailDownloadSheet(
        video: sc!.activeVideo,
        currentEpisodeIndex: current,
        onOpenManagement: () {
          if (!mounted) return;
          Navigator.of(
            this.context,
          ).push(MaterialPageRoute(builder: (_) => DownloadManagementPage()));
        },
      ),
    );
    if (selectedIndexes == null || selectedIndexes.isEmpty || !mounted) return;
    await _downloadEpisodes(selectedIndexes);
  }

  Future<void> _downloadEpisodes(List<int> indexes) async {
    if (sc == null || downloadResolving) return;
    setState(() => downloadResolving = true);
    try {
      final source = _src(sc!.activeVideo.sourceId);
      if (source == null) throw VideoDataException('未知来源');
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, sc!.activeVideo.ref);
      if (fresh.episodes.isEmpty) {
        throw VideoDataException('该视频暂时没有可下载剧集');
      }
      final manager = await ref.read(downloadManagerProvider.future);
      var created = 0;
      for (final episodeIndex in indexes) {
        if (episodeIndex >= sc!.activeVideo.episodes.length) continue;
        final prior = sc!.activeVideo.episodes[episodeIndex];
        final episode = playbackEpisodeFor(fresh, prior);
        if (episode == null) continue;
        final selection = selectionFor(fresh, episode);
        if (selection == null) continue;
        await manager.enqueue(selection);
        created++;
      }
      if (created == 0) {
        throw VideoDataException('选中的剧集缺少稳定身份，无法下载');
      }
      if (mounted) {
        showAppToast(
          context,
          '已开始下载 $created 集（自动跳过广告片段）',
          actionLabel: '查看',
          onAction: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => DownloadManagementPage())),
        );
      }
    } catch (e) {
      if (mounted) {
        final reason = (e is Exception) ? e.toString() : '未知错误';
        showAppToast(context, '下载任务创建失败：$reason');
      }
    } finally {
      if (mounted) setState(() => downloadResolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rs = ref.watch(vodSourceRegistryProvider);
    final size = MediaQuery.sizeOf(context);
    final barLayout = DetailPageLayout.resolve(
      viewportWidth: size.width,
      shortestSide: size.shortestSide,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '视频详情',
          style: TextStyle(
            fontSize: barLayout.appBarTitleSize,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            key: const ValueKey('detail-download-button'),
            tooltip: '下载',
            icon: _downloadButtonIcon(),
            onPressed:
                sc == null ||
                    loading ||
                    resolving ||
                    downloadResolving ||
                    sc!.activeVideo.episodes.isEmpty
                ? null
                : _chooseDownloads,
          ),
        ],
      ),
      body: PlaybackLoadingOverlay(
        session: _loadingOwner,
        child: rs.when(
          loading: () => AppLoadingView(label: '正在加载…'),
          error: (e, _) => AppErrorView(
            message: '$e',
            onRetry: () => ref.invalidate(vodSourceRegistryProvider),
          ),
          data: (_) {
            if (sc == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _init();
              });
              return AppLoadingView();
            }
            if (loading) return AppLoadingView(label: '正在加载详情…');
            if (error != null) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppErrorView(message: error!, onRetry: _load),
                  TextButton(onPressed: _moreSources, child: Text('切换来源')),
                ],
              );
            }
            return _content(sc!.activeVideo);
          },
        ),
      ),
    );
  }

  Widget _content(Video v) {
    _focusPlayOnTv();
    return LayoutBuilder(
      builder: (context, constraints) {
        _layout = DetailPageLayout.resolve(
          viewportWidth: constraints.maxWidth,
          shortestSide: MediaQuery.sizeOf(context).shortestSide,
        );
        final list = _contentList(v);
        if (_layout.contentWidth >= constraints.maxWidth) return list;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: _layout.contentWidth),
            child: list,
          ),
        );
      },
    );
  }

  void _focusPlayOnTv() {
    if (_didFocusPlay) return;
    final isTv = ref
        .watch(isTvProvider)
        .maybeWhen(data: (value) => value, orElse: () => false);
    if (!isTv) return;
    _didFocusPlay = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocusNode.requestFocus();
    });
  }

  Widget _contentList(Video v) => ListView(
    padding: EdgeInsets.fromLTRB(
      _layout.pagePadding,
      _layout.isTablet ? 12 : 8,
      _layout.pagePadding,
      32,
    ),
    // section 间距统一为 24/28，模块内部 4/8/12（8pt 体系）。
    children: [
      _header(v),
      SizedBox(height: 24),
      _actionRow(v),
      SizedBox(height: 28),
      SkipSettingsBlock(videoGlobalId: v.globalId),
      SizedBox(height: 28),
      _sourceSection(),
      SizedBox(height: 28),
      _desc(v),
      SizedBox(height: 28),
      _eps(v),
    ],
  );

  Widget _actionRow(Video v) {
    final row = Row(
      children: [
        Expanded(child: _playBtn(v)),
        SizedBox(width: 8),
        _relationshipBtn(v),
      ],
    );
    if (!_layout.isTablet) return row;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(_layout.actionRowMaxWidth, 500),
        ),
        child: row,
      ),
    );
  }

  Widget _header(Video v) {
    // 元信息合并为少量纯文本行，不用图标，避免与封面争夺视觉焦点。
    final infoLine = [
      v.area,
      v.year,
      v.category,
      if (v.episodes.isNotEmpty)
        v.episodes.length == 1 ? '正片' : '${v.episodes.length}集',
    ].where((e) => e.isNotEmpty).join(' · ');
    final metaStyle = TextStyle(
      color: context.appColors.secondary,
      fontSize: 13,
      height: 1.5,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            key: ValueKey('detail-poster'),
            width: _layout.posterWidth,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: ColoredBox(
                color: context.appColors.elevated,
                child: v.posterUrl.isEmpty
                    ? Icon(
                        Icons.movie_outlined,
                        size: 44,
                        color: context.appColors.tertiary,
                      )
                    : CachedNetworkImage(
                        imageUrl: v.posterUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => Icon(
                          Icons.movie_outlined,
                          color: context.appColors.tertiary,
                        ),
                      ),
              ),
            ),
          ),
        ),
        SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                v.title,
                style: TextStyle(
                  fontSize: _layout.titleSize,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (infoLine.isNotEmpty) ...[
                SizedBox(height: 8),
                Text(infoLine, style: metaStyle),
              ],
              if (v.remarks.isNotEmpty) ...[
                SizedBox(height: 4),
                Text(v.remarks, style: metaStyle),
              ],
              if (v.actors.isNotEmpty) ...[
                SizedBox(height: 4),
                Text(
                  v.actors,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: metaStyle,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _playBtn(Video v) => SizedBox(
    height: 48,
    child: FilledButton.icon(
      key: const ValueKey('detail-play-button'),
      focusNode: _playFocusNode,
      onPressed: v.episodes.isEmpty || resolving ? null : _play,
      icon: resolving
          ? SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.play_arrow),
      label: Text(
        v.episodes.isEmpty ? '暂无可播放剧集' : '播放 ${v.episodes[selected].name}',
      ),
    ),
  );

  Widget _downloadButtonIcon() => downloadResolving
      ? const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : const Icon(Icons.download_outlined);

  Widget _relationshipBtn(Video v) =>
      DetailRelationshipButton(video: v, isTablet: _layout.isTablet);

  Widget _sourceSection() => DetailSourceSection(
    controller: sc!,
    onChipTap: _onSourceChipTap,
    onMoreSources: _moreSources,
  );

  /// 来源芯片点击分支：有候选先挑选、已加载直接切换、未检测按需搜一次、
  /// 失败重试检测。与「更多来源」入口保持一致。
  void _onSourceChipTap(DetailSourceState s) {
    if (s.status == DetailSourceStatus.hasResource) {
      _candidates(s);
    } else if (s.status == DetailSourceStatus.loaded && s.detail != null) {
      _switchLoaded(s);
    } else if (s.status == DetailSourceStatus.notDetected) {
      _searchOne(s.source.id);
    } else if (s.status == DetailSourceStatus.failed) {
      sc!.retryDetection(s.source.id);
    }
  }

  void _switchLoaded(DetailSourceState s) {
    if (s.detail == null) return;
    final current = detail;
    final prior = current != null && selected < current.episodes.length
        ? current.episodes[selected].name
        : null;
    sc!.activeVideo = s.detail!;
    final matched = sc!.findEpisodeByName(prior);
    selected = matched ?? 0;
    detail = s.detail;
    error = null;
    if (matched == null && prior != null) {
      showAppToast(context, '当前剧集在目标源不存在，已切换到第一集');
    }
    setState(() {});
  }

  void _candidates(DetailSourceState s) {
    if (s.candidates.isEmpty) return;
    if (s.candidates.length == 1) {
      _confirm(s, s.candidates.first);
      return;
    }
    showDetailCandidatesSheet(context, s: s, onSelect: (c) => _confirm(s, c));
  }

  Future<void> _confirm(DetailSourceState s, Video c) async {
    final ok = await confirmSourceSwitch(
      context,
      sourceName: s.source.name,
      videoTitle: c.title,
    );
    if (ok != true) return;
    final current = detail;
    final prior = current != null && selected < current.episodes.length
        ? current.episodes[selected].name
        : null;
    await sc!.loadCandidateDetail(s.source.id, c);
    if (!mounted) return;
    if (sc!.activeVideo.sourceId != s.source.id) {
      showAppToast(context, '该来源加载失败，已保留当前来源');
      return;
    }
    detail = sc!.activeVideo;
    error = null;
    final matched = sc!.findEpisodeByName(prior);
    selected = matched ?? 0;
    if (matched == null && prior != null) {
      showAppToast(context, '当前剧集在目标源不存在，已切换到第一集');
    }
    setState(() {});
  }

  Future<void> _searchOne(String sourceId) async {
    if (sc!.switching) return;
    final source = _src(sourceId);
    if (source == null) return;
    sc!.ensureSourceState(source);
    sc!.retryDetection(sourceId);
  }

  void _moreSources() {
    final reg = ref
        .read(vodSourceRegistryProvider)
        .maybeWhen(data: (r) => r, orElse: () => null);
    if (reg == null) return;
    showModalBottomSheet<void>(
      context: context,
      constraints: BoxConstraints(maxWidth: 600),
      builder: (_) => DetailMoreSourcesSheet(
        sources: reg.enabledSources,
        controller: sc!,
        onSourceTap: (id) {
          Navigator.pop(context);
          if (id == sc!.activeSourceId) return;
          // 与来源栏芯片行为一致：已检测出候选或已加载的来源直接进入
          // 选择/切换，其余按需检测。这样首次加载失败的错误页也能
          // 通过“切换来源”完成整个换源流程。
          final s = sc!.stateFor(id);
          if (s != null &&
              s.status == DetailSourceStatus.hasResource &&
              s.candidates.isNotEmpty) {
            _candidates(s);
          } else if (s != null &&
              s.status == DetailSourceStatus.loaded &&
              s.detail != null) {
            _switchLoaded(s);
          } else {
            _searchOne(id);
          }
        },
        onDetectAll: () {
          Navigator.pop(context);
          _detectAll(reg);
        },
      ),
    );
  }

  Future<void> _detectAll(VodSourceRegistry registry) async {
    final count = registry.enabledSources.length;
    if (count > 6) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('查找全部来源'),
          content: Text('将向全部 $count 个来源发起请求，可能产生额外流量。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('继续'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (mounted) sc!.detectOtherSources(all: true);
  }

  Widget _desc(Video v) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('简介', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      SizedBox(height: 8),
      Text(
        v.description.isEmpty ? '暂无简介' : v.description,
        maxLines: expanded ? null : _layout.descMaxLines,
        overflow: expanded ? null : TextOverflow.ellipsis,
        style: TextStyle(
          color: context.appColors.secondary,
          fontSize: 15,
          height: 1.55,
        ),
      ),
      if (v.description.length > 100)
        // 紧跟正文、弱化颜色，不再用主题色按钮样式。
        TextButton(
          onPressed: () => setState(() => expanded = !expanded),
          style: TextButton.styleFrom(
            foregroundColor: context.appColors.secondary,
            padding: EdgeInsets.zero,
            minimumSize: Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(expanded ? '收起' : '展开'),
        ),
    ],
  );

  Widget _eps(Video v) => DetailEpisodesSection(
    video: v,
    selected: selected,
    reversed: reversed,
    expandedGroups: _expandedEpsGroups,
    layout: _layout,
    onToggleReversed: () => _toggleReversed(v),
    onToggleGroup: _toggleEpsGroup,
    onEpisodeTap: (idx) {
      setState(() => selected = idx);
      _play(episodeIndex: idx);
    },
  );

  void _toggleEpsGroup(int group) {
    setState(() {
      if (_expandedEpsGroups.contains(group)) {
        _expandedEpsGroups.remove(group);
      } else {
        _expandedEpsGroups.add(group);
      }
    });
  }

  void _toggleReversed(Video v) {
    setState(() {
      reversed = !reversed;
      final total = v.episodes.length;
      if (total > DetailEpisodesSection.groupSize) {
        // 倒序后保持选中集所在分组展开。
        final displayIdx = reversed
            ? total - 1 - selected.clamp(0, total - 1)
            : selected.clamp(0, total - 1);
        _expandedEpsGroups
          ..clear()
          ..add(displayIdx ~/ DetailEpisodesSection.groupSize);
      }
    });
  }
}
