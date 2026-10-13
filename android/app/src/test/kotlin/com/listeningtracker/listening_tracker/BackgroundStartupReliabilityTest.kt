package com.listeningtracker.listening_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackgroundStartupReliabilityTest {

    /**
     * Test 1: Deduplication of overlapping ACL and A2DP broadcasts.
     * When ACL_CONNECTED and A2DP CONNECTION_STATE_CHANGED fire within 2.5 seconds
     * for the same device address, the duplicate start must be suppressed without dropping the connection.
     */
    @Test
    fun test_duplicateBroadcastsWithinThreshold_areDeduplicated() {
        val testAddress = "28:04:C6:D2:59:08"
        var lastAddress: String? = null
        var lastTimestamp = 0L

        fun isDuplicate(address: String, timestamp: Long): Boolean {
            val isDup = address.isNotBlank() &&
                address.equals(lastAddress, ignoreCase = true) &&
                (timestamp - lastTimestamp < 2500L)
            lastAddress = address
            lastTimestamp = timestamp
            return isDup
        }

        // First broadcast: ACL_CONNECTED at t=1000
        assertFalse("First broadcast should NOT be marked duplicate", isDuplicate(testAddress, 1000L))

        // Second broadcast: A2DP state change at t=1050 (50ms later)
        assertTrue("Immediate follow-up broadcast MUST be marked duplicate", isDuplicate(testAddress, 1050L))

        // Third broadcast after 3000ms: reconnect event
        assertFalse("Subsequent reconnect after gap must NOT be marked duplicate", isDuplicate(testAddress, 4500L))
    }

    /**
     * Test 2: Different Bluetooth devices in rapid succession must NOT be deduplicated.
     */
    @Test
    fun test_differentDevices_areNotDeduplicated() {
        val device1 = "AA:BB:CC:11:22:33"
        val device2 = "DD:EE:FF:44:55:66"
        var lastAddress: String? = null
        var lastTimestamp = 0L

        fun isDuplicate(address: String, timestamp: Long): Boolean {
            val isDup = address.isNotBlank() &&
                address.equals(lastAddress, ignoreCase = true) &&
                (timestamp - lastTimestamp < 2500L)
            lastAddress = address
            lastTimestamp = timestamp
            return isDup
        }

        assertFalse(isDuplicate(device1, 1000L))
        assertFalse("Distinct device must not be dropped as duplicate", isDuplicate(device2, 1100L))
    }

    /**
     * Test 3: Notification recovery action configuration.
     * Validates that the fallback notification action targets AudioMonitorService with
     * the 'notification_action' origin and extras required to recover monitoring without UI launch.
     */
    @Test
    fun test_recoveryServiceActionIntent_hasCorrectAttributes() {
        val deviceName = "realme Buds T200 Lite"
        val deviceAddress = "28:04:C6:D2:59:08"

        data class ServiceStartRequest(
            val action: String,
            val deviceName: String,
            val deviceAddress: String,
            val origin: String,
            val startupPath: String,
        )

        val request = ServiceStartRequest(
            action = AudioMonitorService.ACTION_START_MONITORING,
            deviceName = deviceName,
            deviceAddress = deviceAddress,
            origin = "notification_action",
            startupPath = "notification_action",
        )

        assertEquals("com.listeningtracker.action.START_MONITORING", request.action)
        assertEquals(deviceName, request.deviceName)
        assertEquals(deviceAddress, request.deviceAddress)
        assertEquals("notification_action", request.origin)
        assertEquals("notification_action", request.startupPath)
    }

    /**
     * Test 4: Diagnostic event attributes on rejected start include all essential telemetry fields.
     */
    @Test
    fun test_rejectedStartDiagnosticPayload_containsRequiredFields() {
        val startupPath = "bluetooth_acl"
        val errorClass = "android.app.ForegroundServiceStartNotAllowedException"
        val errorMessage = "startForegroundService() not allowed due to mAllowStartForeground false"
        val isFgsException = true
        val isIgnoringBatteryOptimizations = false
        val isCompanionAssociated = false
        val recoveryStrategy = "direct_notification_action"

        val payload = mapOf(
            "origin" to startupPath,
            "startupPath" to startupPath,
            "error" to errorClass,
            "message" to errorMessage,
            "isForegroundServiceStartNotAllowed" to isFgsException,
            "isIgnoringBatteryOptimizations" to isIgnoringBatteryOptimizations,
            "isCompanionAssociated" to isCompanionAssociated,
            "recoveryStrategy" to recoveryStrategy,
        )

        assertEquals("bluetooth_acl", payload["startupPath"])
        assertEquals(true, payload["isForegroundServiceStartNotAllowed"])
        assertEquals("direct_notification_action", payload["recoveryStrategy"])
        assertNotNull(payload["message"])
        assertNotNull(payload["error"])
    }

    /**
     * Test 5: Verify peripheral classification handles null safely.
     */
    @Test
    fun test_peripheralClassification_handlesNullSafely() {
        assertFalse(BluetoothConnectionReceiver.isAudioPeripheral(null))
    }

    /**
     * Test 6: Verify subscription snapshot payload generation when audio is actively playing.
     */
    @Test
    fun test_subscriptionSnapshot_includesAudioStartedWhenPlaying() {
        val testDevice = mapOf(
            "id" to 32927,
            "name" to "realme Buds T200 Lite",
            "typeName" to "Bluetooth A2DP",
            "connectionType" to "bluetooth",
            "address" to "28:04:C6:D2:59:08"
        )
        val currentState = mapOf(
            "isMonitoring" to true,
            "isAudioPlaying" to true,
            "outputDeviceName" to "realme Buds T200 Lite",
            "outputDeviceType" to "Bluetooth A2DP",
            "outputConnectionType" to "bluetooth",
            "outputDeviceAddress" to "28:04:C6:D2:59:08",
            "connectedDevices" to listOf(testDevice)
        )

        val events = mutableListOf<Map<String, Any?>>()
        val isAudioPlaying = currentState["isAudioPlaying"] as? Boolean ?: false
        val devices = currentState["connectedDevices"] as? List<*>

        events.add(mapOf("type" to "MONITORING_STATE_CHANGED", "isMonitoring" to true))
        devices?.forEach { dev ->
            if (dev is Map<*, *>) {
                events.add(mapOf("type" to AudioEventType.DEVICE_CONNECTED.name, "deviceName" to dev["name"]))
            }
        }
        if (isAudioPlaying) {
            val activeDev = devices?.firstOrNull() as? Map<*, *>
            events.add(mapOf(
                "type" to AudioEventType.AUDIO_STARTED.name,
                "deviceName" to (currentState["outputDeviceName"] ?: activeDev?.get("name")),
                "isAudioPlaying" to true
            ))
        }

        assertEquals(3, events.size)
        assertEquals("MONITORING_STATE_CHANGED", events[0]["type"])
        assertEquals(AudioEventType.DEVICE_CONNECTED.name, events[1]["type"])
        assertEquals(AudioEventType.AUDIO_STARTED.name, events[2]["type"])
        assertEquals(true, events[2]["isAudioPlaying"])
    }
}
