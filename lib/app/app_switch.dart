/// 应用开关：贝塞尔圆角矩形轨道 + 圆形滑块。
///
/// Flutter 的 Material `Switch` 轨道固定为胶囊形，无法使用统一圆角轮廓，因此这里
/// 自绘可见外形，但保留开关语义与交互：读屏提供 `toggled` 状态与点按动作，键盘
/// 空格/回车可切换，触摸区不小于 48 dp，禁用态不响应。滑块沿用圆形（母版圆点），
/// 轨道外壳与全应用其它圆角组件使用同一贝塞尔轮廓。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bezier_rounded_rect.dart';
import 'theme.dart';

/// 开关（贝塞尔圆角轨道）。
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.semanticsLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final String? semanticsLabel;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _focused = false;

  bool get _enabled => widget.enabled && widget.onChanged != null;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(AppSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.animateTo(
        widget.value ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
    if (!_enabled && _focused) {
      _focused = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (!_enabled) {
      return;
    }
    // 轻触反馈与 Material 开关一致；失败由调用方决定状态，组件本身不乐观更新。
    HapticFeedback.selectionClick();
    widget.onChanged!(!widget.value);
  }

  @override
  Widget build(BuildContext context) {
    final bool on = widget.value;
    return Semantics(
      container: true,
      toggled: on,
      enabled: _enabled,
      label: widget.semanticsLabel,
      onTap: _enabled ? _toggle : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (bool visible) =>
            setState(() => _focused = visible),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (ActivateIntent intent) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _toggle : null,
          child: SizedBox(
            height: AppSpacing.touchTarget,
            width: 60,
            child: Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (BuildContext context, Widget? child) {
                  return CustomPaint(
                    size: const Size(52, 32),
                    painter: _SwitchPainter(
                      progress: _controller.value,
                      enabled: _enabled,
                      focused: _focused,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchPainter extends CustomPainter {
  const _SwitchPainter({
    required this.progress,
    required this.enabled,
    required this.focused,
  });

  final double progress;
  final bool enabled;
  final bool focused;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect trackRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final Path trackPath = bezierRoundedRectPath(
      trackRect.deflate(1),
      AppRadii.switchTrack,
    );
    final Color trackColor = Color.lerp(
      AppColors.canvas,
      AppColors.accent,
      progress,
    )!;
    final Color outlineColor = Color.lerp(
      AppColors.divider,
      AppColors.accent,
      progress,
    )!;
    final double outlineWidth = enabled ? 1 : 1;
    canvas.drawPath(
      trackPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = trackColor,
    );
    canvas.drawPath(
      bezierRoundedRectPath(
        trackRect.deflate(1 + outlineWidth / 2),
        AppRadii.switchTrack - 1,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = outlineWidth
        ..color = enabled
            ? outlineColor
            : AppColors.disabledForeground.withValues(alpha: 0.5),
    );

    // 滑块：白色圆形，落在轨道内侧；关闭态给一圈 D 色描边以保持可见。
    const double thumbRadius = 11;
    final double travel = size.width - thumbRadius * 2 - 8;
    final Offset thumbCenter = Offset(
      4 + thumbRadius + travel * progress,
      size.height / 2,
    );
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(
      thumbCenter,
      thumbRadius,
      Paint()..color = AppColors.canvas,
    );
    if (progress < 1) {
      canvas.drawCircle(
        thumbCenter,
        thumbRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = AppColors.divider,
      );
    }

    if (focused) {
      canvas.drawPath(
        bezierRoundedRectPath(trackRect, AppRadii.switchTrack + 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = AppSpacing.focusBorderWidth
          ..color = AppColors.accent,
      );
    }
  }

  @override
  bool shouldRepaint(_SwitchPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.enabled != enabled ||
      oldDelegate.focused != focused;
}
