/// BiliBili 弹幕源（青枢自建，Kazumi 上游没有这一路）。
///
/// 为什么需要它：Kazumi 唯一的自动弹幕源是 DanDanPlay，而上游靠 CI 注入
/// `DANDANAPI_APPID / DANDANAPI_KEY` 生成请求签名。青枢的构建流程从来没有
/// 这两个值，所以 DanDanPlay 一律 403（见 DanmakuClient.hasCredentials）。
/// 结果就是「弹幕」这个功能整体不可用。
///
/// BiliBili 的公开接口不需要任何鉴权，实测都能直连：
///
/// | 用途 | 接口 | 实测 |
/// |---|---|---|
/// | 搜索番剧视频 | /x/web-interface/wbi/search/all/v2 | 200 |
/// | 拿 cid | /x/web-interface/view?bvid= | 200 |
/// | 弹幕 XML | /x/v1/dm/list.so?oid={cid} | 200（raw-deflate） |
///
/// 弹幕 XML 是 **raw deflate**（没有 zlib 头），直接 inflate 会报
/// `incorrect header check` —— 必须用 `ZLibDecoder(raw: true)`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/danmaku.dart';

/// BiliBili 上一个可用的番剧/视频条目。
class BiliSearchHit {
  const BiliSearchHit({
    required this.bvid,
    required this.title,
    required this.durationSeconds,
  });

  final String bvid;
  final String title;
  final int durationSeconds;

  @override
  String toString() => '$bvid | $title (${durationSeconds}s)';
}

class BiliDanmakuSource {
  BiliDanmakuSource._();

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

  static final HttpClient _client = HttpClient()
    ..userAgent = _ua
    ..connectionTimeout = const Duration(seconds: 15);

  static Map<String, String> get _headers => const {
        'referer': 'https://www.bilibili.com/',
        'accept': 'application/json, text/plain, */*',
      };

  /// 按关键词搜视频。
  ///
  /// 用 wbi/search/all/v2 而不是 search/type：后者在没有签名时会回 412
  /// （实测），前者不需要签名。
  static Future<List<BiliSearchHit>> search(String keyword, {int limit = 10}) async {
    final q = keyword.trim();
    if (q.isEmpty) return const [];
    final uri = Uri.https('api.bilibili.com', '/x/web-interface/wbi/search/all/v2', {
      'keyword': q,
    });
    final json = await _getJson(uri);
    if (json == null) return const [];
    final data = json['data'];
    if (data is! Map) return const [];
    final blocks = data['result'];
    if (blocks is! List) return const [];

    final out = <BiliSearchHit>[];
    for (final block in blocks) {
      if (block is! Map) continue;
      // 优先用番剧（media_bangumi）的条目：它对应整季，弹幕更连贯。
      // v2 里番剧块也叫 media_bangumi，字段是 season_id 而不是 bvid，
      // 所以这里仍只收 video 块（有 bvid 才能取 cid）。
      if (block['result_type'] != 'video') continue;
      final rows = block['data'];
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final bvid = (row['bvid'] ?? '').toString().trim();
        if (bvid.isEmpty) continue;
        final title = _stripTags((row['title'] ?? '').toString());
        final duration = _parseDuration((row['duration'] ?? '').toString());
        out.add(BiliSearchHit(
          bvid: bvid,
          title: title,
          durationSeconds: duration,
        ));
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  /// 取该视频第一个分P的 cid（弹幕按 cid 索引）。
  static Future<int> cidOf(String bvid) async {
    if (bvid.isEmpty) return 0;
    final uri = Uri.https('api.bilibili.com', '/x/web-interface/view', {
      'bvid': bvid,
    });
    final json = await _getJson(uri);
    if (json == null) return 0;
    final data = json['data'];
    if (data is! Map) return 0;
    final cid = data['cid'];
    if (cid is num) return cid.toInt();
    // 有的视频只在 pages[0] 里给 cid。
    final pages = data['pages'];
    if (pages is List && pages.isNotEmpty) {
      final first = pages.first;
      if (first is Map && first['cid'] is num) {
        return (first['cid'] as num).toInt();
      }
    }
    return 0;
  }

  /// 按 cid 拉弹幕。
  static Future<List<DanmakuEntry>> commentsOf(int cid) async {
    if (cid <= 0) return const [];
    final uri = Uri.https(
      'api.bilibili.com',
      '/x/v1/dm/list.so',
      {'oid': cid.toString()},
    );
    final bytes = await _getBytes(uri);
    if (bytes == null || bytes.isEmpty) return const [];
    String xml;
    try {
      // 这里是 raw deflate（无 zlib 头）—— 加 zlib 头直接 inflate 会
      // 报 "incorrect header check"。
      final inflated = ZLibDecoder(raw: true).convert(bytes);
      xml = utf8.decode(inflated, allowMalformed: true);
    } catch (e) {
      // 偶尔服务端不压缩，直接就是 XML。
      final asText = utf8.decode(bytes, allowMalformed: true);
      if (asText.startsWith('<?xml')) {
        xml = asText;
      } else {
        KazumiLogger().w('BiliDanmaku: 弹幕解压失败 cid=$cid', error: e);
        return const [];
      }
    }
    return parseXml(xml);
  }

  /// 解析 `<d p="时间,类型,字号,颜色,时间戳,池,用户,行号">文本</d>`。
  ///
  /// 抽成独立方法方便单测：BiliBili 的 p 字段顺序与 DanDanPlay 不同
  /// （DanDanPlay 的 p 第 4 段是来源字符串），这里单独转成 DanmakuEntry。
  static List<DanmakuEntry> parseXml(String xml) {
    final out = <DanmakuEntry>[];
    final pattern = RegExp(r'<d p="([^"]*)"[^>]*>([\s\S]*?)</d>');
    for (final match in pattern.allMatches(xml)) {
      final p = match.group(1) ?? '';
      final text = _unescape(match.group(2) ?? '');
      if (text.trim().isEmpty) continue;
      final parts = p.split(',');
      if (parts.length < 4) continue;
      final time = double.tryParse(parts[0]);
      final mode = int.tryParse(parts[1]);
      final colorValue = int.tryParse(parts[3]);
      if (time == null) continue;
      // BiliBili 的弹幕类型：1/2/3 滚动，4 底部，5 顶部。
      // Kazumi 的 DanmakuEntry 只区分 1(普通) / 4(底部) / 5(顶部)。
      final int type;
      switch (mode) {
        case 4:
          type = 4;
          break;
        case 5:
          type = 5;
          break;
        default:
          type = 1;
      }
      out.add(DanmakuEntry(
        message: text,
        time: time,
        type: type,
        color: generateDanmakuColor(colorValue ?? 0xFFFFFF),
        source: 'BiliBili',
      ));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// BiliBili 搜索结果的 duration 是 "4:24" / "589:4"（分:秒），不是秒数。
  static int _parseDuration(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    final parts = text.split(':');
    if (parts.length == 1) return int.tryParse(parts[0]) ?? 0;
    var seconds = 0;
    for (final part in parts) {
      seconds = seconds * 60 + (int.tryParse(part) ?? 0);
    }
    return seconds;
  }

  /// 搜索结果标题里带 `<em class="keyword">` 高亮标签，要剥掉。
  static String _stripTags(String raw) =>
      raw.replaceAll(RegExp(r'<[^>]*>'), '').trim();

  static String _unescape(String raw) => raw
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');

  static Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      KazumiLogger().w('BiliDanmaku: 请求失败 $uri', error: e);
      return null;
    }
  }

  static Future<List<int>?> _getBytes(Uri uri) async {
    try {
      final req = await _client.getUrl(uri);
      _headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final chunks = <int>[];
      await for (final chunk in res) {
        chunks.addAll(chunk);
      }
      return chunks;
    } catch (e) {
      KazumiLogger().w('BiliDanmaku: 下载失败 $uri', error: e);
      return null;
    }
  }
}
