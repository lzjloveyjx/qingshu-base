/// 青枢 · 轻之国度接入框架 loader 注入点。
library;

import '../../models/homepage_page.dart';
import '../../models/media_item.dart';
import '../../models/search_discovery.dart';
import 'lightnovel_source.dart';

/// 首页 homepage loader。
Future<HomepagePage> lightNovelHomepageLoader({
  int tabType = 2,
  int offset = 0,
  String? sessionId,
  int? tabIndex,
  int? lastTabIndex,
}) async {
  const pageSize = 60;
  final items = await browseHome(offset: offset, limit: pageSize);
  return HomepagePage(
    items: items,
    nextOffset: items.isEmpty ? null : offset + items.length,
    sessionId: null,
    tabScoped: false,
  );
}

/// 首页搜索兜底 loader。
Future<List<SearchTab>> lightNovelHomeSearchTabs(String query, {int page = 1}) async {
  final items = await search(query);
  if (items.isEmpty) return const [];
  return [SearchTab(title: '小说', items: items)];
}

/// 搜索页 loader：三个桶名覆盖框架各分类页签的认领规则。
Future<List<SearchTab>> lightNovelSearchTabs(
  String query, {
  required int tabType,
  required int offset,
}) async {
  final items = await search(query);
  if (items.isEmpty) return const [];
  return [
    SearchTab(title: '小说', items: items),
    SearchTab(title: '书籍', items: items),
    SearchTab(title: '综合', items: items),
  ];
}