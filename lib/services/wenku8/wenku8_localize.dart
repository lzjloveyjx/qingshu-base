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

/// 一次抓取 → 结构化 → 落盘一章，带重试。返回结构化缓存文本（失败为空串）。
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

/// 正在后台补全的书：bookId → 每章 itemId → 该章的 in-flight future。
///
/// 阅读器翻到还没落盘的章节时，chapter loader 会复用这里的 future，保证
/// 「后台正在抓」与「前台要读」不会重复请求同一章。
final Map<String, Map<String, Future<String>>> _backgroundFills =
    <String, Map<String, Future<String>>>{};

/// 第一章就绪后立刻返回，其余章节在后台并发补全。
///
/// 返回 [ImportedBook] 时：目录里所有章节都已登记（章节标题齐全），但只有
/// 前若干章的正文文件已落盘；剩下的由后台任务逐章写入，manifest 不再改动。
/// 这样阅读器拿到的 chapters 列表是完整的，翻到任何章都能靠 chapter loader
/// 现场抓取 / 命中后台已写好的文件，用户不再为整本书的抓取等待。
Future<ImportedBook> localizeToShelf(
  MediaItem item, {
  void Function(int done, int total)? onProgress,
  int initialChapters = 1,
}) async {
  final volumes = await fetchDirectory(item.id);
  final chapters = <Chapter>[for (final volume in volumes) ...volume];
  if (chapters.isEmpty) throw StateError('目录为空，无法转存');

  final take = initialChapters.clamp(1, chapters.length);
  // 先抓前 N 章，保证立刻有可读正文（结构化，含插图）。
  final parsed = <ParsedBookChapter>[];
  for (var i = 0; i < take; i++) {
    final chapter = chapters[i];
    final structured = await _fetchOneChapter(chapter);
    final name = chapter.title.trim().isEmpty
        ? '第' + (i + 1).toString() + '章'
        : chapter.title.trim();
    parsed.add(
      ParsedBookChapter(title: name, text: structured.isEmpty ? ' ' : structured),
    );
    onProgress?.call(i + 1, chapters.length);
  }
  // 其余章节先登记空正文（' '），目录完整但文件极小；后台会覆写它们。
  for (var i = take; i < chapters.length; i++) {
    final chapter = chapters[i];
    parsed.add(
      ParsedBookChapter(
        title: chapter.title.trim().isEmpty ? '第' + (i + 1).toString() + '章' : chapter.title.trim(),
        text: ' ',
      ),
    );
  }

  final book = await ImportedBookStore.instance.importParsedChapters(
    title: item.title,
    author: item.author,
    chapters: parsed,
  );

  // 后台并发补全：小并发（3）避免把站点打爆，也减少总耗时。
  // 关键：整段用 unawaited 脱离调用方 —— localizeToShelf 一返回骨架书就进
  // 阅读器，剩下的章节在后台慢慢填，绝不让用户干等。
  unawaited(_fillRest(book, chapters, take));
  return book;
}

Future<void> _fillRest(
  ImportedBook book,
  List<Chapter> chapters,
  int take,
) async {
  final inFlight = <String, Future<String>>{};
  _backgroundFills[book.id] = inFlight;
  var done = take;
  final total = chapters.length;
  for (var i = take; i < total; i += 3) {
    final batch = <Future<void>>[];
    for (var j = i; j < total && j < i + 3; j++) {
      final chapter = chapters[j];
      final fut = _fetchOneChapter(chapter);
      inFlight[chapter.itemId] = fut;
      batch.add(
        fut.then((text) async {
          if (text.isEmpty) return;
          await ImportedBookStore.instance.writeChapterText(
            book.id,
            chapter.itemId,
            text,
            overwrite: true,
          );
          inFlight.remove(chapter.itemId);
          done++;
        }),
      );
    }
    await Future.wait(batch, eagerError: false);
  }
  _backgroundFills.remove(book.id);
}

/// 阅读器取章：命中后台 in-flight 就复用，否则读本地文件；本地没有就现场抓并落盘。
///
/// 这样即使后台任务还没跑到这一章，用户翻到时也只是等一章的网络时间，
/// 而不是等整本书。
Future<String> localChapterText(
  String bookId,
  Chapter chapter, {
  String baseUrl = '',
}) async {
  final store = ImportedBookStore.instance;
  if (await store.hasChapterText(bookId, chapter.itemId)) {
    return store.chapterText(bookId, chapter.itemId);
  }
  final fills = _backgroundFills[bookId];
  final inflight = fills?[chapter.itemId];
  if (inflight != null) return inflight;
  // 后台没覆盖到（已停止 / 失败），现场抓一章并落盘。
  final text = await _fetchOneChapter(chapter);
  if (text.isNotEmpty) {
    await store.writeChapterText(bookId, chapter.itemId, text, overwrite: true);
    return text;
  }
  // 实在抓不到，退回可能存在的占位文件，至少不让阅读器崩。
  return store.chapterText(bookId, chapter.itemId);
}
