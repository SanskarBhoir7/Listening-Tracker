package com.listeningtracker.listening_tracker

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Small bounded app-private breadcrumb log for events that happen before Dart is ready. */
internal object NativeLifecycleDiagnostics {
    private const val TAG = "NativeLifecycleDiagnostics"
    private const val FILE_NAME = "native_lifecycle.jsonl"
    private const val MAX_BYTES = 64 * 1024
    private val processId = UUID.randomUUID().toString()

    @Synchronized
    fun record(context: Context, type: String, details: Map<String, Any?> = emptyMap()) {
        try {
            val file = File(context.applicationContext.filesDir, FILE_NAME)
            file.parentFile?.mkdirs()
            val event = JSONObject().apply {
                put("id", UUID.randomUUID().toString())
                put("processId", processId)
                put("timestamp", System.currentTimeMillis())
                put("eventType", type)
                put("details", JSONObject(details))
            }
            file.appendText(event.toString() + "\n", Charsets.UTF_8)
            if (file.length() > MAX_BYTES) {
                val lines = file.readLines(Charsets.UTF_8).toMutableList()
                while (lines.isNotEmpty() && lines.joinToString("\n").toByteArray(Charsets.UTF_8).size > MAX_BYTES) {
                    lines.removeAt(0)
                }
                file.writeText(if (lines.isEmpty()) "" else "${lines.joinToString("\n")}\n", Charsets.UTF_8)
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not persist lifecycle event $type", error)
        }
    }

    @Synchronized
    fun drain(context: Context): List<Map<String, Any?>> {
        val file = File(context.applicationContext.filesDir, FILE_NAME)
        if (!file.exists()) return emptyList()
        val events = mutableListOf<Map<String, Any?>>()
        try {
            file.forEachLine(Charsets.UTF_8) { line ->
                try {
                    val event = JSONObject(line)
                    events.add(mapOf(
                        "id" to event.optString("id"),
                        "processId" to event.optString("processId"),
                        "timestamp" to event.optLong("timestamp"),
                        "eventType" to event.optString("eventType"),
                        "details" to event.optJSONObject("details")?.toMap().orEmpty(),
                    ))
                } catch (_: Exception) { }
            }
        } catch (error: Exception) {
            Log.w(TAG, "Could not drain lifecycle events", error)
        }
        return events
    }

    @Synchronized
    fun acknowledge(context: Context, ids: Set<String>) {
        if (ids.isEmpty()) return
        val file = File(context.applicationContext.filesDir, FILE_NAME)
        if (!file.exists()) return
        try {
            val retained = file.readLines(Charsets.UTF_8).filter { line ->
                try { JSONObject(line).optString("id") !in ids } catch (_: Exception) { false }
            }
            file.writeText(if (retained.isEmpty()) "" else "${retained.joinToString("\n")}\n", Charsets.UTF_8)
        } catch (error: Exception) {
            Log.w(TAG, "Could not acknowledge lifecycle events", error)
        }
    }

    private fun JSONObject.toMap(): Map<String, Any?> = keys().asSequence().associateWith { key ->
        when (val value = opt(key)) {
            JSONObject.NULL -> null
            null -> null
            is JSONObject -> value.toMap()
            is JSONArray -> value.toString()
            else -> value
        }
    }
}
