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

/// 动漫搜索。
///
/// 为什么不用 Bangumi 官方搜索：`api.bgm.tv/v0/search/subjects` 在国内
/// 直连不通；镜像 api.kazumi.fyi 上这个 POST 路径要求请求签名（401
/// invalid request signature），Kazumi 上游自己也是直连官方站。
///
/// 所以做「本地语料 + 关键词匹配」：把榜单多页与当季/上季表拼起来，
/// 对中文名、原名、别名一起做大小写无关的子串匹配。
/// 语料够覆盖热门与当季，配合别名一般能搜到；搜不到时页面会提示。
Future<List<SearchTab>> animeHomeSearchTabs(String query, {int page = 1}) async {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];

  // 语料：榜单多页（热门）+ 当季 + 上季。三路并发，任一失败不影响其余。
  final corpora = await Future.wait([
    for (var i = 0; i < 4; i++)
      // 步长必须与镜像真实页大小一致（20），否则跳到 50/100/150 会漏条目。
      browsePopular(offset: i * browsePageSize, limit: browsePageSize)
          .catchError((_) => <MediaItem>[]),
    browseSeason()
        .then((days) => [for (final day in days) ...day])
        .catchError((_) => <MediaItem>[]),
    browseSeason(at: _previousSeason()).
        then((days) => [for (final day in days) ...day])
        .catchError((_) => <MediaItem>[]),
  ]);

  final all = <MediaItem>[for (final batch in corpora) ...batch];
  final seen = <String>{};
  final hit = <MediaItem>[];
  for (final item in all) {
    if (!seen.add(item.id)) continue;
    if (_matches(item, q)) hit.add(item);
  }
  if (hit.isEmpty) return const [];
  return [SearchTab(title: '动漫', items: hit)];
}

/// 上季的任意一天，交给 [browseSeason] 换算成那个季度。
DateTime _previousSeason() {
  final now = DateTime.now();
  return DateTime(now.year, now.month - 3, 1);
}

/// 标题、原名、别名任一命中即算匹配。
///
/// 原名与别名由 AnimeSource 塞进 MediaItem.categories（动漫条目的 UI 不渲染
/// 这个列表），见 _toItem 里的 _searchKeywords。
bool _matches(MediaItem item, String query) {
  if (item.title.toLowerCase().contains(query)) return true;
  for (final keyword in item.categories) {
    if (keyword.contains(query)) return true;
  }
  return false;
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