/// 青枢 · 动漫（Bangumi）数据源适配层。
///
/// Bangumi 官方 API（api.bgm.tv / next.bgm.tv）在国内直连不通（实测 20s 超时），
/// 所以统一走 Kazumi 官方镜像 `api.kazumi.fyi`，与 Kazumi 默认策略一致。
///
/// 身份约定：MediaItem.source == 'anime'；MediaItem.id == 'anime:{subjectId}'；
///          kind == 'anime'。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/media_item.dart';

const String kAnimeSource = 'anime';
const String _kMirror = 'https://api.kazumi.fyi';
const String _kUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

bool isAnimeItem(MediaItem item) => item.source == kAnimeSource;

/// 从 MediaItem.id 取 Bangumi subject id。
int animeIdOf(String itemId) {
  final m = RegExp(r'^anime:(\d+)$').firstMatch(itemId);
  return m == null ? 0 : (int.tryParse(m.group(1)!) ?? 0);
}

Future<dynamic> _getJson(String url) async {
  final client = HttpClient();
  try {
    client.userAgent = _kUa;
    client.connectionTimeout = const Duration(seconds: 15);
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('accept', 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    final bytes = await consolidateHttpClientResponseBytes(res);
    return jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } catch (e) {
    debugPrint('anime _getJson failed: ' + url + ' :: ' + e.toString());
    return null;
  } finally {
    client.close();
  }
}

/// 封面：bgm 图床在国内直连不通。
///
/// Kazumi 的做法是套 wsrv.nl 图片代理（见 bangumi_image_url_rewriter.dart），
/// 这里照搬同一策略，避免自己发明一个不存在的镜像路径。
String _cover(Map? images) {
  if (images == null) return '';
  final raw = (images['large'] ?? images['common'] ?? images['grid'] ?? '')
      .toString()
      .trim();
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw);
  if (uri == null) return raw;
  final isBangumiImage = uri.host == 'lain.bgm.tv' ||
      (uri.host == 'api.bgm.tv' &&
          uri.pathSegments.length == 4 &&
          uri.pathSegments[0] == 'v0' &&
          uri.pathSegments[3] == 'image');
  if (!isBangumiImage) return raw;
  final sourceUrl =
      uri.host + uri.path + (uri.hasQuery ? '?' + uri.query : '');
  return Uri.https('wsrv.nl', '/', {
    'url': sourceUrl,
    if (uri.path.toLowerCase().endsWith('.gif')) 'n': '-1',
  }).toString();
}

/// 一条 subject 里可用于搜索的文本：中文名、原名、标签。
///
/// Bangumi 的 `name` 是原名（多为日文），`nameCN` / `name_cn` 是中文名。
/// 只按中文名匹配会漏掉大量条目 —— 搜「魔法少女」应当也能命中原名是
/// 「魔法少女まどか☆マギカ」的条目。
///
/// 注意：镜像的 popular/subjects 与 calendar/season 都不返回 `infobox`
/// （那是 /v0/subjects/{id} 的字段），所以这里不处理别名栏；能用的就是
/// name / nameCN / name_cn / tags。
List<String> _searchKeywords(Map subject) {
  final out = <String>{};
  void add(Object? value) {
    final text = (value ?? '').toString().trim();
    if (text.isNotEmpty) out.add(text.toLowerCase());
  }

  add(subject['name']);
  add(subject['name_cn']);
  add(subject['nameCN']);
  add(subject['nameCn']);
  // 标签也参与搜索：搜「百合」「机战」时能按题材捞到，比只匹配标题实用。
  final tags = subject['tags'] ?? subject['metaTags'];
  if (tags is List) {
    for (final tag in tags) {
      if (tag is String) add(tag);
      if (tag is Map) add(tag['name']);
    }
  }
  return out.toList(growable: false);
}

/// 一条 Bangumi subject → MediaItem。
MediaItem? _toItem(Map subject) {
  final id = subject['id'];
  if (id is! int) return null;
  // 镜像的字段名是 nameCN（不是 nameCn），新老两种都认。
  final name = (subject['nameCN'] ?? subject['nameCn'] ?? subject['name_cn'] ??
          subject['name'] ?? '')
      .toString()
      .trim();
  final original = (subject['name'] ?? '').toString().trim();
  final title = name.isNotEmpty ? name : original;
  if (title.isEmpty) return null;
  final rating = subject['rating'];
  double? score;
  if (rating is Map) {
    final s = rating['score'];
    if (s is num && s > 0) score = s.toDouble();
  }
  final date = (subject['date'] ?? '').toString().trim();
  return MediaItem(
    id: 'anime:' + id.toString(),
    // 书架内容键用 [source/]kind:<seriesId ?? id>；id 带冒号不满足 contentIdPattern，
    // 所以把纯数字 subject id 放进 seriesId，让动漫能安全地入架与分区。
    seriesId: id.toString(),
    title: title,
    cover: _cover(subject['images'] is Map ? subject['images'] as Map : null),
    author: '',
    badge: date.length >= 4 ? date.substring(0, 4) : '',
    ep: (subject['eps'] ?? subject['total_episodes'] ?? '').toString(),
    kind: 'anime',
    score: score,
    intro: (subject['summary'] ?? '').toString().trim(),
    source: kAnimeSource,
    // 搜索要用到原名与别名，但 MediaItem 没有专门的字段。categories 在动漫
    // 条目的 UI 上不渲染（只有番茄榜单卡用），借它带一份「可搜索文本」。
    // 这样不用改模型，也不影响任何现有展示。
    categories: _searchKeywords(subject),
  );
}

/// 榜单（镜像 /kazumi/v1/popular/subjects）。
Future<List<MediaItem>> browsePopular({int offset = 0, int limit = 24}) async {
  final data = await _getJson(
    _kMirror + '/kazumi/v1/popular/subjects?limit=' + limit.toString() +
    '&offset=' + offset.toString(),
  );
  if (data is! Map) return const [];
  final list = data['data'];
  if (list is! List) return const [];
  final out = <MediaItem>[];
  for (final row in list) {
    if (row is! Map) continue;
    final subject = row['subject'] is Map ? row['subject'] as Map : row;
    final item = _toItem(subject);
    if (item != null) out.add(item);
  }
  return out;
}

/// 季度时间表（镜像 /kazumi/v1/calendar/season），按星期一~日返回 7 组。
///
/// [at] 指定起点；[endAt] 可显式指定终点，传整年区间就能一次拿全年
/// （实测 2024 全年 295 条，比按四季请求相加的 290 条更全，且省 3/4 往返）。
/// 不传 [endAt] 时按季度收尾，与 Kazumi 的原始语义一致。
Future<List<List<MediaItem>>> browseSeason({DateTime? at, DateTime? endAt}) async {
  final now = at ?? DateTime.now();
  // 不传 endAt 时按季度对齐（1-3 / 4-6 / 7-9 / 10-12），与 Kazumi 语义一致；
  // 传了 endAt 就尊重调用方给的原始起点，否则「整年」会被对齐成 Q1。
  final seasonStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
  final start = endAt != null ? now : DateTime(now.year, seasonStartMonth, 1);
  final end = endAt ?? DateTime(now.year, seasonStartMonth + 3, 0);
  String fmt(DateTime d) =>
      d.year.toString().padLeft(4, '0') + '-' +
      d.month.toString().padLeft(2, '0') + '-' +
      d.day.toString().padLeft(2, '0');
  final data = await _getJson(
    _kMirror + '/kazumi/v1/calendar/season?start=' + fmt(start) + '&end=' + fmt(end),
  );
  if (data is! Map) return const [];
  final out = <List<MediaItem>>[];
  for (var day = 1; day <= 7; day++) {
    final rows = data[day.toString()];
    final items = <MediaItem>[];
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final subject = row['subject'] is Map ? row['subject'] as Map : row;
        final item = _toItem(subject);
        if (item != null) items.add(item);
      }
    }
    out.add(items);
  }
  return out;
}

/// 一集番剧（Bangumi episode）。
class AnimeEpisode {
  const AnimeEpisode({
    required this.id,
    required this.sort,
    required this.name,
    this.nameCn = '',
    this.airdate = '',
    this.ep = 0,
  });

  final int id;

  /// 站内排序号：正片是 1..N，SP/OP 之类是小数。
  final double sort;
  final String name;
  final String nameCn;
  final String airdate;
  final int ep;

  String get display => nameCn.isNotEmpty
      ? nameCn
      : (name.isNotEmpty ? name : '第 ' + sort.toString() + ' 话');
}

/// 拉整部番的剧集表。
///
/// 官方 api.bgm.tv 在国内直连不通，但**镜像直接代理了同一个 v0 路径**
/// （实测 api.kazumi.fyi/v0/episodes?subject_id=... 返回 200），所以这里不需要
/// Kazumi 那套 BangumiAcceleration 加速层，直接拼镜像域名即可。
///
/// [type] 0=正片，1=SP，2=OP，3=ED。
Future<List<AnimeEpisode>> fetchEpisodes(int subjectId, {int type = 0}) async {
  if (subjectId == 0) return const [];
  const limit = 100;
  final out = <AnimeEpisode>[];
  var offset = 0;
  int? total;
  while (true) {
    final data = await _getJson(
      _kMirror +
          '/v0/episodes?subject_id=' +
          subjectId.toString() +
          '&type=' +
          type.toString() +
          '&limit=' +
          limit.toString() +
          '&offset=' +
          offset.toString(),
    );
    if (data is! Map) break;
    total ??= data['total'] is num ? (data['total'] as num).toInt() : null;
    final rows = data['data'];
    if (rows is! List || rows.isEmpty) break;
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['id'];
      if (id is! int) continue;
      final sort = row['sort'];
      out.add(
        AnimeEpisode(
          id: id,
          sort: sort is num ? sort.toDouble() : 0,
          name: (row['name'] ?? '').toString().trim(),
          nameCn: (row['name_cn'] ?? '').toString().trim(),
          airdate: (row['airdate'] ?? '').toString().trim(),
          ep: row['ep'] is num ? (row['ep'] as num).toInt() : 0,
        ),
      );
    }
    offset += rows.length;
    if (total != null && offset >= total) break;
    if (rows.length < limit) break;
  }
  out.sort((a, b) => a.sort.compareTo(b.sort));
  return out;
}

/// 番剧详情（结构化），给详情页直接用。
class AnimeDetail {
  const AnimeDetail({
    required this.id,
    required this.title,
    required this.original,
    required this.cover,
    required this.summary,
    this.score,
    this.rank,
    this.date = '',
    this.eps,
    this.platform = '',
    this.tags = const [],
  });

  final int id;
  final String title;
  final String original;
  final String cover;
  final String summary;
  final double? score;
  final int? rank;
  final String date;
  final int? eps;
  final String platform;
  final List<String> tags;
}

/// 拉 subject 详情；失败返回 null（由页面显示重试态）。
Future<AnimeDetail?> fetchSubjectDetail(int id) async {
  if (id == 0) return null;
  final data = await _getJson(_kMirror + '/p1/subjects/' + id.toString());
  if (data is! Map) return null;
  final rating = data['rating'] is Map ? data['rating'] as Map : null;
  double? score;
  int? rank;
  if (rating != null) {
    final s = rating['score'];
    if (s is num && s > 0) score = s.toDouble();
    final r = rating['rank'];
    if (r is num && r > 0) rank = r.toInt();
  }
  final tags = <String>[];
  for (final tag in (data['tags'] is List ? data['tags'] as List : const [])) {
    if (tag is Map) {
      final name = (tag['name'] ?? '').toString().trim();
      if (name.isNotEmpty) tags.add(name);
    }
  }
  return AnimeDetail(
    id: id,
    title: (data['nameCN'] ?? data['nameCn'] ?? data['name'] ?? '')
        .toString()
        .trim(),
    original: (data['name'] ?? '').toString().trim(),
    cover: _cover(data['images'] is Map ? data['images'] as Map : null),
    summary: (data['summary'] ?? '').toString().trim(),
    score: score,
    rank: rank,
    date: (data['date'] ?? '').toString().trim(),
    eps: data['eps'] is num ? (data['eps'] as num).toInt() : null,
    platform: (data['platform'] ?? '').toString().trim(),
    tags: tags,
  );
}

/// 番剧详情（镜像 /p1/subjects/{id}）。
Future<Map<String, dynamic>> fetchDetail(
  String itemId, {
  String tab = '小说',
}) async {
  final id = animeIdOf(itemId);
  if (id == 0) return {'source': kAnimeSource};
  final data = await _getJson(_kMirror + '/p1/subjects/' + id.toString());
  if (data is! Map) return {'source': kAnimeSource};
  final item = _toItem(data);
  return {
    'book_id': id.toString(),
    'book_name': item?.title ?? '',
    'detail_page_thumb_url': item?.cover ?? '',
    'abstract': (data['summary'] ?? '').toString(),
    'author_info': {'name': ''},
    'category': '动漫',
    'tags': const <String>[],
    'creation_status': -1,
    'source': kAnimeSource,
  };
}