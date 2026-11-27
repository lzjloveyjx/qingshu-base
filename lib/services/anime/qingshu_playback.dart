/// 青枢 · 动漫播放装配层（把青枢的选源结果接进 Kazumi 原版播放页）。
///
/// 为什么不自己写播放页：Kazumi 的播放器是一整套（浮层控件、手势、弹幕、
/// 超分、截图、进度记忆、PiP……），自己重写只会永远追不上。这里只做三件事：
///   1. 把主壳的 Riverpod 依赖建成 Kazumi 需要的 controller 实例；
///   2. 把 PickedSource 翻译成 OnlineVideoPlaybackArgs；
///   3. 把 MediaItem 翻译成 BangumiItem。
///
/// 这些 controller 都是普通 Dart 对象（mobx Store），构造函数不碰 BuildContext，
/// 所以可以在 Riverpod 壳里安全 new 出来。真正需要 inject 的只有
/// PlayerItem 里的 HistoryController / MyController —— 那两处已改成静态注入。
library;

import 'package:material_ui/material_ui.dart';
import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_page.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';

import '../../models/media_item.dart';
import '../../pages/source_picker_sheet.dart' show PickedSource;
import 'anime_source.dart';

/// 进程级装配：这些 controller 的生命周期跟着应用走，不跟着某一次播放。
///
/// Kazumi 原版用 flutter_modular 的 singleton 达到同样效果；主壳没有 Modular，
/// 就退化成静态字段。
class QingshuPlayback {
  QingshuPlayback._();

  static HistoryRepository? _historyRepository;
  static DownloadRepository? _downloadRepository;
  static DanmakuShieldRepository? _shieldRepository;

  static HistoryController? _history;
  static DownloadController? _download;
  static MyController? _my;
  static ShaderAssetService? _shaders;
  static AudioController? _audio;

  static Future<void> ensureReady() async {
    if (_shaders != null) return;
    _historyRepository = HistoryRepository();
    _downloadRepository = DownloadRepository();
    _shieldRepository = DanmakuShieldRepository();

    _history = HistoryController(_historyRepository!)..init();
    _download = DownloadController(
      _downloadRepository!,
      DownloadManager(),
      KazumiBootstrap.plugins,
    );
    await _download!.init();
    _my = MyController(
      _historyRepository!,
      _downloadRepository!,
      _shieldRepository!,
    );
    await _my!.loadShieldList();
    // Anime4K 着色器：从 rootBundle 复制到应用私有目录，mpv 才能按绝对路径加载。
    _shaders = ShaderAssetService();
    await _shaders!.copyShadersToExternalDirectory();
    _audio = AudioController();
  }

  static ShaderAssetService get shaders =>
      _shaders ?? (throw StateError('QingshuPlayback 未初始化'));
  static HistoryController get history =>
      _history ?? (throw StateError('QingshuPlayback 未初始化'));
  static MyController get my =>
      _my ?? (throw StateError('QingshuPlayback 未初始化'));
  static DownloadController get download =>
      _download ?? (throw StateError('QingshuPlayback 未初始化'));
  static DownloadRepository get downloadRepository =>
      _downloadRepository ?? (throw StateError('QingshuPlayback 未初始化'));

  /// 打开 Kazumi 原版播放页。
  ///
  /// [episode] 是青枢这边的 1 基集数，[picked] 里带着源、搜索结果和全部线路。
  static Future<void> open(
    BuildContext context, {
    required MediaItem item,
    required int episode,
    required PickedSource picked,
  }) async {
    await KazumiBootstrap.ensureReady();
    await ensureReady();

    final args = OnlineVideoPlaybackArgs(
      bangumiItem: _bangumiItemOf(item),
      plugin: picked.plugin,
      title: item.title + ' · 第 ' + episode.toString() + ' 集',
      src: picked.item.src,
      roads: picked.roads,
    );

    final playerController = PlayerController(shaders, _download!, _audio!);
    final videoPageController = VideoPageController(
      history,
      _downloadRepository!,
      DownloadManager(),
    );

    // VideoPage 默认从第 1 集起播（或历史进度）。用户在青枢里点的是第 N 集，
    // 所以在 push 之前把选中集数拨过去 —— applyPlaybackArgs 只填 roadList，
    // 不会覆盖 selectedEpisode。
    videoPageController.resetEpisodeState(episode: episode);

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoPage(
          args: args,
          playerController: playerController,
          videoPageController: videoPageController,
          historyController: history,
          downloadController: _download!,
        ),
      ),
    );
    // 路由 pop 之后播放器不再被引用，显式收尾（Kazumi 原来靠 modular 的
    // Disposable 生命周期，这里手动做同样的事）。
    playerController.dispose();
  }

  /// 青枢的 MediaItem -> Kazumi 的 BangumiItem。
  ///
  /// BangumiItem 是 Hive 持久化模型（@HiveType），这里用内存实例即可：
  /// 播放/历史只需要 id、名字、封面这几个字段，不需要写回 box。
  static BangumiItem _bangumiItemOf(MediaItem item) => BangumiItem(
        id: animeIdOf(item.id),
        type: 2,
        name: item.title,
        nameCn: item.title,
        summary: item.intro,
        airDate: item.badge,
        airWeekday: 0,
        rank: 0,
        images: item.cover.isEmpty ? const {} : {'large': item.cover},
        tags: const [],
        alias: const [],
        ratingScore: item.score ?? 0,
        votes: 0,
        votesCount: const [],
        info: '',
      );
}
