/// 青枢 · 播放源管理（第 2 期）。
///
/// 直接复用 Kazumi 的 `PluginsController`：规则的安装、更新、删除、仓库地址
/// 全都由它管，这里只做一层青枢皮的列表界面。
///
/// 为什么自己写界面而不搬 `plugin_shop_page.dart`：那个页面挂在 Kazumi 的
/// `flutter_modular` 路由下，`inject<PluginsController>()` 在 Riverpod 壳里会抛
/// "No Element"（轻小说那次已经踩过）。`PluginsController` 本身是纯 Dart 类，
/// 已经由 [KazumiBootstrap] 在启动时装配好，直接取静态实例即可。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

import '../widgets/home/home_design.dart';
import '../widgets/wenku/wenku_ui.dart';

class PlaySourcePage extends StatefulWidget {
  const PlaySourcePage({super.key});

  @override
  State<PlaySourcePage> createState() => _PlaySourcePageState();
}

class _PlaySourcePageState extends State<PlaySourcePage> {
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  PluginsController? _controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await KazumiBootstrap.ensureReady();
      final controller = KazumiBootstrap.plugins;
      if (force || !controller.isPluginCatalogFresh) {
        await controller.refreshPluginCatalog();
      }
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '规则仓库没拉到，检查网络后重试。';
      });
    }
  }

  Future<void> _install(PluginHTTPItem item) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _busy.add(item.name));
    try {
      final result = await controller.tryUpdatePluginByName(item.name);
      if (!mounted) return;
      _toast(switch (result) {
        PluginUpdateResult.updated => '已安装 ' + item.name,
        PluginUpdateResult.notNewer => item.name + ' 已经是最新的',
        PluginUpdateResult.requiresNewerClient => '这条规则要求更新的客户端',
        PluginUpdateResult.failed => '安装失败，检查网络后重试',
      });
    } catch (_) {
      if (mounted) _toast('安装失败，检查网络后重试');
    } finally {
      if (mounted) setState(() => _busy.remove(item.name));
    }
  }

  Future<void> _uninstall(Plugin plugin) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _busy.add(plugin.name));
    try {
      await controller.removePlugin(plugin);
      if (mounted) _toast('已移除 ' + plugin.name);
    } catch (_) {
      if (mounted) _toast('移除失败，重试一下');
    } finally {
      if (mounted) setState(() => _busy.remove(plugin.name));
    }
  }

  Future<void> _editRepository() async {
    final controller = _controller;
    if (controller == null) return;
    final text = TextEditingController(text: controller.ruleRepository);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('规则仓库地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '留空表示用官方仓库 KazumiRules。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: text,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'https://github.com/…/index.json',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      final changed = await controller.setRuleRepository(text.text);
      if (!mounted) return;
      if (!changed) {
        _toast('仓库地址没变');
        return;
      }
      _toast('已切换仓库，正在重新拉取');
      await _load(force: true);
    } on FormatException catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('保存失败，重试一下');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return WenkuPage(
      header: const Align(
        alignment: Alignment.centerLeft,
        child: ArchiveMasthead(title: '播放源', code: '06 / SOURCES'),
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _body(palette),
        ),
      ),
    );
  }

  Widget _body(HomePalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.cloud_off, size: 42, color: palette.muted),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => _load(force: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller!;
    final installed = controller.pluginList.toList();
    final catalog = controller.pluginHTTPList.toList();
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          Text(
            '播放源来自 Kazumi 的规则仓库：一条规则对应一个番剧站点。已经装好的规则会参与「搜索播放源」。',
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              color: palette.ink.withValues(alpha: 0.62),
            ),
          ),
          const SizedBox(height: 14),
          _RepositoryBar(
            repository: controller.ruleRepository,
            onEdit: _editRepository,
            palette: palette,
          ),
          const SizedBox(height: 22),
          _sectionTitle('已安装 · ' + installed.length.toString(), palette),
          const SizedBox(height: 8),
          if (installed.isEmpty)
            _hint('还没有装任何播放源。下面挑一条装。', palette)
          else
            for (final plugin in installed) ...[
              _InstalledTile(
                plugin: plugin,
                busy: _busy.contains(plugin.name),
                onRemove: () => _uninstall(plugin),
                palette: palette,
              ),
              const SizedBox(height: 8),
            ],
          const SizedBox(height: 22),
          _sectionTitle('规则仓库 · ' + catalog.length.toString(), palette),
          const SizedBox(height: 8),
          for (final item in catalog) ...[
            _CatalogTile(
              item: item,
              status: controller.pluginStatus(item),
              busy: _busy.contains(item.name),
              onInstall: () => _install(item),
              palette: palette,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, HomePalette palette) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: palette.ink,
    ),
  );

  Widget _hint(String text, HomePalette palette) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      text,
      style: TextStyle(fontSize: 12, color: palette.muted),
    ),
  );
}

class _RepositoryBar extends StatelessWidget {
  const _RepositoryBar({
    required this.repository,
    required this.onEdit,
    required this.palette,
  });

  final String repository;
  final VoidCallback onEdit;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.link, size: 18, color: palette.muted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '规则仓库',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  repository.isEmpty ? '官方 KazumiRules' : repository,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onEdit, child: const Text('修改')),
        ],
      ),
    );
  }
}

class _InstalledTile extends StatelessWidget {
  const _InstalledTile({
    required this.plugin,
    required this.busy,
    required this.onRemove,
    required this.palette,
  });

  final Plugin plugin;
  final bool busy;
  final VoidCallback onRemove;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.plug, size: 18, color: palette.accentText),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plugin.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: palette.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'v' + plugin.version + ' · ' + plugin.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              tooltip: '移除',
              onPressed: onRemove,
              icon: Icon(LucideIcons.trash_2, size: 18, color: palette.muted),
            ),
        ],
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.item,
    required this.status,
    required this.busy,
    required this.onInstall,
    required this.palette,
  });

  final PluginHTTPItem item;
  final PluginCatalogItemStatus status;
  final bool busy;
  final VoidCallback onInstall;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    final installed = status == PluginCatalogItemStatus.installed;
    final outdated = status == PluginCatalogItemStatus.update;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                    ),
                    if (item.useNativePlayer) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: palette.soft,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '内核',
                          style: TextStyle(fontSize: 10, color: palette.muted),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'v' + item.version + ' · ' + item.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (installed)
            Text(
              '已装',
              style: TextStyle(fontSize: 12, color: palette.muted),
            )
          else
            TextButton(
              onPressed: onInstall,
              child: Text(outdated ? '更新' : '安装'),
            ),
        ],
      ),
    );
  }
}
