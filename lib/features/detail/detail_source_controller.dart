import 'package:flutter/foundation.dart';
import '../../data/content/cross_source_search_service.dart';
import '../../data/video_repository.dart';
import '../../data/vod_source/vod_source_registry.dart';
import '../../domain/video.dart';
import '../../domain/video_search_target.dart';
import '../../domain/vod_source.dart';

enum DetailSourceStatus {
  notDetected,
  detecting,
  hasResource,
  noResult,
  failed,
  loaded,
}

class DetailSourceState {
  const DetailSourceState({
    required this.source,
    this.status = DetailSourceStatus.notDetected,
    this.candidates = const [],
    this.detail,
    this.error,
  });

  final VodSource source;
  final DetailSourceStatus status;
  final List<Video> candidates;
  final Video? detail;
  final String? error;

  int? get episodeCount => detail?.episodes.length;

  DetailSourceState copyWith({
    DetailSourceStatus? status,
    List<Video>? candidates,
    Video? detail,
    String? error,
    bool clearDetail = false,
  }) => DetailSourceState(
    source: source,
    status: status ?? this.status,
    candidates: candidates ?? this.candidates,
    detail: clearDetail ? null : (detail ?? this.detail),
    error: error,
  );
}

class DetailSourceController extends ChangeNotifier {
  DetailSourceController({
    required this.repository,
    required this.registry,
    required Video initialVideo,
  }) : activeVideo = initialVideo {
    _sourceStates = [
      DetailSourceState(
        source:
            _lookupSource(initialVideo.sourceId) ??
            registry.enabledSources.first,
      ),
    ];
  }

  final VideoRepository repository;
  final VodSourceRegistry registry;
  Video activeVideo;
  List<DetailSourceState> _sourceStates = [];
  bool switching = false;
  int _generation = 0;
  bool _disposed = false;

  List<DetailSourceState> get sourceStates => List.unmodifiable(_sourceStates);
  String get activeSourceId => activeVideo.sourceId;

  CrossSourceSearchService get _crossSourceSearch =>
      CrossSourceSearchService(repository: repository, registry: registry);

  VodSource? _lookupSource(String id) => registry.findById(id);

  List<VodSource> get _backupCandidates {
    final activeId = activeVideo.sourceId;
    return _crossSourceSearch.candidateSources(excludedSourceId: activeId);
  }

  DetailSourceState? stateFor(String sourceId) {
    for (final s in _sourceStates) {
      if (s.source.id == sourceId) return s;
    }
    return null;
  }

  Future<void> detectOtherSources({bool all = false}) async {
    final generation = ++_generation;
    _resetStaleDetections();
    final candidates = (all ? registry.searchableSources : _backupCandidates)
        .where((source) => source.id != activeVideo.sourceId)
        .toList();
    final pending = candidates.where((candidate) {
      final existing = stateFor(candidate.id);
      return existing == null ||
          existing.status == DetailSourceStatus.notDetected ||
          existing.status == DetailSourceStatus.failed;
    }).toList();
    var cursor = 0;

    Future<void> runOne() async {
      while (cursor < pending.length && _isCurrent(generation)) {
        final candidate = pending[cursor++];
        _updateState(
          candidate.id,
          (s) => s.copyWith(status: DetailSourceStatus.detecting),
        );
        try {
          final result = await _crossSourceSearch.searchSource(
            candidate,
            VideoSearchTarget.fromVideo(activeVideo),
          );
          if (!_isCurrent(generation)) return;
          _updateState(
            candidate.id,
            (s) => s.copyWith(
              status: _detailStatus(result.status),
              candidates: result.candidate == null
                  ? const []
                  : [result.candidate!],
              error: result.error,
            ),
          );
        } catch (e) {
          if (!_isCurrent(generation)) return;
          _updateState(
            candidate.id,
            (s) => s.copyWith(
              status: DetailSourceStatus.failed,
              error: e.toString(),
            ),
          );
        }
      }
    }

    await Future.wait([runOne(), if (pending.length > 1) runOne()]);
  }

  Future<void> loadCandidateDetail(String sourceId, Video candidate) async {
    if (switching || _disposed) return;
    _generation++;
    _resetStaleDetections();
    final gen = _generation;
    switching = true;
    notifyListeners();
    try {
      // resolvePlayback 会校验可用 HTTPS 播放地址，没有可用剧集时抛异常，
      // 避免切到只有集名、实际无法播放的来源。
      final detail = await repository.resolvePlayback(
        _lookupSource(sourceId)!,
        candidate.ref,
      );
      if (!_isCurrent(gen)) return;
      _updateState(
        sourceId,
        (s) => s.copyWith(
          status: DetailSourceStatus.loaded,
          detail: detail,
          candidates: [candidate],
        ),
      );
      activeVideo = detail;
      switching = false;
      notifyListeners();
    } catch (e) {
      if (!_isCurrent(gen)) return;
      _updateState(
        sourceId,
        (s) =>
            s.copyWith(status: DetailSourceStatus.failed, error: e.toString()),
      );
      switching = false;
      notifyListeners();
    }
  }

  Future<void> retryDetection(String sourceId) async {
    final generation = ++_generation;
    _resetStaleDetections();
    _updateState(
      sourceId,
      (s) => s.copyWith(
        status: DetailSourceStatus.notDetected,
        error: null,
        clearDetail: true,
      ),
    );
    final source = _lookupSource(sourceId);
    if (source == null) return;
    _updateState(
      source.id,
      (s) => s.copyWith(status: DetailSourceStatus.detecting),
    );
    try {
      final result = await _crossSourceSearch.searchSource(
        source,
        VideoSearchTarget.fromVideo(activeVideo),
      );
      if (!_isCurrent(generation)) return;
      _updateState(
        source.id,
        (s) => s.copyWith(
          status: _detailStatus(result.status),
          candidates: result.candidate == null ? const [] : [result.candidate!],
          error: result.error,
        ),
      );
    } catch (e) {
      if (!_isCurrent(generation)) return;
      _updateState(
        source.id,
        (s) =>
            s.copyWith(status: DetailSourceStatus.failed, error: e.toString()),
      );
    }
  }

  DetailSourceStatus _detailStatus(CrossSourceSearchStatus status) =>
      switch (status) {
        CrossSourceSearchStatus.matched => DetailSourceStatus.hasResource,
        CrossSourceSearchStatus.notFound ||
        CrossSourceSearchStatus.ambiguous => DetailSourceStatus.noResult,
        CrossSourceSearchStatus.requestFailed => DetailSourceStatus.failed,
      };

  /// 新一轮操作会使旧的检测失效（generation 已变），把还停留在
  /// “检测中”的来源复位为“未检测”，避免界面上永久转圈。
  void _resetStaleDetections() {
    var changed = false;
    for (var i = 0; i < _sourceStates.length; i++) {
      final s = _sourceStates[i];
      if (s.status == DetailSourceStatus.detecting) {
        _sourceStates[i] = s.copyWith(status: DetailSourceStatus.notDetected);
        changed = true;
      }
    }
    if (changed && !_disposed) notifyListeners();
  }

  int? findEpisodeByName(String? name) {
    if (name == null || name.isEmpty) return null;
    final episodes = activeVideo.episodes;
    for (var i = 0; i < episodes.length; i++) {
      if (episodes[i].name == name) return i;
    }
    final targetNum = _parseEpisodeNumber(name);
    if (targetNum != null) {
      for (var i = 0; i < episodes.length; i++) {
        if (_parseEpisodeNumber(episodes[i].name) == targetNum) return i;
      }
    }
    return null;
  }

  int? _parseEpisodeNumber(String name) {
    final match = RegExp(r'(\d+)').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  void _updateState(
    String sourceId,
    DetailSourceState Function(DetailSourceState) updater,
  ) {
    final index = _sourceStates.indexWhere((s) => s.source.id == sourceId);
    if (index < 0) {
      final source = _lookupSource(sourceId);
      if (source == null) return;
      _sourceStates.add(updater(DetailSourceState(source: source)));
    } else {
      _sourceStates[index] = updater(_sourceStates[index]);
    }
    if (!_disposed) notifyListeners();
  }

  void ensureSourceState(VodSource source) {
    if (stateFor(source.id) == null) {
      _sourceStates.add(DetailSourceState(source: source));
      if (!_disposed) notifyListeners();
    }
  }

  void markActiveLoaded(Video detail) {
    activeVideo = detail;
    _updateState(
      detail.sourceId,
      (s) => s.copyWith(status: DetailSourceStatus.loaded, detail: detail),
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
