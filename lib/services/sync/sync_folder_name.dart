import 'sync_transport.dart';

// 【青枢·不要改名】这是云同步在网盘里创建目录时用的实际名字。
// 改成「青枢-云同步」会让已存在的同步目录对不上（sync_folder_picker 里
// 有「是否等于默认名」的判断），用户的历史同步数据就找不到了。
// 要改必须同时做一次目录迁移，不能只改这个字符串。
const defaultSyncFolderName = '什锦铺-云同步';

void validateSyncFolderName(String name) {
  if (name.trim().isEmpty ||
      name.length > 64 ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(name)) {
    throw const SyncFailure('请输入有效目录名，不能包含斜线或控制字符');
  }
}
