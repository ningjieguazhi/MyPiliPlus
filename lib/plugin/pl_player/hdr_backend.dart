import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/models/video_fit_type.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

/// 安卓 HDR 画面后端。
///
/// mpv 的视频在 Flutter Texture 上，是 8-bit，HDR10 的 PQ 和杜比的 HLG
/// 基线层都会被压成发灰的 SDR。这里用 Media3 的 SurfaceView 单独解视频，
/// 让系统合成器按屏幕能力做色调映射；音频和进度仍由 mpv 负责。
class HdrBackend {
  static const viewType = 'piliplus/hdr_player';
  static const _channel = MethodChannel('piliplus/hdr');

  static bool get supported => Platform.isAndroid;

  /// 125 HDR10、126 杜比视界（B 站给的是 HLG 基线层）、129 HDR Vivid。
  static bool isHdrQuality(int? quality) =>
      quality == 125 || quality == 126 || quality == 129;

  static bool? _displaySupportsHdr;

  /// 当前屏幕是否声明了 HDR 能力。查不到时按不支持处理，退回 mpv。
  static Future<bool> displaySupportsHdr() async {
    final cached = _displaySupportsHdr;
    if (cached != null) return cached;
    if (!supported) return _displaySupportsHdr = false;
    try {
      final value = await _channel.invokeMethod<bool>('displaySupportsHdr');
      return _displaySupportsHdr = value ?? false;
    } catch (e) {
      debugPrintSynchronously('[PiliHDR] display query failed: $e');
      return _displaySupportsHdr = false;
    }
  }

  MethodChannel? _viewChannel;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Media3 进入 STATE_READY 之前 `position` 一直是 0，不能拿来算漂移。
  bool mediaReady = false;

  /// 必须走 Hybrid Composition。`AndroidView` 默认请求 TLHC，而引擎对
  /// `SurfaceView` 的回退是 Virtual Display，画面会进纹理、HDR 信号丢失；
  /// `initSurfaceAndroidView` 请求 `hybridFallback`，引擎检测到 SurfaceView
  /// 后落到真正的混合编排，SurfaceView 留在窗口里。
  Widget buildView({Key? key, VoidCallback? onCreated}) {
    return PlatformViewLink(
      key: key,
      viewType: viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const {},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: params.viewType,
          layoutDirection: TextDirection.ltr,
          onFocus: () => params.onFocusChanged(true),
        );
        controller
          ..addOnPlatformViewCreatedListener((id) {
            params.onPlatformViewCreated(id);
            _onCreated(id);
            onCreated?.call();
          })
          ..create();
        return controller;
      },
    );
  }

  void _onCreated(int id) {
    _viewChannel = MethodChannel('piliplus/hdr_player_$id')
      ..setMethodCallHandler((call) async {
        if (call.method == 'event' && call.arguments is Map) {
          final event = Map<String, dynamic>.from(call.arguments as Map);
          debugPrintSynchronously('[PiliHDR] surface $event');
          if (!_events.isClosed) _events.add(event);
        }
      });
  }

  bool get ready => _viewChannel != null;

  Future<void> open({
    required String url,
    required Duration position,
    required double rate,
    double? frameRate,
  }) {
    final channel = _viewChannel;
    if (channel == null) return Future.value();
    return channel.invokeMethod('open', {
      'url': url,
      'position': position.inMilliseconds,
      'rate': rate,
      if (frameRate != null && frameRate > 0) 'frameRate': frameRate,
      'headers': {
        'user-agent': BrowserUa.pc,
        'referer': HttpString.baseUrl,
      },
    });
  }

  Future<void> play() => _invoke('play');

  Future<void> pause() => _invoke('pause');

  Future<void> seek(Duration position) =>
      _invoke('seek', {'position': position.inMilliseconds});

  Future<void> setRate(double rate) => _invoke('setRate', {'rate': rate});

  /// 画面比例。`ratio` 是视频自身的宽高比，固定比例（4:3、16:9）时由调用方传入。
  Future<void> setFit(VideoFitType fit, {double? ratio}) => _invoke('setFit', {
    'mode': switch (fit) {
      VideoFitType.fill => 'fill',
      VideoFitType.cover => 'cover',
      _ => 'contain',
    },
    if (ratio != null && ratio > 0) 'ratio': ratio,
  });

  /// 页面返回前把 SurfaceView 藏起来，避免它的独立窗口在下一页上多停一帧。
  Future<void> hide() => _invoke('hide');

  /// 起播对齐完成后再显示，避免片头 0 帧闪一下。
  Future<void> show() => _invoke('show');

  /// 画面相对音频的漂移，正值表示画面超前。同时返回画面自己的进度。
  /// 两边报的都是各自解码器的真实进度，没有折算。
  Future<
    ({
      Duration drift,
      Duration video,
      double? hdrSdrRatio,
      double? brightness,
      double? speed,
    })?
  >
  drift(Duration audioPosition) async {
    final channel = _viewChannel;
    if (channel == null) return null;
    final raw = await channel.invokeMethod<Object?>('position');
    if (raw is! Map) return null;
    // 优先用真正上屏的帧 PTS。`currentPosition` 在 seek 后会立刻跳，
    // 画面还停在旧帧，拿它算漂移会对齐日志、对不齐画面。
    final ms = raw['rendered'] ?? raw['position'];
    if (ms is! num) return null;
    final video = Duration(milliseconds: ms.round());
    final ratio = raw['hdrSdrRatio'];
    final brightness = raw['brightness'];
    final speed = raw['speed'];
    return (
      drift: video - audioPosition,
      video: video,
      hdrSdrRatio: ratio is num ? ratio.toDouble() : null,
      brightness: brightness is num ? brightness.toDouble() : null,
      speed: speed is num ? speed.toDouble() : null,
    );
  }

  /// 用当前音频进度给画面定基准，只在画面进入 STATE_READY 后有效。
  Future<void> anchor(Duration position) =>
      _invoke('anchor', {'position': position.inMilliseconds});

  Future<void> _invoke(String method, [Map<String, Object>? args]) {
    final channel = _viewChannel;
    if (channel == null) return Future.value();
    return channel.invokeMethod(method, args);
  }

  void dispose() {
    final channel = _viewChannel;
    _viewChannel = null;
    if (channel != null) {
      channel.setMethodCallHandler(null);
      channel.invokeMethod<void>('dispose').catchError((_) {});
    }
    if (!_events.isClosed) _events.close();
  }
}
