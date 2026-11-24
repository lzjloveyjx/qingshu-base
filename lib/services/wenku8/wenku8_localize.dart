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

/// 转存整本书到本地书架。
Future<ImportedBook> localizeToShelf(
  MediaItem item, {
  void Function(int done, int total)? onProgress,
}) async {
  final volumes = await fetchDirectory(item.id);
  final chapters = <Chapter>[for (final volume in volumes) ...volume];
  if (chapters.isEmpty) throw StateError('目录为空，无法转存');

  // 每章单独落盘：章节正文是结构化缓存格式，不能走 TXT 再解析那条路
  // （那样会把插图块和分块结构打散）。
  final parsed = <ParsedBookChapter>[];
  var done = 0;
  for (final chapter in chapters) {
    var html = '';
    for (var attempt = 0; attempt <= _kChapterRetries; attempt++) {
      html = await fetchChapterHtml(chapter);
      if (html.trim().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    done++;
    onProgress?.call(done, chapters.length);
    final name = chapter.title.trim().isEmpty
        ? '第' + done.toString() + '章'
        : chapter.title.trim();
    final structured = buildStructuredChapter(html, baseUrl: chapter.itemId);
    parsed.add(ParsedBookChapter(title: name, text: structured));
  }
  return ImportedBookStore.instance.importParsedChapters(
    title: item.title,
    author: item.author,
    chapters: parsed,
  );
}
