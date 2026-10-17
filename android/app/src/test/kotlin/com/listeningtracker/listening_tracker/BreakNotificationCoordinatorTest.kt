package com.listeningtracker.listening_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class BreakNotificationCoordinatorTest {

    @Test
    fun staleActionCannotCancelNewerNotificationWithSameId() {
        val coordinator = BreakNotificationCoordinator()
        var cancelCount = 0
        coordinator.post(3001, "session-new") {}

        val cancelled = coordinator.cancelForAction(3001, "session-old") {
            cancelCount++
        }

        assertFalse(cancelled)
        assertEquals(0, cancelCount)
        assertTrue(coordinator.cancelForAction(3001, "session-new") { cancelCount++ })
        assertEquals(1, cancelCount)
    }

    @Test
    fun validActionCancelsItsNotification() {
        val coordinator = BreakNotificationCoordinator()
        var cancelCount = 0
        coordinator.post(3002, "session-current") {}

        assertTrue(coordinator.cancelForAction(3002, "session-current") { cancelCount++ })
        assertEquals(1, cancelCount)
    }

    @Test
    fun postingAndActionCancellationAreSerializedForSameId() {
        val coordinator = BreakNotificationCoordinator()
        coordinator.post(3001, "session-old") {}

        val notificationPostEntered = CountDownLatch(1)
        val allowNotificationPostToFinish = CountDownLatch(1)
        val actionAttempted = CountDownLatch(1)
        val actionCancelEntered = CountDownLatch(1)
        val actionFinished = CountDownLatch(1)
        val cancelled = AtomicBoolean(true)
        val operations = Collections.synchronizedList(mutableListOf<String>())

        val postingThread = thread(name = "break-notification-post") {
            coordinator.post(3001, "session-new") {
                notificationPostEntered.countDown()
                check(allowNotificationPostToFinish.await(5, TimeUnit.SECONDS))
                operations.add("post-complete")
            }
        }
        assertTrue(notificationPostEntered.await(5, TimeUnit.SECONDS))

        val actionThread = thread(name = "break-notification-action") {
            actionAttempted.countDown()
            cancelled.set(coordinator.cancelForAction(3001, "session-new") {
                actionCancelEntered.countDown()
                operations.add("action-cancel")
            })
            actionFinished.countDown()
        }
        assertTrue(actionAttempted.await(5, TimeUnit.SECONDS))
        // This bounded latch check verifies the Android cancel callback cannot
        // enter while the post callback is still occupying the same lock.
        assertFalse(actionCancelEntered.await(250, TimeUnit.MILLISECONDS))

        // The notification operation itself is held at a latch while a valid
        // action contends for the same ID. The action must cancel only after
        // the replacement has finished posting.
        allowNotificationPostToFinish.countDown()
        assertTrue(actionFinished.await(5, TimeUnit.SECONDS))
        postingThread.join(5000)
        actionThread.join(5000)

        assertFalse(postingThread.isAlive)
        assertFalse(actionThread.isAlive)
        assertTrue(cancelled.get())
        assertEquals(listOf("post-complete", "action-cancel"), operations)
    }
}
