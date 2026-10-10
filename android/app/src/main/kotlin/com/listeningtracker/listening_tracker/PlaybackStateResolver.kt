package com.listeningtracker.listening_tracker

/**
 * Transitions emitted by the playback state resolver.
 */
enum class PlaybackTransition {
    NONE,
    STARTED,
    STOPPED
}

/**
 * Native playback-state resolver reconciling three signals:
 * 1. AudioPlaybackConfiguration (with playerState and isActive check)
 * 2. AudioManager.isMusicActive()
 * 3. BluetoothA2dp.isA2dpPlaying() (for Bluetooth audio devices)
 *
 * Prevents false AUDIO_STOPPED events during continuous music playback when
 * media playback configurations temporarily disappear or transition between tracks.
 */
class PlaybackStateResolver(
    private var isPlaying: Boolean = false,
    private val confirmationWindowMs: Long = 2000L
) {
    /**
     * Whether a stop verification window is currently active.
     */
    var isStopPending: Boolean = false
        private set

    /**
     * Timestamp (in milliseconds) when the stop verification window was started.
     */
    var stopPendingSinceMs: Long? = null
        private set

    /**
     * Whether the resolver currently considers playback to be active.
     */
    val isCurrentlyPlaying: Boolean
        get() = isPlaying

    /**
     * Resolves playback state transitions based on three signals:
     * 1. [hasMediaConfig]: Whether any active playback configuration matching media/game exists in STARTED state.
     * 2. [isMusicActive]: Whether AudioManager.isMusicActive() is currently true.
     * 3. [isA2dpStreaming]: Whether Bluetooth A2DP is actively streaming to connected earbuds.
     * 4. [currentTimeMs]: Current epoch milliseconds (defaults to System.currentTimeMillis()).
     *
     * State transition requirements:
     * - INACTIVE -> ACTIVE: emits STARTED immediately (0ms latency).
     * - ACTIVE -> ACTIVE: emits NONE; cancels any pending stop verification and preserves active playback.
     * - ACTIVE -> ALL FALSE:
     *     - If not already pending: marks pending stop at [currentTimeMs], returns NONE (session remains active).
     *     - If already pending and [currentTimeMs] - [stopPendingSinceMs] >= [confirmationWindowMs]:
     *       emits STOPPED exactly once (genuine pause/stop confirmed).
     *     - If already pending and [currentTimeMs] - [stopPendingSinceMs] < [confirmationWindowMs]:
     *       returns NONE (session remains active within confirmation window).
     * - INACTIVE -> INACTIVE: emits NONE.
     */
    fun resolve(
        hasMediaConfig: Boolean,
        isMusicActive: Boolean,
        isA2dpStreaming: Boolean = false,
        currentTimeMs: Long = System.currentTimeMillis()
    ): PlaybackTransition {
        val isAudioActive = hasMediaConfig || isMusicActive || isA2dpStreaming

        if (!isPlaying && isAudioActive) {
            isPlaying = true
            isStopPending = false
            stopPendingSinceMs = null
            return PlaybackTransition.STARTED
        }

        if (isPlaying && isAudioActive) {
            // Audio recovered or remains active -> cancel any pending stop window
            isStopPending = false
            stopPendingSinceMs = null
            return PlaybackTransition.NONE
        }

        if (isPlaying && !isAudioActive) {
            val pendingSince = stopPendingSinceMs
            if (!isStopPending || pendingSince == null) {
                // First detection of all false signals: start confirmation window
                isStopPending = true
                stopPendingSinceMs = currentTimeMs
                return PlaybackTransition.NONE
            } else {
                val elapsed = currentTimeMs - pendingSince
                if (elapsed >= confirmationWindowMs) {
                    // Full window elapsed with continuous false signals -> genuine stop
                    isPlaying = false
                    isStopPending = false
                    stopPendingSinceMs = null
                    return PlaybackTransition.STOPPED
                } else {
                    // Still within confirmation window -> remain active, emit nothing
                    return PlaybackTransition.NONE
                }
            }
        }

        // !isPlaying && !isAudioActive
        return PlaybackTransition.NONE
    }

    /**
     * Explicitly confirms and finalizes a pending stop when the confirmation timer deadline fires.
     * Transitions state from playing to stopped and returns [PlaybackTransition.STOPPED] exactly once.
     */
    fun confirmPendingStop(): PlaybackTransition {
        if (isPlaying && isStopPending) {
            isPlaying = false
            isStopPending = false
            stopPendingSinceMs = null
            return PlaybackTransition.STOPPED
        }
        return PlaybackTransition.NONE
    }

    /**
     * Cancels any pending stop verification without altering the underlying playing state.
     */
    fun cancelPendingStop() {
        isStopPending = false
        stopPendingSinceMs = null
    }

    /**
     * Returns a human-readable explanation of why audio was resolved as active or inactive.
     */
    fun getResolutionReason(
        hasMediaConfig: Boolean,
        isMusicActive: Boolean,
        isA2dpStreaming: Boolean
    ): String {
        return when {
            hasMediaConfig -> "active_media_configuration"
            isA2dpStreaming -> "bluetooth_a2dp_streaming"
            isMusicActive -> "audio_manager_music_active"
            else -> "no_active_media_or_sound"
        }
    }

    /**
     * Resets the resolver to an explicit state and clears any pending verification.
     */
    fun reset(initialPlaying: Boolean = false) {
        isPlaying = initialPlaying
        isStopPending = false
        stopPendingSinceMs = null
    }
}
