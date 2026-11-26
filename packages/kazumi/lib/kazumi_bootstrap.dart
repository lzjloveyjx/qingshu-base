import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/my/my_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/danmaku_shield_repository.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/repositories/history_repository.dart';
import 'package:kazumi/repositories/novel_shelf_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/novel/novel_reader_prefs.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 青枢：Kazumi 模块的依赖装配层。
///
/// 为什么需要它：Kazumi 用 flutter_modular 的 `inject<T>()` 拿依赖，而本项目的
/// 壳（什锦铺）用 Riverpod。两套 DI 不通用，直接调 `inject` 会抛
/// "No Element" —— 一进页面就白屏/灰块。
///
/// 这里改成进程级单例 + 显式装配：主壳启动时 `ensureReady()` 一次，
/// Kazumi 侧页面从静态字段取值。装配的是轻小说与播放两边真正用到的那些：
///   • PluginsController —— 规则源（wenku8 / 番剧规则）
///   • NovelShelfRepository —— 书架/进度（需要 GStorage 的 novelShelf box）
///   • NovelReaderPrefs —— 阅读排版偏好
///   • AudioController —— 朗读（复用本项目的音频服务）
///   • HistoryController / DownloadController / MyController —— 播放页与详情页
///   • ShaderAssetService —— Anime4K 超分着色器
///
/// 没有初始化番茄后端（libfqapi_core.so）：本项目不提供在线书源，
/// 规则源走 XPath 抓取，不需要那个 Rust 内核。
class KazumiBootstrap {
  KazumiBootstrap._();

  static PluginsController? _plugins;
  static NovelShelfRepository? _shelfRepo;
  static NovelReaderPrefs? _readerPrefs;
  static AudioController? _audioController;
  static HistoryController? _history;
  static DownloadController? _download;
  static MyController? _my;
  static ShaderAssetService? _shaders;
  static DownloadRepository? _downloadRepo;
  static CollectController? _collect;

  static Future<void>? _initializing;
  static bool _ready = false;

  static bool get isReady => _ready;

  static PluginsController get plugins =>
      _plugins ?? (throw StateError('KazumiBootstrap 未初始化'));

  static NovelShelfRepository get shelfRepo =>
      _shelfRepo ?? (throw StateError('KazumiBootstrap 未初始化'));

  static NovelReaderPrefs get readerPrefs =>
      _readerPrefs ?? (throw StateError('KazumiBootstrap 未初始化'));

  static AudioController get audioController =>
      _audioController ?? (throw StateError('KazumiBootstrap 未初始化'));

  static HistoryController get history =>
      _history ?? (throw StateError('KazumiBootstrap 未初始化'));

  static DownloadController get download =>
      _download ?? (throw StateError('KazumiBootstrap 未初始化'));

  static MyController get my =>
      _my ?? (throw StateError('KazumiBootstrap 未初始化'));

  static ShaderAssetService get shaders =>
      _shaders ?? (throw StateError('KazumiBootstrap 未初始化'));

  static DownloadRepository get downloadRepository =>
      _downloadRepo ?? (throw StateError('KazumiBootstrap 未初始化'));

  static CollectController get collect =>
      _collect ?? (throw StateError('KazumiBootstrap 未初始化'));

  /// 幂等初始化。并发调用共享同一个 Future。
  static Future<void> ensureReady() {
    if (_ready) return Future<void>.value();
    return _initializing ??= _init();
  }

  static Future<void> _init() async {
    // Hive：Kazumi 的书架/进度存在自己的 box 里。本项目主壳用的是另一套
    // 存储（什锦铺的 ImportedBookStore / ShelfStore），两边互不干扰，
    // 但都需要 Hive 先 initFlutter 过。
    final dir = await getApplicationSupportDirectory();
    await Hive.initFlutter('${dir.path}/kazumi_hive');
    await GStorage.init();

    final plugins = PluginsController();
    await plugins.init();

    _plugins = plugins;
    _shelfRepo = NovelShelfRepository();
    _readerPrefs = NovelReaderPrefs();
    _audioController = AudioController();

    // 播放侧：历史 / 下载 / 我的。Kazumi 原来靠 modular 的 singleton，
    // 这里手动建一次并长期持有。
    final historyRepo = HistoryRepository();
    _downloadRepo = DownloadRepository();
    final shieldRepo = DanmakuShieldRepository();
    _history = HistoryController(historyRepo);
    _history!.init();
    _download = DownloadController(
      _downloadRepo!,
      DownloadManager(),
      plugins,
    );
    await _download!.init();
    _my = MyController(historyRepo, _downloadRepo!, shieldRepo);
    await _my!.loadShieldList();
    // 收藏（追番）：播放页/详情页的收藏按钮直接 new 出来用，
    // 过去靠 flutter_modular 的 inject<> 拿实例，主壳没有 ModularApp。
    _collect = CollectController(CollectCrudRepository())..loadCollectibles();

    // Anime4K 着色器：从 rootBundle 复制到应用私有目录，mpv 才能按绝对路径加载。
    _shaders = ShaderAssetService();
    try {
      await _shaders!.copyShadersToExternalDirectory();
    } catch (_) {
      // 复制失败只影响超分，不该挡住启动。
    }

    _ready = true;
  }
}
