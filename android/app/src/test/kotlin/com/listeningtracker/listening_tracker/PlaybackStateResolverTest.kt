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
     * Test 1:
     * Previous ACTIVE
     * Current config = none
     * isMusicActive = true
     * Expected: No AUDIO_STOPPED (PlaybackTransition.NONE), remains playing.
     */
    @Test
    fun test1_activeToNoneWithMusicActive_emitsNone() {
        resolver.reset(initialPlaying = true)
        assertTrue(resolver.isCurrentlyPlaying)

        val transition = resolver.resolve(hasMediaConfig = false, isMusicActive = true)

        assertEquals(PlaybackTransition.NONE, transition)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 2:
     * Previous ACTIVE
     * Current config = none
     * isMusicActive = false
     * Expected: One AUDIO_STOPPED (PlaybackTransition.STOPPED), becomes inactive.
     */
    @Test
    fun test2_activeToNoneWithNoMusic_emitsStoppedOnce() {
        resolver.reset(initialPlaying = true)
        assertTrue(resolver.isCurrentlyPlaying)

        val transition = resolver.resolve(hasMediaConfig = false, isMusicActive = false)

        assertEquals(PlaybackTransition.STOPPED, transition)
        assertFalse(resolver.isCurrentlyPlaying)

        // Repeated inactive call produces no transition
        val nextTransition = resolver.resolve(hasMediaConfig = false, isMusicActive = false)
        assertEquals(PlaybackTransition.NONE, nextTransition)
        assertFalse(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 3:
     * Previous INACTIVE
     * Current active playback
     * isMusicActive = true
     * Expected: One AUDIO_STARTED (PlaybackTransition.STARTED).
     */
    @Test
    fun test3_inactiveToActive_emitsStartedOnce() {
        resolver.reset(initialPlaying = false)
        assertFalse(resolver.isCurrentlyPlaying)

        val transition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)

        assertEquals(PlaybackTransition.STARTED, transition)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 4:
     * Multiple playback configurations where one disappears but another remains.
     * Expected: No AUDIO_STOPPED.
     */
    @Test
    fun test4_multipleConfigsOneDisappears_emitsNone() {
        resolver.reset(initialPlaying = true)

        // hasMediaConfig is still true because another valid media stream remains
        val transition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)

        assertEquals(PlaybackTransition.NONE, transition)
        assertTrue(resolver.isCurrentlyPlaying)
    }

    /**
     * Test 5:
     * Repeated ACTIVE callbacks.
     * Expected: No duplicate AUDIO_STARTED.
     */
    @Test
    fun test5_repeatedActiveCallbacks_noDuplicateStarted() {
        val firstTransition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)
        assertEquals(PlaybackTransition.STARTED, firstTransition)
        assertTrue(resolver.isCurrentlyPlaying)

        for (i in 1..5) {
            val repeatTransition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)
            assertEquals(PlaybackTransition.NONE, repeatTransition)
            assertTrue(resolver.isCurrentlyPlaying)
        }
    }

    /**
     * Test 6:
     * Temporary config disappearance followed by config returning while music remains active.
     * Expected: No STOPPED -> STARTED cycle.
     */
    @Test
    fun test6_temporaryConfigDropThenReturn_noStoppedStartedCycle() {
        // Step 1: Music starts
        val startTransition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)
        assertEquals(PlaybackTransition.STARTED, startTransition)
        assertTrue(resolver.isCurrentlyPlaying)

        // Step 2: Track transition or offload momentarily drops config, but music is active
        val dropTransition = resolver.resolve(hasMediaConfig = false, isMusicActive = true)
        assertEquals(PlaybackTransition.NONE, dropTransition)
        assertTrue(resolver.isCurrentlyPlaying)

        // Step 3: Config reappears for new track
        val returnTransition = resolver.resolve(hasMediaConfig = true, isMusicActive = true)
        assertEquals(PlaybackTransition.NONE, returnTransition)
        assertTrue(resolver.isCurrentlyPlaying)
    }
}
