import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 源闸门最短展示，避免本地缓存命中时闪屏一闪而过。
const splashMinHold = Duration(milliseconds: 800);

/// 冷启动品牌页：居中 Logo + 「Jive」，底部轻量加载。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  static const logoAsset = 'assets/branding/splash_logo.png';

  @override
  Widget build(BuildContext context) {
    final logoSize = MediaQuery.sizeOf(context).shortestSide >= 600
        ? 120.0
        : 96.0;
    return Scaffold(
      key: ValueKey('splash-page'),
      backgroundColor: context.appColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Semantics(
                label: 'Jive',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      logoAsset,
                      key: ValueKey('splash-logo'),
                      width: logoSize,
                      height: logoSize,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: context.appColors.elevated,
                        child: SizedBox(width: logoSize, height: logoSize),
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Jive',
                      style: TextStyle(
                        fontSize: 28,
                        height: 36 / 28,
                        fontWeight: FontWeight.w700,
                        color: context.appColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
