/// 应用状态控制器：维护项目列表、当前运行快照和每秒时钟刷新。
///
/// 页面只读取本类暴露的状态并调用命令方法；持久化与系统提醒都经 [repository]
/// 边界完成。控制器不在失败时伪造成功：命令返回 [CommandStatus.failed] 并给出
/// 面向用户的失败原因，调用方据此保留输入或目标。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'repository.dart';
import 'time_format.dart';

/// 命令结果。
enum CommandStatus { success, failed }

/// 失败原因（面向用户的简短说明）。
abstract final class FailureText {
  static const String runAlreadyActive = '已有一项正在计时，请先结束它。';
  static const String projectGone = '该项目已不存在，已返回列表。';
  static const String invalidProject = '名称或时长不合法，请检查后重试。';
  static const String runNotRunning = '该计时已结束，请重新开始。';
  static const String noActiveRun = '没有正在进行的计时。';
  static const String storage = '操作失败，请重试。';
}

/// 列表、运行与提醒的唯一状态来源。
class CountdownController extends ChangeNotifier {
  CountdownController(this._repository)
    : _clockNotifier = ValueNotifier<ClockReading>(
        const ClockReading(elapsedMillis: 0, utcMillis: 0, bootCount: -1),
      );

  final CountdownRepository _repository;

  /// 每秒推进的时钟读数。只有计时文字监听它，避免整页每秒重建。
  final ValueNotifier<ClockReading> _clockNotifier;

  ValueListenable<ClockReading> get clockListenable => _clockNotifier;

  AppSnapshot? _snapshot;
  bool _loading = true;
  Object? _loadError;
  bool _busy = false;
  String? _lastFailureMessage;

  final Stopwatch _stopwatch = Stopwatch();
  int _anchorElapsedMillis = 0;
  int _anchorUtcMillis = 0;
  Timer? _ticker;

  /// 已完成归零收尾的运行，避免每秒重复提交。
  final Set<int> _finalizedRunIds = <int>{};

  /// 已在前台认领提醒的运行。
  final Set<int> _claimedRunIds = <int>{};

  bool _disposed = false;

  List<CountdownProject> get projects =>
      _snapshot?.projects ?? const <CountdownProject>[];
  RunSnapshot? get activeRun => _snapshot?.activeRun;
  bool get loading => _loading;
  Object? get loadError => _loadError;
  bool get busy => _busy;
  String? get lastFailureMessage => _lastFailureMessage;

  /// 当前运行是否处于暂停状态。
  bool get isPaused => activeRun?.paused ?? false;

  /// 是否已有占用主区的运行（运行中或暂停中，且尚未归零）。
  bool get hasActiveRun {
    final RunSnapshot? run = activeRun;
    if (run == null) {
      return false;
    }
    return _clockNotifier.value.remainingMillisOf(run) > 0;
  }

  /// 列表页需要的主计时卡剩余毫秒数；没有可见运行时为 0。
  int get mainCardRemainingMillis {
    final RunSnapshot? run = activeRun;
    if (run == null) {
      return 0;
    }
    final int remaining = _clockNotifier.value.remainingMillisOf(run);
    return remaining > 0 ? remaining : 0;
  }

  /// 主计时卡是否处于提醒区间（数字变红）。
  bool get mainCardWithinReminder =>
      activeRun != null &&
      isWithinReminderWindow(
        remainingMillis: _clockNotifier.value.remainingMillisOf(activeRun!),
        thresholdMillis: activeRun!.reminderThresholdMillis,
      );

  /// 当前是否需要显示提前提醒提示条。
  bool get bannerVisible {
    final RunSnapshot? run = activeRun;
    if (run == null) {
      return false;
    }
    return run.reminderDelivery == ReminderDelivery.foreground &&
        !run.bannerDismissed &&
        _clockNotifier.value.remainingMillisOf(run) > 0;
  }

  /// 通知点击目标（运行 ID）流，由入口装配层订阅并决定跳转。
  Stream<int> get notificationOpens => _repository.notificationOpens;

  /// 取走冷启动前缓存的通知点击目标（运行 ID），没有则返回 null。
  Future<int?> consumePendingNotificationRun() async {
    try {
      return await _repository.consumePendingNotificationRun();
    } catch (_) {
      return null;
    }
  }

  /// 首次进入或页面需要完整刷新时调用。
  Future<void> load() async {
    _loading = true;
    _loadError = null;
    _notify();
    try {
      final AppSnapshot snapshot = await _repository.snapshot();
      _applySnapshot(snapshot);
      _loading = false;
      _loadError = null;
      _startTicker();
      unawaited(_evaluateActiveRun());
    } catch (error) {
      _loading = false;
      _loadError = error;
    }
    _notify();
  }

  /// 重新读取快照并按真实经过时间校准，不重建页面结构。
  Future<void> refresh() async {
    try {
      final AppSnapshot snapshot = await _repository.snapshot();
      _applySnapshot(snapshot);
      _notify();
      unawaited(_evaluateActiveRun());
    } catch (error) {
      _loadError = error;
      _notify();
    }
  }

  /// 应用回到前台：重读快照、重新校准时钟并补登记本轮的提醒闹钟。
  Future<void> onAppResumed() async {
    await refresh();
    final RunSnapshot? run = activeRun;
    if (run != null && run.reminderEnabled) {
      await _ensureReminderScheduled(run.runId);
    }
    _startTicker();
  }

  /// 应用退到后台：停止每秒刷新，避免无意义的后台重绘。
  void onAppPaused() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// 保存新项目。校验已在表单完成，宿主还会再校验一次。
  Future<CommandStatus> createProject({
    required String name,
    required int totalSeconds,
    required int? reminderSeconds,
  }) async {
    if (_busy) {
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      await _repository.createProject(
        name: name,
        totalSeconds: totalSeconds,
        reminderSeconds: reminderSeconds,
      );
      await refresh();
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 启动新一轮运行。
  Future<CommandStatus> startRun(int projectId) async {
    if (_busy) {
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      final RunSnapshot run = await _repository.startRun(projectId);
      _finalizedRunIds.remove(run.runId);
      _claimedRunIds.remove(run.runId);
      await refresh();
      if (run.reminderEnabled) {
        await _ensureReminderScheduled(run.runId);
      }
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      if (error.code == CountdownErrorCode.runAlreadyActive ||
          error.code == CountdownErrorCode.projectNotFound) {
        await refresh();
      }
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 首页滚轮快启：用选出的时长启动一轮临时运行。
  ///
  /// 临时运行不写入常用列表、默认关闭提前提醒，取消或归零后由宿主清理。
  Future<CommandStatus> startTemporaryRun(int totalSeconds) async {
    if (_busy) {
      return CommandStatus.failed;
    }
    if (totalSeconds <= 0) {
      _lastFailureMessage = FailureText.invalidProject;
      _notify();
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      final RunSnapshot run = await _repository.startTemporaryRun(totalSeconds);
      _finalizedRunIds.remove(run.runId);
      _claimedRunIds.remove(run.runId);
      await refresh();
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      if (error.code == CountdownErrorCode.runAlreadyActive) {
        await refresh();
      }
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 暂停当前运行：冻结剩余时间并撤销本轮待发闹钟。
  Future<CommandStatus> pauseRun() => _runControlCommand(
    (int runId) => _repository.pauseRun(runId),
    scheduleReminder: false,
  );

  /// 继续当前运行：从冻结值重建截止点，并按新截止点重算未投递的提醒。
  Future<CommandStatus> resumeRun() => _runControlCommand(
    (int runId) => _repository.resumeRun(runId),
    scheduleReminder: true,
  );

  /// 重新计时：从本轮最初的总时长立即开始新一轮（新的运行 ID）。
  Future<CommandStatus> restartRun() => _runControlCommand(
    (int runId) => _repository.restartRun(runId),
    scheduleReminder: true,
  );

  /// 取消当前运行：结束本轮、撤销提醒；常用项回到可再次启动状态。
  Future<CommandStatus> cancelRun() async {
    final RunSnapshot? run = activeRun;
    if (run == null) {
      _lastFailureMessage = FailureText.noActiveRun;
      _notify();
      return CommandStatus.failed;
    }
    if (_busy) {
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      await _repository.cancelRun(run.runId);
      await refresh();
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      await refresh();
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 暂停/继续/重新计时共用的命令外壳：防重、失败保留快照、成功按需重登记提醒。
  Future<CommandStatus> _runControlCommand(
    Future<RunSnapshot> Function(int runId) action, {
    required bool scheduleReminder,
  }) async {
    final RunSnapshot? current = activeRun;
    if (current == null) {
      _lastFailureMessage = FailureText.noActiveRun;
      _notify();
      return CommandStatus.failed;
    }
    if (_busy) {
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      final RunSnapshot updated = await action(current.runId);
      _finalizedRunIds.remove(updated.runId);
      _claimedRunIds.remove(updated.runId);
      await refresh();
      if (scheduleReminder && updated.reminderEnabled && !updated.paused) {
        await _ensureReminderScheduled(updated.runId);
      }
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      // 命令可能因归零/结束而失败，重读后让页面显示真实状态。
      await refresh();
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 确认删除项目（含其运行、待发提醒与已展示通知）。
  Future<CommandStatus> deleteProject(int projectId) async {
    if (_busy) {
      return CommandStatus.failed;
    }
    _busy = true;
    _lastFailureMessage = null;
    _notify();
    try {
      await _repository.deleteProject(projectId);
      await refresh();
      return CommandStatus.success;
    } on CountdownRepositoryException catch (error) {
      _lastFailureMessage = _messageFor(error.code);
      return CommandStatus.failed;
    } catch (_) {
      _lastFailureMessage = FailureText.storage;
      return CommandStatus.failed;
    } finally {
      _busy = false;
      _notify();
    }
  }

  /// 收起提示条：只影响本轮的提示展示，红色数字保留至归零。
  Future<void> dismissBanner() async {
    final RunSnapshot? run = activeRun;
    if (run == null) {
      return;
    }
    try {
      await _repository.dismissBanner(run.runId);
    } on CountdownRepositoryException {
      // 收起失败不改变红字与计时，只记录到快照，下一次刷新再对齐。
    }
    await refresh();
  }

  /// 用户开启提前提醒时请求通知权限；拒绝后仍保留计时与前台提示能力。
  Future<NotificationPermission> requestNotificationPermission() async {
    try {
      return await _repository.requestNotificationPermission();
    } catch (_) {
      return NotificationPermission.denied;
    }
  }

  /// 读取当前通知权限，不触发系统弹窗。
  Future<NotificationPermission> notificationPermission() async {
    try {
      return await _repository.notificationPermission();
    } catch (_) {
      return NotificationPermission.denied;
    }
  }

  void clearFailureMessage() {
    if (_lastFailureMessage != null) {
      _lastFailureMessage = null;
      _notify();
    }
  }

  // ---- 内部实现 ----

  String _messageFor(String code) => switch (code) {
    CountdownErrorCode.runAlreadyActive => FailureText.runAlreadyActive,
    CountdownErrorCode.projectNotFound => FailureText.projectGone,
    CountdownErrorCode.invalidProject => FailureText.invalidProject,
    CountdownErrorCode.runNotRunning => FailureText.runNotRunning,
    CountdownErrorCode.runNotFound => FailureText.runNotRunning,
    _ => FailureText.storage,
  };

  void _applySnapshot(AppSnapshot snapshot) {
    _snapshot = snapshot;
    _anchorElapsedMillis = snapshot.clock.elapsedMillis;
    _anchorUtcMillis = snapshot.clock.utcMillis;
    _stopwatch
      ..reset()
      ..start();
    _clockNotifier.value = snapshot.clock;
  }

  void _startTicker() {
    if (_disposed || _ticker != null) {
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) {
        return;
      }
      final int advanced = _stopwatch.elapsedMilliseconds;
      _clockNotifier.value = ClockReading(
        elapsedMillis: _anchorElapsedMillis + advanced,
        utcMillis: _anchorUtcMillis + advanced,
        bootCount: _snapshot?.clock.bootCount ?? -1,
      );
      unawaited(_evaluateActiveRun());
    });
  }

  /// 每秒检查一次运行状态：归零收尾、提醒认领。只在状态真正变化时通知页面。
  ///
  /// 暂停中的剩余时间是冻结值，不会归零，也不在暂停期间认领新的提醒：
  /// 继续后按新的截止点重新判断。
  Future<void> _evaluateActiveRun() async {
    final RunSnapshot? run = activeRun;
    if (run == null || run.paused) {
      return;
    }
    final int remaining = _clockNotifier.value.remainingMillisOf(run);
    if (remaining <= 0) {
      await _finalizeRun(run);
      return;
    }
    if (!run.reminderEnabled) {
      return;
    }
    if (run.reminderDelivery != ReminderDelivery.none) {
      return;
    }
    if (!isWithinReminderWindow(
      remainingMillis: remaining,
      thresholdMillis: run.reminderThresholdMillis,
    )) {
      return;
    }
    if (_claimedRunIds.contains(run.runId)) {
      return;
    }
    _claimedRunIds.add(run.runId);
    try {
      final bool claimed = await _repository.claimForegroundReminder(run.runId);
      if (claimed) {
        await refresh();
      }
    } catch (_) {
      // 认领失败时保留红字；下一次刷新会重新读取持久状态。
      _claimedRunIds.remove(run.runId);
    }
  }

  /// 归零收尾：把运行置为已结束，列表恢复为「已结束」而不是负数。
  Future<void> _finalizeRun(RunSnapshot run) async {
    if (_finalizedRunIds.contains(run.runId)) {
      return;
    }
    _finalizedRunIds.add(run.runId);
    try {
      await _repository.finishRun(run.runId);
    } catch (_) {
      // 结束提交失败时保留原快照，下一轮 tick 或回到前台时会重试。
      _finalizedRunIds.remove(run.runId);
      return;
    }
    await refresh();
  }

  Future<void> _ensureReminderScheduled(int runId) async {
    try {
      await _repository.ensureReminderScheduled(runId);
    } catch (_) {
      // 登记失败时前台红字与提示条仍然可用；下一次进入前台会重试。
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _stopwatch.stop();
    _clockNotifier.dispose();
    _repository.dispose();
    super.dispose();
  }
}
