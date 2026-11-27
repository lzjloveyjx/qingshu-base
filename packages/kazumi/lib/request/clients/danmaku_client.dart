import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/crypto.dart';

/// DanDanPlay 客户端。
///
/// 【青枢】上游用 CI 注入的 --dart-define=DANDANAPI_APPID / DANDANAPI_KEY
/// 生成 X-AppId + X-Signature。青枢的构建流程从来没注入过这两个值，所以
/// `dandanCredentials` 里是空字符串 —— 发出去的请求 AppId 为空，服务器
/// 一律回 403（实测 bangumi / search / comment 三个端点全 403）。
///
/// 原来的表现是：每部番、每一集都往 DanDanPlay 打一次注定失败的请求，
/// 每次刷一条 WARNING + 一条 ERROR，把运行日志刷满。
///
/// 现在改成：发现凭证为空就直接短路，只记一条说明，不再发请求。
/// 弹幕功能本身不受影响 —— BiliBili / Gamer 那两个源照常工作。
class DanmakuClient {
  DanmakuClient._();

  static final DanmakuClient instance = DanmakuClient._();

  /// 凭证是否齐全。空的时候所有 DanDanPlay 请求必然 403，没有发出去的意义。
  static bool get hasCredentials {
    final id = dandanCredentials['id'] ?? '';
    final value = dandanCredentials['value'] ?? '';
    return id.trim().isNotEmpty && value.trim().isNotEmpty;
  }

  static bool _warnedNoCredentials = false;

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic> headers = const {},
    CancelToken? cancelToken,
  }) async {
    if (!hasCredentials) {
      if (!_warnedNoCredentials) {
        _warnedNoCredentials = true;
        KazumiLogger().i(
          'Danmaku: 未配置 DanDanPlay 凭证（DANDANAPI_APPID / DANDANAPI_KEY），'
          '该源已跳过；BiliBili / Gamer 弹幕不受影响',
        );
      }
      // 抛一个可识别的错误让上层走「本次没有弹幕」的分支，而不是当成
      // 网络故障去重试。
      throw DanmakuUnavailableException(url);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(url);
    final requestHeaders = <String, dynamic>{
      'user-agent': getRandomUA(),
      'referer': '',
      'X-Auth': 1,
      'X-AppId': dandanCredentials['id'],
      'X-Timestamp': timestamp,
      'X-Signature': generateDandanSignature(uri.path, timestamp),
      ...headers,
    };

    try {
      final response = await DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(headers: requestHeaders),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }
}
/// DanDanPlay 未配置凭证时抛出的异常。
///
/// 单独定义一个类型，是为了让上层和真正的网络错误区分开：网络错误值得
/// 提示用户「换个源试试」，缺凭证只是「这个源没启用」，不该报警。
class DanmakuUnavailableException implements Exception {
  DanmakuUnavailableException(this.url);

  final String url;

  @override
  String toString() => 'DanDanPlay 未配置凭证，已跳过（$url）';
}
