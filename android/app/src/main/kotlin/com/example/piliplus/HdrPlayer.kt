@file:OptIn(UnstableApi::class)

package com.example.piliplus

import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.SurfaceControl
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlaybackException
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.FormatHolder
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.util.ArrayList
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * HDR 画面后端。B 站的 HDR10（qn 125）和杜比 Profile 8.4（qn 126，对外是
 * hvc1 的 HLG 基线层）都只有走 SurfaceView 才能把 PQ/HLG 交给系统合成器；
 * Flutter 的 Texture 是 8-bit，会把信号压成 SDR。
 *
 * 音频、进度、弹幕仍由 mpv 负责，这里只解码视频并静音输出。
 */
class HdrPlayerView(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
    viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {
    private val surfaceView = SurfaceView(activity)

    /**
     * Flutter 每次布局都会把根视图的宽高重置成播放窗口的大小，直接改
     * SurfaceView 的尺寸会被它覆盖，所以画面比例要做在这一层里面。
     */
    private val container =
        FrameLayout(activity).apply {
            setBackgroundColor(Color.BLACK)
            clipChildren = true
            clipToPadding = true
            addView(
                surfaceView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    Gravity.CENTER,
                ),
            )
        }
    private val channel = MethodChannel(messenger, "piliplus/hdr_player_$viewId")
    private val mainHandler = Handler(Looper.getMainLooper())

    private val renderersFactory =
        HdrRenderersFactory(activity, { sourceFrameRate }, ::emit)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
            .setEnableDecoderFallback(true)

    private val httpFactory =
        DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(20_000)

    private val player: ExoPlayer =
        ExoPlayer.Builder(activity)
            .setRenderersFactory(renderersFactory)
            .setMediaSourceFactory(DefaultMediaSourceFactory(httpFactory))
            .build()
            .apply {
                setVideoSurfaceView(surfaceView)
                volume = 0f
                trackSelectionParameters =
                    trackSelectionParameters
                        .buildUpon()
                        .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, true)
                        .build()
                addListener(Listener())
                setVideoFrameMetadataListener { presentationTimeUs, _, _, _ ->
                    lastRenderedPtsUs = presentationTimeUs
                    val target = seekTargetMs
                    if (target >= 0L) {
                        val renderedMs = presentationTimeUs / 1000L
                        // 旧帧还在队列里时 PTS 会停在 seek 前。只有新帧接近目标
                        // 才算真正落到新位置；对不上就继续等，直到超时。
                        if (abs(renderedMs - target) <= 200L) {
                            mainHandler.post { completeSeek() }
                        }
                    }
                }
                addAnalyticsListener(
                    object : AnalyticsListener {
                        override fun onDroppedVideoFrames(
                            eventTime: AnalyticsListener.EventTime,
                            droppedFrames: Int,
                            elapsedMs: Long,
                        ) {
                            emit(
                                "dropped",
                                mapOf(
                                    "dropped" to droppedFrames,
                                    "elapsed" to elapsedMs,
                                    "speed" to playbackParameters.speed,
                                ),
                            )
                        }

                        override fun onVideoDecoderInitialized(
                            eventTime: AnalyticsListener.EventTime,
                            decoderName: String,
                            initializedTimestampMs: Long,
                            initializationDurationMs: Long,
                        ) {
                            emit(
                                "decoder",
                                mapOf(
                                    "name" to decoderName,
                                    "initMs" to initializationDurationMs,
                                ),
                            )
                        }
                    },
                )
            }

    private var reportedReady = false
    private var reportedFirstFrame = false
    private var reportedSize: VideoSize? = null

    /** 最近真正要上屏的帧 PTS。`currentPosition` 在 seek 后会立刻跳，画面还停在旧帧。 */
    @Volatile
    private var lastRenderedPtsUs = C.TIME_UNSET

    private var seekAnswered = true
    private var seekResult: MethodChannel.Result? = null
    private var seekTimeout: Runnable? = null
    private var seekTargetMs = -1L
    private var hiddenForPop = false
    private var surfaceHidden = false

    /** 用户设定的播放速度。 */
    private var baseRate = 1f

    /**
     * 片源标称帧率。DASH 容器经常不带 fps，Media3 会当成 -1，
     * 二倍速时 `operating-rate` 就不会跟着提高，4K HDR 会堆管道延迟。
     */
    private var sourceFrameRate = 0f

    /** 画面比例。`contain` 留黑边，`cover` 裁掉超出的部分，`fill` 拉伸铺满。 */
    private var fitMode = "contain"

    /** 视频自身的宽高比，旋转和像素宽高比都算进去。 */
    private var videoAspect = 0.0

    /** 解码出来的画幅（未乘像素宽高比），`原始`/`限制` 两种模式要用。 */
    private var videoPixelWidth = 0
    private var videoPixelHeight = 0

    /** 当前是否已经把这扇窗切成 HDR 色域。 */
    private var hdrWindowEnabled = false

    /** 已下发的 MediaCodec scaling mode，避免每次布局都重复设置。 */
    private var appliedScalingMode = -1

    init {
        channel.setMethodCallHandler(this)
        // SurfaceView 自己有窗口，不该参与 Flutter 的命中测试，手势仍由外层处理。
        surfaceView.setOnTouchListener { _, _ -> false }
        // 全屏会改变外层窗口的比例，画面尺寸要按新窗口重算。
        container.addOnLayoutChangeListener { _, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) {
                applyFit()
            }
        }
        // 窗口色域要等拿到真实码流色彩信息再开：HDR 画质在缺流时会回退到
        // SDR 编码，先把整窗切成 HDR 会让画面发灰。
        surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    if (!hiddenForPop && surfaceHidden) {
                        setSurfaceAlpha(0f)
                    }
                    requestSurfaceHdrBrightness(hdrWindowEnabled)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            },
        )
    }

    override fun getView(): FrameLayout = container

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> {
                open(call)
                result.success(null)
            }
            "play" -> {
                player.play()
                result.success(null)
            }
            "pause" -> {
                player.pause()
                result.success(null)
            }
            "seek" -> seekTo(call.argument<Number>("position")?.toLong() ?: 0L, result)
            "setRate" -> {
                baseRate = call.argument<Number>("rate")?.toFloat() ?: 1f
                player.setPlaybackSpeed(baseRate)
                result.success(null)
            }
            "position" ->
                result.success(
                    mapOf(
                        "position" to player.currentPosition,
                        "rendered" to renderedPositionMs(),
                        "content" to player.contentPosition,
                        "buffered" to player.bufferedPosition,
                        "hdrSdrRatio" to hdrSdrRatio(),
                        "colorMode" to activity.window.colorMode,
                        "brightness" to activity.window.attributes.screenBrightness,
                        "speed" to player.playbackParameters.speed,
                    ),
                )
            "setFit" -> {
                fitMode = call.argument<String>("mode") ?: "contain"
                val ratio = call.argument<Number>("ratio")?.toDouble() ?: 0.0
                if (ratio > 0) videoAspect = ratio
                applyFit()
                result.success(null)
            }
            "hide" -> {
                // 页面返回时先藏起来。SurfaceView 是独立窗口，等 Flutter 路由拆掉
                // 视图再释放的话，画面会在下一页上多停留一帧。
                hiddenForPop = true
                container.visibility = View.INVISIBLE
                result.success(null)
            }
            "show" -> {
                hiddenForPop = false
                surfaceHidden = false
                container.visibility = View.VISIBLE
                setSurfaceAlpha(1f)
                requestSurfaceHdrBrightness(hdrWindowEnabled)
                result.success(null)
            }
            "dispose" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun renderedPositionMs(): Long {
        val ptsUs = lastRenderedPtsUs
        return if (ptsUs == C.TIME_UNSET) player.currentPosition else ptsUs / 1000L
    }

    private fun completeSeek() {
        if (seekAnswered) return
        seekAnswered = true
        seekTargetMs = -1L
        seekTimeout?.let { mainHandler.removeCallbacks(it) }
        seekTimeout = null
        val result = seekResult
        seekResult = null
        val position = player.currentPosition
        val rendered = renderedPositionMs()
        emit(
            "seekDone",
            mapOf(
                "position" to position,
                "rendered" to rendered,
            ),
        )
        result?.success(
            mapOf(
                "position" to position,
                "rendered" to rendered,
            ),
        )
    }

    /**
     * 跳到指定位置，等那一帧真正要上屏再返回。只等 `onPositionDiscontinuity`
     * 会在时钟跳变时就返回，画面还停在旧帧，对齐日志是假的。
     */
    private fun seekTo(ms: Long, result: MethodChannel.Result) {
        completeSeek()
        seekAnswered = false
        seekResult = result
        seekTargetMs = ms
        val timeout = Runnable { completeSeek() }
        seekTimeout = timeout
        mainHandler.postDelayed(timeout, 800)
        player.seekTo(ms)
    }

    private fun open(call: MethodCall) {
        val url = call.argument<String>("url") ?: return
        val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
            .mapNotNull { (key, value) ->
                val name = key as? String ?: return@mapNotNull null
                val header = value as? String ?: return@mapNotNull null
                name to header
            }
            .toMap()
        val position = call.argument<Number>("position")?.toLong() ?: 0L
        val rate = call.argument<Number>("rate")?.toFloat() ?: 1f
        sourceFrameRate = call.argument<Number>("frameRate")?.toFloat() ?: 0f

        httpFactory.setDefaultRequestProperties(headers)
        reportedReady = false
        reportedFirstFrame = false
        reportedSize = null
        lastRenderedPtsUs = C.TIME_UNSET
        baseRate = rate
        // 上一次播放若是 HDR，换片后要等新码流的色彩信息再决定是否保持 HDR 窗口。
        if (hdrWindowEnabled) {
            applyHdrWindow(false)
        }
        // 上一次 seek 可能还挂着，别让它等到这次播放的帧才回包。
        seekTimeout?.let { mainHandler.removeCallbacks(it) }
        seekTimeout = null
        seekAnswered = true
        seekResult = null
        seekTargetMs = -1L
        // 对齐完成前先藏起来。不能用 INVISIBLE：SurfaceView 不出帧，
        // firstFrame/seek 就会一直等超时。View.alpha 也挡不住独立窗口，
        // 必须走 SurfaceControl.setAlpha。
        if (!hiddenForPop) {
            container.visibility = View.VISIBLE
            surfaceHidden = true
            setSurfaceAlpha(0f)
        }

        player.setMediaItem(MediaItem.fromUri(url), position)
        player.setPlaybackSpeed(rate)
        player.playWhenReady = false
        player.prepare()
        emit(
            "opened",
            mapOf(
                "url" to url,
                "position" to position,
                "frameRate" to sourceFrameRate,
            ),
        )
    }

    /**
     * 窗口默认是 SDR 合成。HDR10/HLG 画面要走 wide-gamut 色域，系统才会
     * 把 PQ/HLG 交给面板，而不是压成发灰的 SDR。
     */
    private fun applyHdrWindow(enable: Boolean) {
        hdrWindowEnabled = enable
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val window = activity.window ?: return
        window.colorMode =
            if (enable) {
                if (Build.VERSION.SDK_INT >= 34) {
                    ActivityInfo.COLOR_MODE_HDR
                } else {
                    ActivityInfo.COLOR_MODE_WIDE_COLOR_GAMUT
                }
            } else {
                ActivityInfo.COLOR_MODE_DEFAULT
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setPreferMinimalPostProcessing(enable)
        }
        requestSurfaceHdrBrightness(enable)
        // 不要把窗口亮度拉到 1.0：小米会把这当成 SDR 已满，HDR 头房从 8x 被压到 3x。
        // API 35 的 HDR 头房。当前编译 SDK 不一定有这个符号，反射调用即可。
        if (Build.VERSION.SDK_INT >= 35) {
            val headroom = if (enable) 8f else 0f
            var windowHeadroom = false
            var surfaceHeadroom = false
            try {
                window.javaClass.getMethod("setDesiredHdrHeadroom", Float::class.javaPrimitiveType)
                    .invoke(window, headroom)
                windowHeadroom = true
            } catch (_: Throwable) {
            }
            try {
                surfaceView.javaClass.getMethod("setDesiredHdrHeadroom", Float::class.javaPrimitiveType)
                    .invoke(surfaceView, headroom)
                surfaceHeadroom = true
            } catch (_: Throwable) {
            }
            emit(
                "hdrWindow",
                mapOf(
                    "enable" to enable,
                    "headroom" to headroom,
                    "windowHeadroom" to windowHeadroom,
                    "surfaceHeadroom" to surfaceHeadroom,
                    "colorMode" to window.colorMode,
                    "hdrSdrRatio" to hdrSdrRatio(),
                ),
            )
        }
    }

    /**
     * 码流声明的色彩是否是 HDR（PQ / HLG，或 BT.2020 广色域）。
     * 认不出来时按 SDR 处理：宁可不开 HDR 窗口，也不要把 SDR 画面撑灰。
     */
    private fun isHdrColorFormat(format: Format?): Boolean {
        val color = format?.colorInfo ?: return false
        return color.colorTransfer == C.COLOR_TRANSFER_ST2084 ||
            color.colorTransfer == C.COLOR_TRANSFER_HLG ||
            color.colorSpace == C.COLOR_SPACE_BT2020
    }

    private fun hdrSdrRatio(): Float {
        if (Build.VERSION.SDK_INT < 34) return 1f
        val display = activity.display ?: return 1f
        return if (display.isHdrSdrRatioAvailable) display.hdrSdrRatio else 1f
    }

    private fun surfaceControlOrNull(): SurfaceControl? {
        if (Build.VERSION.SDK_INT < 29) return null
        return try {
            surfaceView.surfaceControl
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * SurfaceView 自己有独立图层，改 View.alpha 经常看不见效果。
     * 这里直接改 SurfaceControl 的透明度，图层仍在合成，帧还是会出。
     */
    private fun setSurfaceAlpha(alpha: Float) {
        surfaceView.alpha = alpha
        val sc = surfaceControlOrNull() ?: return
        val txn = SurfaceControl.Transaction()
        try {
            txn.setAlpha(sc, alpha)
            txn.apply()
        } catch (_: Throwable) {
        } finally {
            txn.close()
        }
    }

    /**
     * 立刻向这块 Surface 要 HDR 头房。窗口 `desiredHdrHeadroom` 只是意向，
     * 真正生效的是 SurfaceControl 的 headroom。
     * 不要改 `screenBrightness`，也不要把 buffer 范围谎报成 SDR。
     */
    private fun requestSurfaceHdrBrightness(enable: Boolean) {
        if (Build.VERSION.SDK_INT < 35) return
        val sc = surfaceControlOrNull() ?: return
        var headroom = false
        val txn = SurfaceControl.Transaction()
        try {
            txn.setDesiredHdrHeadroom(sc, if (enable) 8f else 0f)
            headroom = true
            txn.apply()
        } catch (_: Throwable) {
        } finally {
            txn.close()
        }
        emit(
            "surfaceBrightness",
            mapOf(
                "enable" to enable,
                "headroom" to headroom,
                "hdrSdrRatio" to hdrSdrRatio(),
            ),
        )
    }

    /**
     * 外层容器的大小就是 Flutter 给的播放窗口，Media3 默认把画面拉伸到整个
     * 表面。这里按视频比例改内层 SurfaceView 的布局尺寸：`contain` 缩小并居中
     * 留黑边，`cover` 放大后由容器裁掉超出的部分，`fill` 铺满。
     * 只改内层，外层留给 Flutter 重置，两边不再互相覆盖。
     */
    private fun applyFit() {
        val aspect = videoAspect
        if (aspect <= 0.0) return
        container.post {
            val viewWidth = container.width
            val viewHeight = container.height
            if (viewWidth <= 0 || viewHeight <= 0) return@post
            val viewAspect = viewWidth.toDouble() / viewHeight
            // 1:1 像素尺寸，给 `原始` / `限制` 两种模式兜底。
            val nativeWidth =
                if (videoPixelWidth > 0) videoPixelWidth else (viewHeight * aspect).roundToInt()
            val nativeHeight =
                if (videoPixelHeight > 0) videoPixelHeight else viewHeight
            val containWidth: Int
            val containHeight: Int
            if (aspect > viewAspect) {
                containWidth = viewWidth
                containHeight = (viewWidth / aspect).roundToInt()
            } else {
                containHeight = viewHeight
                containWidth = (viewHeight * aspect).roundToInt()
            }
            val targetWidth: Int
            val targetHeight: Int
            when (fitMode) {
                "fill" -> {
                    targetWidth = FrameLayout.LayoutParams.MATCH_PARENT
                    targetHeight = FrameLayout.LayoutParams.MATCH_PARENT
                }
                "cover" ->
                    if (aspect > viewAspect) {
                        targetHeight = viewHeight
                        targetWidth = (viewHeight * aspect).roundToInt()
                    } else {
                        targetWidth = viewWidth
                        targetHeight = (viewWidth / aspect).roundToInt()
                    }
                "fitWidth" -> {
                    targetWidth = viewWidth
                    targetHeight = (viewWidth / aspect).roundToInt()
                }
                "fitHeight" -> {
                    targetHeight = viewHeight
                    targetWidth = (viewHeight * aspect).roundToInt()
                }
                "none" -> {
                    targetWidth = nativeWidth
                    targetHeight = nativeHeight
                }
                "scaleDown" ->
                    if (nativeWidth <= containWidth && nativeHeight <= containHeight) {
                        targetWidth = nativeWidth
                        targetHeight = nativeHeight
                    } else {
                        targetWidth = containWidth
                        targetHeight = containHeight
                    }
                else -> {
                    targetWidth = containWidth
                    targetHeight = containHeight
                }
            }
            val params =
                (surfaceView.layoutParams as? FrameLayout.LayoutParams)
                    ?: FrameLayout.LayoutParams(targetWidth, targetHeight, Gravity.CENTER)
            if (params.width == targetWidth && params.height == targetHeight) return@post
            params.width = targetWidth
            params.height = targetHeight
            params.gravity = Gravity.CENTER
            surfaceView.layoutParams = params
            if (appliedScalingMode != C.VIDEO_SCALING_MODE_SCALE_TO_FIT) {
                appliedScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT
                player.setVideoScalingMode(C.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            }
        }
    }

    private fun rememberSize(width: Int, height: Int, pixelRatio: Float) {
        if (width <= 0 || height <= 0) return
        val ratio = if (pixelRatio > 0f) pixelRatio else 1f
        videoPixelWidth = width
        videoPixelHeight = height
        val aspect = width.toDouble() * ratio / height
        if (abs(aspect - videoAspect) < 0.001) return
        videoAspect = aspect
        emit(
            "videoSize",
            mapOf(
                "width" to (width * ratio).roundToInt(),
                "height" to height,
            ),
        )
        applyFit()
    }

    private fun emit(event: String, data: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>(data.size + 1)
        payload["event"] = event
        payload.putAll(data)
        mainHandler.post { channel.invokeMethod("event", payload) }
    }

    private fun release() {
        applyHdrWindow(false)
        channel.setMethodCallHandler(null)
        player.release()
    }

    override fun dispose() = release()

    private inner class Listener : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_READY && !reportedReady) {
                reportedReady = true
                val format = player.videoFormat
                // 只有码流真的是 PQ/HLG 才把整窗切成 HDR：HDR 画质缺流时会
                // 回退到 SDR 编码，那时开 HDR 窗口会让画面发灰。
                applyHdrWindow(isHdrColorFormat(format))
                emit(
                    "ready",
                    mapOf(
                        "width" to (format?.width ?: 0),
                        "height" to (format?.height ?: 0),
                        "codecs" to format?.codecs,
                        "frameRate" to format?.frameRate,
                        "sourceFrameRate" to sourceFrameRate,
                        "speed" to player.playbackParameters.speed,
                        "colorTransfer" to format?.colorInfo?.colorTransfer,
                        "colorSpace" to format?.colorInfo?.colorSpace,
                        "colorMode" to activity.window.colorMode,
                        "hdrSdrRatio" to hdrSdrRatio(),
                    ),
                )
            }
        }

        override fun onRenderedFirstFrame() {
            if (reportedFirstFrame) return
            reportedFirstFrame = true
            emit(
                "firstFrame",
                mapOf(
                    "position" to player.currentPosition,
                    "rendered" to renderedPositionMs(),
                ),
            )
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width == 0 || videoSize == reportedSize) return
            reportedSize = videoSize
            rememberSize(videoSize.width, videoSize.height, videoSize.pixelWidthHeightRatio)
        }

        override fun onPlayerError(error: PlaybackException) {
            emit(
                "error",
                mapOf("code" to error.errorCode, "message" to (error.message ?: error.errorCodeName)),
            )
        }
    }
}

/**
 * 平台硬解已经够解 B 站 HEVC HDR。这里不走扩展渲染器，方便把片源
 * fps 写进 Format，让 2 倍速时 `KEY_OPERATING_RATE` 跟着提高。
 */
private class HdrRenderersFactory(
    context: Context,
    private val frameRate: () -> Float,
    private val onOperatingRate: (String, Map<String, Any?>) -> Unit,
) : DefaultRenderersFactory(context) {
    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        out.add(
            HdrVideoRenderer(
                context,
                getCodecAdapterFactory(),
                mediaCodecSelector,
                allowedVideoJoiningTimeMs,
                enableDecoderFallback,
                eventHandler,
                eventListener,
                MAX_DROPPED_VIDEO_FRAME_COUNT_TO_NOTIFY,
                frameRate,
                onOperatingRate,
            ),
        )
    }
}

private class HdrVideoRenderer(
    context: Context,
    codecAdapterFactory: MediaCodecAdapter.Factory,
    mediaCodecSelector: MediaCodecSelector,
    allowedJoiningTimeMs: Long,
    enableDecoderFallback: Boolean,
    eventHandler: Handler,
    eventListener: VideoRendererEventListener,
    maxDroppedFramesToNotify: Int,
    private val frameRate: () -> Float,
    private val onOperatingRate: (String, Map<String, Any?>) -> Unit,
) : MediaCodecVideoRenderer(
        context,
        codecAdapterFactory,
        mediaCodecSelector,
        allowedJoiningTimeMs,
        enableDecoderFallback,
        eventHandler,
        eventListener,
        maxDroppedFramesToNotify,
        DEFAULT_ASSUMED_MINIMUM_CODEC_OPERATING_RATE,
    ) {
    private var lastLoggedSpeed = Float.NaN
    private var lastLoggedRate = Float.NaN

    @Throws(ExoPlaybackException::class)
    override fun onInputFormatChanged(formatHolder: FormatHolder): DecoderReuseEvaluation? {
        patchFormat(formatHolder)
        return super.onInputFormatChanged(formatHolder)
    }

    override fun getCodecOperatingRateV23(
        targetPlaybackSpeed: Float,
        format: Format,
        streamFormats: Array<Format>,
    ): Float {
        val sourceFps = frameRate()
        val patchedFormat = withSourceFps(format, sourceFps)
        val patchedStreams =
            Array(streamFormats.size) { index ->
                withSourceFps(streamFormats[index], sourceFps)
            }
        var rate = super.getCodecOperatingRateV23(targetPlaybackSpeed, patchedFormat, patchedStreams)
        if (rate <= 0f && sourceFps > 0f && targetPlaybackSpeed > 0f) {
            rate = sourceFps * targetPlaybackSpeed
        }
        if (rate != lastLoggedRate || targetPlaybackSpeed != lastLoggedSpeed) {
            lastLoggedRate = rate
            lastLoggedSpeed = targetPlaybackSpeed
            onOperatingRate(
                "operatingRate",
                mapOf(
                    "speed" to targetPlaybackSpeed,
                    "formatFps" to patchedFormat.frameRate,
                    "sourceFps" to sourceFps,
                    "rate" to rate,
                ),
            )
        }
        return rate
    }

    private fun patchFormat(formatHolder: FormatHolder) {
        val format = formatHolder.format ?: return
        val sourceFps = frameRate()
        if (format.frameRate > 0f || sourceFps <= 0f) return
        formatHolder.format = format.buildUpon().setFrameRate(sourceFps).build()
    }

    private fun withSourceFps(format: Format, sourceFps: Float): Format {
        if (format.frameRate > 0f || sourceFps <= 0f) return format
        return format.buildUpon().setFrameRate(sourceFps).build()
    }

    private companion object {
        // MediaCodecRenderer 默认 30。低于计算出的 operating-rate 才会真正下发。
        const val DEFAULT_ASSUMED_MINIMUM_CODEC_OPERATING_RATE = 30f
    }
}
