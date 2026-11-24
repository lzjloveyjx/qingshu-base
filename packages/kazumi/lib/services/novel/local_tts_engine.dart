import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/novel/tts_model_manager.dart';

/// 本地神经网络 TTS 引擎（sherpa-onnx + VITS 中文模型）。
///
/// 和 flutter_tts 的分工：
///   • 这个负责「好听」—— 神经网络合成，语调自然，接近有声书
///   • flutter_tts 负责「兜底」—— 模型没下、下载失败、加载失败时也能出声
///
/// 为什么模型放在磁盘而不是 assets：30MB 的 onnx 权重放进 APK 会让每个
/// 用户都付这份代价。首次朗读时下载（见 [TtsModelManager]），之后离线可用。
///
/// 为什么合成要开后台 isolate：VITS 推理一段几百字要几百毫秒到几秒，在
/// 主 isolate 跑会直接卡住 UI（翻页、滚动全都停）。
class LocalTtsEngine {
  LocalTtsEngine({TtsModelManager? manager, TtsVoice? voice})
      : _manager = manager ?? TtsModelManager(),
        _voice = voice ?? TtsVoice.xiaoYa;

  final TtsModelManager _manager;

  /// 当前音色。换音色要重新 warmUp。
  TtsVoice _voice;
  TtsVoice get voice => _voice;

  IsolateHandle? _handle;
  bool _ready = false;
  bool _loading = false;
  String _error = '';

  /// 每次请求的序号，用来丢弃过期结果。
  int _requestSeq = 0;
  final Map<int, Completer<TtsAudio>> _pending = {};

  /// 合成完成回调（可选）。合成结果同时也会由 [synthesize] 返回 ——
  /// 两者**只能择一**，都用会重复播放。
  void Function(TtsAudio audio)? onAudio;

  /// 引擎层错误回调（可选）。
  void Function(String error)? onError;

  bool get isReady => _ready;
  bool get isLoading => _loading;
  String get error => _error;

  /// 模型是否已下载。
  Future<bool> modelReady([TtsVoice? v]) => _manager.isReady(v ?? _voice);

  /// 把随包模型释放到磁盘（首次使用）。[onProgress] 是 0~1。
  ///
  /// 不联网：模型在 assets 里，这里只是拷到应用私有目录，因为
  /// sherpa-onnx 的 C 接口要文件路径，读不了 Flutter asset 的字节流。
  Future<void> downloadModel({
    void Function(double progress)? onProgress,
    TtsVoice? voice,
  }) {
    return _manager.ensureReady(voice ?? _voice, onProgress: onProgress);
  }

  /// 切换音色。下次 warmUp 生效；正在朗读时调用会停止当前播放。
  Future<void> setVoice(TtsVoice next) async {
    if (next.id == _voice.id) return;
    await dispose();
    _voice = next;
  }

  /// 初始化引擎。已就绪时立即返回。
  Future<void> warmUp() async {
    if (_ready || _loading) return;
    _loading = true;
    _error = '';
    try {
      if (!await _manager.isReady(_voice)) {
        throw Exception('模型还没释放');
      }
      final dir = await _manager.voiceDir(_voice);

      // onnx 文件名随音色不同（zh_CN-xiao_ya-medium.onnx），扫出来。
      final onnx = (await dir
              .list()
              .where((e) => e is File && e.path.endsWith('.onnx'))
              .toList())
          .first as File;

      final handle = IsolateHandle(
        modelPath: onnx.path,
        tokensPath: '${dir.path}/tokens.txt',
        lexiconPath: '${dir.path}/lexicon.txt',
      );
      handle.onAudio = (audio) {
        // 先兑现等待中的合成请求，再通知上层播放 —— 顺序反了会让
        // NovelTtsPlayer 在 completer 还没完成时就去读结果。
        final completer = _pending.remove(audio.seq);
        if (completer != null && !completer.isCompleted) {
          completer.complete(audio);
        }
        onAudio?.call(audio);
      };
      handle.onError = (message) {
        // 出错时把当前所有等待中的请求都失败掉，否则它们会挂到超时。
        for (final c in _pending.values.toList()) {
          if (!c.isCompleted) c.completeError(Exception(message));
        }
        _pending.clear();
        onError?.call(message);
      };
      await handle.start();
      _handle = handle;
      _ready = true;
      KazumiLogger().i('LocalTTS: engine ready');
    } catch (e) {
      _error = e.toString();
      KazumiLogger().w('LocalTTS: warm up failed: $e');
      rethrow;
    } finally {
      _loading = false;
    }
  }

  /// 合成一段文本。返回 null 表示引擎未就绪或合成失败。
  /// [speed] 是语速倍率（1.0 = 原速）。
  Future<TtsAudio?> synthesize(String text, {double speed = 1.0}) async {
    final handle = _handle;
    if (!_ready || handle == null) return null;
    final seq = ++_requestSeq;
    final completer = Completer<TtsAudio>();
    _pending[seq] = completer;
    handle.request(seq: seq, text: text, speed: speed);
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } catch (_) {
      _pending.remove(seq);
      return null;
    }
  }

  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('disposed'));
    }
    _pending.clear();
    await _handle?.dispose();
    _handle = null;
    _ready = false;
  }
}

/// 合成结果：16-bit PCM 采样 + 采样率。
class TtsAudio {
  const TtsAudio({
    required this.seq,
    required this.samples,
    required this.sampleRate,
  });

  final int seq;
  final Float32List samples;
  final int sampleRate;

  /// 这段音频的时长。
  Duration get duration => Duration(
        milliseconds: (samples.length * 1000 / sampleRate).round(),
      );
}

/// 后台 isolate 的句柄封装。
class IsolateHandle {
  IsolateHandle({
    required this.modelPath,
    required this.tokensPath,
    required this.lexiconPath,
  });

  final String modelPath;
  final String tokensPath;
  final String lexiconPath;

  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _from;

  /// isolate 回传的音频，由 LocalTtsEngine 挂接。
  void Function(TtsAudio audio)? onAudio;

  /// isolate 回传的错误。
  void Function(String error)? onError;

  Future<void> start() async {
    final receive = ReceivePort();
    final completer = Completer<void>();
    _from = receive;

    _isolate = await Isolate.spawn(_workerMain, _InitMsg(
      reply: receive.sendPort,
      modelPath: modelPath,
      tokensPath: tokensPath,
      lexiconPath: lexiconPath,
    ));

    receive.listen((msg) {
      if (msg is SendPort) {
        _toWorker = msg;
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (msg is _ErrMsg) {
        onError?.call(msg.message);
        if (!completer.isCompleted) {
          completer.completeError(Exception(msg.message));
        }
        return;
      }
      if (msg is _AudioMsg) {
        onAudio?.call(TtsAudio(
          seq: msg.seq,
          samples: msg.samples,
          sampleRate: msg.sampleRate,
        ));
      }
    });

    await completer.future.timeout(
      const Duration(seconds: 40),
      onTimeout: () => throw Exception('TTS 引擎初始化超时'),
    );
  }

  void request({
    required int seq,
    required String text,
    required double speed,
  }) {
    _toWorker?.send(_ReqMsg(seq: seq, text: text, speed: speed));
  }

  Future<void> dispose() async {
    _toWorker?.send(const _ShutdownMsg());
    _from?.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
  }
}

class _InitMsg {
  const _InitMsg({
    required this.reply,
    required this.modelPath,
    required this.tokensPath,
    required this.lexiconPath,
  });
  final SendPort reply;
  final String modelPath;
  final String tokensPath;
  final String lexiconPath;
}

class _ReqMsg {
  const _ReqMsg({required this.seq, required this.text, required this.speed});
  final int seq;
  final String text;
  final double speed;
}

class _ShutdownMsg {
  const _ShutdownMsg();
}

class _AudioMsg {
  const _AudioMsg({
    required this.seq,
    required this.samples,
    required this.sampleRate,
  });
  final int seq;
  final Float32List samples;
  final int sampleRate;
}

class _ErrMsg {
  const _ErrMsg(this.message);
  final String message;
}

/// 后台 isolate 入口。
void _workerMain(_InitMsg init) {
  final receive = ReceivePort();
  sherpa.OfflineTts? tts;

  try {
    sherpa.initBindings();
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: init.modelPath,
          tokens: init.tokensPath,
          lexicon: init.lexiconPath,
        ),
      ),
      maxNumSentences: 1,
    );
    tts = sherpa.OfflineTts(config);
  } catch (e) {
    init.reply.send(_ErrMsg('TTS 初始化失败：$e'));
    return;
  }

  init.reply.send(receive.sendPort);

  receive.listen((msg) {
    if (msg is _ShutdownMsg) {
      tts?.free();
      receive.close();
      return;
    }
    if (msg is! _ReqMsg) return;
    try {
      final audio = tts!.generate(text: msg.text, speed: msg.speed);
      init.reply.send(_AudioMsg(
        seq: msg.seq,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      ));
    } catch (e) {
      init.reply.send(_ErrMsg('合成失败：$e'));
    }
  });
}

/// 把 Float32 采样写成 16-bit PCM WAV 字节流。
///
/// 用 WAV 而不是裸 PCM：播放器能直接吃文件，不用自己管重采样和声道。
Uint8List encodeWav(Float32List samples, int sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataSize = samples.length * 2;

  final header = ByteData(44);
  // RIFF
  header.setUint8(0, 0x52);
  header.setUint8(1, 0x49);
  header.setUint8(2, 0x46);
  header.setUint8(3, 0x46);
  header.setUint32(4, 36 + dataSize, Endian.little);
  // WAVE
  header.setUint8(8, 0x57);
  header.setUint8(9, 0x41);
  header.setUint8(10, 0x56);
  header.setUint8(11, 0x45);
  // fmt 
  header.setUint8(12, 0x66);
  header.setUint8(13, 0x6d);
  header.setUint8(14, 0x74);
  header.setUint8(15, 0x20);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, numChannels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  // data
  header.setUint8(36, 0x64);
  header.setUint8(37, 0x61);
  header.setUint8(38, 0x74);
  header.setUint8(39, 0x61);
  header.setUint32(40, dataSize, Endian.little);

  final out = Uint8List(44 + dataSize);
  out.setRange(0, 44, header.buffer.asUint8List());

  final pcm = ByteData(dataSize);
  for (var i = 0; i < samples.length; i++) {
    // clamp 后转 16 位：不 clamp 会有溢出导致的爆音。
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    pcm.setInt16(i * 2, v, Endian.little);
  }
  out.setRange(44, 44 + dataSize, pcm.buffer.asUint8List());
  return out;
}
