import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/novel_shelf_repository.dart';
import 'package:kazumi/services/novel/novel_reader_prefs.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 青枢：Kazumi 模块的依赖装配层。
///
/// 为什么需要它：Kazumi 用 flutter_modular 的 `inject<T>()` 拿依赖，而本项目的
/// 壳（什锦铺）用 Riverpod。两套 DI 不通用，直接调 `inject` 会抛
/// "No Element" —— 轻小说页一进去就白屏。
///
/// 这里改成进程级单例 + 显式装配：主壳启动时 `ensureReady()` 一次，
/// Kazumi 侧页面从静态字段取值。只装配轻小说真正用到的那几个：
///   • PluginsController —— 规则源（wenku8）
///   • NovelShelfRepository —— 书架/进度（需要 GStorage 的 novelShelf box）
///   • NovelReaderPrefs —— 阅读排版偏好
///   • AudioController —— 朗读（复用本项目的音频服务）
///
/// 没有初始化番茄后端（libfqapi_core.so）：本项目不提供在线书源，
/// 规则源走 wenku8 的 XPath 抓取，不需要那个 Rust 内核。
class KazumiBootstrap {
  KazumiBootstrap._();

  static PluginsController? _plugins;
  static NovelShelfRepository? _shelfRepo;
  static NovelReaderPrefs? _readerPrefs;
  static AudioController? _audioController;

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
    _ready = true;
  }
}
