import 'dart:math' as math;

/// 详情页宽屏布局：手机保持原密度；平板加大封面、限制主按钮宽度、剧集改等宽网格。
class DetailPageLayout {
  const DetailPageLayout({
    required this.isTablet,
    required this.contentWidth,
    required this.pagePadding,
    required this.posterWidth,
    required this.titleSize,
    required this.appBarTitleSize,
    required this.descMaxLines,
    required this.actionRowMaxWidth,
    required this.episodeColumns,
  });

  static const double tabletBreakpoint = 600;
  static const double maxContentWidth = 960;
  static const double tabletActionRowMaxWidth = 560;
  static const double tabletPosterWidth = 168;
  static const double phonePosterWidth = 120;
  static const double episodePillHeight = 48;

  final bool isTablet;
  final double contentWidth;
  final double pagePadding;
  final double posterWidth;
  final double titleSize;
  final double appBarTitleSize;
  final int descMaxLines;
  final double actionRowMaxWidth;
  final int episodeColumns;

  bool get useEpisodeGrid => isTablet && episodeColumns >= 5;

  double get episodeAspectRatio {
    if (episodeColumns <= 0) return 2.4;
    final inner = math.max(0.0, contentWidth - pagePadding * 2);
    final cell = (inner - 8 * (episodeColumns - 1)) / episodeColumns;
    return cell <= 0 ? 2.4 : cell / episodePillHeight;
  }

  factory DetailPageLayout.resolve({
    required double viewportWidth,
    required double shortestSide,
  }) {
    final isTablet = shortestSide >= tabletBreakpoint;
    final contentWidth = isTablet
        ? math.min(viewportWidth, maxContentWidth)
        : viewportWidth;
    final padding = isTablet ? 24.0 : 16.0;
    final inner = math.max(0.0, contentWidth - padding * 2);
    return DetailPageLayout(
      isTablet: isTablet,
      contentWidth: contentWidth,
      pagePadding: padding,
      posterWidth: isTablet ? tabletPosterWidth : phonePosterWidth,
      titleSize: isTablet ? 28 : 22,
      appBarTitleSize: isTablet ? 22 : 17,
      descMaxLines: isTablet ? 8 : 4,
      actionRowMaxWidth: isTablet ? tabletActionRowMaxWidth : double.infinity,
      episodeColumns: _episodeColumns(inner, isTablet: isTablet),
    );
  }

  static int _episodeColumns(double inner, {required bool isTablet}) {
    if (!isTablet) return 0;
    const minCell = 110.0;
    const spacing = 8.0;
    final count = ((inner + spacing) / (minCell + spacing)).floor();
    return count.clamp(5, 8);
  }
}
