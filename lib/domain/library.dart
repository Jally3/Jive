import 'video.dart';

/// A personal-library entry. Favorites and follow updates share one snapshot.
class FavoriteRecord {
  const FavoriteRecord({
    required this.video,
    required this.createdAt,
    required this.updatedAt,
    this.isFavorite = true,
    this.isFollowing = false,
    this.followedAt,
    this.lastCheckedAt,
    this.acknowledgedEpisodeSignature = '',
    this.remoteEpisodeSignature = '',
    this.notifiedEpisodeSignature = '',
    this.viewedEpisodeSignature = '',
    this.acknowledgedEpisodeCount = 0,
    this.remoteEpisodeCount = 0,
    this.latestEpisodeLabel = '',
    this.unreadAddedCount = 0,
    this.checkError,
    this.sourceUnavailable = false,
  });

  final Video video;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isFavorite;
  final bool isFollowing;
  final DateTime? followedAt;
  final DateTime? lastCheckedAt;
  final String acknowledgedEpisodeSignature;
  final String remoteEpisodeSignature;
  final String notifiedEpisodeSignature;
  final String viewedEpisodeSignature;
  final int acknowledgedEpisodeCount;
  final int remoteEpisodeCount;
  final String latestEpisodeLabel;
  final int unreadAddedCount;
  final String? checkError;
  final bool sourceUnavailable;

  bool get hasUnreadUpdate => isFollowing && unreadAddedCount > 0;

  FavoriteRecord copyWith({
    Video? video,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isFavorite,
    bool? isFollowing,
    DateTime? followedAt,
    bool clearFollowedAt = false,
    DateTime? lastCheckedAt,
    String? acknowledgedEpisodeSignature,
    String? remoteEpisodeSignature,
    String? notifiedEpisodeSignature,
    String? viewedEpisodeSignature,
    int? acknowledgedEpisodeCount,
    int? remoteEpisodeCount,
    String? latestEpisodeLabel,
    int? unreadAddedCount,
    String? checkError,
    bool clearCheckError = false,
    bool? sourceUnavailable,
  }) => FavoriteRecord(
    video: video ?? this.video,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    isFavorite: isFavorite ?? this.isFavorite,
    isFollowing: isFollowing ?? this.isFollowing,
    followedAt: clearFollowedAt ? null : followedAt ?? this.followedAt,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    acknowledgedEpisodeSignature:
        acknowledgedEpisodeSignature ?? this.acknowledgedEpisodeSignature,
    remoteEpisodeSignature:
        remoteEpisodeSignature ?? this.remoteEpisodeSignature,
    notifiedEpisodeSignature:
        notifiedEpisodeSignature ?? this.notifiedEpisodeSignature,
    viewedEpisodeSignature:
        viewedEpisodeSignature ?? this.viewedEpisodeSignature,
    acknowledgedEpisodeCount:
        acknowledgedEpisodeCount ?? this.acknowledgedEpisodeCount,
    remoteEpisodeCount: remoteEpisodeCount ?? this.remoteEpisodeCount,
    latestEpisodeLabel: latestEpisodeLabel ?? this.latestEpisodeLabel,
    unreadAddedCount: unreadAddedCount ?? this.unreadAddedCount,
    checkError: clearCheckError ? null : checkError ?? this.checkError,
    sourceUnavailable: sourceUnavailable ?? this.sourceUnavailable,
  );

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'isFavorite': isFavorite,
    'isFollowing': isFollowing,
    if (followedAt != null) 'followedAt': followedAt!.toIso8601String(),
    if (lastCheckedAt != null)
      'lastCheckedAt': lastCheckedAt!.toIso8601String(),
    'acknowledgedEpisodeSignature': acknowledgedEpisodeSignature,
    'remoteEpisodeSignature': remoteEpisodeSignature,
    'notifiedEpisodeSignature': notifiedEpisodeSignature,
    'viewedEpisodeSignature': viewedEpisodeSignature,
    'acknowledgedEpisodeCount': acknowledgedEpisodeCount,
    'remoteEpisodeCount': remoteEpisodeCount,
    'latestEpisodeLabel': latestEpisodeLabel,
    'unreadAddedCount': unreadAddedCount,
    if (checkError != null) 'checkError': checkError,
    'sourceUnavailable': sourceUnavailable,
  };

  static FavoriteRecord? tryFromJson(Object? value) {
    if (value is! Map || value['video'] is! Map) return null;
    try {
      final video = Video.fromJson(
        Map<String, dynamic>.from(value['video'] as Map),
      );
      final createdAt = DateTime.tryParse('${value['createdAt'] ?? ''}');
      final updatedAt = DateTime.tryParse('${value['updatedAt'] ?? ''}');
      if (video.id.isEmpty ||
          video.title.isEmpty ||
          createdAt == null ||
          updatedAt == null) {
        return null;
      }
      return FavoriteRecord(
        video: video,
        createdAt: createdAt,
        updatedAt: updatedAt,
        // Records written before the independent flags were introduced were
        // favorites by definition, so a missing field migrates to true.
        isFavorite:
            value['isFollowing'] == true || value['isFavorite'] != false,
        isFollowing: value['isFollowing'] == true,
        followedAt: DateTime.tryParse('${value['followedAt'] ?? ''}'),
        lastCheckedAt: DateTime.tryParse('${value['lastCheckedAt'] ?? ''}'),
        acknowledgedEpisodeSignature:
            '${value['acknowledgedEpisodeSignature'] ?? ''}',
        remoteEpisodeSignature: '${value['remoteEpisodeSignature'] ?? ''}',
        notifiedEpisodeSignature: '${value['notifiedEpisodeSignature'] ?? ''}',
        viewedEpisodeSignature: '${value['viewedEpisodeSignature'] ?? ''}',
        acknowledgedEpisodeCount: _asNonNegativeInt(
          value['acknowledgedEpisodeCount'],
        ),
        remoteEpisodeCount: _asNonNegativeInt(value['remoteEpisodeCount']),
        latestEpisodeLabel: '${value['latestEpisodeLabel'] ?? ''}',
        unreadAddedCount: _asNonNegativeInt(value['unreadAddedCount']),
        checkError: value['checkError'] == null
            ? null
            : '${value['checkError']}',
        sourceUnavailable: value['sourceUnavailable'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

int _asNonNegativeInt(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value') ?? 0;
  return parsed < 0 ? 0 : parsed;
}

/// Stable, URL-free episode version.
String episodeVersionSignature(List<Episode> episodes) => [
  for (var index = 0; index < episodes.length; index++)
    _episodeVersionPart(episodes[index], index),
].join('|');

String _episodeVersionPart(Episode episode, int index) {
  if (episode.identity.trim().isNotEmpty) {
    return 'i:${Uri.encodeComponent(episode.identity.trim())}';
  }
  final number = episode.parsedEpisodeNumber;
  if (number != null) return 'n:$number';
  if (episode.normalizedName.isNotEmpty) {
    return 't:${Uri.encodeComponent(episode.normalizedName)}';
  }
  return 'p:$index';
}
