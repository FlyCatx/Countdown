/// 02 新增倒计时页：名称、时长滚轮、秒级提前提醒与固定底部保存。
///
/// 草稿只存在于本页 State（名称、两组时/分/秒、开关）：返回列表或保存成功前都
/// 不写业务数据，保存失败保留全部输入与选值。校验集中在
/// [_CreatePageState._canSave]（同时控制保存按钮可用性并在提交前复用），宿主
/// 仓储保存时按同一契约再校验一次。
///
/// 数据语义：
/// - D = 3600×时 + 60×分 + 秒，为左侧倒计时总秒数（时 00–99，分秒 00–59）；
/// - R = 提前提醒触发时的剩余秒数，合法范围精确为 1 ≤ R ≤ D−1，关闭时存 null。
///
/// 布局约定（本轮提示词 §2）：
/// - 竖屏（手机/平板）：名称 → 时长三列 → 提前提醒三列 → 底部保存；平板限宽
///   [WindowMetrics.formMaxWidth] 居中。
/// - 横屏（手机/平板）：名称独占首行；中部左时长、右提醒，两组标题行等高，
///   因此两组的选中行横向对齐；底部保存独占操作行。
/// - 窄分屏或大字体放不下六列时上下排。
/// - 保存固定在安全区底部。它放在 body 末尾而不是
///   [Scaffold.bottomNavigationBar]，因为 Scaffold 只把键盘高度让给 body，
///   bottomNavigationBar 会被键盘盖住；放在 body 末尾才能随键盘一起抬升。
/// - 滚动视口可用高度低于 [_compactHeightThreshold] 时滚轮显示 3 行并压缩组距。
///
/// 圆角：输入框、按钮、开关的外形都来自 theme / app_switch 的贝塞尔路径，本页
/// 不自行声明 BorderRadius 或其它圆角形状。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app_switch.dart';
import '../app/theme.dart';
import '../app/window_layout.dart';
import 'controller.dart';
import 'wheel_picker.dart';

// ---- 规格常量 ----

/// 首次开启提前提醒的默认剩余秒数：延续 3 分钟偏好，并按 D−1 收敛。
const int _defaultReminderSeconds = 180;

/// 标签、标题与滚轮、失败文案与按钮之间的细小间距。
const double _labelGap = 4;
const double _titleToWheelGap = 8;
const double _failureGap = 8;

/// 导航行到表单、滚动内容底部、表单与底部保存栏的留白。
const double _navToFormGap = 16;
const double _contentBottomGap = 16;
const double _saveBarTopGap = 8;
const double _saveBarBottomGap = 12;

/// 短屏 / 横屏压缩后的组距与滚动留白。
const double _compactGroupGap = 8;
const double _compactNavToFormGap = 8;
const double _compactContentBottomGap = 8;

/// 滚动视口高度低于该值时切换紧凑形态：滚轮 3 行、组距压缩。
const double _compactHeightThreshold = 520;

/// 判定「六列放不下、需要上下排」时每列滚轮的保守最小宽度系数：
/// 一列需要容纳两位数字、4 dp 间距与单位字，约 1.75 个字高。
const double _wheelColumnWidthFactor = 1.75;

/// 一组三列滚轮内部的列间距（与 [DurationWheelSet] / [ReminderWheelSet] 一致）。
const double _wheelColumnGap = 8;

const String _cannotEnableReminderText = '总时长不足 2 秒，无法开启提前提醒。';
const String _reminderClosedByShrinkText = '总时长不足，提前提醒已关闭。';
const String _saveFailedFallback = '保存失败，请重试。';

/// 左侧总时长变化后提醒选值的收敛结果。
enum _ReminderReconcile {
  /// 提醒已关闭或选值本来就合法。
  unchanged,

  /// 选值超出新上限，已钳到 D−1 并同步滚轮。
  clamped,

  /// 总时长已不足 2 秒，提醒被自动关闭，需要向用户说明。
  closed,
}

/// 新增倒计时页（02）。
class CreatePage extends StatefulWidget {
  const CreatePage({super.key, required this.controller});

  /// 保存命令与通知权限都经控制器完成，页面不直接访问仓储。
  final CountdownController controller;

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage> {
  final TextEditingController _nameController = TextEditingController();

  // 两组滚轮选值只存整数；旋转或父级重建时由这些值恢复选中行，草稿不丢。
  int _hours = 0;
  int _minutes = 0;
  int _seconds = 0;

  bool _reminderEnabled = false;
  int _reminderHours = 0;
  int _reminderMinutes = 0;
  int _reminderSeconds = 0;

  /// 本页正在提交保存；与 [CountdownController.busy] 配合防止连点。
  bool _submitting = false;

  /// 保存失败时展示的面向用户文案；输入变化时清除。
  String? _failureText;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ---- 取值与校验 ----

  /// 左侧倒计时总秒数 D。
  int get _totalSeconds => _hours * 3600 + _minutes * 60 + _seconds;

  /// 提前提醒剩余秒数 R。
  int get _reminderTotalSeconds =>
      _reminderHours * 3600 + _reminderMinutes * 60 + _reminderSeconds;

  bool get _nameValid => _nameController.text.trim().isNotEmpty;

  /// 开关是否可用：D ≥ 2 才有合法提醒值（R 至少为 1 秒，且严格小于 D）。
  bool get _canEnableReminder => _totalSeconds >= 2;

  /// 提前提醒合法范围 1 ≤ R ≤ D−1。
  bool get _reminderValid {
    if (!_reminderEnabled) {
      return true;
    }
    final int total = _totalSeconds;
    return total >= 2 &&
        _reminderTotalSeconds >= 1 &&
        _reminderTotalSeconds <= total - 1;
  }

  /// 保存可用性的唯一判定：名称去首尾空格后非空、总时长大于零、提醒关闭或
  /// 剩余秒数合法，且当前没有提交中的命令。
  ///
  /// 按钮可用性、提交前检查与失败提示共用这一组条件，避免界面允许点击而宿主
  /// 拒绝，或相反。
  bool get _canSave =>
      !_submitting &&
      !widget.controller.busy &&
      _nameValid &&
      _totalSeconds > 0 &&
      _reminderValid;

  // ---- 输入变化 ----

  void _handleNameChanged(String _) {
    widget.controller.clearFailureMessage();
    setState(() => _failureText = null);
  }

  /// 左侧时长滚轮变化：更新选值，并让提醒与新的 D 保持自洽。
  void _handleDurationChanged(int hours, int minutes, int seconds) {
    late final _ReminderReconcile outcome;
    setState(() {
      _hours = hours;
      _minutes = minutes;
      _seconds = seconds;
      _failureText = null;
      outcome = _reconcileReminderWithTotal();
    });
    widget.controller.clearFailureMessage();
    if (outcome == _ReminderReconcile.closed) {
      // 自动关闭是真实状态变化，给出可读说明，避免开关在用户不知情时变灰。
      _showSnackBar(_reminderClosedByShrinkText);
    }
  }

  /// D 变化后收敛提醒选值。
  ///
  /// 规则（本轮提示词 §2「动态约束」）：
  /// - D ≤ 1 时没有任何合法提醒值，自动关闭开关并保留说明；
  /// - R > D−1 时立即钳到 D−1：取它的时/分/秒分解（即三列都取上界），滚轮按新
  ///   数值与上界重建控制器，选中行同步；
  /// - R 仍合法（D 增大或缩小后仍满足 1 ≤ R ≤ D−1）时保持原值。
  ///
  /// 返回结果供调用方决定是否需要向用户说明。
  _ReminderReconcile _reconcileReminderWithTotal() {
    if (!_reminderEnabled) {
      return _ReminderReconcile.unchanged;
    }
    final int total = _totalSeconds;
    if (total <= 1) {
      _reminderEnabled = false;
      _reminderHours = 0;
      _reminderMinutes = 0;
      _reminderSeconds = 0;
      return _ReminderReconcile.closed;
    }
    final int upper = total - 1;
    if (_reminderTotalSeconds <= upper) {
      return _ReminderReconcile.unchanged;
    }
    // 钳到 D−1：它是 D−1 的时/分/秒分解，也是三列各自上界组成的唯一组合。
    final ReminderWheelBounds bounds = reminderBoundsOf(total);
    _reminderHours = bounds.maxHours;
    _reminderMinutes = bounds.maxMinutes;
    _reminderSeconds = bounds.maxSeconds;
    return _ReminderReconcile.clamped;
  }

  // ---- 提前提醒 ----

  void _handleReminderToggle(bool value) {
    if (!value) {
      setState(() {
        _reminderEnabled = false;
        _failureText = null;
      });
      widget.controller.clearFailureMessage();
      return;
    }
    final int total = _totalSeconds;
    if (total <= 1) {
      // 没有合法提醒值时开关保持关闭，并明确说明原因，不静默失败。
      _showSnackBar(_cannotEnableReminderText);
      return;
    }
    // 首次开启：R = min(180, D−1)，再分解为时/分/秒（该值本身合法，收敛函数
    // 只做前缀上界校验）。
    final int target = math.min(_defaultReminderSeconds, total - 1);
    final ({int hours, int minutes, int seconds}) selection =
        clampReminderSelection(
          totalSeconds: total,
          hours: target ~/ 3600,
          minutes: (target % 3600) ~/ 60,
          seconds: target % 60,
        );
    setState(() {
      _reminderEnabled = true;
      _reminderHours = selection.hours;
      _reminderMinutes = selection.minutes;
      _reminderSeconds = selection.seconds;
      _failureText = null;
    });
    widget.controller.clearFailureMessage();
    // 在用户主动开启提前提醒的上下文请求通知权限（API 33+ 要求由用户操作触发）。
    // 拒绝只影响后台通知，不阻止开关与保存，因此界面不承诺“通知已开启”。
    unawaited(widget.controller.requestNotificationPermission());
  }

  /// 右侧提醒滚轮回调：组件已按前缀上界收敛，这里再按当前 D 校验一次防御，
  /// 只保存 1 ≤ R ≤ D−1 的合法组合，绝不写回旧值。
  void _handleReminderChanged(int hours, int minutes, int seconds) {
    if (!_reminderEnabled || _submitting) {
      return;
    }
    final ({int hours, int minutes, int seconds}) selection =
        clampReminderSelection(
          totalSeconds: _totalSeconds,
          hours: hours,
          minutes: minutes,
          seconds: seconds,
        );
    final int total =
        selection.hours * 3600 + selection.minutes * 60 + selection.seconds;
    if (total < 1 || total > _totalSeconds - 1) {
      return;
    }
    if (selection.hours == _reminderHours &&
        selection.minutes == _reminderMinutes &&
        selection.seconds == _reminderSeconds) {
      return;
    }
    setState(() {
      _reminderHours = selection.hours;
      _reminderMinutes = selection.minutes;
      _reminderSeconds = selection.seconds;
      _failureText = null;
    });
    widget.controller.clearFailureMessage();
  }

  // ---- 保存 ----

  Future<void> _save() async {
    if (!_canSave || _submitting || widget.controller.busy) {
      return;
    }
    // 收起键盘焦点，让底部保存栏回到安全区底部。
    FocusScope.of(context).unfocus();
    final String name = _nameController.text.trim();
    final int totalSeconds = _totalSeconds;
    final int? reminderSeconds = _reminderEnabled
        ? _reminderTotalSeconds
        : null;
    widget.controller.clearFailureMessage();
    setState(() {
      _submitting = true;
      _failureText = null;
    });
    final CommandStatus status = await widget.controller.createProject(
      name: name,
      totalSeconds: totalSeconds,
      reminderSeconds: reminderSeconds,
    );
    if (!mounted) {
      return;
    }
    if (status == CommandStatus.success) {
      Navigator.of(context).pop(true);
      return;
    }
    // 失败保留名称、两组选值与开关，恢复按钮并给出控制器提供的真实原因。
    setState(() {
      _submitting = false;
      _failureText =
          widget.controller.lastFailureMessage ?? _saveFailedFallback;
    });
  }

  void _leavePage() {
    // 草稿只在本页 State 中，返回列表不写库，也不回传结果。
    Navigator.of(context).pop();
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

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final WindowMetrics metrics = WindowMetrics.of(context);
    final double horizontalPadding = metrics.pageHorizontalPadding;
    final double maxContentWidth = metrics.formMaxWidth;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxContentWidth),
                  child: _buildNavigationBar(metrics),
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  // 用滚动视口的真实高度判断短屏 / 横屏：它已扣除导航行与底部
                  // 保存栏，键盘弹出时也会缩小，因此这里能自动切到紧凑形态。
                  final bool compact =
                      constraints.maxHeight < _compactHeightThreshold;
                  // 内容宽度用于判断横屏六列是否放得下；窄分屏或大字体时上下排。
                  final double contentWidth = math.min(
                    maxContentWidth,
                    math.max(0, constraints.maxWidth - horizontalPadding * 2),
                  );
                  final bool useColumns =
                      metrics.formUsesColumns &&
                      _fitsTwoWheelGroups(
                        metrics,
                        contentWidth,
                        MediaQuery.textScalerOf(context),
                      );
                  final double topGap = compact
                      ? _compactNavToFormGap
                      : _navToFormGap;
                  final double bottomGap = compact
                      ? _compactContentBottomGap
                      : _contentBottomGap;
                  return SingleChildScrollView(
                    // 中部内容可滚动：键盘打开、放大文字或矮窗时，两组滚轮都能
                    // 滚动到达；保存栏在滚动区之外恒可见。
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      topGap,
                      horizontalPadding,
                      bottomGap,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxContentWidth),
                        child: _buildForm(
                          metrics,
                          compact: compact,
                          useColumns: useColumns,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            _buildSaveBar(metrics),
          ],
        ),
      ),
    );
  }

  /// 六列并排是否放得下：两组各三列，加上栏间距后不超过内容宽度。
  ///
  /// 滚轮内部有 FittedBox 兜底缩放，但缩到该阈值以下会牺牲可读性，因此按
  /// 自然字宽估算后直接上下排。
  bool _fitsTwoWheelGroups(
    WindowMetrics metrics,
    double contentWidth,
    TextScaler textScaler,
  ) {
    if (!contentWidth.isFinite) {
      return true;
    }
    final double minGroupWidth = _minWheelGroupWidth(metrics, textScaler);
    return contentWidth >= minGroupWidth * 2 + metrics.columnGap;
  }

  /// 一组三列滚轮的保守最小宽度：随字级与系统文字缩放增长。
  double _minWheelGroupWidth(WindowMetrics metrics, TextScaler textScaler) {
    final double digitFont = textScaler.scale(metrics.fontOf(TextLevel.f));
    return digitFont * _wheelColumnWidthFactor * 3 + _wheelColumnGap * 2;
  }

  /// 导航行高 48：左返回箭头，标题「新增倒计时」在行中居中。
  Widget _buildNavigationBar(WindowMetrics metrics) {
    return SizedBox(
      height: AppSpacing.touchTarget,
      child: Stack(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: _leavePage,
              padding: EdgeInsets.zero,
              iconSize: 24,
              color: AppColors.primaryText,
              tooltip: '返回列表',
              style: IconButton.styleFrom(
                minimumSize: const Size.square(AppSpacing.touchTarget),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Padding(
              // 为左侧返回按钮预留同宽空间，窄窗口下标题不压住图标。
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.touchTarget,
              ),
              child: Text(
                '新增倒计时',
                textAlign: TextAlign.center,
                style: textStyleOf(
                  metrics,
                  TextLevel.h,
                  color: AppColors.primaryText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 四向表单：竖屏 / 窄分屏单列；横屏名称首行、中部左时长右提醒。
  Widget _buildForm(
    WindowMetrics metrics, {
    required bool compact,
    required bool useColumns,
  }) {
    // 短屏 / 横屏压缩：两组滚轮都只显示 3 行，组距同步收紧。
    final int visibleRows = compact ? 3 : 5;
    final double groupGap = compact ? _compactGroupGap : metrics.formGroupGap;
    final Widget nameGroup = _buildNameGroup(metrics);
    final Widget durationGroup = _buildDurationGroup(
      metrics,
      visibleRows: visibleRows,
      alignTitleHeight: useColumns,
    );
    final Widget reminderGroup = _buildReminderGroup(
      metrics,
      visibleRows: visibleRows,
      alignTitleHeight: useColumns,
    );

    if (!useColumns) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          nameGroup,
          SizedBox(height: groupGap),
          durationGroup,
          SizedBox(height: groupGap),
          reminderGroup,
        ],
      );
    }
    // 手机横屏左列约 55%，平板横屏两列等宽；总宽由 formMaxWidth 限制在 960。
    final int leftFlex = (metrics.formLeftColumnFraction * 1000).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        nameGroup,
        SizedBox(height: groupGap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: leftFlex, child: durationGroup),
            SizedBox(width: metrics.columnGap),
            Expanded(flex: 1000 - leftFlex, child: reminderGroup),
          ],
        ),
      ],
    );
  }

  Widget _buildNameGroup(WindowMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '名称',
          style: textStyleOf(
            metrics,
            TextLevel.a,
            color: AppColors.primaryText,
          ),
        ),
        const SizedBox(height: _labelGap),
        Semantics(
          label: '名称',
          child: TextField(
            controller: _nameController,
            maxLines: 1,
            enabled: !_submitting,
            textInputAction: TextInputAction.done,
            style: textStyleOf(
              metrics,
              TextLevel.k,
              color: AppColors.primaryText,
            ),
            decoration: countdownFieldDecoration(
              metrics: metrics,
              enabled: !_submitting,
            ),
            onChanged: _handleNameChanged,
            onSubmitted: (String _) => FocusScope.of(context).unfocus(),
          ),
        ),
      ],
    );
  }

  Widget _buildDurationGroup(
    WindowMetrics metrics, {
    required int visibleRows,
    required bool alignTitleHeight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildGroupTitle(
          metrics,
          title: '时长',
          reserveTouchHeight: alignTitleHeight,
        ),
        const SizedBox(height: _titleToWheelGap),
        DurationWheelSet(
          hours: _hours,
          minutes: _minutes,
          seconds: _seconds,
          metrics: metrics,
          enabled: !_submitting,
          visibleRows: visibleRows,
          semanticsPrefix: '倒计时时长',
          onChanged: _handleDurationChanged,
        ),
      ],
    );
  }

  Widget _buildReminderGroup(
    WindowMetrics metrics, {
    required int visibleRows,
    required bool alignTitleHeight,
  }) {
    // D ≤ 1 没有合法提醒值：不构造空范围滚轮，开关禁用并解释原因。
    final bool showWheels = _reminderEnabled && _canEnableReminder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _buildGroupTitle(
          metrics,
          title: '提前提醒',
          trailing: _buildReminderSwitch(),
          reserveTouchHeight: alignTitleHeight,
          excludeTitleSemantics: true,
        ),
        if (showWheels) ...<Widget>[
          const SizedBox(height: _titleToWheelGap),
          // 与左侧时长同一套 NumberWheel 样式；上界/下界与收敛由组件处理，
          // 这里只保存回调返回的合法值。
          ReminderWheelSet(
            hours: _reminderHours,
            minutes: _reminderMinutes,
            seconds: _reminderSeconds,
            totalSeconds: _totalSeconds,
            metrics: metrics,
            enabled: !_submitting,
            visibleRows: visibleRows,
            semanticsPrefix: '提前提醒',
            onChanged: _handleReminderChanged,
          ),
        ],
      ],
    );
  }

  /// 分组标题行；横屏两组都预留 48，保证两组滚轮顶部与选中行对齐。
  Widget _buildGroupTitle(
    WindowMetrics metrics, {
    required String title,
    Widget? trailing,
    required bool reserveTouchHeight,
    bool excludeTitleSemantics = false,
  }) {
    final Widget titleText = Text(
      title,
      style: textStyleOf(metrics, TextLevel.a, color: AppColors.primaryText),
    );
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: excludeTitleSemantics
              ? ExcludeSemantics(child: titleText)
              : titleText,
        ),
        ?trailing,
      ],
    );
    if (!reserveTouchHeight) {
      return row;
    }
    // 开关的 48 dp 高度由标题行吸收；左侧「时长」标题行用同一高度与滚轮对齐。
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.touchTarget),
      child: Align(alignment: Alignment.center, child: row),
    );
  }

  Widget _buildReminderSwitch() {
    final bool enabled = _canEnableReminder && !_submitting;
    final Widget switchWidget = AppSwitch(
      value: _reminderEnabled,
      enabled: enabled,
      onChanged: _submitting ? null : _handleReminderToggle,
      semanticsLabel: '提前提醒',
    );
    if (_canEnableReminder) {
      return switchWidget;
    }
    // 总时长不足 2 秒时开关禁用；点按仍说明原因，不静默失败。
    return Tooltip(
      message: _cannotEnableReminderText,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _submitting
            ? null
            : () => _showSnackBar(_cannotEnableReminderText),
        child: switchWidget,
      ),
    );
  }

  /// 固定底栏：失败说明在上，保存按钮在下，始终锚定安全区底部。
  Widget _buildSaveBar(WindowMetrics metrics) {
    final String? failure = _failureText;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        metrics.pageHorizontalPadding,
        _saveBarTopGap,
        metrics.pageHorizontalPadding,
        _saveBarBottomGap,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: metrics.formMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (failure != null) ...<Widget>[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    failure,
                    style: textStyleOf(
                      metrics,
                      TextLevel.a,
                      color: AppColors.danger,
                    ),
                  ),
                ),
                const SizedBox(height: _failureGap),
              ],
              FilledButton(
                onPressed: _canSave ? _save : null,
                style: solidButtonStyle(metrics),
                child: _submitting
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          // 提交中按钮处于禁用态，用禁用前景色的小号进度环
                          // 表达进行中。
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.disabledForeground,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text('保存'),
                        ],
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
