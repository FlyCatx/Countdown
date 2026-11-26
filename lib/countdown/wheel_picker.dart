/// 时分秒与分钟滚轮选择器，首页快启与新增页共用同一套样式和读数规则。
///
/// 交互约定：一列数字垂直滚动、吸附到整行，选中行居中并以粗体主文色显示，
/// 相邻行按距离弱化；屏幕阅读器通过增加/减少动作逐项调整，而不是逐像素滑动。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../app/window_layout.dart';

/// 单列数字滚轮。
class NumberWheel extends StatefulWidget {
  const NumberWheel({
    super.key,
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.onChanged,
    required this.metrics,
    this.unitLabel,
    this.semanticsLabel,
    this.enabled = true,
    this.visibleRows = 5,
  });

  final int value;
  final int minValue;
  final int maxValue;
  final ValueChanged<int> onChanged;
  final WindowMetrics metrics;

  /// 选中行右侧的单位文字（如「时」「分」「秒」「分钟」）。
  final String? unitLabel;
  final String? semanticsLabel;
  final bool enabled;

  /// 可见行数，必须为奇数（3 或 5）。短窗口用 3 行压缩高度。
  final int visibleRows;

  /// 给定行数时滚轮占用的高度，供页面预留空间。
  static double heightFor(WindowMetrics metrics, int visibleRows) =>
      metrics.fontOf(TextLevel.f) *
      1.45 *
      (visibleRows.isOdd ? visibleRows : 5);

  /// 两位数显示；上限固定为 99，不会出现三位数。
  static String textOf(int value) => value.toString().padLeft(2, '0');

  @override
  State<NumberWheel> createState() => _NumberWheelState();
}

class _NumberWheelState extends State<NumberWheel> {
  late FixedExtentScrollController _controller;
  late int _selectedIndex;

  int get _itemCount => widget.maxValue - widget.minValue + 1;

  @override
  void initState() {
    super.initState();
    _selectedIndex = (widget.value - widget.minValue).clamp(0, _itemCount - 1);
    _controller = FixedExtentScrollController(initialItem: _selectedIndex);
  }

  @override
  void didUpdateWidget(NumberWheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int desired = (widget.value - widget.minValue).clamp(
      0,
      _itemCount - 1,
    );
    if (desired == _selectedIndex) {
      return;
    }
    _selectedIndex = desired;
    if (_controller.hasClients) {
      // 父级把值收敛到另一档（例如提醒阈值上限变化）时同步位置。
      _controller.animateToItem(
        desired,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      _controller.dispose();
      _controller = FixedExtentScrollController(initialItem: desired);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _step(int delta) {
    if (!widget.enabled) {
      return;
    }
    final int next = (_selectedIndex + delta).clamp(0, _itemCount - 1);
    if (next == _selectedIndex) {
      return;
    }
    if (_controller.hasClients) {
      _controller.animateToItem(
        next,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
    _selectedIndex = next;
    widget.onChanged(widget.minValue + next);
  }

  @override
  Widget build(BuildContext context) {
    final WindowMetrics metrics = widget.metrics;
    final int rows = widget.visibleRows.isOdd ? widget.visibleRows : 5;
    final double itemExtent = metrics.fontOf(TextLevel.f) * 1.45;
    final double height = itemExtent * rows;
    final String valueText = NumberWheel.textOf(widget.value);

    return Semantics(
      label: widget.semanticsLabel,
      value: valueText,
      increasedValue: widget.value >= widget.maxValue
          ? null
          : NumberWheel.textOf(widget.value + 1),
      decreasedValue: widget.value <= widget.minValue
          ? null
          : NumberWheel.textOf(widget.value - 1),
      enabled: widget.enabled,
      onIncrease: widget.enabled && widget.value < widget.maxValue
          ? () => _step(1)
          : null,
      onDecrease: widget.enabled && widget.value > widget.minValue
          ? () => _step(-1)
          : null,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Stack(
          children: <Widget>[
            ListWheelScrollView.useDelegate(
              controller: _controller,
              itemExtent: itemExtent,
              physics: widget.enabled
                  ? const FixedExtentScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              diameterRatio: 2.2,
              perspective: 0.002,
              onSelectedItemChanged: (int index) {
                if (index == _selectedIndex) {
                  return;
                }
                setState(() => _selectedIndex = index);
                widget.onChanged(widget.minValue + index);
              },
              childDelegate: ListWheelChildBuilderDelegate(
                childCount: _itemCount,
                builder: (BuildContext context, int index) {
                  final bool selected = index == _selectedIndex;
                  final int distance = (index - _selectedIndex).abs();
                  final TextStyle style = textStyleOf(
                    metrics,
                    selected ? TextLevel.f : TextLevel.v,
                    color: widget.enabled
                        ? (selected
                              ? AppColors.primaryText
                              : AppColors.secondaryText.withValues(
                                  alpha: distance <= 1 ? 0.55 : 0.28,
                                ))
                        : AppColors.disabledForeground,
                    weight: selected ? FontWeight.w700 : FontWeight.w500,
                  );
                  // 窄列（平板横屏左栏、短窗压缩）时数字+单位可能超出列宽：
                  // 整行按比例缩小而不是换行或裁切，保证选中档完整可读。
                  return Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: <Widget>[
                          Text(
                            NumberWheel.textOf(widget.minValue + index),
                            style: style,
                            textAlign: TextAlign.center,
                          ),
                          if (selected && widget.unitLabel != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Text(
                                widget.unitLabel!,
                                style: textStyleOf(
                                  metrics,
                                  TextLevel.a,
                                  color: AppColors.secondaryText,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            // 上下两端渐隐，视觉上弱化相邻档位；不拦截手势。
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        AppColors.canvas,
                        AppColors.canvas.withValues(alpha: 0.0),
                        AppColors.canvas.withValues(alpha: 0.0),
                        AppColors.canvas,
                      ],
                      stops: const <double>[0.0, 0.2, 0.8, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时 / 分 / 秒三列滚轮（首页快启与新增页时长共用）。
class DurationWheelSet extends StatelessWidget {
  const DurationWheelSet({
    super.key,
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.onChanged,
    required this.metrics,
    this.enabled = true,
    this.visibleRows = 5,
    this.semanticsPrefix = '倒计时时长',
  });

  final int hours;
  final int minutes;
  final int seconds;
  final void Function(int hours, int minutes, int seconds) onChanged;
  final WindowMetrics metrics;
  final bool enabled;
  final int visibleRows;

  /// 读屏前缀，用于区分「倒计时时长」与「提前提醒」两组滚轮。
  final String semanticsPrefix;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: NumberWheel(
            value: hours,
            minValue: 0,
            maxValue: 99,
            metrics: metrics,
            unitLabel: '时',
            semanticsLabel: '$semanticsPrefix，小时',
            enabled: enabled,
            visibleRows: visibleRows,
            onChanged: (int value) => onChanged(value, minutes, seconds),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NumberWheel(
            value: minutes,
            minValue: 0,
            maxValue: 59,
            metrics: metrics,
            unitLabel: '分',
            semanticsLabel: '$semanticsPrefix，分钟',
            enabled: enabled,
            visibleRows: visibleRows,
            onChanged: (int value) => onChanged(hours, value, seconds),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NumberWheel(
            value: seconds,
            minValue: 0,
            maxValue: 59,
            metrics: metrics,
            unitLabel: '秒',
            semanticsLabel: '$semanticsPrefix，秒',
            enabled: enabled,
            visibleRows: visibleRows,
            onChanged: (int value) => onChanged(hours, minutes, value),
          ),
        ),
      ],
    );
  }
}

/// 提前提醒秒数的三列上限（按总时长 D 推导，D−1 为最大合法剩余秒数）。
@immutable
class ReminderWheelBounds {
  const ReminderWheelBounds({
    required this.maxHours,
    required this.maxMinutes,
    required this.maxSeconds,
  });

  final int maxHours;
  final int maxMinutes;
  final int maxSeconds;
}

/// 按总秒数 [totalSeconds] 推导提醒滚轮上限：U = D−1 分解为 H/M/S。
///
/// D ≤ 1 时没有合法提醒值（返回全 0 上界），调用方应禁用提醒开关。
ReminderWheelBounds reminderBoundsOf(int totalSeconds) {
  final int upper = math.max(0, totalSeconds - 1);
  return ReminderWheelBounds(
    maxHours: upper ~/ 3600,
    maxMinutes: (upper % 3600) ~/ 60,
    maxSeconds: upper % 60,
  );
}

/// 把一组提醒时/分/秒收敛到「1 ≤ 总秒数 ≤ D−1」的最近合法组合。
///
/// 规则与手柄滚动一致：小时受 H 上界限制；小时取上界时分钟受 M 上界限制，否则
/// 0–59；时、分都取上界前缀时秒受 S 上界限制，否则 0–59；时、分都为 0 时秒至少
/// 为 1。返回的顺序固定为 (时, 分, 秒)。
({int hours, int minutes, int seconds}) clampReminderSelection({
  required int totalSeconds,
  required int hours,
  required int minutes,
  required int seconds,
}) {
  final int upper = totalSeconds - 1;
  if (totalSeconds <= 1 || upper < 1) {
    return (hours: 0, minutes: 0, seconds: 0);
  }
  final ReminderWheelBounds bounds = reminderBoundsOf(totalSeconds);
  int h = hours.clamp(0, bounds.maxHours);
  int m = h == bounds.maxHours
      ? minutes.clamp(0, bounds.maxMinutes)
      : minutes.clamp(0, 59);
  int s = (h == bounds.maxHours && m == bounds.maxMinutes)
      ? seconds.clamp(0, bounds.maxSeconds)
      : seconds.clamp(0, 59);
  if (h == 0 && m == 0 && s < 1) {
    s = 1;
  }
  // 防御：前缀都未到上界时组合已 ≤U；这里再校验一次总秒数。
  while (h * 3600 + m * 60 + s > upper) {
    if (s > 0) {
      s -= 1;
    } else if (m > 0) {
      m -= 1;
      s = 59;
    } else if (h > 0) {
      h -= 1;
      m = 59;
      s = 59;
    } else {
      break;
    }
  }
  if (h == 0 && m == 0 && s < 1) {
    s = upper >= 1 ? 1 : 0;
  }
  return (hours: h, minutes: m, seconds: s);
}

/// 提前提醒的时 / 分 / 秒三列滚轮：上限随总时长与已选高位动态变化。
///
/// 每次选择都经 [clampReminderSelection] 收敛后再回调，避免滚轮惯性或程序化跳转
/// 把越界值写回；上界变化时滚轮以新的 key 重建控制器，保证选中行与数值同步。
class ReminderWheelSet extends StatelessWidget {
  const ReminderWheelSet({
    super.key,
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.totalSeconds,
    required this.onChanged,
    required this.metrics,
    this.enabled = true,
    this.visibleRows = 5,
    this.semanticsPrefix = '提前提醒',
  });

  final int hours;
  final int minutes;
  final int seconds;

  /// 左侧倒计时总秒数 D；提醒上限为 D−1。
  final int totalSeconds;
  final void Function(int hours, int minutes, int seconds) onChanged;
  final WindowMetrics metrics;
  final bool enabled;
  final int visibleRows;
  final String semanticsPrefix;

  @override
  Widget build(BuildContext context) {
    final ReminderWheelBounds bounds = reminderBoundsOf(totalSeconds);
    final bool hourAtMax = hours.clamp(0, bounds.maxHours) == bounds.maxHours;
    final int minuteMax = hourAtMax ? bounds.maxMinutes : 59;
    final bool prefixAtMax =
        hourAtMax && minutes.clamp(0, minuteMax) == bounds.maxMinutes;
    final int secondMax = prefixAtMax ? bounds.maxSeconds : 59;
    final int minuteMin = 0;
    final int secondMin = (hours == 0 && minutes == 0) ? 1 : 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: _boundedWheel(
            keyName: 'reminder-h-${bounds.maxHours}',
            value: hours,
            minValue: 0,
            maxValue: bounds.maxHours,
            unitLabel: '时',
            label: '$semanticsPrefix，小时',
            onChanged: (int value) => _emit(
              clampReminderSelection(
                totalSeconds: totalSeconds,
                hours: value,
                minutes: minutes,
                seconds: seconds,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _boundedWheel(
            keyName: 'reminder-m-$minuteMin-$minuteMax',
            value: minutes,
            minValue: minuteMin,
            maxValue: math.max(minuteMin, minuteMax),
            unitLabel: '分',
            label: '$semanticsPrefix，分钟',
            onChanged: (int value) => _emit(
              clampReminderSelection(
                totalSeconds: totalSeconds,
                hours: hours,
                minutes: value,
                seconds: seconds,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _boundedWheel(
            keyName: 'reminder-s-$secondMin-$secondMax',
            value: seconds,
            minValue: secondMin,
            maxValue: math.max(secondMin, secondMax),
            unitLabel: '秒',
            label: '$semanticsPrefix，秒',
            onChanged: (int value) => _emit(
              clampReminderSelection(
                totalSeconds: totalSeconds,
                hours: hours,
                minutes: minutes,
                seconds: value,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _boundedWheel({
    required String keyName,
    required int value,
    required int minValue,
    required int maxValue,
    required String unitLabel,
    required String label,
    required ValueChanged<int> onChanged,
  }) {
    // 上界变化时重建滚轮控制器：避免旧的滚动位置映射到新范围后越界或写回旧值。
    return NumberWheel(
      key: ValueKey<String>(keyName),
      value: value.clamp(minValue, maxValue),
      minValue: minValue,
      maxValue: maxValue,
      metrics: metrics,
      unitLabel: unitLabel,
      semanticsLabel: label,
      enabled: enabled,
      visibleRows: visibleRows,
      onChanged: onChanged,
    );
  }

  void _emit(({int hours, int minutes, int seconds}) selection) {
    onChanged(selection.hours, selection.minutes, selection.seconds);
  }
}
