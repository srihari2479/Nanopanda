package com.example.nanospark

// ─────────────────────────────────────────────────────────────────────────────
// BackgroundMonitorService.kt
//
// CORRECT FLOW:
//   1. Service polls UsageStats every 1.5s for watched packages.
//   2. Watched app detected → open front camera with Camera2 API directly.
//   3. Capture one JPEG frame silently (Android shows camera indicator dot —
//      this is intentional and expected per Android policy).
//   4. Save JPEG to face_logs/ directory.
//   5. Save pending log entry to SharedPrefs with photoPath + pendingVerify=true.
//   6. Flutter reads pending logs when owner opens Nanopanda → ML compare →
//      show in Logs page.
//
// WHY Camera2 HERE (not Flutter camera plugin):
//   Flutter camera plugin requires an active Activity in the foreground.
//   When the user opens HappyPay and Nanopanda is in the background, there is
//   NO foreground Activity → Flutter plugin throws "op=CAMERA not allowed".
//   Camera2 API can be used from a Service context directly on Android 9+.
//   targetSdk=34 means the camera indicator dot appears (Android policy) which
//   is acceptable — we are not hiding the capture from Android OS.
// ─────────────────────────────────────────────────────────────────────────────

import android.Manifest
import android.annotation.SuppressLint
import android.app.*
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.*
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

private const val TAG        = "BGMonitorSvc"
private const val CHANNEL_ID = "nanopanda_bg_monitor"
private const val NOTIF_ID   = 8001

private const val PREFS_NAME         = "FlutterSharedPreferences"
private const val KEY_WATCHED        = "flutter.nanopanda_watched_packages"
private const val KEY_PENDING        = "flutter.nanopanda_pending_logs"

class BackgroundMonitorService : Service() {

    private val mainHandler  = Handler(Looper.getMainLooper())
    private val cameraHandler: Handler by lazy {
        val t = HandlerThread("CameraBackground").apply { start() }
        Handler(t.looper)
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            poll()
            mainHandler.postDelayed(this, 1500L)
        }
    }

    private val activePackages = mutableSetOf<String>()
    private var captureInProgress = false
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
                        or android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
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

        // Watched app closed → clear tracking
        if (current !in watched) {
            activePackages.removeAll(activePackages.intersect(watched.toSet()))
        }

        // New watched app opened → capture face
        if (current in watched && current !in activePackages) {
            activePackages.add(current)
            val entryTime = System.currentTimeMillis()
            Log.i(TAG, "watched app opened: $current → starting background capture")

            if (!captureInProgress) {
                captureInProgress = true
                captureAndSave(current, entryTime)
            }
        }
    }

    // ── Camera2 background capture ────────────────────────────────────────────

    @SuppressLint("MissingPermission")
    private fun captureAndSave(pkg: String, entryTime: Long) {
        // Check CAMERA permission — must be granted in AndroidManifest
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "CAMERA permission not granted — cannot capture")
            savePendingLog(pkg, entryTime, null, false)
            captureInProgress = false
            return
        }

        val manager = getSystemService(CAMERA_SERVICE) as CameraManager

        // Find front camera
        val frontCameraId = try {
            manager.cameraIdList.firstOrNull { id ->
                val chars = manager.getCameraCharacteristics(id)
                chars.get(CameraCharacteristics.LENS_FACING) ==
                        CameraCharacteristics.LENS_FACING_FRONT
            }
        } catch (e: Exception) {
            Log.e(TAG, "camera list error: $e")
            null
        }

        if (frontCameraId == null) {
            Log.e(TAG, "no front camera found")
            savePendingLog(pkg, entryTime, null, false)
            captureInProgress = false
            return
        }

        val imageReader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 1)

        imageReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val buffer = image.planes[0].buffer
                val bytes  = ByteArray(buffer.remaining())
                buffer.get(bytes)

                val savedPath = saveJpeg(pkg, bytes)
                Log.i(TAG, "face captured → $savedPath")

                mainHandler.post {
                    savePendingLog(pkg, entryTime, savedPath, savedPath != null)
                    captureInProgress = false
                }
            } catch (e: Exception) {
                Log.e(TAG, "image save error: $e")
                mainHandler.post {
                    savePendingLog(pkg, entryTime, null, false)
                    captureInProgress = false
                }
            } finally {
                image.close()
                reader.close()
            }
        }, cameraHandler)

        // Open camera and capture
        try {
            manager.openCamera(frontCameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    try {
                        val surface  = imageReader.surface
                        val builder  = camera.createCaptureRequest(
                            CameraDevice.TEMPLATE_STILL_CAPTURE)
                        builder.addTarget(surface)
                        builder.set(CaptureRequest.CONTROL_MODE,
                            CaptureRequest.CONTROL_MODE_AUTO)
                        builder.set(CaptureRequest.CONTROL_AF_MODE,
                            CaptureRequest.CONTROL_AF_MODE_AUTO)
                        builder.set(CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_ON)
                        builder.set(CaptureRequest.JPEG_QUALITY, 90)

                        camera.createCaptureSession(
                            listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    // Let AE settle for 800ms then capture
                                    cameraHandler.postDelayed({
                                        try {
                                            session.capture(builder.build(),
                                                object : CameraCaptureSession.CaptureCallback() {
                                                    override fun onCaptureCompleted(
                                                        s: CameraCaptureSession,
                                                        r: CaptureRequest,
                                                        result: TotalCaptureResult
                                                    ) {
                                                        // image arrives via ImageReader listener
                                                        // Close camera after short delay
                                                        cameraHandler.postDelayed({
                                                            try { camera.close() } catch (_: Exception) {}
                                                        }, 500)
                                                    }
                                                    override fun onCaptureFailed(
                                                        s: CameraCaptureSession,
                                                        r: CaptureRequest,
                                                        failure: CaptureFailure
                                                    ) {
                                                        Log.e(TAG, "capture failed: ${failure.reason}")
                                                        camera.close()
                                                        mainHandler.post {
                                                            savePendingLog(pkg, entryTime, null, false)
                                                            captureInProgress = false
                                                        }
                                                    }
                                                },
                                                cameraHandler
                                            )
                                        } catch (e: Exception) {
                                            Log.e(TAG, "capture request error: $e")
                                            camera.close()
                                            mainHandler.post {
                                                savePendingLog(pkg, entryTime, null, false)
                                                captureInProgress = false
                                            }
                                        }
                                    }, 800)
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    Log.e(TAG, "session configure failed")
                                    camera.close()
                                    mainHandler.post {
                                        savePendingLog(pkg, entryTime, null, false)
                                        captureInProgress = false
                                    }
                                }
                            },
                            cameraHandler
                        )
                    } catch (e: Exception) {
                        Log.e(TAG, "session creation error: $e")
                        camera.close()
                        mainHandler.post {
                            savePendingLog(pkg, entryTime, null, false)
                            captureInProgress = false
                        }
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    mainHandler.post { captureInProgress = false }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.e(TAG, "camera error: $error")
                    camera.close()
                    mainHandler.post {
                        savePendingLog(pkg, entryTime, null, false)
                        captureInProgress = false
                    }
                }
            }, cameraHandler)
        } catch (e: Exception) {
            Log.e(TAG, "openCamera error: $e")
            savePendingLog(pkg, entryTime, null, false)
            captureInProgress = false
        }
    }

    // ── Save JPEG ─────────────────────────────────────────────────────────────

    private fun saveJpeg(pkg: String, bytes: ByteArray): String? {
        return try {
            // Match Flutter's getApplicationDocumentsDirectory() path
            val baseDir = File(filesDir.parent ?: filesDir.absolutePath, "app_flutter/face_logs")
            if (!baseDir.exists()) baseDir.mkdirs()

            val filename = "face_${pkg.replace('.', '_')}_${System.currentTimeMillis()}.jpg"
            val file     = File(baseDir, filename)
            FileOutputStream(file).use { it.write(bytes) }
            Log.d(TAG, "JPEG saved: ${file.absolutePath} (${bytes.size} bytes)")
            file.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "saveJpeg error: $e")
            null
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