/// 01 倒计时列表页：首页滚轮快启、当前轮就地控制与常用计时器列表。
///
/// 主区按控制器状态二选一：没有可见运行时显示「时 / 分 / 秒」三列滚轮与
/// 「开始」；有运行时在同一位置切换为活动卡，卡内复用 [RunControls] 完成
/// 暂停/继续、重新计时与取消，卡片空白处或右侧箭头进入运行页。滚轮选值保存在
/// 本页 [State]，因此快启、取消、归零与横竖屏切换都不会重置选值；运行状态与
/// 每秒时钟仍由 [CountdownController] 提供，页面不另存一份运行数据。
///
/// 整页只订阅 [CountdownController]；每秒推进的时钟只由活动卡时间文字监听，
/// 避免整页每秒重建。四向差异只体现在是否分栏、内容限宽与滚轮可见行数，断点、
/// 间距和字号统一取自 [WindowMetrics]，不在这里重复定义数值。
///
/// 所有应用内自绘的圆角外壳（活动卡、菜单弹层与菜单项、图标按钮状态底）都通过
/// `bezier_rounded_rect.dart` 的贝塞尔路径表达，页面不再使用 Material 默认圆角。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/bezier_rounded_rect.dart';
import '../app/routes.dart';
import '../app/theme.dart';
import '../app/window_layout.dart';
import 'controller.dart';
import 'create_page.dart';
import 'delete_dialog.dart';
import 'model.dart';
import 'run_controls.dart';
import 'running_page.dart';
import 'time_format.dart';
import 'wheel_picker.dart';

/// 横屏分栏所需的最小可用宽度。
///
/// 窄于此宽度时名称、时间和开始按钮挤在一行，两栏都放不下，回退单列；
/// 断点本身仍由 [WindowMetrics] 判定，这里只处理分栏是否可行。
const double _minColumnLayoutWidth = 600;

/// 左栏最小宽度：主区要放下三列滚轮与 48 宽的操作入口。
const double _minLeftColumnWidth = 240;

/// 标题与页面主体之间的固定间距（HANDOFF §4.1）。
const double _titleGap = 16;

/// 可用高度低于该值时按短屏处理：滚轮只显示三行并压缩垂直间距。
const double _shortScreenHeight = 520;

/// 竖屏上下分区时为列表预留的最小高度：至少保留常用计时器表头。
const double _minListReserveHeight = 48;

/// 滚轮与「开始」之间的间距；短屏压缩到 8，保证按钮在可视区内。
const double _wheelActionGap = 16;
const double _compactWheelActionGap = 8;

/// 「开始」按钮宽度：不铺满整行，窄栏与平板上都保持适中比例。
const double _startButtonWidth = 160;

/// 操作失败且控制器没有给出原因时的兜底文案。
const String _failureFallback = '操作失败，请重试。';

/// 首页。
class ListPage extends StatefulWidget {
  const ListPage({super.key, required this.controller});

  /// 页面状态与命令的唯一来源，由入口装配注入。
  final CountdownController controller;

  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  /// 快启滚轮最近一次选值。
  ///
  /// 只在用户滚动滚轮时改写：快启成功后隐藏滚轮、取消或归零回到空闲态、
  /// 甚至切换横竖屏，都从这里恢复，不重置为零。
  int _hours = 0;
  int _minutes = 0;
  int _seconds = 0;

  CountdownController get _controller => widget.controller;

  /// 当前滚轮选值的总秒数；全零时「开始」禁用。
  int get _selectedTotalSeconds => _hours * 3600 + _minutes * 60 + _seconds;

  /// 快启可用性：选值大于零且没有命令在途。
  bool get _canStartTemporaryRun =>
      _selectedTotalSeconds > 0 && !_controller.busy;

  @override
  Widget build(BuildContext context) {
    // 在 SafeArea 之外读取度量：SafeArea 会把系统安全边从 MediaQuery 中扣除，
    // 在其内部再算 [WindowMetrics] 会把整窗尺寸当成安全矩形，断点可能判错。
    final WindowMetrics metrics = WindowMetrics.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.pageHorizontalPadding,
            metrics.pageTopSpacing,
            metrics.pageHorizontalPadding,
            0,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: metrics.listMaxContentWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '倒计时',
                    style: textStyleOf(
                      metrics,
                      TextLevel.h,
                      color: AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(height: _titleGap),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: _controller,
                      builder: (BuildContext context, Widget? child) =>
                          _buildBody(context, metrics),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WindowMetrics metrics) {
    if (_controller.loadError != null) {
      return _LoadFailure(metrics: metrics, onRetry: () => _controller.load());
    }
    if (_controller.loading &&
        _controller.projects.isEmpty &&
        _controller.activeRun == null) {
      return const _PageLoading();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int wheelRows = _wheelRowsFor(metrics, constraints.maxHeight);
        final Widget mainArea = _buildMainArea(metrics, wheelRows: wheelRows);
        final Widget listSection = _buildListSection(context, metrics);
        if (_usesColumns(metrics, constraints.maxWidth)) {
          // 手机横屏与平板横屏：主区在左（约 38%）、列表在右，两栏各自可滚。
          final double leftWidth =
              (constraints.maxWidth - metrics.columnGap) *
              metrics.leftColumnFraction;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: leftWidth,
                child: SingleChildScrollView(
                  // 主区自身纵向滚动只作为矮窗兜底；不抢占页面的主滚动控制器。
                  primary: false,
                  child: mainArea,
                ),
              ),
              SizedBox(width: metrics.columnGap),
              Expanded(child: listSection),
            ],
          );
        }
        // 竖屏：主区在上、列表在下。主区最多占用扣除列表表头后的剩余高度，
        // 极端矮窗中主区内部滚动，滚轮、开始与控制按钮都不会被裁掉。
        final double listReserve = math.min(
          _minListReserveHeight,
          constraints.maxHeight * 0.3,
        );
        final double mainMaxHeight = math.max(
          0.0,
          constraints.maxHeight - metrics.sectionGap - listReserve,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: mainMaxHeight),
              child: SingleChildScrollView(primary: false, child: mainArea),
            ),
            SizedBox(height: metrics.sectionGap),
            Expanded(child: listSection),
          ],
        );
      },
    );
  }

  /// 滚轮可见行数：短屏与手机横屏用三行并压缩间距，其余用五行。
  int _wheelRowsFor(WindowMetrics metrics, double availableHeight) {
    final bool shortScreen =
        metrics.sizeClass == WindowSizeClass.phoneLandscape ||
        availableHeight < _shortScreenHeight;
    return shortScreen ? 3 : 5;
  }

  /// 主区内容：无可见运行时是滚轮快启，有运行时是活动卡（互斥）。
  Widget _buildMainArea(WindowMetrics metrics, {required int wheelRows}) {
    final RunSnapshot? run = _controller.activeRun;
    if (run == null || !_controller.hasActiveRun) {
      return _buildIdleMain(metrics, wheelRows: wheelRows);
    }
    final bool compact = wheelRows < 5;
    return _ActiveCard(
      controller: _controller,
      metrics: metrics,
      run: run,
      compact: compact,
      onOpen: _openRunningPage,
      onTogglePause: _handleTogglePause,
      onRestart: _handleRestart,
      onCancel: _handleCancel,
      // 旧基线的「⋮ → 删除确认」仍是回归要求：运行中的项目不在常用列表里，
      // 只有活动卡能发起删除，因此保留这个入口。
      onDelete: _deleteActiveProject,
    );
  }

  /// 空闲态：三列滚轮 + 蓝色实心「开始」。
  Widget _buildIdleMain(WindowMetrics metrics, {required int wheelRows}) {
    final bool compact = wheelRows < 5;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DurationWheelSet(
          // 四向切换会改变滚轮行高。重建滚轮控制器并按页面 State 的选值重新
          // 定位，避免沿用旧像素偏移后选中行错位；选值本身来自 [_hours] 等，
          // 不会因重建丢失。
          key: ValueKey<String>(
            'duration-wheel-${metrics.sizeClass.name}-$wheelRows',
          ),
          hours: _hours,
          minutes: _minutes,
          seconds: _seconds,
          onChanged: _handleDurationChanged,
          metrics: metrics,
          visibleRows: wheelRows,
        ),
        SizedBox(height: compact ? _compactWheelActionGap : _wheelActionGap),
        Center(
          child: SizedBox(
            width: _startButtonWidth,
            child: FilledButton(
              style: solidButtonStyle(metrics),
              onPressed: _canStartTemporaryRun
                  ? _handleStartTemporaryRun
                  : null,
              child: const Text('开始'),
            ),
          ),
        ),
      ],
    );
  }

  void _handleDurationChanged(int hours, int minutes, int seconds) {
    if (hours == _hours && minutes == _minutes && seconds == _seconds) {
      return;
    }
    setState(() {
      _hours = hours;
      _minutes = minutes;
      _seconds = seconds;
    });
  }

  /// 快启：用当前选值启动临时运行，成功后由控制器刷新把主区切到活动卡。
  Future<void> _handleStartTemporaryRun() async {
    if (!_canStartTemporaryRun) {
      return;
    }
    final CommandStatus status = await _controller.startTemporaryRun(
      _selectedTotalSeconds,
    );
    if (!mounted) {
      return;
    }
    if (status == CommandStatus.success) {
      return;
    }
    _showSnackBar(_controller.lastFailureMessage ?? _failureFallback);
  }

  Future<void> _handleTogglePause() async {
    final CommandStatus status = _controller.isPaused
        ? await _controller.resumeRun()
        : await _controller.pauseRun();
    if (!mounted) {
      return;
    }
    if (status != CommandStatus.success) {
      _showSnackBar(_controller.lastFailureMessage ?? _failureFallback);
    }
  }

  Future<void> _handleRestart() async {
    final CommandStatus status = await _controller.restartRun();
    if (!mounted) {
      return;
    }
    if (status != CommandStatus.success) {
      _showSnackBar(_controller.lastFailureMessage ?? _failureFallback);
    }
  }

  /// 取消成功后控制器刷新会让主区回到滚轮快启；选值保留在页面 State。
  Future<void> _handleCancel() async {
    final CommandStatus status = await _controller.cancelRun();
    if (!mounted) {
      return;
    }
    if (status != CommandStatus.success) {
      _showSnackBar(_controller.lastFailureMessage ?? _failureFallback);
    }
  }

  Future<void> _deleteActiveProject() async {
    final RunSnapshot? run = _controller.activeRun;
    if (run == null) {
      return;
    }
    await showDeleteProjectDialog(
      context,
      controller: _controller,
      project: _projectOfRun(run),
    );
  }

  /// 补齐活动卡删除所需的目标项目。
  ///
  /// 运行快照刻意不包含创建时间等完整项目字段，而删除确认弹窗的签名要求完整
  /// 项目对象。弹窗只读取 [CountdownProject.id] 与 [CountdownProject.name]；
  /// 时长与本轮提醒阈值取自运行快照的真实值，创建时间无法从运行快照取得，用 0
  /// 填充且不在任何界面展示，也不会写回持久层。
  ///
  /// 单位换算：运行快照的 [RunSnapshot.reminderThresholdMillis] 是毫秒，而
  /// [CountdownProject.reminderSeconds] 以秒存储，因此这里向下取整除以 1000；
  /// 本轮阈值本身按整秒生成，不会丢失精度。
  CountdownProject _projectOfRun(RunSnapshot run) {
    final int? thresholdMillis = run.reminderThresholdMillis;
    return CountdownProject(
      id: run.projectId,
      name: run.projectName,
      totalSeconds: run.totalSeconds,
      reminderSeconds: thresholdMillis == null ? null : thresholdMillis ~/ 1000,
      createdAtUtcMillis: 0,
      state: ProjectState.idle,
    );
  }

  Widget _buildListSection(BuildContext context, WindowMetrics metrics) {
    final List<CountdownProject> projects = _controller.projects;
    final bool runExists = _controller.hasActiveRun;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionHeader(metrics: metrics, onAdd: _openCreatePage),
        Expanded(
          child: projects.isEmpty
              ? const SizedBox.shrink()
              : ListView.separated(
                  padding: EdgeInsets.only(bottom: metrics.sectionGap),
                  itemCount: projects.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: AppSpacing.dividerWidth),
                  itemBuilder: (BuildContext context, int index) {
                    final CountdownProject project = projects[index];
                    return _ProjectRow(
                      metrics: metrics,
                      project: project,
                      startEnabled: !runExists && !_controller.busy,
                      showStartDisabledHint: runExists,
                      onStart: () => _startProject(project),
                      onDelete: () => showDeleteProjectDialog(
                        context,
                        controller: _controller,
                        project: project,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  bool _usesColumns(WindowMetrics metrics, double availableWidth) {
    if (!metrics.usesColumns || availableWidth < _minColumnLayoutWidth) {
      return false;
    }
    final double leftWidth =
        (availableWidth - metrics.columnGap) * metrics.leftColumnFraction;
    return leftWidth >= _minLeftColumnWidth;
  }

  /// 常用项的「开始」仍走完整项目启动；成功后进入运行页。
  Future<void> _startProject(CountdownProject project) async {
    final CommandStatus status = await _controller.startRun(project.id);
    if (!mounted) {
      return;
    }
    if (status == CommandStatus.success) {
      _openRunningPage();
      return;
    }
    _showSnackBar(_controller.lastFailureMessage ?? _failureFallback);
  }

  void _openRunningPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AppRoutes.running),
        builder: (BuildContext context) => RunningPage(controller: _controller),
      ),
    );
  }

  void _openCreatePage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AppRoutes.create),
        builder: (BuildContext context) => CreatePage(controller: _controller),
      ),
    );
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    final WindowMetrics metrics = WindowMetrics.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: AppColors.primaryText,
          content: Text(
            message,
            style: textStyleOf(metrics, TextLevel.a, color: AppColors.canvas),
          ),
        ),
      );
  }
}

/// 活动卡：状态、名称、剩余时间、就地控制、进入运行页入口与删除菜单。
class _ActiveCard extends StatelessWidget {
  const _ActiveCard({
    required this.controller,
    required this.metrics,
    required this.run,
    required this.compact,
    required this.onOpen,
    required this.onTogglePause,
    required this.onRestart,
    required this.onCancel,
    required this.onDelete,
  });

  final CountdownController controller;
  final WindowMetrics metrics;
  final RunSnapshot run;

  /// 短屏压缩卡内垂直间距，优先保证三个控制按钮可见。
  final bool compact;
  final VoidCallback onOpen;
  final VoidCallback onTogglePause;
  final VoidCallback onRestart;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool paused = run.paused;
    return Material(
      color: AppColors.accentSurface,
      shape: const BezierRoundedRectangleBorder(radius: AppRadii.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        // 卡片水波纹与卡片轮廓使用同一条贝塞尔路径；Material 的 shape 负责
        // 裁剪可见外形，customBorder 负责按压/悬停水波纹的边界。
        customBorder: bezierButtonShape(radius: AppRadii.card),
        overlayColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.pressed)) {
            return AppColors.cardPressed;
          }
          return null;
        }),
        // 卡片空白区域可进运行页；控制按钮、⋮ 与箭头都是更深的命中区域，手势
        // 由它们优先裁决，点这些按钮不会同时触发进页。
        child: Stack(
          children: <Widget>[
            Padding(
              padding: EdgeInsets.all(metrics.cardPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(
                      right: AppSpacing.touchTarget,
                    ),
                    child: Text(
                      paused ? '已暂停' : '正在计时',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyleOf(
                        metrics,
                        TextLevel.a,
                        color: AppColors.secondaryText,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(
                      right: AppSpacing.touchTarget,
                    ),
                    child: Text(
                      run.projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyleOf(
                        metrics,
                        TextLevel.k,
                        color: AppColors.primaryText,
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 4 : 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: ValueListenableBuilder<ClockReading>(
                          valueListenable: controller.clockListenable,
                          builder:
                              (
                                BuildContext context,
                                ClockReading clock,
                                Widget? child,
                              ) {
                                final int remaining = clock.remainingMillisOf(
                                  run,
                                );
                                final bool withinReminder =
                                    isWithinReminderWindow(
                                      remainingMillis: remaining,
                                      thresholdMillis:
                                          run.reminderThresholdMillis,
                                    );
                                // 只有这个子树订阅每秒时钟，读屏朗读不会被整卡
                                // 重建打断；窄栏或大字号时按比例缩小，保证八字符
                                // 完整显示。
                                return FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    formatRemaining(remaining),
                                    style: textStyleOf(
                                      metrics,
                                      TextLevel.f,
                                      color: withinReminder
                                          ? AppColors.danger
                                          : AppColors.accent,
                                    ),
                                  ),
                                );
                              },
                        ),
                      ),
                      _CardEntryButton(onOpen: onOpen),
                    ],
                  ),
                  SizedBox(height: compact ? 4 : 8),
                  RunControls(
                    metrics: metrics,
                    paused: paused,
                    busy: controller.busy,
                    onTogglePause: onTogglePause,
                    onRestart: onRestart,
                    onCancel: onCancel,
                    alignment: WrapAlignment.start,
                  ),
                ],
              ),
            ),
            // 与旧基线一致：运行中的项目不在常用列表里，卡右上角保留删除入口。
            Positioned(
              top: 0,
              right: 0,
              child: _MoreMenuButton(
                metrics: metrics,
                tooltip: '更多操作',
                onDelete: onDelete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 活动卡右侧的独立进入入口：语义「进入计时」，触摸区 48。
class _CardEntryButton extends StatelessWidget {
  const _CardEntryButton({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '进入计时',
      onTap: onOpen,
      // 排除图标与提示的默认语义，读屏只读一次「进入计时」。
      excludeSemantics: true,
      child: IconButton(
        tooltip: '进入计时',
        onPressed: onOpen,
        iconSize: 20,
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppSpacing.touchTarget),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.padded,
          foregroundColor: AppColors.primaryText,
          // 图标按钮默认是圆形水波纹；统一为贝塞尔圆角矩形，与全应用一致。
          shape: bezierButtonShape(),
        ),
        icon: const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// 常用计时器分区表头：分区名与新增入口。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.metrics, required this.onAdd});

  final WindowMetrics metrics;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    // 行高只设下限：系统放大文字时表头随之增高，不裁掉分区名或新增按钮。
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.sectionHeaderMinHeight),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '常用计时器',
              style: textStyleOf(
                metrics,
                TextLevel.k,
                color: AppColors.primaryText,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: solidButtonStyle(metrics),
            onPressed: onAdd,
            child: const Text('＋ 新增'),
          ),
        ],
      ),
    );
  }
}

/// 常用计时器条目。
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.metrics,
    required this.project,
    required this.startEnabled,
    required this.showStartDisabledHint,
    required this.onStart,
    required this.onDelete,
  });

  final WindowMetrics metrics;
  final CountdownProject project;
  final bool startEnabled;

  /// 有运行中的项目时，「开始」禁用并说明原因；仅忙碌禁用时不解释。
  final bool showStartDisabledHint;
  final VoidCallback onStart;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool finished = project.state == ProjectState.finished;
    final String timeText = finished
        ? '00:00:00'
        : formatDuration(project.totalSeconds);
    final Widget startButton = OutlinedButton(
      style: outlinedButtonStyle(metrics),
      onPressed: startEnabled ? onStart : null,
      child: const Text('开始'),
    );
    // 整行本身没有点击手势：条目只有「开始」和「⋮」两个操作入口，避免点名称
    // 误启动计时。
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.listRowMinHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: metrics.listRowVerticalPadding),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    project.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textStyleOf(
                      metrics,
                      TextLevel.k,
                      color: AppColors.primaryText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            timeText,
                            style: textStyleOf(
                              metrics,
                              TextLevel.v,
                              color: AppColors.secondaryText,
                            ),
                          ),
                        ),
                      ),
                      if (finished) ...<Widget>[
                        const SizedBox(width: 8),
                        Text(
                          '已结束',
                          style: textStyleOf(
                            metrics,
                            TextLevel.a,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (showStartDisabledHint)
              Tooltip(message: '已有一项正在计时', child: startButton)
            else
              startButton,
            _MoreMenuButton(
              metrics: metrics,
              tooltip: '更多操作：${project.name}',
              onDelete: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「⋮」按钮及其唯一菜单项「删除」。
class _MoreMenuButton extends StatelessWidget {
  const _MoreMenuButton({
    required this.metrics,
    required this.tooltip,
    required this.onDelete,
  });

  final WindowMetrics metrics;
  final String tooltip;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      // 菜单收起时的外部点击只关闭菜单，不能穿透到下层条目。
      consumeOutsideTap: true,
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(AppColors.canvas),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double>(3),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: 8),
        ),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          // 菜单弹层轮廓与全局主题同一几何，半径为菜单专用的 8 dp。
          BezierRoundedRectangleBorder(
            radius: AppRadii.menu,
            side: BorderSide(color: AppColors.divider),
          ),
        ),
      ),
      menuChildren: <Widget>[
        MenuItemButton(
          onPressed: onDelete,
          style: ButtonStyle(
            alignment: AlignmentDirectional.centerStart,
            // 菜单项的水波纹、悬停与焦点边界也用同一贝塞尔轮廓。
            shape: WidgetStatePropertyAll<OutlinedBorder>(bezierButtonShape()),
            minimumSize: const WidgetStatePropertyAll<Size>(
              Size(96, AppSpacing.touchTarget),
            ),
            padding: const WidgetStatePropertyAll<EdgeInsets>(
              EdgeInsets.symmetric(horizontal: 20),
            ),
            foregroundColor: const WidgetStatePropertyAll<Color>(
              AppColors.danger,
            ),
            overlayColor: const WidgetStatePropertyAll<Color?>(
              AppColors.dangerPressed,
            ),
            textStyle: WidgetStatePropertyAll<TextStyle>(
              textStyleOf(metrics, TextLevel.a, color: AppColors.danger),
            ),
          ),
          child: const Text('删除'),
        ),
      ],
      builder:
          (BuildContext context, MenuController menuController, Widget? child) {
            return IconButton(
              tooltip: tooltip,
              onPressed: () {
                if (menuController.isOpen) {
                  menuController.close();
                } else {
                  menuController.open();
                }
              },
              iconSize: 20,
              style: IconButton.styleFrom(
                minimumSize: const Size.square(AppSpacing.touchTarget),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.padded,
                foregroundColor: AppColors.primaryText,
                // 更多按钮的按压/悬停底同样按贝塞尔轮廓绘制，不用默认圆形。
                shape: bezierButtonShape(),
              ),
              icon: const Icon(Icons.more_vert),
            );
          },
    );
  }
}

/// 读取完成、尚无任何项目时的轻量加载态。
class _PageLoading extends StatelessWidget {
  const _PageLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          semanticsLabel: '正在读取',
        ),
      ),
    );
  }
}

/// 读取失败：只提供重试，不把失败当成空列表。
class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.metrics, required this.onRetry});

  final WindowMetrics metrics;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '读取失败',
            style: textStyleOf(
              metrics,
              TextLevel.a,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            style: outlinedButtonStyle(metrics),
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
