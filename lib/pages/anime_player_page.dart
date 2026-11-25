/// 青枢 · 动漫精简播放页（第 2 期）。
///
/// 复用 Kazumi 的规则引擎（搜索播放源 → 取分集 → WebView 解析真实地址），
/// 但播放器用青枢自己的 media_kit —— 不搬 Kazumi 581 行原皮 VideoPage。
///
/// 链路：PluginsController（规则）→ queryChapterRoads（分集 URL）
///      → WebViewVideoSourceService.resolve（真实 m3u8/mp4）→ Player.open。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';

import '../widgets/home/home_design.dart';
import '../services/anime/anime_source.dart';

/// 打开动漫播放页。[itemId] 是 anime:{subjectId}，[episode] 从 1 开始。
Future<void> openAnimePlayer(
  BuildContext context, {
  required MediaItem item,
  required int episode,
}) async {
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => AnimePlayerPage(item: item, episode: episode),
    ),
  );
}

class AnimePlayerPage extends StatefulWidget {
  const AnimePlayerPage({
    super.key,
    required this.item,
    required this.episode,
  });

  final MediaItem item;
  final int episode;

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

class _AnimePlayerPageState extends State<AnimePlayerPage> {
  late final Player _player;
  late final VideoController _videoController;
  WebViewVideoSourceService? _resolver;
  PluginsController? _plugins;

  bool _resolving = true;
  String? _error;
  List<Plugin> _pluginsWithResults = const [];
  int _pluginIndex = 0;
  List<Road> _roads = const [];
  int _roadIndex = 0;
  List<String> get _episodeUrls =>
      _roads.isEmpty ? const [] : (_roads[_roadIndex].data);
  int _episodeIndex = 0;
  String _status = '正在搜索播放源…';
  StreamSubscription<Object>? _errorSub;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _errorSub = _player.stream.error.listen((event) {
      if (mounted) setState(() => _error = '播放出错：' + event.toString());
    });
    _start();
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _resolver?.dispose();
    _videoController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _resolving = true;
      _error = null;
      _status = '正在搜索播放源…';
    });
    try {
      await KazumiBootstrap.ensureReady();
      final plugins = KazumiBootstrap.plugins;
      _plugins = plugins;
      final keyword = widget.item.title;
      // 逐个规则搜索，收集有结果的源。
      final found = <Plugin>[];
      for (final plugin in plugins.pluginList) {
        try {
          final result = await plugin.queryBangumi(keyword, shouldRethrow: true);
          if (result.data.isNotEmpty) found.add(plugin);
        } catch (_) {}
      }
      if (found.isEmpty) {
        if (!mounted) return;
        setState(() {
          _resolving = false;
          _error = '没有找到可用的播放源。先去「我的 → 播放源」装几条规则。';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _pluginsWithResults = found;
        _pluginIndex = 0;
      });
      await _loadRoads(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = '搜索播放源失败：' + e.toString();
      });
    }
  }

  /// 取某个源的分集线路。
  Future<void> _loadRoads(int pluginIndex) async {
    if (pluginIndex >= _pluginsWithResults.length) return;
    setState(() {
      _resolving = true;
      _status = '正在读取分集列表…';
    });
    try {
      final plugin = _pluginsWithResults[pluginIndex];
      // 搜索结果里第一条的 src 就是详情 URL。
      final result = await plugin.queryBangumi(widget.item.title, shouldRethrow: true);
      final src = result.data.first.src;
      final roads = await plugin.queryChapterRoads(src);
      if (roads.isEmpty) throw StateError('这个源没有分集');
      // 默认从传入的集数开始（减 1 转 0 基）。
      final initial = (_roads.isEmpty ? widget.episode - 1 : _episodeIndex)
          .clamp(0, roads.first.data.length - 1);
      if (!mounted) return;
      setState(() {
        _pluginIndex = pluginIndex;
        _roads = roads;
        _roadIndex = 0;
        _episodeIndex = initial < 0 ? 0 : initial,
        _resolving = false;
      });
      await _playCurrent();
    } catch (e) {
      if (!mounted) return;
      // 这条源失败就自动试下一条。
      if (pluginIndex + 1 < _pluginsWithResults.length) {
        await _loadRoads(pluginIndex + 1);
      } else {
        setState(() {
          _resolving = false;
          _error = '所有播放源都解析失败，换一部或稍后再试。';
        });
      }
    }
  }

  /// 解析并播放当前分集。
  Future<void> _playCurrent() async {
    if (_episodeUrls.isEmpty) return;
    final url = _episodeUrls[_episodeIndex];
    setState(() {
      _resolving = true;
      _status = '正在解析第 ' + (_episodeIndex + 1).toString() + ' 集…';
      _error = null;
    });
    try {
      final plugin = _pluginsWithResults[_pluginIndex];
      _resolver ??= WebViewVideoSourceService();
      final source = await _resolver!.resolve(
        plugin.buildFullUrl(url),
        useLegacyParser: plugin.useLegacyParser,
      );
      if (!mounted) return;
      setState(() {
        _resolving = false;
      });
      await _player.open(
        Media(
          source.url,
          httpHeaders: plugin.buildHttpHeaders(),
        ),
        play: true,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = '解析播放地址失败：' + e.toString();
      });
    }
  }

  void _pickEpisode(int index) {
    setState(() => _episodeIndex = index);
    _playCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.item.title + ' · 第 ' + (_episodeIndex + 1).toString() + ' 集',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_pluginsWithResults.length > 1)
            PopupMenuButton<int>(
              icon: const Icon(Icons.playlist_play),
              color: palette.surface,
              onSelected: (i) => _loadRoads(i),
              itemBuilder: (context) => [
                for (var i = 0; i < _pluginsWithResults.length; i++)
                  PopupMenuItem<int>(
                    value: i,
                    child: Text(
                      _pluginsWithResults[i].name,
                      style: TextStyle(
                        color: i == _pluginIndex ? palette.accentText : null,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // 不传 controls 就用 media_kit 默认控制条（播放/暂停/进度/全屏）。
                Video(
                  controller: _videoController,
                  fit: BoxFit.contain,
                ),
                if (_resolving)
                  Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(
                          _status,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Container(
                    color: Colors.black.withValues(alpha: 0.8),
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.white, size: 32),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _start,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text(
                  '选集',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                const Spacer(),
                if (_roads.isNotEmpty && _roads.length > 1)
                  DropdownButton<int>(
                    value: _roadIndex,
                    dropdownColor: palette.surface,
                    style: TextStyle(color: palette.ink, fontSize: 12),
                    underline: const SizedBox.shrink(),
                    items: [
                      for (var i = 0; i < _roads.length; i++)
                        DropdownMenuItem<int>(
                          value: i,
                          child: Text(_roads[i].name),
                        ),
                    ],
                    onChanged: (i) {
                      if (i == null) return;
                      setState(() {
                        _roadIndex = i;
                        _episodeIndex = 0;
                      });
                      _playCurrent();
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _episodeUrls.isEmpty
                ? const Center(
                    child: Text(
                      '暂无分集',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.4,
                    ),
                    itemCount: _episodeUrls.length,
                    itemBuilder: (context, i) => GestureDetector(
                      onTap: () => _pickEpisode(i),
                      child: Container(
                        decoration: BoxDecoration(
                          color: i == _episodeIndex
                              ? palette.accentText
                              : Colors.white12,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          (i + 1).toString(),
                          style: TextStyle(
                            color: i == _episodeIndex ? Colors.white : Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
