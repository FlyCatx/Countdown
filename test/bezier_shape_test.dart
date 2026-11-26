/// 贝塞尔圆角几何与形状适配校验：路径边界、直边保留、零尺寸/零半径、按钮与输入框。
library;

import 'dart:ui' show Tristate;

import 'package:countdown_app/app/app_switch.dart';
import 'package:countdown_app/app/bezier_rounded_rect.dart';
import 'package:countdown_app/app/theme.dart';
import 'package:countdown_app/app/window_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('路径几何', () {
    test('外接矩形与设计矩形一致', () {
      final Path path = buildBezierRoundedRectPath(
        left: 10,
        top: 20,
        right: 110,
        bottom: 70,
        radius: 8,
      );
      expect(path.getBounds(), const Rect.fromLTRB(10, 20, 110, 70));
    });

    test('直边保留：上下左右边的中点都在路径上', () {
      const Rect rect = Rect.fromLTRB(0, 0, 200, 100);
      final Path path = bezierRoundedRectPath(rect, 8);
      for (final Offset point in <Offset>[
        const Offset(100, 0),
        const Offset(100, 100),
        const Offset(0, 50),
        const Offset(200, 50),
      ]) {
        expect(path.contains(point), isTrue, reason: '$point 应落在直边上');
      }
    });

    test('四角被切掉：角落像素不在填充内', () {
      const Rect rect = Rect.fromLTRB(0, 0, 200, 100);
      final Path path = bezierRoundedRectPath(rect, 12);
      expect(path.contains(const Offset(0.5, 0.5)), isFalse);
      expect(path.contains(const Offset(199.5, 0.5)), isFalse);
      expect(path.contains(const Offset(0.5, 99.5)), isFalse);
      expect(path.contains(const Offset(199.5, 99.5)), isFalse);
    });

    test('半径限制在短边一半以内，零半径退化为矩形', () {
      final Path huge = bezierRoundedRectPath(
        const Rect.fromLTRB(0, 0, 100, 40),
        1000,
      );
      expect(huge.getBounds(), const Rect.fromLTRB(0, 0, 100, 40));
      final Path square = bezierRoundedRectPath(
        const Rect.fromLTRB(0, 0, 100, 40),
        0,
      );
      // 零半径时四角保留。
      expect(square.contains(const Offset(0.5, 0.5)), isTrue);
      expect(square.contains(const Offset(99.5, 39.5)), isTrue);
    });

    test('零尺寸返回空路径', () {
      final Path empty = buildBezierRoundedRectPath(
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        radius: 8,
      );
      expect(empty.getBounds(), Rect.zero);
    });

    test('角部轮廓不是标准圆弧（与 RRect 存在差异区域）', () {
      const Rect rect = Rect.fromLTRB(0, 0, 200, 120);
      const double radius = 12;
      final Path bezier = bezierRoundedRectPath(rect, radius);
      final RRect arc = RRect.fromRectAndRadius(
        rect,
        const Radius.circular(radius),
      );
      bool differs = false;
      for (double x = 0; x <= radius + 2; x += 0.25) {
        for (double y = 0; y <= radius + 2; y += 0.25) {
          final Offset point = Offset(x, y);
          if (bezier.contains(point) != arc.contains(point)) {
            differs = true;
          }
        }
      }
      expect(differs, isTrue, reason: '贝塞尔轮廓必须区别于标准圆弧');
    });
  });

  group('形状适配', () {
    test('按钮形状在按压/禁用态下仍为同一外轮廓', () {
      const WindowMetrics metrics = WindowMetrics(
        sizeClass: WindowSizeClass.phonePortrait,
        safeSize: Size(360, 800),
        safePadding: EdgeInsets.zero,
      );
      final ButtonStyle style = solidButtonStyle(metrics);
      final OutlinedBorder shape =
          style.shape?.resolve(<WidgetState>{}) as OutlinedBorder;
      expect(shape, isA<BezierRoundedRectangleBorder>());
      final OutlinedBorder pressed = style.shape!.resolve(<WidgetState>{
        WidgetState.pressed,
      }) as OutlinedBorder;
      final OutlinedBorder disabled = style.shape!.resolve(<WidgetState>{
        WidgetState.disabled,
      }) as OutlinedBorder;
      expect(pressed, shape);
      expect(disabled, shape);
    });

    testWidgets('输入框与实心按钮渲染无异常', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCountdownTheme(),
          home: Builder(
            builder: (BuildContext context) {
              final WindowMetrics metrics = WindowMetrics.of(context);
              return Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: <Widget>[
                      TextField(
                        decoration: countdownFieldDecoration(metrics: metrics),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        style: solidButtonStyle(metrics),
                        onPressed: () {},
                        child: const Text('保存'),
                      ),
                      const SizedBox(height: 16),
                      AppSwitch(
                        value: true,
                        semanticsLabel: '提前提醒',
                        onChanged: (bool value) {},
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppSwitch 点击切换并暴露 toggled 语义', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      bool value = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCountdownTheme(),
          home: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Center(
                child: AppSwitch(
                  value: value,
                  semanticsLabel: '提前提醒',
                  onChanged: (bool next) => setState(() => value = next),
                ),
              );
            },
          ),
        ),
      );
      final Finder switchFinder = find.bySemanticsLabel('提前提醒');
      expect(switchFinder, findsOneWidget);
      expect(
        tester
            .getSemantics(switchFinder)
            .getSemanticsData()
            .flagsCollection
            .isToggled,
        Tristate.isFalse,
      );
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(
        tester
            .getSemantics(switchFinder)
            .getSemanticsData()
            .flagsCollection
            .isToggled,
        Tristate.isTrue,
      );
      handle.dispose();
      expect(tester.takeException(), isNull);
    });

    testWidgets('禁用开关不响应点击', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildCountdownTheme(),
          home: Center(
            child: AppSwitch(
              value: false,
              enabled: false,
              onChanged: (bool value) => calls++,
            ),
          ),
        ),
      );
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
