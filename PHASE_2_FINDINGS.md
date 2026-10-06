# Phase 2: Technical Findings — Listening Tracker

## 1. Data Model

Phase 2 formalizes three distinct levels of audio tracking:

```
┌──────────────────────────────────────────────────────────────┐
│                        AudioDevice                           │
│  id (stable), name, deviceType, connectionType, address,     │
│  firstSeen, lastSeen                                         │
└──────────────────────────────┬───────────────────────────────┘
                               │ 1:N
                               ▼
┌──────────────────────────────────────────────────────────────┐
│                      ListeningSession                        │
│  id, deviceId, deviceName, deviceType                        │
│  connectedAt, disconnectedAt                                 │
│  listeningStartedAt, listeningEndedAt                        │
│  connectedDuration, activeListeningDuration, silentDuration   │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                 ContinuousListeningSession                   │
│  id, startedAt, endedAt, activeDuration, pausedDuration,     │
│  deviceIds, deviceNames                                      │
└──────────────────────────────────────────────────────────────┘
```

### Stable Device Identification Strategy
- **Bluetooth Devices with Hardware Address**: If Android exposes the MAC/hardware address (`AudioDeviceInfo.getAddress()` available on API 28+), the ID is formed as `addr_<sanitized_address>`.
- **Bluetooth Devices without Address**: If address is unavailable due to OEM permission restrictions or older APIs, a deterministic hash of `connectionType` + sanitized device name is used (`bluetooth_<clean_name>`).
- **Wired / USB Devices**: Formed deterministically by port/connection type (`wired_3_5mm_wired_headphones`, `usb_<clean_name>`).
- **Result**: When the user's `realme Buds T200 Lite` connects, disconnects, and reconnects, it matches the exact same existing record in the database instead of creating duplicate devices.

### Durations & Mathematical Invariant
For every device session:
$$\text{connectedDuration} \approx \text{activeListeningDuration} + \text{silentDuration}$$
- **Connected Time**: Total elapsed duration the device remained physically or wirelessly attached to Android.
- **Active Listening**: Confirmed duration that Android detected system-wide media playback (`USAGE_MEDIA`, `USAGE_GAME`) through this device.
- **Silent / Paused**: Duration the device was connected without active media playback.
- **Terminology Rule**: The app strictly refrains from calling connected time "wearing time", as Android APIs cannot detect physical in-ear placement.

---

## 2. Database Choice

### Selected Engine: SQLite via `sqflite` + `path`
- **Why Relational SQL?** Listening tracker data is inherently relational: devices possess multiple historical device sessions, and continuous sessions reference multiple participating devices.
- **Why not Key-Value / SharedPreferences?** Key-value stores lack indexing, range queries (e.g. `connected_at BETWEEN startOfDay AND endOfDay`), aggregation queries (`SUM`, `MAX`), and transactional foreign keys.
- **Why not Hive / Isar / ObjectBox?** `sqflite` is the official, battle-tested standard in the Flutter ecosystem, compiles natively without code-generation build runners, and uses Android's built-in SQLite engine with zero third-party cloud binaries.
- **Indices Created**:
  - `idx_device_sessions_connected_at` on `device_sessions(connected_at)`
  - `idx_continuous_sessions_started_at` on `continuous_sessions(started_at)`

---

## 3. Session State Machine

The session tracking lifecycle is governed by the following state transitions:

```
                  ┌──────────────┐
                  │     IDLE     │ (Monitoring stopped)
                  └──────┬───────┘
                         │ Start Monitoring
                         ▼
        ┌──────────────────────────────────┐
   ┌───►│             STANDBY              │◄───┐
   │    │ (Monitoring active, no earphone) │    │
   │    └────────────────┬─────────────────┘    │
   │                     │ Device Connected     │
   │                     ▼                      │
   │    ┌──────────────────────────────────┐    │
   │    │        CONNECTED (Silent)        │    │ Device
   │    │  (Headphones connected, silent)  │    │ Disconnected
   │    └──────┬────────────────────▲──────┘    │ (Audio stopped)
   │           │                    │           │
   │           │ Audio Started      │ Grace Expired
   │           ▼                    │           │
   │    ┌────────────────────┐      │           │
   │    │ LISTENING (Active) │      │           │
   │    └──────┬─────────────┘      │           │
   │           │                    │           │
   │           │ Audio Stopped      │           │
   │           ▼                    │           │
   │    ┌───────────────────────────┴──────┐    │
   │    │      PAUSED (Grace Period)       │────┘
   │    │   (Countdown: default 3 min)     │
   │    └──────────────────────────────────┘
   │
   │ (If audio plays through speaker while monitoring)
   └────► PLAYING (Speaker)
```

### Termination Criteria:
1. **Device Session Termination**: Closes immediately when `DEVICE_DISCONNECTED` is received or when audio output switches away from that device. Durations are reconciled and persisted into `device_sessions`.
2. **Continuous Session Termination**: Enters an experimental 3-minute grace period upon audio pause or device disconnect. If audio resumes within 3 minutes (even on a different headphone), the continuous session continues. If 3 minutes elapse without audio, the continuous session is finalized and persisted into `continuous_sessions`.

---

## 4. Multi-Device Handling

Modern Android users frequently alternate between Bluetooth earbuds, over-ear headphones, and wired/USB headsets.

### Handling Strategy:
1. **Connected Devices Registry**: Android's `AudioDeviceCallback` maintains an in-memory registry of all currently attached trackable output peripherals (`connectedDevices`).
2. **Active Audio Output vs Connected Devices**:
   - The application does **not** assume Bluetooth Connected = Listening.
   - Even if two Bluetooth devices are paired or connected simultaneously (e.g. Multipoint), Android routes media to only one sink at a time.
   - The app prioritizes: `Bluetooth A2DP / BLE > Wired 3.5mm > USB > Speaker`.
   - The UI clearly separates the list of all connected devices (`STANDBY`) from the device designated as the current `ACTIVE` audio output.

---

## 5. Device Switching Behavior

### Scenario:
1. User is listening on `realme Buds T200 Lite` from 10:05 to 10:40.
2. At 10:40, user puts `realme Buds T200 Lite` in case and turns on `Sony WH-1000XM4`.
3. Audio resumes or continues at 10:40.

### Execution:
- **Device Session 1 (`realme Buds T200 Lite`)**:
  - Closed at 10:40 with `connectedDuration: 35m`, `activeListening: 35m`, `silent: 0m`.
  - Persisted to SQLite.
- **Device Session 2 (`Sony WH-1000XM4`)**:
  - Started at 10:40 with `connectedAt: 10:40`.
- **Continuous Listening Session**:
  - Detects that audio resumed within the 3-minute grace period.
  - Appends `Sony WH-1000XM4` to `deviceNames` and `deviceIds`.
  - **Does not reset** the continuous listening clock.
  - Avoids double-counting overlap.
  - Total continuous listening accumulates seamlessly (e.g. 1h 15m).

---

## 6. Continuous Listening Logic

- **Purpose**: Ear health and auditory fatigue depend on continuous acoustic exposure across time, not whether the user swapped physical hardware.
- **Grace Period**: Default set to 3 minutes (`Duration(minutes: 3)`).
  - Short pauses (e.g., song transitions, buffer stalls, brief phone calls, changing headphones) do not fracture a continuous session.
  - Pauses longer than 3 minutes finalize the session, establishing a true listening break.
  - The UI displays a live remaining countdown indicator when the grace period is active.

---

## 7. Persistence Behavior

- **Completed Session Guarantee**: When earbuds are returned to their charging case (`DEVICE_DISCONNECTED`), the completed device session is written to SQLite **before** the live UI timer is reset.
- **Cold Boot & App Restart**: When the app launches, `SessionEngine.initialize()` queries SQLite for all sessions recorded today. The UI immediately displays completed sessions, daily totals, and device registry without waiting for new events.
- **Crash / Kill Resilience**: When the user taps "STOP MONITORING" or the app lifecycle closes, any in-flight sessions are finalized and written to disk.

---

## 8. Background Behavior

- **Android Foreground Service**: The `AudioMonitorService` operates as a foreground service with `foregroundServiceType="specialUse"`, displaying a persistent notification.
- **Locked Screen Continuity**: Callbacks for `AudioPlaybackCallback` and `AudioDeviceCallback` remain active while the phone screen is locked or while other applications (Spotify, YouTube, Chrome) are active.
- **OEM Battery Restrictions**:
  - Standard Android / Pixel devices run continuously without interruption.
  - Aggressive skins (Realme UI / ColorOS, Xiaomi MIUI, Samsung One UI) may restrict background services after extended periods unless battery optimization is set to "Unrestricted" / "No restrictions".

---

## 9. Known Limitations

1. **Physical In-Ear Detection is Impossible**: Android platform APIs provide no mechanism to detect whether earbuds are inserted into the ears. Only device connection and system media playback can be measured.
2. **Pause vs Stop Ambiguity**: Android's `AudioPlaybackCallback` does not distinguish between a pause and a stop; both result in playback configuration removal. The software grace period is essential to differentiate temporary pauses from finished sessions.
3. **No Volume Exposure**: `AudioPlaybackConfiguration` does not reveal decibel levels or playback volume per device.
4. **App Privacy Restriction**: Third-party apps cannot determine which specific external app (e.g. Spotify vs YouTube) is originating the media playback.

---

## 10. Recommended Architecture for Phase 3

```
┌──────────────────────────────────────────────────────────────┐
│                    Phase 3 Architecture                      │
├──────────────────────────────────────────────────────────────┤
│ 1. Break Recommendation Engine (Rule-based fatigue algorithm)│
│    - Configurable daily limit (e.g., 60m continuous)         │
│    - Recommended break duration (e.g., 10m pause after 60m)  │
│                                                              │
│ 2. Smart Notification Dispatcher                             │
│    - Local actionable notifications when threshold reached   │
│    - "Time for a listening break" alert                      │
│                                                              │
│ 3. Settings & Preferences Storage                            │
│    - Customizable grace period (1 min to 10 min)             │
│    - Notification mute / quiet hours                         │
│                                                              │
│ 4. Analytics & Weekly Historical Charts                      │
│    - Day-by-day continuous vs active listening charts        │
│    - Device distribution breakdown                           │
└──────────────────────────────────────────────────────────────┘
```
