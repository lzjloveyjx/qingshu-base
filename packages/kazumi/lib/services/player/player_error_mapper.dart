class PlayerErrorMapper {
  const PlayerErrorMapper._();

  /// 把 mpv 的原始报错翻译成人能看懂、能行动的一句话。
  ///
  /// 只返回 null 的都会被调用方按「播放器内部错误」原样弹出去 —— 所以
  /// 这里宁可多识别几种常见错，也别让用户对着
  /// `tcp: ffurl_read returned 0xffffff92` 干瞪眼。
  static String? toActionableMessage(
    Object error, {
    required bool isBuffering,
  }) {
    final message = error.toString();

    // 网络层：读超时 / 连接失败 / DNS。青枢的动漫源大多是第三方站，
    // 单条线路挂掉是常态，「换源」才是有效动作。
    if (message.contains('ffurl_read') ||
        message.contains('tcp:') ||
        message.contains('Connection refused') ||
        message.contains('Connection timed out') ||
        message.contains('Name or service not known') ||
        message.contains('Failed to resolve')) {
      return '视频源连接失败或超时, 请更换其他视频来源';
    }

    if (message.contains('Failed to recognize file format') ||
        (isBuffering && message.contains('Failed to open'))) {
      return '加载失败, 请尝试更换其他视频来源';
    }

    // HTTP 状态码错误（源站防盗链/过期）。
    if (message.contains('HTTP error 403') ||
        message.contains('HTTP error 404') ||
        message.contains('HTTP error 410')) {
      return '视频源已失效, 请更换其他视频来源';
    }

    return null;
  }
}
