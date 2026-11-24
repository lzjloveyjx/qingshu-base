import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:kazumi/utils/http_headers.dart';

/// 小说封面图。
///
/// 为什么不用 `Image.network` / `NetworkImgLayer`：
///
///   图片服务器会按 User-Agent 拦请求。`Image.network` 不传 UA 时，
///   Dart 的 HttpClient 默认发 `Dart/3.10 (dart:io)` —— wenku8 的图床
///   （img.wenku8.com）对这个 UA 直接返回 **403**，于是所有封面都是空白。
///   实测：同一个 URL，UA 换成任意浏览器串就 200。
///
///   而 `Image.network(headers: ...)` 也没用：它会在默认 UA 之外**追加**一个
///   User-Agent 头，服务器看到两个 UA，照样 403（已用原始 HTTP 请求验证）。
///   所以必须走 cached_network_image 的 httpHeaders，它用一份干净的 header
///   表替换默认值。
///
/// 同时用缓存：翻列表时同一批封面不该反复下载。
class NovelCoverImage extends StatelessWidget {
  const NovelCoverImage({
    super.key,
    required this.url,
    this.referer = '',
    this.fit = BoxFit.cover,
  });

  final String url;

  /// 图床的防盗链要求。空串表示不带。
  final String referer;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) {
      return _placeholder(context);
    }
    return CachedNetworkImage(
      imageUrl: url.trim(),
      fit: fit,
      width: double.infinity,
      httpHeaders: {
        // 关键：显式给浏览器 UA，覆盖掉 dart:io 的默认值。
        'user-agent': getRandomUA(),
        if (referer.trim().isNotEmpty) 'referer': referer.trim(),
      },
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (context, _) => _placeholder(context),
      errorWidget: (context, _, __) => _placeholder(context),
    );
  }

  Widget _placeholder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.menu_book_outlined,
        size: 28,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    );
  }
}
