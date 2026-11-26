/// 测试替身：内存仓储，时钟可控，便于在不触达平台通道的情况下驱动控制器。
///
/// 只用于测试；生产路径始终使用 `PlatformCountdownRepository`。
library;

import 'dart:async';

import 'package:countdown_app/countdown/model.dart';
import 'package:countdown_app/countdown/repository.dart';

/// 内存仓储。写操作记录到调用列表，便于断言“是否真的提交”。
class FakeCountdownRepository implements CountdownRepository {
  FakeCountdownRepository();

  int clockElapsed = 10000;
  int clockUtc = 1700000000000;
  int bootCount = 3;

  List<CountdownProject> projects = <CountdownProject>[];
  RunSnapshot? activeRun;

  ReminderScheduleResult scheduleResult = ReminderScheduleResult.scheduledExact;
  CountdownRepositoryException? nextCreateError;
  CountdownRepositoryException? nextStartError;
  CountdownRepositoryException? nextDeleteError;
  bool claimForeground = true;
  NotificationPermission permission = NotificationPermission.granted;
  int? pendingNotificationRun;

  final List<int> scheduledRuns = <int>[];
  final List<int> finishedRuns = <int>[];
  final List<int> dismissedBanners = <int>[];
  final List<int> deletedProjects = <int>[];
  final List<int> pausedRuns = <int>[];
  final List<int> resumedRuns = <int>[];
  final List<int> restartedRuns = <int>[];
  final List<int> cancelledRuns = <int>[];
  final List<int> temporaryRunStarts = <int>[];
  final StreamController<int> _opens = StreamController<int>.broadcast();

  /// 临时快启项目的 id；null 表示当前没有临时项目（与常用列表分开保存）。
  int? temporaryProjectId;
  int _nextRunId = 42;

  ClockReading get _clock => ClockReading(
    elapsedMillis: clockElapsed,
    utcMillis: clockUtc,
    bootCount: bootCount,
  );

  /// 直接放入一条运行记录，供页面测试构造确定的时间读数。
  void seedRun({
    required int runId,
    required String name,
    required int totalSeconds,
    required int remainingSeconds,
    int? reminderSeconds,
    ReminderDelivery delivery = ReminderDelivery.none,
    bool bannerDismissed = false,
    bool paused = false,
    int projectId = 1,
  }) {
    activeRun = RunSnapshot(
      runId: runId,
      projectId: projectId,
      projectName: name,
      totalSeconds: totalSeconds,
      startElapsedMillis:
          clockElapsed - (totalSeconds - remainingSeconds) * 1000,
      deadlineElapsedMillis: clockElapsed + remainingSeconds * 1000,
      deadlineUtcMillis: clockUtc + remainingSeconds * 1000,
      bootCount: bootCount,
      reminderThresholdMillis: reminderSeconds == null
          ? null
          : reminderSeconds * 1000,
      reminderDelivery: delivery,
      bannerDismissed: bannerDismissed,
      paused: paused,
      pausedRemainingMillis: paused ? remainingSeconds * 1000 : null,
    );
  }

  @override
  Future<AppSnapshot> snapshot() async {
    return AppSnapshot(
      projects: List<CountdownProject>.unmodifiable(projects),
      activeRun: activeRun,
      clock: _clock,
    );
  }

  @override
  Future<CountdownProject> createProject({
    required String name,
    required int totalSeconds,
    required int? reminderSeconds,
  }) async {
    final CountdownRepositoryException? error = nextCreateError;
    if (error != null) {
      nextCreateError = null;
      throw error;
    }
    // 与宿主同一契约：0 < reminderSeconds < totalSeconds。
    if (totalSeconds <= 0 ||
        (reminderSeconds != null &&
            (reminderSeconds <= 0 || reminderSeconds >= totalSeconds))) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.invalidProject,
      );
    }
    final CountdownProject project = CountdownProject(
      id: projects.length + 1,
      name: name,
      totalSeconds: totalSeconds,
      reminderSeconds: reminderSeconds,
      createdAtUtcMillis: clockUtc,
      state: ProjectState.idle,
    );
    projects = <CountdownProject>[project, ...projects];
    return project;
  }

  @override
  Future<RunSnapshot> startRun(int projectId) async {
    final CountdownRepositoryException? error = nextStartError;
    if (error != null) {
      nextStartError = null;
      throw error;
    }
    if (activeRun != null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.runAlreadyActive,
      );
    }
    final CountdownProject project = projects.firstWhere(
      (CountdownProject item) => item.id == projectId,
    );
    final RunSnapshot run = RunSnapshot(
      runId: _nextRunId++,
      projectId: project.id,
      projectName: project.name,
      totalSeconds: project.totalSeconds,
      startElapsedMillis: clockElapsed,
      deadlineElapsedMillis: clockElapsed + project.totalSeconds * 1000,
      deadlineUtcMillis: clockUtc + project.totalSeconds * 1000,
      bootCount: bootCount,
      reminderThresholdMillis: project.reminderSeconds == null
          ? null
          : project.reminderSeconds! * 1000,
      reminderDelivery: ReminderDelivery.none,
      bannerDismissed: false,
    );
    activeRun = run;
    projects = projects
        .where((CountdownProject item) => item.id != projectId)
        .toList(growable: false);
    return run;
  }

  @override
  Future<RunSnapshot> startTemporaryRun(int totalSeconds) async {
    if (totalSeconds <= 0) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.invalidProject,
      );
    }
    if (activeRun != null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.runAlreadyActive,
      );
    }
    temporaryRunStarts.add(totalSeconds);
    temporaryProjectId = 9000;
    final RunSnapshot run = RunSnapshot(
      runId: _nextRunId++,
      projectId: temporaryProjectId!,
      projectName: temporaryRunName,
      totalSeconds: totalSeconds,
      startElapsedMillis: clockElapsed,
      deadlineElapsedMillis: clockElapsed + totalSeconds * 1000,
      deadlineUtcMillis: clockUtc + totalSeconds * 1000,
      bootCount: bootCount,
      reminderThresholdMillis: null,
      reminderDelivery: ReminderDelivery.none,
      bannerDismissed: false,
    );
    activeRun = run;
    return run;
  }

  @override
  Future<RunSnapshot> pauseRun(int runId) async {
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      throw const CountdownRepositoryException(CountdownErrorCode.runNotFound);
    }
    if (run.paused) {
      return run;
    }
    final int remaining = _clock.remainingMillisOf(run);
    if (remaining <= 0) {
      await finishRun(runId);
      throw const CountdownRepositoryException(
        CountdownErrorCode.runNotRunning,
      );
    }
    pausedRuns.add(runId);
    final RunSnapshot paused = _copyRun(
      run,
      paused: true,
      pausedRemainingMillis: remaining,
    );
    activeRun = paused;
    return paused;
  }

  @override
  Future<RunSnapshot> resumeRun(int runId) async {
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      throw const CountdownRepositoryException(CountdownErrorCode.runNotFound);
    }
    if (!run.paused) {
      return run;
    }
    final int remaining = run.pausedRemainingMillis ?? 0;
    if (remaining <= 0) {
      await finishRun(runId);
      throw const CountdownRepositoryException(
        CountdownErrorCode.runNotRunning,
      );
    }
    resumedRuns.add(runId);
    final RunSnapshot resumed = _copyRun(
      run,
      paused: false,
      deadlineElapsedMillis: clockElapsed + remaining,
      deadlineUtcMillis: clockUtc + remaining,
      clearPausedRemaining: true,
    );
    activeRun = resumed;
    return resumed;
  }

  @override
  Future<RunSnapshot> restartRun(int runId) async {
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      throw const CountdownRepositoryException(CountdownErrorCode.runNotFound);
    }
    restartedRuns.add(runId);
    final RunSnapshot restarted = RunSnapshot(
      runId: _nextRunId++,
      projectId: run.projectId,
      projectName: run.projectName,
      totalSeconds: run.totalSeconds,
      startElapsedMillis: clockElapsed,
      deadlineElapsedMillis: clockElapsed + run.totalSeconds * 1000,
      deadlineUtcMillis: clockUtc + run.totalSeconds * 1000,
      bootCount: bootCount,
      reminderThresholdMillis: run.reminderThresholdMillis,
      reminderDelivery: ReminderDelivery.none,
      bannerDismissed: false,
    );
    activeRun = restarted;
    return restarted;
  }

  @override
  Future<void> cancelRun(int runId) async {
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      return;
    }
    cancelledRuns.add(runId);
    activeRun = null;
    final bool temporary =
        temporaryProjectId != null && run.projectId == temporaryProjectId;
    if (temporary) {
      temporaryProjectId = null;
      return;
    }
    projects = <CountdownProject>[
      CountdownProject(
        id: run.projectId,
        name: run.projectName,
        totalSeconds: run.totalSeconds,
        reminderSeconds: run.reminderThresholdMillis == null
            ? null
            : run.reminderThresholdMillis! ~/ 1000,
        createdAtUtcMillis: clockUtc,
        state: ProjectState.idle,
      ),
      ...projects,
    ];
  }

  @override
  Future<void> finishRun(int runId) async {
    finishedRuns.add(runId);
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      return;
    }
    activeRun = null;
    if (temporaryProjectId != null && run.projectId == temporaryProjectId) {
      // 临时快启项目归零后不进入常用列表。
      temporaryProjectId = null;
      return;
    }
    projects = <CountdownProject>[
      CountdownProject(
        id: run.projectId,
        name: run.projectName,
        totalSeconds: run.totalSeconds,
        reminderSeconds: run.reminderThresholdMillis == null
            ? null
            : run.reminderThresholdMillis! ~/ 1000,
        createdAtUtcMillis: clockUtc,
        state: ProjectState.finished,
      ),
      ...projects,
    ];
  }

  @override
  Future<void> deleteProject(int projectId) async {
    final CountdownRepositoryException? error = nextDeleteError;
    if (error != null) {
      nextDeleteError = null;
      throw error;
    }
    deletedProjects.add(projectId);
    projects = projects
        .where((CountdownProject item) => item.id != projectId)
        .toList(growable: false);
    if (activeRun?.projectId == projectId) {
      activeRun = null;
    }
  }

  @override
  Future<bool> claimForegroundReminder(int runId) async {
    final RunSnapshot? run = activeRun;
    if (!claimForeground || run == null || run.runId != runId) {
      return false;
    }
    if (run.reminderDelivery != ReminderDelivery.none) {
      return false;
    }
    activeRun = _copyRun(run, delivery: ReminderDelivery.foreground);
    return true;
  }

  @override
  Future<void> dismissBanner(int runId) async {
    dismissedBanners.add(runId);
    final RunSnapshot? run = activeRun;
    if (run == null || run.runId != runId) {
      return;
    }
    activeRun = _copyRun(run, bannerDismissed: true);
  }

  RunSnapshot _copyRun(
    RunSnapshot run, {
    ReminderDelivery? delivery,
    bool? bannerDismissed,
    bool? paused,
    int? pausedRemainingMillis,
    int? deadlineElapsedMillis,
    int? deadlineUtcMillis,
    bool clearPausedRemaining = false,
  }) {
    return RunSnapshot(
      runId: run.runId,
      projectId: run.projectId,
      projectName: run.projectName,
      totalSeconds: run.totalSeconds,
      startElapsedMillis: run.startElapsedMillis,
      deadlineElapsedMillis: deadlineElapsedMillis ?? run.deadlineElapsedMillis,
      deadlineUtcMillis: deadlineUtcMillis ?? run.deadlineUtcMillis,
      bootCount: run.bootCount,
      reminderThresholdMillis: run.reminderThresholdMillis,
      reminderDelivery: delivery ?? run.reminderDelivery,
      bannerDismissed: bannerDismissed ?? run.bannerDismissed,
      paused: paused ?? run.paused,
      pausedRemainingMillis: clearPausedRemaining
          ? null
          : (pausedRemainingMillis ?? run.pausedRemainingMillis),
    );
  }

  @override
  Future<ReminderScheduleResult> ensureReminderScheduled(int runId) async {
    scheduledRuns.add(runId);
    return scheduleResult;
  }

  @override
  Future<NotificationPermission> notificationPermission() async => permission;

  @override
  Future<NotificationPermission> requestNotificationPermission() async =>
      permission;

  @override
  Future<bool> canScheduleExactAlarms() async => true;

  @override
  Stream<int> get notificationOpens => _opens.stream;

  @override
  Future<int?> consumePendingNotificationRun() async {
    final int? runId = pendingNotificationRun;
    pendingNotificationRun = null;
    return runId;
  }

  @override
  Future<ClockReading> clock() async => _clock;

  @override
  void dispose() {
    _opens.close();
  }

  /// 模拟宿主向 Flutter 推送通知点击。
  void emitNotificationOpen(int runId) {
    _opens.add(runId);
  }
}

/// 让控制器的异步链（快照读取、认领、收尾）跑完。
Future<void> settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
