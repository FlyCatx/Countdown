/// 滚轮选择器校验：两组三列读数、吸附、秒级提醒的动态上下界与收敛规则。
library;

import 'package:countdown_app/app/theme.dart';
import 'package:countdown_app/app/window_layout.dart';
import 'package:countdown_app/countdown/wheel_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按固定窗口渲染，并把当次 `WindowMetrics` 传给构建函数。
Future<WindowMetrics> pumpWithMetrics(
  WidgetTester tester,
  Widget Function(WindowMetrics metrics) build, {
  Size size = const Size(360, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late WindowMetrics captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildCountdownTheme(),
      home: Builder(
        builder: (BuildContext context) {
          captured = WindowMetrics.of(context);
          return Material(child: Center(child: build(captured)));
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('时长三列滚轮显示初值、单位与读屏前缀', (WidgetTester tester) async {
    final WindowMetrics metrics = await pumpWithMetrics(
      tester,
      (WindowMetrics metrics) => SizedBox(
        width: 320,
        child: DurationWheelSet(
          hours: 0,
          minutes: 3,
          seconds: 0,
          onChanged: (int h, int m, int s) {},
          metrics: metrics,
        ),
      ),
    );
    expect(find.text('03'), findsOneWidget);
    expect(find.text('时'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);
    expect(find.text('秒'), findsOneWidget);
    expect(metrics.sizeClass, WindowSizeClass.phonePortrait);
    expect(find.bySemanticsLabel('倒计时时长，分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('提醒三列滚轮按总时长显示动态上界', (WidgetTester tester) async {
    // D=300s → 提醒上限 299s = 00:04:59。
    await pumpWithMetrics(
      tester,
      (WindowMetrics metrics) => SizedBox(
        width: 320,
        child: ReminderWheelSet(
          hours: 0,
          minutes: 2,
          seconds: 59,
          totalSeconds: 300,
          onChanged: (int h, int m, int s) {},
          metrics: metrics,
        ),
      ),
    );
    expect(find.text('02'), findsOneWidget);
    expect(find.text('59'), findsWidgets);
    expect(find.text('时'), findsOneWidget);
    expect(find.text('分'), findsOneWidget);
    expect(find.text('秒'), findsOneWidget);
    expect(find.bySemanticsLabel('提前提醒，分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('向上滚动一档吸附到下一值并回调', (WidgetTester tester) async {
    int? changed;
    final WindowMetrics metrics = await pumpWithMetrics(
      tester,
      (WindowMetrics metrics) => SizedBox(
        width: 120,
        child: NumberWheel(
          value: 3,
          minValue: 0,
          maxValue: 59,
          metrics: metrics,
          semanticsLabel: '分钟',
          onChanged: (int value) => changed = value,
        ),
      ),
    );
    final double itemExtent = metrics.fontOf(TextLevel.f) * 1.45;
    await tester.drag(find.byType(ListWheelScrollView), Offset(0, -itemExtent));
    await tester.pumpAndSettle();
    expect(changed, 4);
  });

  testWidgets('短窗可用 3 行压缩高度', (WidgetTester tester) async {
    final WindowMetrics metrics = await pumpWithMetrics(
      tester,
      (WindowMetrics metrics) => SizedBox(
        width: 120,
        child: NumberWheel(
          value: 0,
          minValue: 0,
          maxValue: 59,
          metrics: metrics,
          visibleRows: 3,
          unitLabel: '秒',
          onChanged: (int value) {},
        ),
      ),
    );
    expect(
      NumberWheel.heightFor(metrics, 3),
      lessThan(NumberWheel.heightFor(metrics, 5)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('读屏可逐项增减滚轮档位', (WidgetTester tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpWithMetrics(
      tester,
      (WindowMetrics metrics) => SizedBox(
        width: 140,
        child: ReminderWheelSet(
          hours: 0,
          minutes: 0,
          seconds: 3,
          totalSeconds: 10,
          onChanged: (int h, int m, int s) {},
          metrics: metrics,
        ),
      ),
    );
    final Finder wheel = find.bySemanticsLabel('提前提醒，秒');
    expect(wheel, findsOneWidget);
    final SemanticsData data = tester.getSemantics(wheel).getSemanticsData();
    expect(data.value, '03');
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    handle.dispose();
  });

  group('秒级提醒的合法范围（1 ≤ R ≤ D−1）', () {
    test('D ≤ 1 没有合法提醒值', () {
      expect(
        clampReminderSelection(
          totalSeconds: 0,
          hours: 0,
          minutes: 0,
          seconds: 0,
        ),
        (hours: 0, minutes: 0, seconds: 0),
      );
      expect(
        clampReminderSelection(
          totalSeconds: 1,
          hours: 0,
          minutes: 0,
          seconds: 1,
        ),
        (hours: 0, minutes: 0, seconds: 0),
      );
    });

    test('D=2 时唯一合法值为 1 秒', () {
      expect(reminderBoundsOf(2).maxHours, 0);
      expect(reminderBoundsOf(2).maxMinutes, 0);
      expect(reminderBoundsOf(2).maxSeconds, 1);
      expect(
        clampReminderSelection(
          totalSeconds: 2,
          hours: 0,
          minutes: 0,
          seconds: 0,
        ),
        (hours: 0, minutes: 0, seconds: 1),
      );
    });

    test('跨分钟边界：D=60 可提前 59 秒，D=61 可提前 1 分钟', () {
      // D=60 时上限 59 秒：分钟高位回落到 0，秒保留在合法区间。
      expect(
        clampReminderSelection(
          totalSeconds: 60,
          hours: 0,
          minutes: 1,
          seconds: 30,
        ),
        (hours: 0, minutes: 0, seconds: 30),
      );
      expect(
        clampReminderSelection(
          totalSeconds: 60,
          hours: 0,
          minutes: 0,
          seconds: 59,
        ),
        (hours: 0, minutes: 0, seconds: 59),
      );
      expect(
        clampReminderSelection(
          totalSeconds: 61,
          hours: 0,
          minutes: 1,
          seconds: 30,
        ),
        (hours: 0, minutes: 1, seconds: 0),
      );
      expect(
        clampReminderSelection(
          totalSeconds: 61,
          hours: 0,
          minutes: 0,
          seconds: 0,
        ),
        (hours: 0, minutes: 0, seconds: 1),
      );
    });

    test('D=1:00:01 时提醒可达 1:00:00，高位滚动同步下级', () {
      // D = 3601 秒，U = 3600 秒。
      expect(reminderBoundsOf(3601).maxHours, 1);
      expect(reminderBoundsOf(3601).maxMinutes, 0);
      expect(reminderBoundsOf(3601).maxSeconds, 0);
      expect(
        clampReminderSelection(
          totalSeconds: 3601,
          hours: 1,
          minutes: 0,
          seconds: 0,
        ),
        (hours: 1, minutes: 0, seconds: 0),
      );
      // 小时从 1 回到 0 时，分钟/秒回到 0–59 的普通范围。
      expect(
        clampReminderSelection(
          totalSeconds: 3601,
          hours: 0,
          minutes: 59,
          seconds: 59,
        ),
        (hours: 0, minutes: 59, seconds: 59),
      );
    });

    test('D=99:59:59 不溢出', () {
      final int duration = 99 * 3600 + 59 * 60 + 59;
      final ReminderWheelBounds bounds = reminderBoundsOf(duration);
      expect(bounds.maxHours, 99);
      expect(bounds.maxMinutes, 59);
      expect(bounds.maxSeconds, 58);
      expect(
        clampReminderSelection(
          totalSeconds: duration,
          hours: 99,
          minutes: 59,
          seconds: 59,
        ),
        (hours: 99, minutes: 59, seconds: 58),
      );
    });

    test('时间为 0 时秒至少为 1', () {
      expect(
        clampReminderSelection(
          totalSeconds: 300,
          hours: 0,
          minutes: 0,
          seconds: 0,
        ),
        (hours: 0, minutes: 0, seconds: 1),
      );
      expect(
        clampReminderSelection(
          totalSeconds: 300,
          hours: 0,
          minutes: 0,
          seconds: 30,
        ),
        (hours: 0, minutes: 0, seconds: 30),
      );
    });
  });
}
