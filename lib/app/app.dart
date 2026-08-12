import 'package:flutter/material.dart';
import '../features/category_page.dart';
import '../features/history_page.dart';
import '../features/home_page.dart';
import '../features/library_page.dart';
import '../features/search_page.dart';
import 'theme.dart';

class JiveApp extends StatelessWidget {
  const JiveApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Jive',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: const AppShell(),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  var index = 0;
  var historyRevision = 0;
  int? categoryId;
  var categoryRevision = 0;
  late final List<Widget?> pages;

  @override
  void initState() {
    super.initState();
    pages = List<Widget?>.filled(5, null);
    pages[0] = HomePage(onCategorySelected: _openCategory);
  }

  void _openCategory(int value) {
    setState(() {
      categoryId = value;
      categoryRevision++;
      pages[1] = CategoryPage(
        key: ValueKey(categoryRevision),
        initialCategoryId: categoryId,
      );
      index = 1;
    });
  }

  Widget _createPage(int value) => switch (value) {
    0 => HomePage(onCategorySelected: _openCategory),
    1 => CategoryPage(
      key: ValueKey(categoryRevision),
      initialCategoryId: categoryId,
    ),
    2 => const SearchPage(),
    3 => const LibraryPage(),
    4 => HistoryPage(key: ValueKey(historyRevision)),
    _ => const SizedBox.shrink(),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: index,
      children: List.generate(
        5,
        (value) => pages[value] ?? const SizedBox.shrink(),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: index,
      onDestinationSelected: (value) => setState(() {
        index = value;
        if (value == 4) {
          historyRevision++;
          pages[value] = HistoryPage(key: ValueKey(historyRevision));
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
        NavigationDestination(
          icon: Icon(Icons.grid_view_outlined),
          selectedIcon: Icon(Icons.grid_view),
          label: '分类',
        ),
        NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
        NavigationDestination(
          icon: Icon(Icons.favorite_outline),
          selectedIcon: Icon(Icons.favorite),
          label: '收藏',
        ),
        NavigationDestination(icon: Icon(Icons.history), label: '最近观看'),
      ],
    ),
  );
}
