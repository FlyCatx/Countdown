package com.countdown.countdown_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * 提前提醒闹钟的接收器。
 *
 * 系统可能在应用进程已退出后才唤起本接收器，所以这里不能依赖 Flutter 引擎：
 * 直接读宿主 SQLite 判断本轮是否仍有效。登记时刻的判断不能沿用至今——运行可能已
 * 结束、被取消、被重新计时、已暂停、已过期，或前台页面已经用提示条认领过。暂停与
 * 取消会撤销闹钟，但闹钟可能已经被系统触发并在队列里排队，因此必须在事务内重新认领，
 * 认领成功才投递系统通知。
 *
 * 线程：使用 goAsync() 把数据库与通知操作移到 [TimerStore.worker]，与 Activity 的
 * 删除/结束路径在同一条串行队列上执行，避免「先删后发」。任何分支都必须
 * [BroadcastReceiver.PendingResult.finish]，否则系统会判定广播超时。
 */
class ReminderReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ReminderScheduler.ACTION_DELIVER_REMINDER) return
        val runId = intent.getLongExtra(ReminderScheduler.EXTRA_RUN_ID, NO_RUN_ID)
        if (runId <= 0L) return

        val appContext = context.applicationContext
        val pendingResult = goAsync()
        TimerStore.worker.execute {
            try {
                deliverReminder(appContext, runId)
            } catch (error: Exception) {
                // 广播没有调用方可以接收错误：记录后结束，绝不把失败静默当成已投递。
                Log.e(TAG, "reminder delivery failed for run $runId", error)
            } finally {
                pendingResult.finish()
            }
        }
    }

    private fun deliverReminder(context: Context, runId: Long) {
        val scheduler = ReminderScheduler(context)
        scheduler.ensureNotificationChannel()
        if (!scheduler.canPostNotifications()) {
            // 通知不可达时不认领：保持 delivery='none'，用户回到前台仍能看到提示条，
            // 而不是在后台悄悄丢失本轮提醒。
            Log.w(TAG, "notifications unavailable, skip claim for run $runId")
            return
        }

        val claim = TimerStore.get(context).claimNotificationReminder(runId) ?: return
        if (!scheduler.postReminderNotification(claim)) {
            // 投递失败时退回认领，前台提示条仍可表达本轮提醒。
            TimerStore.get(context).releaseNotificationClaim(runId)
        }
    }

    companion object {
        private const val NO_RUN_ID = -1L
        private const val TAG = "CountdownHost"
    }
}
