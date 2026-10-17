package com.listeningtracker.listening_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class BreakActionReceiverTest {

    @Test
    fun test_actionConstants() {
        assertEquals("com.listeningtracker.action.BREAK_SNOOZE", BreakActionReceiver.ACTION_SNOOZE)
        assertEquals("com.listeningtracker.action.BREAK_DISMISS", BreakActionReceiver.ACTION_DISMISS)
        assertEquals("notification_id", BreakActionReceiver.EXTRA_NOTIFICATION_ID)
        assertEquals("snooze_minutes", BreakActionReceiver.EXTRA_SNOOZE_MINUTES)
        assertEquals("session_generation", BreakActionReceiver.EXTRA_SESSION_GENERATION)
    }

    @Test
    fun test_notificationActionIntentKeys() {
        val snoozeAction = BreakActionReceiver.ACTION_SNOOZE
        val dismissAction = BreakActionReceiver.ACTION_DISMISS

        assertNotNull(snoozeAction)
        assertNotNull(dismissAction)
        org.junit.Assert.assertNotEquals(snoozeAction, dismissAction)
    }
}
