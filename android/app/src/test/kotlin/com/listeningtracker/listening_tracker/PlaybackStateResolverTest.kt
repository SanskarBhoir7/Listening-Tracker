package com.listeningtracker.listening_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PlaybackStateResolverTest {

    private lateinit var resolver: PlaybackStateResolver

    @Before
    fun setUp() {
        resolver = PlaybackStateResolver(confirmationWindowMs = 2000L)
    }

    /**
     * Requirement 1: AUDIO_STARTED remains immediate (0ms latency).
     */
    @Test
    fun test_audioStartedRemainsImmediate() {
        resolver.reset(initialPlaying = false)
        assertFalse(resolver.isCurrentlyPlaying)

        val transition = resolver.resolve(
            hasMediaConfig = true,
            isMusicActive = false,
            isA2dpStreaming = false,
            currentTimeMs = 1000L
        )

        assertEquals(PlaybackTransition.STARTED, transition)
        assertTrue(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)
    }

    /**
     * Requirement 2: Transient signal loss (<2s) schedules confirmation window and does NOT emit STOPPED.
     */
    @Test
    fun test_transientSignalLoss_schedulesWindow_emitsNone() {
        resolver.reset(initialPlaying = true)
        assertTrue(resolver.isCurrentlyPlaying)

        // All signals become false at t=1000ms
        val transitionA = resolver.resolve(
            hasMediaConfig = false,
            isMusicActive = false,
            isA2dpStreaming = false,
            currentTimeMs = 1000L
        )

        assertEquals(PlaybackTransition.NONE, transitionA)
        assertTrue(resolver.isCurrentlyPlaying) // Still considered playing
        assertTrue(resolver.isStopPending)
        assertEquals(1000L, resolver.stopPendingSinceMs)

        // Another evaluation within the 2-second window at t=1800ms (800ms elapsed < 2000ms)
        val transitionB = resolver.resolve(
            hasMediaConfig = false,
            isMusicActive = false,
            isA2dpStreaming = false,
            currentTimeMs = 1800L
        )

        assertEquals(PlaybackTransition.NONE, transitionB)
        assertTrue(resolver.isCurrentlyPlaying)
        assertTrue(resolver.isStopPending)
    }

    /**
     * Requirement 3: Playback recovery before the deadline cancels pending stop and keeps session active.
     */
    @Test
    fun test_playbackRecoveryBeforeDeadline_cancelsPendingStop_keepsSessionActive() {
        resolver.reset(initialPlaying = true)

        // Signal drops to false at t=1000ms
        val transitionA = resolver.resolve(
            hasMediaConfig = false,
            isMusicActive = false,
            isA2dpStreaming = false,
            currentTimeMs = 1000L
        )
        assertEquals(PlaybackTransition.NONE, transitionA)
        assertTrue(resolver.isStopPending)

        // Track starts again at t=1800ms (< 2000ms window)
        val recoveryTransition = resolver.resolve(
            hasMediaConfig = true,
            isMusicActive = false,
            isA2dpStreaming = false,
            currentTimeMs = 1800L
        )

        // Emits NONE (session remains active without gap or duplicate start)
        assertEquals(PlaybackTransition.NONE, recoveryTransition)
        assertTrue(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)
        assertEquals(null, resolver.stopPendingSinceMs)
    }

    /**
     * Requirement 4: Genuine pause: all signals remain false for full window (>=2000ms) -> emits STOPPED exactly once.
     */
    @Test
    fun test_genuinePause_emitsStoppedExactlyOnceAfterFullWindow() {
        resolver.reset(initialPlaying = true)

        // Signals become false at t=1000ms
        val drop = resolver.resolve(false, false, false, currentTimeMs = 1000L)
        assertEquals(PlaybackTransition.NONE, drop)
        assertTrue(resolver.isStopPending)

        // Window expired at t=3000ms (2000ms elapsed)
        val stopTransition = resolver.resolve(false, false, false, currentTimeMs = 3000L)
        assertEquals(PlaybackTransition.STOPPED, stopTransition)
        assertFalse(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)

        // Subsequent evaluations while inactive emit NONE (no duplicate stop)
        val repeat = resolver.resolve(false, false, false, currentTimeMs = 3500L)
        assertEquals(PlaybackTransition.NONE, repeat)
        assertFalse(resolver.isCurrentlyPlaying)
    }

    /**
     * Requirement 4 & Handler timer: confirmPendingStop emits STOPPED exactly once.
     */
    @Test
    fun test_confirmPendingStop_emitsStoppedOnce() {
        resolver.reset(initialPlaying = true)

        // Schedule pending stop
        resolver.resolve(false, false, false, currentTimeMs = 1000L)
        assertTrue(resolver.isStopPending)
        assertTrue(resolver.isCurrentlyPlaying)

        // Timer fires
        val confirmed = resolver.confirmPendingStop()
        assertEquals(PlaybackTransition.STOPPED, confirmed)
        assertFalse(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)

        // Second invocation (e.g. race condition) emits NONE
        val duplicate = resolver.confirmPendingStop()
        assertEquals(PlaybackTransition.NONE, duplicate)
    }

    /**
     * Requirement 5: Bluetooth disconnection during pending window cancels verification immediately.
     */
    @Test
    fun test_bluetoothDisconnectionDuringPendingWindow_cancelsImmediately() {
        resolver.reset(initialPlaying = true)

        // Audio signals drop at t=1000ms -> pending stop
        resolver.resolve(false, false, false, currentTimeMs = 1000L)
        assertTrue(resolver.isStopPending)

        // Disconnection event occurs at t=1400ms -> cancelPendingStop and reset
        resolver.cancelPendingStop()
        assertFalse(resolver.isStopPending)
        resolver.reset(initialPlaying = false)
        assertFalse(resolver.isCurrentlyPlaying)

        // Stale timer firing at t=3000ms produces no event
        assertEquals(PlaybackTransition.NONE, resolver.confirmPendingStop())
    }

    /**
     * Requirement 6: Duplicate callbacks during pending window do NOT postpone or duplicate the timer.
     */
    @Test
    fun test_duplicateCallbacksDuringWindow_preserveOriginalDeadline() {
        resolver.reset(initialPlaying = true)

        // First false event at t=1000ms
        resolver.resolve(false, false, false, currentTimeMs = 1000L)
        assertEquals(1000L, resolver.stopPendingSinceMs)

        // Duplicate events at t=1200ms, t=1400ms, t=1600ms
        for (time in listOf(1200L, 1400L, 1600L, 1800L)) {
            val trans = resolver.resolve(false, false, false, currentTimeMs = time)
            assertEquals(PlaybackTransition.NONE, trans)
            assertEquals(1000L, resolver.stopPendingSinceMs) // Deadline anchor preserved!
            assertTrue(resolver.isCurrentlyPlaying)
        }

        // At t=3000ms (2000ms from t=1000ms), deadline is reached
        val finalTransition = resolver.resolve(false, false, false, currentTimeMs = 3000L)
        assertEquals(PlaybackTransition.STOPPED, finalTransition)
        assertFalse(resolver.isCurrentlyPlaying)
    }

    /**
     * Requirement 7: Connected-but-idle never counts as active playback.
     */
    @Test
    fun test_connectedButIdle_neverCountsAsActivePlayback() {
        resolver.reset(initialPlaying = false)

        for (time in listOf(1000L, 2000L, 3000L)) {
            val transition = resolver.resolve(false, false, false, currentTimeMs = time)
            assertEquals(PlaybackTransition.NONE, transition)
            assertFalse(resolver.isCurrentlyPlaying)
            assertFalse(resolver.isStopPending)
        }
    }

    /**
     * Continuous playback with A2DP streaming or isMusicActive (multi-signal preservation).
     */
    @Test
    fun test_continuousPlaybackMultiSignals_emitsNone() {
        resolver.reset(initialPlaying = true)

        // Config lost, but Bluetooth A2DP is streaming
        val transitionA = resolver.resolve(hasMediaConfig = false, isMusicActive = false, isA2dpStreaming = true)
        assertEquals(PlaybackTransition.NONE, transitionA)
        assertTrue(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)

        // Config lost, but isMusicActive is true
        val transitionB = resolver.resolve(hasMediaConfig = false, isMusicActive = true, isA2dpStreaming = false)
        assertEquals(PlaybackTransition.NONE, transitionB)
        assertTrue(resolver.isCurrentlyPlaying)
        assertFalse(resolver.isStopPending)
    }

    /**
     * Resolution reason string checks.
     */
    @Test
    fun test_resolutionReasons() {
        assertEquals("active_media_configuration", resolver.getResolutionReason(true, true, true))
        assertEquals("bluetooth_a2dp_streaming", resolver.getResolutionReason(false, false, true))
        assertEquals("audio_manager_music_active", resolver.getResolutionReason(false, true, false))
        assertEquals("no_active_media_or_sound", resolver.getResolutionReason(false, false, false))
    }
}
