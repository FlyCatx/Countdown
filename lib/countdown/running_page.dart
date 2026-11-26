/// 03 倒计时运行页与 04 提前提醒：居中双行主体、数字正下方的本轮控制区、
/// 顶部返回入口与秒级提示条浮层。
///
/// 数字与提示条文案只由 [CountdownController.clockListenable] 每秒驱动，页面结构只在
/// 控制器状态变化时重建。中心组仍以安全区中心为基准，控制区在中心组下方单独定位，
/// 正常窗口里不会把名称和数字推离中心。窄窗导致按钮换行、大字体或极短窗口放不下
/// 时，先压缩控制区上方间距，再压缩中心组高度（名称与数字等比缩小），保证三个
/// 动作始终完整可见、不被裁切；触摸目标只在极端窗口里随整块缩小。
///
/// 归零后控制器会结束本轮并从 [CountdownController.activeRun] 清空，本页仍用最后
/// 一次有效快照显示原名称与 00:00:00，直到用户返回列表；此时隐藏控制区，避免对
/// 已结束的一轮继续发命令。暂停中控制器刷新后仍返回冻结的剩余毫秒，页面直接显示
/// 冻结值与继续按钮，不自行推算状态；提示条文案同样按冻结值显示。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/bezier_rounded_rect.dart';
import '../app/theme.dart';
import '../app/window_layout.dart';
import 'controller.dart';
import 'model.dart';
import 'reminder_banner.dart';
import 'run_controls.dart';
import 'time_format.dart';
import 'timer_display.dart';

/// 倒计时运行页（03）；同一页面在提醒区间内兼作 04。
class RunningPage extends StatefulWidget {
  const RunningPage({super.key, required this.controller});

  final CountdownController controller;

  @override
  State<RunningPage> createState() => _RunningPageState();
}

class _RunningPageState extends State<RunningPage> {
  /// 最后一次有效的运行快照。
  ///
  /// 归零后控制器结束本轮并清空 activeRun；若直接读 activeRun，页面会在刷新
  /// 间隙失去名称，或错误地显示列表里其他项目的数据。缓存只在本页生命周期内
  /// 有效，返回列表后丢弃，不写回控制器。
  RunSnapshot? _lastRun;

  /// 已安排“无可显示运行则返回列表”，避免重复的帧回调产生多次 pop。
  bool _exitScheduled = false;

  @override
  void initState() {
    super.initState();
    _lastRun = widget.controller.activeRun;
    _scheduleExitIfNothingToShow();
  }

  @override
  Widget build(BuildContext context) {
    // 在 SafeArea 之外读取度量：SafeArea 会把系统安全边从 MediaQuery 中扣除，
    // 在其内部再算 [WindowMetrics] 会把整窗尺寸当成安全矩形，断点可能判错。
    final WindowMetrics metrics = WindowMetrics.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (BuildContext context, Widget? child) =>
              _buildPage(context, metrics),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context, WindowMetrics metrics) {
    final CountdownController controller = widget.controller;
    final RunSnapshot? activeRun = controller.activeRun;
    if (activeRun != null) {
      // 每次结构刷新都对齐缓存，确保归零后显示的是本轮名称而不是更早的一轮；
      // 重新计时会换成新的运行 ID，这里同样以控制器的最新快照为准。
      _lastRun = activeRun;
    }
    final RunSnapshot? run = activeRun ?? _lastRun;
    if (run == null) {
      // 没有可显示的本轮运行。绝不从项目列表挑一条顶替；首次读取尚未结束时
      // 等控制器通知再判断，仍为空则返回列表。
      _scheduleExitIfNothingToShow();
      return const SizedBox.shrink();
    }

    final TextScaler textScaler = MediaQuery.textScalerOf(context);
    // 提示条按秒显示实时剩余；控制器已负责「仍有正剩余」「已投递且未收起」等条件。
    final bool showBanner = controller.bannerVisible && run.reminderEnabled;
    final double bannerHeight = showBanner
        ? ReminderBanner.heightFor(metrics, textScaler)
        : 0;
    final double reservedTop = _reservedTop(
      metrics,
      showBanner: showBanner,
      bannerHeight: bannerHeight,
    );
    // 只有控制器仍维护本轮时才提供控制区；归零或取消后本轮已结束，隐藏命令入口。
    final bool live = activeRun != null;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double contentWidth = math.max(
          0.0,
          constraints.maxWidth - metrics.runningHorizontalPadding * 2,
        );
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomMultiChildLayout(
                delegate: _RunningLayoutDelegate(
                  contentWidth: contentWidth,
                  reservedTop: reservedTop,
                  controlGap: _controlsGap(metrics),
                  controlGapMin: _controlsGapMin,
                  hasControls: live,
                ),
                children: <Widget>[
                  LayoutId(
                    id: _RunningSlot.group,
                    child: _buildGroup(
                      run: run,
                      live: live,
                      metrics: metrics,
                      contentWidth: contentWidth,
                    ),
                  ),
                  if (live)
                    LayoutId(
                      id: _RunningSlot.controls,
                      child: _buildControls(metrics),
                    ),
                ],
              ),
            ),
            _buildBackButton(metrics),
            if (showBanner)
              _buildBanner(
                metrics: metrics,
                run: run,
                contentWidth: contentWidth,
              ),
          ],
        );
      },
    );
  }

  /// 居中双行组：宽度固定为安全区减去左右内距，高度不足时整组等比缩小。
  ///
  /// [live] 表示本轮仍由控制器维护；一旦控制器结束本轮（activeRun 变 null），
  /// 缓存快照的剩余可能仍为正，此时固定显示 00:00:00，避免已结束的运行继续倒数。
  /// 暂停时 [ClockReading.remainingMillisOf] 返回冻结值，颜色也按冻结值判断，
  /// 进入过提醒阈值的一轮即使暂停也仍然是红字。
  Widget _buildGroup({
    required RunSnapshot run,
    required bool live,
    required WindowMetrics metrics,
    required double contentWidth,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: contentWidth),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: contentWidth,
          child: ValueListenableBuilder<ClockReading>(
            valueListenable: widget.controller.clockListenable,
            builder: (BuildContext context, ClockReading clock, Widget? child) {
              final int remainingMillis = live
                  ? clock.remainingMillisOf(run)
                  : 0;
              final bool inReminderWindow =
                  live &&
                  isWithinReminderWindow(
                    remainingMillis: remainingMillis,
                    thresholdMillis: run.reminderThresholdMillis,
                  );
              return TimerDisplay(
                metrics: metrics,
                name: run.projectName,
                timeText: formatRemaining(remainingMillis),
                timeColor: inReminderWindow
                    ? AppColors.danger
                    : AppColors.accent,
              );
            },
          ),
        ),
      ),
    );
  }

  /// 数字正下方的本轮控制区；复用首页活动卡同一套 [RunControls]。
  ///
  /// 外层 [FittedBox] 只在极短窗口里把整行控件等比缩小，正常窗口不改变任何尺寸；
  /// 按钮的文字语义、触摸高度和顺序都由 [RunControls] 保证。
  Widget _buildControls(WindowMetrics metrics) {
    final CountdownController controller = widget.controller;
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: RunControls(
        metrics: metrics,
        paused: controller.isPaused,
        busy: controller.busy,
        onTogglePause: _togglePause,
        onRestart: _restartRun,
        onCancel: _cancelRun,
      ),
    );
  }

  /// 左上「← 列表」：触摸区高 48，返回后计时继续。
  Widget _buildBackButton(WindowMetrics metrics) {
    return Positioned(
      top: metrics.runningNavPadding,
      left: metrics.runningNavPadding,
      child: Semantics(
        button: true,
        label: '返回列表',
        onTap: _popToList,
        // 排除文字与图标的默认语义，避免读屏读成“返回列表 列表”。
        excludeSemantics: true,
        child: TextButton.icon(
          onPressed: _popToList,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll<Size>(
              Size(0, AppSpacing.touchTarget),
            ),
            padding: const WidgetStatePropertyAll<EdgeInsets>(
              EdgeInsets.symmetric(horizontal: 8),
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(
              AppColors.primaryText,
            ),
            overlayColor: const WidgetStatePropertyAll<Color>(
              AppColors.surfacePressed,
            ),
            // 返回入口的按压/焦点外壳与全应用一致，用贝塞尔圆角矩形。
            shape: WidgetStatePropertyAll<OutlinedBorder>(
              BezierRoundedRectangleBorder(radius: AppRadii.field),
            ),
            textStyle: WidgetStatePropertyAll<TextStyle>(
              textStyleOf(metrics, TextLevel.a, color: AppColors.primaryText),
            ),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          icon: const Icon(Icons.arrow_back, size: 20),
          label: const Text('列表'),
        ),
      ),
    );
  }

  /// 提示条按四向定位；宽随内容收缩，作为浮层不改变中心组位置。
  ///
  /// 文案是秒级实时剩余，因此只有提示条自身监听时钟每秒重建；页面结构与中心组
  /// 仍由外层的 [ListenableBuilder] 按控制器状态驱动，不做整页每秒重建。
  /// 暂停时 [ClockReading.remainingMillisOf] 返回冻结值，提示条显示冻结剩余。
  Widget _buildBanner({
    required WindowMetrics metrics,
    required RunSnapshot run,
    required double contentWidth,
  }) {
    final Widget banner = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: math.min(contentWidth, metrics.bannerMaxWidth),
      ),
      child: ValueListenableBuilder<ClockReading>(
        valueListenable: widget.controller.clockListenable,
        builder: (BuildContext context, ClockReading clock, Widget? child) {
          return ReminderBanner(
            metrics: metrics,
            remainingMillis: clock.remainingMillisOf(run),
            onDismiss: widget.controller.dismissBanner,
          );
        },
      ),
    );
    final double navBottom =
        metrics.runningNavPadding + metrics.runningNavHeight;
    return switch (metrics.sizeClass) {
      WindowSizeClass.phonePortrait => Positioned(
        top: navBottom + metrics.bannerTopGap,
        left: metrics.runningHorizontalPadding,
        child: banner,
      ),
      WindowSizeClass.phoneLandscape => Positioned(
        top: metrics.runningNavPadding,
        right: metrics.bannerTrailingInset,
        child: banner,
      ),
      WindowSizeClass.tabletPortrait => Positioned(
        top: navBottom + metrics.bannerTopGap,
        left: 0,
        right: 0,
        child: Center(child: banner),
      ),
      WindowSizeClass.tabletLandscape => Positioned(
        top: metrics.runningNavPadding,
        right: metrics.bannerTrailingInset,
        child: banner,
      ),
    };
  }

  /// 为中心组预留的顶部高度：导航行 +（提示条高度 + 与导航行的间距）。
  double _reservedTop(
    WindowMetrics metrics, {
    required bool showBanner,
    required double bannerHeight,
  }) {
    final double navBottom =
        metrics.runningNavPadding + metrics.runningNavHeight;
    if (!showBanner) {
      return navBottom;
    }
    if (metrics.sizeClass.isLandscape) {
      // 横屏提示条与返回共处一行，只有高于导航行时才额外侵占垂直空间。
      return metrics.runningNavPadding +
          math.max(metrics.runningNavHeight, bannerHeight);
    }
    return navBottom + metrics.bannerTopGap + bannerHeight;
  }

  /// 暂停／继续：按当前暂停状态选择命令，成功后停留在本页。
  Future<void> _togglePause() async {
    final CountdownController controller = widget.controller;
    final CommandStatus status = controller.isPaused
        ? await controller.resumeRun()
        : await controller.pauseRun();
    if (!mounted) {
      return;
    }
    _reportFailure(status);
  }

  /// 重新计时：立刻以本轮最初的总时长开始新一轮（新运行 ID），停留本页。
  Future<void> _restartRun() async {
    final CommandStatus status = await widget.controller.restartRun();
    if (!mounted) {
      return;
    }
    _reportFailure(status);
  }

  /// 取消本轮：成功后返回首页；失败留在本页并用提示条说明原因。
  Future<void> _cancelRun() async {
    final CommandStatus status = await widget.controller.cancelRun();
    if (!mounted) {
      return;
    }
    if (status == CommandStatus.success) {
      _popToList();
      return;
    }
    _reportFailure(status);
  }

  /// 命令失败时显示控制器给出的原因；页面状态继续以刷新后的控制器为准。
  void _reportFailure(CommandStatus status) {
    if (status == CommandStatus.success) {
      return;
    }
    final String message = widget.controller.lastFailureMessage ?? '操作失败，请重试。';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _popToList() {
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  void _scheduleExitIfNothingToShow() {
    if (_exitScheduled) {
      return;
    }
    _exitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _exitScheduled = false;
      if (!mounted) {
        return;
      }
      if (widget.controller.activeRun != null) {
        return;
      }
      if (widget.controller.loading) {
        // 首次读取未完成时 activeRun 必然为空；等控制器通知后再判断，
        // 避免把“数据未到”当成“没有运行”。
        return;
      }
      final NavigatorState navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      }
    });
  }
}

/// 控制区与数字之间的间距（规格未定义，取 8–16 dp 的小间距）。
double _controlsGap(WindowMetrics metrics) {
  return switch (metrics.sizeClass) {
    WindowSizeClass.phonePortrait => 16,
    WindowSizeClass.phoneLandscape => 8,
    WindowSizeClass.tabletPortrait => 16,
    WindowSizeClass.tabletLandscape => 12,
  };
}

/// 垂直空间不足时先把控制区间距压到这个值，再压缩中心组。
const double _controlsGapMin = 4;

/// 运行页主体的两个布局槽位。
enum _RunningSlot { group, controls }

/// 运行页主体布局：中心组固定对准安全区中心，控制区贴在中心组下方。
///
/// 两行中心组的几何中心必须与安全区中心重合（偏差 ≤2 dp），所以不能用会改变
/// 中心组位置的 Column/Padding 排版。这里先量出控制区高度（它只取决于可用宽度
/// 与字级，与中心组无关），再决定中心组可用高度并单独定位两个槽位：
///
/// 1. 正常窗口：中心组按原有上下对称预留放在安全区中心，控制区在组下方；
/// 2. 放不下时先压缩控制区间距，仍放不下则把“中心组 + 间距 + 控制区”整块放进
///    顶部返回/提示条以下的空间，垂直居中，中心组可略离中心但控件不被裁掉；
/// 3. 极短窗口里控制区也会被 [FittedBox] 等比缩小，但始终完整保留三个动作。
class _RunningLayoutDelegate extends MultiChildLayoutDelegate {
  _RunningLayoutDelegate({
    required this.contentWidth,
    required this.reservedTop,
    required this.controlGap,
    required this.controlGapMin,
    required this.hasControls,
  });

  /// 安全区减去左右内距后的内容宽度。
  final double contentWidth;

  /// 顶部返回行（及提示条浮层）占用的高度；中心组上下对称预留它以保持中心。
  final double reservedTop;

  /// 控制区与中心组之间的正常间距。
  final double controlGap;

  /// 空间不足时压缩到的控制区间距。
  final double controlGapMin;

  /// 当前是否显示控制区（本轮仍由控制器维护）。
  final bool hasControls;

  /// 压缩控制区时仍要给名称与数字保留的最小高度。
  static const double _minGroupHeight = AppSpacing.touchTarget;

  @override
  void performLayout(Size size) {
    // 控制区高度只取决于内容宽度（是否换行）与字级，先量它，避免二次布局。
    double controlsWidth = 0;
    double controlsHeight = 0;
    if (hasControls && hasChild(_RunningSlot.controls)) {
      final double controlsMaxHeight = math.max(
        0.0,
        size.height - reservedTop - controlGapMin - _minGroupHeight,
      );
      final Size controlsSize = layoutChild(
        _RunningSlot.controls,
        BoxConstraints(maxWidth: contentWidth, maxHeight: controlsMaxHeight),
      );
      controlsWidth = controlsSize.width;
      controlsHeight = controlsSize.height;
    }

    // 中心组基线约束：上下对称预留顶部浮层高度，组几何中心才对准安全区中心。
    final double centeredMaxHeight = math.max(
      0.0,
      size.height - reservedTop * 2,
    );
    // 控制区也要占位：给“中心组 + 间距 + 控制区”整块留出顶部预留以下的高度，
    // 这样极短窗口只压缩中心组高度，不会把控件裁到屏幕外。
    final double blockMaxHeight = math.max(
      0.0,
      size.height - reservedTop - controlGapMin - controlsHeight,
    );
    final Size groupSize = layoutChild(
      _RunningSlot.group,
      BoxConstraints(
        maxWidth: contentWidth,
        maxHeight: math.min(centeredMaxHeight, blockMaxHeight),
      ),
    );

    final double groupLeft = (size.width - groupSize.width) / 2;
    final double centeredTop = math.max(
      0.0,
      (size.height - groupSize.height) / 2,
    );
    if (!hasControls || !hasChild(_RunningSlot.controls)) {
      positionChild(_RunningSlot.group, Offset(groupLeft, centeredTop));
      return;
    }

    final double controlsLeft = (size.width - controlsWidth) / 2;
    // 先用正常间距，放不下时先压缩间距，仍放不下再整体上移成紧凑块。
    double gap = controlGap;
    double bottom = centeredTop + groupSize.height + gap + controlsHeight;
    if (bottom > size.height) {
      gap = controlGapMin;
      bottom = centeredTop + groupSize.height + gap + controlsHeight;
    }
    if (bottom <= size.height) {
      positionChild(_RunningSlot.group, Offset(groupLeft, centeredTop));
      positionChild(
        _RunningSlot.controls,
        Offset(controlsLeft, centeredTop + groupSize.height + gap),
      );
      return;
    }

    final double available = math.max(0.0, size.height - reservedTop);
    final double blockHeight = groupSize.height + gap + controlsHeight;
    final double blockTop =
        reservedTop + math.max(0.0, (available - blockHeight) / 2);
    positionChild(_RunningSlot.group, Offset(groupLeft, blockTop));
    positionChild(
      _RunningSlot.controls,
      Offset(controlsLeft, blockTop + groupSize.height + gap),
    );
  }

  @override
  bool shouldRelayout(_RunningLayoutDelegate oldDelegate) {
    return contentWidth != oldDelegate.contentWidth ||
        reservedTop != oldDelegate.reservedTop ||
        controlGap != oldDelegate.controlGap ||
        controlGapMin != oldDelegate.controlGapMin ||
        hasControls != oldDelegate.hasControls;
  }
}
