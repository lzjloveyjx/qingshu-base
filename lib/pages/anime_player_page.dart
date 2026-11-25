/// 青枢 · 动漫播放页。
///
/// 选源弹窗选好后进这里：只消费 picked，自己不再搜索。
/// 播放器用 media_kit；在默认控制条之外补了倍速 / 画幅 / 跳过片头 /
/// 定时关闭 / 锁屏 / 播放信息这几个 Kazumi 有而我们原来缺的功能。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';

import '../models/media_item.dart';
import '../widgets/home/home_design.dart';
import '../services/anime/anime_source.dart';
import 'source_picker_sheet.dart';

/// 打开动漫播放页。[picked] 是用户在选源弹窗里选好的源与分集。
Future<void> openAnimePlayer(
  BuildContext context, {
  required MediaItem item,
  required int episode,
  required PickedSource picked,
}) async {
  await Navigator.push<void>(
    context,
    MaterialPageRoute<void>(
      builder: (_) => AnimePlayerPage(
        item: item,
        episode: episode,
        picked: picked,
      ),
    ),
  );
}

class AnimePlayerPage extends StatefulWidget {
  const AnimePlayerPage({
    super.key,
    required this.item,
    required this.episode,
    required this.picked,
  });

  final MediaItem item;
  final int episode;
  final PickedSource picked;

  @override
  State<AnimePlayerPage> createState() => _AnimePlayerPageState();
}

class _AnimePlayerPageState extends State<AnimePlayerPage> {
  late final Player _player;
  late final VideoController _videoController;
  WebViewVideoSourceService? _resolver;

  bool _resolving = true;
  String? _error;
  List<Road> get _roads => widget.picked.roads;
  int _roadIndex = 0;
  List<String> get _episodeUrls =>
      _roads.isEmpty ? const [] : (_roads[_roadIndex].data);
  int _episodeIndex = 0;
  String _status = '正在解析播放地址…';
  StreamSubscription<String>? _errorSub;

  // —— 补上的 Kazumi 功能状态 ——
  double _rate = 1.0;
  BoxFit _fit = BoxFit.contain;
  bool _locked = false;
  bool _showInfo = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _videoWidth = 0;
  int _videoHeight = 0;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<int?>? _widthSub;
  StreamSubscription<int?>? _heightSub;
  Timer? _sleepTimer;
  int _sleepMinutes = 0;
  StreamSubscription<String>? _noticeSub;

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  static const _sleepOptions = [0, 10, 20, 30, 45, 60];

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _errorSub = _player.stream.error.listen((event) {
      if (mounted) setState(() => _error = '播放出错：' + event.toString());
    });
    _posSub = _player.stream.position.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durSub = _player.stream.duration.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _widthSub = _player.stream.width.listen((w) {
      if (mounted) setState(() => _videoWidth = w ?? 0);
    });
    _heightSub = _player.stream.height.listen((h) {
      if (mounted) setState(() => _videoHeight = h ?? 0);
    });
    _start();
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _errorSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _resolver?.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _resolving = true;
      _error = null;
      _roadIndex = 0;
      // 分集为空时 clamp(0, -1) 会抛 ArgumentError，先挡住。
      _episodeIndex = _episodeUrls.isEmpty
          ? 0
          : (widget.episode - 1).clamp(0, _episodeUrls.length - 1).toInt();
    });
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    if (_episodeUrls.isEmpty) return;
    final url = _episodeUrls[_episodeIndex];
    setState(() {
      _resolving = true;
      _status = '正在解析第 ' + (_episodeIndex + 1).toString() + ' 集…';
      _error = null;
    });
    try {
      final plugin = widget.picked.plugin;
      _resolver ??= WebViewVideoSourceService();
      final source = await _resolver!.resolve(
        plugin.buildFullUrl(url),
        useLegacyParser: plugin.useLegacyParser,
      );
      if (!mounted) return;
      setState(() => _resolving = false);
      await _player.open(
        Media(source.url, httpHeaders: plugin.buildHttpHeaders()),
        play: true,
      );
      await _player.setRate(_rate);
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

  void _setRate(double rate) {
    setState(() => _rate = rate);
    _player.setRate(rate);
  }

  void _skipIntro() {
    // Kazumi 的跳过 OP 是固定前进 90 秒。
    final target = _player.state.position + const Duration(seconds: 90);
    _player.seek(target > _duration ? _duration : target);
  }

  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    setState(() => _sleepMinutes = minutes);
    if (minutes == 0) return;
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _player.pause();
      if (mounted) {
        setState(() => _sleepMinutes = 0);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('定时关闭：已暂停播放')),
        );
      }
    });
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Center(
              child: Text(
                '源：' + widget.picked.plugin.name,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
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
                // 不传 controls 就用 media_kit 默认控制条。
                Video(controller: _videoController, fit: _fit),
                if (_resolving)
                  Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(_status,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
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
                        const Icon(Icons.error_outline,
                            color: Colors.white, size: 32),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _start,
                          style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                if (_showInfo && !_resolving)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      color: Colors.black54,
                      child: Text(
                        '${_duration.inMinutes}:${(_duration.inSeconds % 60).toString().padLeft(2, '0')} · '
                        '${_videoWidth}x${_videoHeight} · ${_rate}x',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11),
                      ),
                    ),
                  ),
                if (_locked)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => setState(() => _locked = false),
                      child: Container(
                        color: Colors.transparent,
                        alignment: Alignment.center,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(Icons.lock, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 工具条（锁屏时隐藏）。
          if (!_locked)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  _toolButton(Icons.speed_rounded, '倍速 ${_rate}x', () {
                    final i = _rates.indexOf(_rate);
                    _setRate(_rates[(i + 1) % _rates.length]);
                  }),
                  _toolButton(Icons.aspect_ratio_rounded, '画幅', () {
                    setState(() => _fit =
                        _fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain);
                  }),
                  _toolButton(Icons.fast_forward, '跳过片头', _skipIntro),
                  _toolButton(Icons.timer,
                      _sleepMinutes == 0 ? '定时关闭' : '定时 ${_sleepMinutes}分',
                      () {
                    final i = _sleepOptions.indexOf(_sleepMinutes);
                    _setSleep(_sleepOptions[(i + 1) % _sleepOptions.length]);
                  }),
                  _toolButton(Icons.info_outline, '播放信息',
                      () => setState(() => _showInfo = !_showInfo)),
                  _toolButton(Icons.lock, '锁屏',
                      () => setState(() => _locked = true)),
                ],
              ),
            ),
          if (!_locked) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Text('选集',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
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
                      child: Text('暂无分集',
                          style: TextStyle(color: Colors.white54)),
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
                              color: i == _episodeIndex
                                  ? Colors.white
                                  : Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ActionChip(
      onPressed: onTap,
      avatar: Icon(icon, size: 16, color: Colors.white),
      label: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
    ),
  );
}
