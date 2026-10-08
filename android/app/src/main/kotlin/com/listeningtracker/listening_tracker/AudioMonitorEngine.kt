package com.listeningtracker.listening_tracker

import android.Manifest
import android.bluetooth.BluetoothA2dp
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

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
 * - AudioManager.isMusicActive() for AudioFlinger stream active status
 * - BluetoothA2dp profile proxy for hardware Bluetooth audio streaming status
 * - AudioManager.getDevices() (API 23+) for device enumeration
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

    // Callback to request start/stop of foreground service based on Bluetooth connection lifecycle
    var onMonitoringLifecycleRequested: ((start: Boolean) -> Unit)? = null

    // Track monitoring status to prevent duplicate callbacks or registrations
    var isMonitoring = false
        private set

    // State resolver reconciling AudioPlaybackConfiguration + AudioManager.isMusicActive() + BluetoothA2dp
    private val playbackResolver = PlaybackStateResolver()

    private var lastOutputDeviceType: Int = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
    private var lastOutputDeviceName: String = "Phone Speaker"

    // Track connected headphone/earphone devices
    private val connectedAudioDevices = mutableMapOf<Int, AudioDeviceSnapshot>()

    // Bluetooth A2DP profile proxy to check hardware streaming state on Bluetooth earbuds
    private var bluetoothA2dp: BluetoothA2dp? = null
    private var a2dpReceiverRegistered = false

    private val bluetoothProfileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            if (profile == BluetoothProfile.A2DP) {
                bluetoothA2dp = proxy as? BluetoothA2dp
                Log.d(TAG, "BluetoothA2dp profile proxy connected")
            }
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile == BluetoothProfile.A2DP) {
                bluetoothA2dp = null
                Log.d(TAG, "BluetoothA2dp profile proxy disconnected")
            }
        }
    }

    private val a2dpPlayingReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            if (intent.action == BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED) {
                val state = intent.getIntExtra(BluetoothA2dp.EXTRA_STATE, -1)
                Log.d(TAG, "A2DP playing state changed: state=$state")
                processPlaybackConfigs(audioManager.activePlaybackConfigurations)
            }
        }
    }

    // =========================================================================
    // Audio Device Callback — tracks device connections/disconnections
    // =========================================================================
    private val audioDeviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<AudioDeviceInfo>) {
            var bluetoothDeviceAdded = false
            for (device in addedDevices) {
                if (!device.isSink) continue
                if (!isTrackableDevice(device)) continue

                val snapshot = AudioDeviceSnapshot.from(device)
                connectedAudioDevices[device.id] = snapshot
                bluetoothDeviceAdded = true

                Log.d(TAG, "Trackable device connected: ${snapshot.name} (${snapshot.typeName})")
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

            if (bluetoothDeviceAdded) {
                // Bluetooth device connected -> start monitoring automatically if not already active
                if (!isMonitoring) {
                    Log.d(TAG, "Bluetooth audio device connected -> starting monitoring automatically")
                    startMonitoring()
                    onMonitoringLifecycleRequested?.invoke(true)
                }
                checkAudioOutputChange()
                processPlaybackConfigs(audioManager.activePlaybackConfigurations)
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<AudioDeviceInfo>) {
            var bluetoothDeviceRemoved = false
            for (device in removedDevices) {
                if (!device.isSink) continue

                val snapshot = connectedAudioDevices.remove(device.id)
                    ?: if (isTrackableDevice(device)) AudioDeviceSnapshot.from(device) else null

                if (snapshot != null) {
                    bluetoothDeviceRemoved = true
                    Log.d(TAG, "Trackable device disconnected: ${snapshot.name} (${snapshot.typeName})")
                    eventListener?.onEvent(AudioEvent(
                        type = AudioEventType.DEVICE_DISCONNECTED,
                        deviceId = snapshot.id,
                        deviceAddress = snapshot.address,
                        deviceName = snapshot.name,
                        deviceType = snapshot.typeName,
                        connectionType = snapshot.connectionType,
                        timestamp = System.currentTimeMillis()
                    ))
                }
            }

            if (bluetoothDeviceRemoved) {
                checkAudioOutputChange()

                // If no trackable Bluetooth devices remain connected -> stop monitoring automatically
                if (connectedAudioDevices.isEmpty() && isMonitoring) {
                    Log.d(TAG, "All Bluetooth audio devices disconnected -> stopping monitoring automatically")
                    stopMonitoring()
                    onMonitoringLifecycleRequested?.invoke(false)
                }
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

    init {
        // Always listen for audio device connections/disconnections
        audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
    }

    /**
     * Initializes Bluetooth A2DP proxy and checks initial device connections.
     * MUST be called AFTER eventListener and onMonitoringLifecycleRequested are attached
     * to prevent invoking callbacks on null listeners.
     */
    fun initialize() {
        initBluetoothA2dp()
        checkInitialConnectedDevices()
    }

    /**
     * Disposes the engine and releases all system callbacks and profile proxies.
     */
    fun dispose() {
        stopMonitoring()
        try {
            audioManager.unregisterAudioDeviceCallback(audioDeviceCallback)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister audioDeviceCallback", e)
        }

        try {
            bluetoothA2dp?.let { proxy ->
                val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                val bluetoothAdapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
                bluetoothAdapter?.closeProfileProxy(BluetoothProfile.A2DP, proxy)
                bluetoothA2dp = null
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close BluetoothA2dp proxy", e)
        }

        eventListener = null
        onMonitoringLifecycleRequested = null
        connectedAudioDevices.clear()
        Log.d(TAG, "AudioMonitorEngine disposed")
    }

    private fun initBluetoothA2dp() {
        try {
            val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val bluetoothAdapter = bluetoothManager?.adapter ?: BluetoothAdapter.getDefaultAdapter()
            bluetoothAdapter?.getProfileProxy(context, bluetoothProfileListener, BluetoothProfile.A2DP)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to initialize BluetoothA2dp profile proxy", e)
        }
    }

    private fun checkInitialConnectedDevices() {
        val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        for (device in outputDevices) {
            if (isTrackableDevice(device)) {
                val snapshot = AudioDeviceSnapshot.from(device)
                connectedAudioDevices[device.id] = snapshot
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

        // If a Bluetooth trackable device is ALREADY connected at launch:
        if (connectedAudioDevices.isNotEmpty()) {
            Log.d(TAG, "Found ${connectedAudioDevices.size} connected Bluetooth devices at launch -> starting monitoring")
            startMonitoring()
            onMonitoringLifecycleRequested?.invoke(true)
        } else {
            Log.d(TAG, "No Bluetooth devices connected at launch -> monitoring remains OFF")
        }
    }

    // =========================================================================
    // Public API
    // =========================================================================

    fun startMonitoring() {
        if (isMonitoring) {
            Log.d(TAG, "Audio monitoring already running; ignoring duplicate start")
            return
        }
        isMonitoring = true
        Log.d(TAG, "Starting audio playback monitoring")

        // Register for audio playback state changes
        audioManager.registerAudioPlaybackCallback(audioPlaybackCallback, mainHandler)

        // Register for Bluetooth A2DP playing state broadcasts
        if (!a2dpReceiverRegistered) {
            try {
                val filter = IntentFilter(BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.registerReceiver(a2dpPlayingReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    context.registerReceiver(a2dpPlayingReceiver, filter)
                }
                a2dpReceiverRegistered = true
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register a2dpPlayingReceiver", e)
            }
        }

        // Snapshot current state
        snapshotCurrentState()
    }

    fun stopMonitoring() {
        if (!isMonitoring) {
            Log.d(TAG, "Audio monitoring not running; ignoring stop")
            return
        }
        isMonitoring = false
        Log.d(TAG, "Stopping audio playback monitoring")

        try {
            audioManager.unregisterAudioPlaybackCallback(audioPlaybackCallback)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to unregister audioPlaybackCallback", e)
        }

        if (a2dpReceiverRegistered) {
            try {
                context.unregisterReceiver(a2dpPlayingReceiver)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to unregister a2dpPlayingReceiver", e)
            }
            a2dpReceiverRegistered = false
        }

        playbackResolver.reset(false)
    }

    /**
     * Returns the current state as a map suitable for sending to Flutter.
     */
    fun getCurrentState(): Map<String, Any?> {
        val configs = audioManager.activePlaybackConfigurations
        val hasMedia = hasMediaPlayback(configs)
        val isMusicActive = queryIsMusicActive()
        val isA2dpStreaming = queryIsA2dpPlaying()
        val isPlaying = hasMedia || isMusicActive || isA2dpStreaming
        val outputDevice = getCurrentOutputDevice()
        val outputAddress = if (outputDevice != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try { outputDevice.address ?: "" } catch (e: Exception) { "" }
        } else ""

        return mapOf(
            "isMonitoring" to isMonitoring,
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
        val configs = audioManager.activePlaybackConfigurations
        val hasMedia = hasMediaPlayback(configs)
        val isMusicActive = queryIsMusicActive()
        val isA2dpStreaming = queryIsA2dpPlaying()
        playbackResolver.reset(hasMedia || isMusicActive || isA2dpStreaming)

        val outputDevice = getCurrentOutputDevice()
        if (outputDevice != null) {
            lastOutputDeviceType = outputDevice.type
            lastOutputDeviceName = outputDevice.productName?.toString() ?: "Unknown"
        }

        Log.d(TAG, "Initial state: ${connectedAudioDevices.size} trackable devices, " +
                "hasMedia=$hasMedia, isMusicActive=$isMusicActive, isA2dp=$isA2dpStreaming, isPlaying=${playbackResolver.isCurrentlyPlaying}, output=$lastOutputDeviceName")
    }

    private fun queryIsMusicActive(): Boolean {
        return try {
            audioManager.isMusicActive
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query isMusicActive", e)
            false
        }
    }

    private fun queryIsA2dpPlaying(): Boolean {
        val a2dp = bluetoothA2dp ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED) {
                    return false
                }
            }
            val devices = a2dp.connectedDevices
            devices.any { a2dp.isA2dpPlaying(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to query isA2dpPlaying", e)
            false
        }
    }

    data class PlaybackConfigInfo(
        val playerType: String,
        val usage: Int,
        val usageName: String,
        val playerState: Int,
        val playerStateName: String,
        val isActive: Boolean,
        val rawString: String
    )

    private fun inspectConfigs(configs: List<AudioPlaybackConfiguration>): List<PlaybackConfigInfo> {
        return configs.map { config ->
            val usage = config.audioAttributes.usage
            val usageName = getUsageName(usage)

            var playerTypeInt = -1
            try {
                val method = config.javaClass.getMethod("getPlayerType")
                playerTypeInt = (method.invoke(config) as? Int) ?: -1
            } catch (_: Exception) {}
            val playerType = getPlayerTypeName(playerTypeInt)

            var playerState = -1
            try {
                val method = config.javaClass.getMethod("getPlayerState")
                playerState = (method.invoke(config) as? Int) ?: -1
            } catch (_: Exception) {}

            var isActive = false
            try {
                val method = config.javaClass.getMethod("isActive")
                isActive = (method.invoke(config) as? Boolean) ?: false
            } catch (_: Exception) {
                isActive = (playerState == 2)
            }

            val raw = config.toString()
            if (playerState == -1) {
                if (raw.contains("state:started", ignoreCase = true)) {
                    playerState = 2
                    isActive = true
                } else if (raw.contains("state:paused", ignoreCase = true)) {
                    playerState = 3
                    isActive = false
                } else if (raw.contains("state:stopped", ignoreCase = true)) {
                    playerState = 4
                    isActive = false
                } else if (raw.contains("state:idle", ignoreCase = true)) {
                    playerState = 1
                    isActive = false
                } else if (raw.contains("state:released", ignoreCase = true)) {
                    playerState = 0
                    isActive = false
                }
            }

            val stateName = when (playerState) {
                2 -> "STARTED"
                3 -> "PAUSED"
                4 -> "STOPPED"
                1 -> "IDLE"
                0 -> "RELEASED"
                else -> "UNKNOWN($playerState)"
            }

            PlaybackConfigInfo(
                playerType = playerType,
                usage = usage,
                usageName = usageName,
                playerState = playerState,
                playerStateName = stateName,
                isActive = isActive,
                rawString = raw
            )
        }
    }

    private fun hasMediaPlayback(configs: List<AudioPlaybackConfiguration>): Boolean {
        val inspected = inspectConfigs(configs)
        // A config represents active media playback if:
        // 1. Its usage is MEDIA, GAME, or UNKNOWN
        // 2. AND it is actively in STARTED state (or isActive is true)
        return inspected.any { info ->
            (info.usage == AudioAttributes.USAGE_MEDIA ||
             info.usage == AudioAttributes.USAGE_GAME ||
             info.usage == AudioAttributes.USAGE_UNKNOWN) &&
            (info.isActive || info.playerState == 2)
        }
    }

    private fun processPlaybackConfigs(configs: MutableList<AudioPlaybackConfiguration>) {
        val inspected = inspectConfigs(configs)
        val activeMediaCount = inspected.count {
            (it.usage == AudioAttributes.USAGE_MEDIA ||
             it.usage == AudioAttributes.USAGE_GAME ||
             it.usage == AudioAttributes.USAGE_UNKNOWN) &&
            (it.isActive || it.playerState == 2)
        }
        val hasMedia = activeMediaCount > 0
        val isMusicActive = queryIsMusicActive()
        val isA2dpStreaming = queryIsA2dpPlaying()

        val wasPlaying = playbackResolver.isCurrentlyPlaying
        val transition = playbackResolver.resolve(hasMedia, isMusicActive, isA2dpStreaming)
        val nowPlaying = playbackResolver.isCurrentlyPlaying

        val reason = playbackResolver.getResolutionReason(hasMedia, isMusicActive, isA2dpStreaming)
        val statesSummary = inspected.joinToString(",") { "${it.usageName}:${it.playerStateName}" }
        val diagMsg = "configs=${configs.size}, activeMedia=$activeMediaCount, states=[$statesSummary], isMusicActive=$isMusicActive, isA2dp=$isA2dpStreaming, prev=$wasPlaying, resolved=$nowPlaying, reason=$reason"

        Log.d(TAG, "Playback evaluation: transition=$transition, $diagMsg")

        val currentOutput = getCurrentOutputDevice()
        val currentType = currentOutput?.type ?: lastOutputDeviceType
        val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName
        val outputAddress = if (currentOutput != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try { currentOutput.address ?: "" } catch (e: Exception) { "" }
        } else ""

        when (transition) {
            PlaybackTransition.STARTED -> {
                Log.d(TAG, "Emitting AUDIO_STARTED for $currentName: $diagMsg")
                eventListener?.onEvent(AudioEvent(
                    type = AudioEventType.AUDIO_STARTED,
                    timestamp = System.currentTimeMillis(),
                    isAudioPlaying = true,
                    deviceId = currentOutput?.id,
                    deviceAddress = outputAddress,
                    deviceName = currentName,
                    deviceType = getDeviceTypeName(currentType),
                    connectionType = getConnectionType(currentType),
                    diagnostics = diagMsg
                ))
            }
            PlaybackTransition.STOPPED -> {
                Log.d(TAG, "Emitting AUDIO_STOPPED for $currentName: $diagMsg")
                eventListener?.onEvent(AudioEvent(
                    type = AudioEventType.AUDIO_STOPPED,
                    timestamp = System.currentTimeMillis(),
                    isAudioPlaying = false,
                    deviceId = currentOutput?.id,
                    deviceAddress = outputAddress,
                    deviceName = currentName,
                    deviceType = getDeviceTypeName(currentType),
                    connectionType = getConnectionType(currentType),
                    diagnostics = diagMsg
                ))
            }
            PlaybackTransition.NONE -> {
                // Preserves active state or remains inactive without emitting duplicate events
            }
        }

        checkAudioOutputChange()
    }

    private fun checkAudioOutputChange() {
        val currentOutput = getCurrentOutputDevice()
        val currentType = currentOutput?.type ?: AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
        val currentName = currentOutput?.productName?.toString() ?: "Phone Speaker"
        val outputAddress = if (currentOutput != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
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

    private fun getCurrentOutputDevice(): AudioDeviceInfo? {
        val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
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

    private fun getUsageName(usage: Int): String = when (usage) {
        AudioAttributes.USAGE_MEDIA -> "MEDIA"
        AudioAttributes.USAGE_GAME -> "GAME"
        AudioAttributes.USAGE_VOICE_COMMUNICATION -> "VOICE_COMM"
        AudioAttributes.USAGE_ALARM -> "ALARM"
        AudioAttributes.USAGE_NOTIFICATION -> "NOTIFICATION"
        AudioAttributes.USAGE_UNKNOWN -> "UNKNOWN"
        else -> "USAGE_$usage"
    }

    private fun getPlayerTypeName(type: Int): String = when (type) {
        1 -> "AudioTrack"
        2 -> "MediaPlayer"
        3 -> "SoundPool"
        else -> "Type_$type"
    }

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
    val previousDeviceType: String? = null,
    val diagnostics: String? = null
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
        "previousDeviceType" to previousDeviceType,
        "diagnostics" to diagnostics
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
                else -> "internal"
            }

            val address = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
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
