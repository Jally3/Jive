import 'package:flutter/material.dart';

/// 沉浸式 overlay（全屏或设备横屏）下播放器内的顶栏：返回 + 标题。
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.visible,
    required this.fullScreen,
    required this.title,
    required this.onBack,
  });

  final bool visible;
  final bool fullScreen;
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    // 顶栏隐藏时不允许焦点遍历进入，避免遥控器焦点落在不可见控件上。
    return ExcludeFocus(
      excluding: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !visible,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                key: const ValueKey('player-top-scrim'),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: Row(
                      children: [
                        IconButton(
                          key: const ValueKey('fullscreen-back'),
                          onPressed: onBack,
                          tooltip: fullScreen ? '退出全屏' : '返回',
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 4,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
