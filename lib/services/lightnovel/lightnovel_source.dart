/// 青枢 · 轻之国度（lightnovel.fun）数据源适配层。
///
/// 与 wenku8_source 同构：只负责提供数据（浏览/搜索/详情/目录/正文），
/// 展示全走番茄框架自己的皮。
///
/// 身份约定：MediaItem.source == 'lightnovel'；
///          MediaItem.id == https://www.lightnovel.fun/book/{id}；
///          Chapter.itemId == https://www.lightnovel.fun/reader/{bookId}/{chapterId}。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../models/media_item.dart';
import 'lightnovel_localize.dart';

const String kLightNovelSource = 'lightnovel';
const String kLightNovelBase = 'https://www.lightnovel.fun';
const String _kUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

bool isLightNovelItem(MediaItem item) => item.source == kLightNovelSource;

/// 抓一页 HTML（UTF-8，Nuxt SSR）。
Future<String> _get(String url) async {
  final client = HttpClient();
  try {
    client.userAgent = _kUa;
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('referer', kLightNovelBase + '/');
    final res = await req.close().timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) return '';
    final bytes = await consolidateHttpClientResponseBytes(res);
    return utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    debugPrint('lightnovel _get failed: $e');
    return '';
  } finally {
    client.close();
  }
}

String _abs(String u) {
  final s = u.trim();
  if (s.isEmpty) return '';
  if (s.startsWith('http')) return s;
  if (s.startsWith('//')) return 'https:' + s;
  return s.startsWith('/') ? kLightNovelBase + s : kLightNovelBase + '/' + s;
}

/// 封面：站内默认图跳过；相对路径补全。
String _cover(String u) {
  final s = u.trim();
  if (s.isEmpty) return '';
  if (s.contains('/sample-assets/')) return '';
  return _abs(s);
}

int _bookId(String url) {
  final m = RegExp(r'/book/(\d+)').firstMatch(url);
  return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
}

MediaItem _item({required int id, required String title, String cover = '', String author = ''}) =>
    MediaItem(
      id: kLightNovelBase + '/book/' + id.toString(),
      title: title,
      cover: cover,
      author: author,
      badge: '',
      ep: '',
      kind: 'book',
      source: kLightNovelSource,
    );

/// 从书卡片 `<a href=/book/N>` 里抽标题/作者/封面。
MediaItem? _fromCard(dom.Element a) {
  final href = a.attributes['href'] ?? '';
  final id = _bookId(href);
  if (id == 0) return null;
  final img = a.querySelector('img');
  final cover = _cover(img?.attributes['src'] ?? '');
  // 标题：优先 title 属性 / 第一个 strong；否则用文本首行。
  var title = (a.attributes['title'] ?? '').trim();
  if (title.isEmpty) {
    final strong = a.querySelector('strong');
    if (strong != null) title = strong.text.trim();
  }
  if (title.isEmpty) {
    final raw = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 卡片文本形如「书名作者：XXX…」，截到「作者：」之前。
    final cut = raw.indexOf('作者');
    title = cut > 0 ? raw.substring(0, cut).trim() : raw;
  }
  if (title.isEmpty) title = '未命名';
  var author = '';
  final am = RegExp(r'作者[：:]\s*([^\s·]+)').firstMatch(a.text);
  if (am != null) author = am.group(1)!.trim();
  return _item(id: id, title: title, cover: cover, author: author);
}

/// 从一页 HTML 里收集所有书卡片（去重保序）。
List<MediaItem> _cardsFrom(String html, {String? mustContainClass}) {
  if (html.isEmpty) return const [];
  final doc = html_parser.parse(html);
  final out = <MediaItem>[];
  final seen = <int>{};
  for (final a in doc.querySelectorAll('a[href*="/book/"]')) {
    if (mustContainClass != null &&
        !(a.className.contains(mustContainClass))) {
      continue;
    }
    final item = _fromCard(a);
    if (item == null) continue;
    final id = _bookId(item.id);
    if (!seen.add(id)) continue;
    out.add(item);
  }
  return out;
}

/// 首页书流：优先「新更」区（/book/ 卡片最多），失败退回根域。
Future<List<MediaItem>> browseHome({int offset = 0, int limit = 60}) async {
  try {
    // 站点首页一次能带出 30 张左右卡片；翻页靠排行榜补足。
    final html = await _get(kLightNovelBase + '/');
    var items = _cardsFrom(html);
    if (items.length < limit) {
      final rank = await _get(kLightNovelBase + '/rank');
      final more = _cardsFrom(rank);
      final seen = items.map((e) => e.id).toSet();
      items = [...items, ...more.where((e) => !seen.contains(e.id))];
    }
    if (offset >= items.length) return const [];
    return items.skip(offset).take(limit).toList(growable: false);
  } catch (e) {
    debugPrint('lightnovel browseHome failed: $e');
    return const [];
  }
}

/// 站内搜索（免登录，返回 /book/N 卡片）。
Future<List<MediaItem>> search(String keyword) async {
  final q = keyword.trim();
  if (q.isEmpty) return browseHome();
  try {
    final html = await _get(
      kLightNovelBase + '/search?keyword=' + Uri.encodeQueryComponent(q),
    );
    return _cardsFrom(html);
  } catch (e) {
    debugPrint('lightnovel search failed: $e');
    return const [];
  }
}
/// 详情页：书名/作者/插画/状态/文库/简介/标签。
Future<Map<String, dynamic>> fetchDetail(String bookUrl, {String tab = '小说'}) async {
  final id = _bookId(bookUrl);
  try {
    final html = await _get(kLightNovelBase + '/book/' + id.toString());
    if (html.isEmpty) return {'source': kLightNovelSource};
    final doc = html_parser.parse(html);
    final h1 = doc.querySelector('h1');
    var title = h1?.text.trim() ?? '';
    if (title.isEmpty) {
      final t = doc.querySelector('title');
      title = (t?.text ?? '').split('-').first.trim();
    }
    final plain = (doc.body?.text ?? '').replaceAll(RegExp(r'\s+'), ' ');
    // 作者：木緒なち；插画：xxx；状态：已完结；文库 xxx
    String grab(String label) {
      final m = RegExp(label + r'[：:]\s*([^\s：:]+)').firstMatch(plain);
      return m?.group(1)?.trim() ?? '';
    }
    final author = grab('作者');
    final illustrator = grab('插画');
    final status = grab('状态');
    final coverEl = doc.querySelector('img[src*="/upload-files/images/"]');
    final cover = _cover(coverEl?.attributes['src'] ?? '');
    // 简介：书页里正文前的那段概述，取「内容简介」后的长文本；没有就取第一段长文本。
    var abstract = '';
    final absIdx = plain.indexOf('内容简介');
    if (absIdx >= 0) {
      abstract = plain.substring(absIdx + 4).trim();
      final cutAt = abstract.indexOf('作者简介');
      if (cutAt > 20) abstract = abstract.substring(0, cutAt).trim();
      if (abstract.length > 800) abstract = abstract.substring(0, 800);
    }
    // 标签：卡片上的「后宫 · 异世界」这类。
    final tags = <String>[];
    for (final m in RegExp(r'(?:^|[·\s])([\u4e00-\u9fa5]{2,6})\s*·').allMatches(plain).take(6)) {
      final t = m.group(1)!.trim();
      if (t.isNotEmpty && !tags.contains(t)) tags.add(t);
    }
    return {
      'book_id': id.toString(),
      'book_name': title,
      'detail_page_thumb_url': cover,
      'abstract': abstract,
      'author_info': {'name': author},
      'category': '轻之国度',
      'tags': tags,
      'creation_status': status.contains('完结') ? 0 : (status.isEmpty ? -1 : 1),
      'source': kLightNovelSource,
      if (illustrator.isNotEmpty) 'sub_info': '插画：' + illustrator,
    };
  } catch (e) {
    debugPrint('lightnovel fetchDetail failed: $e');
    return {'source': kLightNovelSource};
  }
}

/// 目录：书页只有当前卷，沿「下一章」链把全书走完（上限保护）。
Future<List<List<Chapter>>> fetchDirectory(String bookUrl, {String tab = '小说'}) async {
  final id = _bookId(bookUrl);
  if (id == 0) return const [];
  try {
    final firstHtml = await _get(kLightNovelBase + '/book/' + id.toString());
    if (firstHtml.isEmpty) return const [];
    final doc = html_parser.parse(firstHtml);
    // 首章：书页里第一个 /reader/{id}/ 链接。
    String? cur;
    for (final a in doc.querySelectorAll('a[href*="/reader/"]')) {
      final href = a.attributes['href'] ?? '';
      if (href.contains('/reader/' + id.toString() + '/')) {
        cur = href;
        break;
      }
    }
    if (cur == null) return const [];

    final chapters = <Chapter>[];
    final seen = <String>{};
    var guard = 0;
    while (cur != null && guard < 2000) {
      guard++;
      final url = _abs(cur);
      if (!seen.add(url)) break;
      final html = await _get(url);
      if (html.isEmpty) break;
      final d = html_parser.parse(html);
      final h1 = d.querySelector('h1');
      var title = h1?.text.trim() ?? '';
      if (title.isEmpty) {
        final t = d.querySelector('title');
        title = (t?.text ?? '').split('-').first.trim();
      }
      if (title.isNotEmpty) {
        chapters.add(Chapter(
          itemId: url,
          title: title,
          volumeName: '',
          hasKnownIndex: true,
        ));
      }
      // 下一章
      String? nxt;
      for (final a in d.querySelectorAll('a')) {
        final cls = a.className;
        if (cls.contains('is-next')) {
          nxt = a.attributes['href'];
          break;
        }
      }
      cur = nxt;
    }
    if (chapters.isEmpty) return const [];
    return [chapters];
  } catch (e) {
    debugPrint('lightnovel fetchDirectory failed: $e');
    return const [];
  }
}

/// 正文 HTML（结构化抽取要用原始 HTML）。
Future<String> fetchChapterHtml(Chapter chapter) async {
  try {
    return await _get(chapter.itemId);
  } catch (e) {
    debugPrint('lightnovel fetchChapterHtml failed: $e');
    return '';
  }
}

/// 章节正文（结构化缓存文本，含插图块）。
Future<String> fetchChapterText(Chapter chapter) async {
  final html = await fetchChapterHtml(chapter);
  if (html.isEmpty) return '';
  return buildLightNovelChapter(html, baseUrl: chapter.itemId);
}