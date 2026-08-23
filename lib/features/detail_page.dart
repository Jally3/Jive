import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/cache/download_providers.dart';
import '../data/cache/download_task_manager.dart';
import '../data/video_repository.dart';
import '../data/library_repository.dart';
import '../data/vod_source_registry.dart';
import '../domain/video.dart';
import '../domain/playback_selection.dart';
import '../domain/vod_source.dart';
import '../shared/app_toast.dart';
import 'detail_source_controller.dart';
import 'detail_more_sources_sheet.dart';
import 'download_management_page.dart';
import 'player_page.dart';

class VideoDetailPage extends ConsumerStatefulWidget {
  const VideoDetailPage({super.key, required this.video});
  final Video video;
  @override
  ConsumerState<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends ConsumerState<VideoDetailPage> {
  /// 剧集超过该数量时按每组 100 集折叠展示。
  static const int _epsGroupSize = 100;

  Video? detail;
  String? error;
  bool loading = true, resolving = false, expanded = false;
  bool reversed = false;
  int selected = 0;
  DetailSourceController? sc;
  bool downloadResolving = false;
  final Set<int> _expandedEpsGroups = {0};

  @override
  void dispose() {
    sc?.dispose();
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
      if (source == null) throw const VideoDataException('未知来源');
      final v = await ref
          .read(videoRepositoryProvider)
          .fetchDetail(source, sc!.activeVideo.ref);
      if (!mounted) return;
      final merged = _withListMetadata(widget.video, v);
      setState(() {
        detail = merged;
      });
      sc!.markActiveLoaded(merged);
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
      if (episodeIndex != null) selected = episodeIndex;
    });
    final overlay = Overlay.of(context);
    try {
      final cachedSelection = await _cachedSelectionForCurrentEpisode();
      if (cachedSelection != null) {
        if (!mounted) return;
        final played = await Navigator.of(context).push<Episode>(
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              video: sc!.activeVideo,
              episode: cachedSelection.episode,
              selection: cachedSelection,
            ),
          ),
        );
        if (mounted) _syncSelectedFromPlayer(played);
        return;
      }
      final source = _src(sc!.activeVideo.sourceId);
      if (source == null) throw const VideoDataException('未知来源');
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, sc!.activeVideo.ref);
      await ref
          .read(favoriteControllerProvider.notifier)
          .refreshSnapshot(fresh);
      if (fresh.episodes.isEmpty) {
        throw const VideoDataException('该视频暂时没有可用播放地址');
      }
      final prior = detail != null && detail!.episodes.length > selected
          ? detail!.episodes[selected].name
          : '';
      final idx = fresh.episodes.indexWhere((e) => e.name == prior);
      final ep =
          fresh.episodes[idx >= 0
              ? idx
              : selected.clamp(0, fresh.episodes.length - 1)];
      if (!mounted) return;
      setState(() => detail = fresh);
      final played = await Navigator.of(context).push<Episode>(
        MaterialPageRoute(
          builder: (_) => PlayerPage(video: fresh, episode: ep),
        ),
      );
      if (mounted) _syncSelectedFromPlayer(played);
    } catch (e) {
      if (mounted) {
        showAppToastVia(overlay, '$e（可尝试查找其他来源）');
      }
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  void _syncSelectedFromPlayer(Episode? played) {
    if (played == null || sc == null) return;
    final episodes = sc!.activeVideo.episodes;
    final index = indexOfEpisode(episodes, played);
    if (index == null) return;
    selected = index;
    if (episodes.length > _epsGroupSize) {
      final displayIdx = reversed ? episodes.length - 1 - index : index;
      _expandedEpsGroups
        ..clear()
        ..add(displayIdx ~/ _epsGroupSize);
    }
    setState(() {});
  }

  Future<PlaybackSelection?> _cachedSelectionForCurrentEpisode() async {
    final active = sc?.activeVideo;
    if (active == null || active.episodes.isEmpty) return null;
    final current =
        active.episodes[selected.clamp(0, active.episodes.length - 1)];
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
      builder: (context) {
        final checked = <int>{current};
        return StatefulBuilder(
          builder: (context, setSheetState) => Consumer(
            builder: (context, ref, _) {
              final tasks = ref.watch(downloadTasksProvider).value ?? const [];
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.7,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '选择下载剧集',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                setSheetState(() {
                                  if (checked.length ==
                                      sc!.activeVideo.episodes.length) {
                                    checked.clear();
                                  } else {
                                    checked.addAll(
                                      List.generate(
                                        sc!.activeVideo.episodes.length,
                                        (index) => index,
                                      ),
                                    );
                                  }
                                });
                              },
                              child: Text(
                                checked.length ==
                                        sc!.activeVideo.episodes.length
                                    ? '取消全选'
                                    : '全选',
                              ),
                            ),
                          ],
                        ),
                        const Text(
                          '下载时自动跳过广告片段',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.secondary,
                          ),
                        ),
                        const Divider(),
                        Expanded(
                          child: ListView.builder(
                            itemCount: sc!.activeVideo.episodes.length,
                            itemBuilder: (_, index) {
                              final episode = sc!.activeVideo.episodes[index];
                              final task = _taskForEpisode(tasks, episode);
                              return CheckboxListTile(
                                value: checked.contains(index),
                                title: Text(episode.name),
                                subtitle: task == null
                                    ? null
                                    : Text(
                                        _downloadTaskSummary(task),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.secondary,
                                        ),
                                      ),
                                onChanged: (value) {
                                  setSheetState(() {
                                    if (value == true) {
                                      checked.add(index);
                                    } else {
                                      checked.remove(index);
                                    }
                                  });
                                },
                              );
                            },
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: checked.isEmpty
                                ? null
                                : () =>
                                      Navigator.pop(context, checked.toList()),
                            icon: const Icon(Icons.download),
                            label: Text('确认下载（${checked.length} 集）'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
    if (selectedIndexes == null || selectedIndexes.isEmpty || !mounted) return;
    await _downloadEpisodes(selectedIndexes);
  }

  DownloadTask? _taskForEpisode(List<DownloadTask> tasks, Episode episode) {
    final active = sc?.activeVideo;
    final lineIdentity = active == null
        ? null
        : preferredPlaybackLine(active)?.identity;
    return tasks
        .where(
          (task) =>
              task.sourceId == sc?.activeVideo.sourceId &&
              task.sourceVideoId == sc?.activeVideo.sourceVideoId &&
              task.playbackLineIdentity == lineIdentity &&
              (task.episodeIdentity == episode.identity ||
                  (episode.identity.isEmpty &&
                      (task.episodeId == episode.id ||
                          task.episodeName == episode.name))),
        )
        .firstOrNull;
  }

  String _downloadTaskSummary(DownloadTask task) {
    final status = switch (task.status) {
      DownloadTaskStatus.queued => '排队中',
      DownloadTaskStatus.downloading => '下载中',
      DownloadTaskStatus.paused => '已暂停',
      DownloadTaskStatus.completed => '已完成',
      DownloadTaskStatus.failed => '失败，可重试',
      DownloadTaskStatus.cancelled => '已取消',
    };
    final progress = task.expectedResourceCount > 0
        ? ' · ${(task.progress * 100).round()}%'
        : '';
    final size = task.totalBytes > 0
        ? ' · ${_formatBytes(task.downloadedBytes)}/${_formatBytes(task.totalBytes)}'
        : '';
    final speed = task.status == DownloadTaskStatus.downloading
        ? ' · ${_formatSpeed(task.speedBytesPerSecond)}'
        : '';
    return '$status$progress$size$speed';
  }

  static String _formatSpeed(int bytes) => '${_formatBytes(bytes)}/s';

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Future<void> _downloadEpisodes(List<int> indexes) async {
    if (sc == null || downloadResolving) return;
    setState(() => downloadResolving = true);
    try {
      final source = _src(sc!.activeVideo.sourceId);
      if (source == null) throw const VideoDataException('未知来源');
      final fresh = await ref
          .read(videoRepositoryProvider)
          .resolvePlayback(source, sc!.activeVideo.ref);
      if (fresh.episodes.isEmpty) {
        throw const VideoDataException('该视频暂时没有可下载剧集');
      }
      final manager = await ref.read(downloadManagerProvider.future);
      var created = 0;
      for (final episodeIndex in indexes) {
        if (episodeIndex >= sc!.activeVideo.episodes.length) continue;
        final prior = sc!.activeVideo.episodes[episodeIndex];
        final idx = fresh.episodes.indexWhere(
          (item) =>
              item.identity == prior.identity ||
              item.name == prior.name ||
              item.id == prior.id,
        );
        if (idx < 0) continue;
        final episode = fresh.episodes[idx];
        final selection = selectionFor(fresh, episode);
        if (selection == null) continue;
        await manager.enqueue(selection);
        created++;
      }
      if (created == 0) {
        throw const VideoDataException('选中的剧集缺少稳定身份，无法下载');
      }
      if (mounted) {
        showAppToast(
          context,
          '已开始下载 $created 集（自动跳过广告片段）',
          actionLabel: '查看',
          onAction: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DownloadManagementPage()),
          ),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('视频详情'),
        actions: [
          IconButton(
            tooltip: '下载管理',
            icon: const Icon(Icons.download_done_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadManagementPage()),
            ),
          ),
        ],
      ),
      body: rs.when(
        loading: () => const AppLoadingView(label: '正在加载…'),
        error: (e, _) => AppErrorView(
          message: '$e',
          onRetry: () => ref.invalidate(vodSourceRegistryProvider),
        ),
        data: (_) {
          if (sc == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _init();
            });
            return const AppLoadingView();
          }
          if (loading) return const AppLoadingView(label: '正在加载详情…');
          if (error != null) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppErrorView(message: error!, onRetry: _load),
                TextButton(onPressed: _moreSources, child: const Text('切换来源')),
              ],
            );
          }
          return _content(sc!.activeVideo);
        },
      ),
    );
  }

  Widget _content(Video v) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
    // section 间距统一为 24/28，模块内部 4/8/12（8pt 体系）。
    children: [
      _header(v),
      const SizedBox(height: 24),
      Row(
        children: [
          // 播放 : 下载 ≈ 65 : 35，收藏收起为同高图标按钮。
          Expanded(flex: 13, child: _playBtn(v)),
          const SizedBox(width: 8),
          Expanded(flex: 7, child: _downloadBtn(v)),
          const SizedBox(width: 8),
          _favBtn(v),
        ],
      ),
      const SizedBox(height: 28),
      _sourceSection(),
      const SizedBox(height: 28),
      _desc(v),
      const SizedBox(height: 28),
      _eps(v),
    ],
  );

  Widget _header(Video v) {
    // 元信息合并为少量纯文本行，不用图标，避免与封面争夺视觉焦点。
    final infoLine = [
      v.area,
      v.year,
      v.category,
      if (v.episodes.isNotEmpty)
        v.episodes.length == 1 ? '正片' : '${v.episodes.length}集',
    ].where((e) => e.isNotEmpty).join(' · ');
    const metaStyle = TextStyle(
      color: AppColors.secondary,
      fontSize: 13,
      height: 1.5,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 120,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: ColoredBox(
                color: AppColors.elevated,
                child: v.posterUrl.isEmpty
                    ? const Icon(
                        Icons.movie_outlined,
                        size: 44,
                        color: AppColors.tertiary,
                      )
                    : CachedNetworkImage(
                        imageUrl: v.posterUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) => const Icon(
                          Icons.movie_outlined,
                          color: AppColors.tertiary,
                        ),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                v.title,
                style: const TextStyle(
                  fontSize: 22,
                  height: 1.35,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (infoLine.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(infoLine, style: metaStyle),
              ],
              if (v.remarks.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(v.remarks, style: metaStyle),
              ],
              if (v.actors.isNotEmpty) ...[
                const SizedBox(height: 4),
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
      onPressed: v.episodes.isEmpty || resolving ? null : _play,
      icon: resolving
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow),
      label: Text(
        v.episodes.isEmpty ? '暂无可播放剧集' : '播放 ${v.episodes[selected].name}',
      ),
    ),
  );

  Widget _downloadBtn(Video v) => SizedBox(
    height: 48,
    child: OutlinedButton.icon(
      onPressed: v.episodes.isEmpty || resolving || downloadResolving
          ? null
          : _chooseDownloads,
      // 次操作用普通文字色，把琥珀色留给播放主按钮。
      // 窄屏下按钮仅约 78px，收紧横向留白并让标签缩放，避免“下载”折行。
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.text,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: downloadResolving
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined),
      label: const FittedBox(
        fit: BoxFit.scaleDown,
        child: Text('下载', maxLines: 1, softWrap: false),
      ),
    ),
  );

  Widget _favBtn(Video v) => Consumer(
    builder: (_, ref, _) {
      final favs = ref.watch(favoriteControllerProvider);
      final fav =
          favs.value?.any((i) => i.video.globalId == v.globalId) ?? false;
      return SizedBox.square(
        dimension: 48,
        child: OutlinedButton(
          onPressed: favs.isLoading
              ? null
              : () async {
                  try {
                    await ref
                        .read(favoriteControllerProvider.notifier)
                        .toggle(v);
                    if (mounted) {
                      showAppToast(context, fav ? '已取消收藏' : '已收藏');
                    }
                  } catch (_) {
                    if (mounted) {
                      showAppToast(context, '收藏保存失败，请重试');
                    }
                  }
                },
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            padding: EdgeInsets.zero,
          ),
          child: Icon(fav ? Icons.favorite : Icons.favorite_outline, size: 20),
        ),
      );
    },
  );

  Widget _sourceSection() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '播放来源',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      _sourceBar(),
    ],
  );

  Widget _sourceBar() {
    final states = sc!.sourceStates;
    final hasBackup = states.any(
      (s) =>
          s.source.id != sc!.activeSourceId &&
          s.status != DetailSourceStatus.notDetected,
    );
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final s in states) _chip(s),
          if (!hasBackup)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: const Text('查找其他来源'),
                onPressed: sc!.switching
                    ? null
                    : () => sc!.detectOtherSources(),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                label: const Text('更多 ▾'),
                onPressed: () => _moreSources(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(DetailSourceState s) {
    final active = s.source.id == sc!.activeSourceId;
    final name = s.source.name;
    String label;
    switch (s.status) {
      case DetailSourceStatus.loaded:
        final c = s.episodeCount;
        label = c != null && c > 0
            ? (c == 1 ? '$name 正片' : '$name $c集')
            : '$name 有资源';
      case DetailSourceStatus.hasResource:
        label = '$name 有资源';
      case DetailSourceStatus.noResult:
        label = '$name 0';
      case DetailSourceStatus.detecting:
        label = '$name …';
      case DetailSourceStatus.failed:
        label = '$name !';
      case DetailSourceStatus.notDetected:
        label = '$name —';
    }
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? AppColors.onAccent : AppColors.secondary,
          ),
        ),
        selected: active,
        onSelected: (_) {
          if (active || sc!.switching) return;
          if (s.status == DetailSourceStatus.hasResource) {
            _candidates(s);
          } else if (s.status == DetailSourceStatus.loaded &&
              s.detail != null) {
            _switchLoaded(s);
          } else if (s.status == DetailSourceStatus.notDetected) {
            _searchOne(s.source.id);
          } else if (s.status == DetailSourceStatus.failed) {
            sc!.retryDetection(s.source.id);
          }
        },
        visualDensity: VisualDensity.compact,
      ),
    );
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
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Text(
                  '从 ${s.source.name} 选择',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: s.candidates.length,
                  itemBuilder: (_, i) {
                    final c = s.candidates[i];
                    return ListTile(
                      leading: c.posterUrl.isEmpty
                          ? const Icon(
                              Icons.movie_outlined,
                              color: AppColors.tertiary,
                            )
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: CachedNetworkImage(
                                imageUrl: c.posterUrl,
                                width: 40,
                                height: 60,
                                fit: BoxFit.cover,
                                errorWidget: (_, _, _) => const Icon(
                                  Icons.movie_outlined,
                                  color: AppColors.tertiary,
                                ),
                              ),
                            ),
                      title: Text(
                        c.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          c.year,
                          c.remarks,
                          c.area,
                          if (c.episodes.isNotEmpty)
                            c.episodes.length == 1
                                ? '正片'
                                : '${c.episodes.length}集',
                        ].where((e) => e.isNotEmpty).join(' · '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.secondary,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _confirm(s, c);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(DetailSourceState s, Video c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认切换来源'),
        content: Text('将从 ${s.source.name} 加载「${c.title}」的播放信息。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
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
          title: const Text('查找全部来源'),
          content: Text('将向全部 $count 个来源发起请求，可能产生额外流量。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
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
      const Text(
        '简介',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        v.description.isEmpty ? '暂无简介' : v.description,
        maxLines: expanded ? null : 4,
        overflow: expanded ? null : TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 15,
          height: 1.55,
        ),
      ),
      if (v.description.length > 100)
        // 紧跟正文、弱化颜色，不再用主题色按钮样式。
        TextButton(
          onPressed: () => setState(() => expanded = !expanded),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.secondary,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(expanded ? '收起' : '展开'),
        ),
    ],
  );

  Widget _eps(Video v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '剧集',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '${v.episodes.length} 集',
              style: const TextStyle(color: AppColors.secondary),
            ),
            if (v.episodes.length > 1)
              TextButton.icon(
                onPressed: () => _toggleReversed(v),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.secondary,
                ),
                icon: const Icon(Icons.swap_vert, size: 18),
                label: Text(reversed ? '正序' : '倒序'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (v.episodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: AppEmptyView(message: '暂时没有可用剧集'),
          )
        else if (v.episodes.length <= _epsGroupSize)
          _epsWrap(v, 0, v.episodes.length)
        else
          _epsGroups(v),
      ],
    );
  }

  void _toggleReversed(Video v) {
    setState(() {
      reversed = !reversed;
      final total = v.episodes.length;
      if (total > _epsGroupSize) {
        // 倒序后保持选中集所在分组展开。
        final displayIdx = reversed
            ? total - 1 - selected.clamp(0, total - 1)
            : selected.clamp(0, total - 1);
        _expandedEpsGroups
          ..clear()
          ..add(displayIdx ~/ _epsGroupSize);
      }
    });
  }

  /// 超过 100 集时按 100 集一组折叠展示，默认只展开选中集所在分组。
  Widget _epsGroups(Video v) {
    final total = v.episodes.length;
    final groupCount = (total + _epsGroupSize - 1) ~/ _epsGroupSize;
    return Column(
      children: [
        for (var g = 0; g < groupCount; g++) ...[
          _epsGroupHeader(total, g),
          if (_expandedEpsGroups.contains(g))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _epsWrap(
                v,
                g * _epsGroupSize,
                math.min((g + 1) * _epsGroupSize, total),
              ),
            ),
        ],
      ],
    );
  }

  Widget _epsGroupHeader(int total, int group) {
    final start = group * _epsGroupSize;
    final end = math.min(start + _epsGroupSize, total);
    // 显示顺序对应的实际集号范围（倒序时组内集号从大到小）。
    final first = reversed ? total - start : start + 1;
    final last = reversed ? total - end + 1 : end;
    final lo = math.min(first, last);
    final hi = math.max(first, last);
    final isExpanded = _expandedEpsGroups.contains(group);
    return InkWell(
      onTap: () => setState(() {
        if (isExpanded) {
          _expandedEpsGroups.remove(group);
        } else {
          _expandedEpsGroups.add(group);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '第 $lo–$hi 集',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.secondary,
                ),
              ),
            ),
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: AppColors.secondary,
            ),
          ],
        ),
      ),
    );
  }

  /// 渲染显示顺序区间 [start, end) 内的剧集按钮。
  Widget _epsWrap(Video v, int start, int end) {
    final total = v.episodes.length;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(end - start, (i) {
        final idx = reversed ? total - 1 - (start + i) : start + i;
        final episode = v.episodes[idx];
        return ChoiceChip(
          label: Text(episode.name),
          selected: selected == idx,
          selectedColor: AppColors.accent,
          labelStyle: TextStyle(
            color: selected == idx ? AppColors.onAccent : AppColors.secondary,
          ),
          showCheckmark: false,
          onSelected: (_) {
            setState(() => selected = idx);
            _play(episodeIndex: idx);
          },
        );
      }),
    );
  }
}
