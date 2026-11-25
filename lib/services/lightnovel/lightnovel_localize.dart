/// 青枢 · 轻之国度章节正文 → 结构化缓存文本（含插图）。
///
/// 复用与 wenku8 相同的目标格式：把正文容器里的 <p>/<img> 抽成块，
/// 阅读器才会按块渲染真图，而不是退化成「[图片] url」文本。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../chapter_content_blocks.dart';
import '../chapter_text_formatter.dart';

/// 轻之国度正文容器：`div.reader-text`。
const String kLightNovelContentSelector = 'div.reader-text';

String buildLightNovelChapter(String html, {String baseUrl = ''}) {
  if (html.trim().isEmpty) return '';
  final doc = html_parser.parse(html);
  final container = doc.querySelector(kLightNovelContentSelector) ??
      doc.querySelector('article') ??
      doc.body;
  final blocks = <ChapterBlock>[];
  if (container == null) return '';
  for (final node in container.nodes) {
    _collect(node, blocks, baseUrl);
  }
  final content = ChapterContent(blocks: blocks, illustrationsChecked: true);
  return content.toCacheText();
}

void _collect(dom.Node node, List<ChapterBlock> out, String baseUrl) {
  if (node is dom.Text) {
    final t = _clean(node.data);
    if (t.isNotEmpty) out.add(ChapterParagraph(t));
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName;
  if (tag == 'script' || tag == 'style' || tag == 'nav') return;
  if (tag == 'img') {
    final url = _imageUrl(node, baseUrl);
    if (url != null) {
      out.add(ChapterImage(url: url, alt: node.attributes['alt'] ?? ''));
    }
    return;
  }
  if (tag == 'p') {
    final text = _nodeText(node);
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

String _clean(String raw) => raw
    .replaceAll('\u00a0', ' ')
    .replaceAll('\r', ' ')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .trim();

String _nodeText(dom.Node node) {
  if (node is dom.Text) return _clean(node.data);
  if (node is! dom.Element) return '';
  if (node.localName == 'br') return ' ';
  final parts = <String>[];
  for (final child in node.nodes) {
    final t = _nodeText(child);
    if (t.isNotEmpty) parts.add(t);
  }
  return _clean(parts.join(''));
}

String? _imageUrl(dom.Element img, String baseUrl) {
  for (final key in const ['data-src', 'data-original', 'src']) {
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