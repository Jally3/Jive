import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_states.dart';
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
    return MaterialApp(
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
    );
  }
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

  @override
  void initState() {
    super.initState();
    pages = List<Widget?>.filled(3, null);
    pages[0] = const HomePage();
  }

  Widget _createPage(int value) => switch (value) {
    0 => const HomePage(),
    1 => const SearchPage(),
    2 => ProfilePage(key: ValueKey(profileRevision)),
    _ => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: index,
      children: List.generate(
        3,
        (value) => pages[value] ?? const SizedBox.shrink(),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => setState(() {
        index = value;
        if (value == 2) {
          profileRevision++;
          pages[value] = ProfilePage(key: ValueKey(profileRevision));
        } else {
          pages[value] ??= _createPage(value);
        }
      }),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: '首页',
        ),
        NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ],
    ),
  );
}
