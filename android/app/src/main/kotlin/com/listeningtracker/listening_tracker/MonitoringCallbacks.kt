package com.listeningtracker.listening_tracker

/** Transactional registration for callbacks that define an active monitor. */
internal class MonitoringCallbacks(
    private val registerPlayback: () -> Unit,
    private val unregisterPlayback: () -> Unit,
    private val registerA2dp: () -> Unit,
    private val unregisterA2dp: () -> Unit,
) {
    var playbackRegistered: Boolean = false
        private set
    var a2dpRegistered: Boolean = false
        private set
    var isActive: Boolean = false
        private set

    fun start(): Boolean {
        if (isActive) return true
        try {
            registerPlayback()
            playbackRegistered = true
            registerA2dp()
            a2dpRegistered = true
            isActive = true
            return true
        } catch (error: Exception) {
            stop()
            throw error
        }
    }

    fun stop() {
        isActive = false
        if (a2dpRegistered) {
            try { unregisterA2dp() } catch (_: Exception) { }
            a2dpRegistered = false
        }
        if (playbackRegistered) {
            try { unregisterPlayback() } catch (_: Exception) { }
            playbackRegistered = false
        }
    }
}
