/// 青枢 · 动漫页（第 1 期：能看见、能查详情，还不能播）。
///
/// 数据：Bangumi（国内直连不通，统一走 Kazumi 镜像 api.kazumi.fyi）。
/// 展示沿用首页的网格与卡片：排行榜分页加载，本季新番按星期分节。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_source.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';
import 'detail_page.dart';

class AnimePage extends StatefulWidget {
  const AnimePage({super.key});

  @override
  State<AnimePage> createState() => _AnimePageState();
}

class _AnimePageState extends State<AnimePage> {
  static const _tabs = ['排行榜', '本季新番'];
  static const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  static const _pageSize = 30;

  int _tab = 0;
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
        browsePopular(offset: 0, limit: _pageSize),
        browseSeason(),
      ]);
      if (!mounted) return;
      final popular = results[0] as List<MediaItem>;
      final season = results[1] as List<List<MediaItem>>;
      setState(() {
        _popular = popular;
        _season = season;
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
      final more = await browsePopular(offset: _popular.length, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _popular = [..._popular, ...more];
        _hasMore = more.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
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
            return HomeMediaCard(
              item: item,
              cacheWidth: 360,
              onTap: () => _open(item),
            );
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
