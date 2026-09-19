// 截图巡检集成测试：按 doc/flows/ 盘点的核心流程驱动应用
// （详情 → 播放器 → 首页续播 → 我的），供官网截图挑帧使用。
//
// 注意：`flutter test integration_test` 结束后会卸载应用，持久化数据
// 不跨轮保留；因此把「播放」排在首页截图之前——播放产生的观看记录经
// HistoryRepository._notify → WatchHistoryController 失效 → 首页续播条
// 响应式出现，「我的」页追更/收藏/最近观看也有了内容。
//
// 运行方式：fvm flutter test integration_test/screenshot_tour_test.dart -d <simulator-udid>
// 每个阶段输出带真实时间戳的 TOUR_STAGE:<name> 标记，外部配合
// `xcrun simctl io booted screenshot` 高频截帧后按标记区间挑帧。
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:jive/features/player/player_page.dart';
import 'package:jive/features/player/widgets/player_error_view.dart';
import 'package:jive/main.dart' as app_main;
import 'package:jive/shared/video_card.dart';

void _stage(String name) {
  // 带真实时间戳，供外部与截帧文件的 mtime 精确对位挑帧
  debugPrint('TOUR_STAGE:$name @ ${DateTime.now().toIso8601String()}');
}

/// 真实异步环境（LiveTestWidgetsFlutterBinding）下驻留指定秒数，
/// 期间持续 pump 让动画/网络图刷新走真实帧。
Future<void> _hold(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    await Future.delayed(const Duration(milliseconds: 250));
  }
}

Future<void> _holdSeconds(WidgetTester tester, int seconds) =>
    _hold(tester, Duration(seconds: seconds));

/// 轮询 finder 出现，出现即返回 true，超时返回 false。
Future<bool> _waitUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return true;
    await Future.delayed(const Duration(milliseconds: 300));
  }
  return false;
}

/// 返回上一页：播放器是自定义 IconButton(tooltip「返回」)，详情页是
/// AppBar 默认 BackButton；`tester.pageBack()` 只认 Cupertino 返回键，
/// 这里按形态逐一尝试。
Future<void> _goBack(WidgetTester tester) async {
  final customBack = find.byTooltip('返回');
  final materialBack = find.byType(BackButton);
  final cupertinoBack = find.byType(CupertinoNavigationBarBackButton);
  if (customBack.evaluate().isNotEmpty) {
    await tester.tap(customBack.first, warnIfMissed: false);
  } else if (materialBack.evaluate().isNotEmpty) {
    await tester.tap(materialBack.first, warnIfMissed: false);
  } else if (cupertinoBack.evaluate().isNotEmpty) {
    await tester.tap(cupertinoBack.first, warnIfMissed: false);
  }
  await _holdSeconds(tester, 2);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('screenshot tour: detail → player → home(resume) → profile',
      (tester) async {
    app_main.main();
    await tester.pump();
    await _holdSeconds(tester, 4); // 闪屏 800ms + 源注册表就绪

    // ── 等首页综合流出卡片（不在此截图，续播条要等播放后才有）──────
    final hasCards = await _waitUntilFound(
      tester,
      find.byType(VideoCard),
      timeout: const Duration(seconds: 20),
    );
    await _holdSeconds(tester, 6); // 等首屏海报网络图加载

    // ── 阶段 1：详情页 ──────────────────────────────────────────────
    var onDetail = false;
    if (hasCards) {
      await tester.tap(find.byType(VideoCard).first, warnIfMissed: false);
      await _holdSeconds(tester, 2);
      onDetail = await _waitUntilFound(
        tester,
        find.textContaining('播放 第'),
        timeout: const Duration(seconds: 15),
      );
    }
    if (onDetail) {
      _stage('detail');
      await _holdSeconds(tester, 6); // 截图窗口（未收藏的初始状态）
      // 截图后顺手追更并收藏，让「我的」页有内容（按钮文案为「追更」，
      // 点击弹锚定菜单）
      final followButton = find.text('追更');
      if (followButton.evaluate().isNotEmpty) {
        await tester.tap(followButton.first, warnIfMissed: false);
        await _holdSeconds(tester, 1);
        final followAndFav = find.text('追更并收藏');
        if (followAndFav.evaluate().isNotEmpty) {
          await tester.tap(followAndFav.first, warnIfMissed: false);
        }
        await _holdSeconds(tester, 1);
      }
    } else {
      _stage('detail_skipped');
    }

    // ── 阶段 2：播放器（出画面后循环呼出控制条）────────────────────
    var needSearchShot = !onDetail;
    if (onDetail) {
      await tester.tap(find.textContaining('播放 第'), warnIfMissed: false);
      final playerShown = await _waitUntilFound(
        tester,
        find.byType(PlayerPage),
        timeout: const Duration(seconds: 10),
      );
      if (playerShown) {
        await _holdSeconds(tester, 12); // URL 解析 + HLS + 代理 + 起播缓冲
        if (find.byType(PlayerErrorView).evaluate().isNotEmpty) {
          await tester.tap(find.text('重新获取并重试'), warnIfMissed: false);
          await _holdSeconds(tester, 10);
        }
        if (find.byType(PlayerErrorView).evaluate().isNotEmpty) {
          _stage('player_error');
          needSearchShot = true;
        } else {
          _stage('player');
          // 竖屏窗口模式视频面中心：AppBar 56 + 16:9 区域；单击切换控制条
          final size = tester.view.physicalSize / tester.view.devicePixelRatio;
          final videoCenter = Offset(size.width / 2, 56 + size.width * 9 / 32);
          for (var i = 0; i < 10; i++) {
            await tester.tapAt(videoCenter);
            await _holdSeconds(tester, 1);
          }
        }
        await _goBack(tester); // 播放器 → 详情（退出时保存观看记录）
      } else {
        _stage('player_skipped');
        needSearchShot = true;
      }
      await _goBack(tester); // 详情 → 首页
    }

    // ── 阶段 3：首页（播放后回首页，续播条已响应式出现）────────────
    if (hasCards) {
      await _holdSeconds(tester, 4); // 等续播条 AnimatedSize 进场 + 海报
      _stage('home');
      await _holdSeconds(tester, 10);
    }

    // ── 阶段 3.5 兜底：搜索结果页（播放器不可用时作为第三张图）──────
    if (needSearchShot) {
      final navSearch = find.text('搜索');
      if (await _waitUntilFound(tester, navSearch, timeout: const Duration(seconds: 8))) {
        await tester.tap(navSearch.last, warnIfMissed: false);
        await _holdSeconds(tester, 2);
        final field = find.byType(TextField).first;
        if (field.evaluate().isNotEmpty) {
          await tester.enterText(field, '海');
          await tester.pump();
          await _holdSeconds(tester, 10); // 防抖 + 多源搜索 + 海报加载
          _stage('search_results');
          await _holdSeconds(tester, 6);
        }
      }
    }

    // ── 阶段 4：我的 ────────────────────────────────────────────────
    final navProfile = find.text('我的');
    if (await _waitUntilFound(tester, navProfile, timeout: const Duration(seconds: 8))) {
      await tester.tap(navProfile.last, warnIfMissed: false);
      await _holdSeconds(tester, 4); // 我的页每次进入整页重建
      _stage('profile');
      await _holdSeconds(tester, 10);
    } else {
      _stage('profile_skipped');
    }
  });
}
