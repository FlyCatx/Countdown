/// 倒计时项目、运行记录与时钟读数的数据模型。
///
/// 字段与宿主 SQLite 表（projects / runs / reminders）一一对应，宿主通过
/// `countdown/storage` 通道以 Map 形式传输；本文件负责把 Map 还原成强类型对象，
/// 并集中定义运行剩余时间的时钟换算规则（含暂停后的冻结值）。
library;

/// 临时快启项目的名称。快启按单个运行存在，取消或归零后不进入常用列表。
const String temporaryRunName = '倒计时';

/// 项目在列表中的展示状态。运行中的项目不出现在列表里，由当前运行快照表达。
enum ProjectState {
  /// 没有进行中的运行，也没有已结束的历史运行（含被取消或重新计时的旧轮）。
  idle,

  /// 最近一轮运行已经结束（归零或已被判定过期），列表显示 00:00:00。
  finished,
}

/// 一轮提前提醒的投递方。用于前台提示条与系统通知之间的去重。
enum ReminderDelivery {
  /// 尚未投递。
  none,

  /// 前台运行页认领，用屏内提示条表达。
  foreground,

  /// 后台接收器认领，用系统通知表达。
  notification,
}

/// 一条倒计时项目。
class CountdownProject {
  const CountdownProject({
    required this.id,
    required this.name,
    required this.totalSeconds,
    required this.reminderSeconds,
    required this.createdAtUtcMillis,
    required this.state,
  });

  /// 持久化主键，删除与运行都以此为准，不使用列表下标。
  final int id;
  final String name;
  final int totalSeconds;

  /// 提前提醒阈值：提醒触发时距离归零的剩余**秒数**，null 表示关闭提醒。
  ///
  /// 宿主以项目总秒数与阈值秒数做合法性校验：`0 < reminderSeconds < totalSeconds`。
  final int? reminderSeconds;
  final int createdAtUtcMillis;
  final ProjectState state;

  bool get reminderEnabled => reminderSeconds != null;

  factory CountdownProject.fromMap(Map<Object?, Object?> map) {
    final Object? state = map['state'];
    return CountdownProject(
      id: map['id']! as int,
      name: map['name']! as String,
      totalSeconds: map['totalSeconds']! as int,
      reminderSeconds: map['reminderSeconds'] as int?,
      createdAtUtcMillis: map['createdAtUtcMillis']! as int,
      state: state == 'finished' ? ProjectState.finished : ProjectState.idle,
    );
  }
}

/// 一轮运行的持久快照。所有页面共用同一条记录，重新计时会分配新的 [runId]。
class RunSnapshot {
  const RunSnapshot({
    required this.runId,
    required this.projectId,
    required this.projectName,
    required this.totalSeconds,
    required this.startElapsedMillis,
    required this.deadlineElapsedMillis,
    required this.deadlineUtcMillis,
    required this.bootCount,
    required this.reminderThresholdMillis,
    required this.reminderDelivery,
    required this.bannerDismissed,
    this.paused = false,
    this.pausedRemainingMillis,
  });

  final int runId;
  final int projectId;
  final String projectName;
  final int totalSeconds;

  /// 开始时刻的 `SystemClock.elapsedRealtime()`，用于同次开机内的单调计时。
  final int startElapsedMillis;

  /// 截止时刻的单调时钟值，仅在 [bootCount] 与当前开机计数一致且未暂停时有效。
  final int deadlineElapsedMillis;

  /// 截止时刻的 UTC 毫秒值，跨重启时用于重新校准。
  final int deadlineUtcMillis;

  /// 运行开始（或继续）时的开机计数（`Settings.Global.BOOT_COUNT`）。
  final int bootCount;

  /// 提前提醒阈值毫秒数，null 表示本轮未开启提醒。
  final int? reminderThresholdMillis;
  final ReminderDelivery reminderDelivery;

  /// 提示条是否已被用户收起；同一轮收起后不再弹出。
  final bool bannerDismissed;

  /// 本轮是否处于暂停状态。暂停期间剩余时间是冻结快照，不随时间变化。
  final bool paused;

  /// 暂停时冻结的剩余毫秒数；仅在 [paused] 为 true 时有值。
  final int? pausedRemainingMillis;

  bool get reminderEnabled => reminderThresholdMillis != null;

  /// 提醒数字应当变红：开启提醒且在未取整的剩余时间内已进入阈值区间。
  bool get withinReminderWindow {
    final int? threshold = reminderThresholdMillis;
    final int remaining;
    if (paused) {
      remaining = pausedRemainingMillis ?? 0;
    } else {
      // 运行中的红字由页面按实时时钟判断；此处仅用于暂停态的静态判断。
      return false;
    }
    return threshold != null && remaining > 0 && remaining <= threshold;
  }

  factory RunSnapshot.fromMap(Map<Object?, Object?> map) {
    return RunSnapshot(
      runId: map['runId']! as int,
      projectId: map['projectId']! as int,
      projectName: map['projectName']! as String,
      totalSeconds: map['totalSeconds']! as int,
      startElapsedMillis: map['startElapsedMillis']! as int,
      deadlineElapsedMillis: map['deadlineElapsedMillis']! as int,
      deadlineUtcMillis: map['deadlineUtcMillis']! as int,
      bootCount: map['bootCount']! as int,
      reminderThresholdMillis: map['reminderThresholdMillis'] as int?,
      reminderDelivery: switch (map['reminderDelivery'] as String?) {
        'foreground' => ReminderDelivery.foreground,
        'notification' => ReminderDelivery.notification,
        _ => ReminderDelivery.none,
      },
      bannerDismissed: map['bannerDismissed'] == true,
      paused: map['paused'] == true,
      pausedRemainingMillis: map['pausedRemainingMillis'] as int?,
    );
  }
}

/// 一次时钟读数：单调经过时间、UTC 时刻和开机计数。
class ClockReading {
  const ClockReading({
    required this.elapsedMillis,
    required this.utcMillis,
    required this.bootCount,
  });

  final int elapsedMillis;
  final int utcMillis;
  final int bootCount;

  factory ClockReading.fromMap(Map<Object?, Object?> map) {
    return ClockReading(
      elapsedMillis: map['elapsedMillis']! as int,
      utcMillis: map['utcMillis']! as int,
      bootCount: map['bootCount']! as int,
    );
  }

  /// 本轮剩余毫秒数，可能为负或超过总时长。
  ///
  /// 暂停时返回冻结值，与时钟无关；同次开机用单调时钟相减，手动调系统时间不会
  /// 改变倒数；开机计数变化（设备重启过）时退回持久 UTC 截止值重新校准。
  int remainingMillisOf(RunSnapshot run) {
    if (run.paused) {
      return run.pausedRemainingMillis ?? 0;
    }
    if (run.bootCount == bootCount) {
      return run.deadlineElapsedMillis - elapsedMillis;
    }
    return run.deadlineUtcMillis - utcMillis;
  }

  ClockReading advancedBy(int deltaMillis) {
    return ClockReading(
      elapsedMillis: elapsedMillis + deltaMillis,
      utcMillis: utcMillis + deltaMillis,
      bootCount: bootCount,
    );
  }
}

/// 一次完整读取的结果：项目列表、当前运行和读取时钟。
class AppSnapshot {
  const AppSnapshot({
    required this.projects,
    required this.activeRun,
    required this.clock,
  });

  /// 按创建时间从新到旧排序，不含正在运行的项目（该项目由 [activeRun] 表达），
  /// 也不含临时快启项目——它们不属于常用列表。
  final List<CountdownProject> projects;
  final RunSnapshot? activeRun;
  final ClockReading clock;

  factory AppSnapshot.fromMap(Map<Object?, Object?> map) {
    final Object? projects = map['projects'];
    final Object? activeRun = map['activeRun'];
    final Object? clock = map['clock'];
    return AppSnapshot(
      projects: projects is List
          ? projects
                .map(
                  (Object? item) => CountdownProject.fromMap(
                    (item! as Map<Object?, Object?>),
                  ),
                )
                .toList(growable: false)
          : const <CountdownProject>[],
      activeRun: activeRun is Map<Object?, Object?>
          ? RunSnapshot.fromMap(activeRun)
          : null,
      clock: clock is Map<Object?, Object?>
          ? ClockReading.fromMap(clock)
          : const ClockReading(elapsedMillis: 0, utcMillis: 0, bootCount: -1),
    );
  }

  /// 只有存在运行且尚未归零时，列表才需要隐藏该项目（它显示在主卡）。
  bool isRunVisible(RunSnapshot? run) =>
      run != null && remainingMillisOf(run) > 0;

  int remainingMillisOf(RunSnapshot? run) =>
      run == null ? 0 : clock.remainingMillisOf(run);
}
