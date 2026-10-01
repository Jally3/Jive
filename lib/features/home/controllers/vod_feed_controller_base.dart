import 'package:flutter/foundation.dart';

import '../../../data/content/video_matcher.dart';
import '../../../data/video_repository.dart';
import '../../../domain/video.dart';
import '../../../domain/vod_source.dart';
import '../support/curated_vod_search_pool.dart';

/// 推荐位/策展位 slot 模型的公共面：一条候选在当前来源下的
/// 匹配结果与"最优查询证据"。
abstract interface class VodMatchEvidenceSlot {
  Video? get matchedVideo;
  set matchedVideo(Video? value);
  String get evidenceQuery;
  set evidenceQuery(String value);
  int get rawResultCount;
  set rawResultCount(int value);
  List<String> get candidateTitles;
  set candidateTitles(List<String> value);
  Object? get lastError;
  set lastError(Object? value);
}

/// 两个首页 Feed 控制器（推荐/策展）共享的 VOD 匹配基础设施：
/// 来源与查询池接线、来源指纹、池租约获取与证据记录。
/// 各自的分页调度、会话缓存与通知节流仍留在子类。
abstract class VodMatchingFeedControllerBase extends ChangeNotifier {
  VodMatchingFeedControllerBase({
    required this.source,
    required this.videoRepository,
    required CuratedVodSearchPool searchPool,
    this.matcher = const VideoMatcher(),
  }) : _searchPool = searchPool,
       sourceFingerprint = curatedVodSourceFingerprint(source);

  /// 当前匹配的 VOD 来源。推荐控制器切源时会整体重指。
  VodSource source;
  final VideoRepository videoRepository;
  final VideoMatcher matcher;

  /// 策展控制器未注入池时自建并负责关闭；推荐控制器共享首页池。
  final CuratedVodSearchPool _searchPool;

  /// 当前来源指纹；推荐控制器切源时更新，策展控制器保持只读。
  String sourceFingerprint;

  /// 供子类使用池的同源只读能力（peekReady）与自建池的关闭。
  @protected
  CuratedVodSearchPool get searchPool => _searchPool;

  /// 从池里租一条关键词查询：优先走可取消仓储，供上层实现
  /// 并发上限、超时与取消语义。
  CuratedVodSearchLease acquireVodSearch({
    required VodSource source,
    required String query,
    SearchCacheMode mode = SearchCacheMode.preferCache,

    /// 搜索期间来源可能被整体切换；调用方可在入口快照指纹传入，
    /// 保证"来源+指纹"成对使用。
    String? fingerprint,
  }) => _searchPool.acquire(
    sourceFingerprint: fingerprint ?? sourceFingerprint,
    query: query,
    mode: mode,
    loader: (abortTrigger) => videoRepository is CancellableVideoRepository
        ? (videoRepository as CancellableVideoRepository).fetchPageCancellable(
            source,
            page: 1,
            keyword: query,
            abortTrigger: abortTrigger,
          )
        : videoRepository.fetchPage(source, page: 1, keyword: query),
  );

  /// 记录"结果数最多的那条查询"作为候选位的检索证据；命中更优时
  /// 返回 true（策展控制器据此同步 queryIndex）。
  bool recordMatchEvidence(
    VodMatchEvidenceSlot slot, {
    required String query,
    required VideoPage page,
  }) {
    final count = page.total ?? page.items.length;
    if (slot.evidenceQuery.isNotEmpty && count <= slot.rawResultCount) {
      return false;
    }
    slot
      ..evidenceQuery = query
      ..rawResultCount = count
      ..candidateTitles = page.items
          .map((video) => video.title.trim())
          .where((title) => title.isNotEmpty)
          .take(5)
          .toList(growable: false);
    return true;
  }
}
