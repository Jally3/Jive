import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _isrgRootX1Asset = 'assets/certs/isrgrootx1.pem';

/// Android 6 的系统证书库早于 ISRG Root X1，部分现代图片 CDN 因此会
/// TLS 握手失败。这里只追加官方根证书，保留系统信任库和完整证书校验。
Future<void> installLegacyAndroidTrustedRoots() async {
  if (!Platform.isAndroid) return;
  try {
    final data = await rootBundle.load(_isrgRootX1Asset);
    SecurityContext.defaultContext.setTrustedCertificatesBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } catch (error, stackTrace) {
    debugPrint('Failed to install Android 6 trusted root: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
