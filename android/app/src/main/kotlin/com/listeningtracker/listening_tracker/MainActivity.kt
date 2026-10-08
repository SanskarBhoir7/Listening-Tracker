package com.listeningtracker.listening_tracker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity bridges Flutter and the native Android audio monitoring layer.
 *
 * Communication architecture:
 * - MethodChannel ("com.listeningtracker/audio_monitor"):
 *   For one-shot commands: startMonitoring, stopMonitoring, getCurrentState, requestPermissions
 *
 * - EventChannel ("com.listeningtracker/audio_events"):
 *   For streaming real-time audio events to Flutter (device connections, playback changes, etc.)
 *
 * This is the standard Flutter platform channel approach — no external plugins needed.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "ListeningTracker"
        private const val METHOD_CHANNEL = "com.listeningtracker/audio_monitor"
        private const val EVENT_CHANNEL = "com.listeningtracker/audio_events"
        private const val PERMISSION_REQUEST_CODE = 1001
    }

    private var eventSink: EventChannel.EventSink? = null
    private var monitorEngine: AudioMonitorEngine? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize the audio monitor engine
        monitorEngine = AudioMonitorEngine(applicationContext)

        // Set up the event listener to forward events to Flutter
        monitorEngine?.eventListener = object : AudioEventListener {
            override fun onEvent(event: AudioEvent) {
                runOnUiThread {
                    Log.d(TAG, "Sending event to Flutter: ${event.type}")
                    eventSink?.success(event.toMap())
                }
            }
        }

        // Share the engine with the foreground service
        AudioMonitorService.monitorEngine = monitorEngine

        // Wire Bluetooth-driven monitoring lifecycle to start/stop the foreground service
        monitorEngine?.onMonitoringLifecycleRequested = { shouldStart ->
            runOnUiThread {
                if (shouldStart) {
                    startMonitoringWithService()
                } else {
                    stopMonitoringWithService()
                }
            }
        }

        // ===== MethodChannel =====
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startMonitoring" -> {
                        startMonitoringWithService()
                        result.success(true)
                    }
                    "stopMonitoring" -> {
                        stopMonitoringWithService()
                        result.success(true)
                    }
                    "getCurrentState" -> {
                        val state = monitorEngine?.getCurrentState()
                            ?: mapOf("error" to "Engine not initialized")
                        result.success(state)
                    }
                    "requestPermissions" -> {
                        requestRequiredPermissions()
                        result.success(true)
                    }
                    "checkPermissions" -> {
                        result.success(checkAllPermissions())
                    }
                    else -> result.notImplemented()
                }
            }

        // ===== EventChannel =====
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    Log.d(TAG, "Flutter started listening for audio events")
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    Log.d(TAG, "Flutter stopped listening for audio events")
                    eventSink = null
                }
            })
    }

    /**
     * Start monitoring via the foreground service.
     * This ensures monitoring continues when the app is backgrounded.
     */
    private fun startMonitoringWithService() {
        Log.d(TAG, "Starting monitoring with foreground service")

        val serviceIntent = Intent(this, AudioMonitorService::class.java)

        // Use startForegroundService for API 26+
        ContextCompat.startForegroundService(this, serviceIntent)

        // Also start the engine directly in case the service takes time to start
        monitorEngine?.startMonitoring()
    }

    private fun stopMonitoringWithService() {
        Log.d(TAG, "Stopping monitoring")
        monitorEngine?.stopMonitoring()
        stopService(Intent(this, AudioMonitorService::class.java))
    }

    /**
     * Request runtime permissions needed for the app.
     *
     * BLUETOOTH_CONNECT: Required on API 31+ to access Bluetooth device info
     * POST_NOTIFICATIONS: Required on API 33+ for the foreground service notification
     *
     * Note: Audio monitoring itself (AudioDeviceCallback, AudioPlaybackCallback)
     * does NOT require any runtime permissions. Only Bluetooth device name access
     * and notification display do.
     */
    private fun requestRequiredPermissions() {
        val permissionsToRequest = mutableListOf<String>()

        // BLUETOOTH_CONNECT is needed for BT device names on API 31+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED) {
                permissionsToRequest.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }

        // POST_NOTIFICATIONS is needed on API 33+ for foreground service notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
                permissionsToRequest.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        if (permissionsToRequest.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                permissionsToRequest.toTypedArray(),
                PERMISSION_REQUEST_CODE
            )
        }
    }

    private fun checkAllPermissions(): Map<String, Boolean> {
        val permissions = mutableMapOf<String, Boolean>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions["bluetooth_connect"] = ContextCompat.checkSelfPermission(
                this, Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            // Not needed on older APIs
            permissions["bluetooth_connect"] = true
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions["post_notifications"] = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            permissions["post_notifications"] = true
        }

        return permissions
    }

    override fun onDestroy() {
        // Don't stop monitoring on activity destroy — the service keeps running
        super.onDestroy()
    }
}
