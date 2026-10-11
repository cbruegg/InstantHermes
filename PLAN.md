# PLAN.md — Watch → STT Backend (Voxtral) → Hermes over Tailscale

Status: **implemented** (2026-10-11).

This is the revised plan for replacing the dummy `localhost:8080` audio endpoint with the real pipeline: the Apple Watch streams recorded audio to a tiny STT backend on the Raspberry Pi, which transcribes via Mistral Voxtral; the transcript is then submitted to the Hermes API server's message endpoint. Cancellation is end-to-end: cancelling means the transcript is never submitted to Hermes.

## 0. Locked-in decisions

| # | Decision | Consequence |
|---|----------|-------------|
| 1 | Streaming to the STT endpoint is fine | Audio leaves the watch during recording. The cancellation gate is **only** the message-endpoint POST (`/v1/runs`) — never triggered on Cancel. |
| 2 | No `tailscale serve` | Plain HTTP over the tailnet to the MagicDNS hostname; app needs a scoped ATS exception. (Tailscale cannot read the data either way — see §1.) |
| 3 | No PR branch; tiny systemd backend using **Mistral Voxtral**, key from **Hermes config** | New `instanthermes-stt` service on the raspi (port 8643). Reads `MISTRAL_API_KEY` from `~/.hermes/.env`. |
| 4 | Watch-direct | Watch holds the Hermes `API_SERVER_KEY` (synced from iPhone), talks to both `:8643` (STT) and `:8642` (Hermes) directly. |
| 5 | **PCM float32** (revised from AAC) | AAC encoding via `AVAudioConverter` requires `AudioToolbox`, which is **not available on watchOS**. Fallback per §5: stream 16 kHz mono float32 PCM (~32 KB/s — trivial bandwidth). Backend wraps PCM in WAV for Voxtral. |

## 1. Can Tailscale read the data?

**No — Tailscale cannot read the data, with or without `serve`.** Two independent reasons:

1. The data path is **end-to-end WireGuard-encrypted** between the iPhone's tailscaled and the raspi's tailscaled. Tailscale's coordination servers only do key exchange/discovery; they never see packet contents (if a direct connection fails, even the DERP relays only forward already-encrypted WireGuard packets). Tailscale sees *metadata* (which nodes talk, when, roughly how much) — never content.
2. `tailscale serve` terminates TLS **locally on the raspi** — tailscaled holds the certificate private key and proxies to `localhost:8642`. Tailscale's servers are not in the data path.

We are dropping `serve` per preference. Everything below is plain HTTP inside the tailnet, which is equally unreadable to Tailscale (WireGuard), and simpler to operate.

## 2. Architecture

```text
Apple Watch
  AVAudioEngine tap (waveform + silence detection, unchanged)
    → AVAudioConverter (PCM → AAC-LC, 16 kHz, mono, ~32 kbps)
    → ADTS frame wrap (self-delimiting frames)
    → batch ~0.5–1 s → chunk POSTs (retry on failure)
        |
        |  chunk uploads + submit/cancel actions
        v
instanthermes-stt  (systemd, raspi, :8643)
  reassembles ADTS → Mistral Voxtral
  (MISTRAL_API_KEY from ~/.hermes/.env)
        |
        |  transcript text — returned only after Submit
        v
Hermes API server  (hermes gateway, raspi, :8642)
  POST /v1/runs {"input": "<transcript>"} → 202, fire-and-forget

Both raspi services bind the Tailscale IP only and require the
same bearer key (API_SERVER_KEY).
```

**The cancellation invariant:** the only request that turns audio into "a complete message to Hermes" is `POST /v1/runs` with the transcript. It is sent **only** after Submit (manual tap or 3 s-silence auto-submit) **and** after the transcript came back. Cancel at any earlier point simply means that request never happens.

## 3. The STT backend service (`instanthermes-stt`)

A single-file, **stdlib-only** Python service (no pip deps) running under systemd on the raspi.

### 3.1 API contract

Mirrors the current app's pattern (single endpoint, `X-Action` header distinguishes actions from chunks) so app-side changes stay small.

All requests carry `Authorization: Bearer <API_SERVER_KEY>` — the **same key** as Hermes, so there is exactly one secret to configure and sync.

```text
POST /audio                       — chunk upload
  X-Recording-ID: <uuid>
  X-Chunk-Sequence: <int, 0-based, contiguous>
  X-Audio-Format: aac-adts
  X-Sample-Rate: 16000
  Body: raw ADTS AAC bytes
  → 200 {"ok": true}

POST /audio                       — action (X-Action header present → not a chunk)
  X-Recording-ID: <uuid>
  X-Action: submit | cancel
  → submit: 200 {"text": "<transcript>"}                        (after Voxtral completes)
            409 {"error": "audio_incomplete", "missing": [..]}  (sequence gap)
            503 {"error": "stt_unavailable", ...}               (no key / Voxtral failed)
  → cancel: 200 {"ok": true}                                    (discard buffered chunks)

GET /health → 200 {"ok": true, "mistral_configured": true|false}
```

### 3.2 Behavior

- **Spool:** in-memory `{recording_id: {seq: bytes}}` plus last-activity timestamp; 25 MB cap per recording.
- **Finalize (submit):** verify sequences are contiguous `0..N`, concatenate into a complete, valid ADTS `.aac` stream, call Voxtral. Always clean up the spooled entry after responding (success or failure).
- **Voxtral call:** `POST https://api.mistral.ai/v1/audio/transcriptions`, multipart `file=@recording.aac` (`audio/aac`), `model=voxtral-mini-latest`, `Authorization: Bearer $MISTRAL_API_KEY` → `{"text": "..."}`. **If Mistral rejects raw ADTS** (verify during implementation with a real clip): one-line fallback — `ffmpeg -i in.aac -ar 16000 -ac 1 out.wav`, retry. ffmpeg is already on the raspi (Hermes dependency).
- **Cleanup:** background sweeper deletes recordings idle > 10 min (watch died mid-recording → nothing transcribed, nothing submitted).
- **Auth:** reject missing/wrong bearer with 401 (defense in depth; the port is also Tailscale-IP-bound only).
- **Keys:** read `API_SERVER_KEY` and `MISTRAL_API_KEY` from `os.environ` first, then parse `~/.hermes/.env` (i.e. "the Mistral API key from Hermes config"). If `MISTRAL_API_KEY` is missing: `/health` reports it; finalize returns 503 with a clear message.
- **Bind:** discovers its own Tailscale IPv4 via `tailscale ip -4` at startup and binds `100.x.y.z:8643` — never listens on LAN. Self-healing: if tailscaled is not up yet, systemd ordering plus `Restart=always` retries.

### 3.3 Sketch

```python
#!/usr/bin/env python3
"""InstantHermes STT backend: streamed AAC chunks -> Mistral Voxtral.
Stdlib only. Binds the machine's Tailscale IP. Bearer-auth with API_SERVER_KEY."""
import json, os, subprocess, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STT_PORT      = int(os.environ.get("STT_PORT", "8643"))
VOXTRAL_URL   = "https://api.mistral.ai/v1/audio/transcriptions"
VOXTRAL_MODEL = "voxtral-mini-latest"
MAX_BYTES     = 25 * 1024 * 1024
TTL_SECONDS   = 600

def hermes_env():
    env = dict(os.environ)
    path = os.path.join(
        os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes")), ".env")
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                env.setdefault(k.strip(), v.strip().strip('"'))
    return env

API_KEY     = hermes_env().get("API_SERVER_KEY", "")
MISTRAL_KEY = hermes_env().get("MISTRAL_API_KEY", "")

recordings = {}   # id -> {"chunks": {seq: bytes}, "updated": ts}
lock = threading.Lock()

def tailscale_ip():
    return subprocess.check_output(
        ["tailscale", "ip", "-4"], text=True).strip().splitlines()[0]

def voxtral(audio: bytes) -> str:
    # hand-rolled multipart (~15 lines) -> urllib POST; ffmpeg->wav fallback
    ...

class Handler(BaseHTTPRequestHandler):
    def _auth(self) -> bool: ...
    def do_GET(self):  ...   # /health
    def do_POST(self): ...   # /audio: X-Action header? action : append chunk

def sweeper(): ...           # TTL thread

# main: ThreadingHTTPServer((tailscale_ip(), STT_PORT), Handler) + sweeper thread
```

### 3.4 systemd unit

`/etc/systemd/system/instanthermes-stt.service`:

```ini
[Unit]
Description=InstantHermes STT backend (Mistral Voxtral)
Requires=tailscaled.service
After=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/instanthermes-stt/server.py
Restart=always
RestartSec=5
# Run as the same user as Hermes so ~/.hermes resolves
User=<hermes-user>

[Install]
WantedBy=multi-user.target
```

Install:

```bash
sudo mkdir -p /opt/instanthermes-stt && sudo cp server.py /opt/instanthermes-stt/
sudo systemctl enable --now instanthermes-stt
# from any tailnet node:
curl http://raspi5.<tailnet>.ts.net:8643/health
# → {"ok": true, "mistral_configured": true}
```

## 4. Hermes side & transport

`~/.hermes/.env` on the raspi:

```bash
API_SERVER_ENABLED=true
API_SERVER_KEY=<openssl rand -hex 32>     # shared with the backend; >=16 chars enforced
API_SERVER_HOST=<raspi Tailscale IP>      # from `tailscale ip -4`; hardcode (stable)
MISTRAL_API_KEY=<your key>                # the STT backend reads this from here
```

Then ensure `hermes gateway` runs persistently (the API server only exists inside the gateway).

- **Binding:** both services bind the Tailscale IP only → **nothing on LAN**. Caveat: if the gateway starts before tailscaled assigns the IP, the bind fails — the API server retries with backoff (verify on the actual setup), but the clean fix is running `hermes gateway` under systemd with the same `After=/Requires=tailscaled.service` ordering as the STT unit. Fallback if this proves fragile: `API_SERVER_HOST=0.0.0.0` (the key is still required and enforced; LAN exposure is authenticated).
- **Addressing:** the app uses the **MagicDNS hostname** (`raspi5.<tailnet>.ts.net`), not the raw IP — it survives IP changes and lets us scope the ATS exception to a domain. Hermes = `http://<host>:8642`, backend = `http://<host>:8643`.
- **ATS (both watch and iOS targets):** plain HTTP needs `NSAppTransportSecurity` → `NSExceptionDomains` → `<tailnet>.ts.net` → `NSExceptionAllowsInsecureHTTPLoads: true` + `NSIncludesSubdomains: true`. Scoped to the tailnet only. Note: the project uses `GENERATE_INFOPLIST_FILE=YES` — either add the key via the `INFOPLIST_KEY_NSAppTransportSecurity` build setting or introduce a minimal physical `Info.plist`; resolve during implementation.
- **Watch connectivity:** the watch has no Tailscale client; its traffic rides the paired iPhone's network → iPhone's tailscaled → raspi. The iPhone must have Tailscale running (the normal case). A watch alone on WiFi cannot reach the tailnet — acceptable for MVP.

## 5. Watch-side recording & streaming pipeline (PCM float32)

**Revised during implementation (2026-10-11):** AAC encoding via `AVAudioConverter` requires `AudioToolbox`, which is **not available on watchOS**. The implemented approach streams **16 kHz mono float32 PCM** — the documented fallback from the original plan. Bandwidth is ~32 KB/s over the tailnet, which is trivial. The backend wraps the PCM in a WAV container (IEEE float32) before sending to Voxtral.

Pipeline replacing the original raw-float32 chunk sender:

1. `AVAudioEngine` tap (unchanged — waveform levels + silence detection keep working off it).
2. `AVAudioConverter`: PCM float32 at hardware rate → **PCM float32, 16 kHz, mono** (sample rate + channel conversion; no codec encoding needed).
3. **Batch** samples; flush as one chunk POST every ~0.5 s or ~4 KB. That is ~1 tiny request/sec over the tailnet.
4. Each chunk POST carries `X-Recording-ID` + incrementing `X-Chunk-Sequence` + `X-Audio-Format: pcm-float32`. **Retry** failed POSTs 3× (0.5/1/2 s backoff); if still failing → stop recording with an error (sequences stay contiguous by construction; the backend would 409 a gap anyway). Chunk uploads go through a small serial queue so finalize/cancel can wait for in-flight chunks to settle.

**Backend WAV wrapping:** the stdlib-only Python backend uses `struct` to write a minimal WAV header (IEEE float32, 16 kHz, mono, 46-byte header) around the concatenated PCM chunks, then sends the `.wav` to Voxtral.

**Future AAC upgrade path:** if AAC becomes desirable, the `AudioConverter` C API via the `AudioUnit` framework is available on watchOS. The backend already accepts `aac-adts` format as an alternative to `pcm-float32`.

### 5.1 App state machine

```text
idle
  └─ start ─→ recording ── Submit / 3 s silence ──→ transcribing ── transcript ──→ submitting ── 202 ──→ idle
                  │                                      │
                  └─ Cancel ──→ idle                     └─ Cancel ──→ idle (discard transcript)

recording    : streaming chunk POSTs; Cancel + Submit available
transcribing : finalize POST in flight (Voxtral); Cancel still available —
               the transcript is discarded when it arrives, never submitted
submitting   : POST /v1/runs in flight; no Cancel — 202 is the point of no return
```

- **Empty transcript** (silence/hallucination): do not POST to `/v1/runs` (it 400s on empty input); show "didn't catch that", reset.
- **Transcription latency sits on the Submit path** (~1–5 s for a short clip) so a **cancelled recording never costs a Voxtral call**. Alternative if instant Submit is preferred: the backend transcribes eagerly at stream end, the app holds the text, and Submit just POSTs it. Cancellation semantics are identical either way. **Open choice — finalize-on-Submit is the default.**
- Timeouts: finalize 60 s (Voxtral), `/v1/runs` 15 s (retry once, same `Idempotency-Key`), chunks 10 s.

### 5.2 Message submission

```bash
curl -X POST http://raspi5.<tailnet>.ts.net:8642/v1/runs \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <recording-uuid>" \
  -d '{"input": "<transcript>"}'
# → 202 {"run_id":"run_...","status":"started"} → fire-and-forget, app returns to idle
```

Omit `session_id` → fresh session per message (matches the product vision). `GET /health` (no auth) serves as the connectivity check.

## 6. End-to-end cancellation — analysis

| Cancel timing | What happens | Hermes processes anything? |
|---|---|---|
| During recording | Stop tap, drop batch, POST `cancel` → backend discards spooled chunks. | **No** — `/v1/runs` never called |
| Watch dies mid-recording | Backend sweeper deletes the partial spool after TTL. | **No** |
| During transcribing (Submit tapped, Voxtral in flight) | Keep Cancel available: when the transcript arrives, the app **discards it** — never POSTs to `/v1/runs`. (Cost: one Voxtral call; effect on Hermes: none.) | **No** |
| During `/v1/runs` POST (submitting) | No cancel UI; aborting mid-POST would also prevent processing (the server only dispatches on complete bodies), but 202 is treated as the point of no return. Fire-and-forget means the user is not waiting anyway. | Submitted by explicit user action |
| Future "cancel a submitted message" | Keep the `run_id` → `POST /v1/runs/{id}/stop` (interrupts at the next safe point, settles `cancelled`). Needed for interactive mode later. | Cooperative stop |

The invariant holds: **anything submitted to the STT backend is never "processed as a complete message to Hermes" — only the gated `/v1/runs` POST is, and Cancel at any point before it means it never fires.**

## 7. Config & secrets

- **iPhone app** (part of the MVVM work): a small settings UI — *Server host* (`raspi5.<tailnet>.ts.net`) + *API key* (`API_SERVER_KEY`). Derive Hermes `:8642` and backend `:8643` from the host. Stored in **Keychain**.
- **Sync to watch** via the existing `WatchConnectivityManager` (replacing the template Item-sync). Watch stores in Keychain with **`kSecAttrSynchronizable: false`** (keeps the key out of iCloud Keychain sync).
- **Mistral key never leaves the raspi** — only the backend reads it from `~/.hermes/.env` and only the backend talks to Mistral.

## 8. Code changes (implemented 2026-10-11)

| File | Change |
|---|---|
| `InstantHermesWatchApp/Services/AudioRecordingService.swift` | Rewritten: PCM float32 streaming via `AVAudioConverter` (sample rate conversion), `ChunkBatcher` actor with serial queue + retry, async submit/cancel |
| `InstantHermesWatchApp/Networking/STTClient.swift` | New: chunk/action POSTs to `:8643` with bearer auth |
| `InstantHermesWatchApp/Networking/HermesClient.swift` | New: `/v1/runs` POST with `Idempotency-Key`, `/health` check on `:8642` |
| `InstantHermesWatchApp/Utilities/AppConfig.swift` | New: Keychain config store (`kSecAttrSynchronizable: false`) |
| `InstantHermesWatchApp/Models/RecordingState.swift` | Extended: added `.transcribing` and `.submitting` states |
| `InstantHermesWatchApp/ViewModels/RecordingViewModel.swift` | Rewritten: full state machine (idle → recording → transcribing → submitting → idle), cancel-during-transcription support |
| `InstantHermesWatchApp/Views/ContentView.swift` | Updated: new states UI (status messages, transcribing/submitting indicators, not-configured warning) |
| `InstantHermesWatchApp/Services/WatchConnectivityManager.swift` | Rewritten: host/key sync from iPhone (replaces Item-sync) |
| `InstantHermes/Services/AppConfig.swift` | New: iOS Keychain config store |
| `InstantHermes/WatchConnectivityManager.swift` | Rewritten: host/key sync to watch (replaces Item-sync) |
| `InstantHermes/ContentView.swift` | Rewritten: server status + settings navigation (SwiftData removed) |
| `InstantHermes/SettingsView.swift` | New: settings UI (host, API key, connection test) |
| `InstantHermes/InstantHermesApp.swift` | Updated: removed SwiftData/ModelContainer |
| `Config/InstantHermes-Info.plist` | New: physical Info.plist with ATS exception for `*.ts.net` |
| `Config/InstantHermesWatchApp-Info.plist` | New: physical Info.plist with ATS exception for `*.ts.net` |
| `InstantHermes.xcodeproj/project.pbxproj` | Updated: `GENERATE_INFOPLIST_FILE=NO`, `INFOPLIST_FILE` set for both targets |
| `backend/server.py` | New: stdlib-only STT backend (PCM→WAV wrapping, Voxtral transcription) |
| `backend/instanthermes-stt.service` | New: systemd unit file |
| `backend/README.md` | New: install + test instructions |
| `InstantHermes/Item.swift` | Removed (SwiftData no longer used) |

## 9. Testing

- **Backend (curl):** health; chunked upload of a real ADTS file split by sequence; finalize → transcript; cancel → discard; gap → 409; no auth → 401; TTL sweep.
- **Test media:** `ffmpeg -i sample.wav -c:a aac -f adts sample.aac`.
- **End-to-end:** from a tailnet node (iPhone with Tailscale, or Mac with Tailscale for simulator runs).
- **Cancellation:** verify Hermes logs/sessions show no session created on cancel at each stage.

## 10. Risks — resolution status

1. ~~`AVAudioConverter` AAC output on watchOS~~ **RESOLVED:** AudioToolbox not available on watchOS. Switched to PCM float32 streaming (documented fallback). Backend wraps in WAV.
2. ~~Voxtral accepting `audio/aac`~~ **MOOT:** Now sending `audio/wav` (IEEE float32). Voxtral accepts WAV. ffmpeg fallback retained in backend for safety.
3. ~~ATS mechanics with `GENERATE_INFOPLIST_FILE=YES`~~ **RESOLVED:** Switched to physical Info.plist files in `Config/` directory with `NSAppTransportSecurity` → `NSExceptionDomains` → `ts.net` exception. `GENERATE_INFOPLIST_FILE=NO`.
4. Gateway bind ordering vs tailscaled (systemd `After=/Requires=`; Hermes API server retry behavior). **OPEN:** Verify on actual raspi setup.

## 11. Open items

- **§5.1 RESOLVED:** finalize-on-Submit implemented (default). No wasted Voxtral calls; Submit takes ~1–5 s. Cancel during transcription discards the transcript.
- **Backend location RESOLVED:** `backend/` in this repo.
- iPhone settings UI: **implemented** (basic version in `SettingsView.swift`).
- **Verify on actual raspi:** end-to-end test with real Hermes gateway + Voxtral.
- **Verify on actual watch:** PCM streaming + sample rate conversion quality.
