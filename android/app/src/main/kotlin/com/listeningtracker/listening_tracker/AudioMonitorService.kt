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
 * WHY A FOREGROUND SERVICE IS NEEDED:
 * Android aggressively kills background processes. Without a foreground service,
 * the AudioDeviceCallback and AudioPlaybackCallback would stop receiving events
 * when the user switches to another app or locks the screen.
 *
 * A foreground service with a persistent notification keeps the process alive
 * and allows continuous monitoring.
 *
 * WHY specialUse (NOT mediaPlayback):
 * This app does NOT play audio — it monitors audio state. The mediaPlayback
 * foreground service type is reserved for apps that actually play/stream media.
 * specialUse is the correct type for monitoring/tracking use cases.
 *
 * This is the MINIMUM viable foreground service. It:
 * 1. Shows a persistent notification
 * 2. Keeps the process alive
 * 3. Delegates all actual work to AudioMonitorEngine
 */
class AudioMonitorService : Service() {

    companion object {
        private const val TAG = "AudioMonitorService"
        private const val NOTIFICATION_CHANNEL_ID = "listening_tracker_monitor"
        private const val NOTIFICATION_ID = 1001

        // Singleton engine reference shared with the Flutter plugin
        var monitorEngine: AudioMonitorEngine? = null
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "Service started")

        val notification = buildNotification()

        // Start as foreground service with appropriate type (connectedDevice on API 34+)
        try {
            val fgsType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
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
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start foreground service", e)
            // Fallback for older APIs where specific type isn't required
            startForeground(NOTIFICATION_ID, notification)
        }

        // Initialize the audio monitor engine if not already running
        if (monitorEngine == null) {
            monitorEngine = AudioMonitorEngine(applicationContext)
        }
        monitorEngine?.startMonitoring()

        // If the service is killed by the system, restart it
        return START_STICKY
    }

    override fun onDestroy() {
        Log.d(TAG, "Service destroyed")
        monitorEngine?.stopMonitoring()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Listening Tracker",
            NotificationManager.IMPORTANCE_LOW  // Low importance = no sound, minimal visual
        ).apply {
            description = "Monitors audio device and playback state"
            setShowBadge(false)
        }

        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // Tapping the notification opens the app
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Listening Tracker")
            .setContentText("Monitoring audio devices")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}
