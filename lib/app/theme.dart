/// 颜色、字级样式、统一贝塞尔圆角与共用控件样式。
///
/// 数值来源：HANDOFF §3.2（颜色、圆角、触摸区、按压态）与 §3.1（字级表）。
/// 圆角几何统一来自 `bezier_rounded_rect.dart`（用户提供的 Direct2D 路径），
/// 这里只提供半径与形状装配；页面不自行定义圆角外观。
library;

import 'package:flutter/material.dart';

import 'bezier_rounded_rect.dart';
import 'window_layout.dart';

/// 画布、文字、强调色与交互态颜色。
abstract final class AppColors {
  /// 画布与输入底 W。
  static const Color canvas = Color(0xFFFFFFFF);

  /// 主文 T。
  static const Color primaryText = Color(0xFF102341);

  /// 次文 S。
  static const Color secondaryText = Color(0xFF425572);

  /// 蓝 Bc：正常时间、主要操作。
  static const Color accent = Color(0xFF1C52D4);

  /// 浅蓝 L：主卡底、提示条底。
  static const Color accentSurface = Color(0xFFEEF4FF);

  /// 分隔线 D。
  static const Color divider = Color(0xFFD5DEEB);

  /// 提醒与破坏性操作 R。
  static const Color danger = Color(0xFFB42332);

  /// 蓝实心按钮按压底。
  static const Color accentPressed = Color(0xFF1643AB);

  /// 白底文本或图标按钮按压底。
  static const Color surfacePressed = Color(0xFFE4EDFF);

  /// 主卡按压底。
  static const Color cardPressed = Color(0xFFDFE9FF);

  /// 删除动作按压底。
  static const Color dangerPressed = Color(0xFFFBEAEC);

  /// 禁用按钮底。
  static const Color disabledSurface = Color(0xFFE8EDF4);

  /// 禁用按钮字与图标。
  static const Color disabledForeground = Color(0xFF667386);

  /// 删除确认弹窗遮罩：主文色约 20% 不透明度。
  static const Color scrim = Color(0x33102341);
}

/// 设计半径。系数统一来自贝塞尔路径，仅半径可按组件类型区分。
abstract final class AppRadii {
  /// 卡片、确认弹窗。
  static const double card = 12;

  /// 按钮、输入框、提示条、菜单、开关轨道。
  static const double field = 8;

  /// 提示条。
  static const double banner = 8;

  /// 实心/描边按钮。
  static const double solidButton = 8;

  /// 菜单弹层。
  static const double menu = 8;

  /// 开关轨道（可见轮廓，比按钮略大以便容纳圆点）。
  static const double switchTrack = 14;
}

/// 布局与交互的共用尺寸。
abstract final class AppSpacing {
  /// 触摸区最小边长。
  static const double touchTarget = 48;

  /// 分隔线粗细。
  static const double dividerWidth = 1;

  /// 键盘焦点描边。
  static const double focusBorderWidth = 2;
}

/// 按字级代号生成文字样式。
///
/// 数字（B/F/V）固定等宽并加粗；标题、名称（B/N/F/H/K）为粗体，标签与说明（A）
/// 为常规字重。颜色由调用方按作用指定。
TextStyle textStyleOf(
  WindowMetrics metrics,
  TextLevel level, {
  required Color color,
  FontWeight? weight,
}) {
  final bool numeric =
      level == TextLevel.b || level == TextLevel.f || level == TextLevel.v;
  final bool emphasis =
      numeric ||
      level == TextLevel.n ||
      level == TextLevel.h ||
      level == TextLevel.k;
  return TextStyle(
    fontSize: metrics.fontOf(level),
    color: color,
    fontWeight: weight ?? (emphasis ? FontWeight.w700 : FontWeight.w400),
    height: numeric ? 1.1 : 1.3,
    letterSpacing: 0,
    fontFeatures: numeric
        ? const <FontFeature>[FontFeature.tabularFigures()]
        : null,
  );
}

/// 按钮形状：统一贝塞尔圆角矩形（默认 8 dp，描边内缩由形状自身处理）。
OutlinedBorder bezierButtonShape({
  double radius = AppRadii.solidButton,
  BorderSide side = BorderSide.none,
}) => BezierRoundedRectangleBorder(radius: radius, side: side);

/// 应用主题：白底、深色主文、蓝色强调；所有应用内圆角外壳使用贝塞尔轮廓。
ThemeData buildCountdownTheme() {
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: AppColors.accent,
        brightness: Brightness.light,
      ).copyWith(
        primary: AppColors.accent,
        onPrimary: AppColors.canvas,
        surface: AppColors.canvas,
        onSurface: AppColors.primaryText,
        error: AppColors.danger,
        outline: AppColors.divider,
      );
  const BezierRoundedRectangleBorder canvasShape = BezierRoundedRectangleBorder(
    radius: AppRadii.card,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    canvasColor: AppColors.canvas,
    splashFactory: InkRipple.splashFactory,
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: AppSpacing.dividerWidth,
      space: AppSpacing.dividerWidth,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.accent,
    ),
    // 全局按钮默认外形：任何未显式设置 shape 的 Material 按钮也用同一轮廓。
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: canvasShape,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.canvas,
      surfaceTintColor: Colors.transparent,
      shape: BezierRoundedRectangleBorder(radius: AppRadii.card),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: BezierRoundedRectangleBorder(radius: AppRadii.menu),
    ),
    snackBarTheme: const SnackBarThemeData(
      shape: BezierRoundedRectangleBorder(radius: AppRadii.menu),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: ShapeDecoration(
        color: AppColors.primaryText,
        shape: BezierRoundedRectangleBorder(radius: AppRadii.field),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.canvas,
      border: const BezierRoundedInputBorder(radius: AppRadii.field),
      enabledBorder: const BezierRoundedInputBorder(
        radius: AppRadii.field,
        borderSide: BorderSide(color: AppColors.divider),
      ),
      focusedBorder: const BezierRoundedInputBorder(
        radius: AppRadii.field,
        borderSide: BorderSide(
          color: AppColors.accent,
          width: AppSpacing.focusBorderWidth,
        ),
      ),
      errorBorder: const BezierRoundedInputBorder(
        radius: AppRadii.field,
        borderSide: BorderSide(color: AppColors.danger),
      ),
      focusedErrorBorder: const BezierRoundedInputBorder(
        radius: AppRadii.field,
        borderSide: BorderSide(
          color: AppColors.danger,
          width: AppSpacing.focusBorderWidth,
        ),
      ),
    ),
  );
}

/// 蓝实心主要操作按钮。禁用态换底色与字色，且不响应点击。
ButtonStyle solidButtonStyle(WindowMetrics metrics) {
  return ButtonStyle(
    minimumSize: WidgetStatePropertyAll<Size>(Size(0, AppSpacing.touchTarget)),
    padding: const WidgetStatePropertyAll<EdgeInsets>(
      EdgeInsets.symmetric(horizontal: 16),
    ),
    elevation: const WidgetStatePropertyAll<double>(0),
    shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
    textStyle: WidgetStatePropertyAll<TextStyle>(
      textStyleOf(
        metrics,
        TextLevel.a,
        color: AppColors.canvas,
        weight: FontWeight.w600,
      ),
    ),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.disabledSurface;
      }
      if (states.contains(WidgetState.pressed)) {
        return AppColors.accentPressed;
      }
      return AppColors.accent;
    }),
    foregroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.disabledForeground;
      }
      return AppColors.canvas;
    }),
  );
}

/// 白底描边按钮：默认蓝边蓝字，可切换为红色（取消）或其它强调色。
///
/// 可见高度、圆角与实心按钮一致；触摸区由 `tapTargetSize` 保证不小于 48 dp。
ButtonStyle outlinedButtonStyle(
  WindowMetrics metrics, {
  Color color = AppColors.accent,
  Color pressedSurface = AppColors.surfacePressed,
}) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(
      Size(0, AppSpacing.touchTarget),
    ),
    tapTargetSize: MaterialTapTargetSize.padded,
    padding: const WidgetStatePropertyAll<EdgeInsets>(
      EdgeInsets.symmetric(horizontal: 16),
    ),
    elevation: const WidgetStatePropertyAll<double>(0),
    shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
    textStyle: WidgetStatePropertyAll<TextStyle>(
      textStyleOf(metrics, TextLevel.a, color: color, weight: FontWeight.w600),
    ),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.canvas;
      }
      if (states.contains(WidgetState.pressed)) {
        return pressedSurface;
      }
      return AppColors.canvas;
    }),
    foregroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.disabledForeground;
      }
      return color;
    }),
    side: WidgetStateProperty.resolveWith<BorderSide>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return const BorderSide(color: AppColors.disabledForeground);
      }
      return BorderSide(color: color, width: 1);
    }),
  );
}

/// 纯文字操作按钮（菜单项、弹窗取消等）。按压底随动作性质变化，
/// 按压外形同样使用贝塞尔圆角矩形。
ButtonStyle textActionButtonStyle(
  WindowMetrics metrics, {
  required Color foreground,
  required Color pressedSurface,
}) {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(Size(64, 40)),
    tapTargetSize: MaterialTapTargetSize.padded,
    padding: const WidgetStatePropertyAll<EdgeInsets>(
      EdgeInsets.symmetric(horizontal: 12),
    ),
    elevation: const WidgetStatePropertyAll<double>(0),
    shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.pressed)) {
        return pressedSurface;
      }
      return Colors.transparent;
    }),
    foregroundColor: WidgetStateProperty.resolveWith<Color>((
      Set<WidgetState> states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.disabledForeground;
      }
      return foreground;
    }),
    textStyle: WidgetStatePropertyAll<TextStyle>(
      textStyleOf(metrics, TextLevel.a, color: foreground),
    ),
  );
}

/// 名称输入框外观：白底、D 边、贝塞尔 8 圆角，聚焦时 2 dp 蓝描边。
InputDecoration countdownFieldDecoration({
  required WindowMetrics metrics,
  String? hintText,
  bool enabled = true,
}) {
  BezierRoundedInputBorder border(Color color, double width) =>
      BezierRoundedInputBorder(
        radius: AppRadii.field,
        borderSide: BorderSide(color: color, width: width),
      );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: enabled ? AppColors.canvas : AppColors.disabledSurface,
    hintText: hintText,
    hintStyle: textStyleOf(
      metrics,
      TextLevel.k,
      color: AppColors.disabledForeground,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    constraints: const BoxConstraints(minHeight: AppSpacing.touchTarget),
    enabledBorder: border(AppColors.divider, 1),
    disabledBorder: border(AppColors.divider, 1),
    focusedBorder: border(AppColors.accent, AppSpacing.focusBorderWidth),
    errorBorder: border(AppColors.danger, 1),
    focusedErrorBorder: border(AppColors.danger, AppSpacing.focusBorderWidth),
  );
}
