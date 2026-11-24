// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'novel_shelf_module.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class NovelBookRecordAdapter extends TypeAdapter<NovelBookRecord> {
  @override
  final typeId = 9;

  @override
  NovelBookRecord read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NovelBookRecord(
      pluginName: fields[0] as String,
      bookKey: fields[1] as String,
      title: fields[2] as String,
      cover: fields[3] as String,
      author: fields[4] as String,
      lastRoadIndex: fields[5] as int,
      lastChapterIndex: fields[6] as int,
      lastChapterUrl: fields[7] as String,
      lastChapterTitle: fields[8] as String,
      lastReadAtMs: fields[9] as int,
      chapterCount: fields[10] as int,
      onShelf: fields[11] as bool,
      addedAtMs: fields[12] as int,
      // 13/14 是后加的字段：老记录里没有这两项，必须容错成 0，
      // 否则升级后读旧书架会抛 null check。
      lastPageIndex: (fields[13] as int?) ?? 0,
      lastPageAnchor: (fields[14] as int?) ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, NovelBookRecord obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.pluginName)
      ..writeByte(1)
      ..write(obj.bookKey)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.cover)
      ..writeByte(4)
      ..write(obj.author)
      ..writeByte(5)
      ..write(obj.lastRoadIndex)
      ..writeByte(6)
      ..write(obj.lastChapterIndex)
      ..writeByte(7)
      ..write(obj.lastChapterUrl)
      ..writeByte(8)
      ..write(obj.lastChapterTitle)
      ..writeByte(9)
      ..write(obj.lastReadAtMs)
      ..writeByte(10)
      ..write(obj.chapterCount)
      ..writeByte(11)
      ..write(obj.onShelf)
      ..writeByte(12)
      ..write(obj.addedAtMs)
      ..writeByte(13)
      ..write(obj.lastPageIndex)
      ..writeByte(14)
      ..write(obj.lastPageAnchor);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NovelBookRecordAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
