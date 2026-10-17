package com.listeningtracker.listening_tracker

/**
 * Keeps the generation associated with a break notification in step with the
 * Android operation that posts or cancels that notification.
 *
 * Callbacks are deliberately run while holding the coordinator lock: Android
 * addresses notifications by ID, so generation validation and notify/cancel
 * must be one serialized operation for that ID.
 */
internal class BreakNotificationCoordinator {
    private val lock = Any()
    private val generations = mutableMapOf<Int, String>()

    fun post(id: Int, generation: String, notify: () -> Unit) {
        synchronized(lock) {
            val previousGeneration = generations.put(id, generation)
            try {
                notify()
            } catch (error: Throwable) {
                if (previousGeneration == null) {
                    generations.remove(id)
                } else {
                    generations[id] = previousGeneration
                }
                throw error
            }
        }
    }

    /** Returns true when this action was allowed to cancel the notification. */
    fun cancelForAction(id: Int, generation: String?, cancel: () -> Unit): Boolean =
        synchronized(lock) {
            val currentGeneration = generations[id]
            if (currentGeneration != null && currentGeneration != generation) {
                false
            } else {
                generations.remove(id)
                cancel()
                true
            }
        }

    fun cancel(id: Int, cancel: () -> Unit) {
        synchronized(lock) {
            generations.remove(id)
            cancel()
        }
    }
}
