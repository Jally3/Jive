import 'package:flutter_test/flutter_test.dart';
import 'package:jive/shared/app_network_image.dart';

void main() {
  test('normalizes scheme-relative image URLs for legacy Android', () {
    expect(
      normalizeImageUrl('  //img.example.com/poster.webp  '),
      'https://img.example.com/poster.webp',
    );
  });

  test('rejects unsupported or incomplete image URLs', () {
    expect(normalizeImageUrl('/poster.webp'), isEmpty);
    expect(normalizeImageUrl('file:///poster.webp'), isEmpty);
    expect(normalizeImageUrl('not a url'), isEmpty);
  });
}
