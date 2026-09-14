import 'dart:convert';
import 'dart:math';

import '../../domain/library.dart';
import '../../domain/watch_record.dart';

Map<String, dynamic> recommendationPreferencePayload(
  List<WatchRecord> history,
  List<FavoriteRecord> library,
) {
  final recentHistory = [...history]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final recentLibrary = [...library]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return {
    'history': [
      for (final record
          in recentHistory
              .where((item) => item.completed || item.progress >= 0.05)
              .take(20))
        {
          'title': _trim(record.video.title, 100),
          'year': record.video.year,
          'category': _trim(record.video.category, 50),
          'episodeName': _trim(record.episodeName, 50),
          'progress': double.parse(record.progress.toStringAsFixed(3)),
          'completed': record.completed,
          'watchedAt': record.updatedAt.toIso8601String(),
        },
    ],
    'library': [
      for (final record
          in recentLibrary
              .where((item) => item.isFavorite || item.isFollowing)
              .take(10))
        {
          'title': _trim(record.video.title, 100),
          'year': record.video.year,
          'category': _trim(record.video.category, 50),
          'favorite': record.isFavorite,
          'following': record.isFollowing,
          'updatedAt': record.updatedAt.toIso8601String(),
        },
    ],
  };
}

Map<String, dynamic> backendRecommendationPayload({
  required String clientRequestId,
  required List<WatchRecord> history,
  required List<FavoriteRecord> library,
  String locale = 'zh-CN',
  int pageSize = 24,
}) {
  final payload = {
    'clientRequestId': clientRequestId,
    'locale': _trim(locale, 20),
    'pageSize': pageSize.clamp(12, 24),
    ...recommendationPreferencePayload(history, library),
  };
  if (utf8.encode(jsonEncode(payload)).length > 64 * 1024) {
    throw const FormatException('推荐请求超过 64 KiB');
  }
  return payload;
}

String createClientRequestId([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _trim(String value, int maximum) {
  final trimmed = value.trim();
  return trimmed.length <= maximum ? trimmed : trimmed.substring(0, maximum);
}
