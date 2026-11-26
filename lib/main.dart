/// 入口：创建一次依赖并启动应用。
library;

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'countdown/controller.dart';
import 'countdown/repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  applySystemOverlayStyle();
  final CountdownRepository repository = PlatformCountdownRepository();
  runApp(CountdownApp(controller: CountdownController(repository)));
}
