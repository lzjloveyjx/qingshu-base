/// 青枢 · 把 wenku8 的书转存成本地书（TXT），走基座自带的「本地书听书」。
///
/// 为什么不直接听在线书：番茄的听书要么用服务端作品音频（wenku8 没有），
/// 要么用系统朗读；而系统朗读那条路径只对**本地书**（localOnly）自动生效。
/// 所以先把正文抓成一本本地 TXT，导入后就与用户自己导入的书完全一致。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/media_item.dart';
import '../imported_book_store.dart';
import 'wenku8_source.dart';

/// 单章抓取失败时的重试次数（wenku8 偶尔会抽风）。
const int _kChapterRetries = 2;

/// 转存结果：成功返回导入的书，失败抛异常由调用方提示。
Future<ImportedBook> localizeToShelf(
  MediaItem item, {
  void Function(int done, int total)? onProgress,
}) async {
  final volumes = await fetchDirectory(item.id);
  final chapters = <Chapter>[
    for (final volume in volumes) ...volume,
  ];
  if (chapters.isEmpty) {
    throw StateError('目录为空，无法转存');
  }

  final buffer = StringBuffer();
  buffer.writeln(item.title);
  buffer.writeln();
  var done = 0;
  for (final chapter in chapters) {
    String text = '';
    for (var attempt = 0; attempt <= _kChapterRetries; attempt++) {
      text = await fetchChapterText(chapter);
      if (text.trim().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    done++;
    onProgress?.call(done, chapters.length);
    // 章节标题按「第N章」合成，保证 TXT 解析器能切出每一章；
    // 原标题附在后面，不丢信息。
    final name = chapter.title.trim().isEmpty
        ? '第' + done.toString() + '章'
        : '第' + done.toString() + '章 ' + chapter.title.trim();
    buffer.writeln(name);
    if (text.trim().isEmpty) {
      buffer.writeln('（本章正文抓取失败，可稍后重试）');
    } else {
      buffer.writeln(text.trim());
    }
    buffer.writeln();
  }
  final content = buffer.toString();
  if (content.trim().length < item.title.length + 8) {
    throw StateError('没有抓到任何正文，无法转存');
  }

  final bytes = Uint8List.fromList(utf8.encode(content));
  final safeName = item.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return ImportedBookStore.instance.importBytes(
    fileName: safeName + '.txt',
    bytes: bytes,
    decodedText: content,
    sourceByteLength: bytes.lengthInBytes,
  );
}
