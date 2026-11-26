/// 05 删除确认弹窗：锁定目标、说明后果、确认或取消。
///
/// 弹窗只负责交互与展示；删除由 [CountdownController.deleteProject] 执行，
/// 失败时保留目标供重试，不伪造成功。目标以项目 ID 锁定，不依赖列表下标。
/// 弹窗外壳沿用全应用统一的贝塞尔圆角矩形（半径 12，与卡片一致）。
library;

import 'package:flutter/material.dart';

import '../app/bezier_rounded_rect.dart';
import '../app/theme.dart';
import '../app/window_layout.dart';
import 'controller.dart';
import 'model.dart';

/// 显示删除确认弹窗，返回是否已确认删除。
Future<bool> showDeleteProjectDialog(
  BuildContext context, {
  required CountdownController controller,
  required CountdownProject project,
}) async {
  final bool? deleted = await showDialog<bool>(
    context: context,
    barrierColor: AppColors.scrim,
    barrierLabel: '取消删除',
    useSafeArea: true,
    builder: (BuildContext dialogContext) =>
        DeleteProjectDialog(controller: controller, project: project),
  );
  return deleted ?? false;
}

/// 删除确认弹窗。
class DeleteProjectDialog extends StatefulWidget {
  const DeleteProjectDialog({
    super.key,
    required this.controller,
    required this.project,
  });

  final CountdownController controller;

  /// 发起删除时锁定的目标项目。
  final CountdownProject project;

  @override
  State<DeleteProjectDialog> createState() => _DeleteProjectDialogState();
}

class _DeleteProjectDialogState extends State<DeleteProjectDialog> {
  bool _submitting = false;
  String? _errorText;

  /// 运行中的项目还要提示计时会被终止；其余项目没有这一后果。
  bool get _targetIsRunning =>
      widget.controller.activeRun?.projectId == widget.project.id;

  Future<void> _confirmDelete() async {
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    final CommandStatus status = await widget.controller.deleteProject(
      widget.project.id,
    );
    if (!mounted) {
      return;
    }
    if (status == CommandStatus.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _errorText = widget.controller.lastFailureMessage ?? '操作失败，请重试。';
    });
  }

  void _cancel() {
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final WindowMetrics metrics = WindowMetrics.of(context);
    // 提交期间禁止系统返回与遮罩点击收起弹窗：删除已经发出，若此时关闭弹窗，
    // 弹窗返回的「未删除」会与真实结果不一致。按钮本身也同时禁用。
    return PopScope(
      canPop: !_submitting,
      child: Dialog(
        backgroundColor: AppColors.canvas,
        surfaceTintColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: metrics.dialogHorizontalInset,
          vertical: metrics.dialogVerticalInset,
        ),
        constraints: BoxConstraints(maxWidth: metrics.dialogMaxWidth),
        // 弹窗外壳与全应用共用同一条贝塞尔圆角路径（半径 12，与卡片一致）。
        shape: const BezierRoundedRectangleBorder(radius: AppRadii.card),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.all(metrics.dialogPadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 标题与说明可滚动，操作区固定在其下方，长名称不会把按钮挤出屏幕。
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '删除「${widget.project.name}」？',
                          style: textStyleOf(
                            metrics,
                            TextLevel.h,
                            color: AppColors.primaryText,
                          ),
                        ),
                        if (_targetIsRunning) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            '将结束本次计时。',
                            style: textStyleOf(
                              metrics,
                              TextLevel.a,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ],
                        if (_errorText != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            _errorText!,
                            style: textStyleOf(
                              metrics,
                              TextLevel.a,
                              color: AppColors.danger,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      TextButton(
                        style: textActionButtonStyle(
                          metrics,
                          foreground: AppColors.primaryText,
                          pressedSurface: AppColors.surfacePressed,
                        ),
                        onPressed: _submitting ? null : _cancel,
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        style: textActionButtonStyle(
                          metrics,
                          foreground: AppColors.danger,
                          pressedSurface: AppColors.dangerPressed,
                        ),
                        onPressed: _submitting ? null : _confirmDelete,
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
