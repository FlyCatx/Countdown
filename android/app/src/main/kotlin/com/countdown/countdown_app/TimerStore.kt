package com.countdown.countdown_app

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 宿主侧唯一的业务数据库入口。
 *
 * 职责边界：
 * - 持有 SQLiteOpenHelper，集中实现 projects / runs / reminders 三张表的读写；
 * - 把需要裁决的竞态（谁先认领本轮提醒、哪些运行已经过期、暂停/取消/重新计时的先后）
 *   放在同一个事务里完成。系统闹钟唤起的 [ReminderReceiver] 与前台通道会在不同线程
 *   改同一行数据；
 * - 对外返回带通道字段名的 Map（字段与 `lib/countdown/model.dart` 一一对应），
 *   避免字段名散落到 Activity 里。
 *
 * 临时快启项目与常用项目共用 projects 表，用 `is_temporary` 区分是否进入常用列表；
 * 暂停中的运行用 `paused` 与冻结的 `paused_remaining_millis` 表达剩余时间，
 * 不再依赖原截止点。
 *
 * 线程约定：所有公开方法只允许在 [worker] 上执行。Activity 的通道任务与接收器任务
 * 共用这一条串行队列，因此单例创建、事务、闹钟登记与通知投递之间不会交错，也不需要
 * 额外的锁；方法内部不再切换线程，调用方负责把结果送回主线程。
 */
internal class TimerStore private constructor(
    context: Context,
    private val clock: RunClock,
) : SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

    // --- 数据结构 ---------------------------------------------------------

    /** projects 表的一行原始数据，不含展示状态。 */
    data class ProjectRow(
        val id: Long,
        val name: String,
        val totalSeconds: Long,
        /** 提前提醒阈值：触发时距离归零的剩余**秒数**；null 表示关闭提醒。 */
        val reminderSeconds: Int?,
        val createdAtUtcMillis: Long,
        val isTemporary: Boolean,
    )

    /**
     * 列表中的项目。[state] 取值与 `ProjectState` 一致：
     * 'finished' 表示最近一轮运行已结束（含已过期但尚未收尾的运行），否则 'idle'。
     */
    data class ProjectRecord(
        val row: ProjectRow,
        val state: String,
    ) {
        fun toWireMap(): Map<String, Any?> = mapOf(
            "id" to row.id,
            "name" to row.name,
            "totalSeconds" to row.totalSeconds,
            "reminderSeconds" to row.reminderSeconds,
            "createdAtUtcMillis" to row.createdAtUtcMillis,
            "state" to state,
        )
    }

    /** runs 表的一行；时间单位均为毫秒，时钟基准见 [RunClock]。 */
    data class RunRecord(
        val id: Long,
        val projectId: Long,
        val nameSnapshot: String,
        val totalSeconds: Long,
        val startElapsedMillis: Long,
        val deadlineElapsedMillis: Long,
        val deadlineUtcMillis: Long,
        val bootCount: Int,
        val status: String,
        val finishedAtUtcMillis: Long?,
        /** 暂停标记；为 true 时剩余时间取 [pausedRemainingMillis]，时钟不再参与换算。 */
        val paused: Boolean,
        /** 暂停时冻结的剩余毫秒数；只在 [paused] 为 true 时有意义。 */
        val pausedRemainingMillis: Long?,
    )

    /**
     * 一轮运行加提醒投递状态，即 `RunSnapshot` 的对应物。
     * [reminderThresholdMillis] 为 null 表示本轮没有提醒行（创建项目时关闭了提醒）。
     */
    data class RunView(
        val run: RunRecord,
        val reminderThresholdMillis: Long?,
        val reminderDelivery: String,
        val bannerDismissed: Boolean,
    ) {
        fun toWireMap(): Map<String, Any?> = mapOf(
            "runId" to run.id,
            "projectId" to run.projectId,
            "projectName" to run.nameSnapshot,
            "totalSeconds" to run.totalSeconds,
            "startElapsedMillis" to run.startElapsedMillis,
            "deadlineElapsedMillis" to run.deadlineElapsedMillis,
            "deadlineUtcMillis" to run.deadlineUtcMillis,
            "bootCount" to run.bootCount,
            "reminderThresholdMillis" to reminderThresholdMillis,
            "reminderDelivery" to reminderDelivery,
            "bannerDismissed" to bannerDismissed,
            "paused" to run.paused,
            "pausedRemainingMillis" to run.pausedRemainingMillis,
        )
    }

    /** 一次完整读取；三个部分取自同一时刻的时钟读数。 */
    data class Snapshot(
        val projects: List<ProjectRecord>,
        val activeRun: RunView?,
        val clock: RunClock.Reading,
    ) {
        fun toWireMap(): Map<String, Any?> = mapOf(
            "projects" to projects.map { it.toWireMap() },
            "activeRun" to activeRun?.toWireMap(),
            "clock" to clock.toWireMap(),
        )
    }

    /**
     * 启动结果。[cancelRunIds] 是事务内被顺带收尾或清理掉的旧运行；调用方必须在
     * 提交后取消它们的闹钟与已展示通知（事务里不能调用系统 API）。
     */
    data class StartRunResult(
        val run: RunView,
        val cancelRunIds: List<Long>,
    )

    /**
     * 重新计时结果：[previousRunId] 的闹钟与已展示通知必须在提交后撤销，
     * 新运行需要按项目设置重新登记提醒。
     */
    data class RestartRunResult(
        val previousRunId: Long,
        val run: RunView,
    )

    /**
     * 暂停/继续命令的数据库结果。
     *
     * [Active] 表示运行仍有效，携带更新后的快照；
     * [Elapsed] 表示运行在命令生效前已经归零，事务内已收尾并删除提醒行。调用方必须
     * 在提交后撤销闹钟与已展示通知，再按 run_not_running 回复 Dart——不能把刚结束的
     * 运行报告成暂停或继续成功，否则前台会继续显示一个已经停止的倒计时。
     */
    sealed class RunControlResult {
        class Active(val run: RunView) : RunControlResult()
        object Elapsed : RunControlResult()
    }

    /**
     * 闹钟登记计划。[triggerAtElapsedMillis] 是 `SystemClock.elapsedRealtime()` 基准的
     * 绝对触发时刻，与 AlarmManager.ELAPSED_REALTIME_WAKEUP 对齐。
     */
    data class ReminderPlan(
        val runId: Long,
        val triggerAtElapsedMillis: Long,
        val thresholdMillis: Long,
    )

    /**
     * 后台接收器成功认领的一轮提醒。[remainingMillis] 是认领时刻的真实剩余时间：
     * 非精确闹钟可能晚到，通知正文必须按它换算，而不是沿用登记时的阈值。
     */
    data class NotificationClaim(
        val runId: Long,
        val projectName: String,
        val remainingMillis: Long,
    )

    /** 业务错误；[code] 直接作为 PlatformException 的错误码返回 Dart。 */
    class StoreException(val code: String, message: String) : Exception(message)

    // --- 快照 -------------------------------------------------------------

    /**
     * 读取完整快照。只读：只发起查询，不写入任何行。
     *
     * 用只读事务包住三次查询，避免读到「运行已提交但提醒行尚未可见」这类中间态；
     * 事务通过 [SQLiteDatabase.setTransactionSuccessful] 正常结束，没有 DML。
     */
    fun readSnapshot(): Snapshot {
        val reading = clock.now()
        val db = readableDatabase
        db.beginTransactionNonExclusive()
        try {
            val activeRun = queryActiveRun(db)
            val projects = queryProjectRecords(db, reading)
            db.setTransactionSuccessful()
            return Snapshot(projects = projects, activeRun = activeRun, clock = reading)
        } finally {
            db.endTransaction()
        }
    }

    fun readClock(): RunClock.Reading = clock.now()

    // --- 项目 -------------------------------------------------------------

    /**
     * 保存项目。
     *
     * 校验规则来自 repository.dart：名称去首尾空格后非空；总秒数大于 0；
     * 提醒阈值为 null（关闭）或正整数秒且严格小于总时长，否则提醒时刻会落在开始之前。
     */
    fun createProject(name: String, totalSeconds: Long, reminderSeconds: Int?): ProjectRecord {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) {
            throw StoreException(ERROR_INVALID_PROJECT, "project name must not be blank")
        }
        if (totalSeconds <= 0L) {
            throw StoreException(ERROR_INVALID_PROJECT, "totalSeconds must be positive")
        }
        if (reminderSeconds != null && (reminderSeconds <= 0 || reminderSeconds.toLong() >= totalSeconds)) {
            throw StoreException(ERROR_INVALID_PROJECT, "reminderSeconds must be a positive integer second below totalSeconds")
        }

        val createdAtUtcMillis = System.currentTimeMillis()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val values = ContentValues().apply {
                put(COL_NAME, trimmedName)
                put(COL_TOTAL_SECONDS, totalSeconds)
                if (reminderSeconds == null) {
                    putNull(COL_REMINDER_SECONDS)
                } else {
                    put(COL_REMINDER_SECONDS, reminderSeconds)
                }
                put(COL_CREATED_AT_UTC, createdAtUtcMillis)
                put(COL_IS_TEMPORARY, 0)
            }
            val id = db.insertOrThrow(TABLE_PROJECTS, null, values)
            db.setTransactionSuccessful()
            return ProjectRecord(
                row = ProjectRow(
                    id = id,
                    name = trimmedName,
                    totalSeconds = totalSeconds,
                    reminderSeconds = reminderSeconds,
                    createdAtUtcMillis = createdAtUtcMillis,
                    isTemporary = false,
                ),
                state = STATE_IDLE,
            )
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 删除项目及其全部运行与提醒。目标不存在时视为已完成，不抛错。
     *
     * 返回被删掉的运行 ID；调用方在提交后按这些 ID 撤销闹钟与已展示的通知。
     */
    fun deleteProject(projectId: Long): List<Long> {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val runIds = queryRunIdsOfProject(db, projectId)
            deleteProjectRows(db, projectId)
            db.setTransactionSuccessful()
            return runIds
        } finally {
            db.endTransaction()
        }
    }

    // --- 运行 -------------------------------------------------------------

    /**
     * 启动新一轮运行。整个过程在单个事务内完成：
     * 1. 把「status='running' 且剩余<=0」的旧运行收尾并删除其提醒行（提交后取消闹钟）；
     * 2. 仍存在 running 运行则抛 run_already_active（同一时刻只允许一轮）；
     * 3. 项目不存在抛 project_not_found；
     * 4. 插入运行行（截止点同时记录单调钟与 UTC），项目开启提醒时插入 reminders 行。
     *
     * 事务内只改数据库，闹钟登记与通知撤销交给调用方在提交后执行。
     */
    fun startRun(projectId: Long): StartRunResult {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val runningRuns = queryRunningRuns(db)
            val cancelRunIds = finishElapsedRuns(db, reading, runningRuns)
            if (runningRuns.any { it.id !in cancelRunIds }) {
                // 事务整体回滚：没有产生新运行，调用方保留列表页并提示重试。
                throw StoreException(ERROR_RUN_ALREADY_ACTIVE, "another run is still active")
            }

            val project = queryProject(db, projectId)
                ?: throw StoreException(ERROR_PROJECT_NOT_FOUND, "project $projectId not found")

            val run = insertRun(
                db = db,
                projectId = project.id,
                nameSnapshot = project.name,
                totalSeconds = project.totalSeconds,
                reminderSeconds = project.reminderSeconds,
                reading = reading,
            )
            db.setTransactionSuccessful()
            return StartRunResult(run = run, cancelRunIds = cancelRunIds)
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 用滚轮选出的时长启动一轮临时运行（首页快启）。
     *
     * 与 [startRun] 相同的「一次只允许一轮」规则，另外：
     * - 临时项目名固定为 [TEMPORARY_PROJECT_NAME]、关闭提醒，不写 reminders 行；
     * - 上次快启被中断留下的临时项目（没有 running 运行）在这里一并清理，
     *   避免残留项目长期占用 is_temporary 行。
     *
     * 事务提交后再由调用方撤销被收尾/清理旧运行的闹钟与通知。
     */
    fun startTemporaryRun(totalSeconds: Long): StartRunResult {
        if (totalSeconds <= 0L) {
            throw StoreException(ERROR_INVALID_PROJECT, "totalSeconds must be positive")
        }
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val runningRuns = queryRunningRuns(db)
            val cancelRunIds = ArrayList(finishElapsedRuns(db, reading, runningRuns))
            if (runningRuns.any { it.id !in cancelRunIds }) {
                throw StoreException(ERROR_RUN_ALREADY_ACTIVE, "another run is still active")
            }

            // 清理遗留临时项目：取消/归零会立即删除临时项目，所以「没有 running 运行
            // 的临时项目」只可能是上次快启在提交后、系统撤销提醒前被中断留下的。
            cancelRunIds += deleteOrphanTemporaryProjects(db)

            val projectValues = ContentValues().apply {
                put(COL_NAME, TEMPORARY_PROJECT_NAME)
                put(COL_TOTAL_SECONDS, totalSeconds)
                putNull(COL_REMINDER_SECONDS)
                put(COL_CREATED_AT_UTC, reading.utcMillis)
                put(COL_IS_TEMPORARY, 1)
            }
            val projectId = db.insertOrThrow(TABLE_PROJECTS, null, projectValues)
            val run = insertRun(
                db = db,
                projectId = projectId,
                nameSnapshot = TEMPORARY_PROJECT_NAME,
                totalSeconds = totalSeconds,
                reminderSeconds = null,
                reading = reading,
            )
            db.setTransactionSuccessful()
            return StartRunResult(run = run, cancelRunIds = cancelRunIds)
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 暂停本轮。
     *
     * 事务内取一次时钟读数算出准确剩余并冻结：暂停期间单调钟与 UTC 都还在走，
     * 不冻结毫秒数而沿用原 deadline 会让剩余时间在暂停中继续减少。deadline 列保持
     * 原值不动——暂停态下不参与换算，继续时会用冻结值重建两个截止基准。
     *
     * 已暂停时幂等返回当前快照；运行已归零时事务内收尾，返回 [RunControlResult.Elapsed]，
     * 由调用方撤销闹钟与通知后报告 run_not_running。提醒行不删除：已投递状态（前台
     * 提示条或系统通知）要跨暂停保留，继续后不再重复提醒。
     */
    fun pauseRun(runId: Long): RunControlResult {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId)
                ?: throw StoreException(ERROR_RUN_NOT_FOUND, "run $runId not found")
            if (run.status != RUN_STATUS_RUNNING) {
                throw StoreException(ERROR_RUN_NOT_RUNNING, "run $runId is not running")
            }
            if (run.paused) {
                // 连点或重复命令：保留第一次冻结的剩余时间，不做任何 DML。
                db.setTransactionSuccessful()
                return RunControlResult.Active(queryRunView(db, run))
            }
            val remainingMillis = clock.remainingOf(reading, run)
            if (remainingMillis <= 0L) {
                markRunFinished(db, run, reading.utcMillis)
                db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(runId.toString()))
                db.setTransactionSuccessful()
                return RunControlResult.Elapsed
            }
            val values = ContentValues().apply {
                put(COL_PAUSED, 1)
                put(COL_PAUSED_REMAINING, remainingMillis)
            }
            db.update(TABLE_RUNS, values, "$COL_ID = ?", arrayOf(runId.toString()))
            db.setTransactionSuccessful()
            return RunControlResult.Active(
                queryRunView(db, run.copy(paused = true, pausedRemainingMillis = remainingMillis)),
            )
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 继续本轮：用暂停时冻结的剩余毫秒重建截止点，继续同一个运行 ID。
     *
     * 暂停期间经过的实际时长不计入，因此两个截止基准都要用「同一次读数 + 冻结剩余」
     * 重算，并写入当前 boot_count；`start_elapsed` 保持不变（它只用于诊断本轮起点）。
     * 未暂停时幂等返回；冻结值缺失或非正说明本轮已归零，收尾后返回
     * [RunControlResult.Elapsed]。闹钟重登记由调用方在提交后按新截止点执行。
     */
    fun resumeRun(runId: Long): RunControlResult {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId)
                ?: throw StoreException(ERROR_RUN_NOT_FOUND, "run $runId not found")
            if (run.status != RUN_STATUS_RUNNING) {
                throw StoreException(ERROR_RUN_NOT_RUNNING, "run $runId is not running")
            }
            if (!run.paused) {
                // 连点或重复命令：运行已经在走，直接返回当前快照。
                db.setTransactionSuccessful()
                return RunControlResult.Active(queryRunView(db, run))
            }
            val remainingMillis = run.pausedRemainingMillis
            if (remainingMillis == null || remainingMillis <= 0L) {
                markRunFinished(db, run, reading.utcMillis)
                db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(runId.toString()))
                db.setTransactionSuccessful()
                return RunControlResult.Elapsed
            }
            val values = ContentValues().apply {
                put(COL_DEADLINE_ELAPSED, reading.elapsedMillis + remainingMillis)
                put(COL_DEADLINE_UTC, reading.utcMillis + remainingMillis)
                put(COL_BOOT_COUNT, reading.bootCount)
                put(COL_PAUSED, 0)
                putNull(COL_PAUSED_REMAINING)
            }
            db.update(TABLE_RUNS, values, "$COL_ID = ?", arrayOf(runId.toString()))
            db.setTransactionSuccessful()
            return RunControlResult.Active(
                queryRunView(
                    db,
                    run.copy(
                        deadlineElapsedMillis = reading.elapsedMillis + remainingMillis,
                        deadlineUtcMillis = reading.utcMillis + remainingMillis,
                        bootCount = reading.bootCount,
                        paused = false,
                        pausedRemainingMillis = null,
                    ),
                ),
            )
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 重新计时：把当前轮置为 'restarted'，用本轮最初的总时长插入一轮新运行。
     *
     * 暂停中也可以重新计时。新运行的提醒阈值取自项目当前设置（临时项目没有提醒行，
     * 因此永远不会插入 reminders）；旧运行的提醒行直接删除，投递状态不继承——新一轮
     * 应当能再次提醒。提交后调用方撤销旧运行的闹钟与通知，并登记新运行的提醒。
     */
    fun restartRun(runId: Long): RestartRunResult {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val previousRun = queryRun(db, runId)
                ?: throw StoreException(ERROR_RUN_NOT_FOUND, "run $runId not found")
            if (previousRun.status != RUN_STATUS_RUNNING) {
                throw StoreException(ERROR_RUN_NOT_RUNNING, "run $runId is not running")
            }
            db.update(
                TABLE_RUNS,
                ContentValues().apply {
                    put(COL_STATUS, RUN_STATUS_RESTARTED)
                    put(COL_PAUSED, 0)
                    putNull(COL_PAUSED_REMAINING)
                },
                "$COL_ID = ?",
                arrayOf(runId.toString()),
            )
            db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(runId.toString()))

            val project = queryProject(db, previousRun.projectId)
            val newRun = insertRun(
                db = db,
                projectId = previousRun.projectId,
                nameSnapshot = previousRun.nameSnapshot,
                totalSeconds = previousRun.totalSeconds,
                reminderSeconds = project?.reminderSeconds,
                reading = reading,
            )
            db.setTransactionSuccessful()
            return RestartRunResult(previousRunId = runId, run = newRun)
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 取消本轮。
     *
     * 保存的常用项目只结束当前运行（置 'cancelled'、删提醒行），项目保留、可再次启动；
     * 临时项目没有需要保留的历史，连同它的全部运行与提醒一起删除。目标运行已不存在时
     * 幂等成功，不抛错。提交后调用方撤销该运行的闹钟与已展示通知。
     */
    fun cancelRun(runId: Long) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId) ?: return
            val project = queryProject(db, run.projectId)
            if (project?.isTemporary == true) {
                // 临时项目只服务于这一轮快启：留着空项目会让列表过滤与「无 running
                // 运行即清理」的规则长期兜底，也不符合「取消后不进入常用列表」的语义。
                deleteProjectRows(db, project.id)
            } else if (run.status == RUN_STATUS_RUNNING) {
                db.update(
                    TABLE_RUNS,
                    ContentValues().apply {
                        put(COL_STATUS, RUN_STATUS_CANCELLED)
                        put(COL_PAUSED, 0)
                        putNull(COL_PAUSED_REMAINING)
                    },
                    "$COL_ID = ?",
                    arrayOf(runId.toString()),
                )
                db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(runId.toString()))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 结束一轮运行并删除其待发提醒。
     *
     * 幂等：重复调用保留首次结束时刻；目标运行不存在（已被删除或从未存在）时视为已完成，
     * 静默成功——归零收尾会重试，把「已经没有这轮运行」当成可重试错误没有意义。
     * 临时项目随归零一起消失：它没有可保留的历史运行，整项目在同一个事务里删除。
     */
    fun finishRun(runId: Long) {
        val finishedAtUtcMillis = clock.now().utcMillis
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId) ?: return
            val project = queryProject(db, run.projectId)
            if (project?.isTemporary == true) {
                deleteProjectRows(db, project.id)
            } else {
                markRunFinished(db, run, finishedAtUtcMillis)
                db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(runId.toString()))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 前台运行页认领本轮提醒。
     *
     * 事务内的条件更新是前后台去重的唯一裁决点：affected == 1 才说明本次认领成功；
     * 运行已被删除/结束或剩余<=0 时一律返回 false，不显示提示条。暂停时剩余取冻结值，
     * 因此暂停中的轮次不会因为 deadline 继续流逝而被误判为已结束。
     */
    fun claimForegroundReminder(runId: Long): Boolean {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId)
            // 暂停中的轮次不认领新提醒：冻结值不会再次跨过阈值，继续时按新截止点重新判断。
            if (run == null || run.status != RUN_STATUS_RUNNING || run.paused ||
                remainingMillisOf(reading, run) <= 0L
            ) {
                return false
            }
            val affected = db.update(
                TABLE_REMINDERS,
                ContentValues().apply { put(COL_DELIVERY, DELIVERY_FOREGROUND) },
                "$COL_RUN_ID = ? AND $COL_DELIVERY = ?",
                arrayOf(runId.toString(), DELIVERY_NONE),
            )
            db.setTransactionSuccessful()
            return affected == 1
        } finally {
            db.endTransaction()
        }
    }

    /** 记录提示条已被用户收起。没有提醒行时静默忽略（本轮本来就没有提示条）。 */
    fun dismissBanner(runId: Long) {
        writableDatabase.update(
            TABLE_REMINDERS,
            ContentValues().apply { put(COL_BANNER_DISMISSED, 1) },
            "$COL_RUN_ID = ?",
            arrayOf(runId.toString()),
        )
    }

    // --- 提醒 -------------------------------------------------------------

    /**
     * 计算本轮的闹钟登记计划。返回 null 表示没有需要登记的时刻：
     * 运行不存在或已结束、暂停中、没有提醒行、剩余<=0，或已经越过阈值（不补发）。
     *
     * 暂停中一律返回 null：暂停态没有可信的 deadline，继续时会重建并重新登记；
     * 调用方据 null 撤销可能残留的闹钟，避免暂停期间仍有旧闹钟唤起接收器。
     */
    fun reminderSchedulePlan(runId: Long): ReminderPlan? {
        val reading = clock.now()
        val db = readableDatabase
        val run = queryRun(db, runId) ?: return null
        if (run.status != RUN_STATUS_RUNNING) return null
        if (run.paused) return null
        val remainingMillis = clock.remainingOf(reading, run)
        if (remainingMillis <= 0L) return null
        val thresholdMillis = queryReminderThreshold(db, runId) ?: return null
        val delayMillis = remainingMillis - thresholdMillis
        if (delayMillis <= 0L) return null
        return ReminderPlan(
            runId = runId,
            triggerAtElapsedMillis = reading.elapsedMillis + delayMillis,
            thresholdMillis = thresholdMillis,
        )
    }

    /**
     * 后台接收器在事务内重新校验并认领提醒。
     *
     * 返回非 null 才允许发通知：运行必须仍在正向计时（status='running'、未暂停、
     * 剩余>0）且 delivery 仍为 'none'。暂停、取消、重新计时都会撤销闹钟，但闹钟可能
     * 已经被系统触发并在 worker 队列里排队；只有提交前重查这些状态，才能保证旧轮的
     * 迟到广播不会投递通知。这一步与删除/结束路径共用同一张表和同一条串行队列。
     */
    fun claimNotificationReminder(runId: Long): NotificationClaim? {
        val reading = clock.now()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val run = queryRun(db, runId)
            if (run == null || run.status != RUN_STATUS_RUNNING || run.paused) {
                return null
            }
            val remainingMillis = clock.remainingOf(reading, run)
            if (remainingMillis <= 0L) {
                return null
            }
            val affected = db.update(
                TABLE_REMINDERS,
                ContentValues().apply {
                    put(COL_DELIVERY, DELIVERY_NOTIFICATION)
                    // 闹钟已触发，本行不再有待发时刻；scheduled 只用于诊断登记状态。
                    put(COL_SCHEDULED, 0)
                },
                "$COL_RUN_ID = ? AND $COL_DELIVERY = ?",
                arrayOf(runId.toString(), DELIVERY_NONE),
            )
            if (affected != 1) return null
            db.setTransactionSuccessful()
            return NotificationClaim(
                runId = runId,
                projectName = run.nameSnapshot,
                remainingMillis = remainingMillis,
            )
        } finally {
            db.endTransaction()
        }
    }

    /**
     * 通知投递失败时把认领退回未投递，让前台提示条仍有机会表达本轮提醒。
     * 仅当状态仍是本次认领写入的 'notification' 才回退，不影响已由前台认领的记录。
     */
    fun releaseNotificationClaim(runId: Long) {
        writableDatabase.update(
            TABLE_REMINDERS,
            ContentValues().apply { put(COL_DELIVERY, DELIVERY_NONE) },
            "$COL_RUN_ID = ? AND $COL_DELIVERY = ?",
            arrayOf(runId.toString(), DELIVERY_NOTIFICATION),
        )
    }

    /**
     * 记录本轮是否已经登记系统闹钟。该字段只用于诊断登记结果，读取路径不依赖它；
     * 提醒行随运行结束被删除，因此不需要额外清理。
     */
    fun markReminderScheduled(runId: Long, scheduled: Boolean) {
        writableDatabase.update(
            TABLE_REMINDERS,
            ContentValues().apply { put(COL_SCHEDULED, if (scheduled) 1 else 0) },
            "$COL_RUN_ID = ?",
            arrayOf(runId.toString()),
        )
    }

    // --- 查询辅助 ---------------------------------------------------------

    /**
     * 本轮剩余毫秒数：暂停时取冻结值（与时钟无关），否则沿用 [RunClock] 的双基准换算。
     * 事务内多次判断必须共用同一次 [RunClock.Reading]，避免跨读数边界。
     */
    private fun remainingMillisOf(reading: RunClock.Reading, run: RunRecord): Long {
        if (run.paused) {
            return run.pausedRemainingMillis ?: 0L
        }
        return clock.remainingOf(reading, run)
    }

    /**
     * 收尾所有已归零的 running 运行：置为 finished、删除其待发提醒，并返回这些运行 ID
     * 供调用方在提交后撤销系统闹钟与通知。暂停中的运行取冻结值，正常不会归零，因此
     * 不会被这里提前收尾。调用方必须已处在事务内。
     */
    private fun finishElapsedRuns(
        db: SQLiteDatabase,
        reading: RunClock.Reading,
        runningRuns: List<RunRecord>,
    ): List<Long> {
        val finishedRunIds = ArrayList<Long>()
        for (run in runningRuns) {
            if (remainingMillisOf(reading, run) > 0L) continue
            markRunFinished(db, run, reading.utcMillis)
            db.delete(TABLE_REMINDERS, "$COL_RUN_ID = ?", arrayOf(run.id.toString()))
            finishedRunIds += run.id
        }
        return finishedRunIds
    }

    /**
     * 插入新一轮运行：用同一次读数同时写单调钟与 UTC 截止点，paused=0。
     * 项目开启提醒时插入对应的 reminders 行，阈值以毫秒保存（提醒秒数 × 1000）；
     * 本轮阈值一旦写入就只按毫秒使用，项目后来改单位也不会二次换算。
     * 调用方必须已处在事务内。
     */
    private fun insertRun(
        db: SQLiteDatabase,
        projectId: Long,
        nameSnapshot: String,
        totalSeconds: Long,
        reminderSeconds: Int?,
        reading: RunClock.Reading,
    ): RunView {
        val totalMillis = totalSeconds * 1000L
        val runValues = ContentValues().apply {
            put(COL_PROJECT_ID, projectId)
            put(COL_NAME_SNAPSHOT, nameSnapshot)
            put(COL_TOTAL_SECONDS, totalSeconds)
            put(COL_START_ELAPSED, reading.elapsedMillis)
            put(COL_DEADLINE_ELAPSED, reading.elapsedMillis + totalMillis)
            put(COL_DEADLINE_UTC, reading.utcMillis + totalMillis)
            put(COL_BOOT_COUNT, reading.bootCount)
            put(COL_STATUS, RUN_STATUS_RUNNING)
            putNull(COL_FINISHED_AT_UTC)
            put(COL_PAUSED, 0)
            putNull(COL_PAUSED_REMAINING)
        }
        val runId = db.insertOrThrow(TABLE_RUNS, null, runValues)

        val thresholdMillis = reminderSeconds?.toLong()?.times(1000L)
        if (thresholdMillis != null) {
            val reminderValues = ContentValues().apply {
                put(COL_RUN_ID, runId)
                put(COL_THRESHOLD_MILLIS, thresholdMillis)
                put(COL_DELIVERY, DELIVERY_NONE)
                put(COL_BANNER_DISMISSED, 0)
                put(COL_SCHEDULED, 0)
            }
            db.insertOrThrow(TABLE_REMINDERS, null, reminderValues)
        }

        return RunView(
            run = RunRecord(
                id = runId,
                projectId = projectId,
                nameSnapshot = nameSnapshot,
                totalSeconds = totalSeconds,
                startElapsedMillis = reading.elapsedMillis,
                deadlineElapsedMillis = reading.elapsedMillis + totalMillis,
                deadlineUtcMillis = reading.utcMillis + totalMillis,
                bootCount = reading.bootCount,
                status = RUN_STATUS_RUNNING,
                finishedAtUtcMillis = null,
                paused = false,
                pausedRemainingMillis = null,
            ),
            reminderThresholdMillis = thresholdMillis,
            reminderDelivery = DELIVERY_NONE,
            bannerDismissed = false,
        )
    }

    /** 删除项目、其全部运行与提醒行；不开启事务，调用方负责事务边界。 */
    private fun deleteProjectRows(db: SQLiteDatabase, projectId: Long) {
        // reminders 以 run_id 关联且没有外键约束，先按子查询清掉再删运行行。
        db.delete(
            TABLE_REMINDERS,
            "$COL_RUN_ID IN (SELECT $COL_ID FROM $TABLE_RUNS WHERE $COL_PROJECT_ID = ?)",
            arrayOf(projectId.toString()),
        )
        db.delete(TABLE_RUNS, "$COL_PROJECT_ID = ?", arrayOf(projectId.toString()))
        db.delete(TABLE_PROJECTS, "$COL_ID = ?", arrayOf(projectId.toString()))
    }

    /**
     * 删除所有「临时项目且没有任何 running 运行」的项目及其 runs/reminders，返回被删掉的
     * 运行 ID 供提交后撤销可能残留的闹钟与通知。仍有 running 运行的临时项目属于当前
     * 活动轮次，不能删除。调用方必须已处在事务内。
     */
    private fun deleteOrphanTemporaryProjects(db: SQLiteDatabase): List<Long> {
        val projectIds = ArrayList<Long>()
        db.rawQuery(SQL_ORPHAN_TEMPORARY_PROJECTS, null).use { cursor ->
            while (cursor.moveToNext()) {
                projectIds += cursor.getLong(0)
            }
        }
        val runIds = ArrayList<Long>()
        for (projectId in projectIds) {
            runIds += queryRunIdsOfProject(db, projectId)
            deleteProjectRows(db, projectId)
        }
        return runIds
    }

    private fun queryProjectRecords(db: SQLiteDatabase, reading: RunClock.Reading): List<ProjectRecord> {
        val records = ArrayList<ProjectRecord>()
        db.rawQuery(SQL_PROJECT_LIST, null).use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(COL_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(COL_NAME)
            val totalSecondsIndex = cursor.getColumnIndexOrThrow(COL_TOTAL_SECONDS)
            val reminderSecondsIndex = cursor.getColumnIndexOrThrow(COL_REMINDER_SECONDS)
            val createdAtIndex = cursor.getColumnIndexOrThrow(COL_CREATED_AT_UTC)
            val statusIndex = cursor.getColumnIndexOrThrow(COL_LATEST_RUN_STATUS)
            val deadlineElapsedIndex = cursor.getColumnIndexOrThrow(COL_DEADLINE_ELAPSED)
            val deadlineUtcIndex = cursor.getColumnIndexOrThrow(COL_DEADLINE_UTC)
            val bootCountIndex = cursor.getColumnIndexOrThrow(COL_BOOT_COUNT)
            val pausedIndex = cursor.getColumnIndexOrThrow(COL_PAUSED)
            val pausedRemainingIndex = cursor.getColumnIndexOrThrow(COL_PAUSED_REMAINING)

            while (cursor.moveToNext()) {
                val latestStatus = if (cursor.isNull(statusIndex)) null else cursor.getString(statusIndex)
                val paused = !cursor.isNull(pausedIndex) && cursor.getInt(pausedIndex) != 0
                val remainingMillis = when {
                    latestStatus == null -> 0L
                    paused -> if (cursor.isNull(pausedRemainingIndex)) 0L else cursor.getLong(pausedRemainingIndex)
                    else -> clock.remainingOf(
                        reading = reading,
                        deadlineElapsedMillis = cursor.getLong(deadlineElapsedIndex),
                        deadlineUtcMillis = cursor.getLong(deadlineUtcIndex),
                        bootCount = cursor.getInt(bootCountIndex),
                    )
                }
                if (latestStatus == RUN_STATUS_RUNNING && remainingMillis > 0L) {
                    // 仍在计时（或暂停中仍有剩余）的项目由 activeRun 表达，不出现在列表里。
                    continue
                }
                val state = if (latestStatus == RUN_STATUS_FINISHED ||
                    (latestStatus == RUN_STATUS_RUNNING && remainingMillis <= 0L)
                ) {
                    STATE_FINISHED
                } else {
                    STATE_IDLE
                }
                records += ProjectRecord(
                    row = ProjectRow(
                        id = cursor.getLong(idIndex),
                        name = cursor.getString(nameIndex),
                        totalSeconds = cursor.getLong(totalSecondsIndex),
                        reminderSeconds = if (cursor.isNull(reminderSecondsIndex)) {
                            null
                        } else {
                            cursor.getInt(reminderSecondsIndex)
                        },
                        createdAtUtcMillis = cursor.getLong(createdAtIndex),
                        isTemporary = false,
                    ),
                    state = state,
                )
            }
        }
        return records
    }

    /**
     * 当前运行：全局最多一条 status='running' 的运行，运行中与暂停中都返回。
     * 暂停时剩余时间取冻结值，由 Flutter 侧按 RunSnapshot 的暂停语义换算。
     * 剩余<=0 的运行不再显示主卡，但这里仍原样返回，由 Flutter 侧按剩余时间过滤，
     * 宿主不擅自把「已过期未收尾」的运行隐藏掉。
     */
    private fun queryActiveRun(db: SQLiteDatabase): RunView? {
        db.rawQuery(SQL_ACTIVE_RUN, null).use { cursor ->
            if (!cursor.moveToFirst()) return null
            val run = readRun(cursor)
            val thresholdIndex = cursor.getColumnIndexOrThrow(COL_THRESHOLD_MILLIS)
            val deliveryIndex = cursor.getColumnIndexOrThrow(COL_DELIVERY)
            val bannerIndex = cursor.getColumnIndexOrThrow(COL_BANNER_DISMISSED)
            return RunView(
                run = run,
                reminderThresholdMillis = if (cursor.isNull(thresholdIndex)) null else cursor.getLong(thresholdIndex),
                reminderDelivery = if (cursor.isNull(deliveryIndex)) DELIVERY_NONE else cursor.getString(deliveryIndex),
                bannerDismissed = !cursor.isNull(bannerIndex) && cursor.getInt(bannerIndex) != 0,
            )
        }
    }

    private fun queryProject(db: SQLiteDatabase, projectId: Long): ProjectRow? {
        db.rawQuery(SQL_PROJECT_BY_ID, arrayOf(projectId.toString())).use { cursor ->
            if (!cursor.moveToFirst()) return null
            return ProjectRow(
                id = cursor.getLong(cursor.getColumnIndexOrThrow(COL_ID)),
                name = cursor.getString(cursor.getColumnIndexOrThrow(COL_NAME)),
                totalSeconds = cursor.getLong(cursor.getColumnIndexOrThrow(COL_TOTAL_SECONDS)),
                reminderSeconds = cursor.getColumnIndexOrThrow(COL_REMINDER_SECONDS).let { index ->
                    if (cursor.isNull(index)) null else cursor.getInt(index)
                },
                createdAtUtcMillis = cursor.getLong(cursor.getColumnIndexOrThrow(COL_CREATED_AT_UTC)),
                isTemporary = cursor.getInt(cursor.getColumnIndexOrThrow(COL_IS_TEMPORARY)) != 0,
            )
        }
    }

    private fun queryRun(db: SQLiteDatabase, runId: Long): RunRecord? {
        db.rawQuery(SQL_RUN_BY_ID, arrayOf(runId.toString())).use { cursor ->
            return if (cursor.moveToFirst()) readRun(cursor) else null
        }
    }

    /** 读取运行及其提醒投递状态；没有提醒行时对应字段取默认值。 */
    private fun queryRunView(db: SQLiteDatabase, run: RunRecord): RunView {
        db.rawQuery(SQL_REMINDER_OF_RUN, arrayOf(run.id.toString())).use { cursor ->
            if (!cursor.moveToFirst()) {
                return RunView(
                    run = run,
                    reminderThresholdMillis = null,
                    reminderDelivery = DELIVERY_NONE,
                    bannerDismissed = false,
                )
            }
            return RunView(
                run = run,
                reminderThresholdMillis = cursor.getLong(cursor.getColumnIndexOrThrow(COL_THRESHOLD_MILLIS)),
                reminderDelivery = cursor.getString(cursor.getColumnIndexOrThrow(COL_DELIVERY)),
                bannerDismissed = cursor.getInt(cursor.getColumnIndexOrThrow(COL_BANNER_DISMISSED)) != 0,
            )
        }
    }

    private fun queryRunningRuns(db: SQLiteDatabase): List<RunRecord> {
        val runs = ArrayList<RunRecord>()
        db.rawQuery(SQL_RUNNING_RUNS, null).use { cursor ->
            while (cursor.moveToNext()) {
                runs += readRun(cursor)
            }
        }
        return runs
    }

    private fun queryRunIdsOfProject(db: SQLiteDatabase, projectId: Long): List<Long> {
        val runIds = ArrayList<Long>()
        db.rawQuery(SQL_RUN_IDS_OF_PROJECT, arrayOf(projectId.toString())).use { cursor ->
            while (cursor.moveToNext()) {
                runIds += cursor.getLong(0)
            }
        }
        return runIds
    }

    private fun queryReminderThreshold(db: SQLiteDatabase, runId: Long): Long? {
        db.rawQuery(SQL_REMINDER_THRESHOLD, arrayOf(runId.toString())).use { cursor ->
            return if (cursor.moveToFirst()) cursor.getLong(0) else null
        }
    }

    private fun readRun(cursor: Cursor): RunRecord {
        val finishedAtIndex = cursor.getColumnIndexOrThrow(COL_FINISHED_AT_UTC)
        val pausedRemainingIndex = cursor.getColumnIndexOrThrow(COL_PAUSED_REMAINING)
        return RunRecord(
            id = cursor.getLong(cursor.getColumnIndexOrThrow(COL_ID)),
            projectId = cursor.getLong(cursor.getColumnIndexOrThrow(COL_PROJECT_ID)),
            nameSnapshot = cursor.getString(cursor.getColumnIndexOrThrow(COL_NAME_SNAPSHOT)),
            totalSeconds = cursor.getLong(cursor.getColumnIndexOrThrow(COL_TOTAL_SECONDS)),
            startElapsedMillis = cursor.getLong(cursor.getColumnIndexOrThrow(COL_START_ELAPSED)),
            deadlineElapsedMillis = cursor.getLong(cursor.getColumnIndexOrThrow(COL_DEADLINE_ELAPSED)),
            deadlineUtcMillis = cursor.getLong(cursor.getColumnIndexOrThrow(COL_DEADLINE_UTC)),
            bootCount = cursor.getInt(cursor.getColumnIndexOrThrow(COL_BOOT_COUNT)),
            status = cursor.getString(cursor.getColumnIndexOrThrow(COL_STATUS)),
            finishedAtUtcMillis = if (cursor.isNull(finishedAtIndex)) null else cursor.getLong(finishedAtIndex),
            paused = cursor.getInt(cursor.getColumnIndexOrThrow(COL_PAUSED)) != 0,
            pausedRemainingMillis = if (cursor.isNull(pausedRemainingIndex)) {
                null
            } else {
                cursor.getLong(pausedRemainingIndex)
            },
        )
    }

    /**
     * 把运行置为已结束。已结束的运行保留首次结束时刻，重复调用不会改写历史；
     * 同时清掉暂停标记——结束的运行不再有暂停语义，避免快照里出现 paused=true 的历史行。
     * 调用方必须已处在事务内。
     */
    private fun markRunFinished(db: SQLiteDatabase, run: RunRecord, finishedAtUtcMillis: Long) {
        val values = ContentValues().apply {
            put(COL_STATUS, RUN_STATUS_FINISHED)
            put(COL_PAUSED, 0)
            putNull(COL_PAUSED_REMAINING)
            if (run.finishedAtUtcMillis == null) {
                put(COL_FINISHED_AT_UTC, finishedAtUtcMillis)
            }
        }
        db.update(TABLE_RUNS, values, "$COL_ID = ?", arrayOf(run.id.toString()))
    }

    // --- 建表与迁移 -------------------------------------------------------

    /** 新库直接建到当前版本；结构必须与 [onUpgrade] 迁移后的结果一致。 */
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(SQL_CREATE_PROJECTS)
        db.execSQL(SQL_CREATE_RUNS)
        db.execSQL(SQL_CREATE_REMINDERS)
        // runs 的主查询与删除都按 project_id 过滤，建索引避免每次全表扫描。
        db.execSQL(SQL_CREATE_RUNS_PROJECT_INDEX)
    }

    /**
     * 逐版本迁移，每个分支只升一级，且只允许使用保留数据的 ALTER / CREATE / 表重建。
     *
     * SQLiteOpenHelper 已把 onUpgrade 包在事务里：任一语句失败会整体回滚，不会留下
     * 半升级的表。
     * - v1 → v2：只加列。历史项目 is_temporary 取默认 0（仍进列表），历史运行 paused 取
     *   默认 0、paused_remaining_millis 为 NULL（按原 deadline 计时）。
     * - v2 → v3：projects 的提醒阈值从整分钟改为秒，SQLite 不能改列单位，因此按
     *   「建新表 → 复制并换算 → 删旧表 → 改名」重建；runs / reminders 不动，运行中已按
     *   毫秒保存的 threshold_millis 原样保留，不做二次换算。
     */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        var version = oldVersion
        while (version < newVersion) {
            when (version) {
                // 从 0 升到 1 没有可迁移的数据：v0 结构从未发布过。
                0 -> Unit
                1 -> {
                    db.execSQL(SQL_MIGRATE_V2_PROJECTS_IS_TEMPORARY)
                    db.execSQL(SQL_MIGRATE_V2_RUNS_PAUSED)
                    db.execSQL(SQL_MIGRATE_V2_RUNS_PAUSED_REMAINING)
                }
                2 -> {
                    db.execSQL(SQL_MIGRATE_V3_CREATE_PROJECTS)
                    db.execSQL(SQL_MIGRATE_V3_COPY_PROJECTS)
                    db.execSQL(SQL_MIGRATE_V3_MERGE_PROJECT_SEQUENCE)
                    db.execSQL(SQL_MIGRATE_V3_ENSURE_PROJECT_SEQUENCE)
                    db.execSQL(SQL_MIGRATE_V3_DROP_PROJECTS)
                    db.execSQL(SQL_MIGRATE_V3_RENAME_PROJECTS)
                    db.execSQL(SQL_MIGRATE_V3_RESTORE_PROJECT_SEQUENCE)
                    db.execSQL(SQL_MIGRATE_V3_DROP_STALE_SEQUENCE)
                }
                else -> error("missing migration branch for schema version $version")
            }
            version += 1
        }
    }

    companion object {
        /**
         * 宿主侧唯一的串行执行队列。
         *
         * Activity 的通道任务、闹钟接收器的投递任务都提交到这里：数据库事务和系统通知
         * 投递因此不会与删除/结束路径交错（删除后不会再冒出迟到的通知）。任务内部
         * 不得同步等待主线程，否则会与 MethodChannel 回调互相阻塞。
         */
        val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
            Thread(task, "countdown-host-worker")
        }

        @Volatile
        private var instance: TimerStore? = null

        /** 进程内单例：Activity 与接收器共用同一个数据库连接，避免多份连接各自开事务。 */
        fun get(context: Context): TimerStore {
            val existing = instance
            if (existing != null) return existing
            return synchronized(this) {
                val created = instance ?: run {
                    val appContext = context.applicationContext
                    TimerStore(appContext, RunClock(appContext)).also { instance = it }
                }
                created
            }
        }

        private const val DATABASE_NAME = "countdown.db"
        private const val DATABASE_VERSION = 3

        private const val TABLE_PROJECTS = "projects"
        private const val TABLE_RUNS = "runs"
        private const val TABLE_REMINDERS = "reminders"

        private const val COL_ID = "id"
        private const val COL_NAME = "name"
        private const val COL_TOTAL_SECONDS = "total_seconds"
        private const val COL_REMINDER_SECONDS = "reminder_seconds"
        private const val COL_CREATED_AT_UTC = "created_at_utc"
        private const val COL_IS_TEMPORARY = "is_temporary"
        private const val COL_PROJECT_ID = "project_id"
        private const val COL_NAME_SNAPSHOT = "name_snapshot"
        private const val COL_START_ELAPSED = "start_elapsed"
        private const val COL_DEADLINE_ELAPSED = "deadline_elapsed"
        private const val COL_DEADLINE_UTC = "deadline_utc"
        private const val COL_BOOT_COUNT = "boot_count"
        private const val COL_STATUS = "status"
        private const val COL_FINISHED_AT_UTC = "finished_at_utc"
        private const val COL_PAUSED = "paused"
        private const val COL_PAUSED_REMAINING = "paused_remaining_millis"
        private const val COL_RUN_ID = "run_id"
        private const val COL_THRESHOLD_MILLIS = "threshold_millis"
        private const val COL_DELIVERY = "delivery"
        private const val COL_BANNER_DISMISSED = "banner_dismissed"
        private const val COL_SCHEDULED = "scheduled"

        /** 列表查询里最近一轮运行状态的别名，避免与 projections 无关的同名列混淆。 */
        private const val COL_LATEST_RUN_STATUS = "latest_run_status"

        const val RUN_STATUS_RUNNING = "running"
        const val RUN_STATUS_FINISHED = "finished"
        const val RUN_STATUS_CANCELLED = "cancelled"
        const val RUN_STATUS_RESTARTED = "restarted"

        const val DELIVERY_NONE = "none"
        const val DELIVERY_FOREGROUND = "foreground"
        const val DELIVERY_NOTIFICATION = "notification"

        const val STATE_IDLE = "idle"
        const val STATE_FINISHED = "finished"

        const val ERROR_INVALID_PROJECT = "invalid_project"
        const val ERROR_PROJECT_NOT_FOUND = "project_not_found"
        const val ERROR_RUN_ALREADY_ACTIVE = "run_already_active"
        const val ERROR_RUN_NOT_FOUND = "run_not_found"
        const val ERROR_RUN_NOT_RUNNING = "run_not_running"

        /**
         * 临时快启项目的固定名称，与 `lib/countdown/model.dart` 的 `temporaryRunName` 一致。
         * 它是持久化数据而不是界面文案，因此不放进 strings.xml 做本地化。
         */
        private const val TEMPORARY_PROJECT_NAME = "倒计时"

        private const val SQL_CREATE_PROJECTS = """
            CREATE TABLE projects (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                total_seconds INTEGER NOT NULL,
                reminder_seconds INTEGER,
                created_at_utc INTEGER NOT NULL,
                is_temporary INTEGER NOT NULL DEFAULT 0
            )
        """

        private const val SQL_CREATE_RUNS = """
            CREATE TABLE runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                project_id INTEGER NOT NULL,
                name_snapshot TEXT NOT NULL,
                total_seconds INTEGER NOT NULL,
                start_elapsed INTEGER NOT NULL,
                deadline_elapsed INTEGER NOT NULL,
                deadline_utc INTEGER NOT NULL,
                boot_count INTEGER NOT NULL,
                status TEXT NOT NULL,
                finished_at_utc INTEGER,
                paused INTEGER NOT NULL DEFAULT 0,
                paused_remaining_millis INTEGER
            )
        """

        private const val SQL_CREATE_REMINDERS = """
            CREATE TABLE reminders (
                run_id INTEGER PRIMARY KEY,
                threshold_millis INTEGER NOT NULL,
                delivery TEXT NOT NULL DEFAULT 'none',
                banner_dismissed INTEGER NOT NULL DEFAULT 0,
                scheduled INTEGER NOT NULL DEFAULT 0
            )
        """

        private const val SQL_CREATE_RUNS_PROJECT_INDEX = """
            CREATE INDEX idx_runs_project_id ON runs (project_id)
        """

        // v1 → v2：只加列。列顺序追加在末尾，与 onCreate 的 v2 结构一致。
        private const val SQL_MIGRATE_V2_PROJECTS_IS_TEMPORARY = """
            ALTER TABLE projects ADD COLUMN is_temporary INTEGER NOT NULL DEFAULT 0
        """

        private const val SQL_MIGRATE_V2_RUNS_PAUSED = """
            ALTER TABLE runs ADD COLUMN paused INTEGER NOT NULL DEFAULT 0
        """

        private const val SQL_MIGRATE_V2_RUNS_PAUSED_REMAINING = """
            ALTER TABLE runs ADD COLUMN paused_remaining_millis INTEGER
        """

        // v2 → v3：projects 的提醒阈值从分钟改为秒。SQLite 不能修改列定义或单位，
        // 因此整表重建；runs / reminders 结构与数据都不动，运行中已按毫秒保存的
        // threshold_millis 原样保留（180000 毫秒仍是 180000），不做二次换算。
        private const val SQL_MIGRATE_V3_CREATE_PROJECTS = """
            CREATE TABLE projects_v3 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                total_seconds INTEGER NOT NULL,
                reminder_seconds INTEGER,
                created_at_utc INTEGER NOT NULL,
                is_temporary INTEGER NOT NULL DEFAULT 0
            )
        """

        /** 历史分钟阈值换算为秒；NULL 表示关闭提醒，保持 NULL。 */
        private const val SQL_MIGRATE_V3_COPY_PROJECTS = """
            INSERT INTO projects_v3 (id, name, total_seconds, reminder_seconds, created_at_utc, is_temporary)
            SELECT id, name, total_seconds,
                   CASE WHEN reminder_minutes IS NULL THEN NULL ELSE reminder_minutes * 60 END,
                   created_at_utc, is_temporary
            FROM projects
        """

        /**
         * 重建表会丢掉 AUTOINCREMENT 的序列记录（原表随后被 DROP），先把原表与临时表的
         * 序列取较大值，保证后续自增 id 不回退到历史 id（包括已删除的高位 id）。
         * sqlite_sequence 没有唯一约束，不能用 INSERT OR REPLACE 去重，因此拆成
         * 「存在则 UPDATE、不存在则 INSERT」两条语句。
         */
        private const val SQL_MIGRATE_V3_MERGE_PROJECT_SEQUENCE = """
            UPDATE sqlite_sequence
            SET seq = MAX(seq, COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'projects'), 0))
            WHERE name = 'projects_v3'
        """

        /** 项目表为空时上面没有可 UPDATE 的行，这里补一条序列记录。 */
        private const val SQL_MIGRATE_V3_ENSURE_PROJECT_SEQUENCE = """
            INSERT INTO sqlite_sequence (name, seq)
            SELECT 'projects_v3', COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'projects'), 0)
            WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'projects_v3')
        """

        private const val SQL_MIGRATE_V3_DROP_PROJECTS = """
            DROP TABLE projects
        """

        private const val SQL_MIGRATE_V3_RENAME_PROJECTS = """
            ALTER TABLE projects_v3 RENAME TO projects
        """

        /**
         * 旧版 Android 的 SQLite（API 24 为 3.9）执行 RENAME 时不会改写
         * sqlite_sequence.name，新版会改写；两种情况下都把序列落到 projects 名下。
         */
        private const val SQL_MIGRATE_V3_RESTORE_PROJECT_SEQUENCE = """
            INSERT INTO sqlite_sequence (name, seq)
            SELECT 'projects', seq FROM sqlite_sequence WHERE name = 'projects_v3'
            AND NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'projects')
        """

        private const val SQL_MIGRATE_V3_DROP_STALE_SEQUENCE = """
            DELETE FROM sqlite_sequence WHERE name = 'projects_v3'
        """

        private val SQL_PROJECT_LIST = """
            SELECT p.$COL_ID, p.$COL_NAME, p.$COL_TOTAL_SECONDS, p.$COL_REMINDER_SECONDS, p.$COL_CREATED_AT_UTC,
                   r.$COL_STATUS AS $COL_LATEST_RUN_STATUS,
                   r.$COL_DEADLINE_ELAPSED, r.$COL_DEADLINE_UTC, r.$COL_BOOT_COUNT,
                   r.$COL_PAUSED AS $COL_PAUSED, r.$COL_PAUSED_REMAINING AS $COL_PAUSED_REMAINING
            FROM $TABLE_PROJECTS AS p
            LEFT JOIN $TABLE_RUNS AS r ON r.$COL_ID = (
                SELECT MAX(r2.$COL_ID) FROM $TABLE_RUNS AS r2 WHERE r2.$COL_PROJECT_ID = p.$COL_ID
            )
            WHERE p.$COL_IS_TEMPORARY = 0
            ORDER BY p.$COL_CREATED_AT_UTC DESC, p.$COL_ID DESC
        """

        private val SQL_ACTIVE_RUN = """
            SELECT r.$COL_ID, r.$COL_PROJECT_ID, r.$COL_NAME_SNAPSHOT, r.$COL_TOTAL_SECONDS,
                   r.$COL_START_ELAPSED, r.$COL_DEADLINE_ELAPSED, r.$COL_DEADLINE_UTC,
                   r.$COL_BOOT_COUNT, r.$COL_STATUS, r.$COL_FINISHED_AT_UTC,
                   r.$COL_PAUSED, r.$COL_PAUSED_REMAINING,
                   rm.$COL_THRESHOLD_MILLIS, rm.$COL_DELIVERY, rm.$COL_BANNER_DISMISSED
            FROM $TABLE_RUNS AS r
            LEFT JOIN $TABLE_REMINDERS AS rm ON rm.$COL_RUN_ID = r.$COL_ID
            WHERE r.$COL_STATUS = '$RUN_STATUS_RUNNING'
            ORDER BY r.$COL_ID DESC
            LIMIT 1
        """

        private val SQL_PROJECT_BY_ID = """
            SELECT $COL_ID, $COL_NAME, $COL_TOTAL_SECONDS, $COL_REMINDER_SECONDS, $COL_CREATED_AT_UTC,
                   $COL_IS_TEMPORARY
            FROM $TABLE_PROJECTS
            WHERE $COL_ID = ?
        """

        private val SQL_RUN_BY_ID = """
            SELECT $COL_ID, $COL_PROJECT_ID, $COL_NAME_SNAPSHOT, $COL_TOTAL_SECONDS,
                   $COL_START_ELAPSED, $COL_DEADLINE_ELAPSED, $COL_DEADLINE_UTC,
                   $COL_BOOT_COUNT, $COL_STATUS, $COL_FINISHED_AT_UTC,
                   $COL_PAUSED, $COL_PAUSED_REMAINING
            FROM $TABLE_RUNS
            WHERE $COL_ID = ?
        """

        private val SQL_RUNNING_RUNS = """
            SELECT $COL_ID, $COL_PROJECT_ID, $COL_NAME_SNAPSHOT, $COL_TOTAL_SECONDS,
                   $COL_START_ELAPSED, $COL_DEADLINE_ELAPSED, $COL_DEADLINE_UTC,
                   $COL_BOOT_COUNT, $COL_STATUS, $COL_FINISHED_AT_UTC,
                   $COL_PAUSED, $COL_PAUSED_REMAINING
            FROM $TABLE_RUNS
            WHERE $COL_STATUS = '$RUN_STATUS_RUNNING'
            ORDER BY $COL_ID ASC
        """

        private val SQL_RUN_IDS_OF_PROJECT = """
            SELECT $COL_ID FROM $TABLE_RUNS WHERE $COL_PROJECT_ID = ?
        """

        private val SQL_ORPHAN_TEMPORARY_PROJECTS = """
            SELECT p.$COL_ID
            FROM $TABLE_PROJECTS AS p
            WHERE p.$COL_IS_TEMPORARY = 1
              AND NOT EXISTS (
                  SELECT 1 FROM $TABLE_RUNS AS r
                  WHERE r.$COL_PROJECT_ID = p.$COL_ID AND r.$COL_STATUS = '$RUN_STATUS_RUNNING'
              )
        """

        private val SQL_REMINDER_THRESHOLD = """
            SELECT $COL_THRESHOLD_MILLIS FROM $TABLE_REMINDERS WHERE $COL_RUN_ID = ?
        """

        private val SQL_REMINDER_OF_RUN = """
            SELECT $COL_THRESHOLD_MILLIS, $COL_DELIVERY, $COL_BANNER_DISMISSED
            FROM $TABLE_REMINDERS
            WHERE $COL_RUN_ID = ?
        """
    }
}

/** `ClockReading` 对应的通道字段；与 `lib/countdown/model.dart` 的键名一致。 */
internal fun RunClock.Reading.toWireMap(): Map<String, Any?> = mapOf(
    "elapsedMillis" to elapsedMillis,
    "utcMillis" to utcMillis,
    "bootCount" to bootCount,
)
