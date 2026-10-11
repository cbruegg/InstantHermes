# PLAN.md — Watch → STT Backend (Voxtral) → Hermes over Tailscale

Status: **implemented** (2026-10-11). **Revised later the same day: fire-and-forget** — the backend now transcribes *and* forwards to Hermes itself; the watch never waits for transcription (see §2, §3.1, §5.1, §8.1).

This is the revised plan for replacing the dummy `localhost:8080` audio endpoint with the real pipeline: the Apple Watch streams recorded audio to a tiny STT backend on the Raspberry Pi, which transcribes via Mistral Voxtral and submits the transcript to the Hermes API server's message endpoint itself. Cancellation is end-to-end: cancelling means the recording is discarded before the backend accepts it.

## 0. Locked-in decisions

| # | Decision | Consequence |
|---|----------|-------------|
| 1 | Streaming to the STT endpoint is fine | Audio leaves the watch during recording. The cancellation gate is **only** the backend's message-endpoint POST (`/v1/runs`) — never triggered on Cancel. |
| 2 | No `tailscale serve` | Plain HTTP over the tailnet to the MagicDNS hostname; app needs a scoped ATS exception. (Tailscale cannot read the data either way — see §1.) |
| 3 | No PR branch; tiny systemd backend using **Mistral Voxtral**, key from **Hermes config** | New `instanthermes-stt` service on the raspi (port 8643). Reads `MISTRAL_API_KEY` from `~/.hermes/.env`. |
| 4 | Watch → backend only | Watch holds the `API_SERVER_KEY` (synced from iPhone) and talks **only** to `:8643` (STT backend); the backend talks to Hermes `:8642`. |
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
    → AVAudioConverter (PCM → 16 kHz mono float32)
    → batch ~0.5 s → chunk POSTs (retry on failure)
        |
        |  chunk uploads + submit/cancel actions
        v
instanthermes-stt  (systemd, raspi, :8643)
  reassembles PCM → wraps in WAV → Mistral Voxtral
  (MISTRAL_API_KEY from ~/.hermes/.env)
        |
        |  submit → 202 immediately (fire and forget);
        |  transcription + Hermes submission run in a background thread
        v
Hermes API server  (hermes gateway, raspi, :8642)
  POST /v1/runs {"input": "<transcript>"} → 202, fire-and-forget

Both raspi services bind the Tailscale IP only and require the
same bearer key (API_SERVER_KEY).
```

**The cancellation invariant:** the only request that turns audio into "a complete message to Hermes" is the backend's `POST /v1/runs` with the transcript. It fires **only** after the watch submits (manual tap or 3 s-silence auto-submit) **and** the backend accepted the audio (202). Cancel at any earlier point simply discards the spooled audio — that request never happens.

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
  → submit: 202 {"status": "accepted"}                          (immediately — fire and forget;
            optional JSON body {"delivery_target": "matrix"}    the backend transcribes (Voxtral),
            → the Hermes response is delivered to that         POSTs /v1/runs in a background
            platform's home channel via `hermes send`          thread, and delivers the response)
            404 {"error": "recording_not_found"}
            409 {"error": "audio_incomplete", "missing": [..]}  (sequence gap)
            503 {"error": "stt_unavailable", ...}               (no Mistral key — fast fail)
  → cancel: 200 {"ok": true}                                    (discard buffered chunks)

GET /health → 200 {"ok": true, "mistral_configured": true|false}
```

### 3.2 Behavior

- **Spool:** in-memory `{recording_id: {seq: bytes}}` plus last-activity timestamp; 25 MB cap per recording.
- **Finalize (submit):** verify sequences are contiguous `0..N`, then respond `202` immediately and hand the concatenated audio to a background thread that wraps it (PCM→WAV), calls Voxtral, and POSTs the transcript to Hermes `/v1/runs`. The spooled entry is removed when the submit is accepted; the recording ID doubles as the Hermes `Idempotency-Key`, so retries never duplicate a run.
- **Hermes forwarding:** `POST http://$API_SERVER_HOST:$API_SERVER_PORT/v1/runs` (default port `8642`; host from `~/.hermes/.env`, falling back to the machine's own Tailscale IP) with `Authorization: Bearer $API_SERVER_KEY`. Empty transcripts are logged and dropped (Hermes 400s on empty input). The voice context `"[Voice message from Apple Watch via InstantHermes]\n\nUser said: <transcript>"` is prepended server-side. If the submit carried a `delivery_target`, the backend polls `GET /v1/runs/{run_id}` until the run completes and delivers the final `output` text to that platform's home channel via `hermes send --to <platform>` — the agent has no callable `send_message` tool in hermes-agent, so delivery must happen backend-side.
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

**Revised during implementation (2026-10-11):** AAC encoding via `AVAudioConverter` requires `AudioToolbox`, which is **not available on watchOS**. The implemented approach streams **16 kHz mono float32 PCM** — the documented fallback from the original plan. Bandwidth is ~64 KB/s over the tailnet, which is trivial. The backend wraps the PCM in a WAV container (IEEE float32) before sending to Voxtral.

Pipeline replacing the original raw-float32 chunk sender:

1. `AVAudioEngine` tap (unchanged — waveform levels + silence detection keep working off it).
2. `AVAudioConverter`: PCM float32 at hardware rate → **PCM float32, 16 kHz, mono** (sample rate + channel conversion; no codec encoding needed).
3. **Batch** samples; flush as one chunk POST every ~1 s (~64 KB). That is ~1 request/sec over the tailnet — large enough that per-request RTT cannot make the serial upload queue fall behind (with ~4 KB chunks the backlog drained at submit, stalling "Sending…").
4. Each chunk POST carries `X-Recording-ID` + incrementing `X-Chunk-Sequence` + `X-Audio-Format: pcm-float32`. **Retry** failed POSTs 3× (0.5/1/2 s backoff); if still failing → stop recording with an error (sequences stay contiguous by construction; the backend would 409 a gap anyway). Chunk uploads go through a small serial queue so finalize/cancel can wait for in-flight chunks to settle.

**Backend WAV wrapping:** the stdlib-only Python backend uses `struct` to write a minimal WAV header (IEEE float32, 16 kHz, mono, 46-byte header) around the concatenated PCM chunks, then sends the `.wav` to Voxtral.

**Future AAC upgrade path:** if AAC becomes desirable, the `AudioConverter` C API via the `AudioUnit` framework is available on watchOS. The backend already accepts `aac-adts` format as an alternative to `pcm-float32`.

### 5.1 App state machine

```text
idle
  └─ start ─→ recording ── Submit / 3 s silence ──→ submitting ── 202 ──→ idle
                  │
                  └─ Cancel ──→ idle

recording  : streaming chunk POSTs; Cancel + Submit available
submitting : submit POST in flight; no Cancel — once the backend accepts (202)
             it owns the recording: transcription + Hermes submission happen server-side
```
- **Empty transcript** (silence/hallucination): the backend logs it and does not POST to `/v1/runs` (it 400s on empty input).
- **Transcription happens server-side after Submit** (~1–5 s for a short clip), so the watch returns to idle immediately — truly fire and forget. A cancelled recording never costs a Voxtral call (Cancel discards the spool before submit).
- Timeouts: submit POST 15 s (returns 202 in well under 1 s), Voxtral 60 s and `/v1/runs` 15 s server-side, chunks 10 s; the backend polls the run for up to 300 s before giving up on response delivery.

### 5.2 Message submission & response delivery (backend → Hermes → channel)

The watch never talks to Hermes. On submit, the backend:

1. POSTs the transcript to Hermes itself, with a fixed voice context prepended:
   `"[Voice message from Apple Watch via InstantHermes]\n\nUser said: <transcript>"`.
   (The agent's `send_message` tool does **not** exist as a model tool in
   hermes-agent — it is intentionally not agent-callable — so delivery cannot
   rely on the agent; the backend does it.)
2. If the watch sent a `delivery_target` (JSON body on the submit action),
   polls `GET /v1/runs/{run_id}` (the `/events` endpoint is live-only) until
   the run completes, reads the final assistant text from `output`, and
   delivers it to that platform's home channel via `hermes send --to <platform>`
   (non-interactive; uses Hermes's own client, so E2EE works; the gateway must
   be running for the persistent session to be reused).

```bash
curl -X POST http://$API_SERVER_HOST:8642/v1/runs \
  -H "Authorization: Bearer $API_SERVER_KEY" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: <recording-uuid>" \
  -d '{"input": "<transcript>"}'
# → 202 {"run_id":"run_...","status":"started"} → fire-and-forget

curl http://$API_SERVER_HOST:8642/v1/runs/<run_id> -H "Authorization: Bearer $API_SERVER_KEY"
# → {..., "status": "completed", "output": "<final assistant text>", ...}

hermes send --to matrix "<final assistant text>"   # deliver to the matrix home channel
```

The backend targets `http://$API_SERVER_HOST:$API_SERVER_PORT/v1/runs` (default port `8642`, host from `~/.hermes/.env`, falling back to its own Tailscale IP).

Omit `session_id` → fresh session per message (matches the product vision). `GET /health` (no auth) serves as the connectivity check.

## 6. End-to-end cancellation — analysis

| Cancel timing | What happens | Hermes processes anything? |
|---|---|---|
| During recording | Stop tap, drop batch, POST `cancel` → backend discards spooled chunks. | **No** — `/v1/runs` never called |
| Watch dies mid-recording | Backend sweeper deletes the partial spool after TTL. | **No** |
| During submitting (submit POST in flight) | No cancel UI — the POST completes in well under a second; 202 is the point of no return. | Accepted by explicit user action |
| After 202 (backend transcribing / forwarding) | Too late to cancel from the watch — the backend owns the recording. (A future "cancel a submitted message" can use `POST /v1/runs/{id}/stop`.) | Processing has begun |
| Future "cancel a submitted message" | Keep the `run_id` → `POST /v1/runs/{id}/stop` (interrupts at the next safe point, settles `cancelled`). Needed for interactive mode later. | Cooperative stop |

The invariant holds: **anything submitted to the STT backend is never "processed as a complete message to Hermes" — only the backend's gated `/v1/runs` POST is, and Cancel at any point before the submit is accepted means it never fires.**

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

### 8.1 Revision (2026-10-11, later same day): fire-and-forget backend

| File | Change |
|---|---|
| `backend/server.py` | Submit returns `202` immediately; a background thread transcribes (Voxtral) and POSTs the transcript to Hermes `/v1/runs` (`Idempotency-Key` = recording ID); optional `delivery_instruction` JSON body on submit; Hermes target from `API_SERVER_HOST`/`API_SERVER_PORT` |
| `backend/instanthermes-stt.service` | `python3 -u` so the background worker's logs are actually emitted |
| `InstantHermesWatchApp/Networking/STTClient.swift` | `submit` is fire-and-forget (expects 202), sends optional `delivery_instruction` body |
| `InstantHermesWatchApp/Services/AudioRecordingService.swift` | `submit` returns `Void` |
| `InstantHermesWatchApp/ViewModels/RecordingViewModel.swift` | State machine reduced to idle → recording → submitting → idle; Hermes submission moved server-side; cancel also stops the audio engine |
| `InstantHermesWatchApp/Models/RecordingState.swift` | Removed `.transcribing` |
| `InstantHermesWatchApp/Networking/HermesClient.swift` | Removed — the watch no longer talks to Hermes |
| `InstantHermesWatchApp/Views/ContentView.swift` | Auto-start also when the config arrives after launch |
| `InstantHermesWatchApp/Localizable.xcstrings` | Removed unused "Transcribing…" / "Didn't catch that" |

### 8.2 Revision (2026-10-11, later still): response delivery + streaming fix

The agent-side delivery instruction (`MUST use the send_message tool…`) was **unsatisfiable**: in hermes-agent, `send_message` is intentionally not an agent-callable model tool, and `api_server` runs have no delivery obligation bound to a channel. The backend now delivers the response itself. Also, the chunk batcher emitted ~4 KB chunks every ~64 ms, which the serial upload queue could not keep up with over the watch→Pi path — the backlog drained at submit, stalling "Sending…".

| File | Change |
|---|---|
| `backend/server.py` | Submit body carries `delivery_target`; the backend prepends the voice context, polls `GET /v1/runs/{id}` until the run completes, and delivers the final `output` via `hermes send --to <platform>` (serialized; needs the gateway running for the persistent E2EE session) |
| `InstantHermesWatchApp/Networking/STTClient.swift` | Submit body is `{"delivery_target": ...}` |
| `InstantHermesWatchApp/Services/AudioRecordingService.swift` | `submit` takes `deliveryTarget`; chunk batching raised to ~1 s / 64 KB so the serial upload queue keeps up with recording (submit no longer stalls while a backlog drains) |
| `InstantHermesWatchApp/ViewModels/RecordingViewModel.swift` | Passes `deliveryTarget` |
| `InstantHermesWatchApp/Utilities/AppConfig.swift` | Removed `deliveryInstruction` (the voice context now lives in the backend) |
| `InstantHermes/Services/AppConfig.swift` | Removed dead `deliveryInstruction` |
| `InstantHermes/SettingsView.swift` | Footer text no longer describes the send_message mechanism |

## 11. Open items

- **§5.1 RESOLVED:** fire-and-forget — the backend transcribes and forwards after accepting the submit (202). The watch never waits for transcription; Cancel discards the spool before submit.
- **Backend location RESOLVED:** `backend/` in this repo.
- iPhone settings UI: **implemented** (basic version in `SettingsView.swift`).
- **Verify on actual raspi:** end-to-end test with real Hermes gateway + Voxtral.
- **Verify on actual watch:** PCM streaming + sample rate conversion quality.
