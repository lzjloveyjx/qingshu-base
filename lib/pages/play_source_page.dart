/// 青枢 · 播放源管理入口。
///
/// 直接用 Kazumi 原版的 [PluginViewPage]（已安装规则页：搜索 / 筛选 /
/// 批量多选 / 拖拽排序 / 三点菜单 / 单条更新），行为与 Kazumi 完全一致。
///
/// 这里只负责两件事：等 KazumiBootstrap 装配好 PluginsController，
/// 然后把 controller 传进去。Kazumi 内部那 7 处 flutter_modular 的 pushNamed
/// 已经改成 Navigator.push，所以能在青枢的 Riverpod 壳里正常跳子页。
library;

import 'package:material_ui/material_ui.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/pages/plugin_editor/plugin_view_page.dart';

class PlaySourcePage extends StatefulWidget {
  const PlaySourcePage({super.key});

  @override
  State<PlaySourcePage> createState() => _PlaySourcePageState();
}

class _PlaySourcePageState extends State<PlaySourcePage> {
  Future<void>? _ready;

  @override
  void initState() {
    super.initState();
    _ready = KazumiBootstrap.ensureReady();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      }
      if (snapshot.hasError) {
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    '播放源初始化失败：' + snapshot.error.toString(),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => setState(() => _ready = KazumiBootstrap.ensureReady()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return PluginViewPage(controller: KazumiBootstrap.plugins);
    },
  );
}
