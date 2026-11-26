/// 本轮的暂停／继续／重新计时／取消与临时快启：控制器状态机校验。
///
/// 使用内存仓储验证“命令结果 + 快照投影”，不覆盖宿主 SQLite 事务与系统闹钟，
/// 那些仍需设备验证。
library;

import 'package:countdown_app/countdown/controller.dart';
import 'package:countdown_app/countdown/model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_countdown_repository.dart';

Future<CountdownController> controllerWith(
  FakeCountdownRepository repository,
) async {
  final CountdownController controller = CountdownController(repository);
  await controller.load();
  await settle();
  return controller;
}

Future<void> seedProject(FakeCountdownRepository repository) async {
  await repository.createProject(
    name: '演讲',
    totalSeconds: 300,
    reminderSeconds: 60,
  );
}

void main() {
  late FakeCountdownRepository repository;
  late CountdownController controller;

  setUp(() async {
    repository = FakeCountdownRepository();
    await seedProject(repository);
    controller = await controllerWith(repository);
  });

  tearDown(() {
    controller.dispose();
  });

  test('暂停冻结剩余时间，时钟推进后读数不变', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    repository.clockElapsed += 30000;
    await controller.refresh();
    await settle();

    final CommandStatus paused = await controller.pauseRun();
    await settle();
    expect(paused, CommandStatus.success);
    expect(controller.isPaused, isTrue);
    expect(controller.activeRun!.pausedRemainingMillis, closeTo(270000, 1000));
    expect(controller.mainCardRemainingMillis, closeTo(270000, 1000));

    // 暂停期间经过 20 秒，冻结值不变。
    repository.clockElapsed += 20000;
    await controller.refresh();
    await settle();
    expect(controller.mainCardRemainingMillis, closeTo(270000, 1000));
    expect(repository.pausedRuns, contains(controller.activeRun!.runId));
  });

  test('继续后从冻结值往下计时，暂停期间不计入', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    repository.clockElapsed += 30000;
    await controller.refresh();
    await controller.pauseRun();
    await settle();

    repository.clockElapsed += 45000; // 暂停期间经过 45 秒，不应被计入
    await controller.refresh();
    final int frozen = controller.mainCardRemainingMillis;
    final CommandStatus resumed = await controller.resumeRun();
    await settle();
    expect(resumed, CommandStatus.success);
    expect(controller.isPaused, isFalse);
    expect(controller.mainCardRemainingMillis, closeTo(frozen, 1000));
    expect(repository.resumedRuns, contains(controller.activeRun!.runId));

    repository.clockElapsed += 10000;
    await controller.refresh();
    await settle();
    expect(controller.mainCardRemainingMillis, closeTo(frozen - 10000, 1500));
  });

  test('重新计时分配新的运行 ID 并从完整总时长开始', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    final int oldRunId = controller.activeRun!.runId;
    repository.clockElapsed += 60000;
    await controller.refresh();
    await controller.pauseRun();
    await settle();

    final CommandStatus restarted = await controller.restartRun();
    await settle();
    expect(restarted, CommandStatus.success);
    final RunSnapshot run = controller.activeRun!;
    expect(run.runId, isNot(oldRunId));
    expect(run.paused, isFalse);
    expect(run.pausedRemainingMillis, isNull);
    expect(controller.mainCardRemainingMillis, closeTo(300000, 1000));
    expect(repository.restartedRuns, contains(oldRunId));
    // 新一轮重新登记提醒闹钟。
    expect(repository.scheduledRuns, contains(run.runId));
  });

  test('取消保存中的常用项后回到可再次启动的空闲态', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    final CommandStatus cancelled = await controller.cancelRun();
    await settle();
    expect(cancelled, CommandStatus.success);
    expect(controller.activeRun, isNull);
    expect(controller.projects, hasLength(1));
    expect(controller.projects.single.name, '演讲');
    expect(controller.projects.single.state, ProjectState.idle);
    expect(repository.cancelledRuns, isNotEmpty);
  });

  test('快启临时运行不进入常用列表，取消后恢复空闲', () async {
    final int before = controller.projects.length;
    final CommandStatus started = await controller.startTemporaryRun(240);
    await settle();
    expect(started, CommandStatus.success);
    final RunSnapshot run = controller.activeRun!;
    expect(run.projectName, temporaryRunName);
    expect(run.reminderThresholdMillis, isNull);
    expect(run.totalSeconds, 240);
    expect(controller.projects.length, before, reason: '快启不写入常用列表');
    expect(run.paused, isFalse);

    final CommandStatus cancelled = await controller.cancelRun();
    await settle();
    expect(cancelled, CommandStatus.success);
    expect(controller.activeRun, isNull);
    expect(controller.projects.length, before);
    expect(repository.temporaryRunStarts, contains(240));
  });

  test('已有活动轮时快启被拒绝', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    final CommandStatus started = await controller.startTemporaryRun(60);
    expect(started, CommandStatus.failed);
    expect(controller.lastFailureMessage, FailureText.runAlreadyActive);
  });

  test('暂停在提醒窗口内仍显示红字', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    // 总 300 秒、提醒 1 分钟：推进到剩余 50 秒后暂停。
    repository.clockElapsed += 250000;
    await controller.refresh();
    await settle();
    expect(controller.mainCardWithinReminder, isTrue);
    await controller.pauseRun();
    await settle();
    expect(controller.isPaused, isTrue);
    expect(controller.mainCardWithinReminder, isTrue);
  });

  test('没有活动轮时控制命令给出明确失败原因', () async {
    final CommandStatus paused = await controller.pauseRun();
    expect(paused, CommandStatus.failed);
    expect(controller.lastFailureMessage, FailureText.noActiveRun);
    final CommandStatus cancelled = await controller.cancelRun();
    expect(cancelled, CommandStatus.failed);
    expect(controller.lastFailureMessage, FailureText.noActiveRun);
  });

  test('暂停状态下重新进入应用仍读到同一冻结值', () async {
    await controller.startRun(controller.projects.single.id);
    await settle();
    repository.clockElapsed += 120000;
    await controller.refresh();
    await controller.pauseRun();
    await settle();
    final int frozen = controller.mainCardRemainingMillis;

    // 模拟进程回收后重新建控制器读取同一仓储。
    final CountdownController reopened = CountdownController(repository);
    await reopened.load();
    await settle();
    expect(reopened.isPaused, isTrue);
    expect(reopened.mainCardRemainingMillis, closeTo(frozen, 1000));
    reopened.dispose();
  });
}
