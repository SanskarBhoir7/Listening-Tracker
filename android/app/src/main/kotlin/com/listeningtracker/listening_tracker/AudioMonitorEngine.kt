package com.listeningtracker.listening_tracker

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Core audio monitoring engine that tracks:
 * 1. Audio device connections/disconnections (Bluetooth, wired, USB)
 * 2. Audio playback state changes (started/stopped/paused)
 * 3. Audio output routing changes
 *
 * Uses modern Android APIs:
 * - AudioManager.registerAudioDeviceCallback() (API 23+) for device events
 * - AudioManager.registerAudioPlaybackCallback() (API 26+) for playback events
 * - AudioManager.getActivePlaybackConfigurations() (API 26+) for current state
 * - AudioManager.getDevices() (API 23+) for device enumeration
 *
 * IMPORTANT LIMITATIONS:
 * - Cannot detect if earbuds are physically in the user's ears
 * - Only tracks device connection state + audio playback state
 * - Playback detection depends on app cooperation with AudioManager
 * - Some apps may not register their playback with the system
 */
class AudioMonitorEngine(private val context: Context) {

    companion object {
        private const val TAG = "AudioMonitorEngine"
    }

    private val audioManager: AudioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val mainHandler = Handler(Looper.getMainLooper())

    // Listener interface for Flutter bridge
    var eventListener: AudioEventListener? = null

    // Track last known state to detect changes
    private var lastActivePlaybackCount = 0
    private var lastOutputDeviceType: Int = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
    private var lastOutputDeviceName: String = "Phone Speaker"

    // Track connected headphone/earphone devices
    private val connectedAudioDevices = mutableMapOf<Int, AudioDeviceSnapshot>()

    // =========================================================================
    // Audio Device Callback — tracks device connections/disconnections
    // =========================================================================
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
            for (device in addedDevices) {
                // Only track output devices that are headphones/earphones/BT
                if (!device.isSink) continue
                if (!isTrackableDevice(device)) continue

                val snapshot = AudioDeviceSnapshot.from(device)
                connectedAudioDevices[device.id] = snapshot

                Log.d(TAG, "Device connected: ${snapshot.name} (${snapshot.typeName})")
                eventListener?.onEvent(AudioEvent(
                    type = AudioEventType.DEVICE_CONNECTED,
                    deviceId = snapshot.id,
                    deviceAddress = snapshot.address,
                    deviceName = snapshot.name,
                    deviceType = snapshot.typeName,
                    connectionType = snapshot.connectionType,
                    timestamp = System.currentTimeMillis()
                ))
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
            for (device in removedDevices) {
                if (!device.isSink) continue

                val snapshot = connectedAudioDevices.remove(device.id)
                    ?: AudioDeviceSnapshot.from(device)

                if (!isTrackableDevice(device)) continue

                Log.d(TAG, "Device disconnected: ${snapshot.name} (${snapshot.typeName})")
                eventListener?.onEvent(AudioEvent(
                    type = AudioEventType.DEVICE_DISCONNECTED,
                    deviceId = snapshot.id,
                    deviceAddress = snapshot.address,
                    deviceName = snapshot.name,
                    deviceType = snapshot.typeName,
                    connectionType = snapshot.connectionType,
                    timestamp = System.currentTimeMillis()
                ))

                // Check if audio output has changed as a result
                checkAudioOutputChange()
            }
        }
    }

    // =========================================================================
    // Audio Playback Callback — tracks when ANY app starts/stops audio
    // =========================================================================
    private val audioPlaybackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
            processPlaybackConfigs(configs)
        }
    }

    // =========================================================================
    // Public API
    // =========================================================================

    fun startMonitoring() {
        Log.d(TAG, "Starting audio monitoring")

        // Register for device connection/disconnection events
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)

        // Register for audio playback state changes
        audioManager.registerAudioPlaybackCallback(audioPlaybackCallback, mainHandler)

        // Snapshot current state
        snapshotCurrentState()
    }

    fun stopMonitoring() {
        Log.d(TAG, "Stopping audio monitoring")
        audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
        audioManager.unregisterAudioPlaybackCallback(audioPlaybackCallback)
    }

    /**
     * Returns the current state as a map suitable for sending to Flutter.
     */
    fun getCurrentState(): Map<String, Any?> {
        val configs = audioManager.activePlaybackConfigurations
        val isPlaying = hasMediaPlayback(configs)
        val outputDevice = getCurrentOutputDevice()
        val outputAddress = if (outputDevice != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            try { outputDevice.address ?: "" } catch (e: Exception) { "" }
        } else ""

        return mapOf(
            "isAudioPlaying" to isPlaying,
            "activePlaybackCount" to configs.size,
            "outputDeviceId" to outputDevice?.id,
            "outputDeviceAddress" to outputAddress,
            "outputDeviceName" to (outputDevice?.productName?.toString() ?: "Phone Speaker"),
            "outputDeviceType" to (outputDevice?.let { getDeviceTypeName(it.type) } ?: "Built-in Speaker"),
            "outputConnectionType" to (outputDevice?.let { getConnectionType(it.type) } ?: "internal"),
            "connectedDevices" to connectedAudioDevices.values.map { it.toMap() }
        )
    }

    // =========================================================================
    // Internal logic
    // =========================================================================

    private fun snapshotCurrentState() {
        // Enumerate currently connected output devices
        val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        for (device in outputDevices) {
            if (isTrackableDevice(device)) {
                connectedAudioDevices[device.id] = AudioDeviceSnapshot.from(device)
            }
        }

        // Check current playback state
        val configs = audioManager.activePlaybackConfigurations
        lastActivePlaybackCount = countMediaPlaybacks(configs)

        // Identify current output device
        val outputDevice = getCurrentOutputDevice()
        if (outputDevice != null) {
            lastOutputDeviceType = outputDevice.type
            lastOutputDeviceName = outputDevice.productName?.toString() ?: "Unknown"
        }

        Log.d(TAG, "Initial state: ${connectedAudioDevices.size} trackable devices, " +
                "$lastActivePlaybackCount active playbacks, output=$lastOutputDeviceName")
    }

    /**
     * Process playback configuration changes.
     * This is the core mechanism for detecting AUDIO_STARTED and AUDIO_STOPPED.
     *
     * Note: Android's AudioPlaybackCallback fires when any app starts or stops
     * audio playback. It provides a list of ALL current active playback configs.
     * We compare with the previous count to determine transitions.
     */
    private fun processPlaybackConfigs(configs: MutableList<AudioPlaybackConfiguration>) {
        val currentMediaCount = countMediaPlaybacks(configs)
        val wasPlaying = lastActivePlaybackCount > 0
        val isPlaying = currentMediaCount > 0

        Log.d(TAG, "Playback config changed: was=$lastActivePlaybackCount, now=$currentMediaCount")

        val currentOutput = getCurrentOutputDevice()
        val currentType = currentOutput?.type ?: lastOutputDeviceType
        val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName
        val outputAddress = if (currentOutput != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            try { currentOutput.address ?: "" } catch (e: Exception) { "" }
        } else ""

        if (!wasPlaying && isPlaying) {
            // Audio started
            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.AUDIO_STARTED,
                timestamp = System.currentTimeMillis(),
                isAudioPlaying = true,
                deviceId = currentOutput?.id,
                deviceAddress = outputAddress,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType)
            ))
        } else if (wasPlaying && !isPlaying) {
            // Audio stopped
            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.AUDIO_STOPPED,
                timestamp = System.currentTimeMillis(),
                isAudioPlaying = false,
                deviceId = currentOutput?.id,
                deviceAddress = outputAddress,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType)
            ))
        }

        lastActivePlaybackCount = currentMediaCount

        // Also check if the output device has changed
        checkAudioOutputChange()
    }

    /**
     * Detect when audio output switches (e.g., BT → Speaker, or Wired → Speaker).
     */
    private fun checkAudioOutputChange() {
        val currentOutput = getCurrentOutputDevice()
        val currentType = currentOutput?.type ?: AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val currentName = currentOutput?.productName?.toString() ?: "Phone Speaker"
        val outputAddress = if (currentOutput != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
            try { currentOutput.address ?: "" } catch (e: Exception) { "" }
        } else ""

        if (currentType != lastOutputDeviceType) {
            Log.d(TAG, "Audio output changed: $lastOutputDeviceName → $currentName")
            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.AUDIO_OUTPUT_CHANGED,
                timestamp = System.currentTimeMillis(),
                deviceId = currentOutput?.id,
                deviceAddress = outputAddress,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType),
                previousDeviceName = lastOutputDeviceName,
                previousDeviceType = getDeviceTypeName(lastOutputDeviceType)
            ))
            lastOutputDeviceType = currentType
            lastOutputDeviceName = currentName
        }
    }

    /**
     * Determines the current audio output device.
     * Prioritizes: BT A2DP > BLE > Wired > USB > Speaker
     *
     * Note: Android does not have a single "getActiveOutputDevice()" API.
     * We infer it from connected output devices. If multiple are connected,
     * Android's routing typically follows: BT > Wired > Speaker.
     */
    private fun getCurrentOutputDevice(): AudioDeviceInfo? {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        // Priority order matches Android's default audio routing
        val priorityOrder = listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        )

        for (priorityType in priorityOrder) {
            val device = outputs.find { it.type == priorityType }
            if (device != null) return device
        }

        return outputs.firstOrNull { it.isSink }
    }

    /**
     * Counts only media-type playbacks (USAGE_MEDIA, USAGE_GAME).
     * Excludes notification sounds, system sounds, alarms etc.
     * This prevents short notification pings from being counted as "listening".
     */
    private fun countMediaPlaybacks(configs: List<AudioPlaybackConfiguration>): Int {
        return configs.count { config ->
            val usage = config.audioAttributes.usage
            usage == android.media.AudioAttributes.USAGE_MEDIA ||
            usage == android.media.AudioAttributes.USAGE_GAME
        }
    }

    private fun hasMediaPlayback(configs: List<AudioPlaybackConfiguration>): Boolean {
        return countMediaPlaybacks(configs) > 0
    }

    /**
     * Determines if a device type is one we should track.
     * We only track external audio output devices (headphones, earphones, BT).
     * We exclude built-in speakers, telephony, etc.
     */
    private fun isTrackableDevice(device: AudioDeviceInfo): Boolean {
        if (!device.isSink) return false
        return device.type in listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE
        )
    }

    // =========================================================================
    // Helper functions for device type classification
    // =========================================================================

    private fun getDeviceTypeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth LE Headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "Bluetooth LE Speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired Headphones"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Audio Device"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "Built-in Speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "Earpiece"
        else -> "Unknown ($type)"
    }

    private fun getConnectionType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_3.5mm"
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        else -> "internal"
    }
}

// =============================================================================
// Data classes
// =============================================================================

enum class AudioEventType {
    DEVICE_CONNECTED,
    DEVICE_DISCONNECTED,
    AUDIO_STARTED,
    AUDIO_STOPPED,
    AUDIO_OUTPUT_CHANGED
}

data class AudioEvent(
    val type: AudioEventType,
    val timestamp: Long = System.currentTimeMillis(),
    val deviceId: Int? = null,
    val deviceAddress: String? = null,
    val deviceName: String? = null,
    val deviceType: String? = null,
    val connectionType: String? = null,
    val isAudioPlaying: Boolean? = null,
    val previousDeviceName: String? = null,
    val previousDeviceType: String? = null
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "type" to type.name,
        "timestamp" to timestamp,
        "deviceId" to deviceId,
        "deviceAddress" to deviceAddress,
        "deviceName" to deviceName,
        "deviceType" to deviceType,
        "connectionType" to connectionType,
        "isAudioPlaying" to isAudioPlaying,
        "previousDeviceName" to previousDeviceName,
        "previousDeviceType" to previousDeviceType
    )
}

data class AudioDeviceSnapshot(
    val id: Int,
    val name: String,
    val typeName: String,
    val connectionType: String,
    val type: Int,
    val address: String = ""
) {
    companion object {
        fun from(device: AudioDeviceInfo): AudioDeviceSnapshot {
            val typeName = when (device.type) {
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "Bluetooth A2DP"
                AudioDeviceInfo.TYPE_BLE_HEADSET -> "Bluetooth LE Headset"
                AudioDeviceInfo.TYPE_BLE_SPEAKER -> "Bluetooth LE Speaker"
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> "Wired Headset"
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "Wired Headphones"
                AudioDeviceInfo.TYPE_USB_HEADSET -> "USB Headset"
                AudioDeviceInfo.TYPE_USB_DEVICE -> "USB Audio Device"
                else -> "Unknown (${device.type})"
            }

            val connectionType = when (device.type) {
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_3.5mm"
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
                else -> "unknown"
            }

            val address = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                try { device.address ?: "" } catch (e: Exception) { "" }
            } else ""

            return AudioDeviceSnapshot(
                id = device.id,
                name = device.productName?.toString()?.ifBlank { typeName } ?: typeName,
                typeName = typeName,
                connectionType = connectionType,
                type = device.type,
                address = address
            )
        }
    }

    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "name" to name,
        "typeName" to typeName,
        "connectionType" to connectionType,
        "address" to address
    )
}

// =============================================================================
// Event listener interface
// =============================================================================

interface AudioEventListener {
    fun onEvent(event: AudioEvent)
}
