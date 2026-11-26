/// 青枢 · 动漫搜索页。
///
/// 主路径走后端全库搜索（Bangumi v0 镜像的 /v0/search/subjects）；
/// 网络不通时退回本地索引（services/anime/anime_index.dart）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_index.dart';
import '../services/anime/anime_source.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart' show homeGutter;
import 'detail_page.dart';

class AnimeSearchPage extends StatefulWidget {
  const AnimeSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  State<AnimeSearchPage> createState() => _AnimeSearchPageState();
}

class _AnimeSearchPageState extends State<AnimeSearchPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  Timer? _debounce;

  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _searched = false;
  String _lastQuery = '';
  int _total = 0;
  bool _canLoadMore = false;

  /// 当前这批结果来自本地索引（离线兜底）而不是后端。
  bool _fromIndex = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (widget.initialQuery.trim().isNotEmpty) {
      _input.text = widget.initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit(widget.initialQuery);
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_canLoadMore || _loadingMore) return;
    if (_scroll.position.pixels <
        _scroll.position.maxScrollExtent - 320) {
      return;
    }
    _loadMore();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      final q = value.trim();
      if (q.isEmpty) {
        setState(() {
          _results = const [];
          _searched = false;
          _lastQuery = '';
          _total = 0;
          _canLoadMore = false;
        });
        return;
      }
      _submit(q);
    });
  }

  Future<void> _submit(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
      _lastQuery = q;
      _fromIndex = false;
    });

    // 1) 后端全库搜索。
    final remote = await searchAnime(q);
    if (!mounted || q != _lastQuery) return;
    if (remote.items.isNotEmpty) {
      setState(() {
        _results = remote.items;
        _total = remote.total;
        _canLoadMore = remote.items.length < remote.total;
        _loading = false;
      });
      return;
    }

    // 2) 后端没结果/不可达 → 本地索引兜底。
    List<MediaItem> local = const [];
    try {
      await AnimeIndex.instance.init();
      local = AnimeIndex.instance.search(q);
    } catch (_) {}
    if (!mounted || q != _lastQuery) return;
    setState(() {
      _results = local;
      _total = local.length;
      _canLoadMore = false;
      _loading = false;
      _fromIndex = local.isNotEmpty;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_canLoadMore) return;
    setState(() => _loadingMore = true);
    final q = _lastQuery;
    final next = await searchAnime(q, offset: _results.length);
    if (!mounted || q != _lastQuery) return;
    setState(() {
      _results = [..._results, ...next.items];
      _canLoadMore = next.items.isNotEmpty && _results.length < next.total;
      _loadingMore = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _submit,
          style: TextStyle(fontSize: 16, color: palette.ink),
          decoration: InputDecoration(
            hintText: '搜索动漫',
            border: InputBorder.none,
            hintStyle: TextStyle(
              fontSize: 16,
              color: palette.ink.withValues(alpha: 0.4),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(LucideIcons.search, size: 20),
            onPressed: () => _submit(_input.text),
          ),
        ],
      ),
      body: _body(palette),
    );
  }

  Widget _body(HomePalette palette) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      return _hint(palette, '输入番剧名开始搜索');
    }
    if (_results.isEmpty) {
      return _hint(palette, '没有找到「$_lastQuery」');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(homeGutter, 10, homeGutter, 2),
          child: Text(
            _fromIndex
                ? '本地索引 · $_total 条（后端不可达时的离线结果）'
                : '共 $_total 条',
            style: TextStyle(
              fontSize: 12,
              color: palette.ink.withValues(alpha: 0.5),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 24),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 12,
              mainAxisSpacing: 18,
              childAspectRatio: 0.52,
            ),
            itemCount: _results.length + (_loadingMore ? 3 : 0),
            itemBuilder: (context, index) {
              if (index >= _results.length) {
                return const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }
              final item = _results[index];
              return HomeMediaCard(
                item: item,
                onTap: () => openBookDetail(context, item),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _hint(HomePalette palette, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: palette.ink.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
