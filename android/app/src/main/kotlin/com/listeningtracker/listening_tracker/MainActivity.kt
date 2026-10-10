package com.listeningtracker.listening_tracker

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * MainActivity bridges Flutter and the native Android audio monitoring layer.
 *
 * Uses cached FlutterEngine shared with AudioMonitorService to provide instantaneous
 * state synchronization between background service tracking and foreground dashboard UI.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "ListeningTracker"
        private const val PERMISSION_REQUEST_CODE = 1001
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return AudioMonitorBridge.ensureFlutterEngine(context)
    }

    override fun shouldDestroyEngineWithHost(): Boolean {
        // Keep engine running if background monitoring is currently active
        val isMonitoring = AudioMonitorBridge.monitorEngine?.isMonitoring == true
        return !isMonitoring
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleStartupIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleStartupIntent(intent)
    }

    private fun handleStartupIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("auto_start_monitoring", false) == true) {
            val deviceName = intent.getStringExtra("device_name") ?: "Bluetooth Audio Device"
            Log.i(TAG, "Activity launched with auto_start_monitoring from notification for $deviceName")
            AudioMonitorBridge.handleBluetoothConnected(this, deviceName, "")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AudioMonitorBridge.setupChannels(flutterEngine, this)
    }

    /**
     * Request runtime permissions needed for the app.
     *
     * BLUETOOTH_CONNECT: Required on API 31+ to access Bluetooth device info
     * POST_NOTIFICATIONS: Required on API 33+ for the foreground service notification
     */
    fun requestRequiredPermissions() {
        val permissionsToRequest = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                != PackageManager.PERMISSION_GRANTED) {
                permissionsToRequest.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
        }

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

    override fun onDestroy() {
        // If monitoring is active, the foreground service and cached FlutterEngine continue running
        super.onDestroy()
    }
}
