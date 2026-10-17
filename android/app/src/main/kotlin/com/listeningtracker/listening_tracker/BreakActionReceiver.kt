package com.listeningtracker.listening_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * BroadcastReceiver for handling notification action clicks (Snooze / Dismiss)
 * reliably, even when the screen is locked or the Flutter UI has been swiped from Recents.
 */
class BreakActionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "BreakActionReceiver"
        const val ACTION_SNOOZE = "com.listeningtracker.action.BREAK_SNOOZE"
        const val ACTION_DISMISS = "com.listeningtracker.action.BREAK_DISMISS"

        const val EXTRA_NOTIFICATION_ID = "notification_id"
        const val EXTRA_SNOOZE_MINUTES = "snooze_minutes"
        const val EXTRA_SESSION_GENERATION = "session_generation"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val id = intent.extras?.get(EXTRA_NOTIFICATION_ID) as? Int ?: -1
        val snoozeMinutes = intent.getIntExtra(EXTRA_SNOOZE_MINUTES, 10)
        val sessionGeneration = intent.extras?.get(EXTRA_SESSION_GENERATION) as? String

        Log.d(TAG, "onReceive action=$action, id=$id, snoozeMinutes=$snoozeMinutes")

        when (action) {
            ACTION_SNOOZE -> {
                AudioMonitorBridge.handleBreakAction(context, "snooze", id, snoozeMinutes, sessionGeneration)
            }
            ACTION_DISMISS -> {
                AudioMonitorBridge.handleBreakAction(context, "dismiss", id, snoozeMinutes, sessionGeneration)
            }
            else -> {
                Log.w(TAG, "Unhandled action: $action")
            }
        }
    }
}
