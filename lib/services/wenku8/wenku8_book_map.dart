/// wenku8 详情页 URL → 本地书 id 的持久化映射。
///
/// 内存 Map 在 app 重启后丢失会导致同一本书被重复转存；这里用 SharedPreferences
/// 落盘，打开书与加入书架共用，保证幂等。
library;

import 'package:shared_preferences/shared_preferences.dart';

class Wenku8BookMap {
  Wenku8BookMap._();
  static final Wenku8BookMap instance = Wenku8BookMap._();

  static const _prefix = 'wenku8_local_book:';
  final Map<String, String> _memory = <String, String>{};
  bool _loaded = false;

  Future<void> _ensure() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    for (final key in sp.getKeys().where((k) => k.startsWith(_prefix))) {
      final value = sp.getString(key);
      if (value != null) _memory[key.substring(_prefix.length)] = value;
    }
    _loaded = true;
  }

  Future<String?> get(String sourceUrl) async {
    await _ensure();
    return _memory[sourceUrl];
  }

  Future<void> put(String sourceUrl, String localBookId) async {
    await _ensure();
    _memory[sourceUrl] = localBookId;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefix + sourceUrl, localBookId);
  }
}