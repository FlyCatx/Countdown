package com.countdown.countdown_app

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter 宿主入口：注册 countdown/storage、countdown/reminder、countdown/events 三条通道。
 *
 * 数据库与系统提醒操作全部提交到 [TimerStore.worker]，结果回到主线程再回复 Dart，
 * 因此通道回调不会阻塞 Flutter 的 UI 线程，多步写入也不会与接收器交错。
 *
 * 事件通道是原生 → Dart 单向，目前只用于通知点击：
 * - 冷启动（Dart 尚未注册事件 handler）先缓存运行 ID，等 Dart 调用
 *   `consumePendingNotificationRun` 取走；
 * - 热启动（Dart 已经调用过本宿主的通道，说明仓储构造函数里的 handler 已注册）
 *   直接 invokeMethod("openRun")。
 * 两条路径互斥，同一 runId 不会重复上报。
 */
class MainActivity : FlutterActivity() {

    private var engine: FlutterEngine? = null
    private var storageChannel: MethodChannel? = null
    private var reminderChannel: MethodChannel? = null
    private var eventsChannel: MethodChannel? = null

    /**
     * 事件通道可用的引擎实例。
     *
     * Dart 侧只有 PlatformCountdownRepository 构造完成后才会调用本宿主的通道，而该构造
     * 函数同步注册了 countdown/events 的 handler；因此「收到过一次 Dart 调用」等价于
     * 「事件 handler 已就位」。Activity 重建时 FlutterActivity 可能复用同一个引擎，
     * 此时保留该标记；换成新引擎则清空，等新 Dart 侧再次调用。
     */
    private var eventsReadyEngine: FlutterEngine? = null

    /** 冷启动缓存的通知点击目标；由 consumePendingNotificationRun 一次性取走。 */
    private var pendingNotificationRunId: Long? = null

    /** 等待 onRequestPermissionsResult 的通知权限请求结果。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 系统权限弹窗长时间未回调时的兜底，避免 Dart 侧的 Future 永远不完成。 */
    private val permissionTimeout = Runnable {
        completePermissionRequest("notification permission request timed out")
    }

    // --- 生命周期 ---------------------------------------------------------

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ReminderScheduler(applicationContext).ensureNotificationChannel()
        // 进程被回收后系统会按原启动 Intent 重建 Activity；上次已经上报过的点击不再重放。
        val launchIntentHandled = savedInstanceState?.getBoolean(STATE_LAUNCH_INTENT_HANDLED) == true
        if (!launchIntentHandled) {
            handleNotificationIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_LAUNCH_INTENT_HANDLED, true)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(permissionTimeout)
        // Activity 销毁会带走挂起的授权结果，显式回 denied，避免 Dart 侧永久等待。
        completePermissionRequest("activity destroyed while requesting notification permission")
        storageChannel?.setMethodCallHandler(null)
        reminderChannel?.setMethodCallHandler(null)
        storageChannel = null
        reminderChannel = null
        eventsChannel = null
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = flutterEngine
        if (eventsReadyEngine !== flutterEngine) {
            // 新引擎意味着新的 Dart isolate，事件 handler 需要重新注册。
            eventsReadyEngine = null
        }

        val messenger = flutterEngine.dartExecutor.binaryMessenger
        storageChannel = MethodChannel(messenger, STORAGE_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result -> onStorageCall(call.method, call.arguments, result) }
        }
        reminderChannel = MethodChannel(messenger, REMINDER_CHANNEL).also { channel ->
            channel.setMethodCallHandler { call, result -> onReminderCall(call.method, call.arguments, result) }
        }
        eventsChannel = MethodChannel(messenger, EVENT_CHANNEL)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_NOTIFICATIONS) return
        // 不直接采信 grantResults：用户可能在弹窗后到系统设置里又改过，以实际状态为准。
        completePermissionRequest(reason = null)
    }

    // --- 通知点击 ---------------------------------------------------------

    private fun handleNotificationIntent(intent: Intent?) {
        if (intent == null) return
        if (intent.action != ReminderScheduler.ACTION_OPEN_RUN) return
        val runId = intent.getLongExtra(ReminderScheduler.EXTRA_RUN_ID, NO_RUN_ID)
        if (runId <= 0L) return
        // 取走 extra，避免同一个 Intent 被再次分发时重复上报。
        intent.removeExtra(ReminderScheduler.EXTRA_RUN_ID)
        deliverOpenRun(runId)
    }

    private fun deliverOpenRun(runId: Long) {
        val channel = eventsChannel
        val currentEngine = engine
        if (channel == null || currentEngine == null || eventsReadyEngine !== currentEngine) {
            // Dart 还没准备好接收事件：先缓存，由 consumePendingNotificationRun 取走。
            pendingNotificationRunId = runId
            return
        }
        channel.invokeMethod(OPEN_RUN_METHOD, mapOf("runId" to runId), object : MethodChannel.Result {
            override fun success(result: Any?) {
                // 同一次点击可能还留在冷启动缓存里，投递成功后清掉，避免二次上报。
                if (pendingNotificationRunId == runId) {
                    pendingNotificationRunId = null
                }
            }

            override fun error(code: String, message: String?, details: Any?) {
                // Dart 侧异常或 handler 不可用：转回缓存路径，不假装已经送达。
                pendingNotificationRunId = runId
                Log.w(TAG, "Dart failed to handle openRun($runId): $code $message")
            }

            override fun notImplemented() {
                pendingNotificationRunId = runId
                Log.w(TAG, "event channel handler not implemented, cache openRun($runId)")
            }
        })
    }

    // --- 存储通道 ---------------------------------------------------------

    private fun onStorageCall(method: String, arguments: Any?, result: MethodChannel.Result) {
        markDartChannelReady()
        val args = arguments as? Map<*, *>
        when (method) {
            "snapshot" -> runOnWorker(result) {
                TimerStore.get(applicationContext).readSnapshot().toWireMap()
            }

            "createProject" -> runOnWorker(result) {
                val name = args?.get("name") as? String
                    ?: throw IllegalArgumentException("createProject requires a string name")
                val totalSeconds = longArgument(args, "totalSeconds")
                val reminderSeconds = intArgumentOrNull(args, "reminderSeconds")
                TimerStore.get(applicationContext)
                    .createProject(name, totalSeconds, reminderSeconds)
                    .toWireMap()
            }

            "startRun" -> runOnWorker(result) {
                startRunInternal(longArgument(args, "projectId"))
            }

            "startTemporaryRun" -> runOnWorker(result) {
                startTemporaryRunInternal(longArgument(args, "totalSeconds"))
            }

            "pauseRun" -> runOnWorker(result) {
                pauseRunInternal(longArgument(args, "runId"))
            }

            "resumeRun" -> runOnWorker(result) {
                resumeRunInternal(longArgument(args, "runId"))
            }

            "restartRun" -> runOnWorker(result) {
                restartRunInternal(longArgument(args, "runId"))
            }

            "cancelRun" -> runOnWorker(result) {
                val runId = longArgument(args, "runId")
                TimerStore.get(applicationContext).cancelRun(runId)
                // 事务已提交：撤销可能残留的闹钟与已展示通知。目标已不存在时是空操作。
                cancelReminderBestEffort(runId)
                null
            }

            "finishRun" -> runOnWorker(result) {
                val runId = longArgument(args, "runId")
                TimerStore.get(applicationContext).finishRun(runId)
                cancelReminderBestEffort(runId)
                null
            }

            "deleteProject" -> runOnWorker(result) {
                val projectId = longArgument(args, "projectId")
                val deletedRunIds = TimerStore.get(applicationContext).deleteProject(projectId)
                for (runId in deletedRunIds) {
                    cancelReminderBestEffort(runId)
                }
                null
            }

            "claimForegroundReminder" -> runOnWorker(result) {
                TimerStore.get(applicationContext)
                    .claimForegroundReminder(longArgument(args, "runId"))
            }

            "dismissBanner" -> runOnWorker(result) {
                TimerStore.get(applicationContext).dismissBanner(longArgument(args, "runId"))
                null
            }

            "clock" -> runOnWorker(result) {
                TimerStore.get(applicationContext).readClock().toWireMap()
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 启动运行并在事务提交后登记闹钟。全部步骤都在 [TimerStore.worker] 上执行，
     * 因此「提交成功但系统登记前退出」的窗口只可能是进程被杀，下一次进入前台时
     * Dart 会调用 ensureReminderScheduled 重新对照持久状态登记。
     */
    private fun startRunInternal(projectId: Long): Map<String, Any?> {
        val store = TimerStore.get(applicationContext)
        val startResult = store.startRun(projectId)
        for (runId in startResult.cancelRunIds) {
            cancelReminderBestEffort(runId)
        }
        scheduleReminderBestEffort(startResult.run.run.id)
        return startResult.run.toWireMap()
    }

    /**
     * 首页快启：启动临时运行。临时项目始终关闭提前提醒，因此只处理被收尾旧运行的
     * 撤销，不登记新闹钟。
     */
    private fun startTemporaryRunInternal(totalSeconds: Long): Map<String, Any?> {
        val store = TimerStore.get(applicationContext)
        val startResult = store.startTemporaryRun(totalSeconds)
        for (runId in startResult.cancelRunIds) {
            cancelReminderBestEffort(runId)
        }
        return startResult.run.toWireMap()
    }

    /**
     * 暂停本轮。暂停后只撤销待发闹钟：已经展示的提醒通知保留，暂停不会把用户看过的
     * 提醒重新藏起来；提醒行也保留，继续后不会重复投递已经提醒过的轮次。
     */
    private fun pauseRunInternal(runId: Long): Map<String, Any?> {
        val store = TimerStore.get(applicationContext)
        return when (val outcome = store.pauseRun(runId)) {
            is TimerStore.RunControlResult.Active -> {
                cancelAlarmBestEffort(runId)
                outcome.run.toWireMap()
            }

            TimerStore.RunControlResult.Elapsed -> {
                // 事务内已把归零的运行收尾：先撤销闹钟与通知，再如实报告本轮已经结束。
                cancelReminderBestEffort(runId)
                throw TimerStore.StoreException(
                    TimerStore.ERROR_RUN_NOT_RUNNING,
                    "run $runId has already elapsed",
                )
            }
        }
    }

    /**
     * 继续本轮。提交后按新的截止点重算未投递提醒；已经提醒过的轮次由
     * [TimerStore.reminderSchedulePlan] 判定为无需登记，不会重复提醒。
     */
    private fun resumeRunInternal(runId: Long): Map<String, Any?> {
        val store = TimerStore.get(applicationContext)
        return when (val outcome = store.resumeRun(runId)) {
            is TimerStore.RunControlResult.Active -> {
                scheduleReminderBestEffort(runId)
                outcome.run.toWireMap()
            }

            TimerStore.RunControlResult.Elapsed -> {
                cancelReminderBestEffort(runId)
                throw TimerStore.StoreException(
                    TimerStore.ERROR_RUN_NOT_RUNNING,
                    "run $runId has no frozen remaining time",
                )
            }
        }
    }

    /**
     * 重新计时：先让旧轮的闹钟与已展示通知失效，再按新运行登记提醒。
     * 旧轮的迟到广播即使被系统触发，接收器也会因状态不是 running 而拒绝投递。
     */
    private fun restartRunInternal(runId: Long): Map<String, Any?> {
        val store = TimerStore.get(applicationContext)
        val restartResult = store.restartRun(runId)
        cancelReminderBestEffort(restartResult.previousRunId)
        scheduleReminderBestEffort(restartResult.run.run.id)
        return restartResult.run.toWireMap()
    }

    /** 对照持久状态登记或撤销本轮闹钟；失败只记录日志，不影响已提交的业务写入。 */
    private fun scheduleReminderBestEffort(runId: Long) {
        try {
            ensureReminderScheduled(runId)
        } catch (error: Exception) {
            Log.w(TAG, "scheduling reminder failed for run $runId", error)
        }
    }

    /** 只撤销闹钟、保留已展示通知；用于暂停等不打扰用户的纠正确认。 */
    private fun cancelAlarmBestEffort(runId: Long) {
        try {
            ReminderScheduler(applicationContext).cancelAlarm(runId)
        } catch (error: Exception) {
            Log.w(TAG, "cancelling alarm for run $runId failed", error)
        }
    }

    /**
     * 撤销闹钟与已展示通知。数据库事务已经提交，这里的系统调用失败不应让调用方误以为
     * 业务写入失败；记录日志后由后续刷新/重进前台纠正。
     *
     * 已知限制：AlarmManager.cancel / NotificationManagerCompat.cancel 不返回撤销是否成功，
     * 宿主也没有持久化「待撤销标识」，因此无法在本次进程之外重试撤销，不构成强一致保证。
     * 运行结束后不会再产生新的提醒（接收器在事务内会拒绝已结束的运行），残留窗口极小。
     */
    private fun cancelReminderBestEffort(runId: Long) {
        try {
            ReminderScheduler(applicationContext).cancelReminder(runId)
        } catch (error: Exception) {
            Log.w(TAG, "cancelling reminder for run $runId failed", error)
        }
    }

    // --- 提醒通道 ---------------------------------------------------------

    private fun onReminderCall(method: String, arguments: Any?, result: MethodChannel.Result) {
        markDartChannelReady()
        val args = arguments as? Map<*, *>
        when (method) {
            "ensureReminderScheduled" -> runOnWorker(result) {
                ensureReminderScheduled(longArgument(args, "runId"))
            }

            "notificationPermission" -> replyToDart(
                result,
                Result.success(ReminderScheduler(applicationContext).notificationPermission()),
            )

            "requestNotificationPermission" -> requestNotificationPermission(result)

            "canScheduleExactAlarms" -> replyToDart(
                result,
                Result.success(ReminderScheduler(applicationContext).canScheduleExactAlarms()),
            )

            "consumePendingNotificationRun" -> {
                val pendingRunId = pendingNotificationRunId
                pendingNotificationRunId = null
                replyToDart(result, Result.success(pendingRunId))
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 对照持久状态登记或撤销本轮闹钟，返回通道枚举字符串。
     * 只在 [TimerStore.worker] 上调用；没有待发时刻时撤销旧闹钟，避免已结束的运行再唤起接收器。
     */
    private fun ensureReminderScheduled(runId: Long): String {
        val store = TimerStore.get(applicationContext)
        val scheduler = ReminderScheduler(applicationContext)
        val plan = store.reminderSchedulePlan(runId)
        if (plan == null) {
            scheduler.cancelAlarm(runId)
            store.markReminderScheduled(runId, false)
            return ReminderScheduler.RESULT_NOT_SCHEDULED
        }
        val scheduleResult = scheduler.scheduleReminder(plan.runId, plan.triggerAtElapsedMillis)
        store.markReminderScheduled(runId, true)
        return scheduleResult
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val scheduler = ReminderScheduler(applicationContext)
        if (pendingPermissionResult != null) {
            // 同时只处理一个请求；重复调用直接回当前状态，不覆盖挂起的 Result。
            replyToDart(result, Result.success(scheduler.notificationPermission()))
            return
        }
        if (!scheduler.requestNotificationPermission(this, REQUEST_NOTIFICATIONS)) {
            // API 32 及以下或已授权：不需要弹窗，直接给当前状态。
            replyToDart(result, Result.success(scheduler.notificationPermission()))
            return
        }
        pendingPermissionResult = result
        mainHandler.postDelayed(permissionTimeout, PERMISSION_TIMEOUT_MS)
    }

    /**
     * 完成挂起的权限请求。[reason] 为 null 表示系统回调正常返回；超时或 Activity 销毁时
     * 记录原因，但仍以实际权限状态回复 Dart，不伪造结果。
     */
    private fun completePermissionRequest(reason: String?) {
        mainHandler.removeCallbacks(permissionTimeout)
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        if (reason != null) {
            Log.w(TAG, reason)
        }
        replyToDart(
            pending,
            Result.success(ReminderScheduler(applicationContext).notificationPermission()),
        )
    }

    // --- 通道回复 ---------------------------------------------------------

    /**
     * 把 Dart 调用标记为「已见过调用」，事件通道因此可以安全 invoke。
     * 只在通道 handler（主线程）里调用。
     */
    private fun markDartChannelReady() {
        val currentEngine = engine ?: return
        eventsReadyEngine = currentEngine
    }

    /** 在 [TimerStore.worker] 上执行 [block]，再把结果/错误送回主线程回复 Dart。 */
    private fun runOnWorker(result: MethodChannel.Result, block: () -> Any?) {
        TimerStore.worker.execute {
            val outcome: Result<Any?> = try {
                Result.success(block())
            } catch (error: TimerStore.StoreException) {
                Result.failure(error)
            } catch (error: Exception) {
                Result.failure(error)
            }
            mainHandler.post { replyToDart(result, outcome) }
        }
    }

    /**
     * 回复必须在主线程发出。引擎可能在操作完成前随 Activity 销毁而断开，此时回复会抛
     * 异常；这不是业务失败，记录后丢弃（调用方已随 Activity 消失）。
     */
    private fun replyToDart(result: MethodChannel.Result, outcome: Result<Any?>) {
        outcome.fold(
            onSuccess = { value ->
                try {
                    result.success(value)
                } catch (error: Exception) {
                    Log.w(TAG, "Dart reply dropped, engine detached", error)
                }
            },
            onFailure = { error ->
                val code = (error as? TimerStore.StoreException)?.code ?: ERROR_STORAGE_FAILURE
                // 业务校验错误（invalid_project 等）是预期分支，不当作宿主故障记录。
                if (error !is TimerStore.StoreException) {
                    Log.e(TAG, "host operation failed", error)
                }
                try {
                    result.error(code, error.message, null)
                } catch (replyError: Exception) {
                    Log.w(TAG, "Dart error reply dropped, engine detached", replyError)
                }
            },
        )
    }

    // --- 参数解析 ---------------------------------------------------------

    private fun longArgument(args: Map<*, *>?, key: String): Long {
        val value = args?.get(key) as? Number
            ?: throw IllegalArgumentException("missing numeric argument: $key")
        return value.toLong()
    }

    private fun intArgumentOrNull(args: Map<*, *>?, key: String): Int? {
        val value = args?.get(key) ?: return null
        return (value as? Number)?.toInt()
            ?: throw IllegalArgumentException("argument $key must be a number or null")
    }

    companion object {
        private const val TAG = "CountdownHost"

        private const val STORAGE_CHANNEL = "countdown/storage"
        private const val REMINDER_CHANNEL = "countdown/reminder"
        private const val EVENT_CHANNEL = "countdown/events"
        private const val OPEN_RUN_METHOD = "openRun"

        private const val REQUEST_NOTIFICATIONS = 4001

        /**
         * 权限弹窗的等待上限。超过后按当前权限状态回复，避免 Dart 的 Future 永远不完成；
         * 用户随后在系统弹窗里的选择不会再次上报给该次调用。
         */
        private const val PERMISSION_TIMEOUT_MS = 60_000L

        private const val STATE_LAUNCH_INTENT_HANDLED = "countdown.launchIntentHandled"

        /** Dart 侧把未知异常统一映射为 storage_failure，这里沿用同一错误码。 */
        private const val ERROR_STORAGE_FAILURE = "storage_failure"

        private const val NO_RUN_ID = -1L
    }
}
