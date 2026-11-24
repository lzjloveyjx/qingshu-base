import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/services/logging/logger.dart';

/// 内置 TTS 音色。
///
/// 两个都是 piper 的 medium 模型（int8 量化，各 17.8MB）：
///   • 小雅  zh_CN-xiao_ya-medium  女声，BZNSYP 数据集训练
///   • 超文  zh_CN-chaowen-medium  男声
///
/// 为什么换成 piper 而不是原来的 vits-icefall-zh-aishell3：
///   aishell3 是「能出声」档，音色偏机械、腔调平；piper 是为朗读优化的
///   模型，重音和停顿更自然，而且 int8 量化后体积只有 17.8MB —— 两个
///   音色加起来（39.5MB）只比原来单音色（31MB）多 8.5MB。
class TtsVoice {
  const TtsVoice({required this.id, required this.label, required this.model});

  final String id;
  final String label;

  /// assets 下的目录名。
  final String model;

  static const TtsVoice xiaoYa = TtsVoice(
    id: 'xiao_ya',
    label: '小雅 · 女声',
    model: 'xiao_ya',
  );

  static const TtsVoice chaoWen = TtsVoice(
    id: 'chaowen',
    label: '超文 · 男声',
    model: 'chaowen',
  );

  static const List<TtsVoice> values = [xiaoYa, chaoWen];

  static TtsVoice byId(String id) {
    for (final v in values) {
      if (v.id == id) return v;
    }
    return xiaoYa;
  }
}

/// 内置 TTS 模型：从随包 assets 释放到磁盘。
///
/// 为什么这么做而不是直接读 asset：
/// sherpa-onnx 的 C 接口要的是**文件系统路径**（它自己在 native 层 fopen），
/// 拿不到 Flutter asset 的字节流。所以第一次用的时候把文件拷到应用私有目录。
class TtsModelManager {
  TtsModelManager();

  /// 每个音色必须有的三个文件。
  static const List<String> _required = ['lexicon.txt', 'tokens.txt'];

  Directory? _root;

  /// 某个音色的磁盘目录。
  Future<Directory> voiceDir(TtsVoice voice) async {
    final root = await _appSupportDir();
    return Directory('${root.path}/${voice.model}');
  }

  Future<Directory> _appSupportDir() async {
    if (_root != null) return _root!;
    final dir = await getApplicationSupportDirectory();
    final ttsRoot = Directory('${dir.path}/tts');
    if (!await ttsRoot.exists()) {
      await ttsRoot.create(recursive: true);
    }
    _root = ttsRoot;
    return ttsRoot;
  }

  /// 音色是否已释放到磁盘且完整。
  Future<bool> isReady(TtsVoice voice) async {
    final dir = await voiceDir(voice);
    if (!await dir.exists()) return false;
    for (final name in _required) {
      if (!await File('${dir.path}/$name').exists()) return false;
    }
    // onnx 文件名随音色变（zh_CN-xxx-medium.onnx），得扫一下。
    final onnx = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.onnx'))
        .toList();
    if (onnx.isEmpty) return false;
    return await (onnx.first as File).length() > 10 * 1024 * 1024;
  }

  /// 释放某个音色到磁盘。已就绪时立即返回。
  Future<void> ensureReady(
    TtsVoice voice, {
    void Function(double progress)? onProgress,
  }) async {
    if (await isReady(voice)) {
      onProgress?.call(1);
      return;
    }
    final dir = await voiceDir(voice);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    // 扫 assets 目录，把所有文件都拷出来（onnx 名字不固定）。
    final assetDir = 'assets/tts/${voice.model}';
    final manifest = await rootBundle.loadString('$assetDir/manifest.txt');
    final names = manifest
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();

    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      final data = await rootBundle.load('$assetDir/$name');
      await File('${dir.path}/$name').writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      onProgress?.call((i + 1) / names.length);
      KazumiLogger().i('TTS released: ${voice.id}/$name');
    }

    if (!await isReady(voice)) {
      throw Exception('模型释放后校验失败');
    }
  }

  /// 删掉已释放的模型。
  Future<void> remove() async {
    for (final v in TtsVoice.values) {
      final dir = await voiceDir(v);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}
