// android/app/src/main/kotlin/com/example/nanospark/MainActivity.kt
//
// KEY FIX: onNewIntent() handles EXTRA_SILENT_CAPTURE flag.
//
// When BackgroundMonitorService detects a watched app, it:
//   1. Writes a capture request to SharedPrefs.
//   2. Launches MainActivity with EXTRA_SILENT_CAPTURE=true via startActivity().
//
// MainActivity.onNewIntent() receives this, then sends a MethodChannel event
// to Flutter: "silentCaptureReady". The Flutter MonitoringProvider listens for
// this signal and immediately calls _silentCapture() — now in foreground
// Activity context so the camera plugin works without OEM AppOps block.
//
// This is the key architectural fix: camera ONLY opens when Activity is in
// foreground. The Kotlin service never touches the camera.

package com.example.nanospark

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    companion object {
        private const val MONITORING_CHANNEL   = "nanopanda/monitoring"
        private const val BG_MONITOR_CHANNEL   = "nanopanda/bg_monitor"
        private const val BG_CAPTURE_CHANNEL   = "nanopanda/bg_capture"
        private const val SCREEN_EVENT_CHANNEL = "nanopanda/screen_events"

        // EventChannel for pushing events FROM Kotlin TO Flutter
        private const val CAPTURE_EVENT_CHANNEL = "nanopanda/capture_events"

        private const val PREFS_NAME  = "FlutterSharedPreferences"
        private const val KEY_WATCHED = "flutter.nanopanda_watched_packages"
        private const val KEY_EMBED   = "flutter.nanopanda_face_embedding"
        private const val KEY_PENDING = "flutter.nanopanda_pending_logs"
        private const val KEY_CAPTURE_REQ    = "flutter.nanopanda_capture_request"
        private const val KEY_CAPTURE_RESULT = "flutter.nanopanda_capture_result"

        private val mainHandler = Handler(Looper.getMainLooper())
    }

    private var screenEventSink:  EventChannel.EventSink? = null
    private var captureEventSink: EventChannel.EventSink? = null   // NEW
    private var screenReceiver:   BroadcastReceiver?      = null
    private var prefs:            SharedPreferences?      = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        setupMonitoringChannel(flutterEngine)
        setupBgMonitorChannel(flutterEngine)
        setupBgCaptureChannel(flutterEngine)
        setupScreenEventChannel(flutterEngine)
        setupCaptureEventChannel(flutterEngine)
        registerScreenReceiver()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onDestroy() {
        unregisterScreenReceiver()
        super.onDestroy()
    }

    // ── Capture Event Channel (Kotlin → Flutter push) ────────────────────────
    // Flutter listens on this EventChannel for "silentCaptureReady" events.
    // On receiving one, it immediately calls _silentCapture() while in foreground.

    private fun setupCaptureEventChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CAPTURE_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, events: EventChannel.EventSink?) {
                captureEventSink = events
            }
            override fun onCancel(a: Any?) { captureEventSink = null }
        })
    }

    // ── Monitoring Channel ───────────────────────────────────────────────────

    private fun setupMonitoringChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MONITORING_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getForegroundApp" -> {
                    if (!hasUsageStatsPermission()) {
                        result.error("PERMISSION_DENIED",
                            "Usage Stats permission not granted", null)
                        return@setMethodCallHandler
                    }
                    result.success(getForegroundPackage() ?: "")
                }
                "checkUsageStatsPermission" ->
                    result.success(hasUsageStatsPermission())
                "openUsageSettings" -> {
                    startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ── Background Monitor Channel ─────────────────────────────────────────

    private fun setupBgMonitorChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BG_MONITOR_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                "startBgService" -> {
                    val packages  = call.argument<List<String>>("packages")  ?: emptyList()
                    val embedding = call.argument<List<Double>>("embedding") ?: emptyList()
                    val threshold = call.argument<Double>("threshold")       ?: 0.50

                    prefs?.edit()
                        ?.putString(KEY_WATCHED, JSONArray(packages).toString())
                        ?.putString(KEY_EMBED,   JSONArray(embedding).toString())
                        ?.putFloat("flutter.nanopanda_match_threshold", threshold.toFloat())
                        ?.apply()

                    val intent = Intent(this, BackgroundMonitorService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "stopBgService" -> {
                    stopService(Intent(this, BackgroundMonitorService::class.java))
                    result.success(null)
                }

                "getPendingLogs" -> {
                    val logs = prefs?.getString(KEY_PENDING, "[]") ?: "[]"
                    prefs?.edit()?.remove(KEY_PENDING)?.apply()
                    result.success(logs)
                }

                "saveFaceEmbedding" -> {
                    val embedding = call.argument<List<Double>>("embedding") ?: emptyList()
                    prefs?.edit()
                        ?.putString(KEY_EMBED, JSONArray(embedding).toString())
                        ?.apply()
                    result.success(null)
                }

                "saveWatchedPackages" -> {
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    prefs?.edit()
                        ?.putString(KEY_WATCHED, JSONArray(packages).toString())
                        ?.apply()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // ── BG Capture Channel ─────────────────────────────────────────────────

    private fun setupBgCaptureChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BG_CAPTURE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {

                // Kept for backwards-compat polling — returns pending request or null
                "pollCaptureRequest" -> {
                    val raw = prefs?.getString(KEY_CAPTURE_REQ, null)
                    if (raw == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val req = JSONObject(raw)
                        if (req.optString("status") == "pending") {
                            req.put("status", "processing")
                            prefs?.edit()?.putString(KEY_CAPTURE_REQ, req.toString())?.apply()
                            result.success(mapOf(
                                "pkg"       to req.getString("pkg"),
                                "entryTime" to req.getLong("entryTime"),
                            ))
                        } else {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        prefs?.edit()?.remove(KEY_CAPTURE_REQ)?.apply()
                        result.success(null)
                    }
                }

                // Called by Flutter after capturing photo — photoPath may be null
                "writeCaptureResult" -> {
                    val pkg       = call.argument<String>("pkg") ?: ""
                    val entryTime = call.argument<Long>("entryTime") ?: 0L
                    val photoPath = call.argument<String>("photoPath")

                    val res = JSONObject().apply {
                        put("pkg",       pkg)
                        put("entryTime", entryTime)
                        put("photoPath", photoPath ?: "")
                        put("status",    "done")
                    }
                    prefs?.edit()
                        ?.putString(KEY_CAPTURE_RESULT, res.toString())
                        ?.remove(KEY_CAPTURE_REQ)
                        ?.apply()

                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    // ── UsageStats helpers ───────────────────────────────────────────────────

    private fun hasUsageStatsPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode   = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(), packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(), packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun getForegroundPackage(): String? {
        val usm   = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val now   = System.currentTimeMillis()
        val stats = usm.queryUsageStats(
            UsageStatsManager.INTERVAL_BEST, now - 3_000L, now)
        return stats?.filter { it.packageName != packageName }
            ?.maxByOrNull { it.lastTimeUsed }?.packageName
    }

    // ── Screen Event Channel ─────────────────────────────────────────────────

    private fun setupScreenEventChannel(flutterEngine: FlutterEngine) {
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, events: EventChannel.EventSink?) {
                screenEventSink = events
            }
            override fun onCancel(a: Any?) { screenEventSink = null }
        })
    }

    private fun registerScreenReceiver() {
        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF ->
                        mainHandler.post { screenEventSink?.success("screen_off") }
                    Intent.ACTION_SCREEN_ON ->
                        mainHandler.post { screenEventSink?.success("screen_on") }
                    Intent.ACTION_USER_PRESENT ->
                        mainHandler.post { screenEventSink?.success("screen_unlocked") }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    private fun unregisterScreenReceiver() {
        try { screenReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        screenReceiver = null
    }
}