import 'package:PiliPlus/models/common/video/cdn_type.dart';
import 'package:PiliPlus/models/common/video/video_decode_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/models_new/live/live_room_play_info/codec.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, debugPrintSynchronously, kDebugMode;

abstract final class VideoUtils {
  static CDNService cdnService = Pref.defaultCDNService;
  static String? liveCdnUrl = Pref.liveCdnUrl;
  static bool disableAudioCDN = Pref.disableAudioCDN;

  static const _proxyTf = 'proxy-tf-all-ws.bilivideo.com';

  static final _mirrorRegex = RegExp(
    r'^https?://(?:upos-\w+-(?!302)\w+|(?:upos|proxy)-tf-[^/]+)\.(?:bilivideo|akamaized)\.(?:com|net)/upgcxcode',
  );

  static final _mCdnTfRegex = RegExp(
    r'^https?://(?:(?:(?:\d{1,3}\.){3}\d{1,3}|[^/]+\.mcdn\.bilivideo\.(?:com|cn|net))(?:\:\d{1,5})?/v\d/resource)',
  );

  static String getCdnUrl(
    Iterable<String> urls, {
    CDNService? defaultCDNService,
    bool isAudio = false,
  }) {
    defaultCDNService ??= cdnService;

    if (defaultCDNService == CDNService.baseUrl) {
      return urls.first;
    }

    String? mcdnTf;
    String? mcdnUpgcxcode;

    String last = '';
    for (final url in urls) {
      last = url;
      if (_mirrorRegex.hasMatch(url)) {
        final uri = Uri.parse(url);
        if (uri.queryParameters['os'] == 'mcdn') {
          // upos-sz-mirrorcoso1.bilivideo.com os=mcdn
          mcdnUpgcxcode = url;
        } else {
          if (defaultCDNService == CDNService.backupUrl ||
              (isAudio && disableAudioCDN)) {
            return url;
          }
          return uri.replace(host: defaultCDNService.host).toString();
        }
      }

      if (_mCdnTfRegex.hasMatch(url)) {
        mcdnTf = url;
        continue;
      }

      // upos-\w*-302.* & bcache & mcdn host but upgcxcode path
      if (url.contains('/upgcxcode/')) {
        mcdnUpgcxcode = url;
        continue;
      }

      // may be deprecated
      if (url.contains('szbdyd.com')) {
        final uri = Uri.parse(url);
        final hostname =
            uri.queryParameters['xy_usource'] ?? defaultCDNService.host;
        return uri
            .replace(scheme: 'https', host: hostname, port: 443)
            .toString();
      }

      if (kDebugMode) {
        debugPrint('unknown cdn type: $url');
      }
    }

    return mcdnUpgcxcode == null
        ? mcdnTf == null
              ? last
              : Uri(
                  scheme: 'https',
                  host: _proxyTf,
                  queryParameters: {'url': mcdnTf},
                ).toString()
        : Uri.parse(mcdnUpgcxcode)
              .replace(host: defaultCDNService.host ?? CDNService.ali.host)
              .toString();
  }

  static String getLiveCdnUrl(CodecItem e, {int index = 0}) {
    final urlInfo = e.urlInfo.getOrFirst(index);
    return (liveCdnUrl ?? urlInfo.host) + e.baseUrl + urlInfo.extra;
  }

  // 杜比视界在 B 站对外是 hvc1 的 HLG 基线层（Profile 8.4，RPU 藏在 SEI 里），
  // dvh1/dvhe 只在极少数片子上出现，放在后面兜底。
  static const _dolbyPrefixes = ['hvc1', 'dvh1', 'dvhe'];
  static const _hevcPrefixes = ['hev1', 'hvc1'];

  /// HDR 三档不能交给用户的 AVC/AV1 偏好。返回 null 表示按普通规则选。
  static List<String>? hdrCodecPrefixes(int quality) {
    return switch (quality) {
      126 => _dolbyPrefixes,
      125 || 129 => _hevcPrefixes,
      _ => null,
    };
  }

  /// dash 的 `codecs` 字符串映射成枚举。
  /// 未知（例如 `dolby`）或为空时回退 [fallback]，不要抛异常打断播放。
  static VideoDecodeFormatType decodeFormatOf(
    String? codecs, {
    VideoDecodeFormatType fallback = VideoDecodeFormatType.HEVC,
  }) {
    if (codecs == null || codecs.isEmpty) return fallback;
    for (final format in VideoDecodeFormatType.values) {
      if (format.codes.any(codecs.startsWith)) return format;
    }
    return fallback;
  }

  /// 在同一画质的候选流里挑出真正要播的那条。
  /// HDR 画质按 [hdrCodecPrefixes] 锁定；该编码不存在时回退到
  /// [preferCodecs]，再没有就用列表第一条，避免选空。
  static VideoItem selectVideo({
    required int quality,
    required List<VideoItem> videos,
    required List<VideoDecodeFormatType> preferCodecs,
  }) {
    if (videos.isEmpty) {
      if (kDebugMode) {
        debugPrintSynchronously('[PiliHDR] select qn=$quality no streams');
      }
      throw StateError('no video stream for quality $quality');
    }

    VideoItem? match(bool Function(String codec) test) {
      for (final video in videos) {
        final codec = video.codecs;
        if (codec != null && test(codec)) return video;
      }
      return null;
    }

    final prefixes = hdrCodecPrefixes(quality);
    VideoItem? best;
    var reason = 'prefer-codec';
    if (prefixes != null) {
      for (final prefix in prefixes) {
        best = match((codec) => codec.startsWith(prefix));
        if (best != null) {
          reason = 'hdr-codec';
          break;
        }
      }
      reason = best == null ? 'hdr-fallback' : reason;
    }
    if (best == null) {
      for (final prefer in preferCodecs) {
        best = match((codec) => prefer.codes.any(codec.startsWith));
        if (best != null) break;
      }
    }
    if (best == null) {
      best = videos.first;
      reason = prefixes == null ? 'first' : 'hdr-first';
    }

    final offered = videos
        .map((e) => '${e.codecs}#${e.codecid}/${e.width}x${e.height}')
        .join(' | ');
    if (kDebugMode) {
      debugPrintSynchronously(
        '[PiliHDR] select qn=$quality ${best.quality.desc} '
        'reason=$reason codec=${best.codecs} codecid=${best.codecid} '
        '${best.width}x${best.height}@${best.frameRate} '
        'offered=[$offered]',
      );
    }
    return best;
  }
}
