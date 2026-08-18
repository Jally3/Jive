import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_states.dart';
import '../data/cache/download_providers.dart';
import '../data/vod_source_preferences.dart';
import '../data/vod_source_registry.dart';
import '../features/home_page.dart';
import '../features/profile_page.dart';
import '../features/search_page.dart';
import 'theme.dart';

class JiveApp extends ConsumerWidget {
  const JiveApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourceState = ref.watch(selectedVodSourceProvider);
    return _DownloadLifecycle(
      child: MaterialApp(
        title: 'Jive',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: sourceState.when(
          loading: () => const Scaffold(
            backgroundColor: AppColors.background,
            body: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Scaffold(
            backgroundColor: AppColors.background,
            body: AppErrorView(
              message: '$error',
              onRetry: () => ref.invalidate(vodSourceRegistryProvider),
            ),
          ),
          data: (_) => const AppShell(),
        ),
      ),
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

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var index = 0;
  var profileRevision = 0;
  late final List<Widget?> pages;
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    pages = List<Widget?>.filled(3, null);
    pages[0] = const HomePage();
    // 预建搜索页：首次构建开销挪到启动阶段，避免首次切换 tab 时
    // 在同一帧内建整棵子树造成卡顿。
    pages[1] = SearchPage(focusNode: _searchFocusNode);
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
  }

  Widget _createPage(int value) => switch (value) {
    0 => const HomePage(),
    1 => SearchPage(focusNode: _searchFocusNode),
    2 => ProfilePage(key: ValueKey(profileRevision)),
    _ => const SizedBox.shrink(),
  };

  void _onSelect(int value) => setState(() {
    index = value;
    if (value == 2) {
      profileRevision++;
      pages[value] = ProfilePage(key: ValueKey(profileRevision));
    } else {
      pages[value] ??= _createPage(value);
    }
    if (value == 1) {
      // 等 tab 切换动画结束再弹键盘，避免键盘动画与首帧绘制抢资源。
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted && index == 1) _searchFocusNode.requestFocus();
      });
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    extendBody: true,
    body: IndexedStack(
      index: index,
      children: List.generate(
        3,
        (value) => pages[value] ?? const SizedBox.shrink(),
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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _FloatingNavBar(index: index, onSelect: _onSelect),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({required this.index, required this.onSelect});

  final int index;
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.isTablet,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final bool isTablet;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accent : AppColors.secondary;
    return InkWell(
      borderRadius: BorderRadius.circular(isTablet ? 30 : 32),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: isTablet
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: isTablet && selected
              ? AppColors.accent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? selectedIcon : icon,
              color: color,
              size: isTablet ? 26 : 24,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: isTablet ? 13 : 12,
                color: color,
                fontWeight: selected
                    ? FontWeight.w600
                    : isTablet
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
