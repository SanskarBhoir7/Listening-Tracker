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
        private const val STOP_CONFIRMATION_WINDOW_MS = 2000L
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

    // Cancellable 2-second stop verification window
    private var pendingStopRunnable: Runnable? = null
    private var pendingStopToken: Long = 0L

    private var lastOutputDeviceType: Int = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
    private var lastOutputDeviceName: String = "Phone Speaker"

    // Track connected headphone/earphone devices
    private val connectedAudioDevices = mutableMapOf<Int, AudioDeviceSnapshot>()

    // Bluetooth A2DP profile proxy to check hardware streaming state on Bluetooth earbuds
    private var bluetoothA2dp: BluetoothA2dp? = null
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

    private val monitoringCallbacks = MonitoringCallbacks(
        registerPlayback = { audioManager.registerAudioPlaybackCallback(audioPlaybackCallback, mainHandler) },
        unregisterPlayback = { audioManager.unregisterAudioPlaybackCallback(audioPlaybackCallback) },
        registerA2dp = {
            val filter = IntentFilter(BluetoothA2dp.ACTION_PLAYING_STATE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(a2dpPlayingReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(a2dpPlayingReceiver, filter)
            }
        },
        unregisterA2dp = { context.unregisterReceiver(a2dpPlayingReceiver) },
    )

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
                    onMonitoringLifecycleRequested?.invoke(true)
                }
                if (isMonitoring) {
                    checkAudioOutputChange()
                    processPlaybackConfigs(audioManager.activePlaybackConfigurations)
                }
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
                    cancelPendingStopVerification("trackable device disconnected: ${snapshot.name}")
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
        try {
            audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler)
            NativeLifecycleDiagnostics.record(context, "NATIVE_DEVICE_CALLBACK_REGISTERED")
        } catch (error: Exception) {
            NativeLifecycleDiagnostics.record(context, "NATIVE_DEVICE_CALLBACK_REGISTRATION_FAILED", mapOf(
                "error" to error.javaClass.name,
                "message" to (error.message ?: ""),
            ))
            throw error
        }
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
        cancelPendingStopVerification("dispose")
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
            onMonitoringLifecycleRequested?.invoke(true)
        } else {
            Log.d(TAG, "No Bluetooth devices connected at launch -> monitoring remains OFF")
        }
    }

    /**
     * Handles external Bluetooth connection event dispatched by persistent system-managed observer
     * (BluetoothConnectionReceiver or CompanionDeviceService).
     */
    fun handleDeviceConnected(name: String, address: String) {
        val alreadyTracked = connectedAudioDevices.values.any {
            (address.isNotBlank() && it.address.equals(address, ignoreCase = true)) ||
            (name.isNotBlank() && it.name.equals(name, ignoreCase = true))
        }

        if (!alreadyTracked) {
            val outputDevices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val matchedDevice = outputDevices.find {
                isTrackableDevice(it) && (
                    (address.isNotBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && it.address.equals(address, ignoreCase = true)) ||
                    it.productName?.toString()?.equals(name, ignoreCase = true) == true
                )
            }
            val snapshot = if (matchedDevice != null) {
                AudioDeviceSnapshot.from(matchedDevice)
            } else {
                AudioDeviceSnapshot(
                    id = (if (address.isNotBlank()) address.hashCode() else name.hashCode()).let { if (it == 0) 1001 else it },
                    name = name.ifBlank { "Bluetooth Audio Device" },
                    typeName = "Bluetooth A2DP",
                    connectionType = "bluetooth",
                    type = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                    address = address
                )
            }
            connectedAudioDevices[snapshot.id] = snapshot
            Log.d(TAG, "Device registered from system observer: ${snapshot.name} (${snapshot.id})")
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

        if (!isMonitoring) {
            Log.d(TAG, "Audio device active -> starting monitoring automatically")
            onMonitoringLifecycleRequested?.invoke(true)
        }
        if (isMonitoring) {
            checkAudioOutputChange()
            processPlaybackConfigs(audioManager.activePlaybackConfigurations)
        }
    }

    /**
     * Handles external Bluetooth disconnection event dispatched by persistent system-managed observer.
     */
    fun handleDeviceDisconnected(name: String, address: String) {
        val toRemove = connectedAudioDevices.values.find {
            (address.isNotBlank() && it.address.equals(address, ignoreCase = true)) ||
            (name.isNotBlank() && it.name.equals(name, ignoreCase = true))
        }

        if (toRemove != null) {
            cancelPendingStopVerification("device disconnected via system observer: ${toRemove.name}")
            connectedAudioDevices.remove(toRemove.id)
            Log.d(TAG, "Device unregistered from system observer: ${toRemove.name} (${toRemove.id})")
            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.DEVICE_DISCONNECTED,
                deviceId = toRemove.id,
                deviceAddress = toRemove.address,
                deviceName = toRemove.name,
                deviceType = toRemove.typeName,
                connectionType = toRemove.connectionType,
                timestamp = System.currentTimeMillis()
            ))
        }

        checkAudioOutputChange()

        if (connectedAudioDevices.isEmpty() && isMonitoring) {
            Log.d(TAG, "All audio devices disconnected -> stopping monitoring automatically")
            stopMonitoring()
            onMonitoringLifecycleRequested?.invoke(false)
        }
    }

    // =========================================================================
    // Public API
    // =========================================================================

    fun startMonitoring() {
        if (isMonitoring) {
            Log.d(TAG, "Audio monitoring already running; ignoring duplicate start")
            NativeLifecycleDiagnostics.record(context, "NATIVE_MONITORING_DUPLICATE_START_IGNORED")
            return
        }
        NativeLifecycleDiagnostics.record(context, "NATIVE_MONITORING_START_REQUESTED")
        try {
            monitoringCallbacks.start()

            isMonitoring = true
            snapshotCurrentState()
            NativeLifecycleDiagnostics.record(context, "NATIVE_MONITORING_ACTIVE", mapOf(
                "playbackCallbackRegistered" to monitoringCallbacks.playbackRegistered,
                "a2dpReceiverRegistered" to monitoringCallbacks.a2dpRegistered,
            ))
        } catch (error: Exception) {
            Log.e(TAG, "Native monitoring callback registration failed", error)
            monitoringCallbacks.stop()
            isMonitoring = false
            NativeLifecycleDiagnostics.record(context, "NATIVE_MONITORING_START_FAILED", mapOf(
                "error" to error.javaClass.name,
                "message" to (error.message ?: ""),
            ))
        }
    }

    fun stopMonitoring() {
        if (!isMonitoring) {
            Log.d(TAG, "Audio monitoring not running; ignoring stop")
            return
        }
        isMonitoring = false
        Log.d(TAG, "Stopping audio playback monitoring")

        cancelPendingStopVerification("stopping monitoring")

        monitoringCallbacks.stop()

        playbackResolver.reset(false)
        NativeLifecycleDiagnostics.record(context, "NATIVE_MONITORING_STOPPED")
    }

    /**
     * Returns the current state as a map suitable for sending to Flutter.
     */
    fun getCurrentState(): Map<String, Any?> {
        val configs = audioManager.activePlaybackConfigurations
        val hasMedia = hasMediaPlayback(configs)
        val isMusicActive = queryIsMusicActive()
        val isA2dpStreaming = queryIsA2dpPlaying()
        val isPlaying = hasMedia || isMusicActive || isA2dpStreaming || playbackResolver.isCurrentlyPlaying
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

    private fun cancelPendingStopVerification(reason: String) {
        if (pendingStopRunnable != null || playbackResolver.isStopPending) {
            Log.d(TAG, "Cancelling pending stop verification ($reason)")
            pendingStopRunnable?.let {
                mainHandler.removeCallbacks(it)
                pendingStopRunnable = null
            }
            pendingStopToken++
            playbackResolver.cancelPendingStop()

            val currentOutput = getCurrentOutputDevice()
            val currentType = currentOutput?.type ?: lastOutputDeviceType
            val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName

            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.STOP_CONFIRMATION_CANCELLED,
                timestamp = System.currentTimeMillis(),
                isAudioPlaying = playbackResolver.isCurrentlyPlaying,
                deviceId = currentOutput?.id,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType),
                diagnostics = "reason=$reason",
                stopConfirmationStatus = "cancelled"
            ))
        }
    }

    private fun handleStopVerificationDeadline(token: Long) {
        if (token != pendingStopToken) {
            Log.d(TAG, "Ignoring stale stop verification token=$token (current=$pendingStopToken)")
            return
        }
        pendingStopRunnable = null

        if (!isMonitoring) {
            Log.d(TAG, "Monitoring stopped before stop verification deadline; ignoring")
            playbackResolver.reset(false)
            return
        }

        // Re-query current playback state to ensure no signal became true at the deadline
        val configs = audioManager.activePlaybackConfigurations
        val hasMedia = hasMediaPlayback(configs)
        val isMusicActive = queryIsMusicActive()
        val isA2dpStreaming = queryIsA2dpPlaying()
        val isAudioActive = hasMedia || isMusicActive || isA2dpStreaming

        if (isAudioActive) {
            Log.d(TAG, "Stop verification cancelled at deadline: audio signal recovered (hasMedia=$hasMedia, isMusicActive=$isMusicActive, isA2dp=$isA2dpStreaming)")
            playbackResolver.cancelPendingStop()
            return
        }

        // All signals remained false for full 2-second confirmation window -> emit AUDIO_STOPPED exactly once
        val transition = playbackResolver.confirmPendingStop()
        if (transition == PlaybackTransition.STOPPED) {
            val currentOutput = getCurrentOutputDevice()
            val currentType = currentOutput?.type ?: lastOutputDeviceType
            val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName
            val outputAddress = if (currentOutput != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                try { currentOutput.address ?: "" } catch (e: Exception) { "" }
            } else ""

            val reason = playbackResolver.getResolutionReason(false, false, false)
            val diagMsg = "configs=${configs.size}, activeMedia=0, states=[], isMusicActive=false, isA2dp=false, prev=true, resolved=false, confirmed_after=${STOP_CONFIRMATION_WINDOW_MS}ms, reason=$reason"

            Log.d(TAG, "Emitting STOP_CONFIRMATION_CONFIRMED and AUDIO_STOPPED for $currentName after ${STOP_CONFIRMATION_WINDOW_MS}ms confirmation window: $diagMsg")

            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.STOP_CONFIRMATION_CONFIRMED,
                timestamp = System.currentTimeMillis(),
                isAudioPlaying = false,
                deviceId = currentOutput?.id,
                deviceAddress = outputAddress,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType),
                diagnostics = "confirmed_after=${STOP_CONFIRMATION_WINDOW_MS}ms",
                stopConfirmationStatus = "confirmed"
            ))

            eventListener?.onEvent(AudioEvent(
                type = AudioEventType.AUDIO_STOPPED,
                timestamp = System.currentTimeMillis(),
                isAudioPlaying = false,
                deviceId = currentOutput?.id,
                deviceAddress = outputAddress,
                deviceName = currentName,
                deviceType = getDeviceTypeName(currentType),
                connectionType = getConnectionType(currentType),
                diagnostics = diagMsg,
                playbackConfigsCount = configs.size,
                activeMediaCount = 0,
                playbackStates = "[]",
                isMusicActive = false,
                isA2dpStreaming = false,
                prevPlaying = true,
                resolvedPlaying = false,
                resolverReason = reason,
                stopConfirmationStatus = "confirmed"
            ))
        }

        checkAudioOutputChange()
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
        val isAudioActive = hasMedia || isMusicActive || isA2dpStreaming

        val wasPlaying = playbackResolver.isCurrentlyPlaying
        val currentTimestamp = System.currentTimeMillis()

        if (isAudioActive) {
            // Audio is active -> cancel any pending stop verification immediately (playback recovered or active)
            cancelPendingStopVerification("playback detected active")

            val transition = playbackResolver.resolve(hasMedia, isMusicActive, isA2dpStreaming, currentTimestamp)
            val nowPlaying = playbackResolver.isCurrentlyPlaying
            val reason = playbackResolver.getResolutionReason(hasMedia, isMusicActive, isA2dpStreaming)
            val statesSummary = inspected.joinToString(",") { "${it.usageName}:${it.playerStateName}" }
            val diagMsg = "configs=${configs.size}, activeMedia=$activeMediaCount, states=[$statesSummary], isMusicActive=$isMusicActive, isA2dp=$isA2dpStreaming, prev=$wasPlaying, resolved=$nowPlaying, reason=$reason"

            Log.d(TAG, "Playback evaluation: transition=$transition, $diagMsg")

            if (transition == PlaybackTransition.STARTED) {
                val currentOutput = getCurrentOutputDevice()
                val currentType = currentOutput?.type ?: lastOutputDeviceType
                val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName
                val outputAddress = if (currentOutput != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    try { currentOutput.address ?: "" } catch (e: Exception) { "" }
                } else ""

                Log.d(TAG, "Emitting AUDIO_STARTED for $currentName: $diagMsg")
                eventListener?.onEvent(AudioEvent(
                    type = AudioEventType.AUDIO_STARTED,
                    timestamp = currentTimestamp,
                    isAudioPlaying = true,
                    deviceId = currentOutput?.id,
                    deviceAddress = outputAddress,
                    deviceName = currentName,
                    deviceType = getDeviceTypeName(currentType),
                    connectionType = getConnectionType(currentType),
                    diagnostics = diagMsg,
                    playbackConfigsCount = configs.size,
                    activeMediaCount = activeMediaCount,
                    playbackStates = statesSummary,
                    isMusicActive = isMusicActive,
                    isA2dpStreaming = isA2dpStreaming,
                    prevPlaying = wasPlaying,
                    resolvedPlaying = true,
                    resolverReason = reason,
                    stopConfirmationStatus = "none"
                ))
            }
        } else {
            // All audio signals are false
            if (wasPlaying) {
                // Playback was active -> schedule or maintain 2-second confirmation window
                if (pendingStopRunnable == null) {
                    val token = ++pendingStopToken
                    playbackResolver.resolve(hasMedia, isMusicActive, isA2dpStreaming, currentTimestamp)

                    val statesSummary = inspected.joinToString(",") { "${it.usageName}:${it.playerStateName}" }
                    val diagMsg = "configs=${configs.size}, activeMedia=0, states=[$statesSummary], isMusicActive=false, isA2dp=false, prev=true, pending_stop=true, window=${STOP_CONFIRMATION_WINDOW_MS}ms"
                    Log.d(TAG, "All playback signals false while playing; scheduling ${STOP_CONFIRMATION_WINDOW_MS}ms confirmation window: $diagMsg")

                    val currentOutput = getCurrentOutputDevice()
                    val currentType = currentOutput?.type ?: lastOutputDeviceType
                    val currentName = currentOutput?.productName?.toString() ?: lastOutputDeviceName
                    val outputAddress = if (currentOutput != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        try { currentOutput.address ?: "" } catch (e: Exception) { "" }
                    } else ""

                    eventListener?.onEvent(AudioEvent(
                        type = AudioEventType.STOP_CONFIRMATION_SCHEDULED,
                        timestamp = currentTimestamp,
                        isAudioPlaying = true,
                        deviceId = currentOutput?.id,
                        deviceAddress = outputAddress,
                        deviceName = currentName,
                        deviceType = getDeviceTypeName(currentType),
                        connectionType = getConnectionType(currentType),
                        diagnostics = diagMsg,
                        playbackConfigsCount = configs.size,
                        activeMediaCount = 0,
                        playbackStates = statesSummary,
                        isMusicActive = false,
                        isA2dpStreaming = false,
                        prevPlaying = true,
                        resolvedPlaying = true,
                        resolverReason = "no_active_media_or_sound",
                        stopConfirmationStatus = "scheduled"
                    ))

                    val runnable = Runnable {
                        handleStopVerificationDeadline(token)
                    }
                    pendingStopRunnable = runnable
                    mainHandler.postDelayed(runnable, STOP_CONFIRMATION_WINDOW_MS)
                } else {
                    // Duplicate or intermediate callback during the pending window -> do not reschedule or duplicate
                    playbackResolver.resolve(hasMedia, isMusicActive, isA2dpStreaming, currentTimestamp)
                    Log.d(TAG, "All playback signals still false; confirmation window already running (token=$pendingStopToken)")
                }
            } else {
                // Not playing and all signals false -> remain inactive (connected-but-idle)
                playbackResolver.resolve(hasMedia, isMusicActive, isA2dpStreaming, currentTimestamp)
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
    AUDIO_OUTPUT_CHANGED,
    STOP_CONFIRMATION_SCHEDULED,
    STOP_CONFIRMATION_CANCELLED,
    STOP_CONFIRMATION_CONFIRMED
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
    val diagnostics: String? = null,
    val playbackConfigsCount: Int? = null,
    val activeMediaCount: Int? = null,
    val playbackStates: String? = null,
    val isMusicActive: Boolean? = null,
    val isA2dpStreaming: Boolean? = null,
    val prevPlaying: Boolean? = null,
    val resolvedPlaying: Boolean? = null,
    val resolverReason: String? = null,
    val stopConfirmationStatus: String? = null
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
        "diagnostics" to diagnostics,
        "playbackConfigsCount" to playbackConfigsCount,
        "activeMediaCount" to activeMediaCount,
        "playbackStates" to playbackStates,
        "isMusicActive" to isMusicActive,
        "isA2dpStreaming" to isA2dpStreaming,
        "prevPlaying" to prevPlaying,
        "resolvedPlaying" to resolvedPlaying,
        "resolverReason" to resolverReason,
        "stopConfirmationStatus" to stopConfirmationStatus
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
