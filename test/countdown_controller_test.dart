/// 控制器行为校验：使用内存仓储验证命令结果、归零收尾与提醒认领。
///
/// 覆盖可归因于状态机与持久化边界的逻辑；安卓宿主的 SQLite 事务、闹钟与通知
/// 投递仍需在设备上验证。
library;

import 'package:countdown_app/countdown/controller.dart';
import 'package:countdown_app/countdown/model.dart';
import 'package:countdown_app/countdown/repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_countdown_repository.dart';

void main() {
  late FakeCountdownRepository repository;
  late CountdownController controller;

  setUp(() {
    repository = FakeCountdownRepository();
    controller = CountdownController(repository);
  });

  tearDown(() {
    controller.dispose();
  });

  test('首次加载得到空列表且不判定为读取失败', () async {
    await controller.load();
    expect(controller.projects, isEmpty);
    expect(controller.activeRun, isNull);
    expect(controller.loading, isFalse);
    expect(controller.loadError, isNull);
    expect(controller.hasActiveRun, isFalse);
  });

  test('保存成功返回 success 并刷新列表', () async {
    final CommandStatus status = await controller.createProject(
      name: '深度专注',
      totalSeconds: 1500,
      reminderSeconds: 180,
    );
    await settle();
    expect(status, CommandStatus.success);
    expect(controller.projects, hasLength(1));
    expect(controller.projects.single.name, '深度专注');
    expect(controller.projects.single.reminderSeconds, 180);
    expect(controller.busy, isFalse);
  });

  test('保存失败不伪造成功并给出可展示原因', () async {
    repository.nextCreateError = const CountdownRepositoryException(
      CountdownErrorCode.storageFailure,
    );
    final CommandStatus status = await controller.createProject(
      name: '写作',
      totalSeconds: 60,
      reminderSeconds: null,
    );
    expect(status, CommandStatus.failed);
    expect(controller.projects, isEmpty);
    expect(controller.lastFailureMessage, FailureText.storage);
    expect(controller.busy, isFalse);
  });

  test('启动运行后分配本轮快照并登记提醒闹钟', () async {
    await repository.createProject(
      name: '深度专注',
      totalSeconds: 1500,
      reminderSeconds: 180,
    );
    await controller.load();
    final CommandStatus status = await controller.startRun(
      controller.projects.single.id,
    );
    await settle();
    expect(status, CommandStatus.success);
    expect(controller.activeRun, isNotNull);
    expect(controller.activeRun!.projectName, '深度专注');
    expect(repository.scheduledRuns, contains(controller.activeRun!.runId));
    expect(controller.projects, isEmpty, reason: '运行中的项目不在常用列表里');
    expect(controller.hasActiveRun, isTrue);
  });

  test('重复启动返回失败并提示已有计时', () async {
    repository.nextStartError = const CountdownRepositoryException(
      CountdownErrorCode.runAlreadyActive,
    );
    final CommandStatus status = await controller.startRun(1);
    expect(status, CommandStatus.failed);
    expect(controller.lastFailureMessage, FailureText.runAlreadyActive);
  });

  test('归零时结束本轮并让列表显示已结束', () async {
    repository.projects = <CountdownProject>[
      const CountdownProject(
        id: 1,
        name: '阅读',
        totalSeconds: 30,
        reminderSeconds: null,
        createdAtUtcMillis: 1700000000000,
        state: ProjectState.idle,
      ),
    ];
    await controller.startRun(1);
    await settle();
    repository.clockElapsed += 31000;
    await controller.refresh();
    await settle();
    expect(repository.finishedRuns, contains(42));
    expect(controller.activeRun, isNull);
    expect(controller.projects.single.state, ProjectState.finished);
  });

  test('进入提醒窗口后前台认领并显示提示条，收起后不再显示', () async {
    repository.projects = <CountdownProject>[
      const CountdownProject(
        id: 1,
        name: '深度专注',
        totalSeconds: 1500,
        reminderSeconds: 180,
        createdAtUtcMillis: 1700000000000,
        state: ProjectState.idle,
      ),
    ];
    await controller.startRun(1);
    await settle();
    expect(controller.bannerVisible, isFalse, reason: '尚未进入提醒窗口');
    repository.clockElapsed += 1500000 - 100000;
    await controller.refresh();
    await settle();
    expect(controller.bannerVisible, isTrue);
    expect(controller.mainCardWithinReminder, isTrue);
    await controller.dismissBanner();
    await settle();
    expect(repository.dismissedBanners, contains(42));
    expect(controller.bannerVisible, isFalse);
  });

  test('已被系统通知投递的同一轮不再弹前台提示条', () async {
    repository.projects = <CountdownProject>[
      const CountdownProject(
        id: 1,
        name: '阅读',
        totalSeconds: 120,
        reminderSeconds: 60,
        createdAtUtcMillis: 1700000000000,
        state: ProjectState.idle,
      ),
    ];
    await controller.startRun(1);
    await settle();
    repository.seedRun(
      runId: 42,
      name: '阅读',
      totalSeconds: 120,
      remainingSeconds: 50,
      reminderSeconds: 60,
      delivery: ReminderDelivery.notification,
    );
    await controller.refresh();
    await settle();
    expect(controller.bannerVisible, isFalse);
    expect(controller.mainCardWithinReminder, isTrue, reason: '红字仍保留');
  });

  test('删除项目成功返回 success 并刷新列表', () async {
    await repository.createProject(
      name: '拉伸休息',
      totalSeconds: 300,
      reminderSeconds: null,
    );
    await controller.load();
    final CommandStatus status = await controller.deleteProject(
      controller.projects.single.id,
    );
    await settle();
    expect(status, CommandStatus.success);
    expect(repository.deletedProjects, contains(1));
    expect(controller.projects, isEmpty);
  });

  test('删除失败保留列表并给出失败原因', () async {
    await repository.createProject(
      name: '拉伸休息',
      totalSeconds: 300,
      reminderSeconds: null,
    );
    await controller.load();
    repository.nextDeleteError = const CountdownRepositoryException(
      CountdownErrorCode.storageFailure,
    );
    final CommandStatus status = await controller.deleteProject(
      controller.projects.single.id,
    );
    expect(status, CommandStatus.failed);
    expect(controller.projects, hasLength(1));
    expect(controller.lastFailureMessage, FailureText.storage);
  });

  test('通知点击目标可从宿主缓存取回且只取一次', () async {
    repository.pendingNotificationRun = 42;
    expect(await controller.consumePendingNotificationRun(), 42);
    expect(await controller.consumePendingNotificationRun(), isNull);
  });

  test('后台暂停停止每秒刷新，回到前台重新校准', () async {
    await controller.load();
    controller.onAppPaused();
    repository.clockElapsed += 5000;
    await controller.onAppResumed();
    expect(controller.loading, isFalse);
  });
}
