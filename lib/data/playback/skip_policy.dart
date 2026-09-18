import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按影片缓存跳过片头/片尾时长。未设置时默认关闭。
const skipPolicyStoreKey = 'skip_policy_by_video_v1';

/// 片头/片尾跳过预设（秒）。0 表示关闭。
const skipDurationPresets = [30, 60, 90];
const skipDurationMin = 1;
const skipDurationMax = 600;
const skipPolicyMaxEntries = 200;

/// 单个影片的片头、片尾跳过配置，所有时长均以秒为单位。
class SkipPolicy {
  /// [introSeconds]/[outroSeconds] 为 0 时表示关闭对应跳过功能。
  const SkipPolicy({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  bool get introEnabled => introSeconds > 0;
  bool get outroEnabled => outroSeconds > 0;
  bool get isOff => !introEnabled && !outroEnabled;

  Map<String, int> toJson() => {
    'introSeconds': introSeconds,
    'outroSeconds': outroSeconds,
  };

  /// 从持久化数据恢复配置；脏数据会被归零或限制在合法范围内。
  factory SkipPolicy.fromJson(Object? raw) {
    if (raw is! Map) return const SkipPolicy();
    return SkipPolicy(
      introSeconds: clampSkipSeconds(_int(raw['introSeconds'])),
      outroSeconds: clampSkipSeconds(_int(raw['outroSeconds'])),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkipPolicy &&
          introSeconds == other.introSeconds &&
          outroSeconds == other.outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);
}

int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;

/// 将用户输入限制到 0（关闭）或 [skipDurationMin]～[skipDurationMax]。
int clampSkipSeconds(int seconds) {
  if (seconds <= 0) return 0;
  if (seconds < skipDurationMin) return skipDurationMin;
  if (seconds > skipDurationMax) return skipDurationMax;
  return seconds;
}

bool isSkipPreset(int seconds) => skipDurationPresets.contains(seconds);

/// 生成人类可读的跳过时长标签。
String skipDurationLabel(int seconds) {
  if (seconds <= 0) return '关闭';
  if (isSkipPreset(seconds)) return '$seconds 秒';
  return '自定义 · $seconds 秒';
}

/// 当前位置仍在片头窗口内，起播或续播时应跳到片头结束点。
///
/// [position] 是本次判断使用的播放位置，[duration] 是完整片长。
bool shouldSkipIntro({
  required int introSeconds,
  required Duration position,
  required Duration duration,
}) {
  if (introSeconds <= 0 || duration <= Duration.zero) return false;
  final intro = Duration(seconds: introSeconds);
  if (duration <= intro) return false;
  return position < intro - const Duration(seconds: 1);
}

/// 片头判断用续播锚点，避免起播瞬间 native position 仍为 0 而误跳。
/// 返回 [resumePosition] 与 [playerPosition] 中更靠后的一个。
Duration skipIntroDecisionPosition({
  required Duration resumePosition,
  required Duration playerPosition,
}) => resumePosition > playerPosition ? resumePosition : playerPosition;

/// 剩余时长落入片尾窗口，应跳到片尾结束或下一集。
///
/// 最后 2 秒不再触发跳转，避免播放器即将自然结束时反复 seek。
bool shouldSkipOutro({
  required int outroSeconds,
  required Duration position,
  required Duration duration,
}) {
  if (outroSeconds <= 0 || duration <= Duration.zero) return false;
  final outro = Duration(seconds: outroSeconds);
  if (duration <= outro) return false;
  final remaining = duration - position;
  return remaining <= outro && remaining > const Duration(seconds: 2);
}

/// 使用 SharedPreferences 持久化“影片 ID -> 跳过策略”的轻量存储。
abstract final class SkipPolicyStore {
  /// 读取完整策略表；损坏或不兼容的 JSON 按空表处理。
  static Future<Map<String, dynamic>> _loadMap() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(skipPolicyStoreKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (_) {
      return {};
    }
  }

  /// 读取 [videoGlobalId] 对应的策略；空 ID 或无记录时返回关闭状态。
  static Future<SkipPolicy> load(String videoGlobalId) async {
    if (videoGlobalId.isEmpty) return const SkipPolicy();
    final map = await _loadMap();
    return SkipPolicy.fromJson(map[videoGlobalId]);
  }

  /// 保存一部影片的 [policy]，关闭状态会直接删除该影片记录。
  ///
  /// 条目超过 [skipPolicyMaxEntries] 时按 Map 插入顺序淘汰最旧记录。
  static Future<void> save(String videoGlobalId, SkipPolicy policy) async {
    if (videoGlobalId.isEmpty) return;
    final map = await _loadMap();
    map.remove(videoGlobalId);
    if (!policy.isOff) {
      map[videoGlobalId] = policy.toJson();
      while (map.length > skipPolicyMaxEntries) {
        map.remove(map.keys.first);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (map.isEmpty) {
      await prefs.remove(skipPolicyStoreKey);
    } else {
      await prefs.setString(skipPolicyStoreKey, jsonEncode(map));
    }
  }
}

final skipPolicyProvider =
    AsyncNotifierProvider.family<SkipPolicyNotifier, SkipPolicy, String>(
      SkipPolicyNotifier.new,
    );

/// 面向界面的单影片跳过策略状态控制器。
class SkipPolicyNotifier extends AsyncNotifier<SkipPolicy> {
  /// [videoGlobalId] 是跨来源稳定的影片标识，用作持久化键。
  SkipPolicyNotifier(this.videoGlobalId);

  final String videoGlobalId;

  @override
  Future<SkipPolicy> build() => SkipPolicyStore.load(videoGlobalId);

  /// 只更新片头秒数，保留当前片尾设置。
  Future<void> setIntroSeconds(int seconds) => _save(
    SkipPolicy(
      introSeconds: clampSkipSeconds(seconds),
      outroSeconds: (state.value ?? const SkipPolicy()).outroSeconds,
    ),
  );

  /// 只更新片尾秒数，保留当前片头设置。
  Future<void> setOutroSeconds(int seconds) => _save(
    SkipPolicy(
      introSeconds: (state.value ?? const SkipPolicy()).introSeconds,
      outroSeconds: clampSkipSeconds(seconds),
    ),
  );

  /// 先乐观更新状态，再异步写入本地存储。
  Future<void> _save(SkipPolicy policy) async {
    state = AsyncData(policy);
    await SkipPolicyStore.save(videoGlobalId, policy);
  }
}
