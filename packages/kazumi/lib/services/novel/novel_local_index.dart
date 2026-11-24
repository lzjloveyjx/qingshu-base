import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// 用随包内置的书名索引做本地搜索。
///
/// 适用场景：站点搜索必须登录（wenku8），但书页和正文完全免登录。
/// 把整站书名索引打进包（约 400KB / 4300 本），搜索在本地做，命中后
/// 再去站点取目录和正文 —— 能搜到全站每一本，且不需要账号。
///
/// 索引格式（压缩过，字段名只留一个字母，省 1/3 体积）：
///   [{"a": 书 id, "n": 书名, "u": 作者, "c": 封面}]
class NovelLocalIndex {
  NovelLocalIndex._(this._entries);

  final List<_IndexEntry> _entries;

  /// 从 assets 加载。失败返回 null（规则退化成在线搜索）。
  static Future<NovelLocalIndex?> load(String assetPath) async {
    if (assetPath.trim().isEmpty) return null;
    try {
      final raw = await rootBundle.loadString(assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final entries = <_IndexEntry>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final aid = item['a'];
        final name = (item['n'] as String? ?? '').trim();
        if (aid == null || name.isEmpty) continue;
        entries.add(_IndexEntry(
          aid: aid.toString(),
          name: name,
          author: (item['u'] as String? ?? '').trim(),
          cover: (item['c'] as String? ?? '').trim(),
        ));
      }
      return NovelLocalIndex._(entries);
    } catch (_) {
      return null;
    }
  }

  int get length => _entries.length;

  /// 按书名 / 作者做包含匹配。
  ///
  /// 只做子串匹配而不打分排序：中文书名短、关键词通常很具体，包含关系
  /// 已经足够准。名字里带关键词的排在作者命中的前面。
  List<SearchItem> search(String keyword, Plugin plugin, {int limit = 120}) {
    final k = keyword.trim().toLowerCase();
    if (k.isEmpty) return const <SearchItem>[];
    final byName = <SearchItem>[];
    final byAuthor = <SearchItem>[];
    for (final e in _entries) {
      if (e.name.toLowerCase().contains(k)) {
        byName.add(_toItem(e, plugin));
      } else if (e.author.isNotEmpty && e.author.toLowerCase().contains(k)) {
        byAuthor.add(_toItem(e, plugin));
      }
      if (byName.length >= limit) break;
    }
    return [...byName, ...byAuthor].take(limit).toList(growable: false);
  }

  /// 首屏书目：索引本身就是全站书目，按 aid 顺序排列。
  ///
  /// aid 越小入库越早 —— 文库的老书都是经典（文学少女、魔法禁书目录…），
  /// 排在最前面正好当「进 tab 就能看到书」的默认列表。
  ///
  /// [limit] 为 null 时返回全部（4300+ 本）。网格是懒构建的，一次给全量不会
  /// 卡；给个固定上限反而会让用户以为「就这么点书」。
  List<SearchItem> browse(Plugin plugin, {int? limit}) {
    final source = limit == null ? _entries : _entries.take(limit);
    return source.map((e) => _toItem(e, plugin)).toList(growable: false);
  }

  SearchItem _toItem(_IndexEntry e, Plugin plugin) {
    final base = plugin.baseUrl.endsWith('/')
        ? plugin.baseUrl.substring(0, plugin.baseUrl.length - 1)
        : plugin.baseUrl;
    return SearchItem(
      name: e.name,
      // 详情页 URL —— queryChapterRoads 会按 catalogTemplate 换成目录页
      src: '$base/book/${e.aid}.htm',
      cover: e.cover,
    );
  }
}

class _IndexEntry {
  const _IndexEntry({
    required this.aid,
    required this.name,
    required this.author,
    required this.cover,
  });

  final String aid;
  final String name;
  final String author;
  final String cover;
}
