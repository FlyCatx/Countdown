/// 03/04 共用的中心计时组：名称在上、八字符 `HH:MM:SS` 在下。
///
/// 排版规则来自 HANDOFF §3.1：先让名称在给定宽度内换行（最多两行），数字再在剩余
/// 宽度内整体等比缩小，保证八字符永远单行完整显示。字号、间距与颜色只从 `lib/app`
/// 的共享主题读取，页面与提醒条复用同一套排版。
library;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/window_layout.dart';

/// 居中的名称与时间双行组。
///
/// 自身不加外边距：横向可用宽度由父级给定，整体居中由页面负责。
class TimerDisplay extends StatelessWidget {
  const TimerDisplay({
    super.key,
    this.metrics,
    required this.name,
    required this.timeText,
    required this.timeColor,
  });

  /// 布局度量。
  ///
  /// 运行页在 SafeArea 内构建本组件，此时 MediaQuery 的系统安全边已被 SafeArea
  /// 置零；直接读 [WindowMetrics] 会把整窗短边当成安全短边，断点可能判错。
  /// 因此由页面传入在 SafeArea 外取得的度量，未传时退回当前环境。
  final WindowMetrics? metrics;

  /// 项目名称。过长时先换行，最多两行后末端省略。
  final String name;

  /// 已格式化好的剩余时间，固定八字符 `HH:MM:SS`。
  final String timeText;

  /// 数字颜色：普通状态为强调蓝，提醒区间为红色。
  final Color timeColor;

  @override
  Widget build(BuildContext context) {
    final WindowMetrics layoutMetrics = metrics ?? WindowMetrics.of(context);
    final TextStyle nameStyle = textStyleOf(
      layoutMetrics,
      TextLevel.n,
      color: AppColors.primaryText,
    );
    // B 级样式在 theme.dart 中已带粗体与 tabularFigures：数字宽度稳定，
    // 每秒变化时不会左右抖动。
    final TextStyle timeStyle = textStyleOf(
      layoutMetrics,
      TextLevel.b,
      color: timeColor,
    );
    return Semantics(
      container: true,
      // 数字每秒变化，不用 live region，避免读屏每秒打断当前朗读。
      liveRegion: false,
      label: '$name，剩余 $timeText',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: nameStyle,
          ),
          SizedBox(height: layoutMetrics.runningGroupGap),
          // 宽度不足时整体缩小而不是换行或截断，八字符始终完整单行。
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              timeText,
              maxLines: 1,
              softWrap: false,
              style: timeStyle,
            ),
          ),
        ],
      ),
    );
  }
}
