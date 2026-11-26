/// 全应用统一的贝塞尔圆角矩形几何与形状适配。
///
/// 几何来自用户提供的 Direct2D 路径直译：四角各用一段三次贝塞尔，控制点按
/// `cx = radius × 0.675`、`cx1 = 0.000155 × cx` 计算，直边与曲线顺序与符号保持原样。
/// 不允许用标准圆弧（`BorderRadius`/`StadiumBorder`）替代该轮廓。
///
/// 本文件提供：
/// - [buildBezierRoundedRectPath]：唯一几何来源；
/// - [BezierRoundedRectangleBorder]：可作按钮形状、卡片/弹窗/菜单/提示条的
///   `ShapeBorder`，也支持描边；
/// - [BezierRoundedInputBorder]：输入框边框；
/// - [bezierClip]：按同一轮廓裁剪任意子树。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 按母版几何构造四角贝塞尔矩形路径。
///
/// [radius] 会被防御性限制在 `0 .. min(width, height) / 2`；零尺寸或零半径时
/// 退化为矩形路径（零尺寸返回空路径）。
Path buildBezierRoundedRectPath({
  required double left,
  required double top,
  required double right,
  required double bottom,
  required double radius,
}) {
  final double width = right - left;
  final double height = bottom - top;
  final Path path = Path()..fillType = PathFillType.nonZero;
  if (width <= 0 || height <= 0) {
    return path;
  }
  final double safeRadius = radius.isFinite
      ? radius.clamp(0.0, math.min(width, height) / 2)
      : 0.0;
  if (safeRadius <= 0) {
    path.addRect(Rect.fromLTRB(left, top, right, bottom));
    return path;
  }

  // 原 Direct2D 路径：x 为圆角控制半径，x1 为极小的控制点偏移。
  final double cx = safeRadius * 0.675;
  final double cx1 = 0.000155 * cx;

  path.moveTo(left + safeRadius, top);
  path.lineTo(right - safeRadius, top);

  // 右上角。
  double x2 = right;
  double y2 = top + safeRadius;
  path.cubicTo(x2 - safeRadius + cx, top + cx1, x2 - cx1, y2 - cx, x2, y2);

  path.lineTo(right, bottom - safeRadius);

  // 右下角。
  x2 = right - safeRadius;
  y2 = bottom;
  path.cubicTo(
    x2 + safeRadius - cx1,
    y2 - safeRadius + cx,
    x2 + cx,
    y2 - cx1,
    x2,
    y2,
  );

  path.lineTo(left + safeRadius, bottom);

  // 左下角。
  x2 = left;
  y2 = bottom - safeRadius;
  path.cubicTo(
    x2 + safeRadius - cx,
    y2 + safeRadius - cx1,
    x2 + cx1,
    y2 + cx,
    x2,
    y2,
  );

  path.lineTo(left, top + safeRadius);

  // 左上角。
  x2 = left + safeRadius;
  y2 = top;
  path.cubicTo(
    x2 - safeRadius + cx1,
    y2 + safeRadius - cx,
    x2 - cx,
    y2 + cx1,
    x2,
    y2,
  );

  path.close();
  return path;
}

/// 以控件矩形与半径构造路径的便捷入口。
Path bezierRoundedRectPath(Rect rect, double radius) =>
    buildBezierRoundedRectPath(
      left: rect.left,
      top: rect.top,
      right: rect.right,
      bottom: rect.bottom,
      radius: radius,
    );

/// 四角贝塞尔圆角矩形边框，可同时作为填充轮廓（`shape`）与描边（`side`）。
class BezierRoundedRectangleBorder extends OutlinedBorder {
  const BezierRoundedRectangleBorder({
    this.radius = 8,
    super.side = BorderSide.none,
  });

  /// 设计半径；实际绘制时限制在 0 至短边一半以内。
  final double radius;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      bezierRoundedRectPath(rect, radius);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    final double inset = side.strokeInset;
    final Rect inner = inset > 0 ? rect.deflate(inset) : rect;
    return bezierRoundedRectPath(inner, math.max(0, radius - inset));
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) {
      return;
    }
    final double inset = side.strokeInset;
    final Rect outline = inset > 0 ? rect.deflate(inset) : rect;
    final Paint paint = Paint()
      ..color = side.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = side.width
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      bezierRoundedRectPath(outline, math.max(0, radius - inset)),
      paint,
    );
  }

  @override
  BezierRoundedRectangleBorder copyWith({BorderSide? side, double? radius}) {
    return BezierRoundedRectangleBorder(
      radius: radius ?? this.radius,
      side: side ?? this.side,
    );
  }

  @override
  BezierRoundedRectangleBorder scale(double t) {
    return BezierRoundedRectangleBorder(
      radius: radius * t,
      side: side.scale(t),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is BezierRoundedRectangleBorder &&
        other.radius == radius &&
        other.side == side;
  }

  @override
  int get hashCode => Object.hash(radius, side);
}

/// 贝塞尔圆角输入框边框（白底 + 描边，聚焦时 2 dp 蓝边由调用方给出）。
///
/// 本应用的输入框不使用浮动标签，因此 [paint] 的 gap 参数只用于兼容接口，
/// 顶部直线始终完整绘制。
class BezierRoundedInputBorder extends InputBorder {
  const BezierRoundedInputBorder({
    this.radius = 8,
    super.borderSide = const BorderSide(),
  });

  final double radius;

  @override
  bool get isOutline => true;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.strokeInset);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      bezierRoundedRectPath(rect, radius);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    final double inset = borderSide.strokeInset;
    final Rect inner = inset > 0 ? rect.deflate(inset) : rect;
    return bezierRoundedRectPath(inner, math.max(0, radius - inset));
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none || borderSide.width <= 0) {
      return;
    }
    final double inset = borderSide.strokeInset;
    final Rect outline = inset > 0 ? rect.deflate(inset) : rect;
    final Paint paint = Paint()
      ..color = borderSide.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderSide.width
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      bezierRoundedRectPath(outline, math.max(0, radius - inset)),
      paint,
    );
  }

  @override
  BezierRoundedInputBorder copyWith({BorderSide? borderSide, double? radius}) {
    return BezierRoundedInputBorder(
      radius: radius ?? this.radius,
      borderSide: borderSide ?? this.borderSide,
    );
  }

  @override
  BezierRoundedInputBorder scale(double t) {
    return BezierRoundedInputBorder(
      radius: radius * t,
      borderSide: borderSide.scale(t),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is BezierRoundedInputBorder &&
        other.radius == radius &&
        other.borderSide == borderSide;
  }

  @override
  int get hashCode => Object.hash(radius, borderSide);
}

/// 按贝塞尔圆角矩形裁剪子树（与 [BezierRoundedRectangleBorder] 同一几何）。
Widget bezierClip({required double radius, required Widget child}) {
  return ClipPath(clipper: _BezierRoundedRectClipper(radius), child: child);
}

class _BezierRoundedRectClipper extends CustomClipper<Path> {
  const _BezierRoundedRectClipper(this.radius);

  final double radius;

  @override
  Path getClip(Size size) => bezierRoundedRectPath(Offset.zero & size, radius);

  @override
  bool shouldReclip(_BezierRoundedRectClipper oldClipper) =>
      oldClipper.radius != radius;
}
