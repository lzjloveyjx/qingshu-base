/// 青枢 · 动漫详情页（第 1 期）。
///
/// 只做「看得清」：封面、评分、原名、放送日期、标签、简介。
/// 剧集与播放放到第 2 期（要先装 media_kit_libs_android_video）。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_source.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_media_card.dart';
import '../widgets/home/home_shelf.dart';

class AnimeDetailPage extends StatefulWidget {
  const AnimeDetailPage({super.key, required this.item});

  final MediaItem item;

  @override
  State<AnimeDetailPage> createState() => _AnimeDetailPageState();
}

class _AnimeDetailPageState extends State<AnimeDetailPage> {
  AnimeDetail? _detail;
  List<AnimeEpisode> _episodes = const [];
  bool _loading = true;
  String? _error;

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
    final id = animeIdOf(widget.item.id);
    final results = await Future.wait<Object?>([
      fetchSubjectDetail(id),
      fetchEpisodes(id),
    ]);
    if (!mounted) return;
    final detail = results[0] as AnimeDetail?;
    setState(() {
      _detail = detail;
      _episodes = results[1] as List<AnimeEpisode>;
      _loading = false;
      _error = detail == null ? '详情没拉到，检查网络后重试' : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final detail = _detail;
    final title = detail?.title.isNotEmpty == true
        ? detail!.title
        : widget.item.title;
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _body(palette, detail),
    );
  }

  Widget _body(HomePalette palette, AnimeDetail? detail) {
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
    final d = detail!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(homeGutter, 8, homeGutter, 48),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 108,
                height: 150,
                // 用首页那张封面组件：它已经接了 CachedNetworkImage + 失败
                // 兜底，也带了图床需要的 UA 头，别在这里另起一套加载方式。
                child: StoryCover(
                  item: _detailItem(widget.item, d),
                  cacheWidth: 320,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                      color: palette.ink,
                    ),
                  ),
                  if (d.original.isNotEmpty && d.original != d.title) ...[
                    const SizedBox(height: 6),
                    Text(
                      d.original,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (d.score != null) _chip(palette, '★ ' + d.score!.toStringAsFixed(1)),
                      if (d.rank != null) _chip(palette, '#' + d.rank!.toString()),
                      if (d.date.isNotEmpty) _chip(palette, d.date),
                      if ((d.eps ?? 0) > 0) _chip(palette, d.eps.toString() + ' 话'),
                      if (d.platform.isNotEmpty) _chip(palette, d.platform),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (d.tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            d.tags.take(12).join(' · '),
            style: TextStyle(fontSize: 12, color: palette.muted, height: 1.6),
          ),
        ],
        if (_episodes.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            '剧集 · ' + _episodes.length.toString(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final episode in _episodes)
                _episodeChip(palette, episode),
            ],
          ),
        ],
        const SizedBox(height: 22),
        Text(
          '简介',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: palette.ink,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          d.summary.isEmpty ? '这部番还没有简介。' : d.summary,
          style: TextStyle(
            fontSize: 13,
            height: 1.75,
            color: palette.body,
          ),
        ),
        const SizedBox(height: 28),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.soft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.info, size: 16, color: palette.muted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '剧集表已经能看到了。真正点开播放还要接播放器 —— 那是第 2 期的后半段。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: palette.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 封面用详情返回的那张（榜单条目可能没有封面），其余字段沿用列表项。
  MediaItem _detailItem(MediaItem base, AnimeDetail detail) {
    if (detail.cover.isEmpty || detail.cover == base.cover) return base;
    return base.copyWith(cover: detail.cover);
  }

  /// 一集一个方块。点按暂时只提示「还不能播」——真正拉起播放要等播放页接好。
  Widget _episodeChip(HomePalette palette, AnimeEpisode episode) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('第 ' + episode.sort.toString() + ' 话：播放还没接上'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: palette.soft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          episode.sort == episode.sort.roundToDouble()
              ? episode.sort.toStringAsFixed(0)
              : episode.sort.toStringAsFixed(1),
          style: TextStyle(fontSize: 13, color: palette.ink),
        ),
      ),
    );
  }

  Widget _chip(HomePalette palette, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.soft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: palette.ink),
      ),
    );
  }
}
