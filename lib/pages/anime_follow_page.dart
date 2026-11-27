/// 青枢 · 追番页（第四期：追番列表 + 更新提醒 + 未看集数角标）。
///
/// 为什么单独做一页，而不是「书架→筛动漫」：
///   - 书架按加入时间排，追番要按「最近更新 / 最近看过」排
///   - 书架卡片不显示「看到第几集 / 共几集」
///   - 书架没有「未看多少集」这个概念，而追番的核心就是它
///
/// 数据来源（两边都已经存在，只是没被放到一起）：
///   - 追了哪些：ShelfStore 里 kind == 'anime' 的记录
///   - 看到哪了：Kazumi 的 History（每部番一条，progresses 里按集存进度）
///   - 共多少集：指标题里的集数，拿不到就显示「—」
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../models/media_item.dart';
import '../services/anime/anime_source.dart';
import '../services/shelf_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/home/home_shelf.dart';
import 'detail_page.dart';
import 'package:kazumi/modules/history/history_module.dart';
import '../services/anime/qingshu_playback.dart';

/// 一部追番的聚合视图。
class _FollowEntry {
  _FollowEntry({
    required this.item,
    required this.addedAt,
    this.history,
    this.watchedEpisodes = 0,
    this.lastEpisode = 0,
    this.lastWatchTime,
  });

  final MediaItem item;
  final DateTime addedAt;
  final History? history;

  /// 有进度记录的集数（progress 非零即算看过）。
  final int watchedEpisodes;

  /// 最后一次看的集数。
  final int lastEpisode;
  final DateTime? lastWatchTime;

  int get totalEpisodes {
    final parsed = int.tryParse(item.ep.trim());
    return parsed ?? 0;
  }

  /// 未看集数。总数拿不到时返回 -1（UI 显示「—」而不是瞎编）。
  int get unwatched {
    final total = totalEpisodes;
    if (total <= 0) return -1;
    final left = total - watchedEpisodes;
    return left < 0 ? 0 : left;
  }

  /// 排序键：最近看过的排前面，没看过的按加入时间。
  DateTime get sortKey => lastWatchTime ?? addedAt;
}

class AnimeFollowPage extends StatefulWidget {
  const AnimeFollowPage({super.key});

  @override
  State<AnimeFollowPage> createState() => _AnimeFollowPageState();
}

class _AnimeFollowPageState extends State<AnimeFollowPage> {
  bool _loading = true;
  List<_FollowEntry> _entries = const [];

  /// 排序方式：最近活跃 / 未看集数多 / 加入时间。
  int _sort = 0;

  @override
  void initState() {
    super.initState();
    _load();
    ShelfStore.instance.listenable.addListener(_onShelfChanged);
  }

  @override
  void dispose() {
    ShelfStore.instance.listenable.removeListener(_onShelfChanged);
    super.dispose();
  }

  void _onShelfChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // 必须是 QingshuPlayback 的那一份：播放页与下载页写进度用的就是它。
      // KazumiBootstrap 里还有一个同名的 HistoryController，是两套独立实例，
      // 读那边会永远看到空列表。
      await QingshuPlayback.ensureReady();
      final records = ShelfStore.instance
          .records()
          .where((r) => isAnimeItem(r.item))
          .toList();

      // 每部番一条 History，按 bangumi id 索引。
      final histories = <int, History>{};
      for (final h in QingshuPlayback.history.histories) {
        histories[h.bangumiItem.id] = h;
      }

      final out = <_FollowEntry>[];
      for (final record in records) {
        final bangumiId = animeIdOf(record.item.id);
        final history = histories[bangumiId];

        var watched = 0;
        var lastEp = 0;
        if (history != null) {
          for (final entry in history.progresses.entries) {
            // progress 为零的是「开过但没看」，不算已看。
            if (entry.value.progress > Duration.zero) watched++;
            if (entry.key > lastEp) lastEp = entry.key;
          }
        }

        out.add(_FollowEntry(
          item: record.item,
          addedAt: record.addedAt,
          history: history,
          watchedEpisodes: watched,
          lastEpisode: lastEp,
          lastWatchTime: history?.lastWatchTime,
        ));
      }

      if (!mounted) return;
      setState(() {
        _entries = out;
        _loading = false;
      });
      _resort();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _resort() {
    final sorted = List<_FollowEntry>.of(_entries);
    switch (_sort) {
      case 1:
        // 未看最多的在前；拿不到总数的（-1）沉底。
        sorted.sort((a, b) {
          final ua = a.unwatched < 0 ? -1 : a.unwatched;
          final ub = b.unwatched < 0 ? -1 : b.unwatched;
          return ub.compareTo(ua);
        });
      case 2:
        sorted.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      default:
        sorted.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    }
    setState(() => _entries = sorted);
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        title: const Text('追番'),
        centerTitle: false,
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            tooltip: '排序',
            icon: const Icon(LucideIcons.arrow_up_down, size: 20),
            onPressed: _showSortSheet,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(LucideIcons.refresh_cw, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(palette),
    );
  }

  Future<void> _showSortSheet() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, label) in const [
              (0, '最近活跃'),
              (1, '未看集数'),
              (2, '加入时间'),
            ])
              ListTile(
                dense: true,
                selected: _sort == index,
                title: Text(label),
                trailing: _sort == index
                    ? const Icon(LucideIcons.check, size: 16)
                    : null,
                onTap: () => Navigator.of(context).pop(index),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _sort = picked);
    _resort();
  }

  Widget _body(HomePalette palette) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.tv, size: 42, color: palette.muted),
              const SizedBox(height: 12),
              Text(
                '还没有追番\n在动漫详情页点「加入书架」就会出现在这里',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
      padding: EdgeInsets.only(
        top: 8,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
        left: homeGutter,
        right: homeGutter,
      ),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: palette.line,
      ),
      itemBuilder: (context, index) =>
          _FollowRow(entry: _entries[index], palette: palette),
      ),
    );
  }
}

class _FollowRow extends StatelessWidget {
  const _FollowRow({required this.entry, required this.palette});

  final _FollowEntry entry;
  final HomePalette palette;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final unwatched = entry.unwatched;
    return InkWell(
      onTap: () => openBookDetail(context, item),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              height: 86,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: item.cover.isEmpty
                    ? Container(color: palette.line)
                    : Image.network(
                        item.cover,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            Container(color: palette.line),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _progressText(entry),
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      if (unwatched > 0)
                        _Badge(
                          text: '未看 $unwatched 集',
                          color: palette.ink,
                        )
                      else if (unwatched == 0)
                        _Badge(text: '已看完', color: palette.muted)
                      else
                        _Badge(text: '集数未知', color: palette.muted),
                      const Spacer(),
                      if (entry.lastWatchTime != null)
                        Text(
                          _relativeTime(entry.lastWatchTime!),
                          style: TextStyle(fontSize: 11, color: palette.muted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _progressText(_FollowEntry entry) {
    if (entry.lastEpisode <= 0) return '还没有开始看';
    final total = entry.totalEpisodes;
    return total > 0
        ? '看到第 ${entry.lastEpisode} 集 / 共 $total 集'
        : '看到第 ${entry.lastEpisode} 集';
  }

  static String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 10, color: color),
        ),
      );
}
