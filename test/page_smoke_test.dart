/// 页面冒烟校验：四个基准窗口下的渲染与主要交互不抛异常、文案与状态符合规格。
///
/// 只验证 Flutter 层；真机上的视觉、系统栏、输入法、滚轮手势与通知分支仍需手验。
/// 页面测试不需要每秒重绘，读取完成后暂停后台刷新，避免留下未取消的定时器。
library;

import 'package:countdown_app/app/app_switch.dart';
import 'package:countdown_app/app/theme.dart';
import 'package:countdown_app/app/window_layout.dart';
import 'package:countdown_app/countdown/controller.dart';
import 'package:countdown_app/countdown/create_page.dart';
import 'package:countdown_app/countdown/delete_dialog.dart';
import 'package:countdown_app/countdown/list_page.dart';
import 'package:countdown_app/countdown/model.dart';
import 'package:countdown_app/countdown/running_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_countdown_repository.dart';

/// 四个典型验收窗口。
const Map<String, Size> kWindows = <String, Size>{
  '手机竖屏 360×800': Size(360, 800),
  '手机横屏 800×360': Size(800, 360),
  '平板竖屏 800×1280': Size(800, 1280),
  '平板横屏 1280×800': Size(1280, 800),
};

/// 读取一次快照后暂停每秒刷新，使测试不依赖真实定时器。
Future<CountdownController> makeController(
  WidgetTester tester,
  FakeCountdownRepository repository,
) async {
  final CountdownController controller = CountdownController(repository);
  await controller.load();
  await tester.pump();
  controller.onAppPaused();
  addTearDown(controller.dispose);
  return controller;
}

/// 固定逻辑窗口尺寸后渲染页面。
Future<void> pumpPage(WidgetTester tester, Size size, Widget page) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(theme: buildCountdownTheme(), home: page),
  );
  await tester.pump();
}

/// 找到包含指定文案的按钮（`find.byType` 只匹配精确类型，这里匹配子类）。
ButtonStyleButton buttonOf(WidgetTester tester, String label) {
  return tester
      .widgetList<ButtonStyleButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (Widget widget) => widget is ButtonStyleButton,
          ),
        ),
      )
      .first;
}

/// 把第 [index] 列滚轮向上拖 [steps] 档（正值增大）。
Future<void> scrollWheel(WidgetTester tester, int index, int steps) async {
  final Finder wheels = find.byType(ListWheelScrollView);
  final BuildContext context = tester.element(wheels.first);
  final WindowMetrics metrics = WindowMetrics.of(context);
  final double itemExtent = metrics.fontOf(TextLevel.f) * 1.45;
  await tester.drag(wheels.at(index), Offset(0, -itemExtent * steps));
  await tester.pumpAndSettle();
}

void main() {
  group('01 列表页', () {
    for (final MapEntry<String, Size> entry in kWindows.entries) {
      testWidgets('空闲态在${entry.key}显示滚轮与开始', (WidgetTester tester) async {
        final FakeCountdownRepository repository = FakeCountdownRepository();
        final CountdownController controller = await makeController(
          tester,
          repository,
        );
        await pumpPage(tester, entry.value, ListPage(controller: controller));

        expect(find.text('倒计时'), findsOneWidget);
        expect(find.text('常用计时器'), findsOneWidget);
        expect(find.text('＋ 新增'), findsOneWidget);
        expect(find.byType(ListWheelScrollView), findsNWidgets(3));
        expect(find.text('开始'), findsOneWidget);
        expect(find.text('正在计时'), findsNothing);
        expect(
          buttonOf(tester, '开始').onPressed,
          isNull,
          reason: '总时长为 0 时开始按钮禁用',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('有活动项时显示就地控制与常用列表', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.projects = const <CountdownProject>[
        CountdownProject(
          id: 2,
          name: '拉伸休息',
          totalSeconds: 300,
          reminderSeconds: null,
          createdAtUtcMillis: 2,
          state: ProjectState.idle,
        ),
        CountdownProject(
          id: 3,
          name: '阅读',
          totalSeconds: 1200,
          reminderSeconds: null,
          createdAtUtcMillis: 1,
          state: ProjectState.finished,
        ),
      ];
      repository.seedRun(
        runId: 7,
        name: '深度专注',
        totalSeconds: 1500,
        remainingSeconds: 754,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        ListPage(controller: controller),
      );

      expect(find.text('正在计时'), findsOneWidget);
      expect(find.text('深度专注'), findsOneWidget);
      expect(find.text('00:12:34'), findsOneWidget);
      expect(find.text('暂停'), findsOneWidget);
      expect(find.text('重新计时'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('拉伸休息'), findsOneWidget);
      expect(find.text('00:05:00'), findsOneWidget);
      expect(find.text('阅读'), findsOneWidget);
      expect(find.text('00:00:00'), findsOneWidget);
      expect(find.text('已结束'), findsOneWidget);
      expect(find.text('开始'), findsNWidgets(2));
      expect(
        buttonOf(tester, '开始').onPressed,
        isNull,
        reason: '有活动运行时其它项目的开始入口禁用',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('滚轮选时 → 开始 → 暂停 → 取消回到滚轮', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        ListPage(controller: controller),
      );

      // 分钟滚轮在索引 1，向上拖 4 档得到 00:04:00。
      await scrollWheel(tester, 1, 4);
      expect(find.text('04'), findsOneWidget);
      expect(buttonOf(tester, '开始').onPressed, isNotNull);
      await tester.tap(find.text('开始'));
      await tester.pumpAndSettle();

      expect(repository.temporaryRunStarts, contains(240));
      expect(find.text('正在计时'), findsOneWidget);
      expect(find.text('00:04:00'), findsOneWidget);
      // 页面标题与临时运行名称都是「倒计时」，允许出现多处。
      expect(find.text(temporaryRunName), findsWidgets);

      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('继续'), findsOneWidget);
      expect(controller.isPaused, isTrue);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(ListWheelScrollView), findsNWidgets(3));
      expect(find.text('开始'), findsOneWidget);
      expect(controller.activeRun, isNull);
      expect(find.text('04'), findsOneWidget, reason: '取消后保留最近一次快启选值');
      expect(tester.takeException(), isNull);
    });

    testWidgets('点主计时卡空白处进入运行页', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '深度专注',
        totalSeconds: 1500,
        remainingSeconds: 120,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        ListPage(controller: controller),
      );
      await tester.tap(find.text('正在计时'));
      await tester.pumpAndSettle();
      expect(find.byType(RunningPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('02 新增页', () {
    for (final MapEntry<String, Size> entry in kWindows.entries) {
      testWidgets('表单在${entry.key}显示名称/滚轮/提醒/底部保存', (
        WidgetTester tester,
      ) async {
        final FakeCountdownRepository repository = FakeCountdownRepository();
        final CountdownController controller = await makeController(
          tester,
          repository,
        );
        await pumpPage(tester, entry.value, CreatePage(controller: controller));

        expect(find.text('新增倒计时'), findsOneWidget);
        expect(find.text('名称'), findsOneWidget);
        expect(find.text('提前提醒'), findsOneWidget);
        expect(find.text('保存'), findsOneWidget);
        expect(find.byType(ListWheelScrollView), findsNWidgets(3));
        expect(find.text('00'), findsWidgets, reason: '时长初值 00:00:00');
        expect(buttonOf(tester, '保存').onPressed, isNull, reason: '名称为空时不可保存');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('填名称并滚到 25 分钟后保存写入仓储', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        CreatePage(controller: controller),
      );

      await tester.enterText(find.byType(TextField).first, '演讲');
      await tester.pump();
      await scrollWheel(tester, 1, 25);
      expect(find.text('25'), findsOneWidget);

      expect(buttonOf(tester, '保存').onPressed, isNotNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.projects, hasLength(1));
      expect(repository.projects.single.name, '演讲');
      expect(repository.projects.single.totalSeconds, 1500);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开启提前提醒后出现第二组三列滚轮，并保存秒级阈值', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        CreatePage(controller: controller),
      );

      await tester.enterText(find.byType(TextField).first, '演讲');
      await tester.pump();
      // 分钟滚轮拖 1 档 → 时长 60 秒。
      await scrollWheel(tester, 1, 1);
      expect(find.byType(ListWheelScrollView), findsNWidgets(3));

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      // D=60 时提醒上限 59 秒，默认取 min(180, 59)=59。
      expect(find.byType(ListWheelScrollView), findsNWidgets(6));
      expect(find.text('59'), findsOneWidget);
      expect(buttonOf(tester, '保存').onPressed, isNotNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(repository.projects, hasLength(1));
      expect(repository.projects.single.totalSeconds, 60);
      expect(
        repository.projects.single.reminderSeconds,
        59,
        reason: '秒级阈值应按 59 保存，而不是按分钟取整',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('缩短时长后提醒阈值收敛到 D−1', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        CreatePage(controller: controller),
      );

      await tester.enterText(find.byType(TextField).first, '演讲');
      await tester.pump();
      // 先设 3 分钟时长并开启提醒（默认 180 秒）。
      await scrollWheel(tester, 1, 3);
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(find.byType(ListWheelScrollView), findsNWidgets(6));

      // 时长缩到 60 秒：提醒必须同步收敛到 59 秒并随保存写入。
      await scrollWheel(tester, 1, -2);
      expect(find.text('59'), findsOneWidget);
      expect(buttonOf(tester, '保存').onPressed, isNotNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.projects, hasLength(1));
      expect(repository.projects.single.totalSeconds, 60);
      expect(repository.projects.single.reminderSeconds, 59);
      expect(tester.takeException(), isNull);
    });
  });

  group('03/04 运行页', () {
    for (final MapEntry<String, Size> entry in kWindows.entries) {
      testWidgets('运行页在${entry.key}显示居中数字与控制区', (WidgetTester tester) async {
        final FakeCountdownRepository repository = FakeCountdownRepository();
        repository.seedRun(
          runId: 7,
          name: '深度专注',
          totalSeconds: 1500,
          remainingSeconds: 754,
        );
        final CountdownController controller = await makeController(
          tester,
          repository,
        );
        await pumpPage(
          tester,
          entry.value,
          RunningPage(controller: controller),
        );

        expect(find.text('深度专注'), findsOneWidget);
        expect(find.text('00:12:34'), findsOneWidget);
        expect(find.text('列表'), findsOneWidget);
        expect(find.text('暂停'), findsOneWidget);
        expect(find.text('重新计时'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('暂停后原位显示继续并冻结读数', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '演讲',
        totalSeconds: 300,
        remainingSeconds: 223,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        RunningPage(controller: controller),
      );

      expect(find.text('00:03:43'), findsOneWidget);
      await tester.tap(find.text('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('继续'), findsOneWidget);
      expect(find.text('00:03:43'), findsOneWidget);
      expect(controller.isPaused, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新计时从完整时长重新开始', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '演讲',
        totalSeconds: 300,
        remainingSeconds: 223,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        RunningPage(controller: controller),
      );

      await tester.tap(find.text('重新计时'));
      await tester.pumpAndSettle();
      expect(find.text('00:05:00'), findsOneWidget);
      expect(repository.restartedRuns, contains(7));
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消后返回上一页', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '演讲',
        totalSeconds: 300,
        remainingSeconds: 223,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCountdownTheme(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          RunningPage(controller: controller),
                    ),
                  ),
                  child: const Text('进入运行页'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('进入运行页'));
      await tester.pumpAndSettle();
      expect(find.text('演讲'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('进入运行页'), findsOneWidget);
      expect(controller.activeRun, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('提醒窗口内显示红字与提示条，关闭后提示条消失红字保留', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '深度专注',
        totalSeconds: 1500,
        remainingSeconds: 180,
        reminderSeconds: 180,
        delivery: ReminderDelivery.foreground,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        RunningPage(controller: controller),
      );

      expect(find.text('还剩 00:03:00'), findsOneWidget);
      expect(find.text('00:03:00'), findsOneWidget);
      final Text time = tester.widget<Text>(find.text('00:03:00'));
      expect(time.style?.color, AppColors.danger);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('还剩 00:03:00'), findsNothing);
      final Text timeAfter = tester.widget<Text>(find.text('00:03:00'));
      expect(timeAfter.style?.color, AppColors.danger, reason: '收起后仍为红字');
      expect(tester.takeException(), isNull);
    });

    testWidgets('归零后停在 00:00:00 且不再显示负数', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      repository.seedRun(
        runId: 7,
        name: '阅读',
        totalSeconds: 60,
        remainingSeconds: 2,
      );
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        RunningPage(controller: controller),
      );
      expect(find.text('阅读'), findsOneWidget);

      repository.clockElapsed += 5000;
      await controller.refresh();
      await tester.pump();
      expect(find.text('00:00:00'), findsOneWidget);
      expect(find.text('阅读'), findsOneWidget);
      expect(find.textContaining('-'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('05 删除确认', () {
    testWidgets('弹窗显示目标名称并在取消后关闭', (WidgetTester tester) async {
      final FakeCountdownRepository repository = FakeCountdownRepository();
      const CountdownProject project = CountdownProject(
        id: 1,
        name: '深度专注',
        totalSeconds: 1500,
        reminderSeconds: 180,
        createdAtUtcMillis: 1,
        state: ProjectState.idle,
      );
      repository.projects = const <CountdownProject>[project];
      final CountdownController controller = await makeController(
        tester,
        repository,
      );
      await pumpPage(
        tester,
        const Size(360, 800),
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showDeleteProjectDialog(
              context,
              controller: controller,
              project: project,
            ),
            child: const Text('打开删除'),
          ),
        ),
      );
      await tester.tap(find.text('打开删除'));
      await tester.pumpAndSettle();

      expect(find.text('删除「深度专注」？'), findsOneWidget);
      expect(find.text('将结束本次计时。'), findsNothing, reason: '非运行项省略说明');
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('删除「深度专注」？'), findsNothing);
      expect(repository.deletedProjects, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}
