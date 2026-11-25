import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show Size;
import 'package:material_ui/material_ui.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/pages/plugin_editor/plugin_view_page.dart';

/// 回归守卫：规则管理页必须能在**主壳的真实配置**下构建。
///
/// 背景（2026-11-26，v2.1.0 用户实测仍是整页灰块）：
/// 主壳用的是 `package:material_ui`（Flutter 3.47 起从 flutter/material 拆出
/// 的独立包），而 packages/kazumi 原来是 `package:flutter/material`。两套是
/// **互相独立的实现**，类型不通用：
///   • `Theme.of(context)` 拿不到主壳主题 → 回退 Flutter 默认紫；
///   • `MaterialLocalizations.of(context)` 找不到 → TextField 在 build 里
///     抛 "No MaterialLocalizations found"，release 下整块渲染成灰。
///
/// 所以这个测试必须：
///   1. 用 material_ui + 中文 delegates 建 MaterialApp（不能自建 flutter/material 的）；
///   2. 真的把 Kazumi 的存储/规则控制器初始化起来 —— 否则
///      `DesktopWindowConfig.showWindowButton` 读 GStorage 的 late 字段会抛
///      LateInitializationError，同样是一片灰。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('qingshu_widget_test');
    // path_provider 在纯 Dart 测试里没有平台实现，用 mock 通道指到临时目录。
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
    await KazumiBootstrap.ensureReady();
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('规则管理页在主壳配置下可以正常构建', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFFEF5038),
          useMaterial3: true,
        ),
        home: PluginViewPage(controller: KazumiBootstrap.plugins),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final error = tester.takeException();
    // ignore: avoid_print
    print('===== RENDER EXCEPTION =====');
    // ignore: avoid_print
    print(error == null ? 'none' : error.toString().split('\n').take(8).join('\n'));
    // ignore: avoid_print
    print('===== END =====');
    expect(error, isNull, reason: '规则管理页构建时抛异常（release 下会是一整块灰）');
  });
}
