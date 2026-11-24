import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/novel/novel_paginator.dart';

/// 朗读状态。
enum TtsPlaybackState { idle, speaking, paused }

/// 一句话：文本 + 它在整章里的字符区间。
///
/// 为什么要记区间而不是只存一个下标：朗读时要把「正在读的那句」在正文里
/// 高亮出来，而高亮是按字符范围画背景的。只存句子内容，遇到重复句子
/// （「……」「啊。」这类）就分不清是哪一句。
class TtsSentence {
  const TtsSentence({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final int start;
  final int end;
}

/// 小说朗读控制器。
///
/// 用系统 TTS（flutter_tts）而不是自带模型：
///   • 离线可用，不用打包几百 MB 的语音模型
///   • Android/iOS 系统语音质量对中文已经够用，而且用户可以在系统设置里换
///   • 不用为准入资格负责（模型授权、商用限制这些坑全绕开）
///
/// 代价是不像神经语音那么自然，也没有「一个人的声音」这种一致性。真要那个
/// 效果得上在线 TTS，但那样每次朗读都要联网，还得管 key。
class NovelTtsController {
  NovelTtsController();

  final FlutterTts _tts = FlutterTts();

  /// 当前章的句子表（切分后）。
  List<TtsSentence> _sentences = const [];

  /// 当前章拼好的整章文本（和 _sentences 的字符偏移对齐）。
  /// 阅读页长按某段时，用该段在整章的起始偏移反查从第几句开始读。
  String _fullText = '';

  /// 整章文本（只读），供定位使用。
  String get fullText => _fullText;

  int _index = 0;
  TtsPlaybackState _state = TtsPlaybackState.idle;
  bool _initialized = false;
  bool _disposed = false;

  /// 是否处于「用户主动暂停、可以恢复」的状态。
  ///
  /// 不能用 _state == paused 判断：pause() 里的 _tts.stop() 会异步触发
  /// cancel 回调，把状态刷成 idle，于是 resume() 一看不是 paused 就直接
  /// return —— 通知栏暂停后再点播放毫无反应，通话结束也不会自动续读。
  /// 这个标记才是「可以恢复」的唯一依据。
  bool _paused = false;

  /// 正在执行「自己发起的 stop」，此时 cancel 回调不该把状态改成 idle。
  bool _pausing = false;

  /// 每读完一句要通知外面两件事：现在读的是第几句、进度如何。
  void Function(int index)? onSentenceChanged;
  void Function(TtsPlaybackState state)? onStateChanged;

  TtsPlaybackState get state => _state;
  int get sentenceIndex => _index;
  List<TtsSentence> get sentences => _sentences;
  bool get isActive => _state != TtsPlaybackState.idle;

  /// 当前正在读的那句，供 UI 高亮用。未在朗读时返回 null。
  TtsSentence? get currentSentence {
    if (_state == TtsPlaybackState.idle) return null;
    if (_index < 0 || _index >= _sentences.length) return null;
    return _sentences[_index];
  }

  /// 应用朗读参数（语速/音调）。可在朗读前随时调用，系统 TTS 会作用于
  /// 后续句子；正在读的那句不会中途变速。
  Future<void> applySettings({
    required double rate,
    required double pitch,
  }) async {
    await _ensureInit();
    await _tts.setSpeechRate(rate);
    await _tts.setPitch(pitch);
  }

  /// 单独设置语速（Android 语义：1.0 正常，2.0 两倍速，0.5 半速）。
  ///
  /// 必须在 selectEngine 之后调用——切换引擎会重置语速。
  Future<void> setRate(double rate) async {
    await _ensureInit();
    await _tts.setSpeechRate(rate);
  }

  /// 列出系统里装的所有 TTS 引擎（含 MultiTTS 这类第三方引擎）。
  ///
  /// MultiTTS 的价值就在这：它把自己注册成系统 TTS 引擎，所以任何用
  /// 系统 TTS 的应用都能直接选它，不需要我们写任何集成代码。用户装好
  /// MultiTTS、导入语音包（微软/sherpa/火山）之后，在系统设置或我们
  /// 的朗读设置里选中它即可。
  Future<List<Map<String, String>>> listEngines() async {
    await _ensureInit();
    final raw = await _tts.getEngines;
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map)
          {
            'name': (e['name'] ?? '').toString(),
            'package': (e['package'] ?? e['packageName'] ?? '').toString(),
          },
    ];
  }

  /// 列出当前引擎支持的中文音色。
  Future<List<Map<String, String>>> listVoices() async {
    await _ensureInit();
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];
    final out = <Map<String, String>>[];
    for (final v in raw) {
      if (v is! Map) continue;
      final locale = (v['locale'] ?? v['language'] ?? '').toString();
      // 只要中文（zh-CN / zh_CN / cmn-Hans-CN 都算）
      if (!locale.toLowerCase().startsWith('zh') &&
          !locale.toLowerCase().startsWith('cmn')) {
        continue;
      }
      out.add({
        'name': (v['name'] ?? '').toString(),
        'locale': locale,
        'id': (v['id'] ?? v['name'] ?? '').toString(),
      });
    }
    return out;
  }

  /// 切换系统 TTS 引擎（例如切到 MultiTTS）。
  ///
  /// [packageName] 是 [listEngines] 返回的 package 字段。
  Future<bool> selectEngine(String packageName) async {
    await _ensureInit();
    if (packageName.isEmpty) return false;
    try {
      final ok = await _tts.setEngine(packageName);
      return ok == 1 || ok == true;
    } catch (_) {
      return false;
    }
  }

  /// 选择音色（引擎内部的音色，如"小艺""云希"）。
  Future<bool> selectVoice(String voiceName) async {
    await _ensureInit();
    if (voiceName.isEmpty) return false;
    try {
      final ok = await _tts.setVoice({'name': voiceName, 'locale': 'zh-CN'});
      return ok == 1 || ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _initialized = true;

    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(1.0);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    // 让系统在每句结束后回调 completion，这是串行朗读的驱动来源。
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      _emitState(TtsPlaybackState.speaking);
    });
    // 用 completion 而不是 stop/cancel：一句话正常读完才会推进到下一句。
    _tts.setCompletionHandler(() {
      if (_disposed) return;
      _speakNext();
    });
    _tts.setCancelHandler(() {
      if (_disposed) return;
      // 自己调 stop() 暂停时会走到这里。此时状态必须留在 paused，
      // 否则通知栏的「播放」和来电后的自动恢复都会失效。
      if (_pausing) return;
      _emitState(TtsPlaybackState.idle);
    });
    _tts.setErrorHandler((message) {
      KazumiLogger().w('TTS error: $message');
      if (_disposed) return;
      _emitState(TtsPlaybackState.idle);
    });
  }

  /// 载入一章正文并从头（或从 [fromSentence]）开始朗读。
  ///
  /// [paragraphs] 是抽取器切好的段落，这里会先拼成整章文本再切句 ——
  /// 切句必须在整章层面做，否则跨段落的句子会被段落边界切断。
  Future<void> load({
    required List<String> paragraphs,
    required bool indent,
    int fromSentence = 0,
  }) async {
    await _ensureInit();
    final text = _joinParagraphs(paragraphs, indent: indent);
    _fullText = text;
    _sentences = splitSentences(text);
    _index = fromSentence.clamp(0, (_sentences.length - 1).clamp(0, 1 << 30));
    _emitSentence();
  }

  /// 把段落拼成整章文本。
  ///
  /// 段落之间用换行分隔（切句时换行也算一句的边界），和阅读页看到的正文
  /// 保持一致的字符偏移 —— 高亮范围要能对得上原文。
  String _joinParagraphs(List<String> paragraphs, {required bool indent}) {
    final buffer = StringBuffer();
    for (var i = 0; i < paragraphs.length; i++) {
      final p = paragraphs[i].trim();
      if (p.isEmpty) continue;
      if (p.startsWith(NovelPaginator.imageMarker)) continue; // 插图不读
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(indent ? '\u3000\u3000$p' : p);
    }
    return buffer.toString();
  }

  /// 切句。
  ///
  /// 规则：按中文句末标点（。！？；…）和换行切，但**连续的标点和结句引号
  /// 要跟前一句走** —— 「他说：『走吧。』」如果切成「他说：『走吧。」和「』」
  /// 就会读出一个孤零零的引号。
  ///
  /// 太短的片段（< 2 字）并进前一句，避免一个字一句地念，听起来很怪。
  /// 整章字符偏移 → 第几句。用于「从指定段落开始朗读」。
  /// 取第一个 end > offset 的句子；找不到就返回 0。
  int sentenceIndexAt(int offset) {
    if (_sentences.isEmpty) return 0;
    for (var i = 0; i < _sentences.length; i++) {
      if (_sentences[i].end > offset) return i;
    }
    return 0;
  }

  static List<TtsSentence> splitSentences(String text) {
    if (text.trim().isEmpty) return const [];

    final sentences = <TtsSentence>[];
    final terminators = RegExp(r'[。！？；…\n]');
    // 结句后可能跟的收尾字符
    const closers = '”』」）)】》';

    var start = 0;
    var i = 0;
    while (i < text.length) {
      if (terminators.hasMatch(text[i])) {
        var end = i + 1;
        // 吃掉连续标点（！！！ …… 之类）
        while (end < text.length && terminators.hasMatch(text[end])) {
          end++;
        }
        // 吃掉紧跟的结句引号/括号
        while (end < text.length && closers.contains(text[end])) {
          end++;
        }
        _push(sentences, text, start, end);
        start = end;
        i = end;
        continue;
      }
      i++;
    }
    if (start < text.length) _push(sentences, text, start, text.length);
    return sentences;
  }

  static void _push(List<TtsSentence> out, String text, int start, int end) {
    final raw = text.substring(start, end);
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;

    // 太短的片段并进前一句：单独读「啊。」「好。」会显得一顿一顿的。
    // 但也别无限合并，否则一段长对白会合成一整句，进度无法定位。
    if (trimmed.length < 3 && out.isNotEmpty) {
      final prev = out.removeLast();
      final merged = text.substring(prev.start, end);
      if (merged.trim().length < 120) {
        out.add(TtsSentence(text: merged, start: prev.start, end: end));
        return;
      }
      out.add(prev);
    }
    // 前导空白不计入朗读内容，但 start 要保留原文位置
    final lead = raw.length - raw.trimLeft().length;
    final sentence = TtsSentence(
      text: trimmed,
      start: start + lead,
      end: start + lead + trimmed.length,
    );

    // 超长句硬切：没有标点的一大段（对话流、列表）会让「当前读到哪句」失去
    // 意义，而且系统 TTS 对超长输入的处理因引擎而异（有的直接截断）。
    // 这里按逗号等次级标点找切点，找不到就按字数切。
    if (trimmed.length > _maxSentenceChars) {
      out.addAll(_splitLong(sentence));
      return;
    }
    out.add(sentence);
  }

  /// 单句上限。超过就硬切，保证进度粒度和 TTS 输入的稳定性。
  static const int _maxSentenceChars = 90;

  /// 把超长句切成若干段，尽量落在次级标点上。
  static List<TtsSentence> _splitLong(TtsSentence sentence) {
    final text = sentence.text;
    final out = <TtsSentence>[];
    var cursor = 0;
    while (cursor < text.length) {
      var end = (cursor + _maxSentenceChars).clamp(0, text.length);
      if (end < text.length) {
        // 往回找最近的次级标点，让切点落在语义边界上
        final window = text.substring(cursor, end);
        final lastBreak = window.lastIndexOf(RegExp(r'[，、：,;]'));
        if (lastBreak > _maxSentenceChars * 0.5) {
          end = cursor + lastBreak + 1;
        }
      }
      final piece = text.substring(cursor, end).trim();
      if (piece.isNotEmpty) {
        final lead = text.substring(cursor, end).length -
            text.substring(cursor, end).trimLeft().length;
        out.add(TtsSentence(
          text: piece,
          start: sentence.start + cursor + lead,
          end: sentence.start + cursor + lead + piece.length,
        ));
      }
      cursor = end;
    }
    return out;
  }

  Future<void> play({int? fromSentence}) async {
    await _ensureInit();
    if (_sentences.isEmpty) return;
    if (fromSentence != null) {
      _index = fromSentence.clamp(0, _sentences.length - 1);
      _emitSentence();
    }
    _paused = false;
    await _speakCurrent();
  }

  void pause() {
    if (_sentences.isEmpty) return;
    if (_state == TtsPlaybackState.idle) return;
    _paused = true;
    _pausing = true;
    _tts.stop();
    _emitState(TtsPlaybackState.paused);
    // cancel 回调是异步的，给它一个窗口期；过了就重新放开闸门。
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      _pausing = false;
    });
  }

  /// 从暂停处继续朗读。
  ///
  /// 只要还有句子且不是正在读，就恢复 —— 不再死守 _state == paused。
  /// 通知栏按钮、耳机线控、来电结束后都走这条路。
  Future<void> resume() async {
    if (_sentences.isEmpty) return;
    if (_state == TtsPlaybackState.speaking) return;
    // 没暂停过（比如已经读到章末自然结束）就不该凭空开读。
    if (!_paused && _state == TtsPlaybackState.idle) return;
    _paused = false;
    await _speakCurrent();
  }

  Future<void> stop() async {
    _paused = false;
    _tts.stop();
    _index = 0;
    _emitState(TtsPlaybackState.idle);
    _emitSentence();
  }

  /// 是否处于暂停态（供 UI / 通知栏判断该显示播放还是暂停）。
  bool get isPaused => _paused;

  /// 跳到相邻的一句（负数是往前）。
  Future<void> skip(int delta) async {
    if (_sentences.isEmpty) return;
    final next = (_index + delta).clamp(0, _sentences.length - 1);
    if (next == _index) return;
    _tts.stop();
    _index = next;
    _emitSentence();
    if (_state != TtsPlaybackState.idle) {
      await _speakCurrent();
    }
  }

  /// 当前章是否已经读完最后一句。
  bool get atEnd => _sentences.isNotEmpty && _index >= _sentences.length - 1;

  Future<void> _speakCurrent() async {
    if (_index < 0 || _index >= _sentences.length) {
      _emitState(TtsPlaybackState.idle);
      return;
    }
    _emitState(TtsPlaybackState.speaking);
    await _tts.speak(_sentences[_index].text);
  }

  void _speakNext() {
    if (_index + 1 >= _sentences.length) {
      // 本章读完：不自动跳下一章（由阅读页决定），先停在 idle。
      _emitState(TtsPlaybackState.idle);
      return;
    }
    _index++;
    _emitSentence();
    _speakCurrent();
  }

  void _emitState(TtsPlaybackState next) {
    if (_state == next) return;
    _state = next;
    onStateChanged?.call(next);
  }

  void _emitSentence() {
    onSentenceChanged?.call(_index);
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await _tts.stop();
    } catch (_) {}
    onSentenceChanged = null;
    onStateChanged = null;
  }
}
