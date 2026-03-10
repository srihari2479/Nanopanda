// android/app/src/main/kotlin/com/example/nanospark/SilentFaceService.kt
//
// Foreground service that silently captures ONE front-camera frame
// whenever a protected app is detected in the foreground.
// Sends raw JPEG bytes back to Flutter via EventChannel.
//
// Flow:
//   MonitoringService (Dart) detects protected app open
//   → calls platform channel "nanopanda/silent_face/capture"
//   → this service opens Camera2, captures one frame, closes camera
//   → sends JPEG bytes via EventChannel "nanopanda/silent_face/stream"
//   → Flutter MlFaceService processes embedding → match/fail → log

package com.example.nanospark

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.ImageFormat
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

private const val TAG = "SilentFaceService"
private const val CHANNEL_ID = "nanopanda_silent_capture"
private const val NOTIF_ID   = 9001

class SilentFaceService : Service() {

    private var cameraDevice: CameraDevice? = null
    private var imageReader: ImageReader?    = null
    private var captureSession: CameraCaptureSession? = null
    private lateinit var backgroundThread: HandlerThread
    private lateinit var backgroundHandler: Handler

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startForegroundWithNotification()
        startBackgroundThread()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand — capturing face")
        captureFrame()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopBackgroundThread()
        closeCamera()
        super.onDestroy()
    }

    // ── Foreground notification (required for camera foreground service) ────────

    private fun startForegroundWithNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Security Scan",
                NotificationManager.IMPORTANCE_MIN
            ).apply { setShowBadge(false) }
            nm.createNotificationChannel(ch)
        }
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Nanopanda")
            .setContentText("Security scan in progress…")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // ── Background thread ──────────────────────────────────────────────────────

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("SilentFaceCapture").also { it.start() }
        backgroundHandler = Handler(backgroundThread.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread.quitSafely()
        try { backgroundThread.join() } catch (_: InterruptedException) {}
    }

    // ── Camera capture ─────────────────────────────────────────────────────────

    private fun captureFrame() {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val frontId = findFrontCamera(manager) ?: run {
            Log.e(TAG, "No front camera found")
            sendResult(null)
            stopSelf()
            return
        }

        try {
            imageReader = ImageReader.newInstance(640, 480, ImageFormat.JPEG, 1)
            imageReader!!.setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer: ByteBuffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    sendResult(bytes)
                } finally {
                    image.close()
                    closeCamera()
                    stopSelf()
                }
            }, backgroundHandler)

            manager.openCamera(frontId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    createCaptureSession(camera)
                }
                override fun onDisconnected(camera: CameraDevice) {
                    camera.close(); cameraDevice = null
                    sendResult(null); stopSelf()
                }
                override fun onError(camera: CameraDevice, error: Int) {
                    Log.e(TAG, "Camera error: $error")
                    camera.close(); cameraDevice = null
                    sendResult(null); stopSelf()
                }
            }, backgroundHandler)
        } catch (e: SecurityException) {
            Log.e(TAG, "Camera permission denied: $e")
            sendResult(null)
            stopSelf()
        } catch (e: Exception) {
            Log.e(TAG, "captureFrame error: $e")
            sendResult(null)
            stopSelf()
        }
    }

    private fun createCaptureSession(camera: CameraDevice) {
        val surface = imageReader!!.surface
        camera.createCaptureSession(
            listOf(surface),
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    try {
                        val request = camera
                            .createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                            .apply {
                                addTarget(surface)
                                set(CaptureRequest.CONTROL_AF_MODE,
                                    CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                                set(CaptureRequest.CONTROL_AE_MODE,
                                    CaptureRequest.CONTROL_AE_MODE_ON)
                                // Front camera — no flash
                                set(CaptureRequest.FLASH_MODE,
                                    CaptureRequest.FLASH_MODE_OFF)
                            }
                            .build()
                        session.capture(request, null, backgroundHandler)
                    } catch (e: Exception) {
                        Log.e(TAG, "Capture request error: $e")
                        sendResult(null); stopSelf()
                    }
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e(TAG, "Session config failed")
                    sendResult(null); stopSelf()
                }
            },
            backgroundHandler
        )
    }

    private fun closeCamera() {
        captureSession?.close(); captureSession = null
        cameraDevice?.close();   cameraDevice   = null
        imageReader?.close();    imageReader     = null
    }

    private fun findFrontCamera(manager: CameraManager): String? {
        return manager.cameraIdList.firstOrNull { id ->
            val chars = manager.getCameraCharacteristics(id)
            chars.get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_FRONT
        }
    }

    // ── Result delivery to Flutter ─────────────────────────────────────────────

    private fun sendResult(jpeg: ByteArray?) {
        // Post result to MainActivity via static callback
        MainActivity.onSilentCaptureResult(jpeg)
    }
}