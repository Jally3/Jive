import '../../domain/library.dart';
import '../../domain/recommendation.dart';
import '../../domain/watch_record.dart';

abstract interface class RecommendationClient {
  Future<RecommendationBatch> recommend({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  });
}

abstract interface class PaginatedRecommendationClient
    implements RecommendationClient {
  Future<RecommendationBatch> nextPage(String cursor);
  Future<void> reportEvent(RecommendationEvent event);
}

sealed class RecommendationStreamEvent {
  const RecommendationStreamEvent();
}

class RecommendationStreamStart extends RecommendationStreamEvent {
  const RecommendationStreamStart({
    required this.requestId,
    required this.clientRequestId,
    required this.mode,
    required this.source,
  });

  final String requestId;
  final String clientRequestId;
  final RecommendationMode mode;
  final RecommendationSource source;
}

class RecommendationStreamItem extends RecommendationStreamEvent {
  const RecommendationStreamItem({required this.index, required this.item});

  final int index;
  final RecommendationCandidate item;
}

class RecommendationStreamDone extends RecommendationStreamEvent {
  const RecommendationStreamDone(this.result);

  final RecommendationBatch result;
}

/// Repository-level signal that provisional stream state must be discarded
/// before a cached terminal result is delivered.
class RecommendationStreamReset extends RecommendationStreamEvent {
  const RecommendationStreamReset();
}

class RecommendationStreamRequest {
  const RecommendationStreamRequest({
    required this.events,
    required this.cancel,
  });

  final Stream<RecommendationStreamEvent> events;
  final Future<void> Function() cancel;
}

abstract interface class StreamingRecommendationClient {
  RecommendationStreamRequest recommendStream({
    required List<WatchRecord> history,
    required List<FavoriteRecord> library,
  });

  RecommendationStreamRequest nextPageStream(String cursor);
}

enum RecommendationEventType {
  candidateExposed('candidate_exposed'),
  vodMatched('vod_matched'),
  vodNotFound('vod_not_found'),
  vodAmbiguous('vod_ambiguous'),
  vodSearchFailed('vod_search_failed'),
  manualSearchOpened('manual_search_opened'),
  sourceSwitchOpened('source_switch_opened'),
  manualPlayableFound('manual_playable_found');

  const RecommendationEventType(this.wireName);
  final String wireName;
}

class RecommendationEvent {
  const RecommendationEvent({
    required this.sessionId,
    required this.pageIndex,
    required this.candidatePosition,
    required this.type,
    required this.occurredAt,
  });
  final String sessionId;
  final int pageIndex;
  final int candidatePosition;
  final RecommendationEventType type;
  final DateTime occurredAt;
}
