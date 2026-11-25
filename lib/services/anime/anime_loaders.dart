/// 青枢 · 动漫接入框架 loader 注入点。
library;

import '../../models/homepage_page.dart';
import '../../models/media_item.dart';
import 'anime_source.dart';

/// 动漫首页 loader：榜单流。
Future<HomepagePage> animeHomepageLoader({
  int tabType = 2,
  int offset = 0,
  String? sessionId,
  int? tabIndex,
  int? lastTabIndex,
}) async {
  const pageSize = 24;
  final items = await browsePopular(offset: offset, limit: pageSize);
  return HomepagePage(
    items: items,
    nextOffset: items.isEmpty ? null : offset + items.length,
    sessionId: null,
    tabScoped: false,
  );
}

/// 动漫搜索兜底 loader。
///
/// Bangumi 搜索走官方 api.bgm.tv（镜像未提供搜索），国内可能不通；
/// 这里先做本地标题过滤（榜单 + 季度表缓存），保证至少有结果。
Future<List<SearchTab>> animeHomeSearchTabs(String query, {int page = 1}) async {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final popular = await browsePopular(offset: 0, limit: 100);
  final season = await browseSeason();
  final all = <MediaItem>[...popular, for (final day in season) ...day];
  final seen = <String>{};
  final hit = <MediaItem>[];
  for (final item in all) {
    if (!seen.add(item.id)) continue;
    if (item.title.contains(q)) hit.add(item);
  }
  if (hit.isEmpty) return const [];
  return [SearchTab(title: '动漫', items: hit)];
}

/// 搜索页 loader。
Future<List<SearchTab>> animeSearchTabs(
  String query, {
  required int tabType,
  required int offset,
}) async {
  final tabs = await animeHomeSearchTabs(query);
  if (tabs.isEmpty) return const [];
  final items = tabs.first.items;
  return [
    SearchTab(title: '动漫', items: items),
    SearchTab(title: '综合', items: items),
  ];
}