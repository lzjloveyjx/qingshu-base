/// 青枢 · 把 wenku8 的书转存成本地书，走基座自带的「本地书阅读 + 听书」。
///
/// 关键点：章节正文写成**结构化缓存格式**（`ChapterContent.toCacheText()`），
/// 而不是纯文本。阅读器对注入 loader 返回的正文会先 `isStructuredCache` 判断：
/// 结构化内容按块渲染，`ChapterImage` 是真图；纯文本则只剩文字（插图变链接）。
///
/// 所以这里把每章 HTML 里的 `<img>` 抽成 image 块（真实 URL），文字按 `<br>`
/// 切段抽成 paragraph 块，既保住插图，也让本地书与用户自己导入的书行为一致 ——
/// 本地书点听书即系统朗读。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/media_item.dart';
import '../chapter_content_blocks.dart';
import '../chapter_text_formatter.dart';
import '../imported_book_store.dart';
import 'wenku8_source.dart';

const int _kChapterRetries = 2;

/// 单章 HTML → 结构化章节正文（文字 + 插图）。
///
/// wenku8 正文的形态是「一个大 div，里面全是文本节点 + `<br>`」，段落靠 `<br>`
/// 分隔，插图是夹在文本里的 `<img>`。所以这里用「先攒缓冲、遇 `<br>`/`<img>`/
/// 块级元素就切段」的走法，而不是把每个文本节点当一个段落 —— 后者会把同一段
/// 被 `<br>` 打散的内容拆成一堆碎行。
String buildStructuredChapter(String html, {String baseUrl = ''}) {
  final document = html_parser.parse(html);
  // 只取正文容器（wenku8 的规则里 chapterContent == //div[@id='content']）。
  // 直接扫 body 会把导航、广告、页脚一起当成正文。
  final container = document.querySelector('#content') ?? document.body;
  final blocks = <ChapterBlock>[];
  final buffer = StringBuffer();

  void flush() {
    final text = _clean(buffer.toString());
    buffer.clear();
    if (text.isNotEmpty) blocks.add(ChapterParagraph(text));
  }

  if (container != null) {
    _collect(container.nodes, blocks, buffer, flush, baseUrl);
  }
  flush();
  _dropLeadingChapterNumber(blocks);
  final content = ChapterContent(blocks: blocks, illustrationsChecked: true);
  return content.toCacheText();
}

/// `&nbsp;` 解析出来是 U+00A0，`\r` 是网页换行残留；统一清成普通空格/去掉。
String _clean(String raw) => raw
    .replaceAll('\u00a0', ' ')
    .replaceAll('\r', ' ')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .trim();

/// 正文开头常带一行纯数字的章节序号（`001`），目录里已经有标题了，去掉。
void _dropLeadingChapterNumber(List<ChapterBlock> blocks) {
  while (blocks.isNotEmpty) {
    final first = blocks.first;
    if (first is! ChapterParagraph) break;
    final text = first.text.trim();
    if (text.isEmpty) {
      blocks.removeAt(0);
      continue;
    }
    if (RegExp(r'^[0-9]{1,6}$').hasMatch(text)) {
      blocks.removeAt(0);
      continue;
    }
    break;
  }
}

void _collect(
  List<dom.Node> nodes,
  List<ChapterBlock> out,
  StringBuffer buffer,
  void Function() flush,
  String baseUrl,
) {
  for (final node in nodes) {
    if (node is dom.Text) {
      buffer.write(node.data);
      continue;
    }
    if (node is! dom.Element) continue;
    final tag = node.localName;
    if (tag == 'script' || tag == 'style') continue;
    // 正文容器顶部那条「小说目录(http://www.wenku8.com)」跳转条，不是正文。
    if (node.id == 'contentdp') continue;
    if (tag == 'br') {
      flush();
      continue;
    }
    if (tag == 'img') {
      flush();
      final url = _imageUrl(node, baseUrl);
      if (url != null) {
        out.add(ChapterImage(url: url, alt: node.attributes['alt'] ?? ''));
      }
      continue;
    }
    const blockTags = {
      'p', 'div', 'section', 'article', 'li', 'blockquote',
      'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figure', 'figcaption', 'td', 'pre',
    };
    if (blockTags.contains(tag)) {
      flush();
      _collect(node.nodes, out, buffer, flush, baseUrl);
      flush();
      continue;
    }
    _collect(node.nodes, out, buffer, flush, baseUrl);
  }
}

String? _imageUrl(dom.Element img, String baseUrl) {
  for (final key in const ['data-src', 'data-original', 'data-lazy-src', 'src']) {
    final raw = (img.attributes[key] ?? '').trim();
    if (raw.isEmpty) continue;
    if (raw.contains('loading') || raw.contains('placeholder')) continue;
    if (raw.startsWith('//')) return 'https:' + raw;
    if (raw.startsWith('http://')) return 'https://' + raw.substring(7);
    if (raw.startsWith('https://')) return raw;
    if (baseUrl.isEmpty) continue;
    final base = baseUrl.endsWith('/') ? baseUrl : baseUrl + '/';
    return Uri.parse(base).resolve(raw).toString();
  }
  return null;
}


/// 一次抓取 → 结构化 → 落盘一章，串行、带重试。返回结构化缓存文本（失败为空串）。
///
/// 注意：wenku8 站点对并发抓取很敏感（并发 3 时曾出现请求长期挂起），
/// 所以全书缓存严格串行，一章一章来。
Future<String> _fetchOneChapter(Chapter chapter) async {
  var html = '';
  for (var attempt = 0; attempt <= _kChapterRetries; attempt++) {
    html = await fetchChapterHtml(chapter);
    if (html.trim().isNotEmpty) break;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  if (html.trim().isEmpty) return '';
  return buildStructuredChapter(html, baseUrl: chapter.itemId);
}

/// 全本书的「现场抓章」索引：本地书 id → 原始待抓章节（按目录顺序）。
///
/// importParsedChapters 会把章节 id 重写成 local_xxx:chapter:i，丢掉 wenku8 的
/// 原始 URL，所以必须单独保留这份映射，翻章与此后缓存全书都靠它。
class _BookState {
  _BookState({required this.sourceUrl, required this.chapters})
    : done = List<bool>.filled(chapters.length, false);

  final String sourceUrl;
  final List<Chapter> chapters;
  final List<bool> done;

  Map<String, dynamic> toJson() => {
    'sourceUrl': sourceUrl,
    'chapters': chapters.map((c) => c.itemId).toList(),
    'done': done,
  };

  static _BookState? fromJson(Map<String, dynamic> raw) {
    final chapters = (raw['chapters'] as List?)?.cast<String>() ?? const [];
    if (chapters.isEmpty) return null;
    final doneRaw = (raw['done'] as List?) ?? const [];
    final state = _BookState(
      sourceUrl: raw['sourceUrl']?.toString() ?? '',
      chapters: [
        for (var i = 0; i < chapters.length; i++)
          Chapter(itemId: chapters[i], title: '第' + (i + 1).toString() + '章', volumeName: '', hasKnownIndex: true),
      ],
    );
    for (var i = 0; i < chapters.length && i < doneRaw.length; i++) {
      state.done[i] = doneRaw[i] == true;
    }
    return state;
  }
}

/// 书 id → 状态。首章抓取时登记，缓存任务与现场抓章共享。
final Map<String, _BookState> _states = <String, _BookState>{};

/// 持久化索引键前缀（SharedPreferences）。
const String _kIndexPrefix = 'wenku8_local_index:';

Future<void> _saveIndex(String bookId) async {
  final state = _states[bookId];
  if (state == null) return;
  final sp = await SharedPreferences.getInstance();
  await sp.setString(_kIndexPrefix + bookId, jsonEncode(state.toJson()));
}

bool _statesRestored = false;
Future<void>? _restoring;

/// 懒加载：首次用到状态时从 SharedPreferences 回填，避免改 main 启动路径。
Future<void> _ensureStates() {
  if (_statesRestored) return Future<void>.value();
  return _restoring ??= restoreStates().then((_) {
    _statesRestored = true;
  });
}

/// app 启动后回填所有已存的状态（顺序无所谓，按 key 前缀扫描）。
Future<void> restoreStates() async {
  final sp = await SharedPreferences.getInstance();
  for (final key in sp.getKeys().where((k) => k.startsWith(_kIndexPrefix))) {
    final raw = sp.getString(key);
    if (raw == null) continue;
    try {
      final state = _BookState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (state != null) _states[key.substring(_kIndexPrefix.length)] = state;
    } catch (_) {}
  }
}

/// 该书是否还有未缓存章节。
bool hasPendingChapters(String bookId) => _states[bookId]?.done.any((d) => !d) ?? false;

/// 确保状态已回填（由缓存服务在启动任务前调用）。
Future<void> ensureStates() => _ensureStates();

/// 首章就绪即返回，其余章节交给「加入书架」触发的全书缓存任务。
Future<ImportedBook> localizeToShelf(
  MediaItem item, {
  void Function(int done, int total)? onProgress,
  int initialChapters = 1,
}) async {
  final volumes = await fetchDirectory(item.id);
  final chapters = <Chapter>[for (final volume in volumes) ...volume];
  if (chapters.isEmpty) throw StateError('目录为空，无法转存');

  final take = initialChapters.clamp(1, chapters.length);
  final parsed = <ParsedBookChapter>[];
  for (var i = 0; i < take; i++) {
    final chapter = chapters[i];
    final structured = await _fetchOneChapter(chapter);
    final name = chapter.title.trim().isEmpty
        ? '第' + (i + 1).toString() + '章'
        : chapter.title.trim();
    parsed.add(ParsedBookChapter(title: name, text: structured.isEmpty ? ' ' : structured));
    onProgress?.call(i + 1, chapters.length);
  }
  // 其余章节只登记标题，正文留空占位，现场抓章 / 全书缓存任务会覆写。
  for (var i = take; i < chapters.length; i++) {
    parsed.add(
      ParsedBookChapter(
        title: chapters[i].title.trim().isEmpty ? '第' + (i + 1).toString() + '章' : chapters[i].title.trim(),
        text: ' ',
      ),
    );
  }

  final book = await ImportedBookStore.instance.importParsedChapters(
    title: item.title,
    author: item.author,
    chapters: parsed,
  );

  // 记录原始章节 URL 与已抓状态（首章已完成），持久化以便重启后继续。
  final state = _BookState(sourceUrl: item.id, chapters: chapters);
  for (var i = 0; i < take && i < state.done.length; i++) state.done[i] = true;
  _states[book.id] = state;
  await _saveIndex(book.id);

  // 这里不启动任何后台任务：打开书只读首章，翻到哪章抓哪章；
  // 全书缓存由「加入书架」显式触发（cacheWholeBook）。
  return book;
}

/// 现场抓一章（翻章时用）：本地已有正文就读，否则抓并落盘。
Future<String> localChapterText(String bookId, Chapter chapter) async {
  await _ensureStates();
  final store = ImportedBookStore.instance;
  if (await store.hasChapterText(bookId, chapter.itemId)) {
    return store.chapterText(bookId, chapter.itemId);
  }
  final state = _states[bookId];
  // 非 wenku8 本地书（用户自己导入的 TXT/EPUB）没有抓取索引，
  // 直接读本地文件；缺章就是缺章，不做任何网络抓取。
  if (state == null) return store.chapterText(bookId, chapter.itemId);
  // 阅读器传进来的是 manifest 里的本地 id（local_xxx:chapter:N），
  // 而 _states 里存的是 wenku8 原始 URL。必须按序号还原对应关系，
  // 否则会拿本地 id 当 URL 去抓，必定失败（翻到第二章报空正文）。
  final match = RegExp(r':chapter:(\d+)$').firstMatch(chapter.itemId);
  final index = match == null ? -1 : int.tryParse(match.group(1) ?? '') ?? -1;
  if (index < 0 || index >= state.chapters.length) {
    return store.chapterText(bookId, chapter.itemId);
  }
  final text = await _fetchOneChapter(state.chapters[index]);
  if (text.isEmpty) {
    final hasLocal = await store.hasChapterText(bookId, chapter.itemId);
    return hasLocal ? store.chapterText(bookId, chapter.itemId) : ' ';
  }
  await store.writeChapterText(bookId, chapter.itemId, text, overwrite: true);
  state.done[index] = true;
  await _saveIndex(bookId);
  return text;
}

/// 从 ImportedBook 的 manifest 取第 i 章的本地 id（local_xxx:chapter:i）。
Future<String?> _localIdFor(String bookId, int index) async {
  final book = await ImportedBookStore.instance.book(bookId);
  if (book == null || index < 0 || index >= book.chapters.length) return null;
  return book.chapters[index].itemId;
}

/// 全书缓存任务：串行抓完所有未缓存章节，逐章写入 manifest 对应的本地 id。
///
/// [onProgress] 报告 (已完成章数, 总章数)；[shouldStop] 用于取消。
Future<void> cacheWholeBook(
  String bookId, {
  void Function(int done, int total)? onProgress,
  bool Function()? shouldStop,
}) async {
  await _ensureStates();
  final state = _states[bookId];
  if (state == null) return;
  final total = state.chapters.length;
  var done = state.done.where((d) => d).length;
  final store = ImportedBookStore.instance;
  for (var i = 0; i < total; i++) {
    if (shouldStop?.call() ?? false) return;
    final localId = await _localIdFor(bookId, i);
    if (localId == null) continue;
    if (state.done[i] && await store.hasChapterText(bookId, localId)) continue;
    final text = await _fetchOneChapter(state.chapters[i]);
    if (shouldStop?.call() ?? false) return;
    if (text.isNotEmpty) {
      await store.writeChapterText(bookId, localId, text, overwrite: true);
      state.done[i] = true;
      done++;
      await _saveIndex(bookId);
    }
    onProgress?.call(done, total);
  }
}
