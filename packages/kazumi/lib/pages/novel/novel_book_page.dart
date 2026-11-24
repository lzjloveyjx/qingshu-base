import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/novel_cover_image.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/novel/novel_reader_page.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/repositories/novel_shelf_repository.dart';

/// 书籍详情页：封面 + 书名 + 章节目录。
///
/// 为什么要有这一页：之前点书直接进第一章，用户既看不到这本书有多少卷、
/// 也无法从中间挑一章读 —— 那不是「看书」，那是「被推着走」。目录是阅读器
/// 的基本部件，不是可选装饰。
///
/// 章节数据直接用规则引擎解析出来的 [Road]（一条 road = 一个线路/一卷），
/// 不再自己抓一遍页面：解析逻辑已经在规则引擎里，重复实现会跟规则脱节。
class NovelBookPage extends StatefulWidget {
  const NovelBookPage({
    super.key,
    required this.plugin,
    required this.bookTitle,
    required this.roads,
    this.coverUrl = '',
    this.author = '',
    this.bookKey = '',
    this.initialRoadIndex = 0,
    this.initialChapterIndex = 0,
    this.initialPageIndex = 0,
    this.initialPageAnchor = 0,
  });

  final Plugin plugin;
  final String bookTitle;
  final List<Road> roads;
  final String coverUrl;
  final String author;

  /// 书籍身份（详情页 URL）。空串表示调用方没给，此时不记录书架/进度。
  final String bookKey;

  /// 从哪一章开始读。来自书架/历史时是上次的位置，否则是 0。
  final int initialRoadIndex;
  final int initialChapterIndex;

  /// 上次读到那一章的第几页 + 段落锚点（分页模式用）。
  final int initialPageIndex;
  final int initialPageAnchor;

  @override
  State<NovelBookPage> createState() => _NovelBookPageState();
}

class _NovelBookPageState extends State<NovelBookPage> {
  late final NovelShelfRepository _repo = inject<NovelShelfRepository>();
  bool _onShelf = false;

  Plugin get plugin => widget.plugin;
  String get bookTitle => widget.bookTitle;
  List<Road> get roads => widget.roads;
  String get coverUrl => widget.coverUrl;
  String get author => widget.author;
  String get bookKey => widget.bookKey;

  @override
  void initState() {
    super.initState();
    if (bookKey.isNotEmpty) {
      _onShelf = _repo.isOnShelf(plugin.name, bookKey);
    }
  }

  Future<void> _toggleShelf() async {
    if (bookKey.isEmpty) return;
    final now = await _repo.toggleShelf(
      pluginName: plugin.name,
      bookKey: bookKey,
      title: bookTitle,
      cover: coverUrl,
      author: author,
    );
    if (!mounted) return;
    setState(() => _onShelf = now);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(now ? '已加入书架' : '已移出书架'),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  /// 图床防盗链用的 Referer。
  String get _referer {
    final referer = plugin.referer.trim();
    return referer.isNotEmpty ? referer : plugin.baseUrl;
  }

  int get _totalChapters =>
      roads.fold<int>(0, (sum, road) => sum + road.data.length);

  /// 有没有读过的进度（决定「继续阅读」按钮显不显示）。
  bool get _hasProgress =>
      widget.initialRoadIndex > 0 || widget.initialChapterIndex > 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SysAppBar(
        title: Text(bookTitle, overflow: TextOverflow.ellipsis),
        actions: [
          if (bookKey.isNotEmpty)
            IconButton(
              tooltip: _onShelf ? '移出书架' : '加入书架',
              onPressed: _toggleShelf,
              icon: Icon(
                _onShelf
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
              ),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 132,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: NovelCoverImage(
                        url: coverUrl,
                        referer: _referer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookTitle,
                          style: theme.textTheme.titleMedium,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (author.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            author,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Text(
                          '${roads.length} 卷 · $_totalChapters 章',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_hasProgress)
                              FilledButton.icon(
                                onPressed: () => _openReader(
                                  context,
                                  widget.initialRoadIndex,
                                  widget.initialChapterIndex,
                                ),
                                icon: const Icon(Icons.play_arrow_rounded,
                                    size: 20),
                                label: const Text('继续阅读'),
                              ),
                            FilledButton.tonalIcon(
                              onPressed: () => _openReader(context, 0, 0),
                              icon: const Icon(Icons.menu_book_rounded,
                                  size: 20),
                              label: const Text('从第一章开始'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 24)),
          if (roads.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: GeneralEmptyState(
                icon: Icons.menu_book_outlined,
                title: '这本书没有解析出任何章节。',
              ),
            )
          else
            ..._buildChapterSlivers(context, theme),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  /// [pageContext] 是详情页自己的 context。必须显式传入：sliver builder 的
  /// itemBuilder 有个同名参数会把它遮住，而在那个 context 上找 Navigator
  /// 虽然也能跑，但语义上应该是「从这一页推开阅读页」。
  List<Widget> _buildChapterSlivers(BuildContext pageContext, ThemeData theme) {
    final slivers = <Widget>[];
    for (var roadIndex = 0; roadIndex < roads.length; roadIndex++) {
      final road = roads[roadIndex];
      // 只有一条线路时不显示卷标题 —— 单卷书的「播放线路1」是纯噪声。
      if (roads.length > 1) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                // 规则引擎把 road 命名为「播放线路N」（动漫侧的口径），
                // 小说这里按卷展示更合适，序号自己算。
                '第 ${roadIndex + 1} 卷',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        );
      }
      slivers.add(
        SliverList.builder(
          itemCount: road.data.length,
          itemBuilder: (context, i) {
            final title = i < road.identifier.length &&
                    road.identifier[i].trim().isNotEmpty
                ? road.identifier[i]
                : '第 ${i + 1} 章';
            return ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              onTap: () => _openReader(pageContext, roadIndex, i),
            );
          },
        ),
      );
    }
    return slivers;
  }

  /// 打开阅读器。
  ///
  /// 必须用 rootNavigator：小说 tab 的 RouterOutlet 自带一层嵌套 Navigator，
  /// 用默认的 Navigator.of(context) 会把阅读页压在 tab 里，底部导航栏仍然
  /// 可见，阅读页自己的底栏还被挤掉一截 —— 看书就该整屏。
  void _openReader(BuildContext context, int roadIndex, int chapterIndex) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => NovelReaderPage(
          plugin: plugin,
          bookTitle: bookTitle,
          roads: roads,
          coverUrl: coverUrl,
          bookKey: bookKey,
          initialRoadIndex: roadIndex,
          initialChapterIndex: chapterIndex,
          // 只有「继续阅读」那一次带页号；从目录点某一章时应该从该章第一页
          // 开始，而不是跳到上次留下的页号。
          initialPageIndex: roadIndex == widget.initialRoadIndex &&
                  chapterIndex == widget.initialChapterIndex
              ? widget.initialPageIndex
              : 0,
          initialPageAnchor: roadIndex == widget.initialRoadIndex &&
                  chapterIndex == widget.initialChapterIndex
              ? widget.initialPageAnchor
              : 0,
        ),
      ),
    );
  }
}
