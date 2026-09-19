import '../../domain/playback_selection.dart';

const String downloadTaskFileName = 'download_tasks.json';
const int downloadFilterVersion = 1;

enum DownloadTaskStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

enum DownloadFailureReason {
  invalidSelection,
  unsupportedFormat,
  manifestRequestFailed,
  unsupportedHls,
  liveStream,
  encryptedStream,
  quotaExceeded,
  network,
  cacheWriteFailed,
  filterFailed,
  cancelled,
  sourceAccessDenied,
  sourceMissing,
  resourceInvalid,
  resourceTruncated,
  invalidEncryptionKey,
  localWriteFailed,
  offlineFilesIncomplete,
  unexpected,
}

enum DownloadPauseReason { user, network, lifecycle }

enum DownloadResumeResult { started, blockedByCellular, unavailable }

typedef DownloadSelectionResolver =
    Future<PlaybackSelection?> Function(DownloadTask task);

class DownloadTask {
  const DownloadTask({
    required this.taskId,
    required this.sourceId,
    required this.sourceVideoId,
    required this.title,
    required this.playbackLineIdentity,
    required this.episodeIdentity,
    required this.episodeId,
    required this.episodeName,
    required this.status,
    this.playbackUrl = '',
    this.mediaPlaylistUrl = '',
    this.contentKeyHash,
    this.revisionKeyHash,
    this.expectedResourceCount = 0,
    this.completedResourceCount = 0,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.speedBytesPerSecond = 0,
    this.filterVersion = downloadFilterVersion,
    this.filterConfidence,
    this.error,
    this.pauseReason,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
  });

  final String taskId;
  final String sourceId;
  final String sourceVideoId;
  final String title;
  final String playbackLineIdentity;
  final String episodeIdentity;
  final String episodeId;
  final String episodeName;
  final DownloadTaskStatus status;
  final String playbackUrl;
  final String mediaPlaylistUrl;
  final String? contentKeyHash;
  final String? revisionKeyHash;
  final int expectedResourceCount;
  final int completedResourceCount;
  final int totalBytes;
  final int downloadedBytes;
  final int speedBytesPerSecond;
  final int filterVersion;
  final double? filterConfidence;
  final DownloadFailureReason? error;
  final DownloadPauseReason? pauseReason;
  final int createdAtMs;
  final int updatedAtMs;

  double get progress => expectedResourceCount <= 0
      ? 0
      : (completedResourceCount / expectedResourceCount).clamp(0, 1);

  DownloadTask copyWith({
    DownloadTaskStatus? status,
    String? contentKeyHash,
    String? revisionKeyHash,
    int? expectedResourceCount,
    int? completedResourceCount,
    int? totalBytes,
    int? downloadedBytes,
    int? speedBytesPerSecond,
    int? filterVersion,
    double? filterConfidence,
    DownloadFailureReason? error,
    DownloadPauseReason? pauseReason,
    bool clearError = false,
    bool clearPauseReason = false,
    int? createdAtMs,
    int? updatedAtMs,
    String? playbackUrl,
    String? mediaPlaylistUrl,
  }) => DownloadTask(
    taskId: taskId,
    sourceId: sourceId,
    sourceVideoId: sourceVideoId,
    title: title,
    playbackLineIdentity: playbackLineIdentity,
    episodeIdentity: episodeIdentity,
    episodeId: episodeId,
    episodeName: episodeName,
    status: status ?? this.status,
    playbackUrl: playbackUrl ?? this.playbackUrl,
    mediaPlaylistUrl: mediaPlaylistUrl ?? this.mediaPlaylistUrl,
    contentKeyHash: contentKeyHash ?? this.contentKeyHash,
    revisionKeyHash: revisionKeyHash ?? this.revisionKeyHash,
    expectedResourceCount: expectedResourceCount ?? this.expectedResourceCount,
    completedResourceCount:
        completedResourceCount ?? this.completedResourceCount,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    speedBytesPerSecond: speedBytesPerSecond ?? this.speedBytesPerSecond,
    filterVersion: filterVersion ?? this.filterVersion,
    filterConfidence: filterConfidence ?? this.filterConfidence,
    error: clearError ? null : (error ?? this.error),
    pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
    createdAtMs: createdAtMs ?? this.createdAtMs,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'taskId': taskId,
    'sourceId': sourceId,
    'sourceVideoId': sourceVideoId,
    'title': title,
    'playbackLineIdentity': playbackLineIdentity,
    'episodeIdentity': episodeIdentity,
    'episodeId': episodeId,
    'episodeName': episodeName,
    'status': status.name,
    'playbackUrl': playbackUrl,
    'mediaPlaylistUrl': mediaPlaylistUrl,
    'contentKeyHash': contentKeyHash,
    'revisionKeyHash': revisionKeyHash,
    'expectedResourceCount': expectedResourceCount,
    'completedResourceCount': completedResourceCount,
    'totalBytes': totalBytes,
    'downloadedBytes': downloadedBytes,
    'speedBytesPerSecond': speedBytesPerSecond,
    'filterVersion': filterVersion,
    'filterConfidence': filterConfidence,
    'error': error?.name,
    'pauseReason': pauseReason?.name,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('不支持的下载任务 schema 版本');
    }
    return DownloadTask(
      taskId: _required(json['taskId']),
      sourceId: _required(json['sourceId']),
      sourceVideoId: _required(json['sourceVideoId']),
      title: '${json['title'] ?? ''}',
      playbackLineIdentity: _required(json['playbackLineIdentity']),
      episodeIdentity: _required(json['episodeIdentity']),
      episodeId: '${json['episodeId'] ?? ''}',
      episodeName: '${json['episodeName'] ?? ''}',
      status: _taskStatus(json['status']),
      playbackUrl: '${json['playbackUrl'] ?? ''}',
      mediaPlaylistUrl: '${json['mediaPlaylistUrl'] ?? ''}',
      contentKeyHash: json['contentKeyHash'] as String?,
      revisionKeyHash: json['revisionKeyHash'] as String?,
      expectedResourceCount: _nonNegative(json['expectedResourceCount']),
      completedResourceCount: _nonNegative(json['completedResourceCount']),
      totalBytes: _nonNegative(json['totalBytes']),
      downloadedBytes: _nonNegative(json['downloadedBytes']),
      speedBytesPerSecond: _nonNegative(json['speedBytesPerSecond']),
      filterVersion: _nonNegative(json['filterVersion']),
      filterConfidence: (json['filterConfidence'] as num?)?.toDouble(),
      error: _failure(json['error']),
      pauseReason: _pauseReason(json['pauseReason']),
      createdAtMs: _nonNegative(json['createdAtMs']),
      updatedAtMs: _nonNegative(json['updatedAtMs']),
    );
  }
}

String _required(Object? value) {
  final parsed = '${value ?? ''}';
  if (parsed.isEmpty) throw const FormatException('下载任务缺少身份字段');
  return parsed;
}

int _nonNegative(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value') ?? 0;
  if (parsed < 0) throw const FormatException('下载任务字段不能为负');
  return parsed;
}

DownloadTaskStatus _taskStatus(Object? value) =>
    DownloadTaskStatus.values.firstWhere(
      (item) => item.name == value,
      orElse: () => throw const FormatException('未知下载任务状态'),
    );

DownloadFailureReason? _failure(Object? value) {
  if (value == null) return null;
  return DownloadFailureReason.values.firstWhere(
    (item) => item.name == value,
    orElse: () => throw const FormatException('未知下载失败原因'),
  );
}

DownloadPauseReason? _pauseReason(Object? value) {
  if (value == null) return null;
  return DownloadPauseReason.values.firstWhere(
    (item) => item.name == value,
    orElse: () => throw const FormatException('未知下载暂停原因'),
  );
}

String downloadFailureText(DownloadFailureReason? reason) => switch (reason) {
  DownloadFailureReason.invalidSelection => '播放信息不完整，无法下载',
  DownloadFailureReason.unsupportedFormat => '当前格式不支持下载',
  DownloadFailureReason.manifestRequestFailed => '视频清单获取失败，请重试',
  DownloadFailureReason.unsupportedHls => '视频清单包含不支持的内容',
  DownloadFailureReason.liveStream => '直播内容暂不支持下载',
  DownloadFailureReason.encryptedStream => '加密视频暂不支持下载',
  DownloadFailureReason.quotaExceeded => '存储空间不足',
  DownloadFailureReason.network => '网络请求失败，请重试',
  DownloadFailureReason.cacheWriteFailed => '缓存文件未能保存，请重试',
  DownloadFailureReason.filterFailed => '视频处理失败，请重试',
  DownloadFailureReason.cancelled => '任务已取消',
  DownloadFailureReason.sourceAccessDenied => '片源拒绝访问，请切换线路',
  DownloadFailureReason.sourceMissing => '视频分片已失效，请切换线路',
  DownloadFailureReason.resourceInvalid => '视频分片内容异常，请切换线路重试',
  DownloadFailureReason.resourceTruncated => '视频分片下载不完整，请重试',
  DownloadFailureReason.invalidEncryptionKey => '视频密钥内容异常，请切换线路',
  DownloadFailureReason.localWriteFailed => '本地文件写入失败，请检查设备存储',
  DownloadFailureReason.offlineFilesIncomplete => '离线文件不完整，请重试下载',
  DownloadFailureReason.unexpected => '下载处理失败，请重试',
  null => '下载失败，请重试',
};
