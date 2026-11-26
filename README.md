# 倒计时（Countdown）

Android 7.0（API 24）及以上的倒计时应用：首页用「时 / 分 / 秒」滚轮直接快启一轮
计时，也能保存多个常用项目逐个启动；一次只运行一个计时器，提前提醒精确到**秒**。
手机与平板各有横竖四种布局。
当前版本 1.0.0（构建号 3，数据库版本 3）。

## 运行形态与约束

- **一次运行一个计时器**：运行中的轮次以活动卡显示在首页主区，其它项目留在常用列表；
  运行期间其他「开始」入口禁用。
- **本轮控制**：运行页与首页活动卡都提供「暂停／继续」「重新计时」「取消」，分别使用蓝底白字、白底蓝描边、白底红描边。
  暂停冻结剩余毫秒并撤销待发闹钟（已投递的提醒不撤回）；继续时从冻结值重建截止点，
  暂停期间的实际时长不计入；重新计时从本轮最初的总时长立即开始新一轮；取消结束本轮，
  常用项回到可再次启动的状态。
- **快启是临时运行**：名称「倒计时」、默认关闭提醒、不写入常用列表；取消或归零后由
  宿主清理。取消回到空闲态时保留最近一次滚轮选值。
- **提前提醒按秒**：新增页有「时长」与「提前提醒」两组同样式的时/分/秒三列滚轮。
  设总时长为 D 秒、提醒触发时的剩余秒数为 R，则 `1 ≤ R ≤ D−1`；D=1 可保存但无法开启
  提醒，D=2 时唯一可选项是 00:00:01；提醒滚轮的上界随总时长与已选高位动态收敛。
  触发时刻 = 截止时刻 − R 秒；前台红字与提示条、后台通知都按实际正剩余显示
  「还剩 HH:MM:SS」，不按分钟取整。
- **计时口径**：同一次开机内用 Android 单调时钟（`elapsedRealtime`）计算剩余时间，
  手动修改系统时间不影响倒数；设备重启后按持久化的 UTC 截止时间重新校准。
- **持久化**：项目（提醒阈值以秒保存）、运行记录（含暂停冻结值）与提醒投递状态保存在
  宿主 SQLite；系统接收器与 Flutter 前台共用同一份数据。数据库版本 3，升级时对 v1/v2
  历史数据做事务迁移（v2 的分钟阈值迁移为 `× 60` 秒，运行中毫秒阈值保持不变）。
- **归零**：停在 `00:00:00`，保存的常用项标记「已结束」；本轮不再提醒。

## 目录

| 路径 | 职责 |
|---|---|
| `lib/main.dart`、`lib/app/` | 入口装配、主题、四向布局度量、路由名、贝塞尔形状（`bezier_rounded_rect.dart`）、开关（`app_switch.dart`） |
| `lib/countdown/model.dart` | 项目、运行快照（含暂停冻结值）、时钟读数与剩余时间换算 |
| `lib/countdown/repository.dart` | 平台通道契约与仓储接口 |
| `lib/countdown/controller.dart` | 项目列表、当前运行、每秒刷新与本轮命令状态 |
| `lib/countdown/wheel_picker.dart` | 时分秒滚轮、秒级提醒滚轮与合法范围收敛（首页与新增页共用） |
| `lib/countdown/run_controls.dart` | 暂停／继续、重新计时、取消（运行页与首页共用） |
| `lib/countdown/{list,create,running}_page.dart`、`timer_display.dart`、`reminder_banner.dart`、`delete_dialog.dart` | 页面与共用组件 |
| `lib/countdown/time_format.dart` | 显示秒数、八字符格式、秒级提醒文案与提醒窗口判定 |
| `android/app/src/main/kotlin/com/countdown/countdown_app/` | 宿主：SQLite 存储与 v3 迁移、运行时钟、闹钟调度、通知接收器、通道桥接 |
| `android/app/src/main/res/` | 启动图标（传统 mipmap + API 26+ 自适应图标） |
| `design/` | 图标母版 SVG 与生成说明 |
| `test/` | 控制器、计时格式、滚轮与秒级边界、贝塞尔几何、四向页面 |

## 构建

工具链（本次开发实际使用）：Flutter 3.47.7 / Dart 3.13.5、JDK 17、Android SDK
compileSdk 36 / build-tools 36.0.0、AGP 9.1.0、Gradle 9.3.1。最低支持 API 24。

```bash
export JAVA_HOME=<JDK 17>
export ANDROID_HOME=<Android SDK>
flutter pub get
flutter analyze
flutter test
flutter build apk --release   # 当前 release 使用调试签名，正式发布签名需另行配置
```

## 版本与签名

- 版本名为 `1.0.0`，构建号为 `3`，应用 ID 为 `com.countdown.countdown_app`。
- 当前的 release 构建使用 Android 调试证书签名。正式分发前需要配置发布签名。
- 四方向布局、通知投递及数据库覆盖升级等 Android 系统行为仍待真机验证。
