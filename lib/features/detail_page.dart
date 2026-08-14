import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/theme.dart';
import '../core/app_states.dart';
import '../data/video_repository.dart';
import '../data/library_repository.dart';
import '../data/vod_source_registry.dart';
import '../domain/video.dart';
import '../domain/vod_source.dart';
import 'detail_source_controller.dart';
import 'detail_more_sources_sheet.dart';
import 'player_page.dart';

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
  bool reversed = false;
  int selected = 0;
  DetailSourceController? sc;

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
      setState(() {
        detail = v;
      });
      sc!.markActiveLoaded(v);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _play({int? episodeIndex}) async {
    if (sc == null || resolving) return;
    setState(() {
      resolving = true;
      if (episodeIndex != null) selected = episodeIndex;
    });
    final m = ScaffoldMessenger.of(context);
    try {
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
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerPage(video: fresh, episode: ep),
        ),
      );
    } catch (e) {
      if (mounted) {
        m.showSnackBar(SnackBar(content: Text('$e（可尝试查找其他来源）')));
      }
    } finally {
      if (mounted) setState(() => resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rs = ref.watch(vodSourceRegistryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('视频详情')),
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
    children: [
      _header(v),
      const SizedBox(height: 20),
      _playBtn(v),
      const SizedBox(height: 8),
      _favBtn(v),
      const SizedBox(height: 16),
      _sourceSection(),
      const SizedBox(height: 24),
      _desc(v),
      const SizedBox(height: 16),
      _eps(v),
    ],
  );

  Widget _header(Video v) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 128,
          child: AspectRatio(
            aspectRatio: 2 / 3,
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
            const SizedBox(height: 12),
            _Meta(
              icon: Icons.category_outlined,
              text: v.category.isEmpty ? '类型未知' : v.category,
            ),
            if (v.remarks.isNotEmpty) ...[
              const SizedBox(height: 8),
              _Meta(icon: Icons.update, text: v.remarks),
            ],
            if (v.year.isNotEmpty) ...[
              const SizedBox(height: 8),
              _Meta(icon: Icons.calendar_today, text: v.year),
            ],
            if (v.area.isNotEmpty) ...[
              const SizedBox(height: 8),
              _Meta(icon: Icons.public, text: v.area),
            ],
            if (v.actors.isNotEmpty) ...[
              const SizedBox(height: 8),
              _Meta(icon: Icons.people_outline, text: v.actors),
            ],
          ],
        ),
      ),
    ],
  );

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

  Widget _favBtn(Video v) => Consumer(
    builder: (_, ref, _) {
      final favs = ref.watch(favoriteControllerProvider);
      final fav =
          favs.value?.any((i) => i.video.globalId == v.globalId) ?? false;
      return SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: favs.isLoading
              ? null
              : () async {
                  try {
                    await ref
                        .read(favoriteControllerProvider.notifier)
                        .toggle(v);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(fav ? '已取消收藏' : '已收藏')),
                      );
                    }
                  } catch (_) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('收藏保存失败，请重试')),
                      );
                    }
                  }
                },
          icon: Icon(fav ? Icons.favorite : Icons.favorite_outline),
          label: Text(fav ? '取消收藏' : '收藏'),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前剧集在目标源不存在，已切换到第一集')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('该来源加载失败，已保留当前来源')));
      return;
    }
    detail = sc!.activeVideo;
    error = null;
    final matched = sc!.findEpisodeByName(prior);
    selected = matched ?? 0;
    if (matched == null && prior != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前剧集在目标源不存在，已切换到第一集')));
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
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
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
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() => expanded = !expanded),
            child: Text(expanded ? '收起' : '展开'),
          ),
        ),
    ],
  );

  Widget _eps(Video v) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              '剧集',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '${v.episodes.length} 集',
            style: const TextStyle(color: AppColors.secondary),
          ),
          if (v.episodes.length > 1)
            TextButton.icon(
              onPressed: () => setState(() => reversed = !reversed),
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
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: List.generate(v.episodes.length, (i) {
            final idx = reversed ? v.episodes.length - 1 - i : i;
            return ChoiceChip(
              label: Text(v.episodes[idx].name),
              selected: selected == idx,
              onSelected: (_) {
                setState(() => selected = idx);
                _play(episodeIndex: idx);
              },
            );
          }),
        ),
    ],
  );
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: AppColors.tertiary),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.secondary, fontSize: 13),
        ),
      ),
    ],
  );
}
