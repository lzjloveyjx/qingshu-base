/// Per-plugin search progress, written solely by PluginSearchService.
enum PluginSearchStatus { pending, success, error, noResult, captcha }

class SearchItem {
  String name;
  String src;

  /// 封面图 URL（可选）。
  ///
  /// 动漫侧的规则没有 searchCover 字段，所以这里恒为空 —— 那边的 UI 不看它。
  /// 轻小说列表要显示封面，规则里加 searchCover 选择器即可填上。
  String cover;

  SearchItem({
    required this.name,
    required this.src,
    this.cover = '',
  });

  factory SearchItem.fromJson(Map<String, dynamic> json) {
    return SearchItem(
      name: json['name'],
      src: json['src'],
      cover: json['cover'] as String? ?? '',
    );
  }
}

class PluginSearchResponse {
  String pluginName;
  List<SearchItem> data;

  PluginSearchResponse({
    required this.pluginName,
    required this.data,
  });

  factory PluginSearchResponse.fromJson(Map<String, dynamic> json) {
    return PluginSearchResponse(
      pluginName: json['pluginName'],
      data: (json['data'] as List)
          .map((itemJson) => SearchItem.fromJson(itemJson))
          .toList(),
    );
  }
}
