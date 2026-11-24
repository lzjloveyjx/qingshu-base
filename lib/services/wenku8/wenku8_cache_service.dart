/// 青枢 · wenku8 全书缓存服务。
///
/// 加入书架后触发，用 Android 前台服务（dataSync 语义的常驻通知）保活，
/// 抓取仍在主 isolate 跑（flutter_foreground_task 的回调 isolate 无法访问
/// Kazumi 插件），服务只负责通知栏进度与 wakelock 保活。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'wenku8_localize.dart' as localize;

/// 缓存任务状态（供 UI 显示）。
class CacheTaskState {
  const CacheTaskState({required this.bookId, this.done = 0, this.total = 0, this.running = false, this.message = ''});
  final String bookId;
  final int done;
  final int total;
  final bool running;
  final String message;
}

/// 全书缓存管理器（单例）。同一时间只跑一本书，串行抓章。
class Wenku8CacheService {
  Wenku8CacheService._();
  static final Wenku8CacheService instance = Wenku8CacheService._();

  static const _channelId = 'qingshu_cache_channel';
  static const _channelName = '书架缓存';
  static const _channelDesc = '正在后台缓存书架小说的章节';

  final ValueNotifier<CacheTaskState?> state = ValueNotifier<CacheTaskState?>(null);
  bool _serviceRunning = false;
  bool _active = false;

  Future<void> _initForeground() async {
    if (!Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _channelId,
        channelName: _channelName,
        channelDescription: _channelDesc,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    FlutterForegroundTask.initCommunicationPort();
  }

  Future<void> _startForeground(String title) async {
    if (!Platform.isAndroid || _serviceRunning) return;
    await _initForeground();
    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: '准备缓存…',
      callback: _foregroundCallback,
    );
    _serviceRunning = result is ServiceRequestSuccess;
  }

  Future<void> _notify(String title, String text) async {
    if (!_serviceRunning) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  Future<void> _stopForeground() async {
    if (!_serviceRunning) return;
    await FlutterForegroundTask.stopService();
    _serviceRunning = false;
  }

  /// 启动/续跑一本书的全书缓存。重复调用同一本书会被忽略。
  Future<void> start(String bookId, {String title = '后台缓存'}) async {
    if (_active) return;
    await localize.ensureStates();
    if (!localize.hasPendingChapters(bookId)) return;
    _active = true;
    state.value = CacheTaskState(bookId: bookId, running: true, message: '准备中…');
    try {
      await _startForeground(title);
      await localize.cacheWholeBook(
        bookId,
        onProgress: (done, total) {
          state.value = CacheTaskState(bookId: bookId, done: done, total: total, running: true,
            message: done.toString() + '/' + total.toString());
          unawaited(_notify(title, '已缓存 ' + done.toString() + '/' + total.toString() + ' 章'));
        },
        shouldStop: () => !_active,
      );
    } catch (e) {
      state.value = CacheTaskState(bookId: bookId, running: false, message: e.toString());
    } finally {
      _active = false;
      await _stopForeground();
      final last = state.value;
      if (last != null) {
        state.value = CacheTaskState(bookId: bookId, done: last.done, total: last.total,
          running: false, message: '缓存完成');
      }
    }
  }

  void stop() => _active = false;
}

@pragma('vm:entry-point')
void _foregroundCallback() => FlutterForegroundTask.setTaskHandler(_CacheTaskHandler());

class _CacheTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  void onNotificationButtonPressed(String id) {}
  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
  @override
  void onNotificationDismissed() {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
  @override
  void onReceiveData(Object data) {}
}