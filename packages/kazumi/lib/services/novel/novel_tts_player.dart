import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/novel/novel_paginator.dart';
import 'package:kazumi/services/novel/novel_tts_controller.dart';

/// 朗读音源。
///
/// 【青枢】只剩系统 TTS 一条通道：神经网络（sherpa-onnx VITS）已移除 ——
/// 模型体积大（31MB）、且用户的 MultiTTS 已经提供了更好的音色，没必要
/// 再打包一套。枚举保留是为了兼容调用方（阅读页用 useSystem() 明确选它）。
enum TtsEngineKind { system }

/// 朗读引擎的总调度：串行播放、推进句子、把状态抛给 UI。
///
/// 切句和「一句话怎么念」都在 [NovelTtsController] 里；这一层只负责
/// 把整章交给它、把进度回调出去。
class NovelTtsPlayer {
  NovelTtsPlayer();

  /// 系统 TTS 通道。
  final NovelTtsController _system = NovelTtsController();

  TtsEngineKind _kind = TtsEngineKind.system;
  TtsPlaybackState _state = TtsPlaybackState.idle;
  List<TtsSentence> _sentences = const [];
  int _index = 0;
  double _speed = 1.0;

  /// 系统 TTS 引擎包名（空 = 系统默认）。
  String _enginePackage = '';

  /// 引擎内音色名（空 = 引擎默认）。
  String _engineVoice = '';
  bool _disposed = false;

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

  /// 是否处于「可恢复的暂停」（转发给系统通道，它才知道 cancel 回调的时序）。
  bool get isPaused => _system.isPaused;

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

  /// 保留接口：调用方仍会调它，但现在只有系统通道，不做切换。
  void useSystem() {
    _kind = TtsEngineKind.system;
  }

  /// 设置系统 TTS 引擎与音色。
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
    await _system.setRate(_speed);

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
    _system.pause();
  }

  Future<void> resume() async {
    await _system.resume();
  }

  Future<void> stop() async {
    await _system.stop();
    _index = 0;
    _emitState(TtsPlaybackState.idle);
    onSentenceChanged?.call(_index);
  }

  Future<void> skip(int delta) async {
    if (_sentences.isEmpty) return;
    final next = (_index + delta).clamp(0, _sentences.length - 1);
    if (next == _index) return;
    await _system.stop();
    _index = next;
    onSentenceChanged?.call(next);
    if (_state != TtsPlaybackState.idle) {
      await play(fromSentence: next);
    }
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
    await _system.dispose();
    onSentenceChanged = null;
    onStateChanged = null;
    onNotice = null;
  }
}
