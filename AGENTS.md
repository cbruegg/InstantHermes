# AGENTS.md

This file provides guidance for AI agents working on the InstantHermes project.

## Project Overview

**InstantHermes** is a SwiftUI application with an Apple Watch companion app.

- **iOS App**: `InstantHermes` — Main app for iPhone/iPad
- **Watch App**: `InstantHermesWatchApp` — Companion app for Apple Watch
- **Tech Stack**: SwiftUI, SwiftData, WatchConnectivity
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
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

### Build for watchOS Simulator
```bash
xcodebuild -project InstantHermes.xcodeproj \
  -scheme "InstantHermesWatchApp" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (42mm)' \
  -sdk watchsimulator \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
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

### Available watchOS Simulators
- Apple Watch Series 12 (42mm) — UDID: `3E6AB3E7-D55D-4B56-BDA8-DDD7C8C183D4`
- Apple Watch Series 12 (46mm)
- Apple Watch Ultra 4 (49mm)
- Apple Watch SE 3 (40mm / 44mm)

### Code Signing
For simulator builds, disable code signing:
```bash
CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Data Sync Architecture

The iOS app and Watch app sync data via **WatchConnectivity**:

- Each device has its own **SwiftData** container (not shared)
- When items change on either device, the full list is sent to the other device
- The watch app requests items from the iPhone when it becomes reachable
- Sync is "last writer wins" (no conflict resolution)

## Key Build Settings

| Setting | iOS App | Watch App |
|---------|---------|-----------|
| Bundle ID | `com.cbruegg.InstantHermes` | `com.cbruegg.InstantHermes.watchkitapp` |
| Product Type | `com.apple.product-type.application` | `com.apple.product-type.application` |
| Deployment Target | iOS 27.0 | watchOS 10.0 |
| Supported Platforms | `iphoneos iphonesimulator` | `watchos watchsimulator` |
| Device Family | `1,2` | `4` |
| WKCompanionAppBundleIdentifier | — | `com.cbruegg.InstantHermes` |

> **Note**: The watch app uses `com.apple.product-type.application` (not `.watchapp2`) for Xcode 14+ compatibility. Using `.watchapp2` causes "Multiple commands produce" build errors.

## Common Issues

### "Multiple commands produce" error on watch app
**Cause**: Using `com.apple.product-type.application.watchapp2` product type.
**Fix**: Use `com.apple.product-type.application` instead.

### WatchConnectivity not available on macOS
**Cause**: `WatchConnectivity` framework is iOS/watchOS only.
**Fix**: Wrap WatchConnectivity code in `#if canImport(WatchConnectivity)`.

### Watch app not embedded in iOS app
**Cause**: Missing "Embed Watch Content" copy files build phase.
**Fix**: Add a `PBXCopyFilesBuildPhase` with `dstPath = Watch`, `dstSubfolderSpec = 13` to the iOS target.
