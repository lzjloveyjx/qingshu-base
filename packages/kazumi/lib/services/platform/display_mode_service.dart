import 'dart:io';

import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/device.dart';
import 'package:window_manager/window_manager.dart';

class DisplayModeService {
  DisplayModeService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');

  /// 【青枢】宿主提供的系统栏控制通道。
  ///
  /// Kazumi 原本走 `com.predidit.kazumi/intent` 的 setSystemBarsHidden，
  /// 那是它自己的 Android 插件；青枢没有移植，调用必然抛
  /// MissingPluginException，被 _attempt 吞掉 —— 于是全屏时状态栏一直不隐藏。
  ///
  /// 青枢主壳注册了 `fqapp/player_system_ui`（PlayerSystemUiPlugin，走
  /// WindowInsetsController，Android 15+ 的 edge-to-edge 下也有效）。
  /// 这里优先用它，通道不存在时再退回 Kazumi 原来的路径。
  static const _hostSystemUiChannel = MethodChannel('fqapp/player_system_ui');
  static Future<void> _pendingFullscreen = Future.value();
  static Future<void>? _pendingSystemBars;
  static Object? _systemBarsOwner;
  static bool _systemBarsHidden = false;

  static Future<void> applyVideoFullscreen(bool fullscreen) {
    return _pendingFullscreen = _pendingFullscreen.then((_) async {
      if (isDesktop()) {
        await _attempt(() => windowManager.setFullScreen(fullscreen));
        return;
      }

      // Restore system orientation on exit, including an existing landscape.
      await _attempt(() => SystemChrome.setPreferredOrientations(
            fullscreen
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight
                  ]
                : [],
          ));
    });
  }

  /// Outgoing pages cannot release chrome owned by the next visible page.
  static Future<void> setSystemBarsHidden({
    required Object owner,
    required bool hidden,
  }) {
    _systemBarsOwner = owner;
    return _setSystemBarsHidden(hidden);
  }

  static Future<void> releaseSystemBars(Object owner) {
    if (!identical(_systemBarsOwner, owner)) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsOwner = null;
    return _setSystemBarsHidden(false);
  }

  static Future<void> _setSystemBarsHidden(bool hidden) {
    if (_systemBarsHidden == hidden) {
      return _pendingSystemBars ?? Future.value();
    }
    _systemBarsHidden = hidden;
    // Rotation acknowledgements must not delay immersion or route cleanup.
    late final Future<void> request;
    request = (_pendingSystemBars ?? Future<void>.value())
        .then((_) => _attempt(() async {
              if (Platform.isAndroid) {
                // 宿主通道优先：hide/show。
                try {
                  await _hostSystemUiChannel.invokeMethod<void>(
                      hidden ? 'hide' : 'show');
                  return;
                } on MissingPluginException {
                  // 宿主没注册（例如跑在别的主壳里），退回 Kazumi 原路径。
                }
                await _intentChannel.invokeMethod(
                    'setSystemBarsHidden', hidden);
              } else if (Platform.isIOS) {
                await SystemChrome.setEnabledSystemUIMode(
                  hidden
                      ? SystemUiMode.immersiveSticky
                      : SystemUiMode.edgeToEdge,
                );
              }
            }))
        .whenComplete(() {
      if (identical(_pendingSystemBars, request)) _pendingSystemBars = null;
    });
    return _pendingSystemBars = request;
  }

  static Future<void> _attempt(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      KazumiLogger().e('Display: failed to apply video display mode',
          error: error, stackTrace: stackTrace);
    }
  }
}
