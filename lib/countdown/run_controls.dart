/// 运行控制区：暂停／继续、重新计时、取消。
///
/// 运行页与首页活动卡共用同一套按钮与顺序，避免两处操作语义分叉。三个按钮同高、
/// 同一贝塞尔圆角矩形轮廓、各自有可见边界：暂停为蓝底白字，重新计时为白底蓝描边，
/// 取消为白底红描边红字；触摸高度不小于 48 dp。`busy` 期间全部禁用，防止连点。
library;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/window_layout.dart';

/// 三个本轮控制动作。
class RunControls extends StatelessWidget {
  const RunControls({
    super.key,
    required this.metrics,
    required this.paused,
    required this.busy,
    required this.onTogglePause,
    required this.onRestart,
    required this.onCancel,
    this.alignment = WrapAlignment.center,
  });

  final WindowMetrics metrics;
  final bool paused;
  final bool busy;
  final VoidCallback onTogglePause;
  final VoidCallback onRestart;
  final VoidCallback onCancel;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        FilledButton.icon(
          style: solidButtonStyle(metrics),
          onPressed: busy ? null : onTogglePause,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause, size: 20),
          label: Text(paused ? '继续' : '暂停'),
        ),
        OutlinedButton.icon(
          style: outlinedButtonStyle(metrics),
          onPressed: busy ? null : onRestart,
          icon: const Icon(Icons.refresh, size: 20),
          label: const Text('重新计时'),
        ),
        OutlinedButton(
          style: outlinedButtonStyle(
            metrics,
            color: AppColors.danger,
            pressedSurface: AppColors.dangerPressed,
          ),
          onPressed: busy ? null : onCancel,
          child: const Text('取消'),
        ),
      ],
    );
  }
}
