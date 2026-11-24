import 'package:dio/dio.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';

typedef RuleCancelToken = CancelToken;

class CaptchaRequiredException implements Exception {
  const CaptchaRequiredException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'CaptchaRequiredException: $pluginName requires captcha verification';
}

class NoResultException implements Exception {
  const NoResultException(this.pluginName);

  final String pluginName;

  @override
  String toString() =>
      'NoResultException: $pluginName returned no search results';
}

class SearchErrorException implements Exception {
  const SearchErrorException(this.pluginName, {this.cause});

  final String pluginName;
  final Object? cause;

  @override
  String toString() =>
      'SearchErrorException: $pluginName search failed${cause != null ? ' ($cause)' : ''}';
}

class ChapterErrorException implements Exception {
  const ChapterErrorException(this.pluginName, {this.cause});

  final String pluginName;
  final Object? cause;

  @override
  String toString() => 'ChapterErrorException: $pluginName chapter query failed'
      '${cause != null ? ' ($cause)' : ''}';
}

/// Immutable runtime snapshot built from a plugin rule.
///
/// Playback-only headers such as the rule's User-Agent and Referer are
/// deliberately excluded. API requests can provide their own static headers.
class RuleExecutionConfig {
  const RuleExecutionConfig({
    required this.pluginName,
    required this.baseUrl,
    required this.usePost,
    required this.searchMode,
    required this.chapterMode,
    required this.searchUrl,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    this.searchCover = '',
    this.chapterDrop = '',
    required this.chapterRoads,
    required this.chapterResult,
    this.chapterContent = '',
    required this.searchApiConfig,
    required this.chapterApiConfig,
    required this.antiCrawlerConfig,
  });

  final String pluginName;
  final String baseUrl;
  final bool usePost;
  final String searchMode;
  final String chapterMode;
  final String searchUrl;
  final String searchList;
  final String searchName;
  final String searchResult;

  /// 小说扩展：搜索结果的封面图选择器（取 img 的 src/data-src）。
  /// 空串表示该规则不提供封面。
  final String searchCover;
  final String chapterRoads;
  final String chapterResult;

  /// 小说扩展：章节正文的 XPath（空串 = 该规则不提供正文）。
  final String chapterContent;

  /// 正文里要丢掉的噪声节点（XPath，`|` 可组合）。空串表示不丢。
  final String chapterDrop;
  final ApiSearchConfig searchApiConfig;
  final ApiChapterConfig chapterApiConfig;
  final AntiCrawlerConfig antiCrawlerConfig;
}

class PreparedRuleRequest {
  const PreparedRuleRequest({
    required this.method,
    required this.url,
    this.headers = const <String, dynamic>{},
    this.query = const <String, dynamic>{},
    this.bodyType = ApiBodyType.none,
    this.body,
    this.includeCookies = false,
  });

  final String method;
  final String url;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> query;
  final String bodyType;
  final Object? body;

  /// Whether stored plugin cookies are attached to the request. Historically
  /// only search and API requests send cookies; XPath chapter requests do not.
  final bool includeCookies;
}

class RuleSearchParseResult {
  const RuleSearchParseResult({
    required this.items,
    this.matchedFragments = const <String>[],
    this.diagnostics = const <String>[],
  });

  final List<SearchItem> items;
  final List<String> matchedFragments;
  final List<String> diagnostics;
}

class RuleChapterParseResult {
  const RuleChapterParseResult({
    required this.roads,
    this.diagnostics = const <String>[],
  });

  final List<Road> roads;
  final List<String> diagnostics;
}

class RuleSearchTrace {
  const RuleSearchTrace({
    required this.rawResponse,
    required this.response,
    required this.matchedFragments,
    required this.diagnostics,
  });

  final String rawResponse;
  final PluginSearchResponse response;
  final List<String> matchedFragments;
  final List<String> diagnostics;
}

class RuleChapterTrace {
  const RuleChapterTrace({
    required this.rawResponse,
    required this.roads,
    required this.diagnostics,
  });

  final String rawResponse;
  final List<Road> roads;
  final List<String> diagnostics;
}
