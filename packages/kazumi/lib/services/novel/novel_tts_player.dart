import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/novel/local_tts_engine.dart';
import 'package:kazumi/services/novel/novel_paginator.dart';
import 'package:kazumi/services/novel/novel_tts_controller.dart';

/// 朗读的两种音源。
enum TtsEngineKind {
  /// 本地神经网络（sherpa-onnx VITS）。音质好，需要先下模型。
  neural,

  /// 系统 TTS（flutter_tts）。零成本，作为兜底。
  system,
}

/// 朗读引擎的总调度：选哪条通道、下模型、串行播放、推进句子。
///
/// 为什么不直接改 NovelTtsController：那个封装的是「系统 TTS 的一句话
/// 怎么念」，而神经网络通道需要「合成 WAV → 交给播放器 → 等播放完成」
/// 这条完全不同的链路。两者共享的是**切句结果**和**进度语义**，所以这里
/// 复用 NovelTtsController 的切句，只替换发声部分。
class NovelTtsPlayer {
  NovelTtsPlayer({LocalTtsEngine? engine})
      : _engine = engine ?? LocalTtsEngine() {
  }

  final LocalTtsEngine _engine;
  final Player _player = Player();

  /// 系统 TTS 兜底通道。
  final NovelTtsController _system = NovelTtsController();

  TtsEngineKind _kind = TtsEngineKind.neural;
  TtsPlaybackState _state = TtsPlaybackState.idle;
  List<TtsSentence> _sentences = const [];
  int _index = 0;
  double _speed = 1.0;

  /// 系统 TTS 引擎包名（空 = 系统默认）。
  String _enginePackage = '';

  /// 引擎内音色名（空 = 引擎默认）。
  String _engineVoice = '';
  bool _disposed = false;

  /// 临时 WAV 文件，播完即删。
  Directory? _cacheDir;

  void Function(int index)? onSentenceChanged;
  void Function(TtsPlaybackState state)? onStateChanged;
  void Function(String message)? onNotice;

  TtsPlaybackState get state => _state;
  int get sentenceIndex => _index;
  List<TtsSentence> get sentences => _sentences;

  /// 整章文本（只读），供阅读页把长按的段落定位到句子。
  String get fullText => _system.fullText;

  /// 整章字符偏移 → 第几句。
  int sentenceIndexAt(int offset) => _system.sentenceIndexAt(offset);

  TtsEngineKind get engineKind => _kind;
  bool get isActive => _state != TtsPlaybackState.idle;

  /// 是否处于「可恢复的暂停」。
  ///
  /// 系统通道交给 NovelTtsController 判断（它知道 TTS 的 cancel 回调有没有
  /// 把状态刷成 idle）；神经网络通道用自己的播放器，暂停就是真暂停。
  bool get isPaused => _kind == TtsEngineKind.neural
      ? _state == TtsPlaybackState.paused
      : _system.isPaused;
  LocalTtsEngine get engine => _engine;

  /// 系统 TTS 控制器。切引擎/选音色要走它。
  NovelTtsController get system => _system;

  TtsSentence? get currentSentence {
    if (_state == TtsPlaybackState.idle) return null;
    if (_index < 0 || _index >= _sentences.length) return null;
    return _sentences[_index];
  }

  bool get atEnd => _sentences.isNotEmpty && _index >= _sentences.length - 1;

  /// 载入一章正文。
  Future<void> load({
    required List<String> paragraphs,
    required bool indent,
    int fromSentence = 0,
  }) async {
    final text = _joinParagraphs(paragraphs, indent: indent);
    _sentences = NovelTtsController.splitSentences(text);
    _index = fromSentence.clamp(0, (_sentences.length - 1).clamp(0, 1 << 30));
    onSentenceChanged?.call(_index);
  }

  String _joinParagraphs(List<String> paragraphs, {required bool indent}) {
    final buffer = StringBuffer();
    for (final raw in paragraphs) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith(NovelPaginator.imageMarker)) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(indent ? '\u3000\u3000$t' : t);
    }
    return buffer.toString();
  }

  /// 尝试切到神经网络通道。模型没下时返回 false（调用方提示用户下载）。
  Future<bool> tryUseNeural() async {
    if (await _engine.modelReady()) {
      try {
        await _engine.warmUp();
        _kind = TtsEngineKind.neural;
        return true;
      } catch (e) {
        KazumiLogger().w('neural tts warmup failed: $e');
        _kind = TtsEngineKind.system;
        return false;
      }
    }
    _kind = TtsEngineKind.system;
    return false;
  }

  /// 强制使用系统 TTS。
  void useSystem() {
    _kind = TtsEngineKind.system;
  }

  /// 设置系统 TTS 引擎与音色。
  ///
  /// 这是给 MultiTTS 这类第三方引擎用的：它们注册成系统 TTS 引擎后，
  /// 选它就能用它的音色（用户自己导入的微软/火山语音包）。
  /// 注意只影响「系统通道」；神经网络通道用自己的模型。
  void setSystemEngine({required String package, required String voice}) {
    _enginePackage = package;
    _engineVoice = voice;
  }

  void setSpeed(double speed) {
    _speed = speed.clamp(0.3, 3.0);
  }

  Future<void> play({int? fromSentence}) async {
    if (_sentences.isEmpty) return;
    if (fromSentence != null) {
      _index = fromSentence.clamp(0, _sentences.length - 1);
      onSentenceChanged?.call(_index);
    }
    if (_kind == TtsEngineKind.neural) {
      await _speakNeural();
      return;
    }
    // 系统通道：先应用用户选的引擎/音色，再交给 NovelTtsController。
    if (_enginePackage.isNotEmpty) {
      final ok = await _system.selectEngine(_enginePackage);
      if (!ok) {
        _notice('切换朗读引擎失败，用系统默认');
      }
    }
    if (_engineVoice.isNotEmpty) {
      await _system.selectVoice(_engineVoice);
    }
    // 语速必须在选完引擎之后设——换引擎会重置语速。
    // _speed 是倍率（0.8~2.0），正好也是 Android setSpeechRate 的语义。
    await _system.setRate(_speed);

    // 把整章丢给 NovelTtsController，它自己串行。
    await _system.load(
      paragraphs: _currentParagraphs,
      indent: _currentIndent,
      fromSentence: _index,
    );
    _system.onStateChanged = (s) {
      if (!_disposed) _emitState(s);
    };
    _system.onSentenceChanged = (i) {
      if (_disposed) return;
      _index = i;
      onSentenceChanged?.call(i);
    };
    await _system.play(fromSentence: _index);
  }

  // 系统通道需要原始段落，这里存一份。
  List<String> _currentParagraphs = const [];
  bool _currentIndent = true;

  void cacheParagraphs(List<String> paragraphs, {required bool indent}) {
    _currentParagraphs = paragraphs;
    _currentIndent = indent;
  }

  Future<void> pause() async {
    if (_kind == TtsEngineKind.neural) {
      await _player.pause();
      _emitState(TtsPlaybackState.paused);
      return;
    }
    _system.pause();
  }

  Future<void> resume() async {
    if (_kind == TtsEngineKind.neural) {
      await _player.play();
      _emitState(TtsPlaybackState.speaking);
      return;
    }
    await _system.resume();
  }

  Future<void> stop() async {
    if (_kind == TtsEngineKind.neural) {
      await _player.stop();
    } else {
      await _system.stop();
    }
    _index = 0;
    _emitState(TtsPlaybackState.idle);
    onSentenceChanged?.call(_index);
  }

  Future<void> skip(int delta) async {
    if (_sentences.isEmpty) return;
    final next = (_index + delta).clamp(0, _sentences.length - 1);
    if (next == _index) return;
    if (_kind == TtsEngineKind.neural) {
      await _player.stop();
    } else {
      await _system.stop();
    }
    _index = next;
    onSentenceChanged?.call(next);
    if (_state != TtsPlaybackState.idle) {
      await play(fromSentence: next);
    }
  }

  // ── 神经网络通道 ─────────────────────────────────────────────────────

  Future<void> _speakNeural() async {
    if (_index < 0 || _index >= _sentences.length) {
      _emitState(TtsPlaybackState.idle);
      return;
    }
    _emitState(TtsPlaybackState.speaking);
    onSentenceChanged?.call(_index);
    final audio = await _engine.synthesize(
      _sentences[_index].text,
      speed: _speed,
    );
    if (audio == null) {
      // 没拿到音频：可能超时、可能引擎挂了。降级而不是静默。
      await _fallbackToSystem();
      return;
    }
    // 只走这一条播放路径。不要再挂 engine.onAudio —— 那样同一段会播两次
    // （引擎先 complete 兑现 future，随后又回调一次）。
    _awaitingSeq = audio.seq;
    await _playSamples(audio);
  }

  int _awaitingSeq = -1;

  /// 合成失败时的降级：切系统 TTS 继续读，别让朗读卡死。
  Future<void> _fallbackToSystem() async {
    if (_disposed) return;
    _notice('本地合成失败，改用系统朗读');
    _kind = TtsEngineKind.system;
    await play(fromSentence: _index);
  }

  Future<void> _playSamples(TtsAudio audio) async {
    try {
      final dir = await _ensureCacheDir();
      final file = File('${dir.path}/tts_${audio.seq}.wav');
      await file.writeAsBytes(encodeWav(audio.samples, audio.sampleRate),
          flush: true);
      // 播完自动下一句。用 stream 而不是 await open：open 只是开始，
      // 需要等 completed 才代表这一段读完。
      //
      // 先声明再赋值：listen 的回调里要用到 subscription 本身（读完了要
      // cancel），如果写成 final sub = ....listen(cb) 那 cb 里引用 sub 时
      // 它还没初始化，Dart 直接编译报错。
      StreamSubscription<bool>? sub;
      sub = _player.stream.completed.listen((done) {
        if (!done || _disposed) return;
        sub?.cancel();
        unawaited(_onSegmentDone(file));
      });
      await _player.open(Media(file.uri.toString()), play: true);
    } catch (e) {
      KazumiLogger().w('neural tts play failed: $e');
      await _fallbackToSystem();
    }
  }

  Future<void> _onSegmentDone(File file) async {
    // 播完删掉临时文件，免得缓存目录越堆越大。
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    if (_disposed) return;
    if (_index + 1 >= _sentences.length) {
      _emitState(TtsPlaybackState.idle);
      return;
    }
    _index++;
    await _speakNeural();
  }

  Future<Directory> _ensureCacheDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/qingshu_tts');
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  void _emitState(TtsPlaybackState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }

  void _notice(String message) {
    onNotice?.call(message);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _player.dispose();
    await _system.dispose();
    await _engine.dispose();
    onSentenceChanged = null;
    onStateChanged = null;
    onNotice = null;
  }
}
