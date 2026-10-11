#!/usr/bin/env python3
"""InstantHermes STT backend: streamed audio chunks -> Mistral Voxtral -> Hermes.
Fire and forget: a submit is accepted with 202 as soon as the audio is validated;
transcription (Voxtral) and the Hermes /v1/runs submission then happen in a
background thread, so the watch never waits for transcription. If the submit
carries a delivery target, the backend also fetches the run's final response
(GET /v1/runs/{id}) and delivers it to that platform's home channel via the
`hermes send` CLI — the agent has no callable send_message tool.

Stdlib only. Binds the machine's Tailscale IP. Bearer-auth with API_SERVER_KEY.

Accepts two audio formats:
  - pcm-float32: raw 16 kHz mono float32 PCM (wrapped in WAV for Voxtral)
  - aac-adts:    raw ADTS-framed AAC (sent directly to Voxtral, ffmpeg fallback)

API contract:
  POST /audio  — chunk upload (X-Recording-ID, X-Chunk-Sequence, X-Audio-Format headers)
  POST /audio  — action (X-Action: submit|cancel header present)
    submit: 202 {"status": "accepted"} immediately; optional JSON body
            {"delivery_target": "matrix"} tells the backend to deliver the
            Hermes response to that platform's home channel.
  GET  /health — health check
"""

import io
import json
import os
import shutil
import struct
import subprocess
import threading
import time
import urllib.request
import urllib.error
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STT_PORT = int(os.environ.get("STT_PORT", "8643"))
VOXTRAL_URL = "https://api.mistral.ai/v1/audio/transcriptions"
VOXTRAL_MODEL = "voxtral-mini-latest"
MAX_BYTES = 25 * 1024 * 1024  # 25 MB cap per recording
TTL_SECONDS = 600  # 10 minutes idle timeout
SAMPLE_RATE = 16000  # expected sample rate for PCM chunks


def hermes_env():
    """Read environment, falling back to ~/.hermes/.env for missing keys."""
    env = dict(os.environ)
    hermes_home = os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes"))
    path = os.path.join(hermes_home, ".env")
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, _, v = line.partition("=")
                    env.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    return env


_env = hermes_env()
API_KEY = _env.get("API_SERVER_KEY", "")
MISTRAL_KEY = _env.get("MISTRAL_API_KEY", "")

_bound_ip = None  # set in main() once the Tailscale IP is known


def hermes_base_url():
    """Base URL of the Hermes API server (same host; Tailscale IP, port 8642)."""
    host = _env.get("API_SERVER_HOST") or _bound_ip or "127.0.0.1"
    port = _env.get("API_SERVER_PORT", "8642")
    return f"http://{host}:{port}"


# Fixed context prepended to every transcript before forwarding to Hermes
VOICE_CONTEXT = "[Voice message from Apple Watch via InstantHermes]"

# Run-result polling: the /events endpoint is live-only (no replay), so the
# final assistant text is retrieved by polling GET /v1/runs/{run_id}.
RUN_POLL_INTERVAL = 2.0
RUN_POLL_TIMEOUT = 300.0
RUN_TERMINAL_STATES = {"completed", "failed", "cancelled", "canceled", "error", "interrupted", "stopped"}

# Serializes response delivery — concurrent `hermes send` calls would race on the E2EE session
delivery_lock = threading.Lock()

# In-memory spool: recording_id -> {"chunks": {seq: bytes}, "updated": ts, "format": str}
recordings = {}
lock = threading.Lock()


def tailscale_ip():
    """Discover this machine's Tailscale IPv4 address."""
    result = subprocess.run(
        ["tailscale", "ip", "-4"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        raise RuntimeError(f"tailscale ip failed: {result.stderr.strip()}")
    lines = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
    if not lines:
        raise RuntimeError("tailscale ip returned no addresses")
    return lines[0]


def wrap_pcm_float32_in_wav(pcm_bytes: bytes, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Wrap raw float32 PCM bytes in a WAV container (IEEE float format).

    WAV header for IEEE float32 mono:
      - AudioFormat = 3 (IEEE float)
      - BitsPerSample = 32
      - fmt chunk size = 18 (includes cbSize = 0)
    """
    num_channels = 1
    bits_per_sample = 32
    byte_rate = sample_rate * num_channels * bits_per_sample // 8
    block_align = num_channels * bits_per_sample // 8
    data_size = len(pcm_bytes)

    # Build WAV header
    # For IEEE float: fmt chunk = 18 bytes, total header = 46 bytes
    # RIFF chunk size = 4 (WAVE) + 8 (fmt hdr) + 18 (fmt data) + 8 (data hdr) + data_size
    header = b"RIFF"
    header += struct.pack("<I", 38 + data_size)  # chunk size
    header += b"WAVE"
    header += b"fmt "
    header += struct.pack("<I", 18)  # fmt chunk size (18 for float)
    header += struct.pack("<H", 3)   # audio format: IEEE float
    header += struct.pack("<H", num_channels)
    header += struct.pack("<I", sample_rate)
    header += struct.pack("<I", byte_rate)
    header += struct.pack("<H", block_align)
    header += struct.pack("<H", bits_per_sample)
    header += struct.pack("<H", 0)   # cbSize = 0
    header += b"data"
    header += struct.pack("<I", data_size)

    return header + pcm_bytes


def voxtral_transcribe(audio_bytes: bytes, content_type: str, filename: str) -> str:
    """Call Mistral Voxtral to transcribe audio.

    Args:
        audio_bytes: The audio data (WAV or AAC).
        content_type: MIME type (audio/wav or audio/aac).
        filename: Filename for the multipart upload.

    Falls back to converting via ffmpeg if Voxtral rejects the format.
    """
    if not MISTRAL_KEY:
        raise RuntimeError("MISTRAL_API_KEY not configured")

    boundary = uuid.uuid4().hex

    # Try the provided format first
    body = _build_multipart(boundary, filename, content_type, audio_bytes)
    text = _post_voxtral(body, boundary)
    if text is not None:
        return text

    # Fallback: convert to WAV via ffmpeg, retry
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=os.path.splitext(filename)[1], delete=False) as fin:
        fin.write(audio_bytes)
        input_path = fin.name
    wav_path = input_path + ".wav"
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", wav_path],
            capture_output=True, timeout=30, check=True
        )
        with open(wav_path, "rb") as f:
            wav_bytes = f.read()
        body = _build_multipart(boundary, "recording.wav", "audio/wav", wav_bytes)
        text = _post_voxtral(body, boundary)
        if text is None:
            raise RuntimeError("Voxtral rejected both original and WAV formats")
        return text
    finally:
        for p in (input_path, wav_path):
            try:
                os.unlink(p)
            except OSError:
                pass


def _build_multipart(boundary: str, filename: str, content_type: str, data: bytes) -> bytes:
    """Build a multipart/form-data body with file and model fields."""
    parts = []
    parts.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n"
        f"\r\n"
    .encode())
    parts.append(data)
    parts.append(b"\r\n")
    parts.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="model"\r\n'
        f"\r\n"
        f"{VOXTRAL_MODEL}\r\n"
    .encode())
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts)


def _post_voxtral(body: bytes, boundary: str):
    """POST to Voxtral. Returns transcript text or None on failure."""
    req = urllib.request.Request(
        VOXTRAL_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {MISTRAL_KEY}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            result = json.loads(resp.read().decode())
            return result.get("text", "")
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"Voxtral HTTP error {e.code}: {error_body[:500]}")
        return None
    except Exception as e:
        print(f"Voxtral request failed: {e}")
        return None


def submit_to_hermes(recording_id: str, text: str):
    """POST the transcript to the Hermes API as a fire-and-forget run.

    Returns the run ID (used to fetch the response later), or None on failure.
    The recording ID doubles as the idempotency key, so a retry never
    creates a duplicate run.
    """
    text = VOICE_CONTEXT + "\n\nUser said: " + text

    body = json.dumps({"input": text}).encode()
    req = urllib.request.Request(
        hermes_base_url() + "/v1/runs",
        data=body,
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
            "Idempotency-Key": recording_id,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode())
            run_id = result.get("run_id", "")
            print(f"Hermes accepted run {run_id} (recording {recording_id})")
            return run_id or None
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"Hermes rejected recording {recording_id}: HTTP {e.code}: {error_body[:500]}")
        return None
    except Exception as e:
        print(f"Hermes request failed for recording {recording_id}: {e}")
        return None


def wait_for_run_output(run_id: str):
    """Poll the Hermes API until the run reaches a terminal state.

    The /events endpoint is live-only (no replay), so the final assistant
    text is retrieved by polling GET /v1/runs/{run_id} and reading `output`.

    Returns the final assistant text, or None if the run failed or timed out.
    """
    url = hermes_base_url() + f"/v1/runs/{run_id}"
    deadline = time.time() + RUN_POLL_TIMEOUT
    while time.time() < deadline:
        req = urllib.request.Request(
            url, headers={"Authorization": f"Bearer {API_KEY}"}, method="GET"
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                run = json.loads(resp.read().decode())
        except Exception as e:
            print(f"Run {run_id}: status poll failed: {e}")
            time.sleep(RUN_POLL_INTERVAL)
            continue

        status = run.get("status", "")
        if run.get("completed") or status in RUN_TERMINAL_STATES:
            output = (run.get("output") or "").strip()
            if run.get("completed") and output:
                return output
            print(f"Run {run_id}: ended (status={status}, completed={run.get('completed')}), output={output!r}")
            return None
        time.sleep(RUN_POLL_INTERVAL)

    print(f"Run {run_id}: timed out after {int(RUN_POLL_TIMEOUT)}s waiting for completion")
    return None


def find_hermes_cli():
    """Locate the `hermes` CLI (the systemd user service PATH may not include ~/.local/bin)."""
    path = shutil.which("hermes")
    if path:
        return path
    for candidate in ("~/.local/bin/hermes", "~/.hermes/bin/hermes"):
        expanded = os.path.expanduser(candidate)
        if os.path.isfile(expanded) and os.access(expanded, os.X_OK):
            return expanded
    return None


def deliver_response(platform: str, text: str):
    """Deliver the response text to the platform's home channel.

    Uses the `hermes send` CLI so Hermes's own client handles login and
    E2EE (the matrix home room is encrypted). Requires the hermes gateway
    to be running so the persistent session is reused. Serialized with a
    lock — concurrent sends would race on the E2EE session.
    """
    cli = find_hermes_cli()
    if not cli:
        print(f"delivery to {platform}: hermes CLI not found")
        return
    env = dict(os.environ)
    env["PATH"] = os.path.expanduser("~/.local/bin") + os.pathsep + env.get("PATH", "/usr/local/bin:/usr/bin:/bin")
    with delivery_lock:
        try:
            result = subprocess.run(
                [cli, "send", "--to", platform, text],
                capture_output=True, text=True, timeout=90, env=env,
            )
            if result.returncode == 0:
                print(f"Delivered response to {platform} home channel ({len(text)} chars)")
            else:
                print(f"Delivery to {platform} failed (exit {result.returncode}): {result.stderr.strip()[:300]}")
        except Exception as e:
            print(f"Delivery to {platform} failed: {e}")


def process_recording(recording_id: str, raw_audio: bytes, audio_format: str, delivery_target: str):
    """Background worker: transcribe, forward to Hermes, deliver the response.

    Runs in a daemon thread after the submit request was accepted (202).
    All errors are logged — the watch has already moved on.
    """
    try:
        # Prepare audio for Voxtral based on format
        if audio_format == "pcm-float32":
            # Wrap raw float32 PCM in a WAV container
            audio_bytes = wrap_pcm_float32_in_wav(raw_audio, SAMPLE_RATE)
            content_type = "audio/wav"
            filename = "recording.wav"
        else:  # aac-adts
            audio_bytes = raw_audio
            content_type = "audio/aac"
            filename = "recording.aac"

        text = voxtral_transcribe(audio_bytes, content_type, filename).strip()
        if not text:
            print(f"Recording {recording_id}: empty transcript, not forwarding to Hermes")
            return

        run_id = submit_to_hermes(recording_id, text)
        if not run_id:
            return

        if not delivery_target:
            print(f"Recording {recording_id}: no delivery target — response stays in the Hermes run")
            return

        output = wait_for_run_output(run_id)
        if output:
            deliver_response(delivery_target, output)
    except Exception as e:
        print(f"Recording {recording_id}: processing failed: {e}")


class Handler(BaseHTTPRequestHandler):
    """HTTP handler for the STT backend."""

    def log_message(self, format, *args):
        pass  # quiet logging

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self) -> bool:
        """Check bearer token."""
        if not API_KEY:
            return False
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return auth[7:] == API_KEY

    def do_GET(self):
        """GET /health — health check (no auth required)."""
        if self.path == "/health":
            self._send_json(200, {
                "ok": True,
                "mistral_configured": bool(MISTRAL_KEY),
            })
        else:
            self._send_json(404, {"error": "not_found"})

    def do_POST(self):
        """POST /audio — chunk upload or action (submit/cancel)."""
        if self.path != "/audio":
            self._send_json(404, {"error": "not_found"})
            return

        if not self._auth():
            self._send_json(401, {"error": "unauthorized"})
            return

        recording_id = self.headers.get("X-Recording-ID", "")
        if not recording_id:
            self._send_json(400, {"error": "missing X-Recording-ID"})
            return

        action = self.headers.get("X-Action")
        if action:
            self._handle_action(recording_id, action)
        else:
            self._handle_chunk(recording_id)

    def _handle_chunk(self, recording_id: str):
        """Handle an audio chunk upload."""
        seq_str = self.headers.get("X-Chunk-Sequence", "")
        try:
            seq = int(seq_str)
        except ValueError:
            self._send_json(400, {"error": "invalid X-Chunk-Sequence"})
            return

        audio_format = self.headers.get("X-Audio-Format", "pcm-float32")
        if audio_format not in ("pcm-float32", "aac-adts"):
            self._send_json(400, {"error": f"unsupported format: {audio_format}"})
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            self._send_json(400, {"error": "empty body"})
            return

        data = self.rfile.read(content_length)

        with lock:
            rec = recordings.get(recording_id)
            if rec is None:
                rec = {
                    "chunks": {},
                    "updated": time.time(),
                    "total_bytes": 0,
                    "format": audio_format,
                }
                recordings[recording_id] = rec
            elif rec["format"] != audio_format:
                self._send_json(400, {"error": "format mismatch"})
                return

            if rec["total_bytes"] + len(data) > MAX_BYTES:
                self._send_json(413, {"error": "recording too large"})
                return

            rec["chunks"][seq] = data
            rec["total_bytes"] += len(data)
            rec["updated"] = time.time()

        self._send_json(200, {"ok": True})

    def _handle_action(self, recording_id: str, action: str):
        """Handle submit or cancel action."""
        if action == "cancel":
            with lock:
                recordings.pop(recording_id, None)
            self._send_json(200, {"ok": True})
            return

        if action == "submit":
            self._handle_submit(recording_id)
            return

        self._send_json(400, {"error": f"unknown action: {action}"})

    def _handle_submit(self, recording_id: str):
        """Accept the recording (202) and process it in a background thread.

        Fire and forget: the response is sent as soon as the audio is
        validated and the spooled data is handed off — transcription, the
        Hermes submission, and response delivery happen in a worker thread.
        """
        with lock:
            rec = recordings.pop(recording_id, None)

        if rec is None:
            self._send_json(404, {"error": "recording_not_found"})
            return

        chunks = rec["chunks"]
        if not chunks:
            self._send_json(400, {"error": "no_chunks"})
            return

        # Verify contiguity: sequences must be 0..N
        max_seq = max(chunks.keys())
        missing = [s for s in range(max_seq + 1) if s not in chunks]
        if missing:
            self._send_json(409, {
                "error": "audio_incomplete",
                "missing": missing,
            })
            return

        # Fast fail if STT is not configured — before accepting the work
        if not MISTRAL_KEY:
            self._send_json(503, {
                "error": "stt_unavailable",
                "message": "MISTRAL_API_KEY not configured on server",
            })
            return

        # Optional delivery target (e.g. "matrix"), sent by the watch as a JSON body
        delivery_target = ""
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length > 0:
            try:
                payload = json.loads(self.rfile.read(content_length).decode())
                delivery_target = payload.get("delivery_target", "")
            except (ValueError, UnicodeDecodeError):
                pass  # ignore a malformed body — proceed without a target

        # Concatenate in sequence order
        raw_audio = b"".join(chunks[s] for s in range(max_seq + 1))
        audio_format = rec.get("format", "pcm-float32")

        # Accept immediately; transcribe + forward to Hermes in the background
        self._send_json(202, {"status": "accepted"})

        worker = threading.Thread(
            target=process_recording,
            args=(recording_id, raw_audio, audio_format, delivery_target),
            daemon=True,
        )
        worker.start()


def sweeper():
    """Background thread: delete recordings idle > TTL_SECONDS."""
    while True:
        time.sleep(60)
        now = time.time()
        with lock:
            expired = [
                rid for rid, rec in recordings.items()
                if now - rec["updated"] > TTL_SECONDS
            ]
            for rid in expired:
                del recordings[rid]
                print(f"Sweeper: expired recording {rid}")


def main():
    if not API_KEY:
        print("WARNING: API_SERVER_KEY not set — all requests will be rejected!")

    if MISTRAL_KEY:
        print("Mistral API key configured")
    else:
        print("WARNING: MISTRAL_API_KEY not set — transcription will fail")

    # Discover Tailscale IP and bind
    global _bound_ip
    try:
        ip = tailscale_ip()
        print(f"Binding to Tailscale IP: {ip}:{STT_PORT}")
    except Exception as e:
        print(f"Failed to get Tailscale IP: {e}")
        print("Falling back to 127.0.0.1 (not reachable from tailnet!)")
        ip = "127.0.0.1"
    _bound_ip = ip

    print(f"Hermes API target: {hermes_base_url()}/v1/runs")

    # Start sweeper thread
    sweeper_thread = threading.Thread(target=sweeper, daemon=True)
    sweeper_thread.start()

    # Start HTTP server
    server = ThreadingHTTPServer((ip, STT_PORT), Handler)
    print(f"InstantHermes STT backend listening on http://{ip}:{STT_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
