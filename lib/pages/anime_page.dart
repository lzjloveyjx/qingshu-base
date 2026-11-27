/// 青枢 · 动漫页（第 1 期：能看见、能查详情，还不能播）。
///
/// 数据：Bangumi（国内直连不通，统一走 Kazumi 镜像 api.kazumi.fyi）。
/// 展示沿用首页的网格与卡片：热门番组分页加载 + 题材筛选，本季新番按星期分节。
///
/// 「热门番组」必须与 Kazumi 原版一致 —— 走 /kazumi/v1/popular/subjects
/// （对 next.bgm.tv/p1/trending 的代理），是当下热度流，不是评分排名。
/// 题材菜单也照抄 Kazumi 的 defaultAnimeTags。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_source.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import 'anime_search_page.dart';
import 'detail_page.dart';

class AnimePage extends StatefulWidget {
  const AnimePage({super.key});

  @override
  State<AnimePage> createState() => _AnimePageState();
}

class _AnimePageState extends State<AnimePage> {
  // 第一项是「热门番组」（Kazumi 原版叫法），第二项是本季新番时间表。
  static const _tabs = ['热门番组', '本季新番'];
  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  // 与 Kazumi 的 _trendPageSize 一致（24 条/页）。
  static const int _pageSize = browsePageSize;

  int _tab = 0;

  /// 当前榜单题材。空串 = Kazumi 的「热门番组」总流。
  String _tag = '';

  /// 已向镜像请求过的条数（翻页游标，独立于列表长度）。
  int _loadedOffset = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  List<MediaItem> _popular = const [];
  List<List<MediaItem>> _season = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        browsePopular(offset: 0, limit: _pageSize, tag: _tag),
        browseSeason(),
      ]);
      if (!mounted) return;
      final popular = results[0] as List<MediaItem>;
      final season = results[1] as List<List<MediaItem>>;
      setState(() {
        _popular = popular;
        _season = season;
        _loadedOffset = popular.length;
        _hasMore = popular.length >= _pageSize;
        _loading = false;
        _error = (popular.isEmpty && season.every((d) => d.isEmpty))
            ? '镜像没有返回内容，检查网络后重试'
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      // 【青枢】offset 必须用「已请求过的条数」而不是 _popular.length。
      // 两种情况会让两者不等：① 镜像返回的条目里有解析失败的（标题为空
      // 会被丢掉）；② 后端返回重复 subject 被去重。用 _popular.length
      // 会回退 offset，导致一次「加载更多」拉回已经看过的内容。
      final more = await browsePopular(
        offset: _loadedOffset,
        limit: _pageSize,
        tag: _tag,
      );
      if (!mounted) return;
      setState(() {
        _loadedOffset += more.length;
        final existing = _popular.map((item) => item.id).toSet();
        _popular = [
          ..._popular,
          ...more.where((item) => existing.add(item.id)),
        ];
        // 拿满一页就认为还有更多：Kazumi 原版也是这么判断的
        // （trendList 用 isNotEmpty 判断，一直翻到上游返回空为止）。
        _hasMore = more.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 切题材。与 Kazumi 的 _selectTag 一致：清掉当前列表、游标归零、重拉。
  Future<void> _selectTag(String tag) async {
    if (tag == _tag) return;
    setState(() {
      _tag = tag;
      _popular = const [];
      _loadedOffset = 0;
      _hasMore = true;
      _tab = 0;
    });
    await _load();
  }

  /// 题材菜单。顺序与 Kazumi 的 `['', ...defaultAnimeTags]` 完全一致。
  Future<void> _showTagMenu() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final palette = HomePalette.of(context);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final tag in const ['', ...animeRankTags])
                ListTile(
                  dense: true,
                  selected: tag == _tag,
                  selectedColor: palette.ink,
                  title: Text(tag.isEmpty ? '热门番组' : tag),
                  trailing: tag == _tag
                      ? Icon(LucideIcons.check, size: 16,
                          color: palette.ink)
                      : null,
                  onTap: () => Navigator.of(context).pop(tag),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    await _selectTag(picked);
  }

  void _open(MediaItem item) => openBookDetail(context, item);

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('动漫'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: '搜索动漫',
            icon: const Icon(LucideIcons.search, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AnimeSearchPage(),
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(LucideIcons.refresh_cw, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: homeGutter),
              child: Row(
                children: [
                  // 第一项是「热门番组 / 题材名」，点开就是 Kazumi 同款的
                  // 题材菜单（空串 = 总流，其余按题材筛）。
                  GestureDetector(
                    onTap: _showTagMenu,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _tag.isEmpty ? '热门番组' : _tag,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: palette.ink,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            LucideIcons.chevron_down,
                            size: 14,
                            color: palette.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  for (var i = 0; i < _tabs.length; i++) ...[
                    if (i > 0) const SizedBox(width: 18),
                    GestureDetector(
                      onTap: () => setState(() => _tab = i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _tabs[i],
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: _tab == i
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: _tab == i
                                ? palette.ink
                                : palette.ink.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      body: _body(palette),
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
              OutlinedButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return CustomScrollView(
      slivers: _tab == 0 ? _popularSlivers(palette) : _seasonSlivers(palette),
    );
  }

  List<Widget> _popularSlivers(HomePalette palette) {
    if (_popular.isEmpty) {
      return [SliverFillRemaining(hasScrollBody: false, child: _empty(palette))];
    }
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      _grid(_popular),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 40),
          child: Center(
            child: _loadingMore
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : _hasMore
                    ? OutlinedButton(onPressed: _loadMore, child: const Text('加载更多'))
                    : Text('就这么多了', style: TextStyle(fontSize: 12, color: palette.muted)),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 56)),
    ];
  }

  List<Widget> _seasonSlivers(HomePalette palette) {
    final sections = <Widget>[];
    var any = false;
    for (var i = 0; i < _season.length; i++) {
      final items = _season[i];
      if (items.isEmpty) continue;
      any = true;
      sections.add(_sectionHeader(_weekdayLabels[i], items.length, palette));
      sections.add(_grid(items));
    }
    if (!any) {
      return [SliverFillRemaining(hasScrollBody: false, child: _empty(palette))];
    }
    return [
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ...sections,
      const SliverToBoxAdapter(child: SizedBox(height: 96)),
    ];
  }

  Widget _sectionHeader(String title, int count, HomePalette palette) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(homeGutter, 16, homeGutter, 10),
        child: Row(
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: palette.ink,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                color: palette.ink.withValues(alpha: 0.38),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(List<MediaItem> items) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: homeGutter),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 18,
          childAspectRatio: 0.52,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];
            return HomeMediaCard(item: item, onTap: () => _open(item));
          },
          childCount: items.length,
        ),
      ),
    );
  }

  Widget _empty(HomePalette palette) {
    return Center(
      child: Text('暂无内容', style: TextStyle(color: palette.muted)),
    );
  }
}
