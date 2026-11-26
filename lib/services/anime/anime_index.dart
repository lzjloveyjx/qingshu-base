/// 青枢 · 动漫本地索引。
///
/// 为什么需要它：镜像 api.kazumi.fyi 只暴露三个端点（app/latest、
/// popular/subjects、calendar/season），**没有搜索**；官方 api.bgm.tv 与
/// next.bgm.tv 在国内直连不通，镜像上的 /v0/search/subjects 要请求签名
/// （401 invalid request signature），拿不到。
///
/// 所以把能拿到的全量语料落盘成本地索引，搜索在本地做：
///   • 榜单 popular/subjects 翻页（实测最多约 1000 条）
///   • 逐年逐季 calendar/season（实测 2015 年也有数据，单季约 230 条）
///
/// 首次建索引要发几十个请求，之后只做增量刷新（补最近两个季度 + 榜单首页），
/// 搜索结果全部来自内存/磁盘，不依赖网络。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../../models/media_item.dart';
import 'anime_source.dart';
import '../encrypted_hive.dart';

class AnimeIndex {
  AnimeIndex._();

  static final AnimeIndex instance = AnimeIndex._();

  static const boxName = 'anime_index';
  static const _kItems = 'items';
  static const _kBuiltAt = 'built_at';
  static const _kAttemptAt = 'attempt_at';

  /// 索引格式版本。加了新字段或改了匹配规则就 +1，旧索引会被判为过期。
  static const _schemaVersion = 1;

  Box<dynamic>? _box;
  List<MediaItem> _items = const [];

  /// 搜索用的归一化文本，与 [_items] 同下标。
  List<String> _haystack = const [];

  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  ValueListenable<int> get listenable => _revision;

  bool get isReady => _box?.isOpen ?? false;
  int get itemCount => _items.length;
  bool get isEmpty => _items.isEmpty;

  /// 打开 box 并载入已有索引（不触发网络）。
  Future<void> init() async {
    if (isReady) return;
    _box = await EncryptedHive.openBox<dynamic>(Hive, boxName);
    _loadFromDisk();
  }

  void _loadFromDisk() {
    final raw = _box?.get(_kItems);
    if (raw is! String || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = <MediaItem>[];
      final hay = <String>[];
      for (final row in decoded) {
        if (row is! Map) continue;
        final item = _itemFromJson(row.cast<String, dynamic>());
        if (item == null) continue;
        items.add(item);
        hay.add(_normalize(_haystackOf(item)));
      }
      _items = items;
      _haystack = hay;
      _revision.value++;
    } catch (error) {
      debugPrint('AnimeIndex: 读取索引失败 $error');
    }
  }

  /// 索引是否足够新（默认 7 天）。
  bool get isFresh {
    final ts = _box?.get(_kAttemptAt);
    if (ts is! int) return false;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    return age >= 0 && age < const Duration(days: 7).inMilliseconds;
  }

  /// 本地搜索。空查询返回空表。
  List<MediaItem> search(String query, {int limit = 60}) {
    final q = _normalize(query);
    if (q.isEmpty) return const [];
    final hit = <MediaItem>[];
    for (var i = 0; i < _haystack.length; i++) {
      if (!_haystack[i].contains(q)) continue;
      hit.add(_items[i]);
      if (hit.length >= limit) break;
    }
    return hit;
  }

  static String _haystackOf(MediaItem item) {
    // 标题 + 原名/别名（AnimeSource 塞进 categories）。
    return [item.title, ...item.categories].join(' ').toLowerCase();
  }

  /// 归一化：小写、去掉空白与常见分隔符，让「魔法少女」能匹配
  /// 「魔法少女 まどか」。
  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[·・:：\-—_/\\]'), '');

  /// 建索引 / 增量刷新。
  ///
  /// [full] 为 true 时重建全部年份；否则只补最近两个季度 + 榜单首页。
  /// 返回写入的条目数。
  Future<int> rebuild({
    bool full = false,
    void Function(int done, int total)? onProgress,
  }) async {
    await init();
    final started = DateTime.now();
    _box?.put(_kAttemptAt, started.millisecondsSinceEpoch);

    final collected = <String, MediaItem>{};
    if (!full) {
      // 增量：先保留已有条目，再补新的。
      for (final item in _items) {
        collected[item.id] = item;
      }
    }

    final tasks = <Future<List<MediaItem>> Function()>[];

    // 榜单：最多约 1000 条。
    final popularPages = full ? 14 : 3;
    for (var i = 0; i < popularPages; i++) {
      final offset = i * 50;
      tasks.add(() => browsePopular(offset: offset, limit: 50));
    }

    // 季度表：镜像的 calendar/season 接受任意日期区间，**按年请求一次拿全年**
    // 比按季请求省 3/4 的往返（实测 2024 全年 295 条 vs 四季相加 290 条，
    // 按年还更全）。全量时回溯到 2010；增量只补今年和去年。
    final now = DateTime.now();
    final years = <int>[];
    if (full) {
      for (var year = now.year; year >= 2010; year--) {
        years.add(year);
      }
    } else {
      years.add(now.year);
      if (now.month <= 2) years.add(now.year - 1);
    }
    for (final year in years) {
      final start = DateTime(year, 1, 1);
      final end = DateTime(year, 12, 31);
      tasks.add(() => browseSeason(at: start, endAt: end).then(
            (days) => [for (final day in days) ...day],
          ));
    }

    final total = tasks.length;
    var done = 0;
    // 并发 4：镜像对突发请求不友好，太高会 429。
    for (var i = 0; i < tasks.length; i += 4) {
      final batch = tasks.skip(i).take(4).toList();
      final results = await Future.wait(batch.map((task) async {
        try {
          return await task();
        } catch (_) {
          return <MediaItem>[];
        }
      }));
      for (final list in results) {
        for (final item in list) {
          collected[item.id] = item;
        }
      }
      done += batch.length;
      onProgress?.call(done, total);
    }

    final items = collected.values.toList(growable: false);
    await _writeToDisk(items);
    _items = items;
    _haystack = [for (final item in items) _normalize(_haystackOf(item))];
    _box?.put(_kBuiltAt, DateTime.now().millisecondsSinceEpoch);
    _revision.value++;
    return items.length;
  }

  Future<void> _writeToDisk(List<MediaItem> items) async {
    final box = _box;
    if (box == null) return;
    // 只落搜索必需字段，控制体积（每条几十字节，几千条也就几百 KB）。
    final rows = [
      for (final item in items)
        {
          'id': item.id,
          't': item.title,
          'c': item.cover,
          'b': item.badge,
          'e': item.ep,
          's': item.score,
          'i': item.intro,
          'k': item.categories,
          'sid': item.seriesId,
        },
    ];
    await box.put(_kItems, jsonEncode(rows));
    await box.put('schema', _schemaVersion);
  }

  static MediaItem? _itemFromJson(Map<String, dynamic> row) {
    final id = row['id'];
    final title = row['t'];
    if (id is! String || title is! String || title.isEmpty) return null;
    final cats = row['k'];
    return MediaItem(
      id: id,
      title: title,
      cover: (row['c'] ?? '').toString(),
      author: '',
      badge: (row['b'] ?? '').toString(),
      ep: (row['e'] ?? '').toString(),
      kind: 'anime',
      score: row['s'] is num ? (row['s'] as num).toDouble() : null,
      intro: (row['i'] ?? '').toString(),
      source: kAnimeSource,
      seriesId: row['sid']?.toString(),
      categories: cats is List ? cats.map((e) => e.toString()).toList() : const [],
    );
  }
}
