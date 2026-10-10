package com.listeningtracker.listening_tracker

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BluetoothConnectionReceiverTest {

    @Test
    fun testNullDevice_returnsFalse() {
        assertFalse(BluetoothConnectionReceiver.isAudioPeripheral(null))
    }
}
