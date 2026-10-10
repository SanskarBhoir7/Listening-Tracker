package com.listeningtracker.listening_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MonitoringCallbacksTest {
    @Test
    fun successfulStartRegistersBothAndDuplicateStartDoesNotDuplicate() {
        val calls = mutableListOf<String>()
        val callbacks = MonitoringCallbacks(
            registerPlayback = { calls.add("registerPlayback") },
            unregisterPlayback = { calls.add("unregisterPlayback") },
            registerA2dp = { calls.add("registerA2dp") },
            unregisterA2dp = { calls.add("unregisterA2dp") },
        )

        assertTrue(callbacks.start())
        assertTrue(callbacks.start())
        assertTrue(callbacks.isActive)
        assertEquals(listOf("registerPlayback", "registerA2dp"), calls)

        callbacks.stop()
        assertFalse(callbacks.isActive)
        assertEquals(listOf("registerPlayback", "registerA2dp", "unregisterA2dp", "unregisterPlayback"), calls)
    }

    @Test
    fun secondRegistrationFailureRollsBackFirstAndLeavesInactive() {
        val calls = mutableListOf<String>()
        val callbacks = MonitoringCallbacks(
            registerPlayback = { calls.add("registerPlayback") },
            unregisterPlayback = { calls.add("unregisterPlayback") },
            registerA2dp = { calls.add("registerA2dp"); throw SecurityException("denied") },
            unregisterA2dp = { calls.add("unregisterA2dp") },
        )

        try {
            callbacks.start()
            throw AssertionError("Expected registration failure")
        } catch (error: SecurityException) {
            assertEquals("denied", error.message)
        }
        assertFalse(callbacks.isActive)
        assertFalse(callbacks.playbackRegistered)
        assertFalse(callbacks.a2dpRegistered)
        assertEquals(listOf("registerPlayback", "registerA2dp", "unregisterPlayback"), calls)
    }
}
