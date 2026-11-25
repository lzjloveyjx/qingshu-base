/// 青枢 · 把 wenku8 数据源接到番茄框架的加载器注入点。
///
/// 这样首页书城网格 / 搜索页 / 详情页 / 阅读器全部走框架自己的皮，
/// wenku8 只负责提供数据（随包 4326 本索引 + XPath 抓目录正文）。
library;

import '../../models/home_cell.dart';
import '../../models/homepage_page.dart';
import '../../models/media_item.dart';
import '../../models/search_discovery.dart';
import 'wenku8_source.dart';

/// 首页顶栏的题材分类（取自全站 4326 本书的 Tags 覆盖率 Top 10）。
/// 第一项「推荐」保留推荐流，其余按题材名走本地索引精确匹配。
const List<String> kWenku8HomeTabs = [
  '全部', '校园', '恋爱', '奇幻', '青春', '后宫', '欢乐向', '战斗', '冒险', '悬疑', '科幻',
];

/// 题材 tab 的卡片种类统一当作书（走搜索兜底，用题材名当关键词）。
const Set<String> kWenku8TagTabs = {
  '校园', '恋爱', '奇幻', '青春', '后宫', '欢乐向', '战斗', '冒险', '悬疑', '科幻',
};

/// 该 tab 名是否是 wenku8 题材（题材 tab 走 searchLocal 精确匹配）。
bool isWenku8TagTab(String name) => kWenku8TagTabs.contains(name);

/// 其它分类返回空页，沿用它们各自的失败兜底（本项目只做轻小说）。
/// 首页分类搜索兜底 loader（SearchTabsLoader: String query, {int page}）。
Future<List<SearchTab>> wenku8HomeSearchTabs(String query, {int page = 1}) async {
  final items = await searchLocal(query);
  if (items.isEmpty) return const [];
  // 桶名回显查询词：题材 tab（校园/恋爱…）点名自己的桶，_searchItems
  // 才能精确命中，不会去借「综合」混合桶串台。
  final label = isWenku8TagTab(query) ? query : '小说';
  return [SearchTab(title: label, items: items)];
}

/// 首页 homepage loader（tab_type=2 = 小说/推荐）。
Future<HomepagePage> wenku8HomepageLoader({
  int tabType = 2,
  int offset = 0,
  String? sessionId,
  int? tabIndex,
  int? lastTabIndex,
}) async {
  if (tabType != 2) {
    return const HomepagePage(items: [], nextOffset: null, sessionId: null);
  }
  const pageSize = 60;
  final items = await browseHome(offset: offset, limit: pageSize);
  return HomepagePage(
    items: items,
    // 商品流不声明分类归属：tabScoped=false 让 homePageAffinity 放行。
    nextOffset: items.isEmpty ? null : offset + items.length,
    sessionId: null,
    tabScoped: false,
  );
}

/// 搜索页 loader：wenku8 随包索引本地子串匹配，不依赖任何在线后端。
/// 同时挂 '小说' / '书籍' / '综合' 三个桶名，覆盖框架各分类页签的认领规则。
Future<List<SearchTab>> wenku8SearchTabs(
  String query, {
  required int tabType,
  required int offset,
}) async {
  final items = await searchLocal(query);
  if (items.isEmpty) return const [];
  return [
    SearchTab(title: '小说', items: items),
    SearchTab(title: '书籍', items: items),
    SearchTab(title: '综合', items: items),
  ];
}
