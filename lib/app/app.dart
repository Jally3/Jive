import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../shared/app_states.dart';
import '../shared/is_tv.dart';
import '../data/download/download_providers.dart';
import '../data/vod_source/vod_source_preferences.dart';
import '../data/vod_source/vod_source_registry.dart';
import '../features/home/home_page.dart';
import '../features/profile/profile_page.dart';
import '../features/search/search_page.dart';
import '../features/splash/splash_page.dart';
import '../tv/tv_app_shell.dart';
import 'theme.dart';

class JiveApp extends ConsumerWidget {
  const JiveApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _DownloadLifecycle(
      child: MaterialApp(
        title: 'Jive',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
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
      loading: () => const SplashPage(),
      error: (error, _) => Scaffold(
        backgroundColor: AppColors.background,
        body: AppErrorView(
          message: '$error',
          onRetry: () => ref.invalidate(vodSourceRegistryProvider),
        ),
      ),
      data: (_) =>
          (skipHold || _holdElapsed) ? const AppShell() : const SplashPage(),
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
    if (manager == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(manager.pauseForBackground());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(manager.resumeFromForeground());
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
  late final List<Widget?> pages;
  final _searchFocusNode = FocusNode();
  final _contentFocusScopeNode = FocusScopeNode(debugLabel: 'tv-content-scope');
  late final List<FocusNode> _navFocusNodes;
  Timer? _searchFocusTimer;
  bool _didRequestInitialTvFocus = false;
  bool _contentEnteredFromRail = false;

  @override
  void initState() {
    super.initState();
    _navFocusNodes = List.generate(
      3,
      (value) => FocusNode(debugLabel: 'bottom-nav-$value'),
    );
    _searchFocusNode.addListener(_onSearchFocusChanged);
    pages = List<Widget?>.filled(3, null);
    pages[0] = const HomePage();
    // 预建搜索页：首次构建开销挪到启动阶段，避免首次切换 tab 时
    // 在同一帧内建整棵子树造成卡顿。
    pages[1] = SearchPage(focusNode: _searchFocusNode);
  }

  @override
  void dispose() {
    _searchFocusTimer?.cancel();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _contentFocusScopeNode.dispose();
    for (final node in _navFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _onSearchFocusChanged() {
    // PopScope 的 canPop 依赖输入框焦点；焦点变化后及时刷新返回键策略。
    if (mounted) setState(() {});
  }

  Widget _createPage(int value) => switch (value) {
    0 => const HomePage(),
    1 => SearchPage(focusNode: _searchFocusNode),
    2 => ProfilePage(key: ValueKey(profileRevision)),
    _ => const SizedBox.shrink(),
  };

  void _onSelect(int value) {
    final isTv = ref.read(isTvProvider).value ?? false;
    _searchFocusTimer?.cancel();
    _contentEnteredFromRail = false;
    // TV 上第一次确认只切换到搜索页，第二次确认才进入输入状态，避免
    // 遥控器浏览底栏时被输入法抢走焦点。
    if (isTv && value == index && value == 1) {
      _searchFocusNode.requestFocus();
      return;
    }
    if (value != 1) _searchFocusNode.unfocus();
    setState(() {
      index = value;
      if (value == 2) {
        profileRevision++;
        pages[value] = ProfilePage(key: ValueKey(profileRevision));
      } else {
        pages[value] ??= _createPage(value);
      }
    });
    if (value == 1 && !isTv) {
      // 手机端保留原行为：等 tab 切换动画结束后自动弹出键盘。
      _searchFocusTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted && index == 1) _searchFocusNode.requestFocus();
      });
    }
  }

  void _restoreNavFocus() {
    _contentEnteredFromRail = false;
    _searchFocusNode.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navFocusNodes[index].requestFocus();
    });
  }

  KeyEventResult _handleTvKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !(ref.read(isTvProvider).value ?? false)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_searchFocusNode.hasFocus &&
        (key == LogicalKeyboardKey.goBack ||
            key == LogicalKeyboardKey.browserBack ||
            key == LogicalKeyboardKey.escape)) {
      _restoreNavFocus();
      return KeyEventResult.handled;
    }
    if (_searchFocusNode.hasFocus) return KeyEventResult.ignored;
    final primaryLabel = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    if (primaryLabel.startsWith('tv-root-category-') ||
        primaryLabel.startsWith('tv-leaf-category-')) {
      // 首页分类有自己的左右边界和滚动策略，不能被应用壳的几何遍历抢先消费。
      return KeyEventResult.ignored;
    }
    final direction = switch (key) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction != null) {
      _moveTvFocus(direction);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveTvFocus(TraversalDirection direction) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) {
      _navFocusNodes[index].requestFocus();
      return;
    }

    final railIndex = _navFocusNodes.indexOf(primary);
    if (railIndex != -1) {
      if (direction == TraversalDirection.up ||
          direction == TraversalDirection.down) {
        final delta = direction == TraversalDirection.up ? -1 : 1;
        final target = (railIndex + delta) % _navFocusNodes.length;
        _navFocusNodes[target].requestFocus();
        return;
      }
      if (direction == TraversalDirection.left) return;
      if (direction == TraversalDirection.right) {
        _contentEnteredFromRail = true;
        _contentFocusScopeNode.requestFocus();
        _contentFocusScopeNode.nextFocus();
        return;
      }
    }

    if (_contentEnteredFromRail) {
      _contentEnteredFromRail = false;
      if (direction == TraversalDirection.left) {
        _navFocusNodes[index].requestFocus();
        return;
      }
    }

    final moved = primary.focusInDirection(direction);
    if (!moved && direction == TraversalDirection.left) {
      // 内容区已经没有更靠左的目标时，稳定返回当前页面的导航项。
      _navFocusNodes[index].requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = ref.watch(isTvProvider).value ?? false;
    if (isTv && !_didRequestInitialTvFocus) {
      _didRequestInitialTvFocus = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _navFocusNodes[index].requestFocus();
      });
    }
    final pageStack = IndexedStack(
      index: index,
      children: List.generate(
        3,
        (value) => ExcludeFocus(
          // IndexedStack 的隐藏 child 仍是活跃 Offstage 子树；显式排除
          // 焦点，避免首页方向键跳进隐藏搜索框。
          excluding: value != index,
          child: pages[value] ?? const SizedBox.shrink(),
        ),
      ),
    );
    final mobileScaffold = Scaffold(
      extendBody: true,
      body: pageStack,
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _FloatingNavBar(
                    index: index,
                    focusNodes: _navFocusNodes,
                    onSelect: _onSelect,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final scaffold = isTv
        ? TvAppShell(
            index: index,
            focusNodes: _navFocusNodes,
            contentFocusScopeNode: _contentFocusScopeNode,
            onSelect: _onSelect,
            body: pageStack,
          )
        : mobileScaffold;
    final shell = PopScope<void>(
      canPop: !_searchFocusNode.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _searchFocusNode.hasFocus) _restoreNavFocus();
      },
      child: Focus(onKeyEvent: _handleTvKeyEvent, child: scaffold),
    );
    return shell;
  }
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.index,
    required this.focusNodes,
    required this.onSelect,
  });

  final int index;
  final List<FocusNode> focusNodes;
  final ValueChanged<int> onSelect;

  static const _items = [
    (Icons.home_outlined, Icons.home, '首页'),
    (Icons.search, Icons.search, '搜索'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final isTablet = MediaQuery.sizeOf(context).shortestSide >= 600;
    final height = isTablet ? 72.0 : 64.0;
    final radius = height / 2;
    // 首页保留更通透的毛玻璃；其他页面提高底色不透明度，
    // 避免图标和文字被页面内容干扰。
    final surfaceAlpha = index == 0 ? 0.3 : 0.78;
    return Container(
      key: const ValueKey('floating-nav-bar'),
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        boxShadow: const [
          BoxShadow(
            color: AppColors.scrim,
            blurRadius: 24,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            key: const ValueKey('floating-nav-surface'),
            color: AppColors.surface.withValues(alpha: surfaceAlpha),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius),
              side: BorderSide(
                color: isTablet
                    ? AppColors.secondary.withValues(alpha: 0.25)
                    : AppColors.divider,
              ),
            ),
            child: Row(
              children: [
                for (var i = 0; i < _items.length; i++)
                  Expanded(
                    child: _NavItem(
                      icon: _items[i].$1,
                      selectedIcon: _items[i].$2,
                      label: _items[i].$3,
                      selected: index == i,
                      isTablet: isTablet,
                      focusNode: focusNodes[i],
                      onTap: () => onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.isTablet,
    required this.focusNode,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool isTablet;
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected ? AppColors.accent : AppColors.secondary;
    return InkWell(
      key: ValueKey('bottom-nav-${widget.label}'),
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() => _focused = value),
      borderRadius: BorderRadius.circular(widget.isTablet ? 30 : 32),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: widget.isTablet
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: widget.isTablet && widget.selected
              ? AppColors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          border: _focused
              ? Border.all(
                  color: widget.selected ? AppColors.text : AppColors.accent,
                  width: 2,
                )
              : null,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.selected ? widget.selectedIcon : widget.icon,
              color: color,
              size: widget.isTablet ? 26 : 24,
            ),
            const SizedBox(height: 2),
            Text(
              widget.label,
              style: TextStyle(
                fontSize: widget.isTablet ? 13 : 12,
                color: color,
                fontWeight: widget.selected
                    ? FontWeight.w600
                    : widget.isTablet
                    ? FontWeight.w500
                    : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
