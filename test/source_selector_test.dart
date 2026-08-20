import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jive/data/vod_source_registry.dart';
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

double _sheetPixels(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(SourceSelectorSheet),
        matching: find.byType(Scrollable),
      ),
    )
    .first
    .position
    .pixels;

void main() {
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
}
