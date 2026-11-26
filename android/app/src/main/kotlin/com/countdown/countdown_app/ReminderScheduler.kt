package com.countdown.countdown_app

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.Locale

/**
 * 系统提醒的登记、撤销与通知投递。
 *
 * 只负责与系统交互（AlarmManager / NotificationManager / 通知权限），不读写数据库：
 * 是否该提醒、还剩多少由 [TimerStore] 判定；闹钟触发后的二次校验由
 * [ReminderReceiver] 在事务内完成。这样系统唤起的接收器不依赖 Flutter 引擎。
 *
 * 本类的方法都不阻塞（系统调用是轻量的 binder 调用），但仍按调用方约定在
 * [TimerStore.worker] 或主线程执行，类本身不持有线程。
 */
internal class ReminderScheduler(context: Context) {

    private val appContext: Context = context.applicationContext

    /**
     * 登记本轮的提前提醒闹钟。
     *
     * API 31+ 且系统不授予精确闹钟条件时退回 `setAndAllowWhileIdle`（允许空闲投递、
     * 可能延迟），并如实返回 inexact；API 24–30 没有这一限制。返回值是通道枚举字符串。
     *
     * 幂等：PendingIntent 的 requestCode 固定为该运行 ID，重复登记覆盖同一闹钟。
     */
    fun scheduleReminder(runId: Long, triggerAtElapsedMillis: Long): String {
        val alarmManager = appContext.getSystemService(AlarmManager::class.java)
        val pendingIntent = createReminderAlarmPendingIntent(runId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !alarmManager.canScheduleExactAlarms()) {
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAtElapsedMillis,
                pendingIntent,
            )
            return RESULT_SCHEDULED_INEXACT
        }
        return try {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAtElapsedMillis,
                pendingIntent,
            )
            RESULT_SCHEDULED_EXACT
        } catch (error: SecurityException) {
            // 精确闹钟授权可能在 canScheduleExactAlarms() 与登记之间被撤销；
            // 退回非精确闹钟并如实上报，不能把提交结果说成精确登记。
            Log.w(TAG, "exact alarm rejected for run $runId, falling back to inexact", error)
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAtElapsedMillis,
                pendingIntent,
            )
            RESULT_SCHEDULED_INEXACT
        }
    }

    /** 只撤销闹钟，保留已经展示的通知（用于纠正性重算，不打扰用户）。 */
    fun cancelAlarm(runId: Long) {
        val pendingIntent = existingReminderAlarmPendingIntent(runId) ?: return
        appContext.getSystemService(AlarmManager::class.java).cancel(pendingIntent)
        pendingIntent.cancel()
    }

    /** 撤销闹钟与已展示的通知；结束或删除运行时调用。 */
    fun cancelReminder(runId: Long) {
        cancelAlarm(runId)
        NotificationManagerCompat.from(appContext).cancel(notificationId(runId))
    }

    /**
     * 创建提前提醒通知渠道。API 26+ 只创建第一次，之后尊重用户在系统设置里的渠道配置；
     * API 24–25 没有渠道概念，直接返回。
     */
    fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = appContext.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            appContext.getString(R.string.reminder_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        )
        channel.description = appContext.getString(R.string.reminder_channel_description)
        manager.createNotificationChannel(channel)
    }

    /**
     * 投递提前提醒通知。
     *
     * 返回 false 表示系统当前不接受通知（运行时权限被拒、应用通知被关闭、渠道被关闭）；
     * 调用方据此把事务内的认领退回 'none'，让前台提示条仍能表达本轮提醒。
     * 同一运行重复投递使用同一通知 ID，覆盖已有通知而不是叠加。
     */
    @SuppressLint("NotificationPermission") // 权限与渠道状态已由 canPostNotifications() 检查。
    fun postReminderNotification(claim: TimerStore.NotificationClaim): Boolean {
        ensureNotificationChannel()
        if (!canPostNotifications()) {
            Log.w(TAG, "notifications unavailable, skip reminder for run ${claim.runId}")
            return false
        }
        val notification = buildReminderNotification(claim)
        return try {
            NotificationManagerCompat.from(appContext).notify(notificationId(claim.runId), notification)
            true
        } catch (error: SecurityException) {
            // 权限在检查与投递之间被撤销：如实报告失败，由调用方退回认领。
            Log.e(TAG, "posting reminder notification failed for run ${claim.runId}", error)
            false
        }
    }

    /** 通道枚举：'not_required'（API<33）、'granted'、'denied'。 */
    fun notificationPermission(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return PERMISSION_NOT_REQUIRED
        val granted = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        return if (granted) PERMISSION_GRANTED else PERMISSION_DENIED
    }

    /**
     * 在用户开启提醒的上下文发起通知权限请求。
     *
     * 返回 true 表示已经发起系统弹窗，结果通过 Activity 的
     * onRequestPermissionsResult 回传；返回 false 表示当前不需要弹窗
     * （API<33 或已授权），调用方直接回当前状态。
     */
    fun requestNotificationPermission(activity: Activity, requestCode: Int): Boolean {
        if (notificationPermission() != PERMISSION_DENIED) return false
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), requestCode)
        return true
    }

    fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return appContext.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()
    }

    /**
     * 系统此刻是否真的能展示通知。比 [notificationPermission] 更严格：还检查应用级
     * 通知开关与渠道的重要性，因为 API 26+ 用户可以在系统设置里单独关闭本渠道，
     * 此时 notify() 会静默丢弃，不能算作已投递。
     */
    fun canPostNotifications(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!NotificationManagerCompat.from(appContext).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = appContext.getSystemService(NotificationManager::class.java)
            val channel = manager.getNotificationChannel(CHANNEL_ID) ?: return false
            if (channel.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    private fun buildReminderNotification(claim: TimerStore.NotificationClaim): Notification {
        return notificationBuilder()
            .setSmallIcon(android.R.drawable.ic_popup_reminder)
            .setContentTitle(claim.projectName)
            .setContentText(reminderBodyText(claim.remainingMillis))
            .setContentIntent(openRunPendingIntent(claim.runId))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setAutoCancel(true)
            .build()
    }

    /**
     * 正文按认领时刻的真实剩余毫秒格式化为「还剩 HH:MM:SS」：非精确闹钟可能晚到，
     * 沿用登记时的阈值会显示比实际多的时间；阈值只用于排程。正剩余向上取整到秒，
     * 与应用内计时显示（`formatRemaining`）保持同一口径；小时不设上限，分、秒两位补零。
     * 认领已保证剩余 >0，因此不处理归零文案。
     */
    private fun reminderBodyText(remainingMillis: Long): String {
        val totalSeconds = (remainingMillis + 999L) / 1000L
        val hours = totalSeconds / 3600L
        val minutes = (totalSeconds % 3600L) / 60L
        val seconds = totalSeconds % 60L
        return appContext.getString(
            R.string.reminder_notification_body,
            String.format(Locale.US, "%02d:%02d:%02d", hours, minutes, seconds),
        )
    }

    /**
     * API 24–25 没有通知渠道，用 Builder 的优先级与默认提示表达「重要提醒」；
     * API 26+ 由渠道重要性控制，构造时只传渠道 ID。
     */
    @Suppress("DEPRECATION")
    private fun notificationBuilder(): NotificationCompat.Builder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationCompat.Builder(appContext, CHANNEL_ID)
        } else {
            NotificationCompat.Builder(appContext)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
        }
    }

    private fun openRunPendingIntent(runId: Long): PendingIntent {
        val intent = Intent(appContext, MainActivity::class.java).apply {
            action = ACTION_OPEN_RUN
            putExtra(EXTRA_RUN_ID, runId)
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return PendingIntent.getActivity(
            appContext,
            requestCodeOf(runId),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createReminderAlarmPendingIntent(runId: Long): PendingIntent {
        return PendingIntent.getBroadcast(
            appContext,
            requestCodeOf(runId),
            reminderAlarmIntent(runId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** 撤销时只查找已存在的 PendingIntent，避免顺手创建新的登记。 */
    private fun existingReminderAlarmPendingIntent(runId: Long): PendingIntent? {
        return PendingIntent.getBroadcast(
            appContext,
            requestCodeOf(runId),
            reminderAlarmIntent(runId),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun reminderAlarmIntent(runId: Long): Intent {
        return Intent(appContext, ReminderReceiver::class.java).apply {
            action = ACTION_DELIVER_REMINDER
            putExtra(EXTRA_RUN_ID, runId)
        }
    }

    companion object {
        /**
         * 数据库自增 ID 实际远小于 Int 上限；PendingIntent requestCode 与通知 ID 只能是
         * Int，这里直接截断。若运行 ID 真达到该量级，需要另行设计稳定的短标识。
         */
        private fun requestCodeOf(runId: Long): Int = runId.toInt()

        /** 通知 ID = 固定基准 + 运行 ID，同一运行重复投递覆盖同一条通知。 */
        internal fun notificationId(runId: Long): Int = NOTIFICATION_ID_BASE + runId.toInt()

        internal const val EXTRA_RUN_ID = "runId"
        internal const val ACTION_OPEN_RUN = "com.countdown.countdown_app.action.OPEN_RUN"
        internal const val ACTION_DELIVER_REMINDER = "com.countdown.countdown_app.action.DELIVER_REMINDER"

        internal const val CHANNEL_ID = "countdown_reminder"

        internal const val PERMISSION_NOT_REQUIRED = "not_required"
        internal const val PERMISSION_GRANTED = "granted"
        internal const val PERMISSION_DENIED = "denied"

        internal const val RESULT_SCHEDULED_EXACT = "scheduled_exact"
        internal const val RESULT_SCHEDULED_INEXACT = "scheduled_inexact"
        internal const val RESULT_NOT_SCHEDULED = "not_scheduled"

        private const val NOTIFICATION_ID_BASE = 10_000
        private const val TAG = "CountdownHost"
    }
}
