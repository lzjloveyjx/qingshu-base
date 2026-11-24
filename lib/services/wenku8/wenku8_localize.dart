/// 青枢 · 把 wenku8 的书转存成本地书，走基座自带的「本地书阅读 + 听书」。
///
/// 关键点：章节正文写成**结构化缓存格式**（`ChapterContent.toCacheText()`），
/// 而不是纯文本。阅读器对注入 loader 返回的正文会先 `isStructuredCache` 判断：
/// 结构化内容按块渲染，`ChapterImage` 是真图；纯文本则只剩文字（插图变链接）。
///
/// 所以这里把每章 HTML 里的 `<img>` 抽成 image 块（真实 URL），文字抽成
/// paragraph 块，既保住插图，也让本地书与用户自己导入的书行为一致 ——
/// 本地书点听书即系统朗读。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/media_item.dart';
import '../chapter_content_blocks.dart';
import '../chapter_text_formatter.dart';
import '../imported_book_store.dart';
import 'wenku8_source.dart';

const int _kChapterRetries = 2;

/// 单章 HTML → 结构化章节正文（文字 + 插图）。
String buildStructuredChapter(String html, {String baseUrl = ''}) {
  final document = html_parser.parse(html);
  final body = document.body;
  final blocks = <ChapterBlock>[];
  if (body != null) {
    for (final node in body.nodes) {
      _collect(node, blocks, baseUrl);
    }
  }
  final content = ChapterContent(
    blocks: blocks,
    illustrationsChecked: true,
  );
  return content.toCacheText();
}

void _collect(dom.Node node, List<ChapterBlock> out, String baseUrl) {
  if (node is dom.Text) {
    final text = node.data.trim();
    if (text.isNotEmpty) out.add(ChapterParagraph(text));
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName;
  if (tag == 'script' || tag == 'style') return;
  if (tag == 'img') {
    final url = _imageUrl(node, baseUrl);
    if (url != null) {
      out.add(ChapterImage(url: url, alt: node.attributes['alt'] ?? ''));
    }
    return;
  }
  // 段落级元素：整块取出纯文本（保留 br 换行），再补上其中夹带的图片。
  const blocks = {
    'p', 'div', 'section', 'article', 'li', 'blockquote',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'figure', 'figcaption', 'td', 'pre',
  };
  if (blocks.contains(tag)) {
    final text = _nodeText(node).trim();
    if (text.isNotEmpty) out.add(ChapterParagraph(text));
    for (final img in node.querySelectorAll('img')) {
      final url = _imageUrl(img, baseUrl);
      if (url != null) {
        out.add(ChapterImage(url: url, alt: img.attributes['alt'] ?? ''));
      }
    }
    return;
  }
  for (final child in node.nodes) {
    _collect(child, out, baseUrl);
  }
}

String _nodeText(dom.Node node) {
  if (node is dom.Text) return node.data;
  if (node is! dom.Element) return '';
  if (node.localName == 'br') return '\n';
  return node.nodes.map(_nodeText).join();
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
