import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../data/video_repository.dart';
import '../../domain/video.dart';
import '../../domain/vod_source.dart';

class SourceSearchState {
  const SourceSearchState({
    this.items = const [],
    this.nextPage = 1,
    this.total,
    this.hasMore = true,
    this.loading = false,
    this.queried = false,
    this.error,
  });

  final List<Video> items;
  final int nextPage;
  final int? total;
  final bool hasMore;
  final bool loading;
  final bool queried;
  final String? error;

  SourceSearchState copyWith({
    List<Video>? items,
    int? nextPage,
    int? total,
    bool? hasMore,
    bool? loading,
    bool? queried,
    String? error,
    bool clearError = false,
  }) => SourceSearchState(
    items: items ?? this.items,
    nextPage: nextPage ?? this.nextPage,
    total: total ?? this.total,
    hasMore: hasMore ?? this.hasMore,
    loading: loading ?? this.loading,
    queried: queried ?? this.queried,
    error: clearError ? null : (error ?? this.error),
  );
}

class SearchSessionState {
  const SearchSessionState({
    this.keyword = '',
    this.activeSourceId = '',
    this.sources = const {},
    this.generation = 0,
  });

  final String keyword;
  final String activeSourceId;
  final Map<String, SourceSearchState> sources;
  final int generation;

  SearchSessionState copyWith({
    String? keyword,
    String? activeSourceId,
    Map<String, SourceSearchState>? sources,
    int? generation,
  }) => SearchSessionState(
    keyword: keyword ?? this.keyword,
    activeSourceId: activeSourceId ?? this.activeSourceId,
    sources: sources ?? this.sources,
    generation: generation ?? this.generation,
  );
}

/// 数量降级展示：接口提供准确 total 时显示数字；只能从分页推断还有更多时
/// 显示 N+；无 total 且分页也无法推断时显示“有结果”，不得用第一页条数冒充总数。
String formatSourceCount(SourceSearchState? state) {
  if (state == null || !state.queried) return '';
  if (state.error != null) return '!';
  if (state.total != null) return '${state.total}';
  if (state.items.isEmpty) return '0';
  if (state.hasMore) return '${state.items.length}+';
  return '有结果';
}

class _CacheEntry {
  _CacheEntry(this.page, this.fetchedAt);
  final VideoPage page;
  final DateTime fetchedAt;
  bool get expired =>
      DateTime.now().difference(fetchedAt) > const Duration(minutes: 7);
}

/// 内存级健康跟踪：连续失败次数与最近成功/失败/使用时间，不持久化。
class _SourceHealth {
  int consecutiveFailures = 0;
  DateTime? lastFailureAt;
  DateTime? lastSuccessAt;
  DateTime? lastUsedAt;
}

class MultiSourceSearchController extends ChangeNotifier {
  MultiSourceSearchController({
    required this.repository,
    required this.globalSource,
    required this.allSources,
    @visibleForTesting Duration? requestTimeout,
  }) : _requestTimeout = requestTimeout ?? const Duration(seconds: 8),
       _state = SearchSessionState(activeSourceId: globalSource.id);

  final VideoRepository repository;
  VodSource globalSource;
  final List<VodSource> allSources;

  SearchSessionState _state;
  SearchSessionState get state => _state;

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, _SourceHealth> _health = {};
  final Map<String, int> _sourceRequestSeq = {};
  Timer? _debounce;
  Timer? _backupDelay;
  int _searchGeneration = 0;
  bool _disposed = false;
  final Duration _requestTimeout;
  static const _maxBackup = 3;
  static const _maxConcurrentBackup = 2;
  static const _failureCooldown = Duration(minutes: 10);

  List<VodSource> get _searchableSources =>
      allSources.where((s) => s.enabled && s.search).toList();

  /// 备用源候选：按“最近使用 → 健康 → 配置优先级”排序。
  List<VodSource> get _backupCandidates {
    final active = _state.activeSourceId;
    final candidates = _searchableSources.where((s) => s.id != active).toList();
    final order = {
      for (var i = 0; i < candidates.length; i++) candidates[i].id: i,
    };
    candidates.sort((a, b) {
      final healthA = _health[a.id];
      final healthB = _health[b.id];
      final usedA = healthA?.lastUsedAt;
      final usedB = healthB?.lastUsedAt;
      if (usedA != null && usedB == null) return -1;
      if (usedA == null && usedB != null) return 1;
      if (usedA != null && usedB != null && usedA != usedB) {
        return usedB.compareTo(usedA);
      }
      final failA = healthA?.consecutiveFailures ?? 0;
      final failB = healthB?.consecutiveFailures ?? 0;
      if (failA != failB) return failA.compareTo(failB);
      return order[a.id]!.compareTo(order[b.id]!);
    });
    return candidates;
  }

  /// 连续失败 ≥2 且距上次失败不足 [_failureCooldown] 的源临时退出自动探测，
  /// 但仍可由用户手动查询。
  bool _temporarilyExcluded(String sourceId) {
    final health = _health[sourceId];
    if (health == null || health.consecutiveFailures < 2) return false;
    final lastFailure = health.lastFailureAt;
    if (lastFailure == null) return false;
    return DateTime.now().difference(lastFailure) < _failureCooldown;
  }

  void _recordSuccess(String sourceId) {
    final health = _healthOf(sourceId);
    health.consecutiveFailures = 0;
    health.lastSuccessAt = DateTime.now();
  }

  void _recordFailure(String sourceId) {
    final health = _healthOf(sourceId);
    health.consecutiveFailures++;
    health.lastFailureAt = DateTime.now();
  }

  _SourceHealth _healthOf(String sourceId) =>
      _health.putIfAbsent(sourceId, _SourceHealth.new);

  /// 每个源独立的请求序号，保证同一源“后发请求优先”，旧请求完成时不会
  /// 覆盖或误清新请求的状态。
  int _nextSeq(String sourceId) =>
      _sourceRequestSeq[sourceId] = (_sourceRequestSeq[sourceId] ?? 0) + 1;

  /// generation 不匹配（搜索会话已重置）时复位该源的 loading 标记，
  /// 并清掉 queried，保证该源之后仍可被重新点击请求。
  void _resetLoading(String sourceId, int seq) {
    if (_sourceRequestSeq[sourceId] != seq) return;
    final current = _state.sources[sourceId];
    if (current == null || !current.loading) return;
    _updateSourceState(
      sourceId,
      (s) => s.copyWith(loading: false, queried: false),
    );
  }

  void onGlobalSourceChanged(VodSource newSource) {
    globalSource = newSource;
  }

  void resetToGlobalSource() {
    _debounce?.cancel();
    _backupDelay?.cancel();
    _searchGeneration++;
    _state = SearchSessionState(activeSourceId: globalSource.id);
    notifyListeners();
  }

  void clear() {
    _debounce?.cancel();
    _backupDelay?.cancel();
    _searchGeneration++;
    _state = SearchSessionState(activeSourceId: _state.activeSourceId);
    notifyListeners();
  }

  void search(String keyword) {
    _debounce?.cancel();
    _backupDelay?.cancel();
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      clear();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () {
      _doSearch(trimmed);
    });
  }

  Future<void> _doSearch(String keyword) async {
    _searchGeneration++;
    final gen = _searchGeneration;
    final activeId = _state.activeSourceId;
    _state = SearchSessionState(
      keyword: keyword,
      activeSourceId: activeId,
      sources: {},
      generation: gen,
    );
    notifyListeners();

    _searchActiveSource(keyword, gen);
    if (keyword.length >= 2) {
      _scheduleBackupSearch(keyword, gen);
    }
  }

  Future<void> _searchActiveSource(String keyword, int gen) async {
    final sourceId = _state.activeSourceId;
    final source = _searchableSources
        .where((s) => s.id == sourceId)
        .firstOrNull;
    if (source == null) return;
    final seq = _nextSeq(sourceId);
    _updateSourceState(
      sourceId,
      (s) => s.copyWith(loading: true, queried: true, clearError: true),
    );
    try {
      final page = await _fetchWithCache(
        source,
        keyword,
        1,
      ).timeout(_requestTimeout);
      _recordSuccess(sourceId);
      if (gen != _searchGeneration) return _resetLoading(sourceId, seq);
      if (_sourceRequestSeq[sourceId] != seq) return;
      _updateSourceState(
        sourceId,
        (s) => s.copyWith(
          items: page.items,
          nextPage: 2,
          total: page.total,
          hasMore: page.hasMore,
          loading: false,
        ),
      );
      if (page.items.isEmpty) _expediteBackupProbe(keyword, gen);
    } catch (e) {
      _recordFailure(sourceId);
      if (gen != _searchGeneration) return _resetLoading(sourceId, seq);
      if (_sourceRequestSeq[sourceId] != seq) return;
      _updateSourceState(
        sourceId,
        (s) => s.copyWith(loading: false, error: e.toString()),
      );
      _expediteBackupProbe(keyword, gen);
    }
  }

  void _scheduleBackupSearch(String keyword, int gen) {
    _backupDelay = Timer(const Duration(milliseconds: 300), () {
      _probeBackups(keyword, gen);
    });
  }

  /// 当前源无结果（或失败）时立即启动已排期的备用探测，不再等 300ms。
  void _expediteBackupProbe(String keyword, int gen) {
    if (_backupDelay?.isActive != true) return;
    _backupDelay!.cancel();
    if (gen != _searchGeneration) return;
    _probeBackups(keyword, gen);
  }

  Future<void> _probeBackups(String keyword, int gen) async {
    final candidates = _backupCandidates
        .where((s) => !_temporarilyExcluded(s.id))
        .take(_maxBackup)
        .toList();
    if (candidates.isEmpty) return;
    var slot = 0;
    Future<void> probeOne(VodSource source) async {
      final seq = _nextSeq(source.id);
      _updateSourceState(
        source.id,
        (s) => s.copyWith(loading: true, queried: true, clearError: true),
      );
      try {
        final page = await _fetchWithCache(
          source,
          keyword,
          1,
        ).timeout(_requestTimeout);
        _recordSuccess(source.id);
        if (gen != _searchGeneration) return _resetLoading(source.id, seq);
        if (_sourceRequestSeq[source.id] != seq) return;
        _updateSourceState(
          source.id,
          (s) => s.copyWith(
            items: page.items,
            nextPage: 2,
            total: page.total,
            hasMore: page.hasMore,
            loading: false,
          ),
        );
      } catch (e) {
        _recordFailure(source.id);
        if (gen != _searchGeneration) return _resetLoading(source.id, seq);
        if (_sourceRequestSeq[source.id] != seq) return;
        _updateSourceState(
          source.id,
          (s) => s.copyWith(loading: false, error: e.toString()),
        );
      }
    }

    Future<void> runSlot() async {
      if (slot >= candidates.length) return;
      final source = candidates[slot++];
      await probeOne(source);
      if (gen == _searchGeneration) await runSlot();
    }

    final parallel = List.generate(
      _maxConcurrentBackup.clamp(0, candidates.length),
      (_) => runSlot(),
    );
    await Future.wait(parallel);
  }

  Future<void> switchSource(String sourceId) async {
    if (sourceId == _state.activeSourceId) return;
    _healthOf(sourceId).lastUsedAt = DateTime.now();
    // 不递增 generation：切换来源不换关键词，进行中的备用探测结果仍然有效，
    // 直接作废会让对应来源卡在 loading。
    _state = _state.copyWith(activeSourceId: sourceId);
    notifyListeners();

    final keyword = _state.keyword;
    if (keyword.isEmpty) return;
    final existing = _state.sources[sourceId];
    // 重入守卫：该源请求进行中时不重复发请求，等待其写回结果。
    if (existing != null && existing.loading) return;
    if (existing != null && existing.queried && existing.error == null) return;
    await _searchActiveSource(keyword, _searchGeneration);
  }

  Future<void> searchSingleSource(String sourceId) async {
    final keyword = _state.keyword;
    if (keyword.isEmpty) return;
    final existing = _state.sources[sourceId];
    // 重入守卫：请求进行中（如快速双击）时不重复发请求。
    if (existing != null && existing.loading) return;
    final source = _searchableSources
        .where((s) => s.id == sourceId)
        .firstOrNull;
    if (source == null) return;
    // 不递增 generation：手动补查单个源不应打断其他源进行中的请求。
    final gen = _searchGeneration;
    final seq = _nextSeq(sourceId);
    _updateSourceState(
      sourceId,
      (s) => s.copyWith(loading: true, queried: true, clearError: true),
    );
    try {
      final page = await _fetchWithCache(
        source,
        keyword,
        1,
      ).timeout(_requestTimeout);
      _recordSuccess(sourceId);
      if (gen != _searchGeneration) return _resetLoading(sourceId, seq);
      if (_sourceRequestSeq[sourceId] != seq) return;
      _updateSourceState(
        sourceId,
        (s) => s.copyWith(
          items: page.items,
          nextPage: 2,
          total: page.total,
          hasMore: page.hasMore,
          loading: false,
        ),
      );
    } catch (e) {
      _recordFailure(sourceId);
      if (gen != _searchGeneration) return _resetLoading(sourceId, seq);
      if (_sourceRequestSeq[sourceId] != seq) return;
      _updateSourceState(
        sourceId,
        (s) => s.copyWith(loading: false, error: e.toString()),
      );
    }
  }

  Future<void> searchAllSources() async {
    final keyword = _state.keyword;
    if (keyword.isEmpty) return;
    final candidates = _backupCandidates.where((source) {
      final existing = _state.sources[source.id];
      if (existing != null && existing.loading) return false;
      return existing == null || !existing.queried || existing.error != null;
    }).toList();
    var slot = 0;
    Future<void> runSlot() async {
      if (slot >= candidates.length) return;
      final source = candidates[slot++];
      await searchSingleSource(source.id);
      await runSlot();
    }

    final parallel = List.generate(
      _maxConcurrentBackup.clamp(0, candidates.length),
      (_) => runSlot(),
    );
    await Future.wait(parallel);
  }

  Future<void> loadMore() async {
    final gen = _searchGeneration;
    final activeId = _state.activeSourceId;
    final keyword = _state.keyword;
    final current = _state.sources[activeId];
    if (current == null || current.loading || !current.hasMore) return;
    final source = _searchableSources
        .where((s) => s.id == activeId)
        .firstOrNull;
    if (source == null) return;
    final seq = _nextSeq(activeId);
    _updateSourceState(
      activeId,
      (s) => s.copyWith(loading: true, clearError: true),
    );
    try {
      final page = await _fetchWithCache(
        source,
        keyword,
        current.nextPage,
      ).timeout(_requestTimeout);
      if (_disposed || gen != _searchGeneration) {
        return _resetLoading(activeId, seq);
      }
      if (_sourceRequestSeq[activeId] != seq) return;
      final known = current.items.map((v) => v.globalId).toSet();
      _updateSourceState(
        activeId,
        (s) => s.copyWith(
          items: [
            ...s.items,
            ...page.items.where((v) => known.add(v.globalId)),
          ],
          nextPage: s.nextPage + 1,
          hasMore: page.hasMore,
          loading: false,
        ),
      );
    } catch (e) {
      if (_disposed || gen != _searchGeneration) {
        return _resetLoading(activeId, seq);
      }
      if (_sourceRequestSeq[activeId] != seq) return;
      _updateSourceState(
        activeId,
        (s) => s.copyWith(loading: false, error: e.toString()),
      );
    }
  }

  /// 下拉刷新只刷新当前搜索页来源：清除该源的缓存键并重新请求，
  /// 不连带刷新或重新探测备用源。
  Future<void> refresh() async {
    final keyword = _state.keyword;
    if (keyword.isEmpty) return;
    final activeId = _state.activeSourceId;
    _debounce?.cancel();
    _backupDelay?.cancel();
    _cache.removeWhere((key, _) => key.startsWith('$activeId:$keyword:'));
    final sources = Map<String, SourceSearchState>.from(_state.sources);
    sources[activeId] = const SourceSearchState();
    _state = _state.copyWith(sources: sources);
    notifyListeners();
    await _searchActiveSource(keyword, _searchGeneration);
  }

  Future<VideoPage> _fetchWithCache(
    VodSource source,
    String keyword,
    int page,
  ) async {
    final cacheKey = '${source.id}:$keyword:$page';
    final cached = _cache[cacheKey];
    if (cached != null && !cached.expired) return cached.page;
    final result = await repository.fetchPage(
      source,
      page: page,
      keyword: keyword,
    );
    _cache[cacheKey] = _CacheEntry(result, DateTime.now());
    return result;
  }

  void _updateSourceState(
    String sourceId,
    SourceSearchState Function(SourceSearchState) updater,
  ) {
    if (_disposed) return;
    final current = _state.sources[sourceId] ?? const SourceSearchState();
    final updated = updater(current);
    final newSources = Map<String, SourceSearchState>.from(_state.sources);
    newSources[sourceId] = updated;
    _state = _state.copyWith(sources: newSources);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _searchGeneration++;
    _debounce?.cancel();
    _backupDelay?.cancel();
    super.dispose();
  }
}
