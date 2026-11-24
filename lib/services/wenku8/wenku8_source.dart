/// 青枢 · wenku8 数据源适配层（framework loader 用）。
///
/// wenku8 规则只当数据源；展示全走番茄框架的 MediaItem/Chapter/网格/阅读器。
/// 身份约定：MediaItem.source == 'wenku8'；MediaItem.id == 详情页 URL；
///          Chapter.itemId == 章节正文 URL。
library;

import 'dart:async';
import 'dart:io';

import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:kazumi/kazumi_bootstrap.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/novel/novel_content_extractor.dart';
import 'package:kazumi/services/novel/novel_local_index.dart';

import '../../models/media_item.dart';

const String kWenku8Source = 'wenku8';

bool isWenku8Item(MediaItem item) => item.source == kWenku8Source;

Future<Plugin> _plugin() async {
  await KazumiBootstrap.ensureReady();
  final list = KazumiBootstrap.plugins.pluginList;
  for (final p in list) {
    if (p.supportsNovel && p.name.toLowerCase().contains('wenku8')) return p;
  }
  for (final p in list) {
    if (p.supportsNovel) return p;
  }
  throw StateError('wenku8 规则源未加载');
}

Future<NovelLocalIndex?> _index(Plugin p) async {
  final asset = p.novelIndexAsset.trim();
  if (asset.isEmpty) return null;
  return NovelLocalIndex.load(asset);
}

/// 索引里的封面是 http://，Android 禁止明文流量且图床只认带 UA 的请求；
/// https 端点实测可用（curl 200），这里统一升级协议。
String _coverUrl(String cover) {
  final c = cover.trim();
  if (c.startsWith('http://')) return 'https://' + c.substring(7);
  return c;
}

MediaItem _item(SearchItem s) => MediaItem(
      id: s.src, title: s.name, cover: _coverUrl(s.cover),
      author: '', badge: '', ep: '', kind: 'book', source: kWenku8Source,
    );

Future<List<MediaItem>> browseHome({int offset = 0, int limit = 120}) async {
  try {
    final p = await _plugin();
    final idx = await _index(p);
    if (idx == null) return const [];
    final all = idx.browse(p);
    if (offset >= all.length) return const [];
    return all.skip(offset).take(limit).map(_item).toList(growable: false);
  } catch (e) {
    debugPrint('wenku8 browseHome failed: $e');
    return const [];
  }
}

Future<List<MediaItem>> searchLocal(String keyword) async {
  final q = keyword.trim();
  if (q.isEmpty) return browseHome();
  try {
    final p = await _plugin();
    final idx = await _index(p);
    if (idx == null) return const [];
    return idx.search(q, p).map(_item).toList(growable: false);
  } catch (e) {
    debugPrint('wenku8 searchLocal failed: $e');
    return const [];
  }
}

/// 抓 wenku8 详情页 HTML（详情字段只有页面上有，索引里没有）。
Future<String> _fetchBookHtml(String bookUrl) async {
  try {
    final client = HttpClient();
    client.userAgent = _kBrowserUa;
    final req = await client.getUrl(Uri.parse(bookUrl));
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return '';
    // wenku8 全站 GBK。
    final bytes = await consolidateHttpClientResponseBytes(res);
    client.close();
    return gbk.decode(bytes, allowMalformed: true);
  } catch (e) {
    debugPrint('wenku8 _fetchBookHtml failed: $e');
    return '';
  }
}

const String _kBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

/// 详情页里会出现的字段标签，用作取值边界。
///
/// `document.body.text` 会把相邻 `<td>` 的文本直接拼接（没有分隔符），
/// 所以不能用「行」或 `|` 截断，只能用「下一个标签：」当右边界。
const String _kFieldBoundary =
    r'(?:文库分类|小说作者|文章状态|最后更新|全文长度|作品Tags|作品热度'
    r'|最近章节|内容简介|阅读|小说目录|收藏|支持|专栏|游戏|用户登录'
    r'|小说搜索|轻小说大赏|发表书评|轻小说文库所有内容)';

/// 从详情页纯文本里取「标签：值」，值止于下一个字段标签。
String _field(String plain, String label) {
  final m = RegExp(
    RegExp.escape(label) + r'[：:]\s*(.+?)(?=' + _kFieldBoundary + r'[：:]|$)',
  ).firstMatch(plain);
  return m?.group(1)?.trim() ?? '';
}

Future<Map<String, dynamic>> fetchDetail(String bookUrl, {String tab = '小说'}) async {
  try {
    final p = await _plugin();
    final aid = RegExp(r'/book/(\d+)\.htm').firstMatch(bookUrl)?.group(1) ?? '';
    var title = '', cover = '';
    final idx = await _index(p);
    if (idx != null) {
      for (final s in idx.browse(p)) {
        if (s.src.endsWith('/book/' + aid + '.htm')) {
          title = s.name;
          cover = _coverUrl(s.cover);
          break;
        }
      }
    }
    // 详情页补全：分类、Tags、作者、状态、字数、简介、动画化。
    var category = '', tags = <String>[], author = '', status = '';
    var wordText = '', abstract = '', animated = false;
    final html = await _fetchBookHtml(bookUrl);
    if (html.isNotEmpty) {
      final doc = html_parser.parse(html);
      // 表格里的「字段：值」都在纯文本里，先抽一段可读文本。
      final plain = doc.body?.text.replaceAll(RegExp(r'\s+'), ' ') ?? '';
      category = _field(plain, '文库分类');
      author = _field(plain, '小说作者');
      status = _field(plain, '文章状态');
      wordText = _field(plain, '全文长度');
      final tagLine = _field(plain, '作品Tags');
      if (tagLine.isNotEmpty) {
        tags = tagLine
            .split(RegExp(r'[\s,，、]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }
      animated = plain.contains('本作已动画化');
      // 简介：从「内容简介：」到下一个字段标签之间。
      final absMatch = RegExp(
        r'内容简介[：:]\s*(.+?)(?=' + _kFieldBoundary + r'[：:]|$)',
      ).firstMatch(plain);
      if (absMatch != null) {
        abstract = absMatch.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
    }
    return {
      'book_id': aid,
      'book_name': title,
      'detail_page_thumb_url': cover,
      'abstract': abstract,
      'author_info': {'name': author.isEmpty ? '' : author},
      'category': category,
      'tags': tags,
      // 框架约定：0=完结、1=连载中、4=停更，其他=-1（未知）。
      'creation_status': status.isEmpty
          ? -1
          : (status.contains('完结') ? 0 : 1),
      'word_number': _parseWordCount(wordText),
      'last_chapter_title': _field(plain, '最近章节'),
      'source': kWenku8Source,
      if (animated) 'sub_info': '本作已动画化',
    };
  } catch (e) {
    debugPrint('wenku8 fetchDetail failed: $e');
    return {'source': kWenku8Source};
  }
}

/// 「1282833字」→ 1282833。
int _parseWordCount(String text) {
  final m = RegExp(r'(\d+)').firstMatch(text.replaceAll(',', ''));
  return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
}

Future<List<List<Chapter>>> fetchDirectory(String bookUrl, {String tab = '小说'}) async {
  try {
    final p = await _plugin();
    final roads = await p.queryChapterRoads(bookUrl);
    final result = <List<Chapter>>[];
    for (final road in roads) {
      final chapters = <Chapter>[];
      for (var i = 0; i < road.data.length; i++) {
        final url = road.data[i];
        if (url.trim().isEmpty) continue;
        final title = i < road.identifier.length && road.identifier[i].trim().isNotEmpty
            ? road.identifier[i].trim()
            : '第 ' + (i + 1).toString() + ' 章';
        chapters.add(Chapter(
          itemId: p.buildFullUrl(url), title: title,
          volumeName: road.name, hasKnownIndex: true,
        ));
      }
      if (chapters.isNotEmpty) result.add(chapters);
    }
    return result;
  } catch (e) {
    debugPrint('wenku8 fetchDirectory failed: $e');
    return const [];
  }
}

/// 抓一章原始 HTML（结构化转存要自己抽插图，不能先用纯文本抽取器）。
Future<String> fetchChapterHtml(Chapter chapter) async {
  try {
    final p = await _plugin();
    return await p.fetchNovelChapter(chapter.itemId);
  } catch (e) {
    debugPrint('wenku8 fetchChapterHtml failed: ' + e.toString());
    return '';
  }
}

Future<String> fetchChapterText(Chapter chapter) async {
  try {
    final p = await _plugin();
    final raw = await p.fetchNovelChapter(chapter.itemId);
    return const NovelContentExtractor().extract(raw, contentSelector: p.chapterContent);
  } catch (e) {
    debugPrint('wenku8 fetchChapterText failed: $e');
    return '';
  }
}
