/// 应用外壳：主题、导航与生命周期接线。
///
/// 入口装配只发生在 [main.dart] 与这里：控制器创建一次，经构造函数注入页面；
/// 平台事件（通知点击）在此处转换为导航，页面不直接处理。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../countdown/controller.dart';
import '../countdown/list_page.dart';
import '../countdown/running_page.dart';
import 'routes.dart';
import 'theme.dart';

/// 记录当前栈顶路由名，供通知跳转去重。
class AppNavigatorObserver extends NavigatorObserver {
  String? currentRouteName = AppRoutes.list;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = route.settings.name ?? currentRouteName;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    currentRouteName = previousRoute?.settings.name ?? AppRoutes.list;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final String? name = newRoute?.settings.name;
    if (name != null) {
      currentRouteName = name;
    }
  }
}

/// 应用根组件。
class CountdownApp extends StatefulWidget {
  const CountdownApp({super.key, required this.controller});

  final CountdownController controller;

  @override
  State<CountdownApp> createState() => _CountdownAppState();
}

class _CountdownAppState extends State<CountdownApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AppNavigatorObserver _navigatorObserver = AppNavigatorObserver();
  StreamSubscription<int>? _notificationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _notificationSubscription = widget.controller.notificationOpens.listen(
      _handleNotificationOpen,
    );
    _bootstrap();
  }

  /// 先完成一次读取，再取回冷启动前的通知点击目标，避免两个快照互相覆盖。
  Future<void> _bootstrap() async {
    await widget.controller.load();
    if (!mounted) {
      return;
    }
    try {
      final int? runId = await widget.controller
          .consumePendingNotificationRun();
      if (runId != null) {
        await _handleNotificationOpen(runId);
      }
    } catch (_) {
      // 取回失败只影响一次跳转：用户仍可从列表进入运行页，通知本身已经投递。
    }
  }

  /// 点击有效通知后进入对应运行页；旧通知、已删除或已归零的运行停在列表。
  Future<void> _handleNotificationOpen(int runId) async {
    await widget.controller.refresh();
    if (!mounted) {
      return;
    }
    final int? activeRunId = widget.controller.activeRun?.runId;
    if (activeRunId == null || activeRunId != runId) {
      return;
    }
    if (_navigatorObserver.currentRouteName == AppRoutes.running) {
      return;
    }
    await _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: AppRoutes.running),
        builder: (BuildContext context) =>
            RunningPage(controller: widget.controller),
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.controller.onAppResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        widget.controller.onAppPaused();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void dispose() {
    _notificationSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '倒计时',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      navigatorObservers: <NavigatorObserver>[_navigatorObserver],
      theme: buildCountdownTheme(),
      home: ListPage(controller: widget.controller),
    );
  }
}

/// 状态栏与导航栏使用深色图标，配合白底界面。
void applySystemOverlayStyle() {
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
}
