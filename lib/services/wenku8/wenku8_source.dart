/// 青枢 · wenku8 数据源适配层（framework loader 用）。
///
/// wenku8 规则只当数据源；展示全走番茄框架的 MediaItem/Chapter/网格/阅读器。
/// 身份约定：MediaItem.source == 'wenku8'；MediaItem.id == 详情页 URL；
///          Chapter.itemId == 章节正文 URL。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

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

MediaItem _item(SearchItem s) => MediaItem(
      id: s.src, title: s.name, cover: s.cover,
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
          cover = s.cover;
          break;
        }
      }
    }
    return {
      'book_id': aid,
      'book_name': title,
      'detail_page_thumb_url': cover,
      'abstract': '',
      'source': kWenku8Source,
    };
  } catch (e) {
    debugPrint('wenku8 fetchDetail failed: $e');
    return {'source': kWenku8Source};
  }
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
