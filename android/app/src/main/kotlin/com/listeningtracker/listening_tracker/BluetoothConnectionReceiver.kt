package com.listeningtracker.listening_tracker

import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Manifest-declared BroadcastReceiver acting as a persistent system-managed
 * Bluetooth connection observer.
 *
 * Survives app process death and is awakened by Android OS when Bluetooth audio devices
 * (like realme Buds T200 Lite) connect or disconnect, eliminating the requirement
 * to manually open the application to begin monitoring.
 */
class BluetoothConnectionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BtConnectionReceiver"

        /**
         * Evaluates whether the given BluetoothDevice is likely an audio peripheral (earbuds, headphones, headset).
         */
        fun isAudioPeripheral(device: BluetoothDevice?): Boolean {
            if (device == null) return false
            val btClass = try {
                device.bluetoothClass
            } catch (e: SecurityException) {
                null
            } ?: return true // If permission restricted, assume true to ensure we do not miss earbud connections

            val major = btClass.majorDeviceClass
            if (major == BluetoothClass.Device.Major.AUDIO_VIDEO) return true

            // Some Bluetooth LE earbuds report as UNCATEGORIZED or WEARABLE with audio service
            if (major == BluetoothClass.Device.Major.UNCATEGORIZED || major == BluetoothClass.Device.Major.WEARABLE) {
                if (btClass.hasService(BluetoothClass.Service.AUDIO)) return true
            }

            return false
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.d(TAG, "Received broadcast action: $action")
        NativeLifecycleDiagnostics.record(context, "BLUETOOTH_RECEIVER_INVOKED", mapOf("action" to action))

        val device: BluetoothDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }

        val deviceName = try {
            device?.name ?: "Bluetooth Audio Device"
        } catch (e: SecurityException) {
            "Bluetooth Audio Device"
        }

        val deviceAddress = try {
            device?.address ?: ""
        } catch (e: SecurityException) {
            ""
        }

        when (action) {
            BluetoothDevice.ACTION_ACL_CONNECTED -> {
                if (isAudioPeripheral(device)) {
                    Log.i(TAG, "Bluetooth audio device connected (ACL): $deviceName ($deviceAddress)")
                    NativeLifecycleDiagnostics.record(context, "BLUETOOTH_AUDIO_DEVICE_DETECTED", mapOf("action" to action, "deviceName" to deviceName))
                    AudioMonitorBridge.handleBluetoothConnected(context, deviceName, deviceAddress)
                } else {
                    Log.d(TAG, "Non-audio Bluetooth device connected; ignoring: $deviceName")
                }
            }
            BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED -> {
                val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)
                val prevState = intent.getIntExtra(BluetoothProfile.EXTRA_PREVIOUS_STATE, -1)
                Log.d(TAG, "A2DP connection state changed: $prevState -> $state for $deviceName")
                if (state == BluetoothProfile.STATE_CONNECTED) {
                    NativeLifecycleDiagnostics.record(context, "BLUETOOTH_AUDIO_DEVICE_DETECTED", mapOf("action" to action, "deviceName" to deviceName, "state" to state))
                    AudioMonitorBridge.handleBluetoothConnected(context, deviceName, deviceAddress)
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    AudioMonitorBridge.handleBluetoothDisconnected(context, deviceName, deviceAddress)
                }
            }
            BluetoothDevice.ACTION_ACL_DISCONNECTED -> {
                Log.i(TAG, "Bluetooth device disconnected (ACL): $deviceName ($deviceAddress)")
                AudioMonitorBridge.handleBluetoothDisconnected(context, deviceName, deviceAddress)
            }
        }
    }
}
