import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:convert' show ascii, utf8;
import 'dart:io' show Platform;
import 'dart:math' show max, min;
import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models/common/audio_normalization.dart';
import 'package:PiliPlus/models/common/super_resolution_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/user/danmaku_rule.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/video/video_shot/data.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/sponsor_block/block_mixin.dart';
import 'package:PiliPlus/plugin/pl_player/hdr_backend.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/double_tap_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/duration.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/plugin/pl_player/models/heart_beat_type.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_repeat.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/plugin/pl_player/utils/fullscreen.dart';
import 'package:PiliPlus/services/service_locator.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/android/android_helper.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/asset_utils.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/box_ext.dart';
import 'package:PiliPlus/utils/extension/native_geometry_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/ios/pip_helper.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:archive/archive.dart' show getCrc32;
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously, kDebugMode;
import 'package:flutter/services.dart'
    show DeviceOrientation, HapticFeedback, KeyDownEvent;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi show Size, Rectangle;
import 'package:path/path.dart' as path;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

typedef PlayCallback = Future<void>? Function();
typedef PlayOwner = ({String tag, Type type});

/// HDR 诊断日志。只在 debug 包输出：这些日志在一次播放里会打印上百行，
/// 留在 release 里既刷屏又拖慢起播。
void _hdrLog(String message) {
  if (kDebugMode) {
    debugPrintSynchronously('[PiliHDR] $message');
  }
}

class PlPlayerController with BlockConfigMixin, AudioNormalizationMixin {
  Player? _videoPlayerController;
  VideoController? _videoController;

  /// 安卓 HDR 画面。非空时视频由 Media3 的 SurfaceView 输出，mpv 只解音频。
  final Rxn<HdrBackend> hdrBackend = Rxn();
  StreamSubscription<Map<String, dynamic>>? _hdrEvents;
  Timer? _hdrSyncTimer;

  /// HDR 画面后端开关（持久化，播放器设置里可切换）。
  late final RxBool hdrSurfaceEnabled = Pref.enableHdrSurface.obs;

  /// 画面相对音频的固定落后。起播时两路都停在第一帧，一起开跑后这个值
  /// 应接近 0；若仍有几十毫秒的管道延迟，锁定一次补到 `audio-delay`。
  Duration? _hdrOffset;

  /// 上一次读到的原始偏差，用来判断偏差是否已经收敛。
  Duration? _hdrOffsetSample;

  /// 正在重新测量，这段时间的读数不拿来更新偏差。
  bool _hdrOffsetPending = false;

  /// 偏差已经收敛并写进 `audio-delay`，之后不再改。
  bool _hdrOffsetLocked = false;

  /// 这次起播要跳到的位置。视图创建是异步的，等它建好时 mpv 的进度可能还是 0。
  Duration? _hdrOpenAt;

  /// Media3 第一帧还没上屏，音频必须停着等它。
  bool _hdrFirstFrame = false;

  /// 第一帧出来后要不要立刻开播（自动播放，或用户已经按了播放）。
  bool _hdrPendingPlay = false;

  /// 第一帧事件超时，避免个别机型暂停时不回调 `onRenderedFirstFrame`。
  Timer? _hdrFirstFrameTimer;

  /// 片源标称帧率。B 站 DASH 经常不带 fps，Media3 会当成 -1，
  /// 二倍速时解码器 operating-rate 就不会跟着提高。
  double? _hdrFrameRate;

  /// 连续长按会叠多个未完成的对齐。世代一变，旧的对齐立刻停。
  int _hdrRealignEpoch = 0;

  /// 起播时若偏差远大于管道延迟，只允许追一次画面，避免把竞态锁进
  /// `audio-delay`。
  bool _hdrStartupResyncDone = false;

  /// HDR 起播前关掉 mpv 音轨。pause/mute 冻不住 `audio-pts`，
  /// 解码那几百毫秒里音频会自己往前跑。
  bool _hdrAudioDisabled = false;

  /// mpv 已经 loadfile 完成。不能在 open 之前放行 Media3。
  bool _hdrMpvOpened = false;

  /// `aid=no` 之前记下的真实音轨。`aid=auto` 在 EDL 上选不回来。
  AudioTrack? _hdrSavedAudioTrack;

  /// 关掉音轨前的 `lavfi-complex`。图绑的是 `aid1`，恢复时要重挂。
  String? _hdrLavfiComplex;

  /// 本次 HDR 会话是否由我们关掉了 mpv 视频轨。
  /// 不能用 `track.video.id == 'no'` 反推：听视频模式同样是 `no`。
  bool _hdrVidDisabled = false;

  /// 进 HDR 时是否替用户清掉了 glsl-shaders，离开时要挂回去。
  bool _hdrShaderWasOn = false;

  /// 回退提示只弹一次，避免 error 风暴。
  bool _hdrFallbackNotified = false;

  /// 控制器已销毁，异步收尾不能再碰 mpv。
  bool _disposed = false;

  /// 正在处理一次 seek，避免连点把 HDR 的 pause/seek/play 交叉执行。
  bool _hdrSeekInFlight = false;

  /// 处理中的 seek 期间又来的请求，只保留最后一次。
  Duration? _hdrPendingSeek;

  static PlPlayerController? _instance;

  PlayerStatus playerStatus = .paused;

  final Rx<DataStatus> dataStatus = Rx(.none);

  Duration? seekToPos;
  bool hasToasted = false;
  final RxBool isSeeking = false.obs;

  final RxInt position = RxInt(0);
  final RxInt seekPosition = RxInt(0);
  int get progress => isSeeking.value ? seekPosition.value : position.value;

  int get positionInMilliseconds =>
      videoPlayerController?.state.position.inMilliseconds ?? 0;

  final RxInt buffered = RxInt(0);

  final RxInt duration = RxInt(0);

  int durationInMilliseconds = 0;

  void updateDuration(Duration value) {
    duration.value = value.inSeconds;
    durationInMilliseconds = value.inMilliseconds;
  }

  int _playerCount = 0;

  late double lastPlaybackSpeed = 1.0;
  final RxDouble _playbackSpeed = Pref.playSpeedDefault.obs;
  late final RxDouble _longPressSpeed = Pref.longPressSpeedDefault.obs;

  final RxDouble volume = RxDouble(
    PlatformUtils.isDesktop ? Pref.desktopVolume : 1.0,
  );
  final setSystemBrightness = Pref.setSystemBrightness;

  final RxDouble brightness = (-1.0).obs;

  final RxBool showControls = false.obs;

  final RxBool showBrightnessStatus = false.obs;

  final RxBool longPressStatus = false.obs;

  final RxBool controlsLock = false.obs;

  final RxBool isFullScreen = false.obs;
  bool isLive = false;

  bool _isVertical = false;

  final Rx<VideoFitType> videoFit = Rx(.contain);

  late final RxBool continuePlayInBackground =
      Pref.continuePlayInBackground.obs;

  bool _autoPlay = false;

  // 记录历史记录
  int? _aid;
  String? _bvid;
  int? cid;
  int? _epid;
  int? _seasonId;
  int? _pgcType;
  VideoType _videoType = VideoType.ugc;
  int _heartDuration = 0;
  int? width;
  int? height;

  late final tryLook = !Accounts.get(AccountType.video).isLogin && Pref.p1080;

  late DataSource dataSource;

  Timer? _timer;
  StreamSubscription? _subForSeek;

  Box setting = GStorage.setting;

  // final Durations durations;

  String get bvid => _bvid!;

  /// 视频播放速度
  double get playbackSpeed => _playbackSpeed.value;

  // 长按倍速
  double get longPressSpeed => _longPressSpeed.value;

  /// [videoPlayerController] instance of Player
  Player? get videoPlayerController => _videoPlayerController;

  /// [videoController] instance of Player
  VideoController? get videoController => _videoController;

  bool isMuted = false;

  /// 听视频
  late final RxBool onlyPlayAudio = false.obs;

  /// 镜像
  late final RxBool flipX = false.obs;

  late final RxBool flipY = false.obs;

  final RxBool isBuffering = true.obs;

  /// 全屏方向
  // ignore: unnecessary_getters_setters
  bool get isVertical => _isVertical;

  set isVertical(bool value) {
    _isVertical = value;
  }

  /// 弹幕开关
  late final RxBool enableShowDanmaku = Pref.enableShowDanmaku.obs;
  late final RxBool enableShowLiveDanmaku = Pref.enableShowLiveDanmaku.obs;
  RxBool get enableShowDanmakuAdaptive =>
      isLive ? enableShowLiveDanmaku : enableShowDanmaku;

  late final bool autoPiP = Pref.autoPiP;
  bool get isPipMode =>
      (Platform.isAndroid && AndroidHelper.isPipMode) ||
      (PlatformUtils.isDesktop && isDesktopPip);
  late bool isDesktopPip = false;
  late nativeapi.Rectangle _lastWindowBounds;
  static nativeapi.Rectangle? _lastPipBounds;

  nativeapi.Rectangle _adjustPipBounds(
    nativeapi.Rectangle lastRect,
    nativeapi.Size size,
    double aspectRatio,
  ) {
    final lastSize = lastRect.size;
    final lastOrientation = lastSize.orientation;
    final orientation = size.orientation;

    if (lastOrientation != orientation) {
      final double width, height;
      switch (orientation) {
        case .portrait:
          if (lastSize.width > size.height) {
            height = min(lastSize.width, _lastWindowBounds.size.height);
            width = height * aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
        case .landscape:
          if (lastSize.height > size.width) {
            width = lastSize.height;
            height = width / aspectRatio;
          } else {
            height = size.height;
            width = size.width;
          }
      }

      return _lastPipBounds = nativeapi.Rectangle(
        x: lastRect.x,
        y: lastRect.y,
        width: width,
        height: height,
      );
    }
    return _lastPipBounds = nativeapi.Rectangle(
      x: lastRect.x,
      y: lastRect.y,
      width: lastSize.width,
      height: lastSize.width / aspectRatio,
    );
  }

  bool updatePipBounds(Window window) {
    if (isDesktopPip) {
      _lastPipBounds = window.bounds;
      return true;
    }
    return false;
  }

  late final showWindowTitleBar = Pref.showWindowTitleBar;
  late final RxBool isAlwaysOnTop = false.obs;
  void setAlwaysOnTop(bool value, {Window? window}) {
    window ??= WindowController.instance.window;
    if (window == null) return;

    isAlwaysOnTop.value = value;
    window.isAlwaysOnTop = value;
  }

  void exitDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    isDesktopPip = false;
    if (showWindowTitleBar) window.titleBarStyle = .normal;
    window
      ..minimumSize = DeviceUtils.desktopMinSize
      ..bounds = _lastWindowBounds
      ..aspectRatio = 0;
    setAlwaysOnTop(false, window: window);
  }

  void enterDesktopPip() {
    final window = WindowController.instance.window;
    if (window == null) return;

    if (isFullScreen.value) return;

    isDesktopPip = true;

    _lastWindowBounds = window.bounds;

    if (showWindowTitleBar) window.titleBarStyle = .hidden;

    const shortSide = 280.0;
    const minShortSide = 160.0;
    final nativeapi.Size size;
    final nativeapi.Size minimumSize;
    final state = videoPlayerController!.state;
    int width = state.width;
    int height = state.height;
    if (width == 0) width = this.width ?? 16;
    if (height == 0) height = this.height ?? 9;
    final aspectRatio = width / height;
    if (height > width) {
      size = nativeapi.Size(width: shortSide, height: shortSide / aspectRatio);
      minimumSize = nativeapi.Size(
        width: minShortSide,
        height: minShortSide / aspectRatio,
      );
    } else {
      size = nativeapi.Size(width: shortSide * aspectRatio, height: shortSide);
      minimumSize = nativeapi.Size(
        width: minShortSide * aspectRatio,
        height: minShortSide,
      );
    }

    window.minimumSize = minimumSize;
    setAlwaysOnTop(true, window: window);
    if (_lastPipBounds != null) {
      window.bounds = _adjustPipBounds(_lastPipBounds!, size, aspectRatio);
    } else {
      window.contentSize = size;
    }
    window.aspectRatio = aspectRatio;
  }

  void toggleDesktopPip() {
    if (isDesktopPip) {
      exitDesktopPip();
    } else {
      enterDesktopPip();
    }
  }

  late bool _isAutoEnterPip = false;
  bool get isAutoEnterPip => _isAutoEnterPip;

  static bool get _isCurrVideoPage {
    final routing = Get.routing;
    if (routing.route is! GetPageRoute) {
      return false;
    }
    return _isVideoPage(routing.current);
  }

  static bool _isVideoPage(String routeName) {
    return routeName == '/videoV' || routeName == '/liveRoom';
  }

  void enterPip({bool autoEnter = false}) {
    if (videoPlayerController case NativePlayer(:final state)) {
      if (Platform.isIOS) {
        if (videoController?.id.value case final textureId?) {
          IOSPipHelper.enter(
            textureId,
            width: state.width == 0 ? width : state.width,
            height: state.height == 0 ? height : state.height,
            autoEnter: autoEnter,
            state: _iosPipState(state),
          );
        }
        return;
      }
      PageUtils.enterPip(
        autoEnter: autoEnter,
        width: state.width == 0 ? width : state.width,
        height: state.height == 0 ? height : state.height,
        isLive: isLive,
        isPlaying: playerStatus.isPlaying,
      );
    }
  }

  void _disableAutoEnterPip() {
    if (_isAutoEnterPip) {
      if (Platform.isIOS) {
        IOSPipHelper.disableAutoEnter();
      } else {
        PiliAndroidHelper.disableAutoEnterPip();
      }
    }
  }

  Map<String, Object> _iosPipState(PlayerState state, [Duration? position]) {
    return {
      'isPlaying': playerStatus.isPlaying,
      'isBuffering': isBuffering.value,
      'isLive': isLive,
      'position': (position ?? state.position).inMilliseconds,
      'duration': durationInMilliseconds,
      'speed': state.rate,
    };
  }

  void _updateIOSPip([Duration? position]) {
    if (Platform.isIOS && IOSPipHelper.needsUpdate) {
      if (_videoPlayerController case final player?) {
        IOSPipHelper.update(_iosPipState(player.state, position));
      }
    }
  }

  // 弹幕相关配置
  late final enableTapDm = PlatformUtils.isMobile && Pref.enableTapDm;
  late RuleFilter filters = Pref.danmakuFilterRule;
  // 关联弹幕控制器
  DanmakuController<DanmakuExtra>? danmakuController;
  bool showDanmaku = true;
  Set<int> dmState = <int>{};
  late final mergeDanmaku = Pref.mergeDanmaku;
  late final String midHash = getCrc32(
    ascii.encode(Accounts.main.mid.toString()),
    0,
  ).toRadixString(16);
  late final RxDouble danmakuOpacity = Pref.danmakuOpacity.obs;

  late List<double> speedList = Pref.speedList;
  late bool enableAutoLongPressSpeed = Pref.enableAutoLongPressSpeed;
  late final showControlDuration = Pref.enableLongShowControl
      ? const Duration(seconds: 30)
      : const Duration(seconds: 3);
  // 字幕
  late double subtitleFontScale = Pref.subtitleFontScale;
  late double subtitleFontScaleFS = Pref.subtitleFontScaleFS;
  late int subtitlePaddingH = Pref.subtitlePaddingH;
  late int subtitlePaddingB = Pref.subtitlePaddingB;
  late double subtitleBgOpacity = Pref.subtitleBgOpacity;
  final bool showVipDanmaku = Pref.showVipDanmaku; // loop unswitching
  late double subtitleStrokeWidth = Pref.subtitleStrokeWidth;
  late int subtitleFontWeight = Pref.subtitleFontWeight;

  // settings
  late final showFSActionItem = Pref.showFSActionItem;
  late final enableShrinkVideoSize = Pref.enableShrinkVideoSize;
  late final darkVideoPage = Pref.darkVideoPage;
  late final enableSlideVolumeBrightness = Pref.enableSlideVolumeBrightness;
  late final enableSlideFS = Pref.enableSlideFS;
  late final enableDragSubtitle = Pref.enableDragSubtitle;
  late final fastForBackwardDuration = Duration(
    seconds: Pref.fastForBackwardDuration,
  );

  late final horizontalSeasonPanel = Pref.horizontalSeasonPanel;
  late final preInitPlayer = Pref.preInitPlayer;
  late final showRelatedVideo = Pref.showRelatedVideo;
  late final showVideoReply = Pref.showVideoReply;
  late final showBangumiReply = Pref.showBangumiReply;
  late final reverseFromFirst = Pref.reverseFromFirst;
  late final horizontalPreview = Pref.horizontalPreview;
  late final showDmChart = Pref.showDmChart;
  late final showViewPoints = Pref.showViewPoints;
  late final showFsScreenshotBtn = Pref.showFsScreenshotBtn;
  late final showFsLockBtn = Pref.showFsLockBtn;
  late final keyboardControl = Pref.keyboardControl;
  late final uiScale = Pref.uiScale;

  late final bool autoEnterFullScreen = Pref.autoEnterFullScreen;
  late final bool autoExitFullscreen = Pref.autoExitFullscreen;
  late final bool autoPlayEnable = Pref.autoPlayEnable;
  late final bool enableVerticalExpand = Pref.enableVerticalExpand;
  late final bool pipNoDanmaku = Pref.pipNoDanmaku;

  late final bool tempPlayerConf = Pref.tempPlayerConf;

  late int? cacheVideoQa = PlatformUtils.isMobile ? null : Pref.defaultVideoQa;
  late int cacheAudioQa = Pref.defaultAudioQa;
  bool enableHeart = true;
  late final String? hwdec = Pref.enableHA ? Pref.hardwareDecoding : null;

  late final progressType = Pref.btmProgressBehavior;
  late final enableQuickDouble = Pref.enableQuickDouble;
  late final fullScreenGestureReverse = Pref.fullScreenGestureReverse;

  late final isRelative = Pref.useRelativeSlide;
  late final offset = isRelative
      ? Pref.sliderDuration / 100
      : Pref.sliderDuration * 1000;

  num get sliderScale => isRelative ? durationInMilliseconds * offset : offset;

  // 播放顺序相关
  late PlayRepeat playRepeat = Pref.playRepeat;

  TextStyle get subTitleStyle => TextStyle(
    height: 1.5,
    fontSize:
        16 * (isFullScreen.value ? subtitleFontScaleFS : subtitleFontScale),
    letterSpacing: 0.1,
    wordSpacing: 0.1,
    color: Colors.white,
    fontWeight: FontWeight.values[subtitleFontWeight],
    backgroundColor: subtitleBgOpacity == 0
        ? null
        : Colors.black.withValues(alpha: subtitleBgOpacity),
  );

  late final Rx<SubtitleViewConfiguration> subtitleConfig = getSubConfig.obs;

  SubtitleViewConfiguration get getSubConfig {
    final subTitleStyle = this.subTitleStyle;
    return SubtitleViewConfiguration(
      style: subTitleStyle,
      strokeStyle: subtitleBgOpacity == 0
          ? subTitleStyle.copyWith(
              color: null,
              background: null,
              backgroundColor: null,
              foreground: Paint()
                ..color = Colors.black
                ..style = PaintingStyle.stroke
                ..strokeWidth = subtitleStrokeWidth,
            )
          : null,
      padding: EdgeInsets.only(
        left: subtitlePaddingH.toDouble(),
        right: subtitlePaddingH.toDouble(),
        bottom: subtitlePaddingB.toDouble(),
      ),
      textScaleFactor: 1,
    );
  }

  void updateSubtitleStyle() {
    subtitleConfig.value = getSubConfig;
  }

  void onUpdatePadding(EdgeInsets padding) {
    subtitlePaddingB = padding.bottom.round().clamp(0, 200);
    putSubtitleSettings();
  }

  static PlPlayerController? get instance => _instance;

  static bool instanceExists() {
    return _instance != null;
  }

  static void setPlayCallBack(
    PlayCallback? playCallBack, {
    PlayOwner? playOwner,
  }) {
    _playCallBack = playCallBack;
    _playOwner = playOwner;
  }

  static PlayOwner? _playOwner;
  static PlayOwner? get playOwner => _playOwner;
  static PlayCallback? _playCallBack;

  static Future<void>? playIfExists() {
    return _playCallBack?.call();
  }

  // try to get PlayerStatus
  static PlayerStatus? getPlayerStatusIfExists() {
    return _instance?.playerStatus;
  }

  static Future<void>? pauseIfExists({
    bool notify = true,
    bool isInterrupt = false,
  }) {
    if (_instance?.playerStatus.isPlaying ?? false) {
      return _instance?.pause(notify: notify, isInterrupt: isInterrupt);
    }
    return null;
  }

  static Future<void>? seekToIfExists(
    Duration position, {
    bool isSeek = true,
  }) {
    return _instance?.seekTo(position, isSeek: isSeek);
  }

  static double? getVolumeIfExists() {
    return _instance?.volume.value;
  }

  static Future<void>? setVolumeIfExists(
    double volumeNew, {
    bool showIndicator = true,
  }) {
    return _instance?.setVolume(volumeNew, showIndicator: showIndicator);
  }

  Box video = GStorage.video;

  bool visible = true;

  DeviceOrientation? _orientation;
  late final checkIsAutoRotate = Platform.isAndroid && mode != .gravity;
  StreamSubscription<OrientationParams>? _orientationListener;

  void _stopOrientationListener() {
    _orientationListener?.cancel();
    _orientationListener = null;
  }

  void _onOrientationChanged(OrientationParams param) {
    _orientation = param.orientation;
    if (Platform.isIOS && !visible) return;
    final orientation = param.orientation;
    final isFullScreen = this.isFullScreen.value;
    if (checkIsAutoRotate &&
        param.isAutoRotate != true &&
        (!isFullScreen ||
            _isVertical ||
            orientation == .portraitUp ||
            orientation == .portraitDown)) {
      return;
    }
    switch (orientation) {
      case .portraitUp:
        if (!_isVertical && controlsLock.value) return;
        if (!horizontalScreen && !_isVertical && isFullScreen) {
          if (!isManualFS) {
            triggerFullScreen(status: false, orientation: orientation);
          }
        } else {
          portraitUpMode();
        }
      case .portraitDown:
        if (!horizontalScreen) return;
        if (!_isVertical && controlsLock.value) return;
        portraitDownMode();
      case .landscapeLeft:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeLeftMode();
        }
      case .landscapeRight:
        if (!horizontalScreen && !isFullScreen) {
          triggerFullScreen(orientation: orientation, isManualFS: false);
        } else {
          landscapeRightMode();
        }
    }
  }

  // 添加一个私有构造函数
  PlPlayerController._() {
    if (PlatformUtils.isMobile) {
      _orientationListener = NativeDeviceOrientationPlatform.instance
          .onOrientationChanged(
            checkIsAutoRotate: checkIsAutoRotate,
            angleDegrees: Platform.isAndroid ? Pref.angleDegrees : null,
          )
          .listen(_onOrientationChanged);
    }

    if (!Accounts.heartbeat.isLogin || Pref.historyPause) {
      enableHeart = false;
    }

    if (Platform.isAndroid && autoPiP) {
      if (DeviceUtils.sdkInt < 31) {
        final func = Runnable.implement($Runnable(run: _onUserLeaveHint));
        AndroidHelper$ToDart.onUserLeaveHint = func;
        func.release();
      } else {
        _isAutoEnterPip = true;
      }
    } else if (Platform.isIOS && autoPiP && IOSPipHelper.isAvailable) {
      _isAutoEnterPip = true;
    }
  }

  void _onUserLeaveHint() {
    if (playerStatus.isPlaying && _isCurrVideoPage) {
      enterPip();
    }
  }

  // 获取实例 传参
  static PlPlayerController getInstance({bool isLive = false}) {
    // 如果实例尚未创建，则创建一个新实例
    return (_instance ??= PlPlayerController._())
      ..isLive = isLive
      .._playerCount += 1;
  }

  bool _processing = false;
  bool get processing => _processing;

  // offline
  bool get isFileSource => dataSource is FileSource;

  // 初始化资源
  Future<void> setDataSource(
    DataSource dataSource, {
    bool isLive = false,
    bool autoplay = true,
    // 初始化播放位置
    Duration? seekTo,
    // 初始化播放速度
    double speed = 1.0,
    int? width,
    int? height,
    Duration? duration,
    // 方向
    bool? isVertical,
    // 记录历史记录
    int? aid,
    String? bvid,
    int? cid,
    int? epid,
    int? seasonId,
    int? pgcType,
    // 清晰度代码，125/126/129 在安卓上尝试走 HDR 画面后端
    int? quality,
    double? frameRate,
    VideoType? videoType,
    VoidCallback? onInit,
    Volume? volume,
    bool autoFullScreenFlag = false,
  }) async {
    try {
      _processing = true;
      this.isLive = isLive;
      _videoType = videoType ?? VideoType.ugc;
      this.width = width;
      this.height = height;
      this.dataSource = dataSource;
      _autoPlay = autoplay;
      // 初始化数据加载状态
      dataStatus.value = DataStatus.loading;
      // 初始化全屏方向
      _isVertical = isVertical ?? false;
      _aid = aid;
      _bvid = bvid;
      this.cid = cid;
      _epid = epid;
      _seasonId = seasonId;
      _pgcType = pgcType;

      if (showSeekPreview) {
        _clearPreview();
      }
      cancelLongPressTimer();
      if (_videoPlayerController != null &&
          _videoPlayerController!.state.playing) {
        await pause(notify: false);
      }

      if (_playerCount == 0) {
        return;
      }
      // 先决定是否走 HDR 画面，再打开 mpv。HDR 时音轨要先关掉，
      // 否则解码那几百毫秒里 `audio-pts` 会自己往前跑。
      await _startHdrBackend(dataSource, quality, seekTo, frameRate);
      await _createVideoController(dataSource, seekTo, volume);

      if (_playerCount == 0) {
        _removeListeners();
        _videoPlayerController?.dispose();
        _videoPlayerController = null;
        _videoController = null;
        return;
      }

      updateDuration(duration ?? _videoPlayerController!.state.duration);
      position.value = buffered.value = seekTo?.inSeconds ?? 0;

      dataStatus.value = .loaded;

      if (autoFullScreenFlag && autoEnterFullScreen) {
        triggerFullScreen(status: true);
      }

      await _initializePlayer();
      onInit?.call();
    } catch (err, stackTrace) {
      dataStatus.value = DataStatus.error;
      if (kDebugMode) {
        debugPrint(stackTrace.toString());
        debugPrint('plPlayer err:  $err');
      }
    } finally {
      _processing = false;
    }
  }

  String? shadersDirPath;
  Future<void> _startHdrBackend(
    DataSource dataSource,
    int? quality,
    Duration? seekTo,
    double? frameRate,
  ) async {
    await _stopHdrBackend();
    if (!hdrSurfaceEnabled.value ||
        onlyPlayAudio.value ||
        dataSource is! NetworkSource ||
        !HdrBackend.isHdrQuality(quality) ||
        !await HdrBackend.displaySupportsHdr()) {
      return;
    }
    _hdrFrameRate = frameRate != null && frameRate > 0 ? frameRate : null;
    _hdrLog(
      'surface requested qn=$quality '
      'fps=${_hdrFrameRate ?? -1} '
      'display=${HdrBackend.supported}',
    );
    hdrBackend.value = HdrBackend();
    _hdrOpenAt = seekTo;
    _hdrFirstFrame = false;
    _hdrPendingPlay = _autoPlay;
    _hdrAudioDisabled = false;
    _hdrMpvOpened = false;
    _hdrSavedAudioTrack = null;
    _hdrLavfiComplex = null;
    _hdrVidDisabled = false;
    _hdrShaderWasOn = false;
    _hdrFallbackNotified = false;
  }

  /// SurfaceView 创建完成后再打开视频，避免 Media3 没有可输出的表面。
  Future<void> onHdrViewCreated() async {
    final backend = hdrBackend.value;
    final source = dataSource;
    if (backend == null || !backend.ready || source is! NetworkSource) return;
    final url = source.videoSource;
    if (url.isEmpty) return;
    // HDR 后端比 mpv 更早挂上视图。等 loadfile 完成并关轨后再让
    // Media3 出帧，否则 firstFrame 会在 audio-pts 还没冻住时就来。
    for (var i = 0; i < 100; i++) {
      if (_videoPlayerController != null && _hdrMpvOpened) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // 视图重建时必须重新等第一帧，否则音频会自己先跑。
    _hdrPendingPlay = _hdrPendingPlay || playerStatus.isPlaying || _autoPlay;
    _hdrFirstFrame = false;

    _hdrEvents ??= backend.events.listen((event) {
      switch (event['event']) {
        case 'error':
          unawaited(_fallbackFromHdr('player error ${event['message']}'));
        case 'ready':
          backend.mediaReady = true;
          final width = event['width'];
          final height = event['height'];
          if (width is num && height is num && height > 0) {
            unawaited(
              backend.setFit(videoFit.value, ratio: width / height),
            );
          }
        case 'firstFrame':
          unawaited(_onHdrFirstFrame(event));
        case 'videoSize':
          final width = event['width'];
          final height = event['height'];
          if (width is num && height is num && height > 0) {
            unawaited(backend.setFit(videoFit.value, ratio: width / height));
          }
      }
    });
    try {
      final player = _videoPlayerController;
      // 视频改由 Media3 输出，mpv 只保留音轨，避免两路 4K 同时硬解。
      if (player != null) {
        player.setProperty('vid', 'no');
        _hdrVidDisabled = true;
        // 超分 shader 只对 mpv 的 vo 有效，这里临时清掉即可，
        // 不要改写用户设置（setShader(disable) 会写进偏好）。
        if (superResolutionType.value != SuperResolutionType.disable) {
          _hdrShaderWasOn = true;
          await player.command(
            const ['change-list', 'glsl-shaders', 'clr', ''],
          );
        }
      }
      // pause/mute 冻不住 audio-pts。音轨先关掉，等第一帧对齐后再打开。
      await player?.pause();
      await _disableHdrAudioTrack();
      // 音频已停住，优先用当前时钟；起播瞬间 audio-pts 还是 0 时才退回
      // 请求的续播点，避免画面从片头打开。
      final live = _hdrAudioClock();
      final state = _videoPlayerController?.state.position;
      final Duration position;
      if (live != null && live > const Duration(milliseconds: 200)) {
        position = live;
      } else if (state != null && state > const Duration(milliseconds: 200)) {
        position = state;
      } else {
        position = _hdrOpenAt ?? live ?? state ?? Duration.zero;
      }
      await backend.open(
        url: url,
        position: position,
        rate: _videoPlayerController?.state.rate ?? playbackSpeed,
        frameRate: _hdrFrameRate,
      );
      await backend.setFit(
        videoFit.value,
        ratio: _hdrVideoRatio(videoFit.value),
      );
      _hdrLog('waiting first frame at ${position.inMilliseconds}');
      _hdrFirstFrameTimer?.cancel();
      _hdrFirstFrameTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_hdrFirstFrame) return;
        // 个别机型暂停时不出第一帧。先让画面自己跑起来，
        // 音频继续停着，等真正上屏再把音频对齐过去。
        _hdrLog('firstFrame timeout, kick video only');
        unawaited(backend.play());
        // 再等一会儿还是不出帧，说明这条流解不了，回退 mpv。
        _hdrFirstFrameTimer = Timer(
          const Duration(milliseconds: 2500),
          () {
            _hdrFirstFrameTimer = null;
            if (_hdrFirstFrame || hdrBackend.value == null) return;
            unawaited(_fallbackFromHdr('first frame timeout'));
          },
        );
      });
    } catch (e) {
      _hdrLog('surface open failed: $e');
      await _fallbackFromHdr('surface open failed');
    }
  }

  /// 第一帧已经解码出来。音轨若还关着，就对齐到这帧再一起开跑。
  Future<void> _onHdrFirstFrame(Map<String, dynamic> event) async {
    if (_hdrFirstFrame) return;
    _hdrFirstFrame = true;
    _hdrFirstFrameTimer?.cancel();
    _hdrFirstFrameTimer = null;
    _anchorHdr();
    _hdrSyncTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _syncHdrPosition(),
    );
    var audio = _hdrAudioClock();
    final videoMs = event['rendered'] ?? event['position'];
    var video = videoMs is num
        ? Duration(milliseconds: videoMs.round())
        : null;
    _hdrLog(
      'firstFrame audio=${audio?.inMilliseconds} '
      'video=${video?.inMilliseconds} '
      'audioOff=$_hdrAudioDisabled',
    );
    try {
      // 音轨关掉后 audio-pts 不应再自己跑。若仍超前，只能让画面跳到
      // 当前音频；seek 要等真正上屏的帧，期间若音轨仍开着还会走。
      if (video != null && audio != null) {
        final gap = video - audio;
        if (gap < const Duration(milliseconds: -40)) {
          _hdrOffsetPending = true;
          var videoPos = video;
          try {
            for (var i = 0; i < 3; i++) {
              final live = _hdrAudioClock();
              if (live == null) break;
              audio = live;
              _hdrLog(
                'firstFrame seek video ${videoPos.inMilliseconds} -> '
                'audio ${live.inMilliseconds} try=$i',
              );
              await hdrBackend.value?.seek(live);
              final latest = await hdrBackend.value?.drift(live);
              if (latest == null) break;
              videoPos = latest.video;
              video = videoPos;
              if (videoPos >= live - const Duration(milliseconds: 40)) {
                break;
              }
            }
          } finally {
            _hdrOffsetPending = false;
          }
        } else if (gap > const Duration(milliseconds: 40)) {
          _hdrLog(
            'firstFrame seek audio ${audio.inMilliseconds} -> '
            'video ${video.inMilliseconds}',
          );
          await hdrBackend.value?.pause();
          await _videoPlayerController?.seek(video);
        }
      }
    } finally {
      // 音轨仍关着。先把画面亮出来；真正开口留给 play()，
      // 避免 aid=auto 之后、Media3 还没 play 之前 audio-pts 又自己跑。
      await hdrBackend.value?.show();
    }
    _logHdrAudioState(
      'firstFrame aligned video=${video?.inMilliseconds} '
      'clock=${_hdrAudioClock()?.inMilliseconds}',
    );
    if (_hdrPendingPlay || playerStatus.isPlaying) {
      _hdrPendingPlay = false;
      await play();
    }
    unawaited(_catchUpHdrStartup());
  }

  AudioTrack? _pickHdrAudioTrack(Player player) {
    for (final track in player.state.tracks.audio) {
      if (track.id != 'no' && track.id != 'auto') return track;
    }
    final current = player.state.track.audio;
    if (current.id != 'no' && current.id != 'auto') return current;
    return null;
  }

  Future<AudioTrack?> _waitHdrAudioTrack(Player player) async {
    final existing = _pickHdrAudioTrack(player);
    if (existing != null) return existing;
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final track = _pickHdrAudioTrack(player);
      if (track != null) return track;
    }
    _hdrLog('wait audio track timeout');
    return null;
  }

  void _logHdrAudioState(String tag) {
    if (!kDebugMode) return;
    final player = _videoPlayerController;
    _hdrLog(
      '$tag '
      'aid=${player?.getProperty('aid')} '
      'mute=${player?.getProperty('mute')} '
      'pause=${player?.getProperty('pause')} '
      'pts=${player?.getProperty('audio-pts')} '
      'track=${player?.state.track.audio.id} '
      'tracks=${player?.state.tracks.audio.map((t) => t.id).join(',')} '
      'saved=${_hdrSavedAudioTrack?.id} '
      'off=$_hdrAudioDisabled',
    );
  }

  Future<void> _disableHdrAudioTrack() async {
    final player = _videoPlayerController;
    if (player == null) {
      _hdrAudioDisabled = true;
      return;
    }
    if (_hdrAudioDisabled) {
      player.setProperty('mute', 'yes');
      return;
    }
    _hdrSavedAudioTrack ??= await _waitHdrAudioTrack(player);
    if (_disposed || _videoPlayerController == null) return;
    if (_hdrSavedAudioTrack == null) {
      player.setProperty('mute', 'yes');
      _logHdrAudioState('audioOff skipped, no track yet');
      return;
    }
    final lavfi = player.getProperty('lavfi-complex');
    if (lavfi.isNotEmpty &&
        lavfi != '(empty)' &&
        lavfi != '""' &&
        lavfi != 'no') {
      _hdrLavfiComplex = lavfi;
      player.setProperty('lavfi-complex', '');
    }
    player..setProperty('aid', 'no')
      ..setProperty('mute', 'yes');
    _hdrAudioDisabled = true;
    _logHdrAudioState('audioOff');
  }

  Future<void> _enableHdrAudioTrack() async {
    final player = _videoPlayerController;
    if (player == null) {
      _hdrAudioDisabled = false;
      return;
    }
    if (!_hdrAudioDisabled) {
      player.setProperty('mute', 'no');
      return;
    }
    final saved = _hdrSavedAudioTrack ?? _pickHdrAudioTrack(player);
    if (saved != null) {
      await player.setAudioTrack(saved);
      if (_disposed) return;
    } else {
      player.setProperty('aid', 'auto');
    }
    final lavfi = _hdrLavfiComplex;
    if (lavfi != null && lavfi.isNotEmpty) {
      player.setProperty('lavfi-complex', lavfi);
    }
    player.setProperty('mute', 'no');
    _hdrAudioDisabled = false;
    _logHdrAudioState('audioOn');
    if (kDebugMode &&
        (player.getProperty('audio-pts').isEmpty ||
            player.getProperty('aid') == 'no')) {
      _logHdrAudioState('audioOn pts still stale');
    }
  }

  Duration? _hdrAudioPts() {
    if (_hdrAudioDisabled) return null;
    final raw = _videoPlayerController?.getProperty('audio-pts');
    if (raw == null || raw.isEmpty) return null;
    final seconds = double.tryParse(raw);
    if (seconds == null || seconds < 0) return null;
    return Duration(microseconds: (seconds * 1e6).round());
  }

  /// mpv 报给界面的 `time-pos` 比音频真实时间戳 `audio-pts` 固定落后一个
  /// 音频缓冲（实测约 224 毫秒），画面若跟着界面进度走就会一直慢一拍。
  /// 这里取音频时间戳作为对齐基准。
  Duration? _hdrAudioClock() {
    // 音轨关掉后 audio-pts 会停在上一次的值，不能拿来对齐。
    if (_hdrAudioDisabled) {
      return _videoPlayerController?.state.position;
    }
    final raw = _videoPlayerController?.getProperty('audio-pts');
    final seconds = raw == null ? null : double.tryParse(raw);
    if (seconds == null || seconds < 0) {
      return _videoPlayerController?.state.position;
    }
    return Duration(microseconds: (seconds * 1e6).round());
  }

  /// 把画面的固定落后补到音频上。`audio-delay` 为正表示音频推迟。
  /// 画面超前时不能把音频往前拽，那种情况改暂停画面等音频追上。
  void _applyHdrAudioDelay(Duration offset) {
    if (offset >= Duration.zero) return;
    _videoPlayerController?.setProperty(
      'audio-delay',
      (offset.inMicroseconds / -1e6).toStringAsFixed(3),
    );
  }

  /// 画面准备好后开始测量落后。
  void _anchorHdr() {
    _hdrRealignEpoch++;
    _hdrOffset = null;
    _hdrOffsetPending = false;
    _hdrOffsetSample = null;
    _hdrOffsetLocked = false;
    _hdrStartupResyncDone = false;
  }

  Future<void> _syncHdrPosition() async {
    final backend = hdrBackend.value;
    if (backend == null || !_hdrFirstFrame) return;
    // 锁定后不再重测：稳态下每 2 秒打一次平台通道只会白耗电，
    // 变速的瞬时差由改速后的对齐处理，跳转会在 seek() 里清掉补偿再测。
    if (_hdrOffsetLocked) {
      if (kDebugMode) {
        final offset = _hdrOffset ?? Duration.zero;
        final audio = _hdrAudioClock();
        if (audio != null) {
          final reading = await backend.drift(audio);
          if (reading != null) {
            _hdrLog(
              'sync audio=${audio.inMilliseconds} '
              'video=${reading.video.inMilliseconds} '
              'raw=${reading.drift.inMilliseconds} '
              'offset=${offset.inMilliseconds} '
              'drift=${(reading.drift - offset).inMilliseconds} '
              'speed=${reading.speed}',
            );
          }
        }
      }
      return;
    }
    final audio = _hdrAudioClock();
    // 画面还没进入 STATE_READY 时 Media3 的进度恒为 0，拿来测量没有意义。
    if (!backend.mediaReady || audio == null) return;
    if (_hdrOffsetPending || isSeeking.value) return;
    // 长按加速时两路改速有先后，瞬时差不是新的管道延迟。
    if (longPressStatus.value) return;
    final reading = await backend.drift(audio);
    if (reading == null) return;
    final delay = _videoPlayerController?.getProperty('audio-delay');
    // 落后在起播后很快收敛。连续两次读数接近才锁定，
    // 避免把还在变化的值当成固定落后。
    final previous = _hdrOffsetSample;
    _hdrOffsetSample = reading.drift;
    if (previous == null ||
        (reading.drift - previous).abs() > const Duration(milliseconds: 40)) {
      _hdrLog(
        'sync audio=${audio.inMilliseconds} '
        'video=${reading.video.inMilliseconds} '
        'raw=${reading.drift.inMilliseconds} '
        'delay=$delay '
        'hdrSdr=${reading.hdrSdrRatio} '
        'measuring',
      );
      return;
    }
    // 管道延迟是画面落后音频 20–70ms。画面超前不是延迟，不能锁进 offset。
    if (previous > const Duration(milliseconds: 40)) {
      _hdrLog(
        'sync audio=${audio.inMilliseconds} '
        'video=${reading.video.inMilliseconds} '
        'raw=${reading.drift.inMilliseconds} '
        'delay=$delay '
        'hdrSdr=${reading.hdrSdrRatio} '
        'skip lock, video ahead',
      );
      _hdrOffsetSample = null;
      if (playerStatus.isPlaying &&
          !longPressStatus.value &&
          !_hdrOffsetPending &&
          _hdrAudioPts() != null) {
        _hdrStartupResyncDone = true;
        unawaited(_holdHdrVideoForAudio(reading.video, _hdrRealignEpoch));
      }
      return;
    }
    if (previous < const Duration(milliseconds: -150)) {
      _hdrLog(
        'sync audio=${audio.inMilliseconds} '
        'video=${reading.video.inMilliseconds} '
        'raw=${reading.drift.inMilliseconds} '
        'delay=$delay '
        'hdrSdr=${reading.hdrSdrRatio} '
        'skip lock, startup gap',
      );
      _hdrOffsetSample = null;
      if (!_hdrStartupResyncDone &&
          playerStatus.isPlaying &&
          !longPressStatus.value) {
        _hdrStartupResyncDone = true;
        unawaited(_speedHdrVideoToAudio(_hdrRealignEpoch));
      }
      return;
    }
    _hdrOffset = previous;
    _hdrOffsetLocked = true;
    _applyHdrAudioDelay(previous);
    _hdrLog(
      'sync audio=${audio.inMilliseconds} '
      'video=${reading.video.inMilliseconds} '
      'raw=${reading.drift.inMilliseconds} '
      'offset=${previous.inMilliseconds} '
      'delay=${_videoPlayerController?.getProperty('audio-delay')} '
      'hdrSdr=${reading.hdrSdrRatio} '
      'locked',
    );
  }

  /// 画面比例用的视频宽高比。固定比例优先，否则用接口给的分辨率。
  double? _hdrVideoRatio(VideoFitType fit) {
    final fixed = fit.aspectRatio;
    if (fixed != null && fixed > 0) return fixed;
    final w = width;
    final h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  Future<void> _stopHdrBackend() async {
    _hdrSyncTimer?.cancel();
    _hdrSyncTimer = null;
    await _hdrEvents?.cancel();
    _hdrEvents = null;
    _hdrFirstFrameTimer?.cancel();
    _hdrFirstFrameTimer = null;
    _hdrFirstFrame = false;
    _hdrPendingPlay = false;
    await _enableHdrAudioTrack();
    if (_disposed) return;
    final backend = hdrBackend.value;
    if (backend == null) return;
    hdrBackend.value = null;
    _hdrOpenAt = null;
    _hdrFrameRate = null;
    _hdrOffset = null;
    _hdrOffsetPending = false;
    _hdrOffsetSample = null;
    _hdrOffsetLocked = false;
    _hdrStartupResyncDone = false;
    _hdrMpvOpened = false;
    _hdrSavedAudioTrack = null;
    _hdrLavfiComplex = null;
    _hdrRealignEpoch++;
    backend.dispose();
    _restoreHdrMpvState();
  }

  /// 把 HDR 会话对 mpv 做的临时改动恢复回去。
  /// 只做同步、便宜的 setProperty，避免和 player 释放抢跑。
  void _restoreHdrMpvState() {
    final player = _videoPlayerController;
    if (player == null) return;
    player..setProperty('audio-delay', '0')
      ..setProperty('mute', 'no');
    // 听视频模式下 vid 本来就该是 no，别替用户打开。
    if (_hdrVidDisabled && !onlyPlayAudio.value) {
      player.setProperty('vid', 'auto');
    }
    _hdrVidDisabled = false;
    if (_hdrShaderWasOn) {
      _hdrShaderWasOn = false;
      if (superResolutionType.value != SuperResolutionType.disable) {
        unawaited(
          setShader(superResolutionType.value).catchError((Object _) {}),
        );
      }
    }
  }

  /// HDR 画面不可用（解码失败/首帧超时/用户关闭）时退回 mpv 视频轨。
  Future<void> _fallbackFromHdr(String reason, {bool notify = true}) async {
    if (hdrBackend.value == null) return;
    // 自动播放时第一帧还没到，playerStatus 仍是 paused，但用户预期是在播的。
    final shouldPlay = playerStatus.isPlaying || _hdrPendingPlay;
    _hdrLog('fallback: $reason');
    await _stopHdrBackend();
    if (_disposed || hdrBackend.value != null) return;
    final player = _videoPlayerController;
    if (player != null) {
      player.setProperty('vid', 'auto');
      _hdrVidDisabled = false;
    }
    if (shouldPlay) {
      await play();
    }
    if (notify && !_hdrFallbackNotified) {
      _hdrFallbackNotified = true;
      SmartDialog.showToast('HDR 画面异常，已回退到普通渲染');
    }
  }

  /// 用户关闭 HDR 开关时立即收回画面（下次播放同样不再走 HDR）。
  Future<void> toggleHdrSurface(bool value) async {
    hdrSurfaceEnabled.value = value;
    setting.put(SettingBoxKey.enableHdrSurface, value);
    if (!value && hdrBackend.value != null) {
      await _fallbackFromHdr('user disabled', notify: false);
      SmartDialog.showToast('已关闭 HDR 渲染');
    } else if (value && hdrBackend.value == null) {
      SmartDialog.showToast('HDR 渲染已开启，重新加载后生效');
    }
  }

  /// 切“听视频”前调用：先收回 Media3 画面，把 mpv 视频轨还给调用方。
  Future<void> disableHdrForAudioOnly() async {
    if (hdrBackend.value == null) return;
    await _stopHdrBackend();
  }

  /// 控制器销毁时的 HDR 收尾：不碰 mpv（它马上会被释放），只释放平台视图。
  void _disposeHdr() {
    _hdrSyncTimer?.cancel();
    _hdrSyncTimer = null;
    _hdrFirstFrameTimer?.cancel();
    _hdrFirstFrameTimer = null;
    unawaited(_hdrEvents?.cancel());
    _hdrEvents = null;
    _hdrFirstFrame = false;
    _hdrPendingPlay = false;
    _hdrOffsetPending = false;
    // 不能在这里把 hdrBackend 置空：dispose 期间触发 Obx 重建会让
    // view.dart 切回 SimpleVideo，而 videoController 紧接着就被置空了。
    hdrBackend.value?.dispose();
  }

  Future<String> get copyShadersToExternalDirectory async {
    if (shadersDirPath != null) {
      return shadersDirPath!;
    }

    return shadersDirPath = await AssetUtils.getOrCopy(
      'assets/shaders',
      Assets.mpvAnime4KShaders.followedBy(Assets.mpvAnime4KShadersLite),
      path.join(appSupportDirPath, 'anime_shaders'),
    );
  }

  late final isAnim = _pgcType == 1 || _pgcType == 4;
  late final Rx<SuperResolutionType> superResolutionType =
      (isAnim ? Pref.superResolutionType : SuperResolutionType.disable).obs;
  Future<void> setShader([SuperResolutionType? type, NativePlayer? pp]) async {
    if (type == null) {
      type = superResolutionType.value;
    } else {
      superResolutionType.value = type;
      if (isAnim && !tempPlayerConf) {
        setting.put(SettingBoxKey.superResolutionType, type.index);
      }
    }
    pp ??= _videoPlayerController!;
    switch (type) {
      case SuperResolutionType.disable:
        return pp.command(const ['change-list', 'glsl-shaders', 'clr', '']);
      case SuperResolutionType.efficiency:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShadersLite,
          ),
        ]);
      case SuperResolutionType.quality:
        return pp.command([
          'change-list',
          'glsl-shaders',
          'set',
          PathUtils.buildShadersAbsolutePath(
            await copyShadersToExternalDirectory,
            Assets.mpvAnime4KShaders,
          ),
        ]);
    }
  }

  Future<Player> _initPlayer() async {
    assert(_videoPlayerController == null);
    final opt = {
      'video-sync': Pref.videoSync,
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume':
          (PlatformUtils.isMobile ? Pref.playerVolume : volume.value * 100)
              .toString(),
    };
    final autosync = Pref.autosync;
    if (autosync != '0') {
      opt['autosync'] = autosync;
    }

    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: opt,
      ),
    );

    assert(_videoController == null);

    _videoController = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hwdec != null,
        androidAttachSurfaceAfterVideoParameters: false,
        hwdec: hwdec,
      ),
    );

    if (Platform.isAndroid) {
      // Avoid sizing the surface using mpv's idle window between media loads.
      player.setProperty('force-window', 'no');
    }

    player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);

    _startListeners(player);

    return player;
  }

  late final buffer = Pref.initBuffer(_playbackSpeed.value);
  late final liveBuffer = Pref.initLiveBuffer();

  // 配置播放器
  Future<void> _createVideoController(
    DataSource dataSource,
    Duration? seekTo,
    Volume? volume,
  ) async {
    isBuffering.value = false;
    _heartDuration = 0;
    danmakuController?.clear();

    var player = _videoPlayerController;

    if (player == null) {
      player = await _initPlayer();
      if (_playerCount == 0) {
        _removeListeners();
        player.dispose();
        player = null;
        _videoController = null;
        return;
      }
      _videoPlayerController = player;
      if (isAnim && superResolutionType.value != .disable) {
        await setShader();
      }
    }

    final Map<String, String> extras = {
      if (dataSource is FileSource)
        'cache': 'no'
      else if (isLive)
        ...liveBuffer
      else
        ...buffer,
    };

    String video = dataSource.videoSource;
    if (dataSource.audioSource case final audio? when (audio.isNotEmpty)) {
      if (onlyPlayAudio.value) {
        video = audio;
      } else {
        // dely_open need provide length
        video =
            ('edl://'
            '!no_chapters;'
            // '!delay_open,media_type=video;'
            '%${isFileSource ? utf8.encode(video).length : video.length}%$video;'
            '!new_stream;!no_chapters;'
            // '!delay_open,media_type=audio;'
            '%${isFileSource ? utf8.encode(audio).length : audio.length}%$audio');
      }
      audioFilterExtras(volume, map: extras);
    }

    assert(!isLive || seekTo == null);
    if (hdrBackend.value != null) {
      extras['vid'] = 'no';
      extras['pause'] = 'yes';
      extras['mute'] = 'yes';
    }
    await player.open(
      Media(
        video,
        start: seekTo,
        extras: extras.isEmpty ? null : extras,
      ),
      play: false,
    );
    if (hdrBackend.value != null) {
      player
        ..setProperty('vid', 'no')
        ..setProperty('pause', 'yes')
        ..setProperty('mute', 'yes');
      _hdrVidDisabled = true;
      await _disableHdrAudioTrack();
      _hdrMpvOpened = true;
    }
  }

  Future<void>? refreshPlayer() {
    if (dataSource is FileSource) {
      return null;
    }
    if (_videoPlayerController case final ctr? when (ctr.current.isNotEmpty)) {
      var media = ctr.current.last;
      if (!isLive) media = media.copyWith(start: ctr.state.position);
      return ctr.open(media, play: true);
    }
    return null;
  }

  // 开始播放
  Future<void> _initializePlayer() async {
    if (_instance == null) return;
    // 设置倍速
    if (_videoPlayerController != null) {
      final speed = isLive ? 1.0 : playbackSpeed;
      if (_videoPlayerController!.state.rate != speed) {
        await setPlaybackSpeed(speed);
      }
    }
    _initVideoFit();

    // 自动播放。HDR 画面还没出第一帧时音频必须停着等它，
    // 否则解码那几百毫秒里声音已经自己往前跑了。
    if (_autoPlay) {
      if (hdrBackend.value != null) {
        _hdrPendingPlay = true;
      } else {
        playIfExists();
      }
    }
  }

  List<StreamSubscription>? _subscriptions;
  final Set<ValueChanged<Duration>> _positionListeners = {};
  final Set<ValueChanged<PlayerStatus>> _statusListeners = {};

  Timer? _wakeLockTimer;

  void _startWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = Timer(
      const Duration(milliseconds: 500),
      _stopWakeLock,
    );
  }

  void _stopWakeLockTimer() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
  }

  void _stopWakeLock() {
    WakelockPlus.disable();
    _updatePlaybackState(debugLabel: 'onVideoPaused');
  }

  void _updatePlaybackState({Duration? position, String? debugLabel}) {
    videoPlayerServiceHandler?.onUpdateState(
      playerStatus,
      isBuffering.value,
      isLive,
      position: position ?? _videoPlayerController!.state.position,
      speed: playbackSpeed,
      debugLabel: debugLabel,
    );
    _updateIOSPip(position);
  }

  /// 播放事件监听
  void _startListeners(NativePlayer player) {
    assert(_subscriptions == null);
    final stream = player.stream;
    _subscriptions = [
      /// playing
      stream.playing.listen((bool playing) {
        if (playing) {
          playerStatus = .playing;
          _stopWakeLockTimer();
          _updatePlaybackState();
          WakelockPlus.enable();

          if (_isAutoEnterPip) {
            if (_isCurrVideoPage) {
              enterPip(autoEnter: true);
            } else {
              _disableAutoEnterPip();
            }
          }
        } else {
          playerStatus = .paused;
          _startWakeLockTimer();
          _disableAutoEnterPip();
          _updateIOSPip();
        }

        for (final element in _statusListeners) {
          element(playing ? .playing : .paused);
        }

        final seconds = videoPlayerController!.state.position.inSeconds;
        if (seconds != 0) {
          makeHeartBeat(seconds, type: .status);
        }
      }),

      ///completed
      stream.completed.listen((bool completed) {
        if (completed) {
          playerStatus = .completed;
          _startWakeLockTimer();

          for (final element in _statusListeners) {
            element(.completed);
          }

          makeHeartBeat(-1, type: .completed);
        }
      }),

      /// position
      stream.position.listen((Duration position) {
        // `audio-delay` 只推迟扬声器，不改 `time-pos`。偏差锁定后把进度
        // 和弹幕一起挪到延迟后的音频上，否则弹幕会比画面早。
        final offset = _hdrOffset;
        if (_hdrOffsetLocked && offset != null && offset < Duration.zero) {
          final shifted = position + offset;
          position = shifted < Duration.zero ? Duration.zero : shifted;
        }
        final posInSeconds = position.inSeconds;

        if (posInSeconds != this.position.value) {
          if (posInSeconds == 0 && playerStatus.isPlaying) {
            _updatePlaybackState(position: position);
          }

          this.position.value = posInSeconds;

          makeHeartBeat(posInSeconds);
        }

        for (final element in _positionListeners) {
          element(position);
        }
      }),
      stream.duration.listen((Duration duration) {
        updateDuration(duration);
        _updateIOSPip();
      }),
      stream.buffer.listen((Duration buffer) {
        buffered.value = buffer.inSeconds;
      }),
      stream.buffering.listen((bool buffering) {
        isBuffering.value = buffering;
        if (!playerStatus.isCompleted) {
          _stopWakeLockTimer();
          _updatePlaybackState();
        }
      }),
      if (kDebugMode)
        stream.videoParams.listen((params) {
          if (params.w == null && params.pixelformat == null) return;
          _hdrLog(
            'decoded ${params.w}x${params.h} '
            'pixelformat=${params.pixelformat} hw=${params.hwPixelformat} '
            'primaries=${params.primaries} gamma=${params.gamma} '
            'colormatrix=${params.colormatrix} levels=${params.colorlevels} '
            'sigPeak=${params.sigPeak} light=${params.light} '
            'hwdec=${player.getProperty('hwdec-current')} '
            'vo=${player.getProperty('current-vo')} '
            'target-trc=${player.getProperty('target-trc')} '
            'tone-mapping=${player.getProperty('tone-mapping')} '
            'sr=${superResolutionType.value.name}',
          );
        }),
      if (kDebugMode)
        stream.log.listen(((PlayerLog log) {
          if (log.level == 'error' || log.level == 'fatal') {
            Utils.reportError(
              '${log.level}: ${log.prefix}: ${log.text}\n${player.state.playlist}',
              null,
            );
          } else {
            debugPrint(log.toString());
          }
        })),
      stream.error.listen((String event) {
        if (dataSource is FileSource &&
            event.startsWith("Failed to open file")) {
          return;
        }
        if (isLive) {
          if (event.startsWith('tcp: ffurl_read returned ') ||
              event.startsWith("Failed to open https://") ||
              event.startsWith("Can not open external file https://")) {
            Timer(const Duration(milliseconds: 3000), refreshPlayer);
          }
          return;
        }
        if (event.startsWith("Failed to open https://") ||
            event.startsWith("Can not open external file https://") ||
            //tcp: ffurl_read returned 0xdfb9b0bb
            //tcp: ffurl_read returned 0xffffff99
            event.startsWith('tcp: ffurl_read returned ')) {
          EasyThrottle.throttle(
            'controllerStream.error.listen',
            const Duration(milliseconds: 10000),
            () => Timer(const Duration(milliseconds: 3000), () {
              // if (kDebugMode) {
              //   debugPrint("isBuffering.value: ${isBuffering.value}");
              // }
              // if (kDebugMode) {
              //   debugPrint("_buffered.value: ${_buffered.value}");
              // }
              if (isBuffering.value && buffered.value == 0) {
                SmartDialog.showToast(
                  '视频链接打开失败，重试中',
                  displayTime: const Duration(milliseconds: 500),
                );
                refreshPlayer();
              }
            }),
          );
        } else if (event.startsWith('Could not open codec')) {
          SmartDialog.showToast('无法加载解码器, $event，可能会切换至软解');
        } else if (!onlyPlayAudio.value) {
          if (event.startsWith("error running") ||
              event.startsWith("Failed to open .") ||
              event.startsWith("Cannot open") ||
              event.startsWith("Can not open")) {
            return;
          }
          if (!kDebugMode) {
            Utils.reportError('$event\n${player.state.playlist}');
          }
          // SmartDialog.showToast('视频加载错误, $event');
        }
      }),
    ];
  }

  /// 移除事件监听
  void _removeListeners() {
    _subscriptions?.forEach((e) => e.cancel());
    _subscriptions?.clear();
    _subscriptions = null;
  }

  void _cancelSubForSeek() {
    if (_subForSeek != null) {
      _subForSeek!.cancel();
      _subForSeek = null;
    }
  }

  Future<void> seek(Duration position, {bool isSeek = false}) async {
    if (isSeek) {
      /// 拖动进度条调节时，不等待第一帧，防止抖动
      await _videoPlayerController?.stream.buffer.first;
    }
    danmakuController?.clear();
    // 连点/连续拖动时不要让两次 seek 的 pause/seek/play 交叉执行：
    // 只保留最后一次请求，做完再补上。
    if (_hdrSeekInFlight) {
      _hdrPendingSeek = position;
      return;
    }
    final hdr = hdrBackend.value;
    try {
      // HDR 跳转时音频不能先走：Media3 落到新位置要花一段时间，
      // 这段时间 mpv 若继续播，落后会被重新写进管道。
      final resume = hdr != null && playerStatus.isPlaying;
      if (hdr != null) {
        _hdrSeekInFlight = true;
        await _videoPlayerController?.pause();
        await hdr.pause();
        _videoPlayerController?.setProperty('audio-delay', '0');
        _anchorHdr();
        _hdrOffsetPending = true;
      }
      await _videoPlayerController?.seek(position);
      if (hdr != null) {
        await hdr.seek(position);
        if (resume) {
          await _videoPlayerController?.play();
          await hdr.play();
        }
      }
      _updateIOSPip(position);
    } catch (e) {
      if (kDebugMode) debugPrint('seek failed: $e');
    } finally {
      // 出错时也要复位，否则一旦停在 pending 上，后续 drift 同步会永久停摆。
      if (hdr != null) {
        _hdrOffsetPending = false;
        _hdrSeekInFlight = false;
      }
      final pending = _hdrPendingSeek;
      _hdrPendingSeek = null;
      if (pending != null) {
        unawaited(seek(pending, isSeek: false));
      }
    }
  }

  /// 跳转至指定位置
  Future<void> seekTo(Duration position, {bool isSeek = true}) async {
    if (_playerCount == 0) {
      return;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    _heartDuration = position.inSeconds;

    if (duration.value != 0) {
      seek(position, isSeek: isSeek);
    } else {
      // if (kDebugMode) debugPrint('seek duration else');
      _subForSeek?.cancel();
      _subForSeek = duration.listen((_) {
        seek(position, isSeek: isSeek);
        _cancelSubForSeek();
      });
    }
  }

  /// 开播后立刻看一次偏差。以前要等 2 秒同步周期，片头那 200ms 会一直挂着。
  Future<void> _catchUpHdrStartup() async {
    if (_hdrStartupResyncDone || hdrBackend.value == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 240));
    if (_hdrStartupResyncDone ||
        !_hdrFirstFrame ||
        !playerStatus.isPlaying ||
        longPressStatus.value ||
        isSeeking.value) {
      return;
    }
    final sample = await _hdrDriftSample();
    if (sample == null) return;
    final gap = sample.drift;
    _hdrLog(
      'startupCatch audio=${sample.audio.inMilliseconds} '
      'video=${sample.video.inMilliseconds} '
      'raw=${gap.inMilliseconds}',
    );
    if (gap.abs() < const Duration(milliseconds: 40)) return;
    if (_hdrAudioPts() == null && sample.audio <= Duration.zero) {
      _hdrLog('startupCatch skip, audio clock stuck');
      _logHdrAudioState('startupCatch stuck');
      return;
    }
    _hdrStartupResyncDone = true;
    if (gap < Duration.zero) {
      await _speedHdrVideoToAudio(_hdrRealignEpoch);
    } else {
      await _holdHdrVideoForAudio(sample.video, _hdrRealignEpoch);
    }
  }

  /// 变速后重新对齐。起播锁定的 `audio-delay` 是固定管道延迟，这里
  /// 绝不改写。画面超前冻画面等音频；画面落后把 Media3 略加速追上。
  /// mpv 暂停后 `audio-pts` 仍会往前走（音频缓冲还在播），不能冻音频。
  /// 4K 播放中 seek 会卡死，这里绝不 seek。
  Future<void> _realignHdrAfterRateChange() async {
    final epoch = _hdrRealignEpoch;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (epoch != _hdrRealignEpoch) return;
    final sample = await _stableHdrDriftSample();
    if (sample == null || epoch != _hdrRealignEpoch) return;
    final offset = _hdrOffset ?? Duration.zero;
    final corrected = sample.drift - offset;
    _hdrLog(
      'rateAlign audio=${sample.audio.inMilliseconds} '
      'video=${sample.video.inMilliseconds} '
      'raw=${sample.drift.inMilliseconds} '
      'corrected=${corrected.inMilliseconds} '
      'speed=${sample.speed}',
    );
    if (corrected.abs() < const Duration(milliseconds: 80)) return;
    if (corrected > Duration.zero) {
      await _holdHdrVideoForAudio(sample.video, epoch);
      return;
    }
    await _speedHdrVideoToAudio(epoch);
  }

  Future<({Duration drift, Duration video, Duration audio, double? speed})?>
  _stableHdrDriftSample() async {
    if (!_hdrReadyToRealign()) return null;
    final first = await _hdrDriftSample();
    if (first == null) return null;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!_hdrReadyToRealign()) return null;
    final second = await _hdrDriftSample();
    if (second == null) return null;
    if ((second.drift - first.drift).abs() > const Duration(milliseconds: 40)) {
      _hdrLog(
        'rateAlign measuring '
        'first=${first.drift.inMilliseconds} '
        'second=${second.drift.inMilliseconds} '
        'speed=${second.speed}',
      );
      return null;
    }
    return second;
  }

  /// 画面跑到音频前面时冻住画面，等扬声器追上。
  /// `audio-pts` 不含 `audio-delay`，要对到 `video + delay`。不 seek。
  Future<void> _holdHdrVideoForAudio(Duration video, int epoch) async {
    final backend = hdrBackend.value;
    if (backend == null || epoch != _hdrRealignEpoch) return;
    // 先冻画面再取样。若先等音频时钟，目标 PTS 会过期，音频一超过旧目标就直接返回。
    _hdrOffsetPending = true;
    await backend.pause();
    if (epoch != _hdrRealignEpoch || hdrBackend.value == null) {
      _hdrOffsetPending = false;
      return;
    }
    final frozen = await _hdrDriftSample();
    final frozenVideo = frozen?.video ?? video;
    final offset = _hdrOffset ?? Duration.zero;
    final delay = offset < Duration.zero ? -offset : Duration.zero;
    final target = frozenVideo + delay;
    var audioNow = _hdrAudioClock();
    _hdrLog(
      'catchUp pause video=${frozenVideo.inMilliseconds} '
      'audio=${audioNow?.inMilliseconds} '
      'target=${target.inMilliseconds} delay=${delay.inMilliseconds}',
    );
    if (audioNow != null &&
        audioNow >= target - const Duration(milliseconds: 20)) {
      await backend.play();
      _hdrOffsetPending = false;
      return;
    }
    final deadline = DateTime.now().add(const Duration(milliseconds: 1500));
    var timedOut = true;
    var lastAudio = audioNow;
    var lastAudioAt = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      if (epoch != _hdrRealignEpoch ||
          !_hdrFirstFrame ||
          hdrBackend.value == null ||
          longPressStatus.value ||
          isSeeking.value) {
        timedOut = false;
        break;
      }
      final audio = _hdrAudioClock();
      if (audio != null &&
          audio >= target - const Duration(milliseconds: 20)) {
        timedOut = false;
        break;
      }
      if (audio != null && lastAudio != null && audio > lastAudio) {
        lastAudio = audio;
        lastAudioAt = DateTime.now();
      } else if (DateTime.now().difference(lastAudioAt) >
          const Duration(milliseconds: 300)) {
        _hdrLog(
          'catchUp skip freeze, audio clock stuck',
        );
        _logHdrAudioState('catchUp stuck');
        timedOut = false;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (epoch != _hdrRealignEpoch || hdrBackend.value == null) {
      _hdrOffsetPending = false;
      _hdrLog('catchUp aborted');
      return;
    }
    await backend.play();
    _hdrOffsetPending = false;
    _hdrLog(
      'catchUp resume audio=${_hdrAudioClock()?.inMilliseconds} '
      'video=${frozenVideo.inMilliseconds} timeout=$timedOut',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (epoch != _hdrRealignEpoch) return;
    final after = await _hdrDriftSample();
    if (after == null) return;
    final locked = _hdrOffset ?? Duration.zero;
    _hdrLog(
      'catchUp after audio=${after.audio.inMilliseconds} '
      'video=${after.video.inMilliseconds} '
      'raw=${after.drift.inMilliseconds} '
      'corrected=${(after.drift - locked).inMilliseconds}',
    );
  }

  /// 画面落到音频后面时把 Media3 略加速追上。不改 `audio-delay`，
  /// 也不暂停 mpv：暂停后 `audio-pts` 仍随缓冲往前走。
  Future<void> _speedHdrVideoToAudio(int epoch) async {
    final backend = hdrBackend.value;
    if (backend == null || epoch != _hdrRealignEpoch) return;
    final offset = _hdrOffset ?? Duration.zero;
    final baseRate = _videoPlayerController?.state.rate ?? playbackSpeed;
    const boost = 1.4;
    final catchRate = baseRate * boost;
    _hdrOffsetPending = true;
    await backend.setRate(catchRate);
    _hdrLog(
      'catchUp videoBoost base=$baseRate rate=$catchRate '
      'offset=${offset.inMilliseconds}',
    );
    final deadline = DateTime.now().add(const Duration(milliseconds: 2000));
    var timedOut = true;
    Duration? videoNow;
    Duration? audioNow = _hdrAudioClock();
    while (DateTime.now().isBefore(deadline)) {
      if (epoch != _hdrRealignEpoch ||
          !_hdrFirstFrame ||
          hdrBackend.value == null ||
          longPressStatus.value ||
          isSeeking.value) {
        timedOut = false;
        break;
      }
      audioNow = _hdrAudioClock();
      if (audioNow == null) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        continue;
      }
      final latest = await backend.drift(audioNow);
      if (latest != null) {
        videoNow = latest.video;
        final target = audioNow + offset;
        if (latest.video >= target - const Duration(milliseconds: 20)) {
          timedOut = false;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    if (epoch != _hdrRealignEpoch || hdrBackend.value == null) {
      _hdrOffsetPending = false;
      _hdrLog('catchUp aborted');
      return;
    }
    await backend.setRate(baseRate);
    _hdrOffsetPending = false;
    _hdrLog(
      'catchUp videoBoostDone video=${videoNow?.inMilliseconds} '
      'audio=${audioNow?.inMilliseconds} timeout=$timedOut',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (epoch != _hdrRealignEpoch) return;
    final after = await _hdrDriftSample();
    if (after == null) return;
    final locked = _hdrOffset ?? Duration.zero;
    _hdrLog(
      'catchUp after audio=${after.audio.inMilliseconds} '
      'video=${after.video.inMilliseconds} '
      'raw=${after.drift.inMilliseconds} '
      'corrected=${(after.drift - locked).inMilliseconds}',
    );
  }

  bool _hdrReadyToRealign() {
    return hdrBackend.value != null &&
        _hdrFirstFrame &&
        _hdrOffsetLocked &&
        !longPressStatus.value &&
        !isSeeking.value;
  }

  Future<({Duration drift, Duration video, Duration audio, double? speed})?>
  _hdrDriftSample() async {
    final backend = hdrBackend.value;
    final audio = _hdrAudioClock();
    if (backend == null || audio == null) return null;
    final reading = await backend.drift(audio);
    if (reading == null) return null;
    return (
      drift: reading.drift,
      video: reading.video,
      audio: audio,
      speed: reading.speed,
    );
  }

  /// 设置倍速
  Future<void> setPlaybackSpeed(double speed) async {
    lastPlaybackSpeed = playbackSpeed;

    if (speed == _videoPlayerController?.state.rate && hdrBackend.value == null) {
      return;
    }

    final hdr = hdrBackend.value;
    if (hdr != null) {
      _hdrRealignEpoch++;
      _hdrOffsetPending = true;
      // 上一次 catch-up 可能冻着画面。新的改速先把两边都拉起来。
      if (playerStatus.isPlaying) {
        await (_videoPlayerController?.play() ?? Future<void>.value());
        await hdr.play();
      }
      // Media3 改速几乎是同步的，mpv 要绕一圈 JNI。一起发出去时画面会
      // 先到新速度，加速后画面超前、减速后也留一截。按方向错开：
      // 加速先音频，减速先画面。松手后若仍有残差，再冻超前的那一路。
      final currentRate =
          _videoPlayerController?.state.rate ?? playbackSpeed;
      _hdrLog(
        'setRate $currentRate -> $speed',
      );
      if (speed > currentRate + 0.01) {
        await (_videoPlayerController?.setRate(speed) ?? Future<void>.value());
        await hdr.setRate(speed);
      } else if (speed < currentRate - 0.01) {
        await hdr.setRate(speed);
        await (_videoPlayerController?.setRate(speed) ?? Future<void>.value());
      } else {
        await Future.wait<void>([
          _videoPlayerController?.setRate(speed) ?? Future<void>.value(),
          hdr.setRate(speed),
        ]);
      }
      _hdrOffsetPending = false;
      if (!longPressStatus.value) {
        unawaited(_realignHdrAfterRateChange());
      }
    } else {
      await _videoPlayerController?.setRate(speed);
    }
    if (!isLive) _playbackSpeed.value = speed;
    _updatePlaybackState();
    if (danmakuController != null) {
      try {
        danmakuController?.updateOption(
          danmakuController!.option.copyWith(
            duration: DanmakuOptions.danmakuDuration / speed,
            staticDuration: DanmakuOptions.danmakuStaticDuration / speed,
          ),
        );
      } catch (_) {}
    }
  }

  /// 播放视频
  Future<void> play({bool repeat = false, bool hideControls = true}) async {
    if (_playerCount == 0) return;
    // 播放时自动隐藏控制条
    controls = !hideControls;
    // repeat为true，将从头播放
    if (repeat) {
      await seekTo(Duration.zero, isSeek: false);
    }

    if (hdrBackend.value != null && !_hdrFirstFrame) {
      _hdrPendingPlay = true;
      playerStatus = .playing;
      audioSessionHandler?.setActive(true);
      return;
    }

    // 音轨先选上，再两边一起开。Media3 若先 play，画面会在扬声器出声前跑掉一截；
    // 音频若先跑再等 pts，画面又会落后等待的那一段时间。
    if (hdrBackend.value != null) {
      await _enableHdrAudioTrack();
      _videoPlayerController?.setProperty('mute', 'no');
    }
    await Future.wait<void>([
      _videoPlayerController?.play() ?? Future<void>.value(),
      hdrBackend.value?.play() ?? Future<void>.value(),
    ]);
    await hdrBackend.value?.show();
    // 暂停时停掉了 sync timer，恢复播放要重新挂上。
    if (hdrBackend.value != null && _hdrFirstFrame) {
      _hdrSyncTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => _syncHdrPosition(),
      );
    }

    audioSessionHandler?.setActive(true);

    playerStatus = .playing;
  }

  /// 暂停播放
  Future<void> pause({bool notify = true, bool isInterrupt = false}) async {
    _hdrRealignEpoch++;
    _hdrPendingPlay = false;
    // 暂停时没有对齐可做，2 秒一次的采样纯属空转。
    _hdrSyncTimer?.cancel();
    _hdrSyncTimer = null;
    await _videoPlayerController?.pause();
    await hdrBackend.value?.pause();
    playerStatus = .paused;

    // 主动暂停时让出音频焦点
    if (!isInterrupt) {
      audioSessionHandler?.setActive(false);
    }
  }

  bool tripling = false;

  /// 隐藏控制条
  void hideTaskControls() {
    _timer?.cancel();
    _timer = Timer(showControlDuration, () {
      if (!isSeeking.value && !tripling) {
        controls = false;
      }
      _timer = null;
    });
  }

  void onSeekStart(int seekFrom) {
    seekPosition.value = seekFrom;
    isSeeking.value = true;
  }

  void onSeekEnd() {
    if (showSeekPreview) {
      showPreview.value = false;
    }
    hasToasted = false;
    isSeeking.value = false;
    hideTaskControls();
  }

  final RxBool volumeIndicator = false.obs;
  Timer? volumeTimer;
  bool volumeInterceptEventStream = false;

  final double maxVolume = PlatformUtils.isDesktop ? Pref.maxVolume : 1.0;
  Future<void> setVolume(double volume, {bool showIndicator = true}) async {
    if (this.volume.value != volume) {
      this.volume.value = volume;
      try {
        if (PlatformUtils.isDesktop) {
          await _videoPlayerController!.setVolume(volume * 100);
        } else {
          FlutterVolumeController.updateShowSystemUI(false);
          await FlutterVolumeController.setVolume(volume);
        }
      } catch (err) {
        if (kDebugMode) debugPrint(err.toString());
      }
    }
    if (showIndicator) {
      volumeIndicator.value = true;
    }
    volumeInterceptEventStream = true;
    volumeTimer?.cancel();
    volumeTimer = Timer(const Duration(milliseconds: 200), () {
      volumeIndicator.value = false;
      volumeInterceptEventStream = false;
      if (PlatformUtils.isDesktop) {
        setting.put(SettingBoxKey.desktopVolume, volume.toPrecision(3));
      }
    });
  }

  /// Toggle Change the videofit accordingly
  void toggleVideoFit(VideoFitType value) {
    _prefFit = videoFit.value = value;
    video.put(VideoBoxKey.cacheVideoFit, value.index);
    final backend = hdrBackend.value;
    if (backend != null) {
      unawaited(backend.setFit(value, ratio: _hdrVideoRatio(value)));
    }
  }

  /// 读取fit
  var _prefFit = VideoFitType.values[Pref.cacheVideoFit];
  void _initVideoFit() {
    if (_prefFit == .fill && _isVertical) {
      videoFit.value = .contain;
    } else {
      videoFit.value = _prefFit;
    }
  }

  /// 设置后台播放
  void setBackgroundPlay(bool val) {
    videoPlayerServiceHandler?.enableBackgroundPlay = val;
    if (!tempPlayerConf) {
      setting.put(SettingBoxKey.enableBackgroundPlay, val);
    }
  }

  set controls(bool visible) {
    showControls.value = visible;
    _timer?.cancel();
    if (visible) {
      hideTaskControls();
    }
  }

  Timer? longPressTimer;
  void cancelLongPressTimer() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }

  /// 设置长按倍速状态 live模式下禁用
  Future<void> setLongPressStatus(bool val) async {
    if (isLive) {
      return;
    }
    if (controlsLock.value) {
      return;
    }
    if (longPressStatus.value == val) {
      return;
    }
    if (val) {
      if (playerStatus.isPlaying) {
        longPressStatus.value = val;
        HapticFeedback.lightImpact();
        await setPlaybackSpeed(
          enableAutoLongPressSpeed ? playbackSpeed * 2 : longPressSpeed,
        );
      }
    } else {
      // if (kDebugMode) debugPrint('$playbackSpeed');
      longPressStatus.value = val;
      await setPlaybackSpeed(lastPlaybackSpeed);
    }
  }

  bool get isCompleted =>
      videoPlayerController!.state.completed ||
      durationInMilliseconds - positionInMilliseconds <= 50;

  // 双击播放、暂停。HDR 画面不走 mpv，不能用 playOrPause 绕过同步。
  Future<void> onDoubleTapCenter() async {
    if (!isLive && isCompleted) {
      await seekTo(Duration.zero, isSeek: false);
      await play();
    } else if (playerStatus.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  final RxBool mountSeekBackwardButton = false.obs;
  final RxBool mountSeekForwardButton = false.obs;

  void onDoubleTapSeekBackward() {
    mountSeekBackwardButton.value = true;
  }

  void onDoubleTapSeekForward() {
    mountSeekForwardButton.value = true;
  }

  void onForward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position + duration);
  }

  void onBackward(Duration duration) {
    onForwardBackward(videoPlayerController!.state.position - duration);
  }

  void onForwardBackward(Duration duration) {
    seekTo(
      duration.clamp(Duration.zero, videoPlayerController!.state.duration),
      isSeek: false,
    ).whenComplete(play);
  }

  void doubleTapFuc(DoubleTapType type) {
    if (!enableQuickDouble) {
      onDoubleTapCenter();
      return;
    }
    switch (type) {
      case DoubleTapType.left:
        // 双击左边区域 👈
        onDoubleTapSeekBackward();
        break;
      case DoubleTapType.center:
        onDoubleTapCenter();
        break;
      case DoubleTapType.right:
        // 双击右边区域 👈
        onDoubleTapSeekForward();
        break;
    }
  }

  /// 关闭控制栏
  void onLockControl(bool val) {
    feedBack();
    controlsLock.value = val;
    if (!val && showControls.value) {
      showControls.refresh();
    }
    controls = !val;
  }

  void _setFullScreen(bool val) {
    isFullScreen.value = val;
    updateSubtitleStyle();
  }

  double screenRatio = 0.0;
  bool isManualFS = true;
  late final FullScreenMode mode = Pref.fullScreenMode;
  late final horizontalScreen = Pref.horizontalScreen;
  late final removeSafeArea = Pref.removeSafeArea;

  Future<void>? changeOrientation({
    required bool isVertical,
    DeviceOrientation? orientation,
  }) {
    if (orientation == null && (mode == .none || mode == .gravity)) {
      return null;
    }
    if (orientation == null &&
        (mode == .vertical ||
            (mode == .auto && isVertical) ||
            (mode == .ratio && (isVertical || screenRatio < kScreenRatio)))) {
      return portraitUpMode();
    } else {
      // https://github.com/flutter/flutter/issues/73651
      // https://github.com/flutter/flutter/issues/183708
      if (Platform.isAndroid) {
        if ((orientation ?? _orientation) == .landscapeRight) {
          return landscapeRightMode();
        } else {
          return landscapeLeftMode();
        }
      } else {
        if (orientation == .landscapeLeft) {
          return landscapeLeftMode();
        } else {
          return landscapeRightMode();
        }
      }
    }
  }

  // 全屏
  bool _fsProcessing = false;
  Future<void> triggerFullScreen({
    bool status = true,
    bool inAppFullScreen = false,
    DeviceOrientation? orientation,
    bool isManualFS = true,
  }) async {
    if (isDesktopPip) return;
    if (isFullScreen.value == status) return;

    if (_fsProcessing) return;
    _fsProcessing = true;
    this.isManualFS = isManualFS;
    try {
      if (status) {
        if (PlatformUtils.isMobile) {
          hideSystemBar();
          await changeOrientation(
            isVertical: isVertical,
            orientation: orientation,
          );
        } else {
          enterDesktopFullScreen(inAppFullScreen: inAppFullScreen);
        }
      } else {
        if (PlatformUtils.isMobile) {
          if (!removeSafeArea) {
            showSystemBar();
          }
          if (orientation == null && mode == .none) {
            return;
          }
          await resetScreenRotation();
        } else {
          exitDesktopFullScreen();
        }
      }
    } finally {
      _setFullScreen(status);
      _fsProcessing = false;
    }
  }

  void addPositionListener(ValueChanged<Duration> listener) {
    if (_playerCount == 0) return;
    _positionListeners.add(listener);
  }

  void removePositionListener(ValueChanged<Duration> listener) =>
      _positionListeners.remove(listener);

  void addStatusLister(ValueChanged<PlayerStatus> listener) {
    if (_playerCount == 0) return;
    _statusListeners.add(listener);
  }

  void removeStatusLister(ValueChanged<PlayerStatus> listener) =>
      _statusListeners.remove(listener);

  // 记录播放记录
  Future<void>? makeHeartBeat(
    int progress, {
    HeartBeatType type = .playing,
    bool isManual = false,
    dynamic aid,
    dynamic bvid,
    dynamic cid,
    dynamic epid,
    dynamic seasonId,
    dynamic pgcType,
    VideoType? videoType,
  }) {
    if (isLive ||
        !enableHeart ||
        progress == 0 ||
        (playerStatus.isPaused && !isManual)) {
      return null;
    }

    Future<void> send() {
      return VideoHttp.heartBeat(
        aid: aid ?? _aid,
        bvid: bvid ?? _bvid,
        cid: cid ?? this.cid,
        progress: progress,
        epid: epid ?? _epid,
        seasonId: seasonId ?? _seasonId,
        subType: pgcType ?? _pgcType,
        videoType: videoType ?? _videoType,
      );
    }

    switch (type) {
      case .playing:
        if (progress - _heartDuration >= 5) {
          _heartDuration = progress;
          return send();
        }
      case .status:
        if (progress - _heartDuration >= 2) {
          _heartDuration = progress;
          return send();
        }
      case .completed:
        if (playerStatus.isCompleted &&
            (durationInMilliseconds - positionInMilliseconds) <= 1000) {
          progress = -1;
        }
        return send();
    }
    return null;
  }

  void setPlayRepeat(PlayRepeat type) {
    playRepeat = type;
    if (!tempPlayerConf) video.put(VideoBoxKey.playRepeat, type.index);
  }

  void putSubtitleSettings() {
    setting.putAllNE({
      SettingBoxKey.subtitleFontScale: subtitleFontScale,
      SettingBoxKey.subtitleFontScaleFS: subtitleFontScaleFS,
      SettingBoxKey.subtitlePaddingH: subtitlePaddingH,
      SettingBoxKey.subtitlePaddingB: subtitlePaddingB,
      SettingBoxKey.subtitleBgOpacity: subtitleBgOpacity,
      SettingBoxKey.subtitleStrokeWidth: subtitleStrokeWidth,
      SettingBoxKey.subtitleFontWeight: subtitleFontWeight,
    });
  }

  bool _isCloseAll = false;
  bool get isCloseAll => _isCloseAll;

  Future<void>? resetScreenRotation() {
    if (horizontalScreen) {
      return fullMode();
    } else {
      return portraitUpMode();
    }
  }

  void onCloseAll() {
    _isCloseAll = true;
    if (PlatformUtils.isDesktop) exitDesktopFullScreen();
    dispose();
    Get.until((route) => route.isFirst);
  }

  void dispose() {
    // 每次减1，最后销毁
    resetScreenRotation();
    cancelLongPressTimer();
    _cancelSubForSeek();
    if (!_isCloseAll && _playerCount > 1) {
      _playerCount -= 1;
      _heartDuration = 0;
      return;
    }

    _playerCount = 0;
    if (removeSafeArea) {
      showSystemBar();
    }
    danmakuController = null;
    _stopOrientationListener();
    _disableAutoEnterPip();
    setPlayCallBack(null);
    dmState.clear();
    if (showSeekPreview) {
      _clearPreview();
    }
    if (Platform.isAndroid) {
      AndroidHelper$ToDart.onUserLeaveHint = null;
    } else if (Platform.isIOS) {
      IOSPipHelper.dispose();
    }
    _timer?.cancel();
    // _position.close();
    // _playerEventSubs?.cancel();
    // _sliderPosition.close();
    // _sliderTempPosition.close();
    // _isSliderMoving.close();
    // _duration.close();
    // _buffered.close();
    // _showControls.close();
    // _controlsLock.close();

    // playerStatus.close();
    // dataStatus.close();

    if (PlatformUtils.isDesktop && isAlwaysOnTop.value) {
      WindowController.instance.window?.isAlwaysOnTop = false;
    }

    _removeListeners();
    // 先藏起来再异步释放。SurfaceView 是独立窗口，等路由拆掉视图才释放的话，
    // 画面会在下一页上多停留一帧。
    unawaited(hdrBackend.value?.hide());
    // 收尾只释放平台视图，不要再碰 mpv：下面立刻就 dispose 它了，
    // 之前的 unawaited(_stopHdrBackend()) 会在 await 之后踩到已释放的 player。
    _disposed = true;
    _disposeHdr();
    _positionListeners.clear();
    _statusListeners.clear();
    _stopWakeLockTimer();
    WakelockPlus.disable();
    if (kDebugMode) {
      debugPrint('dispose player');
    }
    _videoPlayerController?.dispose();
    _videoPlayerController = null;
    _videoController = null;
    _instance = null;
    videoPlayerServiceHandler?.clear();
  }

  static void updatePlayCount() {
    if (_instance?._playerCount == 1) {
      _instance?.dispose();
    } else {
      _instance?._playerCount -= 1;
    }
  }

  void setContinuePlayInBackground() {
    continuePlayInBackground.toggle();
    if (!tempPlayerConf) {
      setting.put(
        SettingBoxKey.continuePlayInBackground,
        continuePlayInBackground.value,
      );
    }
  }

  late final Map<String, ui.Image?> previewCache = {};
  LoadingState<VideoShotData>? videoShot;
  late final RxBool showPreview = false.obs;
  late final showSeekPreview = Pref.showSeekPreview;
  late final previewIndex = RxnInt();

  void updatePreviewIndex(int seconds) {
    if (videoShot == null) {
      videoShot = LoadingState.loading();
      getVideoShot();
      return;
    }
    if (videoShot case Success(:final response)) {
      showPreview.value = true;
      previewIndex.value = max(
        0,
        (response.index.where((item) => item <= seconds).length - 2),
      );
    }
  }

  void _clearPreview() {
    showPreview.value = false;
    previewIndex.value = null;
    videoShot = null;
    for (final i in previewCache.values) {
      i?.dispose();
    }
    previewCache.clear();
  }

  Future<void> getVideoShot() async {
    videoShot = await VideoHttp.videoshot(bvid: bvid, cid: cid!);
  }

  int _screenshotState = 0;
  Future<void> takeScreenshot() async {
    if (_screenshotState > 0) return;
    // HDR 时 mpv 只解音频（vid=no），截出来会是黑帧。
    if (hdrBackend.value != null) {
      SmartDialog.showToast('HDR 渲染模式下暂不支持截图');
      return;
    }
    _screenshotState = 1;
    SmartDialog.showToast('截图中');
    final image = await videoPlayerController?.screenshot();
    if (image != null) {
      SmartDialog.showToast('点击弹窗或按 Enter 保存截图');
      await showDialog(
        context: Get.context!,
        requestFocus: true,
        builder: (context) {
          Future<void> save() async {
            if (_screenshotState > 1) return;
            _screenshotState = 2;
            final bytes = await image.toByteData(format: .png);
            if (bytes != null) {
              final time = DurationUtils.formatDuration(
                positionInMilliseconds / 1000,
              ).replaceAll(':', '-');
              ImageUtils.saveByteImg(
                bytes: bytes.buffer.asUint8List(),
                fileName: 'screenshot_${cid}_$time',
              );
            } else {
              SmartDialog.showToast('保存失败');
            }
            Get.back();
          }

          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                final key = event.logicalKey;
                if (key == .keyS || key == .enter || key == .numpadEnter) {
                  save();
                  return .handled;
                }
              }
              return .ignored;
            },
            child: GestureDetector(
              onTap: save,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: min(MediaQuery.widthOf(context) / 3, 350),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          width: 5,
                          color: ColorScheme.of(context).surface,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: RawImage(image: image),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
      image.dispose();
    } else {
      SmartDialog.showToast('截图失败');
    }
    _screenshotState = 0;
  }

  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop) {
      unawaited(hdrBackend.value?.hide());
      if (playerStatus.isPlaying) {
        pause();
      }

      setPlayCallBack(null);

      if (Platform.isAndroid && _playerCount <= 1) {
        _disableAutoEnterPip();
        if (!setSystemBrightness) {
          ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness();
        }
      }

      return;
    }

    if (controlsLock.value) {
      onLockControl(false);
      return;
    }
    if (isDesktopPip) {
      exitDesktopPip();
      return;
    }
    if (isFullScreen.value) {
      triggerFullScreen(status: false);
      return;
    }
    unawaited(hdrBackend.value?.hide());
    Get.back();
  }
}
