import 'dart:async';

import 'package:flutter/services.dart';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/audio_controller.dart';

/// 小说朗读的音频生命周期桥接。
///
/// 复用全局 [AudioController]（audio_service 前台媒体服务 + audio_session 来电中断），
/// 再叠加原生设备事件监听（蓝牙 / 有线耳机断开与重连），实现：
///
///  - 来电 / 微信语音 → 暂停，结束 → 自动恢复（audio_session 的 interruption 事件）
///  - 蓝牙耳机断开 → 暂停；重新连接 → 自动恢复（原生 EventChannel）
///  - 通知栏媒体卡片：书名 / 章节名 + 播放暂停 / 上一段 / 下一段（audio_service）
///
/// 为什么单独做一层：AudioController 的 becomingNoisy 只能告诉我们「断了」，
/// 分不清是谁造成的、也没法在重连时自动恢复。这里用 _pausedByDevice 记住
/// 「是设备断开导致的暂停」，只有这种情况才在重连时自动续读 —— 用户手动暂停
/// 后哪怕重连也不会擅自出声。
class TtsAudioBridge {
  TtsAudioBridge({
    required AudioController audioController,
    required Future<void> Function() onPause,
    required Future<void> Function() onResume,
    required Future<void> Function() onPrevious,
    required Future<void> Function() onNext,
  })  : _audio = audioController,
        _onPause = onPause,
        _onResume = onResume,
        _onPrevious = onPrevious,
        _onNext = onNext;

  final AudioController _audio;
  final Future<void> Function() _onPause;
  final Future<void> Function() _onResume;
  final Future<void> Function() _onPrevious;
  final Future<void> Function() _onNext;

  static const EventChannel _deviceChannel =
      EventChannel('com.qingshu.app/tts_device');

  StreamSubscription<dynamic>? _deviceSub;
  bool _active = false;
  bool _pausedByDevice = false;
  DateTime? _startedAt;

  /// 开始朗读时调用：绑定通知栏按钮 + 订阅设备事件。
  Future<void> start() async {
    if (_active) return;
    _active = true;
    _pausedByDevice = false;
    _startedAt = DateTime.now();
    try {
      await _audio.bindCallbacks(
        onPlay: _onResume,
        onPause: _onPause,
        onSkipToNext: _onNext,
        onSkipToPrevious: _onPrevious,
        onSeek: (_) async {},
        artworkUrl: null,
      );
    } catch (e) {
      KazumiLogger().w('TtsAudioBridge: bindCallbacks failed', error: e);
    }
    _deviceSub ??= _deviceChannel.receiveBroadcastStream().listen(
      _onDeviceEvent,
      onError: (Object e) {
        KazumiLogger().w('TtsAudioBridge: device event error: $e');
      },
    );
  }

  void _onDeviceEvent(dynamic event) {
    if (!_active) return;
    final String type;
    if (event is Map) {
      type = (event['type'] ?? '').toString();
    } else {
      type = event.toString();
    }
    switch (type) {
      case 'noisy':
      case 'headsetUnplug':
        // ACTION_HEADSET_PLUG 是 sticky 广播，注册当刻会把「当前没插耳机」
        // (state=0) 立刻回放到我们这里。刚点朗读的几百毫秒内忽略，免得
        // 一启动就被这条历史状态误暂停。
        if (_startedAt != null &&
            DateTime.now().difference(_startedAt!).inMilliseconds < 800) {
          break;
        }
        _pausedByDevice = true;
        unawaited(_onPause());
        break;
      case 'connected':
      case 'headsetPlug':
        if (_pausedByDevice) {
          _pausedByDevice = false;
          unawaited(_onResume());
        }
        break;
    }
  }

  /// 同步通知栏媒体卡片。朗读状态每次变化都要调 —— audio_session 判断
  /// 来电 / 断开是否要暂停，依赖 playbackState.playing 是准确的。
  Future<void> sync({
    required String bookTitle,
    required String chapterTitle,
    required bool playing,
  }) async {
    if (!_active) return;
    try {
      await _audio.updateSession(
        mediaId: 'qingshu_tts',
        title: bookTitle,
        album: '青枢朗读',
        artist: chapterTitle,
        duration: Duration.zero,
        playing: playing,
        loading: false,
        buffering: false,
        completed: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
        queueIndex: 0,
        canSkipToNext: true,
        canSkipToPrevious: true,
      );
    } catch (e) {
      KazumiLogger().w('TtsAudioBridge: sync failed', error: e);
    }
  }

  /// 停止朗读 / 退出阅读页时调用。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _pausedByDevice = false;
    await _deviceSub?.cancel();
    _deviceSub = null;
    try {
      await _audio.deactivate();
    } catch (e) {
      KazumiLogger().w('TtsAudioBridge: deactivate failed', error: e);
    }
  }
}