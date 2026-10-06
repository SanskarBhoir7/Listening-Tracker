# Phase 1: Technical Findings — Listening Tracker

## 1. Android APIs Investigated

| API | Purpose | API Level | Status |
|-----|---------|-----------|--------|
| `AudioManager.registerAudioPlaybackCallback()` | Detect when any app starts/stops playing audio | 26+ | **Used** |
| `AudioManager.getActivePlaybackConfigurations()` | Query currently active audio players | 26+ | **Used** |
| `AudioPlaybackConfiguration` | Details about each active playback stream | 26+ | **Used** |
| `AudioPlaybackConfiguration.getAudioAttributes()` | Filter by usage type (media vs notification) | 26+ | **Used** |
| `AudioManager.registerAudioDeviceCallback()` | Detect device connections/disconnections | 23+ | **Used** |
| `AudioManager.getDevices()` | Enumerate connected audio devices | 23+ | **Used** |
| `AudioDeviceInfo` | Device type, name, capabilities | 23+ | **Used** |
| `AudioDeviceInfo.TYPE_BLUETOOTH_A2DP` | Identify Bluetooth audio devices | 23+ | **Used** |
| `AudioDeviceInfo.TYPE_BLE_HEADSET` | Identify BLE audio devices | 31+ | **Used** |
| `AudioDeviceInfo.TYPE_WIRED_HEADSET/HEADPHONES` | Identify wired audio devices | 23+ | **Used** |
| `AudioDeviceInfo.TYPE_USB_HEADSET/DEVICE` | Identify USB audio devices | 26+ | **Used** |
| `BluetoothDevice.getBatteryLevel()` (reflection) | Read BT device battery level | Hidden | **Investigated only** |
| `ACTION_BATTERY_LEVEL_CHANGED` broadcast | Monitor BT battery changes | Undocumented | **Investigated only** |
| `MediaRouter` | Track selected audio route | 16+ | **Not used** |
| `ACTION_HEADSET_PLUG` broadcast | Legacy headset plug detection | 3+ | **Not used** (deprecated) |
| `isWiredHeadsetOn()` / `isBluetoothA2dpOn()` | Legacy checks | Deprecated | **Not used** |

## 2. APIs Actually Used

### Core Detection
1. **`AudioManager.registerAudioPlaybackCallback()`** — Real-time notification when audio playback starts/stops across all apps
2. **`AudioManager.getActivePlaybackConfigurations()`** — Polling current playback state
3. **`AudioPlaybackConfiguration.getAudioAttributes().getUsage()`** — Filtering media playback vs system sounds
4. **`AudioManager.registerAudioDeviceCallback()`** — Real-time notification when audio devices connect/disconnect
5. **`AudioManager.getDevices(GET_DEVICES_OUTPUTS)`** — Enumerating current output devices

### Background Execution
6. **Foreground Service** (`specialUse` type) — Keeps the monitoring process alive when app is backgrounded

### Flutter ↔ Android Communication
7. **MethodChannel** — For one-shot commands (start, stop, getState, permissions)
8. **EventChannel** — For streaming real-time audio events to Flutter

## 3. What Can Be Detected Reliably

| Capability | Reliability | Notes |
|------------|-------------|-------|
| Bluetooth device connected | ✅ High | AudioDeviceCallback fires reliably |
| Bluetooth device disconnected | ✅ High | AudioDeviceCallback fires reliably |
| Wired headphones connected | ✅ High | AudioDeviceCallback fires reliably |
| Wired headphones disconnected | ✅ High | AudioDeviceCallback fires reliably |
| USB audio device connected | ✅ High | AudioDeviceCallback fires reliably |
| USB audio device disconnected | ✅ High | AudioDeviceCallback fires reliably |
| Audio playback started | ✅ High | AudioPlaybackCallback fires for most apps |
| Audio playback stopped | ✅ High | AudioPlaybackCallback fires for most apps |
| Audio output device routing | ⚠️ Medium | Inferred from connected devices + priority; no direct "current output" API |
| Device name (Bluetooth) | ⚠️ Medium | Requires BLUETOOTH_CONNECT on API 31+; some devices report generic names |
| Device name (Wired) | ⚠️ Low | Often reports empty/generic string (e.g., "Headphones") |
| Media vs notification sound | ✅ High | AudioAttributes.USAGE distinguishes them well |

## 4. What Cannot Be Detected

| Limitation | Reason |
|------------|--------|
| **Whether earbuds are physically in the user's ears** | Android has no API for this. In-ear detection is proprietary hardware (Apple, Samsung, Sony, etc.) and not exposed to third-party apps |
| **Audio volume level per device** | AudioPlaybackConfiguration doesn't expose volume |
| **Which specific app is playing** | AudioPlaybackConfiguration does not expose the package name of the player (security/privacy restriction) |
| **Pause vs Stop distinction** | Android's AudioPlaybackCallback reports both as configuration removal. There is no explicit "paused" state in the callback |
| **Exact audio output routing** | Android doesn't have a `getCurrentOutputDevice()` API. We infer from connected devices using priority heuristics |

## 5. Bluetooth Behavior

### What Works
- **A2DP connections**: Detected reliably via `AudioDeviceCallback`
- **BLE audio**: Detected via `TYPE_BLE_HEADSET` (API 31+)
- **Device names**: Available with `BLUETOOTH_CONNECT` permission on API 31+
- **Connect/disconnect events**: Fire promptly, including unexpected disconnects

### What Doesn't
- **Battery level**: Not available through any official public API. Hidden `getBatteryLevel()` via reflection is unreliable across manufacturers
- **In-ear detection**: Completely inaccessible from Android. This is proprietary hardware-level logic
- **Device type distinction**: Cannot reliably distinguish "earbuds" from "headphones" from "speakers". `TYPE_BLUETOOTH_A2DP` covers all of them
- **Multiple simultaneous BT audio**: Android typically only routes audio to one A2DP device at a time. Multi-point BT is manufacturer-specific

### Battery Investigation
- `BluetoothDevice.getBatteryLevel()` exists as a hidden/internal API accessible via reflection
- Returns -1 on many devices/manufacturers
- `ACTION_BATTERY_LEVEL_CHANGED` broadcast exists but is undocumented and inconsistent
- **Verdict**: Battery tracking is NOT reliably feasible without manufacturer SDKs. Recommend deferring to Phase 2+ and considering Bluetooth GATT Battery Service for individual device profiles

## 6. Wired Headphone Behavior

### What Works
- **3.5mm headphone jack**: Detected as `TYPE_WIRED_HEADPHONES` (no mic) or `TYPE_WIRED_HEADSET` (with mic)
- **Connection events**: Fire instantly when plugged in/unplugged
- **Audio routing**: Android automatically routes audio to wired headphones when plugged in, and back to speaker when unplugged

### What Doesn't
- **Device identification**: Wired headphones typically have no identity. `productName` is usually empty or "Headphones"
- **Type distinction**: Cannot distinguish brands, models, or even headphones vs earphones for wired connections
- **USB-C wired audio**: Detected as `TYPE_USB_HEADSET` or `TYPE_USB_DEVICE` — works when the device exposes a standard USB audio interface

## 7. Background/Locked-Screen Behavior

### Mechanism Used
A **Foreground Service** with `specialUse` type is required for reliable continuous monitoring.

### Why It's Necessary
- Android kills background processes aggressively (especially on battery-optimized OEM ROMs: Xiaomi, Samsung, Huawei, Oppo)
- `AudioDeviceCallback` and `AudioPlaybackCallback` stop firing when the process is killed
- WorkManager/JobScheduler are not suitable for real-time event monitoring (they batch work)
- `START_STICKY` helps restart the service if killed, but doesn't prevent initial killing

### Why `specialUse` (Not `mediaPlayback`)
- `mediaPlayback` foreground service type is for apps that **play** audio
- This app **monitors** audio — it does not play anything
- `specialUse` is the correct type for monitoring/tracking use cases
- Requires a `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` declaration in the manifest

### Observed Behavior
- ✅ Monitoring continues when screen is locked
- ✅ Monitoring continues when switching to another app
- ⚠️ Some OEM battery optimization (Xiaomi MIUI, Samsung One UI) may still kill the service despite foreground status
- ⚠️ Users may need to disable battery optimization for this app manually on aggressive OEM ROMs

## 8. Known Android Limitations

1. **No "current output device" API**: Must infer from connected device list
2. **No pause/stop distinction**: AudioPlaybackCallback doesn't differentiate
3. **OEM fragmentation**: Xiaomi, Samsung, Huawei have aggressive battery optimization that can kill foreground services
4. **No per-app audio tracking**: Cannot determine which app is producing audio
5. **Audio focus is separate from playback**: An app may hold audio focus without actively playing
6. **Notification sounds**: Short notification pings trigger AudioPlaybackCallback — must filter by `USAGE_MEDIA`
7. **System sounds**: Similarly trigger callbacks — filtered by checking AudioAttributes usage type

## 9. Manufacturer/Device-Specific Limitations

| Manufacturer | Issue | Workaround |
|-------------|-------|------------|
| **Xiaomi (MIUI)** | Aggressive battery optimization kills foreground services | User must manually add app to "No restrictions" battery list |
| **Samsung (One UI)** | "Sleeping apps" feature can restrict background activity | User must disable "Put unused apps to sleep" for this app |
| **Huawei (EMUI/HarmonyOS)** | Extra battery management layer | User must enable "Allow background activity" |
| **Oppo/Realme (ColorOS)** | Similar to Xiaomi restrictions | User must manually whitelist the app |
| **Google Pixel/Stock Android** | Generally well-behaved | No special action needed |
| **All manufacturers** | BT device names may be generic or missing | Cannot be fixed; depends on device firmware |

## 10. Recommended Architecture for Phase 2

### Core Architecture
```
Flutter UI Layer
    ↕ MethodChannel / EventChannel
Native Android Layer (Kotlin)
    ├── AudioMonitorEngine (existing, extend)
    ├── AudioMonitorService (existing foreground service)
    ├── SessionManager (new: manage multiple sessions, persistence)
    └── BreakRecommendationEngine (new: analyze sessions, suggest breaks)
```

### Recommended Additions for Phase 2
1. **Local database** (Room/sqflite) for session history persistence
2. **Session analytics**: Daily/weekly listening duration summaries
3. **Break recommendation engine**: Based on configurable rules (not ML)
4. **Notification-based break reminders**: Use the existing notification channel
5. **Settings screen**: Grace period, break frequency, notification preferences
6. **Battery optimization guidance**: In-app instructions for OEM-specific settings
7. **Widget/Quick Settings Tile**: For quick session visibility

### What NOT to Add in Phase 2
- Cloud sync (premature)
- Social features (premature)
- ML-based predictions (insufficient data)
- Hearing health claims (medical liability)
