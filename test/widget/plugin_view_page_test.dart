import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/plugin_editor/plugin_view_page.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

/// 回归守卫：规则管理页在空规则列表下必须能正常构建。
///
/// 2026-11-26 用户实测 v2.1.0 仍然整页灰块（release 下 ErrorWidget 不带文字），
/// 说明灰块不是空态滚动层导致的。这个测试把真实的 PluginViewPage 挂起来，
/// 让 CI 把真正的构建异常打印出来。
void main() {
  testWidgets('规则管理页空列表可以正常构建', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final controller = PluginsController();
    await tester.pumpWidget(
      MaterialApp(home: PluginViewPage(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final error = tester.takeException();
    // ignore: avoid_print
    print('===== RENDER EXCEPTION =====');
    // ignore: avoid_print
    print(error ?? 'none');
    // ignore: avoid_print
    print('===== END =====');
    expect(tester.takeException(), isNull);
  });
}
