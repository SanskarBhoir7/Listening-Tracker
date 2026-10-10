package com.listeningtracker.listening_tracker

import android.companion.CompanionDeviceService
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * System-managed CompanionDeviceService for API 31+.
 * Bound automatically by Android OS when an associated companion device appears/disappears.
 *
 * Crucially, because CompanionDeviceService is bound by the OS system service,
 * the app is granted the ability to start a foreground service without being blocked
 * by background start restrictions (via REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND).
 */
@RequiresApi(Build.VERSION_CODES.S)
class BluetoothCompanionService : CompanionDeviceService() {

    companion object {
        private const val TAG = "BtCompanionService"
    }

    @Deprecated("Deprecated in Java")
    override fun onDeviceAppeared(address: String) {
        Log.i(TAG, "Companion device appeared (address): $address")
        NativeLifecycleDiagnostics.record(this, "COMPANION_DEVICE_APPEARED", mapOf("addressPresent" to address.isNotBlank()))
        AudioMonitorBridge.handleBluetoothConnected(this, "Companion Device", address)
    }

    @Deprecated("Deprecated in Java")
    override fun onDeviceDisappeared(address: String) {
        Log.i(TAG, "Companion device disappeared (address): $address")
        NativeLifecycleDiagnostics.record(this, "COMPANION_DEVICE_DISAPPEARED", mapOf("addressPresent" to address.isNotBlank()))
        AudioMonitorBridge.handleBluetoothDisconnected(this, "Companion Device", address)
    }

    override fun onDeviceAppeared(associationInfo: android.companion.AssociationInfo) {
        val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            associationInfo.deviceMacAddress?.toString() ?: ""
        } else {
            ""
        }
        val name = associationInfo.displayName?.toString() ?: "Companion Device"
        Log.i(TAG, "Companion device appeared (AssociationInfo): $name ($address)")
        NativeLifecycleDiagnostics.record(this, "COMPANION_DEVICE_APPEARED", mapOf("deviceName" to name, "addressPresent" to address.isNotBlank()))
        AudioMonitorBridge.handleBluetoothConnected(this, name, address)
    }

    override fun onDeviceDisappeared(associationInfo: android.companion.AssociationInfo) {
        val name = associationInfo.displayName?.toString() ?: "Companion Device"
        Log.i(TAG, "Companion device disappeared (AssociationInfo): $name")
        NativeLifecycleDiagnostics.record(this, "COMPANION_DEVICE_DISAPPEARED", mapOf("deviceName" to name))
        AudioMonitorBridge.handleBluetoothDisconnected(this, name, "")
    }
}
