import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/ech_adapter.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/rules_mirror.dart';

class RulesRepoClient {
  RulesRepoClient._();

  static final RulesRepoClient instance = RulesRepoClient._();

  /// 官方仓库地址前缀 -> 某个镜像下的实际 URL。
  static String _urlFor(RulesMirror mirror, String url) => switch (mirror) {
        RulesMirror.direct => url,
        RulesMirror.ghProxy => ApiEndpoints.ghProxyMirror + url,
        RulesMirror.ghfast => ApiEndpoints.ghfastMirror + url,
        RulesMirror.gitcode =>
          ApiEndpoints.gitcodeMirror +
              url.substring(ApiEndpoints.pluginShop.length),
      };

  Future<String> getText(String url, {CancelToken? cancelToken}) async {
    // 自定义仓库只有一条路，不做镜像回退。
    if (!url.startsWith(ApiEndpoints.pluginShop)) {
      return _fetch(RulesMirror.direct, url, cancelToken);
    }
    // 青枢：官方仓库按「当前设置 -> 其余镜像」的顺序依次尝试。
    // 原来只试一个镜像，手机上某个镜像挂了就整页空白，
    // 用户看到的就是「规则仓库什么都没有」。
    final preferred = RulesMirror.current;
    final candidates = <RulesMirror>[
      preferred,
      for (final mirror in RulesMirror.values)
        if (mirror != preferred) mirror,
    ];
    Object? lastError;
    for (final mirror in candidates) {
      try {
        final text = await _fetch(mirror, url, cancelToken);
        if (mirror != preferred) {
          KazumiLogger().i(
            'Rules: ${preferred.name} failed, served by ${mirror.name}',
          );
        }
        return text;
      } catch (error) {
        lastError = error;
        KazumiLogger().w('Rules: mirror ${mirror.name} failed');
      }
    }
    throw lastError ?? Exception('规则仓库不可达');
  }

  Future<String> _fetch(
    RulesMirror mirror,
    String url,
    CancelToken? cancelToken,
  ) async {
    try {
      final response = await DioFactory.rulesRepoDio.get<String>(
        _urlFor(mirror, url),
        options: Options(
          responseType: ResponseType.plain,
          extra: mirror == RulesMirror.ghProxy ? echExtra : null,
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
