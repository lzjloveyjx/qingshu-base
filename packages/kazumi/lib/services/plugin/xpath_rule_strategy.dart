import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

enum XPathRuleFormatKind {
  invalidUrl,
  invalidDocument,
  invalidSelector,
}

enum XPathRuleField {
  searchList,
  searchName,
  searchResult,
  chapterRoads,
  chapterResult,
  captchaDetectValue,
  captchaImage,
  captchaButton,
}

class XPathRuleFormatException implements Exception {
  const XPathRuleFormatException(
    this.message, {
    required this.kind,
    this.field,
    this.expression,
    this.cause,
  });

  final String message;
  final XPathRuleFormatKind kind;
  final XPathRuleField? field;
  final String? expression;
  final Object? cause;

  @override
  String toString() => 'XPathRuleFormatException.${kind.name}: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

class XPathRuleStrategy {
  const XPathRuleStrategy();

  PreparedRuleRequest prepareSearchRequest(
    RuleExecutionConfig config,
    String keyword,
  ) {
    final queryUrl = config.searchUrl.replaceAll(
      '@keyword',
      Uri.encodeQueryComponent(keyword),
    );
    final uri = Uri.tryParse(queryUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw XPathRuleFormatException(
        '搜索 URL 无效: $queryUrl',
        kind: XPathRuleFormatKind.invalidUrl,
      );
    }
    if (!config.usePost) {
      return PreparedRuleRequest(
        method: 'GET',
        url: queryUrl,
        includeCookies: true,
      );
    }
    return PreparedRuleRequest(
      method: 'POST',
      url: uri.replace(query: null).toString(),
      bodyType: 'form',
      body: uri.queryParameters,
      includeCookies: true,
    );
  }

  PreparedRuleRequest prepareChapterRequest(
    RuleExecutionConfig config,
    String source,
  ) {
    final url = normalizeEpisodeUrl(config.baseUrl, source);
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw XPathRuleFormatException(
        '章节 URL 无效: $url',
        kind: XPathRuleFormatKind.invalidUrl,
      );
    }
    // XPath chapter requests historically go out without stored cookies;
    // only search requests attach them.
    return PreparedRuleRequest(method: 'GET', url: url);
  }

  RuleSearchParseResult parseSearch(
    String raw,
    RuleExecutionConfig config,
  ) {
    final root = _documentElement(raw);
    if (detectsCaptchaChallenge(
      raw,
      config.antiCrawlerConfig,
      htmlElement: root,
    )) {
      throw CaptchaRequiredException(config.pluginName);
    }

    final items = <SearchItem>[];
    final fragments = <String>[];
    final diagnostics = <String>[];
    final nodes = _runSelector(
      XPathRuleField.searchList,
      config.searchList,
      () => root.queryXPath(config.searchList).nodes,
    );
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      try {
        final name = _runSelector(
              XPathRuleField.searchName,
              config.searchName,
              () => node.queryXPath(config.searchName).node,
            )?.text?.trim() ??
            '';
        final source = _runSelector(
              XPathRuleField.searchResult,
              config.searchResult,
              () => node.queryXPath(config.searchResult).node,
            )?.attributes['href']?.trim() ??
            '';
        if (name.isEmpty || source.isEmpty) {
          diagnostics.add('搜索节点 $index 缺少名称或来源，已跳过');
          continue;
        }
        // 封面（可选）：规则没写 searchCover 时跳过，不报错。
        var cover = '';
        if (config.searchCover.trim().isNotEmpty) {
          try {
            final img = node.queryXPath(config.searchCover).node;
            if (img != null) {
              // 懒加载站点的真地址在 data-src / data-original 上
              cover = (img.attributes['data-src'] ??
                      img.attributes['data-original'] ??
                      img.attributes['src'] ??
                      '')
                  .trim();
            }
          } catch (_) {
            // 单条封面抓不到不该让整条结果消失
          }
        }
        items.add(SearchItem(name: name, src: source, cover: cover));
        fragments.add(_fragment(node.node));
      } on XPathRuleFormatException {
        rethrow;
      } catch (error) {
        diagnostics.add('搜索节点 $index 解析失败: $error');
      }
    }
    return RuleSearchParseResult(
      items: items,
      matchedFragments: fragments,
      diagnostics: diagnostics,
    );
  }

  /// 解析章节目录。
  ///
  /// [pageUrl] 是**目录页自己的 URL**，用来解析相对链接。为什么不能用
  /// config.baseUrl：目录页通常不在站点根目录（wenku8 的目录在
  /// `/novel/3/3057/index.htm`，而章节链接写成 `125416.htm`）。按 baseUrl
  /// 解析会得到 `/125416.htm` —— 一个 404 的地址。这跟动漫侧不同：动漫的
  /// 规则站点把剧集链接写成站内绝对路径，所以按 baseUrl 解析一直是对的。
  RuleChapterParseResult parseChapters(
    String raw,
    RuleExecutionConfig config, {
    String pageUrl = '',
  }) {
    // 解析相对链接的基准：优先目录页自身，退化到 baseUrl。
    final resolveBase = pageUrl.trim().isNotEmpty
        ? pageUrl.trim()
        : config.baseUrl;
    final root = _documentElement(raw);
    final roads = <Road>[];
    final diagnostics = <String>[];
    final roadNodes = _runSelector(
      XPathRuleField.chapterRoads,
      config.chapterRoads,
      () => root.queryXPath(config.chapterRoads).nodes,
    );
    for (var roadIndex = 0; roadIndex < roadNodes.length; roadIndex++) {
      final roadNode = roadNodes[roadIndex];
      try {
        final urls = <String>[];
        final names = <String>[];
        final episodeNodes = _runSelector(
          XPathRuleField.chapterResult,
          config.chapterResult,
          () => roadNode.queryXPath(config.chapterResult).nodes,
        );
        for (var episodeIndex = 0;
            episodeIndex < episodeNodes.length;
            episodeIndex++) {
          try {
            final episode = episodeNodes[episodeIndex].node;
            final source = episode.attributes['href']?.trim() ?? '';
            if (source.isEmpty) {
              diagnostics.add(
                '线路 $roadIndex 的剧集节点 $episodeIndex 缺少 URL，已跳过',
              );
              continue;
            }
            final name = (episode.text ?? '').replaceAll(RegExp(r'\s+'), '');
            urls.add(normalizeEpisodeUrl(resolveBase, source));
            names.add(name.isEmpty ? '第${episodeIndex + 1}集' : name);
          } catch (error) {
            diagnostics.add(
              '线路 $roadIndex 的剧集节点 $episodeIndex 解析失败: $error',
            );
          }
        }
        if (urls.isEmpty) {
          diagnostics.add('线路 $roadIndex 没有有效剧集，已跳过');
          continue;
        }
        roads.add(
          Road(
            name: '播放线路${roads.length + 1}',
            data: urls,
            identifier: names,
          ),
        );
      } on XPathRuleFormatException {
        rethrow;
      } catch (error) {
        diagnostics.add('线路节点 $roadIndex 解析失败: $error');
      }
    }
    return RuleChapterParseResult(
      roads: roads,
      diagnostics: diagnostics,
    );
  }

  bool detectsCaptchaChallenge(
    String raw,
    AntiCrawlerConfig config, {
    Element? htmlElement,
  }) {
    if (!config.enabled) return false;
    final detectValue = config.captchaDetectValue.trim();
    if (detectValue.isNotEmpty) {
      switch (config.captchaDetectType) {
        case CaptchaDetectType.text:
          return raw.contains(detectValue);
        case CaptchaDetectType.regex:
          try {
            return RegExp(
              detectValue,
              caseSensitive: false,
              dotAll: true,
            ).hasMatch(raw);
          } on FormatException {
            return false;
          }
        case CaptchaDetectType.xpath:
        default:
          final root = htmlElement ?? _documentElement(raw);
          return _runSelector(
                XPathRuleField.captchaDetectValue,
                detectValue,
                () => root.queryXPath(detectValue).node,
              ) !=
              null;
      }
    }

    final root = htmlElement ?? _documentElement(raw);
    final fallbackSelectors = <(XPathRuleField, String)>[
      (XPathRuleField.captchaImage, config.captchaImage),
      (XPathRuleField.captchaButton, config.captchaButton),
    ];
    for (final (field, expression) in fallbackSelectors) {
      if (expression.trim().isEmpty) continue;
      final node = _runSelector(
        field,
        expression,
        () => root.queryXPath(expression).node,
      );
      if (node != null) return true;
    }
    return false;
  }

  Element _documentElement(String raw) {
    try {
      final element = parse(raw).documentElement;
      if (element == null) {
        throw const XPathRuleFormatException(
          'HTML 响应没有根节点',
          kind: XPathRuleFormatKind.invalidDocument,
        );
      }
      return element;
    } on XPathRuleFormatException {
      rethrow;
    } catch (error) {
      throw XPathRuleFormatException(
        'HTML 响应解析失败',
        kind: XPathRuleFormatKind.invalidDocument,
        cause: error,
      );
    }
  }

  T _runSelector<T>(
    XPathRuleField field,
    String expression,
    T Function() query,
  ) {
    final label = _fieldLabel(field);
    if (expression.trim().isEmpty) {
      throw XPathRuleFormatException(
        '$label XPath 不能为空',
        kind: XPathRuleFormatKind.invalidSelector,
        field: field,
        expression: expression,
      );
    }
    try {
      return query();
    } catch (error) {
      throw XPathRuleFormatException(
        '$label XPath 无效: $expression',
        kind: XPathRuleFormatKind.invalidSelector,
        field: field,
        expression: expression,
        cause: error,
      );
    }
  }

  String _fieldLabel(XPathRuleField field) {
    return switch (field) {
      XPathRuleField.searchList => '搜索结果列表',
      XPathRuleField.searchName => '条目名称',
      XPathRuleField.searchResult => '条目链接',
      XPathRuleField.chapterRoads => '播放线路列表',
      XPathRuleField.chapterResult => '剧集列表',
      XPathRuleField.captchaDetectValue => '验证页检测',
      XPathRuleField.captchaImage => '验证码图片',
      XPathRuleField.captchaButton => '验证按钮',
    };
  }

  String _fragment(Node node) {
    return node is Element ? node.outerHtml : node.text ?? '';
  }
}
