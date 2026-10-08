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
    private var isPlaying: Boolean = false
) {
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
     *
     * State transition requirements:
     * - INACTIVE -> ACTIVE: emits STARTED exactly once
     * - ACTIVE -> ACTIVE: emits NONE
     * - ACTIVE -> (hasMediaConfig=false, isMusicActive=true or isA2dpStreaming=true): emits NONE (preserves active state during transient config drops)
     * - ACTIVE -> (hasMediaConfig=false, isMusicActive=false, isA2dpStreaming=false): emits STOPPED exactly once (genuine pause/stop)
     * - INACTIVE -> INACTIVE: emits NONE
     */
    fun resolve(
        hasMediaConfig: Boolean,
        isMusicActive: Boolean,
        isA2dpStreaming: Boolean = false
    ): PlaybackTransition {
        val isAudioActive = hasMediaConfig || isMusicActive || isA2dpStreaming

        return if (!isPlaying && isAudioActive) {
            isPlaying = true
            PlaybackTransition.STARTED
        } else if (isPlaying && !hasMediaConfig && !isMusicActive && !isA2dpStreaming) {
            isPlaying = false
            PlaybackTransition.STOPPED
        } else {
            PlaybackTransition.NONE
        }
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
     * Resets the resolver to an explicit state.
     */
    fun reset(initialPlaying: Boolean = false) {
        isPlaying = initialPlaying
    }
}
