import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/http_headers.dart';

class PluginSiteClient {
  PluginSiteClient._();

  static final PluginSiteClient instance = PluginSiteClient._();

  Future<String> requestText(
    String url, {
    required String method,
    Map<String, dynamic> headers = const {},
    Map<String, dynamic> queryParameters = const {},
    Object? data,
    CancelToken? cancelToken,
  }) async {
    try {
      // 用 bytes 取回再自己解码：Dio 默认按 UTF-8 解，遇到 GBK 站点
      // （wenku8 这类 2015 年的老站）会整页乱码，而且乱码后 XPath 一条都
      // 匹配不上 —— 表现是「搜到了但列表空」，很难查。
      final response = await DioFactory.pluginDio.request<List<int>>(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.bytes,
          headers: _headers(headers),
          // 不要 Dio 自己猜编码，交给 _decodeBody
          responseDecoder: null,
        ),
        cancelToken: cancelToken,
      );
      return _decodeBody(response.data, response.headers);
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  /// 把响应字节解成字符串。
  ///
  /// 顺序：
  ///   1. Content-Type 里声明了 charset（且不是 utf-8）→ 按它解
  ///   2. 严格 UTF-8 解码能过 → 就用 UTF-8
  ///   3. 否则按 GBK 解（老站点绝大多数是 GBK / GB18030）
  ///
  /// 严格 UTF-8 这一步很关键：允许替换字符的解码器会把 GBK 字节「解成」
  /// 一堆 U+FFFD，看起来没报错，实际内容全废。
  String _decodeBody(List<int>? bytes, Headers headers) {
    if (bytes == null || bytes.isEmpty) return '';
    final data = Uint8List.fromList(bytes);

    final contentType = headers.value('content-type') ?? '';
    final match = RegExp(r'charset=([\w-]+)', caseSensitive: false)
        .firstMatch(contentType);
    final declared = match?.group(1)?.toLowerCase() ?? '';
    if (declared.isNotEmpty && declared != 'utf-8' && declared != 'utf8') {
      try {
        return _decodeWith(declared, data);
      } catch (_) {
        // 落到下面的自动判断
      }
    }

    try {
      return utf8.decode(data);
    } on FormatException {
      // 不是合法 UTF-8，按 GBK 再试
    }
    try {
      return gbk.decode(data);
    } catch (_) {
      // 最后的兜底：允许替换字符，至少让用户看到部分内容
      return utf8.decode(data, allowMalformed: true);
    }
  }

  String _decodeWith(String charset, Uint8List data) {
    return switch (charset) {
      'gbk' || 'gb2312' || 'gb18030' => gbk.decode(data),
      'big5' => big5.decode(data),
      _ => utf8.decode(data),
    };
  }

  Map<String, dynamic> _headers(Map<String, dynamic> headers) {
    return {
      'user-agent': getRandomUA(),
      // 这一对是 linovelib 的**正文完整性开关**，不是可选的礼貌头：
      // 只带 Accept-Language 时它返回半章（497 字，末尾插一句
      // 「內容加載失敗！請刷新或更換瀏覽器」），两个都带才是整章（2778 字）。
      // 消融实验逐项验证过：UA / Referer / Cookie 都不影响，Accept 与
      // Accept-Language 缺一不可。
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': getRandomAcceptedLanguage(),
      'Connection': 'keep-alive',
      ...headers,
    };
  }
}
