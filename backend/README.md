# InstantHermes STT Backend

A stdlib-only Python service that receives streamed audio chunks from the
Apple Watch, reassembles them, and transcribes via Mistral Voxtral. The
transcript is returned to the watch, which then submits it to the Hermes API
server (`/v1/runs`).

## Architecture

```
Apple Watch
  → PCM float32 chunks, 16 kHz mono (POST /audio with X-Chunk-Sequence)
    → instanthermes-stt (:8643, this service)
      → wraps PCM in WAV container
        → Mistral Voxtral (api.mistral.ai)
          → transcript text returned to watch
            → watch POSTs to Hermes /v1/runs (:8642)
```

Note: AAC encoding via AVAudioConverter requires AudioToolbox, which is not
available on watchOS. PCM streaming is the documented fallback (PLAN.md §5):
~32 KB/s over the tailnet is trivial bandwidth.

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

```bash
# Copy the server
sudo mkdir -p /opt/instanthermes-stt
sudo cp server.py /opt/instanthermes-stt/

# Install the systemd unit
sudo cp instanthermes-stt.service /etc/systemd/system/
# Edit the unit to set User=<hermes-user> if Hermes runs as a non-root user:
#   sudo systemctl edit instanthermes-stt

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable --now instanthermes-stt

# Verify
sudo systemctl status instanthermes-stt
```

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

# Submit for transcription
curl -X POST "http://$HOST:8643/audio" \
  -H "Authorization: Bearer $KEY" \
  -H "X-Recording-ID: $RID" \
  -H "X-Action: submit"
# → {"text": "..."}
```

## API Contract

All requests (except `GET /health`) carry `Authorization: Bearer <API_SERVER_KEY>`.

| Method | Path | Headers | Body | Response |
|--------|------|---------|------|----------|
| GET | `/health` | — | — | `200 {"ok": true, "mistral_configured": bool}` |
| POST | `/audio` | `X-Recording-ID`, `X-Chunk-Sequence`, `X-Audio-Format: pcm-float32`, `X-Sample-Rate` | raw PCM float32 bytes | `200 {"ok": true}` |
| POST | `/audio` | `X-Recording-ID`, `X-Action: submit` | — | `200 {"text": "..."}` or `409`/`503` |
| POST | `/audio` | `X-Recording-ID`, `X-Action: cancel` | — | `200 {"ok": true}` |

Supported `X-Audio-Format` values: `pcm-float32` (default), `aac-adts`.

## Security

- Binds **only** to the machine's Tailscale IPv4 (never LAN)
- Requires bearer auth matching `API_SERVER_KEY` (same key as Hermes)
- 25 MB per-recording cap
- 10-minute idle TTL (sweeper deletes abandoned recordings)
- Mistral API key never leaves the raspi
