import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/vod_source/vod_source_registry.dart';
import 'package:jive/domain/vod_source.dart';
import 'package:jive/shared/source_selector.dart';

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
}) async {
  final container = ProviderContainer(
    overrides: [
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

double _sheetPixels(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('source-list-collection')),
        matching: find.byType(Scrollable),
      ),
    )
    .position
    .pixels;

void main() {
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
      tester.getTopLeft(find.text('独播库')).dy,
      lessThan(tester.getTopLeft(find.text('新 AGE')).dy),
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
