import 'package:hive_ce/hive.dart';

import 'package:kazumi/modules/novel/novel_shelf_module.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 小说书架 / 阅读进度的数据访问层。
///
/// 和动漫侧的 HistoryRepository 是两套东西，故意不合并：动漫的 History 绑死
/// 在 BangumiItem（有 id、有季度、有弹幕）上，而小说的书根本没有 Bangumi 条目，
/// 硬塞进去要么造一个假 BangumiItem（污染收藏/同步/统计），要么把 History 改成
/// 泛型（改动面大到不值得）。
///
/// 所有写入都走同一个 box，读的时候按需过滤，因为数据量很小（几百条量级），
/// 没必要为「书架」和「历史」建两个索引。
class NovelShelfRepository {
  NovelShelfRepository({Box<NovelBookRecord>? box})
      : _box = box ?? GStorage.novelShelf;

  final Box<NovelBookRecord> _box;

  /// 书架：按加入时间倒序。
  List<NovelBookRecord> shelf() {
    final items = _box.values.where((r) => r.onShelf).toList();
    items.sort((a, b) => b.addedAtMs.compareTo(a.addedAtMs));
    return items;
  }

  /// 阅读历史：按最近阅读时间倒序，只保留真正读过的。
  List<NovelBookRecord> history() {
    final items = _box.values.where((r) => r.hasProgress).toList();
    items.sort((a, b) => b.lastReadAtMs.compareTo(a.lastReadAtMs));
    return items;
  }

  NovelBookRecord? find(String pluginName, String bookKey) {
    return _box.get(NovelBookRecord.keyOf(pluginName, bookKey));
  }

  bool isOnShelf(String pluginName, String bookKey) {
    return find(pluginName, bookKey)?.onShelf ?? false;
  }

  /// 加入/移出书架。书还没读过也能加，此时只存身份信息。
  Future<bool> toggleShelf({
    required String pluginName,
    required String bookKey,
    required String title,
    String cover = '',
    String author = '',
  }) async {
    final key = NovelBookRecord.keyOf(pluginName, bookKey);
    final existing = _box.get(key);
    if (existing == null) {
      await _box.put(
        key,
        NovelBookRecord(
          pluginName: pluginName,
          bookKey: bookKey,
          title: title,
          cover: cover,
          author: author,
          onShelf: true,
          addedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return true;
    }
    existing.onShelf = !existing.onShelf;
    if (existing.onShelf) {
      existing.addedAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    await _box.put(key, existing);
    return existing.onShelf;
  }

  /// 记录一次阅读进度。
  ///
  /// 同时补全书名/封面/作者：用户可能是从搜索页点进来的，那时这些信息
  /// 在手上；写进度时顺手更新，历史列表就不用再联网取一次。
  Future<void> recordProgress({
    required String pluginName,
    required String bookKey,
    required String title,
    required int roadIndex,
    required int chapterIndex,
    required String chapterUrl,
    required String chapterTitle,
    String cover = '',
    String author = '',
    int chapterCount = 0,
    int pageIndex = 0,
    int pageAnchor = 0,
  }) async {
    final key = NovelBookRecord.keyOf(pluginName, bookKey);
    var record = _box.get(key);
    if (record == null) {
      record = NovelBookRecord(
        pluginName: pluginName,
        bookKey: bookKey,
        title: title,
      );
      // 没加书架就只是「读过」，onShelf 保持 false。
    }
    record.title = title;
    if (cover.isNotEmpty) record.cover = cover;
    if (author.isNotEmpty) record.author = author;
    record.lastRoadIndex = roadIndex;
    record.lastChapterIndex = chapterIndex;
    record.lastChapterUrl = chapterUrl;
    record.lastChapterTitle = chapterTitle;
    record.lastReadAtMs = DateTime.now().millisecondsSinceEpoch;
    if (chapterCount > 0) record.chapterCount = chapterCount;
    record.lastPageIndex = pageIndex;
    record.lastPageAnchor = pageAnchor;
    await _box.put(key, record);
  }

  Future<void> remove(String pluginName, String bookKey) async {
    await _box.delete(NovelBookRecord.keyOf(pluginName, bookKey));
  }

  Future<void> clearHistory() async {
    // 只清进度，不动书架：用户清历史记录不该把书架也清空。
    for (final record in _box.values.toList()) {
      if (!record.hasProgress) continue;
      record.lastReadAtMs = 0;
      record.lastRoadIndex = 0;
      record.lastChapterIndex = 0;
      record.lastChapterUrl = '';
      record.lastChapterTitle = '';
      record.lastPageIndex = 0;
      record.lastPageAnchor = 0;
      if (record.onShelf) {
        await _box.put(record.key, record);
      } else {
        // 既不在书架又没进度 → 这条记录没意义了
        await _box.delete(record.key);
      }
    }
  }
}
