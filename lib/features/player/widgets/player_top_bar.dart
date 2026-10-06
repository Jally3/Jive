import 'package:flutter/material.dart';

import 'player_device_status.dart';

const _titleStyle = TextStyle(
  color: Colors.white,
  fontWeight: FontWeight.w600,
  shadows: [Shadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 1))],
);

bool playerTopBarUsesTwoRows(double width, TextScaler textScaler) =>
    width < 430 || textScaler.scale(1) > 1.2;

/// 与顶栏字体/行高一致，供倍速提示避让；安全区由调用方单独处理。
double playerTopBarHeight(BuildContext context, double width) {
  final scaler = MediaQuery.textScalerOf(context);
  double height(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: '00:00', style: style),
      textScaler: scaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final result = painter.height;
    painter.dispose();
    return result;
  }

  final title = height(DefaultTextStyle.of(context).style.merge(_titleStyle));
  final titleRow = title < 48 ? 48.0 : title;
  if (!playerTopBarUsesTwoRows(width, scaler)) return titleRow + 32;
  final status = height(
    const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
  );
  final icons = playerDeviceStatusIconHeight(scaler);
  return titleRow + (status < icons ? icons : status) + 36;
}

/// 沉浸式 overlay（全屏或设备横屏）下播放器内的顶栏：返回 + 标题。
class PlayerTopBar extends StatelessWidget {
  const PlayerTopBar({
    super.key,
    required this.visible,
    required this.fullScreen,
    required this.title,
    required this.onBack,
    required this.onShowControls,
    this.isTv = false,
  });

  final bool visible;
  final bool fullScreen;
  final String title;
  final VoidCallback onBack;
  final VoidCallback onShowControls;
  final bool isTv;

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
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => onShowControls(),
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
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final twoRows = playerTopBarUsesTwoRows(
                            constraints.maxWidth + 16,
                            MediaQuery.textScalerOf(context),
                          );
                          final status = PlayerDeviceStatus(
                            visible: visible,
                            isTv: isTv,
                          );
                          final titleRow = Row(
                            key: const ValueKey('player-top-title-row'),
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
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: _titleStyle,
                                ),
                              ),
                              if (!twoRows) ...[
                                const SizedBox(width: 12),
                                status,
                              ],
                            ],
                          );
                          if (!twoRows) return titleRow;
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: status,
                                ),
                              ),
                              const SizedBox(height: 4),
                              titleRow,
                            ],
                          );
                        },
                      ),
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
