// android/app/src/main/kotlin/com/example/nanospark/MainActivity.kt
//
// Flutter MainActivity with two platform channels:
//
//   MethodChannel  "nanopanda/silent_face"
//     → "capture" : starts SilentFaceService, returns JPEG bytes to Dart
//
//   MethodChannel  "nanopanda/monitoring"
//     → "openUsageSettings" : opens Android Usage Access settings screen
//
// FIXES:
//   • onSilentCaptureResult() now posts to main-thread Handler — prevents
//     crash/hang when SilentFaceService callback arrives on background thread
//   • pendingResult timeout (8s) so Dart call never hangs forever
//   • openUsageSettings now correctly uses Settings.ACTION_USAGE_ACCESS_SETTINGS

package com.example.nanospark

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val FACE_CHANNEL       = "nanopanda/silent_face"
        private const val MONITORING_CHANNEL = "nanopanda/monitoring"

        // Main-thread handler — SilentFaceService runs on background thread
        private val mainHandler = Handler(Looper.getMainLooper())

        // Static slot: SilentFaceService posts result here
        @Volatile private var pendingResult: MethodChannel.Result? = null

        @JvmStatic
        fun onSilentCaptureResult(jpeg: ByteArray?) {
            // FIX: always post to main thread — MethodChannel.Result must be
            // called on the platform thread, not from Camera2 callback thread
            mainHandler.post {
                val result = pendingResult ?: return@post
                pendingResult = null
                if (jpeg != null) {
                    result.success(jpeg)
                } else {
                    result.error("CAPTURE_FAILED", "Silent capture returned null", null)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Silent face capture channel ──────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FACE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "capture" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "Capture already in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result

                    // Safety timeout: if SilentFaceService never calls back,
                    // release the result after 8 seconds so Dart doesn't hang
                    mainHandler.postDelayed({
                        val r = pendingResult ?: return@postDelayed
                        pendingResult = null
                        r.error("TIMEOUT", "Silent capture timed out", null)
                    }, 8_000L)

                    val intent = Intent(this, SilentFaceService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── Monitoring / settings channel ────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MONITORING_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openUsageSettings" -> {
                    // FIX: correct intent for Usage Access settings
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}