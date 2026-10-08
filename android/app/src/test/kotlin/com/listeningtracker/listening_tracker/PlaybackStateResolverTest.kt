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
        resolver = PlaybackStateResolver()
    }

    /**
     * Test 1: Continuous playback with temporary configuration loss.
     * Expected: No AUDIO_STOPPED (PlaybackTransition.NONE) when Bluetooth A2DP or isMusicActive is true.
     */
    @Test
    fun test1_continuousPlaybackTemporaryConfigLoss_emitsNone() {
        resolver.reset(initialPlaying = true)
        assertTrue(resolver.isCurrentlyPlaying)

        // Config lost, but Bluetooth A2DP is streaming
        val transitionA = resolver.resolve(hasMediaConfig = false, isMusicActive = false, isA2dpStreaming = true)
        assertEquals(PlaybackTransition.NONE, transitionA)
        assertTrue(resolver.isCurrentlyPlaying)

        // Config lost, but isMusicActive is true
        val transitionB = resolver.resolve(hasMediaConfig = false, isMusicActive = true, isA2dpStreaming = false)
        assertEquals(PlaybackTransition.NONE, transitionB)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 2: playerState transitions (STARTED vs PAUSED).
     */
    @Test
    fun test2_playerStateTransitions_correctTransitions() {
        resolver.reset(initialPlaying = false)

        // STARTED player state
        val startTransition = resolver.resolve(hasMediaConfig = true, isMusicActive = false)
        assertEquals(PlaybackTransition.STARTED, startTransition)
        assertTrue(resolver.isCurrentlyPlaying)

        // PAUSED player state and no music/A2DP active
        val pauseTransition = resolver.resolve(hasMediaConfig = false, isMusicActive = false, isA2dpStreaming = false)
        assertEquals(PlaybackTransition.STOPPED, pauseTransition)
        assertFalse(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 3: isMusicActive transitions.
     */
    @Test
    fun test3_isMusicActiveTransitions_triggersStartAndSustains() {
        resolver.reset(initialPlaying = false)

        val start = resolver.resolve(hasMediaConfig = false, isMusicActive = true)
        assertEquals(PlaybackTransition.STARTED, start)
        assertTrue(resolver.isCurrentlyPlaying)

        val sustain = resolver.resolve(hasMediaConfig = true, isMusicActive = false)
        assertEquals(PlaybackTransition.NONE, sustain)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 4: Multiple playback configurations.
     */
    @Test
    fun test4_multipleConfigsOneDisappears_emitsNone() {
        resolver.reset(initialPlaying = true)

        val transition = resolver.resolve(hasMediaConfig = true, isMusicActive = true, isA2dpStreaming = true)
        assertEquals(PlaybackTransition.NONE, transition)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 5: Genuine pause.
     */
    @Test
    fun test5_genuinePause_emitsStoppedOnce() {
        resolver.reset(initialPlaying = true)

        val transition = resolver.resolve(hasMediaConfig = false, isMusicActive = false, isA2dpStreaming = false)
        assertEquals(PlaybackTransition.STOPPED, transition)
        assertFalse(resolver.isCurrentlyPlaying)
        assertEquals("no_active_media_or_sound", resolver.getResolutionReason(false, false, false))

        val repeat = resolver.resolve(hasMediaConfig = false, isMusicActive = false, isA2dpStreaming = false)
        assertEquals(PlaybackTransition.NONE, repeat)
        assertFalse(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 6: Genuine resume.
     */
    @Test
    fun test6_genuineResume_emitsStartedOnce() {
        resolver.reset(initialPlaying = false)

        val transition = resolver.resolve(hasMediaConfig = true, isMusicActive = true, isA2dpStreaming = true)
        assertEquals(PlaybackTransition.STARTED, transition)
        assertTrue(resolver.isCurrentlyPlaying)
        assertEquals("active_media_configuration", resolver.getResolutionReason(true, true, true))
    }

    /**
     * Test 7: No duplicate start/stop events across repeated identical states.
     */
    @Test
    fun test7_repeatedIdenticalStates_noDuplicates() {
        resolver.reset(initialPlaying = false)

        val start = resolver.resolve(hasMediaConfig = true, isMusicActive = true)
        assertEquals(PlaybackTransition.STARTED, start)

        for (i in 1..5) {
            assertEquals(PlaybackTransition.NONE, resolver.resolve(hasMediaConfig = true, isMusicActive = true))
        }

        val stop = resolver.resolve(hasMediaConfig = false, isMusicActive = false)
        assertEquals(PlaybackTransition.STOPPED, stop)

        for (i in 1..5) {
            assertEquals(PlaybackTransition.NONE, resolver.resolve(hasMediaConfig = false, isMusicActive = false))
        }
    }
}
