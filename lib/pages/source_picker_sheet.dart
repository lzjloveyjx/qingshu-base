/// 青枢 · 动漫选源弹窗（学 Kazumi 的节奏）。
///
/// 点剧集后先弹这个面板：并发搜索所有已装规则，按源分组展示每条源搜出的
/// 结果，用户自己选一条，面板内取好分集（roads）再返回给播放页。
///
/// 只复用 Kazumi 的底层搜索 API（plugin.queryBangumi / queryChapterRoads）
/// 和三个轻数据类，不碰它的 SourceSheet / InfoController / modular 路由。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show CaptchaRequiredException, NoResultException, RuleCancelToken;

import '../services/anime/anime_source.dart';
import '../widgets/home/home_design.dart';

/// 用户选中的那一条：源 + 搜索结果 + 已取好的分集线路。
class PickedSource {
  const PickedSource({
    required this.plugin,
    required this.item,
    required this.roads,
  });

  final Plugin plugin;
  final SearchItem item;
  final List<Road> roads;
}

/// 弹出选源面板。返回 [PickedSource]，用户取消返回 null。
Future<PickedSource?> showSourcePicker(
  BuildContext context, {
  required MediaItem anime,
  required int episode,
}) => showModalBottomSheet<PickedSource>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => SourcePickerSheet(anime: anime, episode: episode),
);

class SourcePickerSheet extends StatefulWidget {
  const SourcePickerSheet({
    super.key,
    required this.anime,
    required this.episode,
  });

  final MediaItem anime;
  final int episode;

  @override
  State<SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourceGroup {
  _SourceGroup(this.plugin);
  final Plugin plugin;
  PluginSearchStatus status = PluginSearchStatus.pending;
  List<SearchItem> results = const [];
  bool expanded = false;
}

class _SourcePickerSheetState extends State<SourcePickerSheet> {
  final List<_SourceGroup> _groups = [];
  final RuleCancelToken _cancel = RuleCancelToken();
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _cancel.cancel();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await KazumiBootstrap.ensureReady();
      final plugins = KazumiBootstrap.plugins.pluginList.toList();
      if (plugins.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '还没有装播放源。先去「我的 → 播放源」装几条规则。';
        });
        return;
      }
      final keyword = widget.anime.title;
      final groups = [for (final p in plugins) _SourceGroup(p)];
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
      });
      // 并发搜全部源，边搜边刷。
      await Future.wait(groups.map((g) => _searchOne(g, keyword)));
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '搜索播放源失败：' + e.toString();
      });
    }
  }

  Future<void> _searchOne(_SourceGroup group, String keyword) async {
    try {
      final result = await group.plugin.queryBangumi(
        keyword,
        shouldRethrow: true,
        cancelToken: _cancel,
      );
      if (!mounted) return;
      setState(() {
        group.results = result.data;
        group.status = result.data.isEmpty
            ? PluginSearchStatus.noResult
            : PluginSearchStatus.success;
        // 有结果的源默认展开第一条（Kazumi 的做法）。
        group.expanded = result.data.isNotEmpty;
      });
    } on CaptchaRequiredException {
      if (!mounted) return;
      setState(() => group.status = PluginSearchStatus.captcha);
    } on NoResultException {
      if (!mounted) return;
      setState(() => group.status = PluginSearchStatus.noResult);
    } catch (_) {
      if (!mounted) return;
      setState(() => group.status = PluginSearchStatus.error);
    }
  }

  Future<void> _pick(_SourceGroup group, SearchItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final roads = await group.plugin.queryChapterRoads(item.src);
      if (roads.isEmpty) throw StateError('这个源没有分集');
      if (!mounted) return;
      Navigator.pop(
        context,
        PickedSource(plugin: group.plugin, item: item, roads: roads),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('取分集失败：' + e.toString()),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final success = _groups
        .where((g) => g.status == PluginSearchStatus.success)
        .fold<int>(0, (n, g) => n + g.results.length);
    return Container(
      decoration: BoxDecoration(
        color: palette.canvas,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(palette, success),
            Expanded(child: _body(palette)),
          ],
        ),
      ),
    );
  }

  Widget _header(HomePalette palette, int success) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '播放来源',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _loading
                    ? '正在检索 ${_groups.length} 个源…'
                    : '${_groups.length} 个来源 · $success 个结果',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
        ),
        if (_loading)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: Icon(LucideIcons.x, color: palette.muted),
        ),
      ],
    ),
  );

  Widget _body(HomePalette palette) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.cloud_off, size: 40, color: palette.muted),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: palette.muted)),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _search,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      itemCount: _groups.length,
      itemBuilder: (context, i) => _groupTile(_groups[i], palette),
    );
  }

  Widget _groupTile(_SourceGroup group, HomePalette palette) {
    final statusText = switch (group.status) {
      PluginSearchStatus.pending => '检索中…',
      PluginSearchStatus.success => '${group.results.length} 个结果',
      PluginSearchStatus.noResult => '无结果',
      PluginSearchStatus.error => '检索失败',
      PluginSearchStatus.captcha => '需要验证',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => group.expanded = !group.expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      group.plugin.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    group.expanded
                        ? LucideIcons.chevron_up
                        : LucideIcons.chevron_down,
                    size: 16,
                    color: palette.muted,
                  ),
                ],
              ),
            ),
          ),
          if (group.expanded) ...[
            if (group.status == PluginSearchStatus.pending)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Text('正在检索…',
                    style: TextStyle(fontSize: 12, color: palette.muted)),
              )
            else if (group.status != PluginSearchStatus.success)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: Text(
                  group.status == PluginSearchStatus.captcha
                      ? '这个源需要验证码，暂不支持；换一条规则试试。'
                      : '没搜到结果，可以换条规则。',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              )
            else
              for (final item in group.results)
                ListTile(
                  dense: true,
                  leading: Icon(LucideIcons.play,
                      size: 16, color: palette.accentText),
                  title: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: palette.ink),
                  ),
                  onTap: _busy ? null : () => _pick(group, item),
                ),
          ],
        ],
      ),
    );
  }
}
