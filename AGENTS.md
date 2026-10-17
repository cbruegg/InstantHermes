# AGENTS.md

This file provides guidance for AI agents working on the InstantHermes project.

## Product and Current Status

InstantHermes is an implemented iOS/watchOS voice interface for [Hermes](https://github.com/NousResearch/hermes-agent), typically running on a Raspberry Pi alongside the InstantHermes Python backend.

### Implemented Flow: Fire and Forget
- Capture microphone audio with AVAudioEngine and convert to 16 kHz mono float32 PCM.
- Stream sequenced audio chunks to the backend on port 8643.
- Manual submit or 3 seconds of silence after detected sound ends recording and submits the buffered audio.
- The backend accepts with HTTP 202, then sends audio to Mistral Voxtral over HTTPS for transcription and forwards the transcript to Hermes on port 8642.
- The app returns to idle on acceptance; it does not wait for processing to finish.
- If configured, the backend delivers the response to a platform's home channel via `hermes send`.

Interactive TTS conversation is not implemented. Do not describe planned behavior as a current feature.

### Security: Hermes API Access
- Do not expose either service to the public internet. The documented setup binds both to the server's Tailscale IP; the backend falls back to loopback if Tailscale discovery fails.
- App-to-server HTTP relies on correct Tailscale routing. The app does not enforce VPN use; do not claim that HTTP is inherently secure or that all processing stays inside the tailnet.
- Audio leaves the tailnet for Mistral transcription. Hermes model providers/tools and optional reply platforms can receive further data. See the README privacy section.
- Currently the apps, backend, and Hermes share `API_SERVER_KEY`, granting clients access to the full reachable Hermes API. This is a limitation, not a restricted backend credential boundary.
- App configuration is stored in Keychain and synced to the paired watch via WatchConnectivity. The Mistral key stays out of the apps but is sent to Mistral for authentication.
- Do not commit credentials or log additional audio, transcripts, or agent output. Existing backend logs may contain sensitive output/error details.

## Design Decisions

### Auto-start recording on resume (watchOS only)
- **watchOS**: Auto-starts recording when the recording view appears AND when the app resumes (scene becomes active), provided it is configured and idle. This is intentional — the watch is a "raise and speak" interface.
- **iOS**: Auto-starts when the recording view appears. Does NOT auto-start just because the scene resumes. This is intentional — the iPhone app has tabs (Record, Settings); auto-starting on every resume would be surprising when the user just wants to check settings.
- Do not "fix" this platform difference — it is by design.

### Acceptance, Cancellation, and Liveness
- Shared state machine: `idle` → `recording` → `submitting` → `idle`.
- HTTP 202 means accepted, not that transcription or agent execution succeeded.
- The UI exposes Cancel while recording/submitting, not after acceptance. Backend cancellation is best-effort before dispatch and cannot undo agent actions; avoid unconditional cancellation guarantees.
- After acceptance, the client attempts keepalives every 5 seconds for up to 90 seconds. The backend checks a 15-second freshness/grace window before forwarding; this is not proof of a live connection or guaranteed background execution.

## Project Overview

- **iOS App**: `InstantHermes` — Main app for iPhone/iPad
- **Watch App**: `InstantHermesWatchApp` — Companion app for Apple Watch
- **Tech Stack**: SwiftUI, Combine, AVFoundation, URLSession, WatchConnectivity, Security/Keychain; Python stdlib HTTP backend
- **Documented Xcode Requirement**: 27.0+
- **Deployment Targets**: iOS 27.0, watchOS 10.0

## Project Structure

```
InstantHermes/
├── InstantHermes/                # iOS entry point, tabs, settings/status, config sync
├── InstantHermesWatchApp/        # Watch entry point, Views/, Services/, Complication/
├── Shared/                      # Compiled into both app targets
│   ├── Models/RecordingState.swift
│   ├── Services/AudioRecordingService.swift
│   ├── Networking/STTClient.swift
│   ├── Utilities/AppConfig.swift
│   ├── ViewModels/RecordingViewModel.swift
│   └── Views/                   # RecordingView and AudioWaveformView
├── backend/                     # server.py, user systemd unit, API/setup docs
├── Config/                      # App Info.plists, including ATS exceptions
├── Design/                      # Icon generation resources
├── InstantHermesTests/          # Swift Testing scaffold
├── InstantHermesUITests/        # XCTest launch/performance scaffold
└── InstantHermes.xcodeproj/      # Xcode project
```

Shared uses Xcode file-system-synchronized groups and is included in both app
targets. Keep platform-specific behavior behind the existing conditional
compilation patterns. There are no SwiftData models in the current app.

Backend installation and API examples live in `README.md` and
`backend/README.md`. The supplied systemd unit is a user unit; the main README
has a separate system-service configuration.

## Build & Run

The simulator names below are examples. Check `xcrun simctl list devices` for
available devices on the current machine and adjust destinations as needed.

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

## Validation

Build both app targets when changing shared Swift code. The existing unit test
is an empty template and UI tests cover launch/performance only; do not treat
them as functional or security coverage. Add focused regression tests when
changing recording, networking, or backend behavior, and report which checks
were actually run. For backend manual smoke tests, see `backend/README.md`;
use a test Hermes instance because submission can trigger agent actions and
billable cloud calls.

Do not assume a particular simulator GUI or local Xcode installation exists.
Use `xcrun simctl` for headless operations when available.

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
