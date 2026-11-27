// ignore_for_file: library_private_types_in_public_api

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/player/playback_cache_policy.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

final class _OwnedPlayer {
  _OwnedPlayer(this.player);

  final Player player;
  Future<void>? _disposeFuture;

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerPlaybackController: failed to dispose media player',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.isLocalPlayback,
  });

  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final bool Function() isLocalPlayback;
  late final PlaybackCachePolicy cachePolicy = PlaybackCachePolicy(
    isLocalPlayback: isLocalPlayback,
    currentPlayer: () => mediaPlayer,
  );

  _OwnedPlayer? _ownedPlayer;
  Player? get mediaPlayer => _ownedPlayer?.player;
  VideoController? videoController;

  final AsyncSerialQueue _prefetchWrites = AsyncSerialQueue();
  bool _prefetchSuspendWanted = false;

  /// 最近一次 open 用的请求头。运行中因为要切软解而重开时得原样带上，
  /// 否则带 Referer 校验的源会直接 403。
  Map<String, String> _lastHttpHeaders = const <String, String>{};

  /// 是否因为开超分而改过解码器。关掉超分时要能还原，否则会一直停在
  /// copy-back 上（虽然仍走硬解，但每帧多一次拷贝）。
  bool _hwdecAdjustedForSuperRes = false;

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 历史记录传入的 offset
  int startOffset = 0;

  /// 当前超分辨率模式
  @observable
  SuperResolutionMode superResolutionMode = SuperResolutionMode.off;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(_OwnedPlayer candidate) async {
    if (identical(_ownedPlayer, candidate)) {
      return candidate.player;
    }
    await candidate.dispose();
    return null;
  }

  Future<void> _cancelDebugInfo() async {
    try {
      await debug.cancel();
    } catch (_) {}
  }

  @action
  void resetForInit() {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    startOffset = 0;
  }

  /// 本次会话是否从距结尾 [nearEndWatchedThreshold] 以内的位置起播。
  /// 这样的"播放完成"并非真正看完，应从头重播而非切下一集
  bool get resumedNearEnd {
    if (startOffset <= 0 || duration <= Duration.zero) {
      return false;
    }
    return Duration(seconds: startOffset) >= duration - nearEndWatchedThreshold;
  }

  /// 从头重播当前视频。[startOffset] 在重播落地后才归零，
  /// 避免自动连播在此期间抢先触发
  Future<void> restartFromBeginning() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.seek(Duration.zero);
      if (!isCurrentPlayer(player)) {
        return;
      }
      await player.play();
      startOffset = 0;
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to restart from beginning', error: e);
    }
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  /// Android blocks network access for backgrounded apps; a prefetching
  /// demuxer then burns through ffmpeg's reconnect/segment retries and marks
  /// the stream EOF, leaving playback permanently stuck once foregrounded.
  /// Suspending zeroes the readahead window so no new requests are issued
  /// while buffered data stays available; restore values are mpv defaults,
  /// which media_kit leaves untouched. Writes are serialized and apply the
  /// latest requested state, so rapid lifecycle flips cannot reorder.
  Future<void> setPrefetchSuspended(bool suspended) async {
    if (!Platform.isAndroid) {
      return;
    }
    _prefetchSuspendWanted = suspended;
    await _prefetchWrites.run(() async {
      final wanted = _prefetchSuspendWanted;
      final player = mediaPlayer;
      if (player == null) {
        return;
      }
      try {
        final pp = player.platform as NativePlayer;
        await pp.setProperty('cache-secs', wanted ? '0' : '36000');
        if (!isCurrentPlayer(player)) {
          return;
        }
        await pp.setProperty('demuxer-readahead-secs', wanted ? '0' : '1');
      } catch (e) {
        KazumiLogger().w(
          'PlayerController: failed to ${wanted ? 'suspend' : 'resume'} demuxer prefetch',
          error: e,
        );
      }
    });
  }

  Future<Player?> createVideoController(
    Map<String, String> httpHeaders,
    bool adBlockerEnabled, {
    required bool Function() canInstall,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
  }) async {
    startOffset = offset;
    _lastHttpHeaders = Map<String, String>.from(httpHeaders);
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultSuperResolutionMode),
    );
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting(SettingsKeys.androidEnableOpenSLES);
    hardwareDecoder = GStorage.getSetting(SettingsKeys.hardwareDecoder);
    autoPlay = GStorage.getSetting(SettingsKeys.autoPlay);
    playerDebugMode = GStorage.getSetting(SettingsKeys.playerDebugMode);

    if (!canInstall()) {
      return null;
    }
    final candidate = _OwnedPlayer(
      Player(
        configuration: PlayerConfiguration(
          bufferSize: cachePolicy.bufferSize,
          osc: false,
          logLevel: MPVLogLevel.values[debug.playerLogLevel],
          // 青枢：Kazumi 用的 media-kit 是 Predidit 的分支（1.1.11 + 私有补丁），
          // 主壳用的是 pub.dev 的 1.2.6，没有 adBlocker 参数。广告屏蔽对
          // 规则源播放本来就没用（视频直链由规则解析），去掉即可。
        ),
      ),
    );
    final player = candidate.player;
    if (!canInstall()) {
      await candidate.dispose();
      return null;
    }
    _ownedPlayer = candidate;
    cachePolicy.startWatching();

    try {
      debug.playerLog.clear();
      await debug.setup(
        player,
        isCurrentPlayer: isCurrentPlayer,
        playerDebugMode: playerDebugMode,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      var pp = player.platform as NativePlayer;
      // media-kit 默认启用硬盘作为双重缓存，这可以维持大缓存的前提下减轻内存压力
      // media-kit 内部硬盘缓存目录按照 Linux 配置，这导致该功能在其他平台上被损坏
      // 该设置可以在所有平台上正确启用双重缓存
      await pp.setProperty("demuxer-cache-dir", await getPlayerTempPath());
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await cachePolicy.apply();
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await pp.setProperty("af", "scaletempo2=max-speed=8");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      if (Platform.isAndroid) {
        await pp.setProperty("volume-max", "100");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
        if (androidEnableOpenSLES) {
          await pp.setProperty("ao", "opensles");
        } else {
          await pp.setProperty("ao", "audiotrack");
        }
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
      if (proxyEnable) {
        final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
        final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
        if (formattedProxy != null) {
          await pp.setProperty("http-proxy", formattedProxy);
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
        }
      } else if (SystemProxyService.isActive) {
        final proxy = SystemProxyService.proxyFor('https');
        if (proxy != null) {
          await pp.setProperty("http-proxy", 'http://${proxy.$1}:${proxy.$2}');
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          KazumiLogger().i('Player: 跟随系统代理 http://${proxy.$1}:${proxy.$2}');
        }
      }

      await player.setAudioTrack(
        AudioTrack.auto(),
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      String? videoRenderer;
      if (Platform.isAndroid) {
        final String androidVideoRenderer =
            GStorage.getSetting(SettingsKeys.androidVideoRenderer);

        if (androidVideoRenderer == 'auto') {
          // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
          // GPU-NEXT 需要 Vulkan 1.2 支持
          // 避免 Android 13 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
          final int androidSdkVersion =
              await PlatformEnvironmentService.getAndroidSdkVersion();
          if (!isCurrentPlayer(player)) {
            return await _discardIfNotCurrent(candidate);
          }
          if (androidSdkVersion >= 34) {
            videoRenderer = 'gpu-next';
          } else {
            videoRenderer = 'gpu';
          }
        } else {
          videoRenderer = androidVideoRenderer;
        }
      }

      if (videoRenderer == 'mediacodec_embed') {
        hAenable = true;
        hardwareDecoder = 'mediacodec';
        superResolutionMode = SuperResolutionMode.off;
      }

      // 【青枢】超分辨率要真的生效，硬解必须关掉。
      //
      // Anime4K 是 mpv 的 GLSL 用户着色器，pipline 只在 vo=gpu/gpu-next
      // 且帧能被当纹理采样的前提下跑。Android 上 hwdec=auto-safe 会命中
      // MediaCodec 直通（surface 直出），帧根本不经过 GL —— 这时
      // `change-list glsl-shaders set` 会返回成功、日志也没有报错，但画面
      // 一模一样。表现就是「超分辨率按钮没生效」。
      //
      // 所以开着超分时强制软件解码 + 指定的渲染器。代价是功耗和发热，
      // 这也是为什么这一步只在用户真的选了效率档/质量档时才做。
      if (Platform.isAndroid &&
          superResolutionMode != SuperResolutionMode.off) {
        final preferred = _copyBackHwdec(hardwareDecoder);
        if (preferred != hardwareDecoder) {
          KazumiLogger().i(
            'SuperResolution: hwdec $hardwareDecoder -> $preferred '
            '（直通解码的帧不是纹理，Anime4K 取不到）',
          );
        }
        hAenable = preferred != 'no';
        hardwareDecoder = preferred;
        _hwdecAdjustedForSuperRes = true;
      }

      videoController ??= VideoController(
        player,
        configuration: VideoControllerConfiguration(
          vo: videoRenderer,
          enableHardwareAcceleration: hAenable,
          // 【青枢】这两行是 Kazumi 有意为之的兼容性设置，不能删。
          //
          // enableAndroidSurfaceProducer=false 让 Android 走保守的
          // AndroidExternalTexture 渲染路径。关掉 SurfaceProducer 是因为
          // 它在不少机型上渲染不出画面（mpv 打开了 URL、时长却是 00:00、
          // 日志无报错）。androidAttachSurfaceAfterVideoParameters=false
          // 与它配套：先建 surface，不等视频参数。
          //
          // 前提是依赖必须换成 Predidit/media-kit 分支 —— pub.dev 的
          // media_kit_video 2.0.1 根本没有这个开关（VideoOutput.java 里
          // 直接 createSurfaceProducer）。见 pubspec.yaml 的说明。
          enableAndroidSurfaceProducer: false,
          hwdec: hAenable ? hardwareDecoder : 'no',
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      player.setPlaylistMode(PlaylistMode.none);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      bool showPlayerError = GStorage.getSetting(SettingsKeys.showPlayerError);
      player.stream.error.listen((event) {
        if (isCurrentPlayer(player)) {
          final actionableMessage = PlayerErrorMapper.toActionableMessage(
            event,
            isBuffering: playerBuffering,
          );
          if (actionableMessage != null) {
            KazumiDialog.showToast(
                message: actionableMessage, showActionButton: true);
          } else if (showPlayerError) {
            KazumiDialog.showToast(
                message: '播放器内部错误 ${event.toString()} ${videoUrl()}',
                duration: const Duration(seconds: 5),
                showActionButton: true);
          }
        }
        // 青枢：这条日志原来叫 "Player intent error"，容易和 Android
        // Intent 混淆，其实是 mpv 的 error 流。改成能直接看懂的说法，
        // 并把 URL 放在原因后面 —— 读日志时先看到错什么。
        KazumiLogger().e(
          'PlayerController: 播放出错 ${videoUrl()}',
          error: event,
        );
      });

      // 【青枢】这里**不**应用着色器。
      //
      // open 之前 vo 还是 'null'（media_kit 在 surface 建好前设的占位），
      // 此时把 glsl-shaders 写进去，mpv 只是记下属性值，并没有 GL 上下文
      // 去编译它 —— 日志上「applied ... glsl-shaders=/...glsl」看着成功，
      // 实际一帧都没跑。用户看到的就是「开了质量档没效果」。
      //
      // 实测日志：mode=效率档 ... vo=null hwdec=mediacodec-copy
      //   → vo=null 就是证据。
      //
      // 正确时机是 open 之后（见下面 open 完那段）。

      if (videoSourceFormat == VideoSourceFormat.hls) {
        await pp.setProperty('demuxer-lavf-format', 'hls');
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      // 【青枢】诊断：记录真的交给 mpv 的信息。
      // 现象是「一直转圈、时长 00:00、日志无报错」，可能是 open 抛错、
      // 也可能是 open 成功但解码不出帧。这几行能区分两者。
      final String hwdecDesc = hAenable ? hardwareDecoder : "no";
      KazumiLogger().i(
        'PlayerOpen: url=${videoUrl()} vo=$videoRenderer hwdec=$hwdecDesc '
        'superres=${superResolutionMode.label} '
        'offset=$offset headers=${httpHeaders.keys.toList()}',
      );
      final sw = Stopwatch()..start();
      await player.open(
        Media(videoUrl(),
            start: Duration(seconds: offset), httpHeaders: httpHeaders),
        play: autoPlay,
      );
      sw.stop();
      KazumiLogger().i(
        'PlayerOpen: returned after ${sw.elapsedMilliseconds}ms '
        'duration=${player.state.duration} width=${player.state.width} height=${player.state.height}',
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 【青枢】open 完成后 vo 才会从 'null' 变成真正的 gpu / gpu-next，
      // 这时挂 glsl-shaders 才会被真正编译。等一小会儿让它就位。
      if (Platform.isAndroid &&
          superResolutionMode != SuperResolutionMode.off) {
        await _waitForGlReady(pp);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
        await setShader(superResolutionMode, player: player);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      if (cachePolicy.networkAutomatic) {
        KazumiDialog.showToast(message: '移动数据下已自动开启低内存模式，可在播放设置中改为始终关闭');
      }

      return player;
    } catch (error, stackTrace) {
      if (identical(_ownedPlayer, candidate)) {
        cachePolicy.stopWatching();
        _ownedPlayer = null;
        videoController = null;
      }
      await candidate.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// 等到 mpv 的 vo 真正就绪（不再是 media_kit 的 'null' 占位）。
  ///
  /// media_kit 在 surface 建好之前把 vo 设成 'null'，此时挂 glsl-shaders
  /// 不会编译。open 之后通常几十毫秒内就绪，这里轮询到就绪或超时为止。
  Future<void> _waitForGlReady(NativePlayer pp) async {
    for (var i = 0; i < 40; i++) {
      String vo = '';
      try {
        vo = (await pp.getProperty('vo')).trim();
      } catch (_) {}
      if (vo.isNotEmpty && vo != 'null') return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 把「直通」硬解换成「拷贝回内存」的硬解。
  ///
  /// Anime4K 是 GLSL 用户着色器，要拿到帧像素才能采样。Android 上
  /// hwdec=auto-safe 命中的是 MediaCodec 直通（surface 直出，帧不经过
  /// 内存），着色器静默失效 —— 这就是「超分辨率按钮没生效」的真正原因。
  ///
  /// 正确的解法不是退回纯软解（那样 1080p 解码会烫手掉帧），而是用
  /// copy-back 变体：仍然是硬件解码，只是把结果拷回系统内存当纹理用。
  /// 代价是每帧一次拷贝，比软解轻得多。
  static String _copyBackHwdec(String configured) {
    final value = configured.trim();
    if (value.isEmpty || value == 'no') {
      return 'no';
    }
    if (value.endsWith('-copy')) {
      return value;
    }
    // mpv 的特殊值只有 no / auto / auto-safe / auto-copy / yes（yes 是
    // auto 的旧别名）。没有 auto-safe-copy 这种东西 —— 硬拼会变成非法
    // 参数，mpv 直接忽略，等于没切。所以 auto 系列统一落到 auto-copy。
    if (value == 'auto' || value == 'auto-safe' || value == 'yes') {
      return 'auto-copy';
    }
    return '$value-copy';
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      // 【青枢】诊断：超分辨率「点了没反应」时，先要区分三种情况：
      //   a) 着色器目录是空的（copyShadersToExternalDirectory 没跑到/失败）
      //   b) mpv 不认这个 vo（mediacodec_embed 不支持 glsl-shaders）
      //   c) 命令发下去了但着色器编译失败（Anime4K 需要 GLSL 支持）
      // 先把路径和目录内容写进日志，用户截图就能定位。
      final shaderDir = shaderAssetService.shadersDirectory;
      final dirExists = await shaderDir.exists();
      final fileCount = dirExists
          ? shaderDir.listSync().whereType<File>().length
          : 0;
      String? vo;
      String? hwdec;
      try {
        vo = await pp.getProperty('vo');
        // hwdec 是配置项，hwdec-current 才是真正在用的解码器。
        hwdec = await pp.getProperty('hwdec-current');
        if (hwdec.trim().isEmpty) {
          hwdec = await pp.getProperty('hwdec');
        }
      } catch (_) {}
      KazumiLogger().i(
        'SuperResolution: mode=${mode.label} dir=${shaderDir.path} '
        'exists=$dirExists files=$fileCount vo=$vo hwdec=$hwdec',
      );
      if (!dirExists || fileCount == 0) {
        KazumiLogger().e('SuperResolution: 着色器目录为空，超分不会生效');
        superResolutionMode = mode;
        return;
      }
      if (Platform.isAndroid && mode != SuperResolutionMode.off) {
        // 【青枢】mediacodec_embed 是硬解直出，压根没有 GL 管线，
        // glsl-shaders 只会静默失效。除此之外的 vo（gpu / gpu-next /
        // 初始化中的 null）都不拦 —— 尤其是 'null'，那是 media_kit 在
        // surface 还没就绪时的正常占位，不是错误。
        final currentVo = (vo ?? '').trim();
        if (currentVo == 'mediacodec_embed') {
          KazumiLogger().e(
            'SuperResolution: vo=mediacodec_embed 不跑 GLSL 着色器。'
            '请把「视频渲染器」改为 auto / gpu / gpu-next',
          );
          superResolutionMode = mode;
          return;
        }
        // 直通硬解（不带 -copy）会让着色器静默失效；copy-back 变体既能
        // 保留硬件解码，帧又能被 GL 当纹理采样。auto-safe 也可能命中
        // 直通，所以以「回读到的值是否带 -copy」作为判断依据。
        //
        // 另外：光 setProperty('hwdec', ...) 是不够的 —— mpv 不会在播放
        // 中途重建解码器，日志上看着切换成功，画面照样是原来的路径。必须
        // 带着新参数重新 open 一次当前 URL。这里保留播放位置与请求头。
        // 注意：正常起播路径不会走到这里 —— open 之前已经把 hwdec 设成
        // copy-back 了。只有「播放中途手动切档」时才可能还是直通。
        final bool passthrough =
            hwdec != null && hwdec.isNotEmpty && !hwdec.endsWith('-copy') &&
                hwdec != 'no' &&
                hwdec != 'null';
        if (passthrough) {
          final position = currentPlayer.state.position;
          final target = _copyBackHwdec(
            GStorage.getSetting(SettingsKeys.hardwareDecoder),
          );
          KazumiLogger().i(
            'SuperResolution: hwdec=$hwdec 是直通解码，重开并切到 $target',
          );
          await pp.setProperty('hwdec', target);
          await currentPlayer.open(
            Media(
              videoUrl(),
              start: position,
              httpHeaders: _lastHttpHeaders,
            ),
            play: currentPlayer.state.playing,
          );
          _hwdecAdjustedForSuperRes = true;
        }
      }
      // 关掉超分时把被强制关掉的硬解还原回来，并同样靠重开生效。
      if (Platform.isAndroid &&
          mode == SuperResolutionMode.off &&
          _hwdecAdjustedForSuperRes) {
        _hwdecAdjustedForSuperRes = false;
        hAenable = GStorage.getSetting(SettingsKeys.hAenable);
        hardwareDecoder = hAenable
            ? GStorage.getSetting(SettingsKeys.hardwareDecoder)
            : 'no';
        try {
          final position = currentPlayer.state.position;
          KazumiLogger().i(
            'SuperResolution: 关闭超分，恢复硬解 hwdec=$hardwareDecoder',
          );
          await pp.setProperty('hwdec', hAenable ? hardwareDecoder : 'no');
          await currentPlayer.open(
            Media(
              videoUrl(),
              start: position,
              httpHeaders: _lastHttpHeaders,
            ),
            play: currentPlayer.state.playing,
          );
        } catch (e) {
          KazumiLogger().w('SuperResolution: 恢复硬解失败', error: e);
        }
      }
      switch (mode) {
        case SuperResolutionMode.efficiency:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShadersLite,
            ),
          ]);
          break;
        case SuperResolutionMode.quality:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShaders,
            ),
          ]);
          break;
        case SuperResolutionMode.off:
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
          break;
      }
      superResolutionMode = mode;
      // 回读 mpv 里真正的 glsl-shaders —— 命令发出去不代表加载成功，
      // 只有回读非空才说明这套着色器真的挂上了。
      String? applied;
      try {
        applied = await pp.getProperty('glsl-shaders');
      } catch (_) {}
      // vo 再读一次：如果还是 'null'，说明这次也没生效 —— 明确报出来，
      // 不要再用「applied」这种让人以为成功的措辞。
      String voAfter = '';
      try {
        voAfter = (await pp.getProperty('vo')).trim();
      } catch (_) {}
      final bool loaded = (applied ?? '').trim().isNotEmpty;
      if (loaded && voAfter.isNotEmpty && voAfter != 'null') {
        KazumiLogger().i(
          'SuperResolution: 生效 mode=${mode.label} vo=$voAfter '
          'glsl-shaders=$applied',
        );
      } else {
        KazumiLogger().e(
          'SuperResolution: 未生效 mode=${mode.label} vo=$voAfter '
          'glsl-shaders=${loaded ? applied : "（空）"} '
          '—— vo 仍是 null 说明 GL 上下文还没建好',
        );
      }
    } catch (e, stack) {
      KazumiLogger().w(
        'PlayerController: failed to set shader (mode=$mode)',
        error: e,
        stackTrace: stack,
      );
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger()
          .e('PlayerController: failed to set playback speed', error: e);
    }
  }

  Future<void> setVolume(double value) async {
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    cachePolicy.stopWatching();
    final ownedPlayer = _ownedPlayer;
    _ownedPlayer = null;
    videoController = null;
    playing = false;
    loading = true;
    // media_kit stops playback as part of disposal before releasing native
    // resources. Debug subscriptions can be cancelled concurrently.
    await Future.wait([
      ownedPlayer?.dispose() ?? Future<void>.value(),
      _cancelDebugInfo(),
    ]);
  }

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    // Encode the captured frame natively; PlayerState dimensions may be stale.
    // 青枢：safeScreenshot 是 Kazumi 分支加的（带初始化等待），
    // pub.dev 的 1.2.6 只有 screenshot()。调用方已经判过 mediaPlayer 非空。
    return player.screenshot(format: 'image/png');
  }
}