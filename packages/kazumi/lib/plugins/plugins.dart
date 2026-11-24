import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/api_rule_engine.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:kazumi/utils/http_headers.dart';

export 'package:kazumi/services/plugin/rule_engine_models.dart'
    show
        CaptchaRequiredException,
        NoResultException,
        SearchErrorException,
        ChapterErrorException;

String pluginNameKey(String name) => name.toLowerCase();

class Plugin {
  static final RuleEngine _ruleEngine = RuleEngine();

  String api;
  String type;
  String name;
  String version;
  bool muliSources;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useWebview;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useNativePlayer;
  bool usePost;
  bool useLegacyParser;
  bool adBlocker;
  String userAgent;
  String baseUrl;
  String searchURL;
  String searchList;
  String searchName;
  String searchResult;

  /// 小说扩展：搜索结果封面图的选择器。
  ///
  /// 动漫规则没有这个字段（列表用海报，不靠规则抓）。轻小说列表要显示封面，
  /// 所以这里补一个，取 img 的 src / data-src / data-original。
  String searchCover;
  String chapterRoads;
  String chapterResult;

  /// 小说扩展：章节正文的 XPath 选择器。
  ///
  /// KazumiRules 里没有这个字段（18 条规则全是 anime），它是本 fork 为
  /// 轻小说加的。空串表示「这条规则不提供正文」，此时阅读器退回整页文本
  /// 并提示用户补选择器 —— 而不是直接报错，因为整页文本至少能读。
  String chapterContent;

  /// 小说扩展：正文里要**丢掉**的噪声节点（XPath，可用 `|` 组合多条）。
  ///
  /// 小说站的正文容器里常混着站点声明、广告位、"本文来自 XXX"这类固定文案。
  /// 它们不影响可读性，但每章开头都顶着一行广告很脏。放这里而不是在
  /// 抽取器里写死，是因为不同站点的噪声结构完全不同。
  ///
  /// 空串表示不丢任何节点。
  String chapterDrop;

  /// 小说扩展：目录页的路径后缀。
  ///
  /// 有些站点的详情页**不含**章节目录，目录在另一个 URL 上。linovelib 就是
  /// 这样：详情是 `/novel/5491.html`，目录在 `/novel/5491/catalog`。
  /// 空串表示「详情页本身就是目录页」，此时不做任何变换。
  ///
  /// 变换规则：去掉末尾的 `.html` 再拼上本字段（见 [catalogUrlFor]）。
  String chapterCatalog;

  /// 小说扩展：随包内置的书名索引（assets 路径）。
  ///
  /// 有些站点的搜索必须登录（wenku8 就是），但书页和正文完全免登录。这种
  /// 情况下把整站书名索引打进包，搜索在本地做，命中后再去站点取目录和正文
  /// —— 既能搜到全站每一本，又不需要账号。
  ///
  /// 空串表示走规则引擎的在线搜索。
  String novelIndexAsset;

  /// 小说扩展：目录页模板，例如 `/novel/{cat}/{aid}/index.htm`。
  ///
  /// 用在「详情页 URL 和目录页 URL 结构完全不同」的站点。{aid} 从详情 URL
  /// 里的 `/book/(\d+)` 取，{cat} 是 aid 除以 1000 的整数部分（wenku8 的
  /// 目录分片规则）。空串时退回 [chapterCatalog] 的简单后缀替换。
  String catalogTemplate;

  /// 小说扩展：排行榜页 URL（@keyword 不需要，榜单没有关键词）。
  ///
  /// 空串表示这条规则不支持「进 tab 直接看榜单」，主页会退化成空列表等用户搜。
  String rankingURL;
  String rankingList;
  String rankingName;
  String rankingResult;
  String rankingCover;
  String referer;
  String searchMode;
  String chapterMode;
  ApiSearchConfig searchApiConfig;
  ApiChapterConfig chapterApiConfig;
  AntiCrawlerConfig antiCrawlerConfig;

  Plugin({
    required this.api,
    required this.type,
    required this.name,
    required this.version,
    required this.muliSources,
    required this.useWebview,
    required this.useNativePlayer,
    required this.usePost,
    required this.useLegacyParser,
    required this.adBlocker,
    required this.userAgent,
    required this.baseUrl,
    required this.searchURL,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    this.searchCover = '',
    required this.chapterRoads,
    required this.chapterResult,
    this.chapterContent = '',
    this.chapterDrop = '',
    this.chapterCatalog = '',
    this.novelIndexAsset = '',
    this.catalogTemplate = '',
    this.rankingURL = '',
    this.rankingList = '',
    this.rankingName = '',
    this.rankingResult = '',
    this.rankingCover = '',
    required this.referer,
    this.searchMode = RuleMode.xpath,
    this.chapterMode = RuleMode.xpath,
    ApiSearchConfig? searchApiConfig,
    ApiChapterConfig? chapterApiConfig,
    AntiCrawlerConfig? antiCrawlerConfig,
  })  : searchApiConfig = searchApiConfig ?? ApiSearchConfig(),
        chapterApiConfig = chapterApiConfig ?? ApiChapterConfig(),
        antiCrawlerConfig = antiCrawlerConfig ?? AntiCrawlerConfig.empty();

  factory Plugin.fromJson(Map<String, dynamic> json) {
    return Plugin(
      api: json['api']?.toString() ?? '1',
      type: json['type'] as String? ?? 'anime',
      name: json['name'] as String? ?? '',
      version: json['version']?.toString() ?? '',
      muliSources: json['muliSources'] as bool? ?? true,
      useWebview: json['useWebview'] as bool? ?? true,
      useNativePlayer: json['useNativePlayer'] as bool? ?? true,
      usePost: json['usePost'] ?? false,
      useLegacyParser: json['useLegacyParser'] ?? false,
      adBlocker: json['adBlocker'] ?? false,
      userAgent: json['userAgent'] as String? ?? '',
      baseUrl: json['baseURL'] as String? ?? '',
      searchURL: json['searchURL'] as String? ?? '',
      searchList: json['searchList'] as String? ?? '',
      searchName: json['searchName'] as String? ?? '',
      searchResult: json['searchResult'] as String? ?? '',
      searchCover: json['searchCover'] as String? ?? '',
      chapterRoads: json['chapterRoads'] as String? ?? '',
      chapterResult: json['chapterResult'] as String? ?? '',
      chapterContent: json['chapterContent'] as String? ?? '',
      chapterDrop: json['chapterDrop'] as String? ?? '',
      chapterCatalog: json['chapterCatalog'] as String? ?? '',
      novelIndexAsset: json['novelIndexAsset'] as String? ?? '',
      catalogTemplate: json['catalogTemplate'] as String? ?? '',
      rankingURL: json['rankingURL'] as String? ?? '',
      rankingList: json['rankingList'] as String? ?? '',
      rankingName: json['rankingName'] as String? ?? '',
      rankingResult: json['rankingResult'] as String? ?? '',
      rankingCover: json['rankingCover'] as String? ?? '',
      referer: json['referer'] ?? '',
      searchMode: RuleMode.normalize(json['searchMode']),
      chapterMode: RuleMode.normalize(json['chapterMode']),
      searchApiConfig: json['searchApiConfig'] is Map
          ? ApiSearchConfig.fromJson(
              Map<String, dynamic>.from(json['searchApiConfig']),
            )
          : ApiSearchConfig(),
      chapterApiConfig: json['chapterApiConfig'] is Map
          ? ApiChapterConfig.fromJson(
              Map<String, dynamic>.from(json['chapterApiConfig']),
            )
          : ApiChapterConfig(),
      antiCrawlerConfig: json['antiCrawlerConfig'] != null
          ? AntiCrawlerConfig.fromJson(
              Map<String, dynamic>.from(json['antiCrawlerConfig']),
            )
          : AntiCrawlerConfig.empty(),
    );
  }

  factory Plugin.fromTemplate() {
    return Plugin(
      api: ApiEndpoints.apiLevel.toString(),
      type: 'anime',
      name: '',
      version: '',
      muliSources: true,
      useWebview: true,
      useNativePlayer: true,
      usePost: false,
      useLegacyParser: false,
      adBlocker: false,
      userAgent: '',
      baseUrl: '',
      searchURL: '',
      searchList: '',
      searchName: '',
      searchResult: '',
      searchCover: '',
      chapterRoads: '',
      chapterResult: '',
      chapterContent: '',
      chapterCatalog: '',
      novelIndexAsset: '',
      catalogTemplate: '',
      rankingURL: '',
      rankingList: '',
      rankingName: '',
      rankingResult: '',
      rankingCover: '',
      referer: '',
      searchMode: RuleMode.xpath,
      chapterMode: RuleMode.xpath,
      searchApiConfig: ApiSearchConfig(),
      chapterApiConfig: ApiChapterConfig(),
      antiCrawlerConfig: AntiCrawlerConfig.empty(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'api': api,
      'type': type,
      'name': name,
      'version': version,
      'muliSources': muliSources,
      'useWebview': useWebview,
      'useNativePlayer': useNativePlayer,
      'usePost': usePost,
      'useLegacyParser': useLegacyParser,
      'adBlocker': adBlocker,
      'userAgent': userAgent,
      'baseURL': baseUrl,
      'searchURL': searchURL,
      'searchList': searchList,
      'searchName': searchName,
      'searchResult': searchResult,
      if (searchCover.isNotEmpty) 'searchCover': searchCover,
      'chapterRoads': chapterRoads,
      'chapterResult': chapterResult,
      // 只在非空时写出：老规则 JSON 不该被塞一个空字段，
      // 否则导出/再导入会多出一堆无意义的键。
      if (chapterContent.isNotEmpty) 'chapterContent': chapterContent,
      if (chapterDrop.isNotEmpty) 'chapterDrop': chapterDrop,
      if (chapterCatalog.isNotEmpty) 'chapterCatalog': chapterCatalog,
      if (novelIndexAsset.isNotEmpty) 'novelIndexAsset': novelIndexAsset,
      if (catalogTemplate.isNotEmpty) 'catalogTemplate': catalogTemplate,
      if (rankingURL.isNotEmpty) 'rankingURL': rankingURL,
      if (rankingList.isNotEmpty) 'rankingList': rankingList,
      if (rankingName.isNotEmpty) 'rankingName': rankingName,
      if (rankingResult.isNotEmpty) 'rankingResult': rankingResult,
      if (rankingCover.isNotEmpty) 'rankingCover': rankingCover,
      'referer': referer,
      'searchMode': searchMode,
      'chapterMode': chapterMode,
      // Persisting re-serializes the whole plugin list, so a configured API
      // rule must survive even while the mode points at XPath.
      if (searchMode == RuleMode.api || searchApiConfig.request.url.isNotEmpty)
        'searchApiConfig': searchApiConfig.toJson(),
      if (chapterMode == RuleMode.api ||
          chapterApiConfig.request.url.isNotEmpty)
        'chapterApiConfig': chapterApiConfig.toJson(),
      'antiCrawlerConfig': antiCrawlerConfig.toJson(),
    };
  }

  bool get usesApiSearch => searchMode == RuleMode.api;

  bool get requiresNewerClient => int.parse(api) > ApiEndpoints.apiLevel;

  RuleExecutionConfig get _executionConfig => RuleExecutionConfig(
        pluginName: name,
        baseUrl: baseUrl,
        usePost: usePost,
        searchMode: searchMode,
        chapterMode: chapterMode,
        searchUrl: searchURL,
        searchList: searchList,
        searchName: searchName,
        searchResult: searchResult,
        searchCover: searchCover,
        chapterRoads: chapterRoads,
        chapterResult: chapterResult,
        chapterContent: chapterContent,
        searchApiConfig: searchApiConfig,
        chapterApiConfig: chapterApiConfig,
        antiCrawlerConfig: antiCrawlerConfig,
      );

  /// 小说：抓一章正文。返回原始 HTML，由 NovelContentExtractor 抽文本。
  Future<String> fetchNovelChapter(
    String chapterUrl, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.fetchChapterHtml(
      _executionConfig,
      chapterUrl,
      cancelToken: cancelToken,
    );
  }

  /// 这条规则能不能当小说源用：有正文选择器、或者至少是个 novel 类型的规则。
  bool get supportsNovel => type == 'novel' || chapterContent.isNotEmpty;

  Future<RuleSearchTrace> traceSearch(
    String keyword, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.search(
      _executionConfig,
      keyword,
      cancelToken: cancelToken,
    );
  }

  Future<RuleChapterTrace> traceChapters(
    String source, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.queryChapters(
      _executionConfig,
      source,
      cancelToken: cancelToken,
    );
  }

  /// Parses HTML harvested from the captcha webview as a search result;
  /// returns null when not applicable, letting callers fall back to
  /// [queryBangumi].
  PluginSearchResponse? parseHarvestedSearch(String html) {
    return _ruleEngine.tryParseHarvestedSearch(_executionConfig, html);
  }

  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async {
    try {
      return (await traceSearch(keyword, cancelToken: cancelToken)).response;
    } on CaptchaRequiredException {
      rethrow;
    } on NoResultException {
      rethrow;
    } on SearchErrorException {
      if (shouldRethrow) rethrow;
      return PluginSearchResponse(pluginName: name, data: <SearchItem>[]);
    }
  }

  /// 榜单用的副本：把搜索通道指向排行榜页。
  ///
  /// 为什么需要它：linovelib 的搜索接口要过图片验证码，而「进入 tab 就想看到
  /// 书」不能每次都弹验证码。排行榜页免验证、结构是另一套（rank_d_list 而不是
  /// search-result-list），所以用一份只换 searchURL / searchList / searchName /
  /// searchResult / searchCover 的副本去抓，其它字段（章节、正文）完全复用。
  ///
  /// 规则里没写 rankingURL 时原样返回自己 —— 不支持榜单的规则照常工作。
  Plugin forRanking() {
    final rankingUrl = rankingURL.trim();
    if (rankingUrl.isEmpty) return this;
    return Plugin(
      api: api,
      type: type,
      name: name,
      version: version,
      muliSources: muliSources,
      useWebview: useWebview,
      useNativePlayer: useNativePlayer,
      usePost: usePost,
      useLegacyParser: useLegacyParser,
      adBlocker: adBlocker,
      userAgent: userAgent,
      baseUrl: baseUrl,
      searchURL: rankingUrl,
      searchList: rankingList.trim().isEmpty ? searchList : rankingList,
      searchName: rankingName.trim().isEmpty ? searchName : rankingName,
      searchResult: rankingResult.trim().isEmpty ? searchResult : rankingResult,
      searchCover: rankingCover.trim().isEmpty ? searchCover : rankingCover,
      chapterRoads: chapterRoads,
      chapterResult: chapterResult,
      chapterContent: chapterContent,
      chapterDrop: chapterDrop,
      chapterCatalog: chapterCatalog,
      novelIndexAsset: novelIndexAsset,
      catalogTemplate: catalogTemplate,
      referer: referer,
      searchMode: RuleMode.xpath,
      chapterMode: chapterMode,
      searchApiConfig: searchApiConfig,
      chapterApiConfig: chapterApiConfig,
      antiCrawlerConfig: antiCrawlerConfig,
    );
  }

  /// 把详情页 URL 换成目录页 URL。
  ///
  /// `chapterCatalog` 为空时原样返回（详情页就是目录页）。否则先去掉末尾的
  /// `.html`，再拼上后缀 —— linovelib 的 `/novel/5491.html` →
  /// `/novel/5491/catalog`。
  String catalogUrlFor(String detailUrl) {
    // 模板优先：有些站点的目录 URL 和详情 URL 毫无共同前缀，只能按规则
    // 从 aid 拼（wenku8 的 /book/6.htm → /novel/0/6/index.htm）。
    final template = catalogTemplate.trim();
    if (template.isNotEmpty) {
      final aid = RegExp(r'/book/(\d+)').firstMatch(detailUrl)?.group(1);
      if (aid != null && aid.isNotEmpty) {
        final cat = (int.parse(aid) ~/ 1000).toString();
        final path = template
            .replaceAll('{aid}', aid)
            .replaceAll('{cat}', cat);
        final base = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl;
        return path.startsWith('http') ? path : base + path;
      }
    }
    final suffix = chapterCatalog.trim();
    if (suffix.isEmpty) return detailUrl;
    var url = detailUrl.trim();
    if (url.endsWith('.html')) url = url.substring(0, url.length - 5);
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    return url + (suffix.startsWith('/') ? suffix : '/$suffix');
  }

  Future<List<Road>> queryChapterRoads(
    String source, {
    RuleCancelToken? cancelToken,
  }) async {
    return (await traceChapters(
      catalogUrlFor(source),
      cancelToken: cancelToken,
    ))
        .roads;
  }

  String buildFullUrl(String urlItem) {
    return normalizeEpisodeUrl(baseUrl, urlItem);
  }

  /// Headers used when resolving or downloading the final media resource.
  Map<String, String> buildHttpHeaders() {
    return {
      'user-agent': userAgent.isEmpty ? getRandomUA() : userAgent,
      if (referer.isNotEmpty) 'referer': referer,
    };
  }
}
