package com.example.piliplus

import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var hdrPlayerRegistered = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerHdrPlayer(flutterEngine)
    }

    private fun registerHdrPlayer(engine: FlutterEngine) {
        if (hdrPlayerRegistered) return
        hdrPlayerRegistered = true
        engine.platformViewsController.registry.registerViewFactory(
            "piliplus/hdr_player",
            HdrPlayerFactory(this, engine.dartExecutor.binaryMessenger),
        )
        MethodChannel(engine.dartExecutor.binaryMessenger, "piliplus/hdr").setMethodCallHandler { call, result ->
            if (call.method == "displaySupportsHdr") {
                result.success(displaySupportsHdr())
            } else {
                result.notImplemented()
            }
        }
    }

    private fun displaySupportsHdr(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display
        } else {
            @Suppress("DEPRECATION")
            windowManager.defaultDisplay
        } ?: return false
        return display.hdrCapabilities?.supportedHdrTypes?.isNotEmpty() == true
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
