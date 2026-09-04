import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';

class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.iconSize = 44,
    this.placeholderColor = AppColors.surface,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final double iconSize;
  final Color placeholderColor;

  static const _headers = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 6.0.1; TV) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36',
    'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8',
  };

  @override
  Widget build(BuildContext context) {
    final imageUrl = normalizeImageUrl(url);
    if (imageUrl.isEmpty) return _fallback();
    return CachedNetworkImage(
      imageUrl: imageUrl,
      httpHeaders: _headers,
      fit: fit,
      width: width,
      height: height,
      placeholder: (_, _) => ColoredBox(color: placeholderColor),
      errorWidget: (_, failedUrl, error) {
        final uri = Uri.tryParse(failedUrl);
        debugPrint(
          'Image load failed (${uri?.host ?? 'invalid-url'}): '
          '${error.runtimeType}: $error',
        );
        return _fallback();
      },
    );
  }

  Widget _fallback() =>
      Icon(Icons.movie_outlined, size: iconSize, color: AppColors.tertiary);
}

@visibleForTesting
String normalizeImageUrl(String raw) {
  var value = raw.trim();
  if (value.startsWith('//')) value = 'https:$value';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return '';
  }
  return uri.toString();
}
