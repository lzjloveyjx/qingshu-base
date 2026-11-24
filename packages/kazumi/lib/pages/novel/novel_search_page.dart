import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/bean/widget/novel_cover_image.dart';
import 'package:kazumi/pages/novel/novel_book_page.dart';
import 'package:kazumi/pages/novel/novel_shelf_page.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/novel/novel_local_index.dart';
import 'package:kazumi/services/plugin/captcha_flow.dart';

/// 轻小说主页。
///
/// 三个状态：
///   • 刚进来 → 直接显示书目（有随包索引就用索引，否则抓榜单）
///   • 搜过 → 显示搜索结果（网格 + 封面）
///   • 搜索被验证码拦住 → 弹验证码，通过后自动继续（仅在线搜索的源）
///
/// 搜索优先走随包索引：wenku8 的站点搜索要登录，但书目索引随包带着，
/// 本地子串匹配能覆盖全站每一本，且不需要账号。
class NovelSearchPage extends StatefulWidget {
  const NovelSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<NovelSearchPage> createState() => _NovelSearchPageState();
}

class _NovelSearchPageState extends State<NovelSearchPage> {
  final TextEditingController _input = TextEditingController();
  final List<Plugin> _sources = <Plugin>[];
  Plugin? _source;

  bool _searching = false;
  String _error = '';
  List<SearchItem> _results = const <SearchItem>[];

  /// true = 当前显示的是搜索结果；false = 首屏书目。
  bool _showingSearch = false;

  /// 打开一本书时的加载态（取 chapterRoads 可能慢）。
  String _openingBook = '';

  late final CaptchaFlow _captchaFlow;

  /// 随包索引（搜索要登录的站点用）。
  NovelLocalIndex? _localIndex;

  /// 封面图带的 Referer（取规则里声明的）。
  String get _imageReferer {
    final plugin = _source;
    if (plugin == null) return '';
    final referer = plugin.referer.trim();
    return referer.isNotEmpty ? referer : plugin.baseUrl;
  }

  @override
  void initState() {
    super.initState();
    _input.text = widget.initialQuery;
    final controller = inject<PluginsController>();
    _sources
      ..clear()
      ..addAll(controller.pluginList.where((p) => p.supportsNovel));
    _source = _sources.isEmpty ? null : _sources.first;
    _captchaFlow = CaptchaFlow(
      onVerified: _onVerified,
      onCancelled: (plugin) {
        if (mounted) setState(() => _searching = false);
      },
    );
    // 进入即加载内容：用户点开 tab 就该看到书，而不是一张空页面。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadLocalIndex();
      if (widget.initialQuery.trim().isNotEmpty) {
        await _search();
      } else {
        await _loadHomeList();
      }
    });
  }

  @override
  void dispose() {
    _captchaFlow.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 加载随包书目索引（只有配了 novelIndexAsset 的规则才有）。
  Future<void> _loadLocalIndex() async {
    final plugin = _source;
    final asset = plugin?.novelIndexAsset.trim() ?? '';
    if (asset.isEmpty) {
      _localIndex = null;
      return;
    }
    if (_localIndex != null) return;
    final index = await NovelLocalIndex.load(asset);
    if (!mounted) return;
    setState(() => _localIndex = index);
  }

  /// 首屏书目。
  Future<void> _loadHomeList() async {
    final plugin = _source;
    if (plugin == null || _searching) return;
    // 有本地索引就直接拿它当首页列表 —— 比在线抓榜单快，而且是全站书目。
    final index = _localIndex;
    if (index != null) {
      setState(() {
        _results = index.browse(plugin);
        _showingSearch = false;
        _error = '';
      });
      return;
    }
    // 规则声明了随包索引、但索引没加载出来（资源缺失/JSON 坏了）时，
    // 不要退回在线榜单：这类站点的榜单页往往需要登录，抓回来的是导航噪声。
    // 直接报错，让用户看到真实原因，而不是一屏乱七八糟的假书。
    if (plugin.novelIndexAsset.trim().isNotEmpty) {
      setState(() {
        _error = '随包书目索引没能加载（${plugin.novelIndexAsset}）。\n'
            '重装 App 或检查安装包是否完整。';
        _results = const <SearchItem>[];
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = '';
      _showingSearch = false;
    });
    try {
      final ranking = plugin.forRanking();
      final response = await ranking.queryBangumi('');
      if (!mounted) return;
      setState(() => _results = response.data);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _search() async {
    final plugin = _source;
    final keyword = _input.text.trim();
    if (plugin == null) return;
    if (keyword.isEmpty) {
      await _loadHomeList();
      return;
    }
    // 有本地索引就在本地搜：能覆盖全站每一本，而且不需要登录。
    final index = _localIndex;
    if (index != null) {
      final hits = index.search(keyword, plugin);
      setState(() {
        _results = hits;
        _showingSearch = true;
        _error = '';
        _searching = false;
      });
      return;
    }
    if (_searching) return;
    setState(() {
      _searching = true;
      _error = '';
      _showingSearch = true;
      _results = const <SearchItem>[];
    });
    try {
      final response = await plugin.queryBangumi(keyword);
      if (!mounted) return;
      setState(() => _results = response.data);
    } on CaptchaRequiredException {
      if (mounted) setState(() => _searching = false);
      _captchaFlow.start(plugin, keyword);
      return;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// 验证通过后直接用收割到的页面解析，省一次请求。
  void _onVerified(Plugin plugin, String pageHtml) {
    if (!mounted) return;
    try {
      final harvested = plugin.parseHarvestedSearch(pageHtml);
      if (harvested != null && harvested.data.isNotEmpty) {
        setState(() {
          _results = harvested.data;
          _error = '';
          _searching = false;
          _showingSearch = true;
        });
        return;
      }
    } catch (_) {
      // 收割页解析不了就走重试
    }
    _search();
  }

  Future<void> _switchSource(Plugin plugin) async {
    if (identical(plugin, _source)) return;
    setState(() {
      _source = plugin;
      _localIndex = null;
      _results = const <SearchItem>[];
      _error = '';
      _showingSearch = false;
      _searching = false;
    });
    _input.clear();
    await _loadLocalIndex();
    await _loadHomeList();
  }

  Future<void> _openBook(SearchItem item) async {
    final plugin = _source;
    if (plugin == null || _openingBook.isNotEmpty) return;
    setState(() => _openingBook = item.name);
    try {
      final roads = await plugin.queryChapterRoads(item.src);
      if (!mounted) return;
      if (roads.isEmpty) {
        setState(() => _error = '这本书没有解析出任何章节：规则可能失效了。');
        return;
      }
      // 用 rootNavigator：小说 tab 的 RouterOutlet 自带嵌套 Navigator，
      // 默认 Navigator.of(context) 会把详情页压在 tab 里，底部导航栏仍在。
      // 详情/阅读都该盖住整个 shell（和动漫的 /info/ 行为一致）。
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => NovelBookPage(
            plugin: plugin,
            bookTitle: item.name,
            roads: roads,
            coverUrl: item.cover,
            // 书籍身份用详情页 URL：它是这条搜索结果唯一稳定的标识，
            // 书名会重名，aid 只在单站点内唯一。
            bookKey: item.src,
          ),
        ),
      );
    } catch (e) {
      KazumiLogger().w('novel open book failed: ${e}');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _openingBook = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: SysAppBar(
        title: const Text('轻小说'),
        actions: [
          IconButton(
            tooltip: '书架',
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(builder: (_) => const NovelShelfPage()),
            ),
            icon: const Icon(Icons.collections_bookmark_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '搜书名 / 作者',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (_sources.length > 1)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final p in _sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(p.name),
                        selected: identical(p, _source),
                        onSelected: (_) => _switchSource(p),
                      ),
                    ),
                ],
              ),
            ),
          if (_sources.isEmpty)
            const Expanded(
              child: GeneralEmptyState(
                icon: Icons.auto_stories_outlined,
                title: '还没有小说规则源。\n'
                    '到「我的 → 规则管理」装一条 type=novel 的规则。',
              ),
            )
          else if (_searching || _openingBook.isNotEmpty)
            const Expanded(child: Center(child: LoadingIndicator()))
          else if (_error.isNotEmpty)
            Expanded(
              child: GeneralEmptyState(
                icon: Icons.error_outline,
                title: _error,
                actions: [
                  FilledButton(
                    onPressed: _showingSearch ? _search : _loadHomeList,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else if (_results.isEmpty)
            Expanded(
              child: GeneralEmptyState(
                icon: Icons.search,
                title: _showingSearch
                    ? '没有搜到这本书。\n换个关键词，或者用繁体书名试试。'
                    : '书目暂时没加载出来，下拉重试。',
                actions: [
                  FilledButton(
                    onPressed: _showingSearch ? _search : _loadHomeList,
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: _showingSearch ? _search : _loadHomeList,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 130,
                    childAspectRatio: 0.58,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, i) => _BookCard(
                    item: _results[i],
                    theme: theme,
                    referer: _imageReferer,
                    onTap: () => _openBook(_results[i]),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一本书的封面卡片。
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.item,
    required this.theme,
    required this.referer,
    required this.onTap,
  });

  final SearchItem item;
  final ThemeData theme;
  final String referer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.cover.isEmpty
                  ? Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      alignment: Alignment.center,
                      child: const Icon(Icons.menu_book_outlined, size: 28),
                    )
                  : NovelCoverImage(
                      url: item.cover,
                      referer: referer,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
