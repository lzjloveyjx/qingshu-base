/// 青枢 · 书源偏好：决定「去哪找书」。
///
/// 只影响发现页（首页/搜索/详情/阅读），书架与阅读进度完全共享 —— 切源不会
/// 让已加入书架的书消失。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 支持的书源。
enum BookSource {
  wenku8('wenku8', '轻小说文库（wenku8）'),
  lightnovel('lightnovel', '轻之国度');

  const BookSource(this.id, this.label);
  final String id;
  final String label;

  static BookSource fromId(String? value) {
    for (final s in BookSource.values) {
      if (s.id == value) return s;
    }
    return BookSource.wenku8;
  }
}

class BookSourcePreference {
  BookSourcePreference._();
  static final BookSourcePreference instance = BookSourcePreference._();

  static const _key = 'book_source_id';

  /// 当前书源；变更时通知首页/搜索重载。
  final ValueNotifier<BookSource> source =
      ValueNotifier<BookSource>(BookSource.wenku8);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      source.value = BookSource.fromId(sp.getString(_key));
    } catch (_) {
      // 读失败保持默认 wenku8。
    }
  }

  Future<void> set(BookSource value) async {
    if (source.value == value) return;
    source.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, value.id);
    } catch (_) {}
  }
}