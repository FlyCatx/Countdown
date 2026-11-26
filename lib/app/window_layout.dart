/// 窗口尺寸分类、安全区与四向布局度量。
///
/// 划分依据（HANDOFF §3.1）：以扣除系统栏、显示缺口和左右安全边后的**安全窗口
/// 短边 600 dp** 区分手机型/平板型，以宽大于高区分横屏。所有页面都从本文件读取
/// 间距与字级，避免同一数值在多个页面各自定义。
library;

import 'package:flutter/widgets.dart';

/// 字级代号，直接对应 HANDOFF §3.1 表格的一行。
enum TextLevel {
  /// 运行页最大号时间数字。
  b,

  /// 运行页名称。
  n,

  /// 主卡时间。
  f,

  /// 页标题与弹窗标题。
  h,

  /// 主卡名称、行名称、输入名称、分区标题。
  k,

  /// 行时间、时长值。
  v,

  /// 动作、提示、说明、标签。
  a,
}

/// 四种基准朝向。分屏或键盘出现时按真实可用空间重新判定，页面只需响应度量变化。
enum WindowSizeClass {
  phonePortrait,
  phoneLandscape,
  tabletPortrait,
  tabletLandscape;

  bool get isTablet =>
      this == WindowSizeClass.tabletPortrait ||
      this == WindowSizeClass.tabletLandscape;

  bool get isLandscape =>
      this == WindowSizeClass.phoneLandscape ||
      this == WindowSizeClass.tabletLandscape;
}

/// 某一时刻的安全区与四向布局度量。不可变，窗口变化时重新创建。
@immutable
class WindowMetrics {
  const WindowMetrics({
    required this.sizeClass,
    required this.safeSize,
    required this.safePadding,
  });

  /// 当前朝向分类。
  final WindowSizeClass sizeClass;

  /// 扣除系统栏、显示缺口和左右安全边后的可用尺寸。
  final Size safeSize;

  /// 安全区相对窗口的偏移（`MediaQuery.padding`）。
  final EdgeInsets safePadding;

  /// 从当前窗口环境推导度量。
  ///
  /// 键盘弹出时不改变分类依据：短边与横竖只由安全窗口决定，表单自身滚动到
  /// 聚焦字段（HANDOFF §4.2 四向）。
  factory WindowMetrics.of(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final Size size = media.size;
    final EdgeInsets padding = media.padding;
    final double safeWidth = (size.width - padding.horizontal).clamp(
      0.0,
      double.infinity,
    );
    final double safeHeight = (size.height - padding.vertical).clamp(
      0.0,
      double.infinity,
    );
    final double shortSide = safeWidth < safeHeight ? safeWidth : safeHeight;
    final bool landscape = safeWidth > safeHeight;
    final WindowSizeClass sizeClass;
    if (shortSide >= 600) {
      sizeClass = landscape
          ? WindowSizeClass.tabletLandscape
          : WindowSizeClass.tabletPortrait;
    } else {
      sizeClass = landscape
          ? WindowSizeClass.phoneLandscape
          : WindowSizeClass.phonePortrait;
    }
    return WindowMetrics(
      sizeClass: sizeClass,
      safeSize: Size(safeWidth, safeHeight),
      safePadding: padding,
    );
  }

  // ---- 字级（sp）。系统文字缩放由 TextStyle 的默认行为叠加。 ----

  /// 表列：B / N / F / H / K / V / A。
  double fontOf(TextLevel level) {
    final List<double> column = switch (sizeClass) {
      WindowSizeClass.phonePortrait => const <double>[
        64,
        32,
        36,
        24,
        20,
        18,
        14,
      ],
      WindowSizeClass.phoneLandscape => const <double>[
        92,
        40,
        40,
        24,
        20,
        18,
        14,
      ],
      WindowSizeClass.tabletPortrait => const <double>[
        112,
        52,
        48,
        28,
        24,
        20,
        16,
      ],
      WindowSizeClass.tabletLandscape => const <double>[
        144,
        64,
        56,
        32,
        26,
        22,
        18,
      ],
    };
    return column[level.index];
  }

  // ---- 通用间距 ----

  /// 列表页与新增页左右内边距：手机 16，平板竖 24，平板横 32（最小值）。
  double get pageHorizontalPadding => switch (sizeClass) {
    WindowSizeClass.phonePortrait || WindowSizeClass.phoneLandscape => 16,
    WindowSizeClass.tabletPortrait => 24,
    WindowSizeClass.tabletLandscape => 32,
  };

  /// 页面顶部与标题之间的间距。
  double get pageTopSpacing => 16;

  /// 主卡与列表两区之间的间距（HANDOFF §4.1 四向）。
  double get sectionGap => switch (sizeClass) {
    WindowSizeClass.phonePortrait || WindowSizeClass.phoneLandscape => 16,
    WindowSizeClass.tabletPortrait => 24,
    WindowSizeClass.tabletLandscape => 32,
  };

  /// 分栏布局的栏间距。
  double get columnGap => switch (sizeClass) {
    WindowSizeClass.phonePortrait || WindowSizeClass.phoneLandscape => 16,
    WindowSizeClass.tabletPortrait => 24,
    WindowSizeClass.tabletLandscape => 32,
  };

  /// 左栏占比：横屏 38%，竖屏不分栏。
  double get leftColumnFraction => 0.38;

  /// 列表页是否使用左右分栏。
  bool get usesColumns =>
      sizeClass == WindowSizeClass.phoneLandscape ||
      sizeClass == WindowSizeClass.tabletLandscape;

  /// 列表页内容最大宽度限制：平板竖屏 600；平板横屏 1120；手机不限制。
  double get listMaxContentWidth => switch (sizeClass) {
    WindowSizeClass.phonePortrait ||
    WindowSizeClass.phoneLandscape => double.infinity,
    WindowSizeClass.tabletPortrait => 600,
    WindowSizeClass.tabletLandscape => 1120,
  };

  // ---- 运行页（03/04 共用中心组） ----

  /// 运行页左右内边距：手机竖 16、手机横 24、平板竖 32、平板横 48。
  double get runningHorizontalPadding => switch (sizeClass) {
    WindowSizeClass.phonePortrait => 16,
    WindowSizeClass.phoneLandscape => 24,
    WindowSizeClass.tabletPortrait => 32,
    WindowSizeClass.tabletLandscape => 48,
  };

  /// 运行页名称与数字的组内间距。
  double get runningGroupGap => switch (sizeClass) {
    WindowSizeClass.phonePortrait => 12,
    WindowSizeClass.phoneLandscape => 8,
    WindowSizeClass.tabletPortrait => 16,
    WindowSizeClass.tabletLandscape => 20,
  };

  /// 运行页返回入口距安全边 16。
  double get runningNavPadding => 16;

  /// 运行页导航行高度下限（触摸区）。
  double get runningNavHeight => 48;

  // ---- 列表页 ----

  /// 主卡内边距 16、圆角 12；行内纵向留白 8。
  double get cardPadding => 16;
  double get listRowVerticalPadding => 8;
  double get listRowMinHeight => 64;
  double get sectionHeaderMinHeight => 48;

  // ---- 新增页（02） ----

  /// 表单组间距。
  double get formGroupGap => switch (sizeClass) {
    WindowSizeClass.phonePortrait || WindowSizeClass.phoneLandscape => 16,
    WindowSizeClass.tabletPortrait || WindowSizeClass.tabletLandscape => 24,
  };

  /// 单列表单最大宽度（平板竖屏 560，其它按需）。
  double get formMaxWidth => switch (sizeClass) {
    WindowSizeClass.phonePortrait ||
    WindowSizeClass.phoneLandscape => double.infinity,
    WindowSizeClass.tabletPortrait => 560,
    WindowSizeClass.tabletLandscape => 960,
  };

  /// 表单是否分成左右两列。
  bool get formUsesColumns =>
      sizeClass == WindowSizeClass.phoneLandscape ||
      sizeClass == WindowSizeClass.tabletLandscape;

  /// 横屏表单左列宽度占比：手机横约 55%；平板横光两侧总宽上限由
  /// [formMaxWidth] 约束，左右近似等宽。
  double get formLeftColumnFraction =>
      sizeClass == WindowSizeClass.phoneLandscape ? 0.55 : 0.5;

  // ---- 删除弹窗（05） ----

  /// 弹窗最大宽度：手机竖/横 ≤360、平板竖 ≤400、平板横 ≤440。
  double get dialogMaxWidth => switch (sizeClass) {
    WindowSizeClass.phonePortrait || WindowSizeClass.phoneLandscape => 360,
    WindowSizeClass.tabletPortrait => 400,
    WindowSizeClass.tabletLandscape => 440,
  };

  double get dialogPadding => 20;

  /// 手机竖屏弹窗左右至少留 16；手机横屏纵向至少留 12。
  double get dialogHorizontalInset =>
      sizeClass == WindowSizeClass.phonePortrait ||
          sizeClass == WindowSizeClass.phoneLandscape
      ? 16
      : 24;

  double get dialogVerticalInset =>
      sizeClass == WindowSizeClass.phoneLandscape ? 12 : 24;

  // ---- 提醒提示条（04） ----

  /// 提示条与导航行的距离：手机竖屏在导航下方 8。
  double get bannerTopGap => 8;

  /// 平板竖屏提示条限宽 480。
  double get bannerMaxWidth => switch (sizeClass) {
    WindowSizeClass.tabletPortrait => 480,
    _ => double.infinity,
  };

  /// 横屏提示条与安全边内的右侧距离。
  double get bannerTrailingInset => switch (sizeClass) {
    WindowSizeClass.phoneLandscape => 16,
    WindowSizeClass.tabletLandscape => 32,
    _ => 0,
  };
}

/// 便捷入口：`WindowMetricsScope` 未显式包裹时直接读 MediaQuery。
extension WindowMetricsContext on BuildContext {
  WindowMetrics get windowMetrics => WindowMetrics.of(this);
}
