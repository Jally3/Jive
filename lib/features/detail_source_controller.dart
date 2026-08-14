import 'package:flutter/foundation.dart';
import '../data/video_repository.dart';
import '../data/vod_source_registry.dart';
import '../domain/video.dart';
import '../domain/vod_source.dart';

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

  VodSource? _lookupSource(String id) => registry.findById(id);

  List<VodSource> get _backupCandidates {
    final activeId = activeVideo.sourceId;
    return registry.searchableSources
        .where((s) => s.id != activeId)
        .take(3)
        .toList();
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
          final page = await repository
              .fetchPage(candidate, keyword: activeVideo.title)
              .timeout(const Duration(seconds: 8));
          if (!_isCurrent(generation)) return;
          final matched = _matchCandidates(page.items);
          _updateState(
            candidate.id,
            (s) => s.copyWith(
              status: matched.isEmpty
                  ? DetailSourceStatus.noResult
                  : DetailSourceStatus.hasResource,
              candidates: matched,
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

  List<Video> _matchCandidates(List<Video> results) {
    final title = _normalize(activeVideo.title);
    if (title.isEmpty) return results.take(3).toList();
    final matches = results
        .where(
          (v) =>
              _normalize(v.title).contains(title) ||
              title.contains(_normalize(v.title)),
        )
        .toList();
    matches.sort((a, b) => _matchScore(b).compareTo(_matchScore(a)));
    return matches.take(5).toList();
  }

  int _matchScore(Video candidate) {
    var score = 0;
    final currentTitle = _normalize(activeVideo.title);
    final candidateTitle = _normalize(candidate.title);
    if (candidateTitle == currentTitle) score += 100;
    if (candidate.year.isNotEmpty &&
        activeVideo.year.isNotEmpty &&
        candidate.year == activeVideo.year) {
      score += 30;
    }
    score += _peopleScore(candidate.actors, activeVideo.actors, 20);
    score += _peopleScore(candidate.director, activeVideo.director, 15);
    if (candidate.area.isNotEmpty &&
        activeVideo.area.isNotEmpty &&
        candidate.area == activeVideo.area) {
      score += 15;
    }
    if (candidate.category.isNotEmpty &&
        activeVideo.category.isNotEmpty &&
        candidate.category == activeVideo.category) {
      score += 10;
    }
    final currentCount = activeVideo.episodes.length;
    final candidateCount = candidate.episodes.length;
    if (currentCount > 0 && candidateCount > 0) {
      final max = currentCount > candidateCount ? currentCount : candidateCount;
      final diff = (currentCount - candidateCount).abs();
      if (diff == 0) {
        score += 10;
      } else if (diff * 2 > max) {
        score -= 30;
      }
    }
    return score;
  }

  int _peopleScore(String candidateValue, String currentValue, int score) {
    if (candidateValue.isEmpty || currentValue.isEmpty) return 0;
    final current = _splitPeople(currentValue);
    if (current.isEmpty) return 0;
    return _splitPeople(candidateValue).any(current.contains) ? score : 0;
  }

  Set<String> _splitPeople(String value) => value
      .split(RegExp(r'[,，、/;；\s]+'))
      .where((token) => token.isNotEmpty)
      .toSet();

  String _normalize(String s) =>
      s.replaceAll(RegExp(r'[\s\-_:：]+'), '').toLowerCase();

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
      final page = await repository
          .fetchPage(source, keyword: activeVideo.title)
          .timeout(const Duration(seconds: 8));
      if (!_isCurrent(generation)) return;
      final matched = _matchCandidates(page.items);
      _updateState(
        source.id,
        (s) => s.copyWith(
          status: matched.isEmpty
              ? DetailSourceStatus.noResult
              : DetailSourceStatus.hasResource,
          candidates: matched,
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
