# Phase 1: Test Results — Listening Tracker

## Test Environment

- **Device**: *(Fill in your test device)*
- **Android Version**: *(Fill in)*
- **Flutter Version**: 3.47.0
- **Dart Version**: 3.13.0
- **Date**: *(Fill in test date)*

## Important Disclaimer

> **The app cannot determine with certainty whether earbuds are physically inside the user's ears.**
>
> It can only infer usage from device connection state and audio playback information.
> Android does not expose any API for in-ear detection. This is proprietary hardware-level
> functionality controlled by individual headphone manufacturers (Apple, Samsung, Sony, etc.)
> and is not accessible to third-party apps.

---

## Bluetooth Tests

| # | Test | Expected | Actual | Pass/Fail | Notes |
|---|------|----------|--------|-----------|-------|
| 1 | Connect earbuds without playing audio | DEVICE_CONNECTED event, state = CONNECTED (Silent) | | | |
| 2 | Start music | AUDIO_STARTED event, state = LISTENING, timer starts | | | |
| 3 | Pause music | AUDIO_STOPPED event, timer pauses, grace period starts | | | |
| 4 | Resume music | AUDIO_STARTED event, timer resumes (same session) | | | |
| 5 | Stop music | AUDIO_STOPPED event, timer pauses | | | |
| 6 | Disconnect earbuds | DEVICE_DISCONNECTED event, session ends immediately | | | |
| 7 | Reconnect earbuds | DEVICE_CONNECTED event, new session ready | | | |
| 8 | Lock phone while music plays | Monitoring continues, timer keeps running | | | |
| 9 | Unlock phone | State refreshes correctly, timer shows accurate elapsed time | | | |
| 10 | Switch audio from earbuds to speaker | AUDIO_OUTPUT_CHANGED event detected | | | |

## Wired Tests

| # | Test | Expected | Actual | Pass/Fail | Notes |
|---|------|----------|--------|-----------|-------|
| 11 | Plug in wired earphones | DEVICE_CONNECTED event | | | |
| 12 | Start music | AUDIO_STARTED event, timer starts | | | |
| 13 | Pause music | AUDIO_STOPPED event, timer pauses | | | |
| 14 | Resume music | AUDIO_STARTED event, timer resumes | | | |
| 15 | Stop music | AUDIO_STOPPED event | | | |
| 16 | Unplug earphones | DEVICE_DISCONNECTED event, session ends | | | |
| 17 | Lock/unlock phone with wired earphones | Monitoring continues through lock/unlock cycle | | | |

## Application Compatibility Tests

| App | Audio Started | Audio Stopped | Audio Paused | Notes |
|-----|--------------|---------------|--------------|-------|
| Spotify | | | | |
| YouTube / YouTube Music | | | | |
| Local media player | | | | |
| Instagram / Reels | | | | |

## Edge Case Tests

| # | Test | Expected | Actual | Pass/Fail | Notes |
|---|------|----------|--------|-----------|-------|
| E1 | Earbuds connected, no audio playing | State = CONNECTED (Silent), no timer | | | |
| E2 | Audio paused for 10 seconds | Timer paused, within grace period, session continues | | | |
| E3 | Audio paused for several minutes | Grace period expires (3 min), session ends | | | |
| E4 | Notification sound plays | Should NOT start a listening session (filtered by USAGE_MEDIA) | | | |
| E5 | System sound plays | Should NOT start a listening session (filtered by AudioAttributes) | | | |
| E6 | Another app briefly takes audio focus | Brief interruption logged, session should continue | | | |
| E7 | Bluetooth disconnects unexpectedly | DEVICE_DISCONNECTED event, session ends | | | |
| E8 | Bluetooth reconnects automatically | DEVICE_CONNECTED event, new session ready | | | |
| E9 | Multiple Bluetooth devices available | Should track the currently active output device | | | |
| E10 | Audio switches between BT and wired | AUDIO_OUTPUT_CHANGED event with device details | | | |

## Device Routing Tests

### Test: BT → Disconnect → Speaker

| Step | Expected Event | Actual | Pass/Fail |
|------|---------------|--------|-----------|
| Connect BT earbuds | DEVICE_CONNECTED | | |
| Play audio | AUDIO_STARTED | | |
| Disconnect BT | DEVICE_DISCONNECTED + AUDIO_OUTPUT_CHANGED | | |
| Audio continues on speaker | State = PLAYING (Speaker) | | |

### Test: Wired → Unplug → Speaker

| Step | Expected Event | Actual | Pass/Fail |
|------|---------------|--------|-----------|
| Plug in wired headphones | DEVICE_CONNECTED | | |
| Play audio | AUDIO_STARTED | | |
| Unplug headphones | DEVICE_DISCONNECTED + AUDIO_OUTPUT_CHANGED | | |
| Audio continues on speaker (or pauses) | State updates accordingly | | |

## Background/Locked-Screen Tests

| # | Test | Expected | Actual | Pass/Fail | Notes |
|---|------|----------|--------|-----------|-------|
| B1 | Start monitoring, lock screen | Foreground service notification visible, monitoring continues | | | |
| B2 | Play music while screen locked | AUDIO_STARTED event detected | | | |
| B3 | Stop music while screen locked | AUDIO_STOPPED event detected | | | |
| B4 | Switch to another app | Monitoring continues, events still received | | | |
| B5 | Return to app after background | State refreshes correctly | | | |
| B6 | Leave app in background for 30+ min | Service still running (check notification) | | | |

## Session Timer Tests

| # | Test | Expected | Actual | Pass/Fail | Notes |
|---|------|----------|--------|-----------|-------|
| S1 | Audio starts | Timer starts at 00:00:00 | | | |
| S2 | Audio pauses briefly (<3 min) | Timer pauses, resumes on audio restart (same session) | | | |
| S3 | Audio pauses > 3 min | Session ends, total duration logged | | | |
| S4 | Device disconnects during session | Session ends immediately | | | |

---

## Summary

- **Total tests defined**: 40+
- **Tests passed**: *(Fill in after testing)*
- **Tests failed**: *(Fill in after testing)*
- **Tests not applicable**: *(Fill in if device doesn't have 3.5mm jack, etc.)*

## Overall Assessment

*(Fill in after completing on-device testing)*
