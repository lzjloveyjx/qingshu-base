import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/utils/device.dart';

/// 画中画工具。
///
/// 青枢注意：`com.predidit.kazumi/pip` 这条原生通道是 Kazumi 自己的
/// Android 插件实现的（MainActivity + PipPlugin），青枢没有移植，所以
/// 这些方法必然抛 MissingPluginException —— 它是 PlatformException 的
/// 兄弟类，原来 `on PlatformException` 抓不到，异常会冒到 zone 变成
/// 「未捕获异步异常」。
///
/// 现在的策略：
///   1) 第一次探测发现通道不存在，就把 [_channelAvailable] 记为 false；
///   2) 之后所有调用直接返回，不再往原生通道发请求 —— 否则播放页每帧
///      同步一次 PiP 动作，日志会被同一条 ERROR 刷满，把真正的错误淹掉；
///   3) 只打一条 info 说明「画中画不可用」，不当作错误。
class PipUtils {
  static bool androidPIPInited = false;

  /// 原生通道是否可用。null = 还没探测过。
  static bool? _channelAvailable;

  /// 设备本身是否支持画中画（只有通道可用时才有意义）。
  static bool? _deviceSupported;

  /// 通道可用 / 设备支持 是两件事：
  ///   - 通道缺失（青枢没移植 Kazumi 的 PiP 插件）→ 是我们的问题
  ///   - 通道在但返回 false → 是设备/系统不支持
  /// 提示文案必须分开，否则会把「我们没做」说成「你的设备不行」。
  static bool get androidPIPAvailable => _channelAvailable ?? false;

  static bool get androidPIPDeviceSupported => _deviceSupported ?? false;

  static bool get _available => _channelAvailable != false;

  static void _markUnavailable(Object error) {
    if (_channelAvailable == false) return;
    _channelAvailable = false;
    _deviceSupported = false;
    KazumiLogger().i(
      'PiP: 原生通道 com.predidit.kazumi/pip 不可用，画中画功能停用'
      '（${error.runtimeType}）',
    );
  }

  // 比例约分
  static Size getPIPAspectSize({required int width, required int height}) {
    if (width <= 0 || height <= 0) {
      return const Size(16, 9);
    }
    final int divisor = width.gcd(height);
    return Size(width / divisor, height / divisor);
  }

  static Future<bool> isAndroidPIPSupported() async {
    if (!Platform.isAndroid) {
      return false;
    }
    // 注意不要在这里返回 _channelAvailable —— 那是「通道在不在」，
    // 不等于「能不能用画中画」。设备不支持时也必须返回 false。
    if (_channelAvailable != null) {
      return _channelAvailable! && (_deviceSupported ?? false);
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      final bool? supported =
          await pipChannel.invokeMethod('isPictureInPictureSupported');
      _channelAvailable = true;
      _deviceSupported = supported ?? false;
      return _deviceSupported!;
    } catch (e) {
      _markUnavailable(e);
      return false;
    }
  }

  static Future<bool> enterAndroidPIPWindow(
      {int width = 16, int height = 9}) async {
    if (!Platform.isAndroid || !_available) {
      return false;
    }
    final Size aspectSize = getPIPAspectSize(width: width, height: height);
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      final bool? entered =
          await pipChannel.invokeMethod('enterPictureInPictureMode', {
        'width': aspectSize.width.toInt(),
        'height': aspectSize.height.toInt(),
      });
      return entered ?? false;
    } catch (e) {
      _markUnavailable(e);
      return false;
    }
  }

  static Future<void> updateAndroidPIPActions({
    required bool playing,
    required bool danmakuEnabled,
    int width = 16,
    int height = 9,
    Rect? sourceRect,
  }) async {
    if (!Platform.isAndroid || !_available) {
      return;
    }
    final Size aspectSize = getPIPAspectSize(width: width, height: height);
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('updatePictureInPictureActions', {
        'playing': playing,
        'danmakuEnabled': danmakuEnabled,
        'width': aspectSize.width.toInt(),
        'height': aspectSize.height.toInt(),
        if (sourceRect != null) ...{
          'sourceLeft': sourceRect.left.round(),
          'sourceTop': sourceRect.top.round(),
          'sourceRight': sourceRect.right.round(),
          'sourceBottom': sourceRect.bottom.round(),
        },
      });
    } catch (e) {
      _markUnavailable(e);
    }
  }

  static Future<void> setAndroidAutoEnterPIPEnabled(bool enabled) async {
    if (!Platform.isAndroid || !_available) {
      return;
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('setAndroidAutoEnterPIPEnabled', {
        'enabled': enabled,
      });
    } catch (e) {
      _markUnavailable(e);
    }
  }

  static Future<void> setAndroidPIPInPlayerPage(bool inPlayerPage) async {
    if (!Platform.isAndroid || !_available) {
      return;
    }
    const pipChannel = MethodChannel('com.predidit.kazumi/pip');
    try {
      await pipChannel.invokeMethod('setAndroidPIPInPlayerPage', {
        'inPlayerPage': inPlayerPage,
      });
    } catch (e) {
      _markUnavailable(e);
    }
  }

  // 进入桌面设备小窗模式，并用播放源比例固定窗口宽高比
  static Future<void> enterDesktopPIPWindow(
      {int width = 16, int height = 9}) async {
    final Size aspectSize = getPIPAspectSize(width: width, height: height);
    final double aspectRatio = aspectSize.width / aspectSize.height;
    const double pipWidth = 480;
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setAspectRatio(aspectRatio);
    await windowManager.setSize(Size(pipWidth, pipWidth / aspectRatio));
  }

  // 退出桌面设备小窗模式
  static Future<void> exitDesktopPIPWindow() async {
    final lowResolution = await isLowResolution();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setAspectRatio(0);
    await windowManager
        .setSize(lowResolution ? const Size(800, 600) : const Size(1280, 860));
    await windowManager.center();
  }

  static void initPipHandler({
    required Future<void> Function(String action) onAction,
    required void Function(bool inPipMode) onModeChanged,
  }) {
    const MethodChannel pipChannel = MethodChannel('com.predidit.kazumi/pip');
    if (androidPIPInited) return;
    androidPIPInited = true;

    pipChannel.setMethodCallHandler((call) async {
      if (!Platform.isAndroid) {
        return;
      }

      final Object? args = call.arguments;
      final Map? arguments = (args is Map) ? args : null;

      switch (call.method) {
        case 'onModeChanged':
          final bool? inPipMode = arguments?['isInPipMode'] as bool?;
          if (inPipMode != null) {
            onModeChanged(inPipMode);
          }
        case 'onAction':
          final String? action = arguments?['action'] as String?;
          if (action != null) {
            await onAction(action);
          }
      }
    });
  }

  static void disposePipHandler() {
    const MethodChannel pipChannel = MethodChannel('com.predidit.kazumi/pip');
    pipChannel.setMethodCallHandler(null);
    androidPIPInited = false;
  }
}
