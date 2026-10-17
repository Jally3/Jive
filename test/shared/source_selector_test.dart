import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/data/vod_source/vod_source_customization_store.dart';
import 'package:jive/data/vod_source/vod_source_customization_provider.dart';
import 'package:jive/domain/vod_source_customization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/shared/source_selector.dart';
import 'package:jive/features/settings/source_management_page.dart';

List<VodSource> _sources(int count) => List.generate(
  count,
  (i) => VodSource(
    id: 's$i',
    name: '源$i',
    baseUri: Uri.parse('https://api.s$i.example.com/api.php/provide/vod'),
    adapterType: 'mac_cms_v10',
  ),
);

Future<void> _pumpSheet(
  WidgetTester tester, {
  required List<VodSource> sources,
  String? selectedId,
  double textScale = 1,
  VodSourceCustomizationStore? store,
}) async {
  final container = ProviderContainer(
    overrides: [
      if (store != null)
        vodSourceCustomizationStoreProvider.overrideWithValue(store),
      vodSourceRegistryProvider.overrideWith(
        (ref) async => VodSourceRegistry(sources, {}),
      ),
    ],
  );
  await container.read(vodSourceRegistryProvider.future);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  SourceSelectorSheet.show(context, selectedId: selectedId),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

VodSource _site({
  required String id,
  required String name,
  String adapterType = 'syncnext_plugin',
}) => VodSource(
  id: id,
  name: name,
  baseUri: Uri.parse('https://$id.example.com'),
  adapterType: adapterType,
  notification: '画质更高',
);

Future<void> _enterManagement(WidgetTester tester) async {
  if (find.text('管理').hitTestable().evaluate().isNotEmpty) {
    await tester.tap(find.text('管理').hitTestable());
    await tester.pumpAndSettle();
  }
}

Future<void> _openSourceMenu(WidgetTester tester, String id) async {
  await _enterManagement(tester);
  await tester.tap(find.byKey(ValueKey('source-menu-$id')));
}

double _sheetPixels(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('source-list-collection')),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

class _FailingStore extends VodSourceCustomizationStore {
  bool fail = true;
  @override
  Future<VodSourceCustomizations> load() async => VodSourceCustomizations();
  @override
  Future<void> save(VodSourceCustomizations value) async {
    if (fail) throw StateError('disk full');
    await super.save(value);
  }
}

class _SlowStore extends VodSourceCustomizationStore {
  final completion = Completer<void>();
  @override
  Future<VodSourceCustomizations> load() async => VodSourceCustomizations();
  @override
  Future<void> save(VodSourceCustomizations value) => completion.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('management stays in the selector and cannot switch sources', (
    tester,
  ) async {
    await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');
    expect(find.byKey(const ValueKey('source-menu-s1')), findsNothing);
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSelectorSheet), findsOneWidget);
    expect(find.byType(SourceManagementPage), findsNothing);
    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.text('源1'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString(
        'selected_vod_source_id',
      ),
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('source-pin-s1')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源1')).dy,
      lessThan(tester.getTopLeft(find.text('源0')).dy),
    );
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-menu-s1')), findsNothing);
    await tester.tap(find.text('源1'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceSelectorSheet), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'selected_vod_source_id',
      ),
      's1',
    );
  });

  testWidgets('bottoming is persistent reversible and exclusive with pinning', (
    tester,
  ) async {
    await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('置底'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源0')).dy,
      greaterThan(tester.getTopLeft(find.text('源2')).dy),
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        'selected_vod_source_id',
      ),
      isNull,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源0')).dy,
      greaterThan(tester.getTopLeft(find.text('源2')).dy),
    );
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-pin-s0')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源0')).dy,
      lessThan(tester.getTopLeft(find.text('源1')).dy),
    );
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    expect(find.text('置底'), findsOneWidget);
    await tester.tap(find.text('置底'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源0')).dy,
      greaterThan(tester.getTopLeft(find.text('源2')).dy),
    );
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消置底'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('源0')).dy,
      lessThan(tester.getTopLeft(find.text('源1')).dy),
    );
  });

  testWidgets(
    'saving a dismissed editor does not pop the underlying selector',
    (tester) async {
      final store = _SlowStore();
      await _pumpSheet(
        tester,
        sources: _sources(1),
        selectedId: 's0',
        store: store,
      );
      await _openSourceMenu(tester, 's0');
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('source-note')),
        '保存中返回',
      );
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 20));
      store.completion.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SourceSelectorSheet), findsOneWidget);
      expect(find.text('编辑来源'), findsNothing);
    },
  );

  testWidgets('pinning a scrolled source reveals its new position', (
    tester,
  ) async {
    await _pumpSheet(tester, sources: _sources(30), selectedId: 's25');
    expect(_sheetPixels(tester), greaterThan(0));
    await _enterManagement(tester);
    await tester.tap(find.byKey(const ValueKey('source-pin-s25')));
    await tester.pumpAndSettle();
    expect(_sheetPixels(tester), 0);
    expect(find.text('源25').hitTestable(), findsOneWidget);
  });

  testWidgets('mode changes retain the source scroll offset', (tester) async {
    await _pumpSheet(tester, sources: _sources(30), selectedId: 's25');
    final before = _sheetPixels(tester);
    await _enterManagement(tester);
    expect(_sheetPixels(tester), before);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(_sheetPixels(tester), before);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('removed bottom sources can be cleared from an empty directory', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      VodSourceCustomizationStore.storageKey:
          '{"schemaVersion":1,"demotedSourceIds":["removed"]}',
    });
    await _pumpSheet(tester, sources: []);
    await _enterManagement(tester);
    await tester.tap(find.text('已不可用的个性化来源（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('已不可用的个性化来源'), findsNothing);
    final raw = (await SharedPreferences.getInstance()).getString(
      VodSourceCustomizationStore.storageKey,
    )!;
    expect(raw, isNot(contains('removed')));
  });

  testWidgets('long aliases fit the home source button on narrow screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      VodSourceCustomizationStore.storageKey:
          '{"schemaVersion":1,"sources":{"s0":{"displayName":"这是一个用于验证来源名称最大长度的超长中文私人别名测试文本"}}}',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vodSourceRegistryProvider.overrideWith(
            (ref) async => VodSourceRegistry(_sources(1), {}),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                const Text('Jive'),
                const Spacer(),
                const SourceIndicatorButton(overrideSelectedId: 's0'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removing the last tag clears an old filter before adding new tags',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        VodSourceCustomizationStore.storageKey:
            '{"schemaVersion":1,"sources":{"s0":{"tags":["variety"]}}}',
      });
      await _pumpSheet(tester, sources: _sources(2), selectedId: 's0');
      await tester.tap(find.byKey(const ValueKey('source-tag-variety')));
      await tester.pumpAndSettle();
      await _openSourceMenu(tester, 's0');
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '综艺'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await _openSourceMenu(tester, 's0');
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '电影'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('源0'), findsOneWidget);
      expect(find.text('源1'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '全部'))
            .selected,
        isTrue,
      );
    },
  );

  testWidgets('mode changes preserve filtering and the selected site tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      VodSourceCustomizationStore.storageKey:
          '{"schemaVersion":1,"sources":{"s0":{"tags":["movie"]},"site":{"tags":["movie"]}}}',
    });
    await _pumpSheet(
      tester,
      sources: [
        ..._sources(2),
        _site(id: 'site', name: '高清源'),
      ],
      selectedId: 's0',
    );
    await tester.tap(find.byKey(const ValueKey('source-tag-movie')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('高清站'));
    await tester.pumpAndSettle();
    await _enterManagement(tester);
    expect(find.text('高清源').hitTestable(), findsOneWidget);
    expect(find.text('源0').hitTestable(), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('高清源').hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('source-tag-movie')))
          .selected,
      isTrue,
    );
    expect(find.byType(SourceManagementPage), findsNothing);
  });

  testWidgets('failed save retains input and can be retried', (tester) async {
    final store = _FailingStore();
    await _pumpSheet(
      tester,
      sources: _sources(1),
      selectedId: 's0',
      store: store,
    );
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('source-display-name')),
      '保留输入',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.text('保留输入'), findsOneWidget);
    store.fail = false;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保留输入'), findsOneWidget);
    expect(find.text('编辑来源'), findsNothing);
  });

  testWidgets('restoring a source clears annotations and pinning only', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      VodSourceCustomizationStore.storageKey:
          '{"schemaVersion":1,"sources":{"s1":{"displayName":"别名","tags":["movie"],"note":"老片全"}},"pinnedSourceIds":["s1"]}',
      'selected_vod_source_id': 's0',
    });
    await _pumpSheet(tester, sources: _sources(2), selectedId: 's0');
    await _openSourceMenu(tester, 's1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复此源设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(find.text('别名'), findsNothing);
    expect(find.text('老片全'), findsNothing);
    expect(find.text('源1'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-tag-movie')), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'selected_vod_source_id',
      ),
      's0',
    );
  });

  testWidgets('tagged sources and editor fit narrow screens with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      VodSourceCustomizationStore.storageKey:
          '{"schemaVersion":1,"sources":{"s0":{"displayName":"这是比较长的私人来源名称","tags":["movie","series","animation","variety"],"note":"这是一条比较长的私人备注用于测试显示"}}}',
    });
    await _pumpSheet(
      tester,
      sources: _sources(2),
      selectedId: 's0',
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('edits personal tags and filters without selecting a source', (
    tester,
  ) async {
    await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');
    await _openSourceMenu(tester, 's1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('source-display-name')),
      '综艺库',
    );
    await tester.enterText(find.byKey(const ValueKey('source-note')), ' 更新快 ');
    await tester.tap(find.widgetWithText(FilterChip, '综艺'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('综艺库'), findsOneWidget);
    expect(find.text('更新快'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('source-tag-variety')));
    await tester.pumpAndSettle();
    expect(find.text('源0'), findsNothing);
    expect(find.text('综艺库'), findsOneWidget);
    expect(find.byType(SourceSelectorSheet), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'selected_vod_source_id',
      ),
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('source-tag-movie')));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有标记为电影'), findsOneWidget);
    await tester.tap(find.text('显示全部'));
    await tester.pumpAndSettle();
    expect(find.text('源0'), findsOneWidget);
  });

  testWidgets(
    'pinning changes list order without selecting and survives reopening',
    (tester) async {
      await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');
      await _enterManagement(tester);
      await tester.tap(find.byKey(const ValueKey('source-pin-s2')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('源2')).dy,
        lessThan(tester.getTopLeft(find.text('源0')).dy),
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          'selected_vod_source_id',
        ),
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('源2')).dy,
        lessThan(tester.getTopLeft(find.text('源0')).dy),
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          VodSourceCustomizationStore.storageKey,
        ),
        contains('s2'),
      );
    },
  );

  testWidgets('cancel discards edits and manage opens the same source list', (
    tester,
  ) async {
    await _pumpSheet(tester, sources: _sources(2), selectedId: 's0');
    await _openSourceMenu(tester, 's0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('source-display-name')),
      '未保存',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('未保存'), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('选择来源'), findsOneWidget);
    expect(find.text('源0').hitTestable(), findsOneWidget);
  });
  testWidgets('sheet caps its width and stays centered on wide screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');

    final rect = tester.getRect(find.byType(SourceSelectorSheet));
    expect(rect.width, lessThanOrEqualTo(600));
    expect(rect.center.dx, closeTo(640, 1));
  });

  testWidgets('focus moves into the sheet when it opens', (tester) async {
    await _pumpSheet(tester, sources: _sources(3), selectedId: 's0');

    final sheetScope = FocusScope.of(
      tester.element(find.byType(SourceSelectorSheet)),
    );
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(
      primary == sheetScope || primary!.ancestors.contains(sheetScope),
      isTrue,
    );
  });

  testWidgets('source sheet scrolls the selected source into view', (
    tester,
  ) async {
    final sources = _sources(30);
    await _pumpSheet(tester, sources: sources, selectedId: 's25');

    expect(_sheetPixels(tester), greaterThan(0));
    final sheetRect = tester.getRect(find.byType(SourceSelectorSheet));
    final selectedRect = tester.getRect(find.text('源25'));
    expect(selectedRect.top, greaterThanOrEqualTo(sheetRect.top));
    expect(selectedRect.bottom, lessThanOrEqualTo(sheetRect.bottom));
  });

  testWidgets(
    'source sheet stays at the top when the first source is selected',
    (tester) async {
      final sources = _sources(30);
      await _pumpSheet(tester, sources: sources, selectedId: 's0');

      expect(_sheetPixels(tester), 0);
    },
  );

  testWidgets('source sheet splits collection and site sources into tabs', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      sources: [
        ..._sources(2),
        _site(id: 'age', name: '新 AGE', adapterType: 'age_v2'),
        _site(id: 'dbku', name: '独播库'),
      ],
      selectedId: 's0',
    );

    expect(find.text(SourceSelectorSheet.collectionTabLabel), findsOneWidget);
    expect(find.text(SourceSelectorSheet.siteTabLabel), findsOneWidget);
    expect(find.text('源0'), findsOneWidget);
    expect(find.textContaining('不一定稳定').hitTestable(), findsNothing);

    await tester.tap(find.text(SourceSelectorSheet.siteTabLabel));
    await tester.pumpAndSettle();
    expect(find.text('独播库'), findsOneWidget);
    expect(find.text('新 AGE'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('新 AGE')).dy,
      lessThan(tester.getTopLeft(find.text('独播库')).dy),
    );
    expect(
      find.textContaining(SourceSelectorSheet.siteTabHint).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets(
    'source sheet opens the site tab when a site source is selected',
    (tester) async {
      await _pumpSheet(
        tester,
        sources: [
          ..._sources(2),
          _site(id: 'dbku', name: '独播库'),
        ],
        selectedId: 'dbku',
      );

      expect(find.text('独播库'), findsOneWidget);
      expect(
        find.textContaining(SourceSelectorSheet.siteTabHint).hitTestable(),
        findsOneWidget,
      );
    },
  );
}
