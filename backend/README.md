# InstantHermes STT Backend

A stdlib-only Python service that receives streamed audio chunks from the
Apple Watch, reassembles them, transcribes via Mistral Voxtral, and submits
the transcript to the Hermes API server (`/v1/runs`) itself. Fire and
forget: the submit action is accepted with `202` immediately; transcription
and the Hermes submission happen in a background thread, so the watch never
waits for transcription. If the watch sent a delivery target, the backend
also fetches the run's final response and delivers it to that platform's
home channel (e.g. Matrix) via `hermes send`.

## Architecture

```
Apple Watch
  → PCM float32 chunks, 16 kHz mono (POST /audio with X-Chunk-Sequence)
    → instanthermes-stt (:8643, this service)
      → wraps PCM in WAV container
        → Mistral Voxtral (api.mistral.ai)
          → transcript forwarded to Hermes /v1/runs (:8642)
            → 202 {"run_id": ...} — the watch already moved on (fire and forget)
            → final response delivered to the delivery target's home channel
              (e.g. matrix, via `hermes send`) when a delivery target is set
```

Note: AAC encoding via AVAudioConverter requires AudioToolbox, which is not
available on watchOS. PCM streaming is the documented fallback (PLAN.md §5):
~64 KB/s over the tailnet is trivial bandwidth.

## Hermes forwarding & response delivery

On `submit`, the backend transcribes the audio and POSTs the transcript to
the Hermes API server itself, with a fixed voice context prepended:

- URL: `http://$API_SERVER_HOST:$API_SERVER_PORT/v1/runs` (default port `8642`;
  host read from `~/.hermes/.env`, falling back to the machine's own Tailscale IP)
- Auth: `Authorization: Bearer $API_SERVER_KEY` (the same key the watch uses)
- `Idempotency-Key: <recording-id>` — retries never create duplicate runs
- Input: `"[Voice message from Apple Watch via InstantHermes]\n\nUser said: <transcript>"`
- Empty transcripts are logged and dropped (Hermes 400s on empty input)
- If the submit carried a `delivery_target` (e.g. `"matrix"`), the backend
  polls `GET /v1/runs/{run_id}` until the run completes, reads the final
  assistant text from `output`, and delivers it to that platform's home
  channel via `hermes send --to <platform>` (non-interactive; uses Hermes's
  own client so E2EE works; keep the hermes gateway running so the persistent
  session is reused). Note: the agent has no callable `send_message` tool in
  hermes-agent — delivery must happen backend-side.
- Background results are logged to stdout — watch them with
  `journalctl --user -u instanthermes-stt -f` (the unit runs `python3 -u`)

## Prerequisites

On the Raspberry Pi:

1. **Tailscale** installed and connected (`tailscale up`)
2. **Hermes** installed with `~/.hermes/.env` containing:
   ```bash
   API_SERVER_ENABLED=true
   API_SERVER_KEY=<openssl rand -hex 32>
   API_SERVER_HOST=<tailscale-ip>    # from `tailscale ip -4`
   MISTRAL_API_KEY=<your-mistral-key>
   ```
3. **ffmpeg** installed (fallback for ADTS→WAV conversion)
4. **Python 3** (stdlib only, no pip dependencies)

## Installation

### User systemd service (recommended)

Run these commands from the repository's `backend/` directory as the user
that runs Hermes. Installing the user unit needs no root privileges; enabling
lingering may require administrator approval.

```bash
# Place the files in your home directory
mkdir -p ~/InstantHermes-backend
cp server.py ~/InstantHermes-backend/

# Install the user systemd unit
mkdir -p ~/.config/systemd/user
cp instanthermes-stt.service ~/.config/systemd/user/

# Enable lingering (so the service runs even when you're not logged in)
sudo loginctl enable-linger $USER

# Enable and start
systemctl --user daemon-reload
systemctl --user enable --now instanthermes-stt

# Verify
systemctl --user status instanthermes-stt
curl http://$(tailscale ip -4):8643/health
```

### System systemd service (alternative — requires sudo)

Follow the [system-service installation instructions in the main README](../README.md#installation-system-systemd-service--requires-sudo),
running those commands from the repository root. They provide a separate unit
with an explicit Hermes user/home, `/opt/instanthermes-stt/server.py` as the
executable path, and `multi-user.target` for boot startup. Do **not** install
the supplied user unit unchanged under `/etc/systemd/system/`: `%h` does not
resolve to `User=`'s home in a system unit.

For a system installation, replace `systemctl --user` with `sudo systemctl`
and `journalctl --user` with `sudo journalctl` throughout this README. Disable
any existing user-service instance before starting the system service.

## Testing

From any tailnet node:

```bash
# Health check (no auth)
curl http://raspi5.<tailnet>.ts.net:8643/health
# → {"ok": true, "mistral_configured": true}

# Create a test WAV file and extract raw PCM float32
ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -ar 16000 -ac 1 -f f32le /tmp/test.pcm

# Upload chunks (split the file)
KEY="your-api-server-key"
HOST="raspi5.<tailnet>.ts.net"
RID="test-$(date +%s)"
split -b 4096 /tmp/test.pcm /tmp/chunk_
seq=0
for f in /tmp/chunk_*; do
  curl -X POST "http://$HOST:8643/audio" \
    -H "Authorization: Bearer $KEY" \
    -H "X-Recording-ID: $RID" \
    -H "X-Chunk-Sequence: $seq" \
    -H "X-Audio-Format: pcm-float32" \
    -H "X-Sample-Rate: 16000" \
    --data-binary @"$f"
  seq=$((seq + 1))
done

# Submit — accepted immediately; transcription, Hermes forwarding, and response
# delivery happen in the background
curl -X POST "http://$HOST:8643/audio" \
  -H "Authorization: Bearer $KEY" \
  -H "X-Recording-ID: $RID" \
  -H "X-Action: submit" \
  -H "Content-Type: application/json" \
  -d '{"delivery_target": "matrix"}'
# → 202 {"status": "accepted"}
# Watch the service logs for the background result:
#   journalctl --user -u instanthermes-stt -f
```

## API Contract

All requests (except `GET /health`) carry `Authorization: Bearer <API_SERVER_KEY>`.

| Method | Path | Headers | Body | Response |
|--------|------|---------|------|----------|
| GET | `/health` | — | — | `200 {"ok": true, "mistral_configured": bool}` |
| POST | `/audio` | `X-Recording-ID`, `X-Chunk-Sequence`, `X-Audio-Format: pcm-float32`, `X-Sample-Rate` | raw PCM float32 bytes | `200 {"ok": true}` |
| POST | `/audio` | `X-Recording-ID`, `X-Action: submit` | optional JSON `{"delivery_target": "matrix"}` | `202 {"status": "accepted"}` (immediately; processed in background) or `404`/`409`/`503` |
| POST | `/audio` | `X-Recording-ID`, `X-Action: cancel` | — | `200 {"ok": true}` — discards spooled chunks OR signals the background worker to abort |
| POST | `/audio` | `X-Recording-ID`, `X-Action: keepalive` | — | `200 {"ok": true}` — updates client-liveness timestamp |

Supported `X-Audio-Format` values: `pcm-float32` (default), `aac-adts`.

## Cancellation & Client Liveness

The backend enforces a strict invariant: **`POST /v1/runs` (the only request that
turns audio into a Hermes message) fires only if the recording was not cancelled
AND the client is still connected.**

### Cancel

The `cancel` action works at any point before the Hermes POST:

- **Before submit:** discards spooled chunks. Transcription never starts.
- **After submit (202):** signals the background worker thread to abort via a
  per-recording `threading.Event`. The worker checks the event at three gates:
  1. Before transcription (saves a Voxtral API call)
  2. After transcription (transcript discarded)
  3. Before the Hermes POST (the critical gate)

### Keepalive

After submit (202), the watch sends `X-Action: keepalive` every 5 seconds for
90 seconds. The backend tracks the last keepalive timestamp per recording and
checks freshness before the Hermes POST:

- `KEEPALIVE_TIMEOUT = 15.0` seconds — if no keepalive arrives within 15 s,
  the client is considered gone (app killed, out of range, network drop).
- Grace period: the first 15 s after submit are always considered alive.

If keepalives stop before the Hermes POST, the backend aborts — `/v1/runs`
is never called.

### Sweeper

The background sweeper thread also cleans up stale processing entries (worker
thread died without unregistering, e.g. OOM kill). A processing entry is stale
after ~7 minutes (transcription + Hermes submission + response polling + margin).

## Privacy and security

The Tailscale connection protects app-to-backend traffic when correctly routed;
it does not keep all processing inside the tailnet. On submit, the backend sends
the recording to **Mistral's cloud API over HTTPS** for transcription. Mistral's
data-handling and retention terms apply. The transcript then goes to Hermes,
whose configured model providers and tools may send data to other services.
Optional response delivery sends the final response through the chosen platform.

Logs can contain agent output and upstream error details, and `hermes send`
receives response text as a local process argument. Limit access to the server
and its logs. Audio conversion fallback can create temporary audio files.

- Binds **only** to the machine's Tailscale IPv4 (never LAN)
- Requires bearer auth matching `API_SERVER_KEY` (same key as Hermes)
- 25 MB per-recording cap
- 10-minute idle TTL (sweeper deletes abandoned recordings)
- ~7-minute stale TTL for processing entries (sweeper cleans up dead workers)
- Mistral API key is read on the server and sent to Mistral over HTTPS for authentication; it is not distributed to the apps
- Cancel and keepalive actions are authenticated (same bearer token)
