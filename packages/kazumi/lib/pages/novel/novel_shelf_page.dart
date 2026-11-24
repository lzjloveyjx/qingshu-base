import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/novel_cover_image.dart';
import 'package:kazumi/modules/novel/novel_shelf_module.dart';
import 'package:kazumi/pages/novel/novel_book_page.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/novel_shelf_repository.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 书架 / 阅读历史。
///
/// 两个 tab 共用同一张表（[NovelBookRecord]），区别只在筛选条件：
///   • 书架 = onShelf
///   • 历史 = 有阅读进度，按最近读的时间倒序
///
/// 点任意一条都回到上次读到的地方 —— 这是阅读器最基本的行为，不该让用户
/// 每次从第一章翻起。
class NovelShelfPage extends StatefulWidget {
  const NovelShelfPage({super.key});

  @override
  State<NovelShelfPage> createState() => _NovelShelfPageState();
}

class _NovelShelfPageState extends State<NovelShelfPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final NovelShelfRepository _repo;

  List<NovelBookRecord> _shelf = const [];
  List<NovelBookRecord> _history = const [];
  String _opening = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _repo = inject<NovelShelfRepository>();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _shelf = _repo.shelf();
      _history = _repo.history();
    });
  }

  /// 找到这本书对应的规则。规则被删掉时返回 null，此时提示用户而不是崩。
  Plugin? _pluginFor(String pluginName) {
    final controller = inject<PluginsController>();
    for (final plugin in controller.pluginList) {
      if (plugin.name.toLowerCase() == pluginName.toLowerCase()) {
        return plugin;
      }
    }
    return null;
  }

  Future<void> _openBook(NovelBookRecord record) async {
    if (_opening.isNotEmpty) return;
    final plugin = _pluginFor(record.pluginName);
    if (plugin == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这本书的来源规则「${record.pluginName}」已经不在列表里了')),
      );
      return;
    }
    setState(() => _opening = record.title);
    try {
      final roads = await plugin.queryChapterRoads(record.bookKey);
      if (!mounted) return;
      if (roads.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('这本书没有解析出章节，可能站点改版了')),
        );
        return;
      }
      // 章节数变了（站点加了新章/删了旧章）时，把越界的进度夹回去。
      var roadIndex = record.lastRoadIndex;
      var chapterIndex = record.lastChapterIndex;
      if (roadIndex < 0 || roadIndex >= roads.length) {
        roadIndex = 0;
        chapterIndex = 0;
      } else if (chapterIndex < 0 || chapterIndex >= roads[roadIndex].data.length) {
        chapterIndex = 0;
      }
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => NovelBookPage(
            plugin: plugin,
            bookTitle: record.title,
            roads: roads,
            coverUrl: record.cover,
            author: record.author,
            bookKey: record.bookKey,
            initialRoadIndex: roadIndex,
            initialChapterIndex: chapterIndex,
            initialPageIndex: record.lastPageIndex,
            initialPageAnchor: record.lastPageAnchor,
          ),
        ),
      );
      // 从详情页/阅读页回来，进度可能变了，刷新一下。
      if (mounted) _reload();
    } catch (e) {
      KazumiLogger().w('novel shelf open failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _opening = '');
    }
  }

  Future<void> _removeFromShelf(NovelBookRecord record) async {
    await _repo.toggleShelf(
      pluginName: record.pluginName,
      bookKey: record.bookKey,
      title: record.title,
    );
    _reload();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空阅读历史？'),
        content: const Text('只清除阅读进度，书架里的书不会动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.clearHistory();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            tooltip: '清空阅读历史',
            onPressed: _history.isEmpty ? null : _clearHistory,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      // SysAppBar 不支持 bottom（它不是标准 AppBar 的包装，只转发固定字段），
      // 所以 TabBar 放在 body 顶部，而不是塞进 appBar。
      body: Column(
        children: [
          TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: '书架'),
              Tab(text: '历史'),
            ],
          ),
          Expanded(
            child: _opening.isNotEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text('正在打开《$_opening》…'),
                      ],
                    ),
                  )
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _buildList(
                        items: _shelf,
                        emptyTitle: '书架还是空的。\n在书籍详情页点右上角的书签图标加进来。',
                        emptyIcon: Icons.bookmark_border_rounded,
                        showRemove: true,
                      ),
                      _buildList(
                        items: _history,
                        emptyTitle: '还没有阅读记录。\n随便打开一本书读一章就会出现。',
                        emptyIcon: Icons.history_rounded,
                        showRemove: false,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildList({
    required List<NovelBookRecord> items,
    required String emptyTitle,
    required IconData emptyIcon,
    required bool showRemove,
  }) {
    if (items.isEmpty) {
      return GeneralEmptyState(icon: emptyIcon, title: emptyTitle);
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        final record = items[i];
        return _ShelfTile(
          record: record,
          onTap: () => _openBook(record),
          onRemove: showRemove ? () => _removeFromShelf(record) : null,
        );
      },
    );
  }
}

class _ShelfTile extends StatelessWidget {
  const _ShelfTile({
    required this.record,
    required this.onTap,
    this.onRemove,
  });

  final NovelBookRecord record;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = record.progressRatio;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              height: 78,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: NovelCoverImage(url: record.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _subtitle(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (ratio != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 3,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: '移出书架',
                onPressed: onRemove,
                icon: const Icon(Icons.more_vert, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    if (!record.hasProgress) {
      return record.author.isEmpty ? '未读' : record.author;
    }
    final chapter = record.lastChapterTitle.isEmpty
        ? '第 ${record.lastChapterIndex + 1} 章'
        : record.lastChapterTitle;
    final at = DateTime.fromMillisecondsSinceEpoch(record.lastReadAtMs);
    return '读到 $chapter · ${_relativeTime(at)}';
  }

  String _relativeTime(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}
