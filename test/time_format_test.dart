/// 计时文本与提醒窗口的边界校验（HANDOFF §3.1、§4.4）。
library;

import 'package:countdown_app/countdown/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('显示秒数把正的剩余毫秒向上取整', () {
    expect(displaySeconds(1), 1);
    expect(displaySeconds(999), 1);
    expect(displaySeconds(1000), 1);
    expect(displaySeconds(1001), 2);
    expect(displaySeconds(3600000), 3600);
  });

  test('归零或负剩余截断为零，不出现负数', () {
    expect(displaySeconds(0), 0);
    expect(displaySeconds(-1), 0);
    expect(displaySeconds(-5000), 0);
    expect(formatRemaining(-1), '00:00:00');
    expect(formatRemaining(0), '00:00:00');
  });

  test('八字符格式固定补零', () {
    expect(formatDuration(0), '00:00:00');
    expect(formatDuration(1), '00:00:01');
    expect(formatDuration(59), '00:00:59');
    expect(formatDuration(60), '00:01:00');
    expect(formatDuration(754), '00:12:34');
    expect(formatDuration(3600), '01:00:00');
    expect(formatDuration(359999), '99:59:59');
    expect(formatRemaining(753500), '00:12:34');
  });

  test('阈值比较使用未取整的剩余毫秒', () {
    // 剩余 60001 ms 仍在阈值 60000 之外。
    expect(
      isWithinReminderWindow(remainingMillis: 60001, thresholdMillis: 60000),
      isFalse,
    );
    expect(
      isWithinReminderWindow(remainingMillis: 60000, thresholdMillis: 60000),
      isTrue,
    );
    expect(
      isWithinReminderWindow(remainingMillis: 1, thresholdMillis: 60000),
      isTrue,
    );
    expect(
      isWithinReminderWindow(remainingMillis: 0, thresholdMillis: 60000),
      isFalse,
      reason: '归零后不再使用提醒红字',
    );
    expect(
      isWithinReminderWindow(remainingMillis: -100, thresholdMillis: 60000),
      isFalse,
    );
    expect(
      isWithinReminderWindow(remainingMillis: 30000, thresholdMillis: null),
      isFalse,
      reason: '未开启提醒时没有提醒窗口',
    );
  });

  test('提示条文案精确到秒，不按整分钟取整', () {
    expect(reminderTextForRemaining(180000), '还剩 00:03:00');
    expect(reminderTextForRemaining(59000), '还剩 00:00:59');
    expect(reminderTextForRemaining(1000), '还剩 00:00:01');
    expect(reminderTextForRemaining(1999), '还剩 00:00:02');
    expect(reminderTextForRemaining(65000), '还剩 00:01:05');
  });

  test('毫秒阈值换算为整秒只用于展示与夹具', () {
    expect(secondsOf(180000), 180);
    expect(secondsOf(1999), 1);
    expect(secondsOf(0), 0);
  });
}
