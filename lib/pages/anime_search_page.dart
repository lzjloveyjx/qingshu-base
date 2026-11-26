/// 青枢 · 动漫搜索页。
///
/// 数据来自 AnimeSource 的本地语料匹配（榜单多页 + 当季 + 上季），
/// 见 services/anime/anime_loaders.dart 的 animeHomeSearchTabs。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_loaders.dart';
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
  Timer? _debounce;
  List<MediaItem> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) {
      _input.text = widget.initialQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit(widget.initialQuery);
      });
    } else {
      // 进页面就能直接打字，少一次点击。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // 本地匹配很快，停顿 350ms 就够，不必等用户按回车。
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final q = value.trim();
      if (q.isEmpty) {
        setState(() {
          _results = const [];
          _searched = false;
          _lastQuery = '';
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
    });
    try {
      final tabs = await animeHomeSearchTabs(q);
      if (!mounted || q != _lastQuery) return;
      setState(() {
        _results = tabs.isEmpty ? const [] : tabs.first.items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _loading = false;
      });
    }
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
          autofocus: false,
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
      return _hint(
        palette,
        '没有找到「$_lastQuery」\n\n'
            '搜索范围是当前榜单与近两季新番。若确定存在，'
            '可到「本季新番」或「排行榜」里翻一翻。',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 24),
      // 与动漫页的网格保持一致，切页时卡片尺寸不跳。
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
        childAspectRatio: 0.52,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final item = _results[index];
        return HomeMediaCard(
          item: item,
          onTap: () => openBookDetail(context, item),
        );
      },
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
