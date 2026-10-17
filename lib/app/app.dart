import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shared/app_states.dart';
import '../shared/app_update_dialog.dart';
import '../shared/double_back_exit_scope.dart';
import '../shared/screen_awake_controller.dart';
import '../data/download/download_providers.dart';
import '../data/library_repository.dart';
import '../data/theme_mode_preferences.dart';
import '../data/update/app_update_service.dart';
import '../data/vod_source/vod_source_preferences.dart';
import '../data/vod_source/vod_source_registry.dart';
import '../features/home/home_page.dart';
import '../features/profile/profile_page.dart';
import '../features/search/search_page.dart';
import '../features/search/search_launch_request.dart';
import '../features/splash/splash_page.dart';
import 'theme.dart';
import 'widgets/floating_nav_bar.dart';

class JiveApp extends ConsumerWidget {
  const JiveApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return _DownloadLifecycle(
      child: MaterialApp(
        title: 'Jive',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: themeMode,
        navigatorObservers: [ref.watch(screenAwakeRouteObserverProvider)],
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: Theme.of(context).brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _StartupGate(),
      ),
    );
  }
}

/// 源就绪且满最短展示后才进首页，避免 pop 回闪屏。
class _StartupGate extends ConsumerStatefulWidget {
  const _StartupGate();

  @override
  ConsumerState<_StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends ConsumerState<_StartupGate> {
  bool _holdElapsed = false;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _holdTimer = Timer(splashMinHold, () {
      if (mounted) setState(() => _holdElapsed = true);
    });
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sourceState = ref.watch(selectedVodSourceProvider);
    final skipHold = MediaQuery.disableAnimationsOf(context);
    return sourceState.when(
      loading: () => SplashPage(),
      error: (error, _) => Scaffold(
        backgroundColor: context.appColors.background,
        body: AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(vodSourceRegistryProvider),
        ),
      ),
      data: (_) => (skipHold || _holdElapsed) ? AppShell() : SplashPage(),
    );
  }
}

class _DownloadLifecycle extends ConsumerStatefulWidget {
  const _DownloadLifecycle({required this.child});
  final Widget child;

  @override
  ConsumerState<_DownloadLifecycle> createState() => _DownloadLifecycleState();
}

class _DownloadLifecycleState extends ConsumerState<_DownloadLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final manager = ref
        .read(downloadManagerProvider)
        .maybeWhen(data: (value) => value, orElse: () => null);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (manager != null) unawaited(manager.pauseForBackground());
    } else if (state == AppLifecycleState.resumed) {
      if (manager != null) unawaited(manager.resumeFromForeground());
      unawaited(
        ref.read(favoriteControllerProvider.notifier).checkForUpdates(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  var index = 0;
  var profileRevision = 0;
  var _updateCheckStarted = false;
  late final List<Widget?> pages;
  final _searchFocusNode = FocusNode();
  final _homeActive = ValueNotifier<bool>(true);
  final _homeScrollDistance = ValueNotifier<double>(0);
  ProviderSubscription<SearchLaunchRequest?>? _searchLaunchSubscription;

  @override
  void initState() {
    super.initState();
    pages = List<Widget?>.filled(3, null);
    pages[0] = HomePage(active: _homeActive);
    // 预建搜索页：首次构建开销挪到启动阶段，避免首次切换 tab 时
    // 在同一帧内建整棵子树造成卡顿。
    pages[1] = SearchPage(focusNode: _searchFocusNode);
    _searchLaunchSubscription = ref.listenManual(searchLaunchRequestProvider, (
      _,
      request,
    ) {
      if (request == null || !mounted) return;
      _homeActive.value = false;
      setState(() {
        index = 1;
        pages[1] ??= _createPage(1);
      });
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (mounted && index == 1) _searchFocusNode.requestFocus();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForAppUpdate());
      unawaited(
        ref.read(favoriteControllerProvider.notifier).checkForUpdates(),
      );
    });
  }

  Future<void> _checkForAppUpdate() async {
    if (_updateCheckStarted ||
        !mounted ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _updateCheckStarted = true;
    final gateway = ref.read(appUpdateGatewayProvider);
    final update = await gateway.checkForUpdate();
    if (!mounted || update == null) return;
    await showAppUpdateDialog(context, update: update, gateway: gateway);
  }

  @override
  void dispose() {
    _searchLaunchSubscription?.close();
    _searchFocusNode.dispose();
    _homeActive.dispose();
    _homeScrollDistance.dispose();
    super.dispose();
  }

  Widget _createPage(int value) => switch (value) {
    0 => HomePage(active: _homeActive),
    1 => SearchPage(focusNode: _searchFocusNode),
    2 => ProfilePage(key: ValueKey(profileRevision)),
    _ => SizedBox.shrink(),
  };

  void _onSelect(int value) {
    _homeActive.value = value == 0;
    setState(() {
      index = value;
      if (value == 2) {
        profileRevision++;
        pages[value] = ProfilePage(key: ValueKey(profileRevision));
      } else {
        pages[value] ??= _createPage(value);
      }
      if (value == 1) {
        // 等 tab 切换动画结束再弹键盘，避免键盘动画与首帧绘制抢资源。
        Future.delayed(Duration(milliseconds: 300), () {
          if (mounted && index == 1) _searchFocusNode.requestFocus();
        });
      }
    });
  }

  bool _onHomeScroll(ScrollUpdateNotification notification) {
    if (index != 0 ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final delta = notification.scrollDelta;
    if (delta == null || !delta.isFinite) return false;
    final metrics = notification.metrics;
    // 只计算有效内容位移，过滤越界回弹，也覆盖惯性和程序化滚动。
    final current = metrics.pixels.clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final previous = (metrics.pixels - delta).clamp(
      metrics.minScrollExtent,
      metrics.maxScrollExtent,
    );
    final distance = (current - previous).abs();
    if (distance > 0) _homeScrollDistance.value += distance;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final scaffold = Scaffold(
      extendBody: true,
      body: NotificationListener<ScrollUpdateNotification>(
        onNotification: _onHomeScroll,
        child: IndexedStack(
          index: index,
          children: List.generate(
            3,
            (value) => TickerMode(
              enabled: index == value,
              child: pages[value] ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth:
                      MediaQuery.orientationOf(context) == Orientation.landscape
                      ? 600
                      : 480,
                ),
                child: Padding(
                  padding: isTablet
                      ? EdgeInsets.fromLTRB(16, 0, 16, 12)
                      : EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: FloatingNavBar(
                    selectedIndex: index,
                    onSelect: _onSelect,
                    showUpdateDot:
                        ref.watch(unreadFollowUpdateCountProvider) > 0,
                    scrollDistance: _homeScrollDistance,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return isAndroid ? DoubleBackExitScope(child: scaffold) : scaffold;
  }
}
