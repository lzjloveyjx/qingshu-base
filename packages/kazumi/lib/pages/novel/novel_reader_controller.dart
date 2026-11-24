import 'package:flutter/foundation.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/novel/novel_content_extractor.dart';

/// 一章的加载状态。
enum NovelChapterStatus { idle, loading, ready, error }

/// 小说阅读器控制器。
///
/// 刻意做成极简的 ChangeNotifier 而不是 MobX store：它只服务于阅读页一处，
/// 没有跨页共享状态，用 MobX 反而要维护 .g.dart 生成文件。
///
/// 与动漫播放链路的边界：
///   • 搜索/详情/目录 复用 Kazumi 现有的 Plugin（规则引擎已经实现）
///   • 只有「取正文」是本 fork 新增的（Plugin.fetchNovelChapter）
class NovelReaderController extends ChangeNotifier {
  NovelReaderController({
    required this.plugin,
    required this.bookTitle,
    this.contentSelector = '',
    this.dropSelector = '',
  });

  final Plugin plugin;
  final String bookTitle;

  /// 规则里的 chapterContent；空串时抽取器退回整页文本。
  final String contentSelector;

  /// 规则里的 chapterDrop；空串表示不丢任何节点。
  ///
  /// 写成 XPath 的 `|` 组合（例如 `//ul[@id='a']|//div[@class='b']`），
  /// 这里拆开逐条交给抽取器 —— 抽取器按「一条选择器删一批节点」处理，
  /// 拆开能让某一条写错时不影响其它条。
  final String dropSelector;

  static const NovelContentExtractor _extractor = NovelContentExtractor();

  NovelChapterStatus status = NovelChapterStatus.idle;
  String error = '';
  List<String> paragraphs = const [];

  String _chapterUrl = '';
  String _chapterTitle = '';

  String get chapterTitle => _chapterTitle;
  bool get hasContent => paragraphs.isNotEmpty;

  /// 打开一章。重复调用同一 URL 直接返回（返回上一章再进来不会重刷）。
  Future<void> openChapter(String url, {String title = ''}) async {
    if (url.isEmpty) return;
    if (url == _chapterUrl && status == NovelChapterStatus.ready) return;
    _chapterUrl = url;
    _chapterTitle = title;
    status = NovelChapterStatus.loading;
    error = '';
    paragraphs = const [];
    notifyListeners();
    try {
      final html = await plugin.fetchNovelChapter(url);
      final text = _extractor.extract(
        html,
        contentSelector: contentSelector,
        dropSelectors: _dropSelectors,
      );
      final parts = _extractor.paragraphs(text);
      if (parts.isEmpty) {
        status = NovelChapterStatus.error;
        error = '正文为空 —— 这条规则可能缺少 chapterContent 选择器，'
            '或者站点改版了。';
      } else {
        paragraphs = parts;
        status = NovelChapterStatus.ready;
      }
    } catch (e) {
      status = NovelChapterStatus.error;
      error = e.toString();
    }
    notifyListeners();
  }

  /// 把 `a|b|c` 拆成独立的 XPath 列表。
  List<String> get _dropSelectors {
    final raw = dropSelector.trim();
    if (raw.isEmpty) return const <String>[];
    return raw
        .split('|')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList(growable: false);
  }

  void setChapterTitle(String title) {
    _chapterTitle = title;
    notifyListeners();
  }
}
