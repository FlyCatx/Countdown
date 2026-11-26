/// 仓储边界：页面与控制器只通过本接口读写业务数据，不直接接触平台通道。
///
/// 平台侧（`android/app/src/main/kotlin`）承担统一写入：项目、运行记录与提醒
/// 投递状态都保存在宿主 SQLite 中，系统闹钟唤起的接收器与 Flutter 前台共用
/// 同一份数据。通道契约见各方法注释，宿主实现必须逐条满足。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'model.dart';

/// 宿主返回的业务错误。页面据此保留用户输入并提示重试，不伪造成功。
class CountdownRepositoryException implements Exception {
  const CountdownRepositoryException(this.code, [this.message = '']);

  /// 宿主错误码，见 [CountdownErrorCode]。
  final String code;
  final String message;

  @override
  String toString() => 'CountdownRepositoryException($code, $message)';
}

/// 宿主可能返回的错误码。
abstract final class CountdownErrorCode {
  /// 参数校验失败（名称为空、时长非法、提醒阈值非法）。
  static const String invalidProject = 'invalid_project';

  /// 目标项目不存在（可能已被删除）。
  static const String projectNotFound = 'project_not_found';

  /// 已有一轮运行尚未结束，按“一次运行一个”的决策拒绝重复启动。
  static const String runAlreadyActive = 'run_already_active';

  /// 目标运行不存在或已经结束。
  static const String runNotFound = 'run_not_found';

  /// 目标运行不在可执行该命令的状态（例如对已归零的运行暂停、对未暂停的运行继续）。
  static const String runNotRunning = 'run_not_running';

  /// 数据库读写失败。
  static const String storageFailure = 'storage_failure';
}

/// 通知权限状态。
enum NotificationPermission {
  /// 系统不需要运行时授权（API 32 及以下）。
  notRequired,

  /// 用户已授权。
  granted,

  /// 用户拒绝或尚未授权。
  denied,
}

/// 提前提醒闹钟的实际登记结果。
enum ReminderScheduleResult {
  /// 精确闹钟已登记。
  scheduledExact,

  /// 精确闹钟受限，登记了允许空闲投递的非精确闹钟，可能延迟。
  scheduledInexact,

  /// 没有需要登记的时刻（未开启提醒、已过阈值或运行已结束）。
  notScheduled,
}

/// 业务数据与系统提醒的读写接口。
abstract class CountdownRepository {
  /// 读取完整快照：项目列表、当前运行和一次时钟读数。
  ///
  /// 只读，不修改任何持久状态。项目列表按创建时间从新到旧排序，并且不含
  /// 仍有剩余时间的运行项目（该项目通过 [AppSnapshot.activeRun] 表达）。
  Future<AppSnapshot> snapshot();

  /// 保存新项目。
  ///
  /// [name] 已由调用方去除首尾空格；[totalSeconds] 必须大于 0；
  /// [reminderSeconds] 为 null 表示关闭提醒，否则必须是大于 0 且严格小于
  /// 总时长的整数秒（提醒触发时的剩余秒数）。失败抛 [CountdownRepositoryException]。
  Future<CountdownProject> createProject({
    required String name,
    required int totalSeconds,
    required int? reminderSeconds,
  });

  /// 启动新一轮运行。
  ///
  /// 宿主在同一事务内分配运行 ID 与截止点；若已有一轮未结束的运行，抛
  /// [CountdownErrorCode.runAlreadyActive]。已过截止点的旧运行会先被置为已结束。
  Future<RunSnapshot> startRun(int projectId);

  /// 用滚轮选出的时长启动一轮临时运行（首页快启）。
  ///
  /// 宿主创建一条仅用于本轮的临时项目（名称 [temporaryRunName]、关闭提醒），
  /// 它不会出现在常用列表里；取消或归零后由宿主删除。已有一轮未结束时抛
  /// [CountdownErrorCode.runAlreadyActive]；[totalSeconds] 必须大于 0。
  Future<RunSnapshot> startTemporaryRun(int totalSeconds);

  /// 暂停本轮：按宿主时钟取得准确剩余毫秒并冻结，同时撤销待发闹钟。
  ///
  /// 仅对运行中且未暂停的轮次有效；已归零或已结束时抛
  /// [CountdownErrorCode.runNotRunning]。返回冻结后的运行快照。
  Future<RunSnapshot> pauseRun(int runId);

  /// 继续本轮：从冻结的剩余时长重建截止点，继续同一个 [runId]。
  ///
  /// 暂停期间经过的实际时长不计入；未投递的提醒按新的截止点重新计算。
  Future<RunSnapshot> resumeRun(int runId);

  /// 从本轮最初的总时长立即开始新一轮（新 [RunSnapshot.runId]）。
  ///
  /// 旧轮的闹钟、通知与过期回调随之失效；活动与暂停状态都可调用。
  Future<RunSnapshot> restartRun(int runId);

  /// 取消本轮：结束当前轮并撤销闹钟与已展示通知。
  ///
  /// 保存的常用项回到可再次启动的状态；临时项目与其运行一并删除。
  /// 目标已不存在时视为已完成，不抛错。
  Future<void> cancelRun(int runId);

  /// 把运行置为已结束（归零后调用），并清除其待发提醒。
  Future<void> finishRun(int runId);

  /// 删除项目，同时终止其本轮运行、撤销待发闹钟与已展示通知。
  ///
  /// 确认后调用；目标不存在时视为已完成，不抛错。
  Future<void> deleteProject(int projectId);

  /// 前台运行页认领本轮提醒。
  ///
  /// 宿主用同一事务裁决前台与接收器谁先认领：返回 true 表示本次调用完成认领，
  /// 页面显示提示条；返回 false 表示已被系统通知投递，本次不再弹前台条。
  Future<bool> claimForegroundReminder(int runId);

  /// 记录提示条已被用户收起，同一轮旋转或重新进入页面不再弹出。
  Future<void> dismissBanner(int runId);

  /// 对照持久状态登记本轮的提前提醒闹钟（幂等，重复调用覆盖同一闹钟）。
  ///
  /// 应用进入前台或提交运行后调用，用于恢复“提交成功但系统登记前退出”的情况。
  Future<ReminderScheduleResult> ensureReminderScheduled(int runId);

  /// 查询当前通知权限，不触发系统弹窗。
  Future<NotificationPermission> notificationPermission();

  /// 在用户开启提前提醒的上下文请求通知权限；系统不需要授权时直接返回
  /// [NotificationPermission.notRequired]。
  Future<NotificationPermission> requestNotificationPermission();

  /// 查询用户是否允许精确闹钟（API 31+ 需要特殊访问）。
  Future<bool> canScheduleExactAlarms();

  /// 点击有效通知后宿主上报的运行 ID。
  ///
  /// 应用在后台被通知唤起时走本通道；冷启动时宿主先缓存，Flutter 就绪后由
  /// [consumePendingNotificationRun] 取回，避免丢失首次点击。
  Stream<int> get notificationOpens;

  /// 取走冷启动前缓存的通知点击目标（运行 ID），没有则返回 null。
  Future<int?> consumePendingNotificationRun();

  /// 只读时钟读数，用于从后台返回、旋转或进程重建后重新校准。
  Future<ClockReading> clock();

  /// 释放事件通道监听。
  void dispose();
}

/// 基于平台通道的实现。通道名与参数名是 Flutter 与 Kotlin 之间的契约。
class PlatformCountdownRepository implements CountdownRepository {
  PlatformCountdownRepository({
    MethodChannel storageChannel = const MethodChannel(_storageChannelName),
    MethodChannel reminderChannel = const MethodChannel(_reminderChannelName),
    MethodChannel eventChannel = const MethodChannel(_eventChannelName),
  }) : _storage = storageChannel,
       _reminder = reminderChannel,
       _events = eventChannel {
    _events.setMethodCallHandler(_handleEvent);
  }

  static const String _storageChannelName = 'countdown/storage';
  static const String _reminderChannelName = 'countdown/reminder';
  static const String _eventChannelName = 'countdown/events';

  final MethodChannel _storage;
  final MethodChannel _reminder;
  final MethodChannel _events;

  final StreamController<int> _notificationOpens =
      StreamController<int>.broadcast();

  CountdownRepositoryException _wrap(Object error) {
    if (error is PlatformException) {
      return CountdownRepositoryException(error.code, error.message ?? '');
    }
    return CountdownRepositoryException(
      CountdownErrorCode.storageFailure,
      error.toString(),
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error) {
      throw _wrap(error);
    }
  }

  Future<void> _handleEvent(MethodCall call) async {
    if (call.method == 'openRun') {
      final Object? arguments = call.arguments;
      if (arguments is Map && arguments['runId'] is int) {
        _notificationOpens.add(arguments['runId']! as int);
      }
    }
  }

  @override
  Future<AppSnapshot> snapshot() => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      'snapshot',
    );
    if (result == null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        'snapshot returned null',
      );
    }
    return AppSnapshot.fromMap(result);
  });

  @override
  Future<CountdownProject> createProject({
    required String name,
    required int totalSeconds,
    required int? reminderSeconds,
  }) => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      'createProject',
      <String, Object?>{
        'name': name,
        'totalSeconds': totalSeconds,
        'reminderSeconds': reminderSeconds,
      },
    );
    if (result == null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        'createProject returned null',
      );
    }
    return CountdownProject.fromMap(result);
  });

  @override
  Future<RunSnapshot> startRun(int projectId) => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      'startRun',
      <String, Object?>{'projectId': projectId},
    );
    if (result == null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        'startRun returned null',
      );
    }
    return RunSnapshot.fromMap(result);
  });

  @override
  Future<RunSnapshot> startTemporaryRun(int totalSeconds) => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      'startTemporaryRun',
      <String, Object?>{'totalSeconds': totalSeconds},
    );
    if (result == null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        'startTemporaryRun returned null',
      );
    }
    return RunSnapshot.fromMap(result);
  });

  @override
  Future<RunSnapshot> pauseRun(int runId) => _runCommand('pauseRun', runId);

  @override
  Future<RunSnapshot> resumeRun(int runId) => _runCommand('resumeRun', runId);

  @override
  Future<RunSnapshot> restartRun(int runId) => _runCommand('restartRun', runId);

  @override
  Future<void> cancelRun(int runId) => _guard(() async {
    await _storage.invokeMethod<void>('cancelRun', <String, Object?>{
      'runId': runId,
    });
  });

  /// 暂停/继续/重新计时共用同一调用形状：入参 runId，返回新的运行快照。
  Future<RunSnapshot> _runCommand(String method, int runId) => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      method,
      <String, Object?>{'runId': runId},
    );
    if (result == null) {
      throw CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        '$method returned null',
      );
    }
    return RunSnapshot.fromMap(result);
  });

  @override
  Future<void> finishRun(int runId) => _guard(() async {
    await _storage.invokeMethod<void>('finishRun', <String, Object?>{
      'runId': runId,
    });
  });

  @override
  Future<void> deleteProject(int projectId) => _guard(() async {
    await _storage.invokeMethod<void>('deleteProject', <String, Object?>{
      'projectId': projectId,
    });
  });

  @override
  Future<bool> claimForegroundReminder(int runId) => _guard(() async {
    final bool? claimed = await _storage.invokeMethod<bool>(
      'claimForegroundReminder',
      <String, Object?>{'runId': runId},
    );
    return claimed ?? false;
  });

  @override
  Future<void> dismissBanner(int runId) => _guard(() async {
    await _storage.invokeMethod<void>('dismissBanner', <String, Object?>{
      'runId': runId,
    });
  });

  @override
  Future<ReminderScheduleResult> ensureReminderScheduled(int runId) =>
      _guard(() async {
        final String? result = await _reminder.invokeMethod<String>(
          'ensureReminderScheduled',
          <String, Object?>{'runId': runId},
        );
        return switch (result) {
          'scheduled_exact' => ReminderScheduleResult.scheduledExact,
          'scheduled_inexact' => ReminderScheduleResult.scheduledInexact,
          _ => ReminderScheduleResult.notScheduled,
        };
      });

  @override
  Future<NotificationPermission> notificationPermission() => _guard(
    () async => _decodePermission(
      await _reminder.invokeMethod<String>('notificationPermission'),
    ),
  );

  @override
  Future<NotificationPermission> requestNotificationPermission() => _guard(
    () async => _decodePermission(
      await _reminder.invokeMethod<String>('requestNotificationPermission'),
    ),
  );

  @override
  Future<bool> canScheduleExactAlarms() => _guard(() async {
    final bool? can = await _reminder.invokeMethod<bool>(
      'canScheduleExactAlarms',
    );
    return can ?? false;
  });

  NotificationPermission _decodePermission(String? value) => switch (value) {
    'granted' => NotificationPermission.granted,
    'denied' => NotificationPermission.denied,
    _ => NotificationPermission.notRequired,
  };

  @override
  Stream<int> get notificationOpens => _notificationOpens.stream;

  @override
  Future<int?> consumePendingNotificationRun() => _guard(() async {
    return await _reminder.invokeMethod<int>('consumePendingNotificationRun');
  });

  @override
  Future<ClockReading> clock() => _guard(() async {
    final Map<Object?, Object?>? result = await _storage.invokeMapMethod(
      'clock',
    );
    if (result == null) {
      throw const CountdownRepositoryException(
        CountdownErrorCode.storageFailure,
        'clock returned null',
      );
    }
    return ClockReading.fromMap(result);
  });

  @override
  void dispose() {
    _events.setMethodCallHandler(null);
    _notificationOpens.close();
  }
}
