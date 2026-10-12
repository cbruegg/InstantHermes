# AGENTS.md

This file provides guidance for AI agents working on the InstantHermes project.

## Product Vision

**Build Hermes agent watchOS and iOS voice app**

InstantHermes is a voice interface for [Hermes](https://github.com/NousResearch/hermes-agent) — an AI agent that runs on a Raspberry Pi. The app lets you talk to Hermes from your iPhone or Apple Watch.

### Default Mode: Fire and Forget
- Record voice and send that to Hermes API as **audio file** (no transcription!)
- Hermes processes the audio and responds
- User does not wait for a response

### Interactive Mode: Voice Conversation
- Record voice → send to Hermes → Hermes responds using **TTS** (text-to-speech)
- Start a **fresh session** for each interaction to ensure fast response
- Real-time back-and-forth conversation

### Security: Hermes API Access
- **Do NOT expose full Hermes API remotely**
- **MVP approach**: No server component — mandate **Tailscale** for the connection
  - Hermes runs on Raspberry Pi on the local network
  - iPhone/Watch connects via Tailscale VPN
  - All communication stays within the Tailscale network
- Future: Optionally implement a small, very restricted backend to run alongside Hermes on the Raspberry Pi with authentication (maybe some kind of pairing mechanism)

### Status
- **Does not exist yet** — this is a greenfield project
- iPhone app first, watchOS companion second
- Default mode is MVP

## Design Decisions

### Auto-start recording on resume (watchOS only)
- **watchOS**: Auto-starts recording on launch AND when the app resumes (scene becomes active). This is intentional — the watch is a "raise and speak" interface where reopening the app should immediately begin recording.
- **iOS**: Auto-starts on launch only. Does NOT auto-start on resume. This is also intentional — the iPhone app has tabs (Record, Settings); auto-starting on every resume would be surprising when the user just wants to check settings.
- Do not "fix" this platform difference — it is by design.

## Project Overview

- **iOS App**: `InstantHermes` — Main app for iPhone/iPad
- **Watch App**: `InstantHermesWatchApp` — Companion app for Apple Watch
- **Tech Stack**: SwiftUI, SwiftData, WatchConnectivity, AVFoundation (audio recording/playback)
- **Xcode Version**: 27.0
- **Deployment Targets**: iOS 27.0, watchOS 10.0

## Project Structure

```
InstantHermes/
├── InstantHermes/                 # iOS app source
│   ├── InstantHermesApp.swift     # App entry point
│   ├── ContentView.swift          # Main UI
│   ├── Item.swift                 # SwiftData model
│   └── WatchConnectivityManager.swift  # iPhone ↔ Watch sync
├── InstantHermesWatchApp/         # Watch app source
│   ├── InstantHermesWatchApp.swift # Watch app entry point
│   ├── ContentView.swift          # Watch-optimized UI
│   ├── Item.swift                 # SwiftData model (duplicated)
│   └── WatchConnectivityManager.swift  # Watch ↔ iPhone sync
├── InstantHermesTests/            # Unit tests (Swift Testing)
├── InstantHermesUITests/          # UI tests (XCTest)
└── InstantHermes.xcodeproj/       # Xcode project
```

## Build & Run

### Build for iOS Simulator
```bash
xcodebuild -project InstantHermes.xcodeproj \
  -scheme InstantHermes \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -sdk iphonesimulator \
  build
```

### Build for watchOS Simulator
```bash
xcodebuild -project InstantHermes.xcodeproj \
  -scheme "InstantHermesWatchApp" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (42mm)' \
  -sdk watchsimulator \
  build
```

### Run on Simulator (headless)
```bash
# List available devices
xcrun simctl list devices

# Boot a device
xcrun simctl boot <device-udid>

# Install the app
xcrun simctl install <device-udid> <path-to-.app>

# Launch the app
xcrun simctl launch <device-udid> com.cbruegg.InstantHermes.watchkitapp

# Take a screenshot
xcrun simctl io <device-udid> screenshot /tmp/screenshot.png
```

## Development Environment Notes

### ⚠️ Simulator.app is NOT installed — use Device Hub instead

The classic **Simulator.app** GUI has been **replaced by the new Device Hub app** in this Xcode installation. The `Simulator.app` binary is not present at:

- `/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app` (does not exist)
- `/Applications/Simulator.app` (not found)

**To manage simulators visually, use the Device Hub app** (part of Xcode 27's new device management UI). Alternatively, use `xcrun simctl` commands for headless operation.

## Common Issues

### "Multiple commands produce" error on watch app
**Cause**: Using `com.apple.product-type.application.watchapp2` product type.
**Fix**: Use `com.apple.product-type.application` instead.

### WatchConnectivity not available on macOS
**Cause**: `WatchConnectivity` framework is iOS/watchOS only.
**Fix**: Wrap WatchConnectivity code in `#if canImport(WatchConnectivity)`.

### Watch app not embedded in iOS app
**Cause**: Missing "Embed Watch Content" copy files build phase.
**Fix**: Add a `PBXCopyFilesBuildPhase` with `dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"`, `dstSubfolderSpec = 16` to the iOS target. Verify that the built companion is at `InstantHermes.app/Watch/InstantHermesWatchApp.app`; destination specifier 13 is `PlugIns`, not `Watch`.
