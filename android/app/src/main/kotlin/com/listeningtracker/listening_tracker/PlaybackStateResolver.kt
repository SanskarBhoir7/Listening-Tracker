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
 * Native playback-state resolver reconciling both AudioPlaybackConfiguration
 * and AudioManager.isMusicActive() signals.
 *
 * Prevents false AUDIO_STOPPED events during continuous music playback when
 * media playback configurations temporarily disappear or transition.
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
     * Resolves playback state transitions based on dual signals:
     * 1. [hasMediaConfig]: Whether any active playback configuration matching media/game exists.
     * 2. [isMusicActive]: Whether AudioManager.isMusicActive() is currently true.
     *
     * State transition requirements:
     * - INACTIVE -> ACTIVE: emits STARTED exactly once
     * - ACTIVE -> ACTIVE: emits NONE
     * - ACTIVE -> (hasMediaConfig=false, isMusicActive=true): emits NONE (preserves active state during transient config drops)
     * - ACTIVE -> (hasMediaConfig=false, isMusicActive=false): emits STOPPED exactly once
     * - INACTIVE -> INACTIVE: emits NONE
     */
    fun resolve(hasMediaConfig: Boolean, isMusicActive: Boolean): PlaybackTransition {
        val isAudioActive = hasMediaConfig || isMusicActive

        return if (!isPlaying && isAudioActive) {
            isPlaying = true
            PlaybackTransition.STARTED
        } else if (isPlaying && !hasMediaConfig && !isMusicActive) {
            isPlaying = false
            PlaybackTransition.STOPPED
        } else {
            PlaybackTransition.NONE
        }
    }

    /**
     * Resets the resolver to an explicit state.
     */
    fun reset(initialPlaying: Boolean = false) {
        isPlaying = initialPlaying
    }
}
