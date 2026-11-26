import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

class PlatformEnvironmentService {
  PlatformEnvironmentService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');

  static Future<bool> isRunningOnX11() async {
    if (!Platform.isLinux) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('isRunningOnX11');
    } catch (e) {
      // 青枢：MissingPluginException 是 PlatformException 的兄弟类，
      // 只 catch PlatformException 抓不到它，异常会穿透到调用方。
      KazumiLogger().e("Failed to check X11 environment: '$e'.");
      return false;
    }
  }

  static int? _cachedSdkVersion;

  /// 当前设备的 Android SDK 版本（API level）。
  ///
  /// 优先走 Kazumi 的原生通道；青枢没有移植那个插件，所以通道缺失时退回
  /// 解析 [Platform.operatingSystemVersion]（形如
  /// "android (SDK 34), ..." 或 "Android 14 (API 34)"），再退化到 0。
  ///
  /// 调用方用它决定 vo=gpu-next（SDK>=34）还是 vo=gpu —— 返回 0 会走 gpu，
  /// 在 Android 14 上只是少了 Vulkan 优化，不影响出画面。
  static Future<int> getAndroidSdkVersion() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    final cached = _cachedSdkVersion;
    if (cached != null) return cached;
    var version = 0;
    try {
      version = await _intentChannel.invokeMethod('getAndroidSdkVersion');
    } catch (e) {
      final parsed = _parseSdkFromOperatingSystemVersion();
      if (parsed == null) {
        KazumiLogger().e("Failed to get Android SDK version: '$e'.");
      } else {
        KazumiLogger().i('Android SDK version from platform string: $parsed');
      }
      version = parsed ?? 0;
    }
    _cachedSdkVersion = version;
    return version;
  }

  /// 从 [Platform.operatingSystemVersion] 里抠出 API level。
  /// Android 上它的格式随版本变化，见过这两种：
  ///   "android (SDK 34), Pixel 7, ..."
  ///   "Android 14 (API 34)"
  static int? _parseSdkFromOperatingSystemVersion() {
    final raw = Platform.operatingSystemVersion;
    for (final pattern in [
      RegExp(r'SDK\s+(\d+)', caseSensitive: false),
      RegExp(r'API\s+(\d+)', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(raw);
      final value = match == null ? null : int.tryParse(match.group(1) ?? '');
      if (value != null && value > 0) return value;
    }
    return null;
  }

}