/// 计时文本格式化与提醒阈值判定。
///
/// 显示秒数与阈值比较使用不同口径：显示把正的剩余毫秒向上取整并在零截断，
/// 阈值比较用未取整的差值，避免最后一秒内出现“显示 00:00:01 但已报警”。
library;

/// 显示用的总秒数：正的剩余毫秒向上取整，零或负值截断为 0。
int displaySeconds(int remainingMillis) {
  if (remainingMillis <= 0) {
    return 0;
  }
  return (remainingMillis + 999) ~/ 1000;
}

/// 把秒数格式化为固定八字符的 `HH:MM:SS`；超过 99 小时按实际位数显示。
String formatDuration(int seconds) {
  final int safeSeconds = seconds < 0 ? 0 : seconds;
  final int hours = safeSeconds ~/ 3600;
  final int minutes = (safeSeconds % 3600) ~/ 60;
  final int secs = safeSeconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(hours)}:${two(minutes)}:${two(secs)}';
}

/// 剩余时间的显示文本。
String formatRemaining(int remainingMillis) =>
    formatDuration(displaySeconds(remainingMillis));

/// 本轮是否已进入提醒区间（红色数字）。
///
/// 条件：开启提醒、剩余未取整毫秒数小于等于阈值、且仍大于零；归零后回到普通状态。
bool isWithinReminderWindow({
  required int remainingMillis,
  required int? thresholdMillis,
}) {
  if (thresholdMillis == null) {
    return false;
  }
  return remainingMillis > 0 && remainingMillis <= thresholdMillis;
}

/// 提示条与通知共用的秒级文案，例如「还剩 00:03:00」。
///
/// 传入显示时的实际正剩余毫秒（四舍五入规则同 [formatRemaining]）；归零后不产生
/// 提醒文案，调用方应先判断剩余是否大于 0。
String reminderTextForRemaining(int remainingMillis) =>
    '还剩 ${formatRemaining(remainingMillis)}';

/// 把毫秒阈值换算为整秒（仅用于展示与测试夹具；运行判定始终用毫秒）。
int secondsOf(int millis) => millis ~/ 1000;
