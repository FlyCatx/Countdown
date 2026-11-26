/// P0 基础校验：四个基准窗口的断点分类、字级、安全区扣除与间距。
library;

import 'package:countdown_app/app/theme.dart';
import 'package:countdown_app/app/window_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<WindowMetrics> metricsFor(
  WidgetTester tester,
  Size size, {
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  late WindowMetrics captured;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, padding: padding),
      child: Builder(
        builder: (BuildContext context) {
          captured = WindowMetrics.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('四个基准窗口映射到正确的朝向分类', (WidgetTester tester) async {
    expect(
      (await metricsFor(tester, const Size(360, 800))).sizeClass,
      WindowSizeClass.phonePortrait,
    );
    expect(
      (await metricsFor(tester, const Size(800, 360))).sizeClass,
      WindowSizeClass.phoneLandscape,
    );
    expect(
      (await metricsFor(tester, const Size(800, 1280))).sizeClass,
      WindowSizeClass.tabletPortrait,
    );
    expect(
      (await metricsFor(tester, const Size(1280, 800))).sizeClass,
      WindowSizeClass.tabletLandscape,
    );
  });

  testWidgets('短边扣除安全区后决定手机型/平板型', (WidgetTester tester) async {
    // 780 dp 宽、显示缺口与导航栏共 200 dp → 安全短边 580，仍属手机型。
    final WindowMetrics phone = await metricsFor(
      tester,
      const Size(780, 800),
      padding: const EdgeInsets.only(left: 100, right: 100),
    );
    expect(phone.sizeClass, WindowSizeClass.phonePortrait);
    expect(phone.safeSize, const Size(580, 800));

    final WindowMetrics tablet = await metricsFor(
      tester,
      const Size(800, 1280),
      padding: const EdgeInsets.only(top: 24, bottom: 24),
    );
    expect(tablet.sizeClass, WindowSizeClass.tabletPortrait);
  });

  testWidgets('字级表与 HANDOFF §3.1 一致', (WidgetTester tester) async {
    final WindowMetrics phonePortrait = await metricsFor(
      tester,
      const Size(360, 800),
    );
    expect(phonePortrait.fontOf(TextLevel.b), 64);
    expect(phonePortrait.fontOf(TextLevel.n), 32);
    expect(phonePortrait.fontOf(TextLevel.f), 36);
    expect(phonePortrait.fontOf(TextLevel.h), 24);
    expect(phonePortrait.fontOf(TextLevel.k), 20);
    expect(phonePortrait.fontOf(TextLevel.v), 18);
    expect(phonePortrait.fontOf(TextLevel.a), 14);

    final WindowMetrics tabletLandscape = await metricsFor(
      tester,
      const Size(1280, 800),
    );
    expect(tabletLandscape.fontOf(TextLevel.b), 144);
    expect(tabletLandscape.fontOf(TextLevel.n), 64);
    expect(tabletLandscape.fontOf(TextLevel.f), 56);
    expect(tabletLandscape.fontOf(TextLevel.h), 32);
    expect(tabletLandscape.fontOf(TextLevel.k), 26);
    expect(tabletLandscape.fontOf(TextLevel.v), 22);
    expect(tabletLandscape.fontOf(TextLevel.a), 18);
  });

  testWidgets('分栏与内容限宽按朝向生效', (WidgetTester tester) async {
    final WindowMetrics phonePortrait = await metricsFor(
      tester,
      const Size(360, 800),
    );
    expect(phonePortrait.usesColumns, isFalse);
    expect(phonePortrait.pageHorizontalPadding, 16);

    final WindowMetrics phoneLandscape = await metricsFor(
      tester,
      const Size(800, 360),
    );
    expect(phoneLandscape.usesColumns, isTrue);
    expect(phoneLandscape.columnGap, 16);

    final WindowMetrics tabletPortrait = await metricsFor(
      tester,
      const Size(800, 1280),
    );
    expect(tabletPortrait.usesColumns, isFalse);
    expect(tabletPortrait.listMaxContentWidth, 600);
    expect(tabletPortrait.pageHorizontalPadding, 24);

    final WindowMetrics tabletLandscape = await metricsFor(
      tester,
      const Size(1280, 800),
    );
    expect(tabletLandscape.usesColumns, isTrue);
    expect(tabletLandscape.listMaxContentWidth, 1120);
    expect(tabletLandscape.columnGap, 32);
    expect(tabletLandscape.pageHorizontalPadding, 32);
  });

  testWidgets('运行页与弹窗度量按朝向取值', (WidgetTester tester) async {
    final WindowMetrics phonePortrait = await metricsFor(
      tester,
      const Size(360, 800),
    );
    expect(phonePortrait.runningHorizontalPadding, 16);
    expect(phonePortrait.runningGroupGap, 12);
    expect(phonePortrait.dialogMaxWidth, 360);

    final WindowMetrics phoneLandscape = await metricsFor(
      tester,
      const Size(800, 360),
    );
    expect(phoneLandscape.runningHorizontalPadding, 24);
    expect(phoneLandscape.runningGroupGap, 8);
    expect(phoneLandscape.dialogVerticalInset, 12);

    final WindowMetrics tabletPortrait = await metricsFor(
      tester,
      const Size(800, 1280),
    );
    expect(tabletPortrait.runningHorizontalPadding, 32);
    expect(tabletPortrait.runningGroupGap, 16);
    expect(tabletPortrait.dialogMaxWidth, 400);

    final WindowMetrics tabletLandscape = await metricsFor(
      tester,
      const Size(1280, 800),
    );
    expect(tabletLandscape.runningHorizontalPadding, 48);
    expect(tabletLandscape.runningGroupGap, 20);
    expect(tabletLandscape.dialogMaxWidth, 440);
  });

  testWidgets('颜色与圆角使用规格值', (WidgetTester tester) async {
    expect(AppColors.primaryText, const Color(0xFF102341));
    expect(AppColors.secondaryText, const Color(0xFF425572));
    expect(AppColors.accent, const Color(0xFF1C52D4));
    expect(AppColors.accentSurface, const Color(0xFFEEF4FF));
    expect(AppColors.divider, const Color(0xFFD5DEEB));
    expect(AppColors.danger, const Color(0xFFB42332));
    expect(AppRadii.card, 12);
    expect(AppRadii.banner, 8);
    expect(AppRadii.solidButton, 8);
    expect(AppRadii.field, 8);
    expect(AppRadii.menu, 8);
    expect(AppSpacing.touchTarget, 48);
  });
}
