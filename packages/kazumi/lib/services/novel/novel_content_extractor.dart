import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

/// 从一章的 HTML 里抽出正文。
///
/// 为什么单独写一个而不是复用 `XPathRuleStrategy`：那条链路是为「动漫播放
/// 线路」设计的，字段是 chapterRoads / chapterResult，输出是 Road（一批
/// URL）。小说需要的是**一页正文文本**，语义不同，硬塞进去会把两边都弄脏。
///
/// 但是 XPath 的语义必须和规则引擎保持一致 —— 用的是同一个
/// `xpath_selector_html_parser`，它对子节点上的 `//foo` 按「相对」解释
/// （descendant-or-self），和标准 XPath 不一样。这是 Kazumi 规则能跑通的
/// 前提，换库就会全错。
class NovelContentExtractor {
  const NovelContentExtractor();

  /// 抽正文纯文本。
  ///
  /// [contentSelector] 是规则里的 `chapterContent`（小说扩展字段）。
  /// 为空时退化成「整页 body 的可见文本」，能读但会带上导航噪声 ——
  /// 所以界面要提示用户补选择器。
  ///
  /// [dropSelectors] 是可选的噪声节点（广告、推荐位），命中就整块删掉。
  String extract(
    String rawHtml, {
    String contentSelector = '',
    List<String> dropSelectors = const [],
  }) {
    if (rawHtml.trim().isEmpty) return '';
    final document = parse(rawHtml);
    final body = document.body;
    if (body == null) return '';

    for (final selector in dropSelectors) {
      final trimmed = selector.trim();
      if (trimmed.isEmpty) continue;
      try {
        for (final match in body.queryXPath(trimmed).nodes) {
          match.node.remove();
        }
      } catch (_) {
        // 单条噪声选择器写错不该让整章读不出来
        continue;
      }
    }

    final selector = contentSelector.trim();
    if (selector.isNotEmpty) {
      try {
        final nodes = body.queryXPath(selector).nodes;
        if (nodes.isNotEmpty) {
          return _normalize(
            nodes.map((n) => _nodeText(n.node)).join('\n'),
          );
        }
      } catch (_) {
        // 落到下面的整页兜底
      }
    }
    return _normalize(body.text);
  }

  /// 把一章切成段落。中文小说站几乎都是 `<br>` 或 `<p>` 分段，
  /// [extract] 已经把块级结构折成换行，这里只做清洗与去空行。
  List<String> paragraphs(String text) {
    return text
        .split(RegExp(r'\n+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
  }

  String _nodeText(Node node) {
    if (node is Element) {
      // <br> 在 html 包里不是块级元素，text 会把上下两行黏在一起，
      // 所以先把 br 换成换行再取 text。
      final clone = node.clone(true);
      for (final br in clone.querySelectorAll('br')) {
        br.replaceWith(Text('\n'));
      }
      // 图片：lazyload 站点的真实地址在 data-src / data-original 上，src 只是
      // 一个占位 svg。把真地址提取成一行 [图片] <url>，交给阅读页渲染。
      // 不做这一步的话，插图会整个丢失 —— 用户看到的就只有文字。
      for (final img in clone.querySelectorAll('img')) {
        final url = _imageUrl(img);
        if (url.isEmpty) {
          img.remove();
        } else {
          img.replaceWith(Text('\n[图片] $url\n'));
        }
      }
      return clone.text;
    }
    return node.text ?? '';
  }

  /// 从 <img> 上取真实图片地址。
  ///
  /// 优先级：data-src > data-original > data-lazy-src > src。
  /// 前几个是常见 lazyload 属性；src 往往只是 loading 占位图，
  /// 所以放最后，并且要挡掉明显是占位符的值。
  String _imageUrl(Element img) {
    for (final attr in const [
      'data-src',
      'data-original',
      'data-lazy-src',
      'data-echo',
    ]) {
      final value = (img.attributes[attr] ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    final src = (img.attributes['src'] ?? '').trim();
    if (src.isEmpty) return '';
    // 占位符特征：明确的 loading 图，或者 svg 占位
    if (src.contains('loading') || src.contains('placeholder')) return '';
    return src;
  }

  String _normalize(String input) {
    return input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        // 全角空格与不间断空格统一成半角
        .replaceAll('\u00a0', ' ')
        .replaceAll('\u3000', ' ')
        // 行内多余空白压成一个空格
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .split('\n')
        .map((line) => line.trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
