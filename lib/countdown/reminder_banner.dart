/// 04 提前提醒提示条：浅蓝底、铃、秒级剩余时间与收起按钮。
///
/// 提示条是运行页顶部的浮层：位置与最大宽度由页面按四向规则决定，自身只按内容
/// 收缩，不占满整行，也不参与中心组的定位计算（见 HANDOFF §4.4）。文案与实际正
/// 剩余量一致，精确到秒；不按整分钟取整。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/bezier_rounded_rect.dart';
import '../app/theme.dart';
import '../app/window_layout.dart';
import 'time_format.dart';

/// 提前提醒提示条。
class ReminderBanner extends StatelessWidget {
  const ReminderBanner({
    super.key,
    this.metrics,
    required this.remainingMillis,
    required this.onDismiss,
  });

  /// 布局度量。
  ///
  /// 运行页在 SafeArea 内构建本组件，MediaQuery 的系统安全边已被 SafeArea 置零；
  /// 为保证字号断点与页面一致，由页面传入在 SafeArea 外取得的度量，未传时退回
  /// 当前环境。
  final WindowMetrics? metrics;

  /// 显示时应表达的正剩余毫秒数；页面每秒更新一次即可让文案持续走动。
  final int remainingMillis;

  /// 收起本轮提示条；红色数字不受影响。
  final VoidCallback onDismiss;

  /// 提示条在给定度量与文字缩放下占用的高度。
  ///
  /// 运行页用它在中心组上方预留浮层空间：高度取行内最高的元素，
  /// 即关闭按钮的 48 触摸区或放大后的单行 A 级文字。
  static double heightFor(WindowMetrics metrics, TextScaler textScaler) {
    final TextStyle textStyle = textStyleOf(
      metrics,
      TextLevel.a,
      color: AppColors.primaryText,
    );
    final double textHeight =
        textScaler.scale(textStyle.fontSize ?? 0) * (textStyle.height ?? 1.2);
    return math.max(AppSpacing.touchTarget, textHeight);
  }

  @override
  Widget build(BuildContext context) {
    final WindowMetrics layoutMetrics = metrics ?? WindowMetrics.of(context);
    return Material(
      color: AppColors.accentSurface,
      shape: const BezierRoundedRectangleBorder(radius: AppRadii.banner),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSpacing.touchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.notifications_none,
                size: 20,
                color: AppColors.accent,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  reminderTextForRemaining(remainingMillis),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyleOf(
                    layoutMetrics,
                    TextLevel.a,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: '收起提醒提示',
                onTap: onDismiss,
                // 图标没有文字标签，排除默认语义后由本节点统一提供按钮标签。
                excludeSemantics: true,
                child: IconButton(
                  onPressed: onDismiss,
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close),
                  style: IconButton.styleFrom(
                    foregroundColor: AppColors.primaryText,
                    minimumSize: const Size(
                      AppSpacing.touchTarget,
                      AppSpacing.touchTarget,
                    ),
                    // 白底图标按钮的按压底；提示条本身是浅蓝底，按压外形跟随圆角。
                    highlightColor: AppColors.surfacePressed,
                    shape: const BezierRoundedRectangleBorder(
                      radius: AppRadii.field,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
