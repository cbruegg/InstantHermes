# InstantHermes

A voice interface for [Hermes](https://github.com/NousResearch/hermes-agent) — an AI agent that runs on a Raspberry Pi. Talk to Hermes from your iPhone or Apple Watch.

## How it works

```
iPhone / Apple Watch
  │  Record voice → stream PCM audio chunks
  ▼
Tailscale (WireGuard-encrypted VPN)
  ▼
instanthermes-stt backend  (:8643, on the Raspberry Pi)
  │  Reassembles audio → wraps in WAV → transcribes via Mistral Voxtral
  ▼
Hermes API server  (:8642, on the Raspberry Pi)
  │  POST /v1/runs — fire and forget
  ▼
Hermes response delivered to your chosen platform (Matrix, Telegram, etc.)
```

**Fire and forget:** You record, hit submit (or just stop talking), and the app returns to idle immediately. Transcription and the Hermes submission happen in the background on the Pi. If you set a delivery target, the Hermes response is delivered to that platform's home channel.

## Features

- **iOS app** — Record tab (same interface as the watch) + Settings tab
- **watchOS app** — One-tap recording with auto-submit after 3 seconds of silence
- **Shared code** — All recording logic, networking, and UI is shared between iOS and watchOS via a `Shared/` directory compiled into both targets
- **Cancellation** — Cancel at any point before the Hermes POST; the backend aborts processing
- **Liveness detection** — After submit, the app sends keepalive pings; if the app dies or goes out of range, the backend aborts before submitting to Hermes
- **Secure** — All traffic stays inside the Tailscale network (WireGuard end-to-end encrypted). The backend binds only to the Tailscale IP. Bearer auth with a shared API key.

## Prerequisites

### On the Raspberry Pi (server)

| Requirement | Details |
|-------------|---------|
| **Tailscale** | Installed, connected, and running (`tailscale up`) |
| **Hermes** | Installed with the API server enabled (see [Hermes configuration](#hermes-configuration) below) |
| **Python 3** | Stdlib only — no pip dependencies needed for the backend |
| **ffmpeg** | Fallback for audio format conversion (already a Hermes dependency) |
| **Mistral API key** | For Voxtral speech-to-text transcription ([get one here](https://console.mistral.ai/)) |

### On your iPhone / Apple Watch (client)

| Requirement | Details |
|-------------|---------|
| **iOS 27.0+** / **watchOS 10.0+** | Deployment targets |
| **Tailscale** | Installed and connected on the iPhone (the watch routes traffic through the iPhone) |
| **Apple Watch** (optional) | Paired with the iPhone; the watch app is embedded in the iOS app |

### For building from source

| Requirement | Details |
|-------------|---------|
| **Xcode 27.0+** | On macOS |
| **Apple Developer account** | For code signing |

## Hermes configuration

The backend reads its configuration from `~/.hermes/.env` on the Raspberry Pi. Make sure these variables are set:

```bash
# ~/.hermes/.env

# Enable the Hermes API server (required)
API_SERVER_ENABLED=true

# Shared secret — the same key the iOS/watch app uses to authenticate.
# Generate with: openssl rand -hex 32
API_SERVER_KEY=<your-secret-key-here>

# The Raspberry Pi's Tailscale IP (from `tailscale ip -4`).
# Hardcode it — Tailscale IPs are stable.
API_SERVER_HOST=<tailscale-ip-of-raspi>

# Hermes API server port (default: 8642)
# API_SERVER_PORT=8642

# Mistral API key for Voxtral speech-to-text (required for the STT backend)
MISTRAL_API_KEY=<your-mistral-api-key>
```

Also make sure the **Hermes gateway** is running persistently — the API server only exists inside the gateway:

```bash
hermes gateway
# or under systemd for persistence
```

## Backend setup (Raspberry Pi)

The backend is a single-file, stdlib-only Python service (`backend/server.py`) that runs under systemd. It:

1. Receives streamed PCM audio chunks from the app
2. Reassembles them and wraps them in a WAV container
3. Transcribes via [Mistral Voxtral](https://docs.mistral.ai/capabilities/audio/) (`voxtral-mini-latest`)
4. POSTs the transcript to the Hermes API (`/v1/runs`) with a voice context prepended
5. If a delivery target is set, polls the run and delivers the response via `hermes send`

### Installation (user systemd service — recommended, no sudo)

```bash
# On the Raspberry Pi:

# 1. Copy the backend files
mkdir -p ~/InstantHermes-backend
cp backend/server.py ~/InstantHermes-backend/

# 2. Install the systemd user unit
mkdir -p ~/.config/systemd/user
cp backend/instanthermes-stt.service ~/.config/systemd/user/

# 3. Enable lingering (so the service runs even when you're not logged in)
sudo loginctl enable-linger $USER

# 4. Enable and start
systemctl --user daemon-reload
systemctl --user enable --now instanthermes-stt

# 5. Verify
systemctl --user status instanthermes-stt
curl http://$(tailscale ip -4):8643/health
# → {"ok": true, "mistral_configured": true}
```

### Installation (system systemd service — requires sudo)

```bash
sudo mkdir -p /opt/instanthermes-stt
sudo cp backend/server.py /opt/instanthermes-stt/
sudo cp backend/instanthermes-stt.service /etc/systemd/system/

# Edit the unit to run as the Hermes user (so ~/.hermes/.env resolves):
sudo systemctl edit instanthermes-stt
# Add:
#   [Service]
#   User=<hermes-user>

sudo systemctl daemon-reload
sudo systemctl enable --now instanthermes-stt
```

### Verifying the backend

From any device on the tailnet (e.g., your iPhone with Tailscale, or a Mac):

```bash
# Health check (no auth required)
curl http://raspi5.<your-tailnet>.ts.net:8643/health
# → {"ok": true, "mistral_configured": true}

# Hermes health check
curl http://raspi5.<your-tailnet>.ts.net:8642/health
```

See [`backend/README.md`](backend/README.md) for the full API contract and curl-based testing examples.

## App setup (iPhone + Apple Watch)

### 1. Build and install

Open `InstantHermes.xcodeproj` in Xcode, select your team for signing, and run on your iPhone. The watch app is embedded automatically.

Or build from the command line:

```bash
# iOS
xcodebuild -project InstantHermes.xcodeproj \
  -scheme InstantHermes \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# watchOS
xcodebuild -project InstantHermes.xcodeproj \
  -scheme "InstantHermesWatchApp" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (42mm)' \
  build
```

### 2. Configure the server

1. Open the **InstantHermes** app on your iPhone
2. Go to the **Settings** tab
3. Tap **Configure**
4. Enter:
   - **Server host**: Your Pi's MagicDNS hostname (e.g., `raspi5.mytailnet.ts.net`)
     - Use the MagicDNS hostname, **not** an IP address — iOS ATS (App Transport Security) blocks HTTP to IPs. The app has ATS exceptions for `*.ts.net` and `*.cbruegg.com`.
   - **API Key**: The `API_SERVER_KEY` from `~/.hermes/.env`
   - **Reply in**: Where Hermes should deliver its response (e.g., `matrix`, `telegram`, `discord`, `slack`, `whatsapp`, `signal`), or **Nowhere** for fire-and-forget
5. Tap **Test Connection** to verify both Hermes (:8642) and the STT backend (:8643) are reachable
6. Tap **Save**

The configuration is stored in the iOS Keychain and automatically synced to the Apple Watch via WatchConnectivity.

### 3. Make sure Tailscale is running

On your **iPhone**, start Tailscale. The watch has no Tailscale client — its traffic rides the paired iPhone's network connection.

### 4. Start recording

- **iPhone**: Open the app → **Record** tab → tap **Start Recording** (or just start talking — it auto-starts)
- **Apple Watch**: Open the watch app → it auto-starts recording immediately

Speak, then tap **Submit** (or just stop talking — auto-submit triggers after 3 seconds of silence). The recording is sent to the backend, which transcribes and forwards it to Hermes in the background.

## Usage

### Recording states

| State | What you see | Available actions |
|-------|-------------|-------------------|
| **Idle** | "Start Recording" button | Start |
| **Recording** | Live waveform, red bars | Cancel, Submit |
| **Submitting** | "Sending…" + spinner | Cancel (aborts processing) |

### Auto-submit

After you stop speaking for **3 seconds**, the recording is automatically submitted. No need to tap anything.

### Cancellation

Tap **Cancel** at any point:

- **During recording**: Stops the microphone and tells the backend to discard the audio. Hermes is never contacted.
- **During submitting** (before the backend accepts): Interrupts the submit request. Hermes is never contacted.
- **After the backend accepts (202)**: Signals the backend's background worker to abort before transcription and before the Hermes POST.

### Response delivery

If you set a **delivery target** in Settings (e.g., `matrix`), the backend:

1. Transcribes your audio
2. Sends the transcript to Hermes
3. Polls the Hermes run until it completes
4. Delivers the final response to that platform's home channel via `hermes send`

If you leave it as **Nowhere**, Hermes processes the message but doesn't reply anywhere (fire-and-forget).

## Troubleshooting

### "Not configured" on the watch

Open the iPhone app → Settings tab → Configure. The config syncs to the watch automatically when it's reachable. On the watch, pull down or reopen the app to trigger a refresh.

### "Server not configured" error

The host or API key is missing. Go to the iPhone app's Settings tab and configure the server.

### Connection test fails: "ATS blocked"

You entered an IP address instead of a MagicDNS hostname. Use `raspi5.<your-tailnet>.ts.net` (or `raspi5.cbruegg.com`), not `100.x.y.z`. iOS ATS blocks plain HTTP to IP addresses; the ATS exception only works for domain names.

### Connection test fails: "Cannot connect"

- Is Tailscale running on your iPhone?
- Is the hostname correct?
- Is the backend service running? Check with `systemctl --user status instanthermes-stt` on the Pi.

### Connection test fails: "No internet"

Tailscale is not connected on your iPhone. Start the Tailscale app and make sure it shows "Connected".

### Watch shows "Installed, not reachable"

The watch needs the iPhone nearby (Bluetooth or same WiFi network). Make sure:
- Bluetooth is on
- The iPhone is unlocked and nearby
- The InstantHermes iPhone app has been opened at least once

### Transcription fails / no response from Hermes

Check the backend logs on the Pi:

```bash
journalctl --user -u instanthermes-stt -f
```

Common causes:
- `MISTRAL_API_KEY` not set in `~/.hermes/.env`
- `API_SERVER_KEY` mismatch between the app and `~/.hermes/.env`
- Hermes gateway not running (`hermes gateway`)

### Backend won't start

```bash
# Check if the port is already in use
ss -tlnp | grep 8643

# Check Tailscale is up
tailscale status

# View detailed logs
journalctl --user -u instanthermes-stt -n 50 --no-pager
```

## Architecture details

### Ports

| Service | Port | Bound to |
|---------|------|----------|
| Hermes API server | 8642 | Tailscale IP |
| InstantHermes STT backend | 8643 | Tailscale IP |

Both services bind **only** to the Tailscale IP — nothing is exposed on the LAN.

### Audio pipeline

1. `AVAudioEngine` captures microphone audio
2. `AVAudioConverter` converts to 16 kHz mono float32 PCM (sample rate conversion)
3. PCM is batched (~64 KB per chunk, ~1 per second) and streamed via HTTP POST
4. The backend reassembles chunks and wraps them in a WAV container (IEEE float32)
5. Mistral Voxtral transcribes the WAV

Bandwidth is ~64 KB/s over the tailnet — trivial.

### Security model

- **Transport**: All traffic flows through Tailscale (WireGuard end-to-end encryption). Tailscale's coordination servers only do key exchange — they never see packet contents.
- **Authentication**: Both the app and the backend use `Authorization: Bearer <API_SERVER_KEY>` — the same key as Hermes.
- **Key storage**: The API key is stored in the iOS/watch Keychain with `kSecAttrSynchronizable = false` (never synced to iCloud).
- **Mistral key**: Never leaves the Raspberry Pi — only the backend reads it from `~/.hermes/.env`.
- **Cancellation invariant**: The backend's `POST /v1/runs` (the only request that turns audio into a Hermes message) fires only if the recording was submitted, not cancelled, and the client is still alive (keepalive freshness checked).

### Project structure

```
InstantHermes/
├── InstantHermes/              # iOS app (platform-specific)
│   ├── ContentView.swift       #   TabView: Record + Settings tabs
│   ├── StatusView.swift        #   Settings tab: server/watch status
│   ├── SettingsView.swift      #   Settings tab: server configuration form
│   └── WatchConnectivityManager.swift  # iOS-side: syncs config to watch
├── InstantHermesWatchApp/      # watchOS app (platform-specific)
│   ├── Views/ContentView.swift #   Thin wrapper → shared RecordingView
│   ├── Services/WatchConnectivityManager.swift  # Watch-side: receives config from iPhone
│   └── Complication/           #   Watch face complications
├── Shared/                     # Shared between both targets
│   ├── Models/RecordingState.swift
│   ├── Services/AudioRecordingService.swift  # AVAudioEngine + PCM streaming
│   ├── Networking/STTClient.swift            # HTTP client for the STT backend
│   ├── Utilities/AppConfig.swift             # Keychain config store
│   ├── ViewModels/RecordingViewModel.swift   # Recording state machine
│   └── Views/
│       ├── RecordingView.swift               # Main recording UI (platform-adaptive)
│       └── AudioWaveformView.swift           # Audio level visualization
├── backend/                    # STT backend (runs on the Raspberry Pi)
│   ├── server.py               #   Stdlib-only Python service
│   ├── instanthermes-stt.service  #   systemd unit
│   └── README.md               #   Backend API docs + testing
├── Config/                     # Info.plist files (ATS exceptions)
└── InstantHermes.xcodeproj
```

## Development

### Building

```bash
# iOS Simulator
xcodebuild -project InstantHermes.xcodeproj \
  -scheme InstantHermes \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build

# watchOS Simulator
xcodebuild -project InstantHermes.xcodeproj \
  -scheme "InstantHermesWatchApp" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (42mm)' \
  build
```

### Code sharing

The project uses Xcode's **file system synchronized groups** (`PBXFileSystemSynchronizedRootGroup`). The `Shared/` directory is added to both the iOS and watchOS targets — any file placed in `Shared/` is automatically compiled into both apps. Platform-specific differences are handled with `#if os(watchOS)`.

### Tech stack

- **SwiftUI** — UI framework
- **AVFoundation** — Audio recording and PCM conversion
- **WatchConnectivity** — iPhone ↔ Watch config sync
- **Security (Keychain)** — Secure API key storage
- **Swift Concurrency** — Async/await for networking and audio

## License

See [LICENSE](LICENSE) if present, or contact the author.
