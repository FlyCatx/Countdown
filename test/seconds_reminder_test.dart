/// 秒级提前提醒：控制器与仓储之间的单位传递、5 秒/2 秒的触发时间线。
///
/// 宿主 SQLite 迁移与系统闹钟在 `host-sql-check.py` 与设备手验覆盖；这里验证
/// Flutter 侧不把阈值换算回分钟，并验证进入提醒区间的时间点。
library;

import 'package:countdown_app/countdown/controller.dart';
import 'package:countdown_app/countdown/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_countdown_repository.dart';

Future<CountdownController> loadController(
  FakeCountdownRepository repository,
) async {
  final CountdownController controller = CountdownController(repository);
  await controller.load();
  await settle();
  controller.onAppPaused();
  return controller;
}

void main() {
  late FakeCountdownRepository repository;
  late CountdownController controller;

  setUp(() async {
    repository = FakeCountdownRepository();
    controller = await loadController(repository);
  });

  tearDown(() {
    controller.dispose();
  });

  test('保存时按秒传入阈值，不换算成分钟', () async {
    final CommandStatus created = await controller.createProject(
      name: '演讲',
      totalSeconds: 65,
      reminderSeconds: 65,
    );
    await settle();
    expect(created, CommandStatus.failed, reason: 'R 必须严格小于 D');

    final CommandStatus ok = await controller.createProject(
      name: '演讲',
      totalSeconds: 65,
      reminderSeconds: 64,
    );
    await settle();
    expect(ok, CommandStatus.success);
    expect(controller.projects.single.totalSeconds, 65);
    expect(
      controller.projects.single.reminderSeconds,
      64,
      reason: '阈值以秒持久化，64 秒不应变成 1 分钟或 60 秒',
    );
  });

  test('开始运行后毫秒阈值 = 秒阈值 × 1000', () async {
    await controller.createProject(
      name: '演讲',
      totalSeconds: 65,
      reminderSeconds: 65 - 1,
    );
    await settle();
    await controller.startRun(controller.projects.single.id);
    await settle();
    expect(controller.activeRun!.reminderThresholdMillis, 64000);
  });

  test('5 秒总时长提前 2 秒：第 3 秒进入提醒区间', () async {
    await controller.createProject(
      name: '短计时',
      totalSeconds: 5,
      reminderSeconds: 2,
    );
    await settle();
    await controller.startRun(controller.projects.single.id);
    await settle();
    expect(controller.activeRun!.reminderThresholdMillis, 2000);
    expect(controller.bannerVisible, isFalse, reason: '尚未到阈值');

    // 开始后 2.9 秒：剩余 2.1 秒，仍在阈值之外。
    repository.clockElapsed += 2900;
    await controller.refresh();
    await settle();
    expect(controller.mainCardWithinReminder, isFalse);

    // 开始后 3.1 秒：剩余 1.9 秒，进入阈值，前台认领提示条。
    repository.clockElapsed += 200;
    await controller.refresh();
    await settle();
    expect(controller.mainCardWithinReminder, isTrue);
    expect(controller.bannerVisible, isTrue);
    expect(controller.mainCardRemainingMillis, greaterThan(0));
    expect(controller.mainCardRemainingMillis, lessThanOrEqualTo(2000));
  });

  test('60 秒总时长可提前 59 秒，提示条显示秒级文案', () async {
    await controller.createProject(
      name: '一分钟',
      totalSeconds: 60,
      reminderSeconds: 59,
    );
    await settle();
    await controller.startRun(controller.projects.single.id);
    await settle();
    expect(controller.activeRun!.reminderThresholdMillis, 59000);
    // 走到剩余 59.5 秒：阈值比较用未取整毫秒，不触发。
    repository.clockElapsed += 500;
    await controller.refresh();
    await settle();
    expect(controller.mainCardWithinReminder, isFalse);
    repository.clockElapsed += 1000;
    await controller.refresh();
    await settle();
    expect(controller.mainCardWithinReminder, isTrue);
    expect(
      reminderTextForRemaining(controller.mainCardRemainingMillis),
      '还剩 00:00:59',
    );
  });

  test('暂停时冻结的阈值仍按秒保留，继续后不重复提醒', () async {
    await controller.createProject(
      name: '演讲',
      totalSeconds: 300,
      reminderSeconds: 60,
    );
    await settle();
    await controller.startRun(controller.projects.single.id);
    await settle();
    // 先跨过阈值，前台认领一次。
    repository.clockElapsed += 240500;
    await controller.refresh();
    await settle();
    expect(controller.bannerVisible, isTrue);
    await controller.pauseRun();
    await settle();
    expect(controller.isPaused, isTrue);
    expect(controller.bannerVisible, isTrue, reason: '已投递的提示保留');
    await controller.resumeRun();
    await settle();
    expect(controller.bannerVisible, isTrue, reason: '同一轮不重复投递也不清除已投递');
    expect(controller.activeRun!.reminderThresholdMillis, 60000);
  });
}
