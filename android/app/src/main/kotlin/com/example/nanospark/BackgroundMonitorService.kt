package com.example.nanospark

import android.app.*
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject

private const val TAG         = "BGMonitorSvc"
private const val CHANNEL_ID  = "nanopanda_bg_monitor"
private const val NOTIF_ID    = 8001
private const val PREFS_NAME  = "FlutterSharedPreferences"
private const val KEY_WATCHED        = "flutter.nanopanda_watched_packages"
private const val KEY_PENDING        = "flutter.nanopanda_pending_logs"
private const val KEY_CAPTURE_REQ    = "flutter.nanopanda_capture_request"
private const val KEY_CAPTURE_RESULT = "flutter.nanopanda_capture_result"

// Intent extra that tells MainActivity to run a silent capture immediately
const val EXTRA_SILENT_CAPTURE = "nanopanda_silent_capture"

class BackgroundMonitorService : Service() {

    private val mainHandler = Handler(Looper.getMainLooper())

    private val pollRunnable = object : Runnable {
        override fun run() {
            poll()
            mainHandler.postDelayed(this, 1500L)
        }
    }

    private val activePackages  = mutableSetOf<String>()
    private var prefs: SharedPreferences? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        startForegroundCompat()
        Log.i(TAG, "service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        mainHandler.post(pollRunnable)
        return START_STICKY
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(pollRunnable)
        Log.i(TAG, "service destroyed")
        super.onDestroy()
    }

    // ── Foreground notification ───────────────────────────────────────────────

    private fun startForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val ch = NotificationChannel(
                CHANNEL_ID, "App Protection",
                NotificationManager.IMPORTANCE_MIN
            ).apply { setShowBadge(false); setSound(null, null) }
            nm.createNotificationChannel(ch)
        }
        val notif = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Nanopanda")
            .setContentText("Protecting your apps…")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ── Polling ───────────────────────────────────────────────────────────────

    private fun poll() {
        val watched = getWatchedPackages()
        if (watched.isEmpty()) return
        val current = getForegroundPackage() ?: return

        // Watched app closed — clear tracking
        if (current !in watched) {
            activePackages.removeAll(activePackages.intersect(watched.toSet()))
        }

        // New watched app opened → write request AND bring MainActivity to front
        if (current in watched && current !in activePackages) {
            activePackages.add(current)
            val entryTime = System.currentTimeMillis()
            Log.i(TAG, "watched app opened: $current → launching MainActivity for capture")
            writeCaptureRequest(current, entryTime)
            launchMainActivity(current, entryTime)
        }

        // Check if Flutter already wrote a capture result (cleanup old ones)
        clearStaleResult()
    }

    // ── Capture request → SharedPreferences ──────────────────────────────────

    private fun writeCaptureRequest(pkg: String, entryTime: Long) {
        val req = JSONObject().apply {
            put("pkg",       pkg)
            put("entryTime", entryTime)
            put("status",    "pending")
        }
        prefs?.edit()
            ?.putString(KEY_CAPTURE_REQ, req.toString())
            ?.apply()
        Log.d(TAG, "capture request written for $pkg")
    }

    // ── Clean up stale results (prevent duplicate logs) ───────────────────────

    private fun clearStaleResult() {
        val raw = prefs?.getString(KEY_CAPTURE_RESULT, null) ?: return
        try {
            val res = JSONObject(raw)
            if (res.optString("status") == "done") {
                val pkg       = res.optString("pkg")
                val entryTime = res.optLong("entryTime", System.currentTimeMillis())
                val photoPath = res.optString("photoPath").takeIf { it.isNotEmpty() }

                Log.i(TAG, "capture result received: pkg=$pkg photo=$photoPath")
                prefs?.edit()?.remove(KEY_CAPTURE_RESULT)?.apply()
                activePackages.remove(pkg)

                savePendingLog(pkg, entryTime, photoPath, photoPath != null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "clearStaleResult error: $e")
            prefs?.edit()?.remove(KEY_CAPTURE_RESULT)?.apply()
        }
    }

    // ── Pending log ───────────────────────────────────────────────────────────

    private fun savePendingLog(
        pkg: String, entryTime: Long, photoPath: String?, hasPhoto: Boolean
    ) {
        try {
            val exitTime = System.currentTimeMillis()
            val arr      = JSONArray(prefs?.getString(KEY_PENDING, "[]") ?: "[]")
            val entry    = JSONObject().apply {
                put("id",              "bglog_${entryTime}_${pkg.hashCode()}")
                put("appName",         resolveAppName(pkg))
                put("appPackageName",  pkg)
                put("entryTime",       entryTime)
                put("exitTime",        exitTime)
                put("detectionReason", if (hasPhoto)
                    "Background capture — pending face verification"
                else
                    "Background access — camera unavailable")
                put("isUnwantedPerson", true)
                put("faceImagePath",   if (photoPath != null) photoPath else JSONObject.NULL)
                put("matchScore",      JSONObject.NULL)
                put("attemptCount",    1)
                put("pendingVerify",   hasPhoto)
            }
            arr.put(entry)
            prefs?.edit()?.putString(KEY_PENDING, arr.toString())?.apply()
            Log.i(TAG, "pending log saved: $pkg hasPhoto=$hasPhoto")
        } catch (e: Exception) {
            Log.e(TAG, "savePendingLog: $e")
        }
    }

    // ── Launch MainActivity for silent capture ────────────────────────────────
    // targetSdk = 34 → BAL is allowed from FOREGROUND_SERVICE on Android 14/15.
    // We bring MainActivity to the front so the camera plugin works (OEM ROMs
    // block camera access for background activities).

    private fun launchMainActivity(pkg: String, entryTime: Long) {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                )
                putExtra(EXTRA_SILENT_CAPTURE, true)
                putExtra("capture_pkg",        pkg)
                putExtra("capture_entry_time", entryTime)
            }
            startActivity(intent)
            Log.i(TAG, "launched MainActivity for capture: pkg=$pkg")
        } catch (e: Exception) {
            Log.e(TAG, "launchMainActivity failed: $e")
            // Fallback: request stays in SharedPrefs — Flutter poller will
            // pick it up next time the app comes to the foreground naturally.
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private fun getForegroundPackage(): String? = try {
        val usm   = getSystemService(UsageStatsManager::class.java)
        val now   = System.currentTimeMillis()
        val stats = usm.queryUsageStats(UsageStatsManager.INTERVAL_BEST, now - 3_000L, now)
        stats?.filter { it.packageName != packageName }
            ?.maxByOrNull { it.lastTimeUsed }?.packageName
    } catch (e: Exception) { null }

    private fun getWatchedPackages(): List<String> = try {
        val json = prefs?.getString(KEY_WATCHED, null) ?: return emptyList()
        val arr  = JSONArray(json)
        (0 until arr.length()).map { arr.getString(it) }
    } catch (e: Exception) { emptyList() }

    private fun resolveAppName(pkg: String): String = try {
        packageManager.getApplicationLabel(
            packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (e: Exception) {
        pkg.split(".").lastOrNull()?.replaceFirstChar { it.uppercase() } ?: pkg
    }
}