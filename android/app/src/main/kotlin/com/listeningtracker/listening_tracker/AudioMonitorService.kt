package com.listeningtracker.listening_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat

/**
 * Minimal foreground service for continuous audio/device monitoring.
 *
 * Keeps the application process alive and active when Bluetooth earbuds are connected
 * and audio playback is being monitored, without keeping an unnecessary always-on
 * foreground service when no audio devices are connected.
 */
class AudioMonitorService : Service() {

    companion object {
        private const val TAG = "AudioMonitorService"
        const val NOTIFICATION_CHANNEL_ID = "listening_tracker_monitor"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START_MONITORING = "com.listeningtracker.action.START_MONITORING"
        const val ACTION_STOP_MONITORING = "com.listeningtracker.action.STOP_MONITORING"
        const val EXTRA_DEVICE_NAME = "device_name"
        const val EXTRA_DEVICE_ADDRESS = "device_address"

        // Engine reference shared with the Flutter plugin
        var monitorEngine: AudioMonitorEngine? = null
    }

    private var activeDeviceName: String? = null
    private var isForegroundActive = false

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "AudioMonitorService created")
        NativeLifecycleDiagnostics.record(this, "SERVICE_CREATED")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.d(TAG, "Service onStartCommand: action=$action, startId=$startId")
        NativeLifecycleDiagnostics.record(this, "SERVICE_START_COMMAND", mapOf(
            "action" to (action ?: "sticky_restart_null_intent"),
            "startId" to startId,
        ))

        if (action == ACTION_STOP_MONITORING) {
            Log.d(TAG, "Handling ACTION_STOP_MONITORING: stopping foreground service")
            isForegroundActive = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val deviceNameExtra = intent?.getStringExtra(EXTRA_DEVICE_NAME)
        if (!deviceNameExtra.isNullOrBlank()) {
            activeDeviceName = deviceNameExtra
        }

        val notification = buildNotification(activeDeviceName)

        // If the service is already in foreground, update notification and ensure monitoring is active
        // without redundant startForeground promotion calls or diagnostic events.
        if (isForegroundActive) {
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.notify(NOTIFICATION_ID, notification)
            try {
                val engine = AudioMonitorBridge.getOrCreateMonitorEngine(applicationContext)
                monitorEngine = engine
                if (!engine.isMonitoring) {
                    engine.startMonitoring()
                }
            } catch (e: Exception) {
                Log.w(TAG, "Error ensuring engine active on existing service", e)
            }
            return START_STICKY
        }

        // Verify runtime prerequisites for connectedDevice FGS type (BLUETOOTH_CONNECT on API 31+)
        val hasBtConnect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            androidx.core.content.ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.BLUETOOTH_CONNECT
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        // Start as foreground service with appropriate type (connectedDevice on API 34+ if permitted)
        var foregroundStarted = false
        try {
            val fgsType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                if (hasBtConnect) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                fgsType
            )
            foregroundStarted = true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service with specific type, falling back", e)
            try {
                startForeground(NOTIFICATION_ID, notification)
                foregroundStarted = true
                NativeLifecycleDiagnostics.record(this, "FOREGROUND_PROMOTION_FALLBACK_SUCCEEDED", mapOf("primaryError" to e.javaClass.name))
            } catch (fallbackEx: Exception) {
                Log.e(TAG, "Fatal fallback startForeground failure", fallbackEx)
                NativeLifecycleDiagnostics.record(this, "FOREGROUND_PROMOTION_FAILED", mapOf(
                    "primaryError" to e.javaClass.name,
                    "primaryMessage" to (e.message ?: ""),
                    "fallbackError" to fallbackEx.javaClass.name,
                    "fallbackMessage" to (fallbackEx.message ?: ""),
                ))
            }
        }

        if (!foregroundStarted) {
            AudioMonitorBridge.notifyMonitoringState(this, false, "foreground_promotion_failed")
            AudioMonitorBridge.monitorEngine?.stopMonitoring()
            stopSelf(startId)
            return START_NOT_STICKY
        }
        isForegroundActive = true
        NativeLifecycleDiagnostics.record(this, "FOREGROUND_PROMOTION_SUCCEEDED", mapOf("fgsType" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) "connectedDevice|specialUse" else "specialUse"))

        // Initialize and wire FlutterEngine and AudioMonitorEngine via AudioMonitorBridge
        try {
            val engine = AudioMonitorBridge.getOrCreateMonitorEngine(applicationContext)
            AudioMonitorBridge.ensureFlutterEngine(applicationContext)
            monitorEngine = engine
            engine.startMonitoring()
            if (!engine.isMonitoring) {
                NativeLifecycleDiagnostics.record(this, "SERVICE_NATIVE_MONITORING_INACTIVE")
                AudioMonitorBridge.notifyMonitoringState(this, false, "native_callback_registration_failed")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
        } catch (error: Exception) {
            NativeLifecycleDiagnostics.record(this, "SERVICE_INITIALIZATION_FAILED", mapOf(
                "error" to error.javaClass.name,
                "message" to (error.message ?: ""),
            ))
            AudioMonitorBridge.notifyMonitoringState(this, false, "service_initialization_failed")
            AudioMonitorBridge.monitorEngine?.stopMonitoring()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        AudioMonitorBridge.notifyMonitoringState(this, true, "service_started")

        // If the service is killed by the system, restart it while tracking
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "AudioMonitorService destroyed")
        isForegroundActive = false
        NativeLifecycleDiagnostics.record(this, "SERVICE_DESTROYED")
        AudioMonitorBridge.notifyMonitoringState(this, false, "service_destroyed")
        monitorEngine?.stopMonitoring()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Listening Tracker Monitor",
            NotificationManager.IMPORTANCE_LOW  // Low importance = no sound, minimal visual
        ).apply {
            description = "Monitors audio device and playback state"
            setShowBadge(false)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(deviceName: String?): Notification {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val contentText = if (!deviceName.isNullOrBlank()) {
            "Monitoring active: $deviceName"
        } else {
            "Monitoring audio devices"
        }

        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Listening Tracker")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}
