package com.countdown.countdown_app

import android.content.Context
import android.os.SystemClock
import android.provider.Settings

/**
 * 宿主侧时钟读数。
 *
 * 剩余时间有两个基准，必须与 `lib/countdown/model.dart` 的
 * `ClockReading.remainingMillisOf` 保持一致：
 * - 同一次开机内用 [SystemClock.elapsedRealtime] 相减（单调、含深度睡眠），手动改系统
 *   时间不会改变倒数；
 * - 开机计数变化说明设备重启过，单调时钟已归零，改用持久化的 UTC 截止时刻校准。
 *
 * 一次业务判断只应调用一次 [now]，并把同一个 [Reading] 传给多次剩余时间计算，
 * 否则跨读数边界时可能出现「同一次快照里两个运行用了不同时刻」的偏差。
 *
 * 暂停运行的剩余时间不在这里换算：它取 runs.paused_remaining_millis 的冻结值，
 * 调用方（[TimerStore]）必须先判断 `paused`，否则会继续扣减暂停期间流逝的时间。
 */
internal class RunClock(context: Context) {

    private val appContext = context.applicationContext

    /** 一次时钟读数；[bootCount] 为 `Settings.Global.BOOT_COUNT` 的读取结果。 */
    data class Reading(
        val elapsedMillis: Long,
        val utcMillis: Long,
        val bootCount: Int,
    )

    fun now(): Reading {
        return Reading(
            elapsedMillis = SystemClock.elapsedRealtime(),
            utcMillis = System.currentTimeMillis(),
            bootCount = currentBootCount(),
        )
    }

    /** 以新读数计算剩余毫秒。 */
    fun remainingOf(run: TimerStore.RunRecord): Long = remainingOf(now(), run)

    fun remainingOf(reading: Reading, run: TimerStore.RunRecord): Long {
        return remainingOf(
            reading = reading,
            deadlineElapsedMillis = run.deadlineElapsedMillis,
            deadlineUtcMillis = run.deadlineUtcMillis,
            bootCount = run.bootCount,
        )
    }

    /**
     * 与 model.dart 的换算规则相同：开机计数一致时用单调时钟，否则用 UTC 截止值。
     * 返回值可能为负（已过期）或大于总时长（系统时间被回拨），调用方按需截断。
     */
    fun remainingOf(
        reading: Reading,
        deadlineElapsedMillis: Long,
        deadlineUtcMillis: Long,
        bootCount: Int,
    ): Long {
        return if (bootCount == reading.bootCount) {
            deadlineElapsedMillis - reading.elapsedMillis
        } else {
            deadlineUtcMillis - reading.utcMillis
        }
    }

    private fun currentBootCount(): Int {
        // BOOT_COUNT 自 API 24 起提供，与本应用 minSdk 一致。个别设备或模拟器可能缺少
        // 该设置项，此时统一返回 UNKNOWN_BOOT_COUNT：写入与读取都拿到同一个值，
        // 比较仍然成立，只是无法区分不同次开机。
        return Settings.Global.getInt(
            appContext.contentResolver,
            Settings.Global.BOOT_COUNT,
            UNKNOWN_BOOT_COUNT,
        )
    }

    companion object {
        const val UNKNOWN_BOOT_COUNT: Int = -1
    }
}
