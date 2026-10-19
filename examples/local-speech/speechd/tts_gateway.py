"""OpenAI-style speech endpoint in front of the Breeze TTS 2 streaming server (Shoofio/breeze-tts2-fast-streaming-api).

    POST /v1/audio/speech  {"model":"breeze-tts-2","voice":"default","input":"...","response_format":"wav"}

- response_format "wav" (default): one complete WAV with exact RIFF/data sizes, sent when synthesis finishes.
  This is what the existing agent-voice clients expect (they read the whole body, then play it).
- response_format "pcm": headerless mono s16le at 24 kHz, streamed as Breeze produces it (OpenAI's pcm format),
  for clients that play incrementally.

Voices are operator-supplied, appropriately licensed reference clips: <name>.wav plus its exact transcript <name>.txt, and an optional
<name>.json ({"seed": 42, "cfg_scale": 1.0, "instruction": null}). Each is registered with Breeze once, so its
codec prompt is cached there. A request for voice "default" (or none) gets the server default, which
 PUT /v1/voices/default {"voice": name} changes at runtime (persisted). No reference voices are included.
GET /v1/voices lists the voices and the default. Requests queue here (FIFO) instead of getting Breeze's 409 busy. A client that
disconnects cancels its request: the upstream connection is closed, and Breeze stops generating within a chunk.

    python -m speechd.tts_gateway --upstream http://127.0.0.1:8450 --voices /path/to/private/references --state /path/to/private/gateway-state --default-voice reference --port 8444
"""
import argparse
import asyncio
import hashlib
import hmac
import itertools
import json
import logging
import math
import os
import time
import wave
from contextlib import aclosing, asynccontextmanager
from pathlib import Path

import aiohttp
from aiohttp import web

from speechd.common import log, now_ms, setup_logging, wav_header

logger = logging.getLogger("tts")
SAMPLE_RATE = 24000
MAX_INPUT = 10000
REQUEST_IDS = itertools.count(1)
VOICE_DEFAULTS = {"seed": 42, "cfg_scale": 1.0, "instruction": None}


class Busy(Exception):
    pass


class Overloaded(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


class UpstreamError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class Gateway:
    def __init__(self, args):
        self.args = args
        self.voices = {}  # name -> settings
        self.default_voice = args.default_voice
        self.lock = asyncio.Lock()  # one synthesis at a time on the GPU; asyncio.Lock wakes waiters FIFO
        self.state = "starting"
        self.error = None
        self.queued = 0
        self.max_queued = int(getattr(args, "max_queued", os.environ.get("TTS_MAX_QUEUED", "32")))
        self.queue_wait_s = float(getattr(args, "queue_wait_s", os.environ.get("TTS_QUEUE_WAIT_S", "30")))
        if self.max_queued < 0 or not math.isfinite(self.queue_wait_s) or self.queue_wait_s <= 0:
            raise ValueError("TTS_MAX_QUEUED must be nonnegative and TTS_QUEUE_WAIT_S finite and positive")
        self.started = time.time()
        self.http: aiohttp.ClientSession | None = None

    def url(self, path):
        return self.args.upstream.rstrip("/") + path

    def scan_voices(self):
        voices = {}
        for wav in sorted(Path(self.args.voices).glob("*.wav")):
            txt = wav.with_suffix(".txt")
            if not txt.exists():
                log(logger, "voice.skipped", logging.WARNING, voice=wav.stem, reason="no transcript .txt")
                continue
            settings = dict(VOICE_DEFAULTS)
            cfg = wav.with_suffix(".json")
            if cfg.exists():
                settings.update(json.loads(cfg.read_text()))
            ref_text = txt.read_text().strip()
            digest = hashlib.sha256(wav.read_bytes() + b"\0" + ref_text.encode()).hexdigest()[:16]
            try:
                with wave.open(str(wav)) as w:
                    seconds = round(w.getnframes() / w.getframerate(), 1)
            except (wave.Error, EOFError):
                seconds = None
            # Display name: optional JSON label, otherwise title-case the clip stem.
            base = wav.stem.removesuffix("_joined")
            label = settings.pop("label", None) or base.replace("_", " ").title() + (" (joined)" if base != wav.stem else "")
            voices[wav.stem] = {**settings, "wav": wav, "ref_text": ref_text, "digest": digest, "label": label,
                                "seconds": seconds}
        return voices

    async def wait_upstream(self, timeout=600):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                async with self.http.get(self.url("/health"), timeout=aiohttp.ClientTimeout(total=3)) as r:
                    if r.status == 200:
                        return await r.json()
            except (aiohttp.ClientError, asyncio.TimeoutError):
                pass
            await asyncio.sleep(1)
        raise RuntimeError(f"Breeze server at {self.args.upstream} did not become healthy")

    async def register_voices(self):
        """Register each voice under its name; re-register when its clip or transcript changed."""
        state_file = Path(self.args.state) / "voices.json"
        known = json.loads(state_file.read_text()) if state_file.exists() else {}
        async with self.http.get(self.url("/v1/voices")) as r:
            existing = {v["id"]: v for v in await r.json()}
        for name, v in self.voices.items():
            if name in existing and known.get(name) == v["digest"]:
                continue
            if name in existing:
                async with self.http.delete(self.url(f"/v1/voices/{name}")) as r:
                    if r.status not in (200, 204, 404):
                        raise RuntimeError(f"could not replace voice {name}: {r.status} {await r.text()}")
            form = aiohttp.FormData()
            form.add_field("name", name)
            form.add_field("ref_text", v["ref_text"])
            form.add_field("ref_audio", v["wav"].read_bytes(), filename=v["wav"].name, content_type="audio/wav")
            async with self.http.post(self.url("/v1/voices"), data=form) as r:
                body = await r.text()
                if r.status != 200:
                    raise RuntimeError(f"could not register voice {name}: {r.status} {body[:200]}")
            known[name] = v["digest"]
            log(logger, "voice.registered", voice=name, digest=v["digest"])
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(known, indent=1))

    async def start(self):
        try:
            self.voices = self.scan_voices()
            if not self.voices:
                raise RuntimeError(f"no voices in {self.args.voices}")
            self.state = "waiting_for_upstream"
            await self.wait_upstream()
            await self.register_voices()
            saved = self.default_file.exists() and json.loads(self.default_file.read_text()).get("voice")
            if saved in self.voices:
                self.default_voice = saved
            if self.default_voice not in self.voices:
                raise RuntimeError(f"default voice {self.default_voice!r} is not in {self.args.voices}")
            self.state = "warming"
            await self.warm(self.default_voice)  # builds Breeze's cached voice prefix and compiles the frame graph
            self.state = "ready"
            log(logger, "gateway.ready", voices=list(self.voices), default=self.default_voice, upstream=self.args.upstream)
            for name in self.voices:  # the rest warm in the background; a request queues behind at most one
                if name != self.default_voice:
                    try:
                        await self.warm(name)
                    except Exception as e:  # that voice will build its prompt on first use instead
                        log(logger, "voice.warm_failed", logging.WARNING, voice=name, error=f"{type(e).__name__}: {e}")
        except Exception as e:
            self.state, self.error = "error", f"{type(e).__name__}: {e}"
            logger.exception("gateway.start_failed")

    @property
    def default_file(self):
        return Path(self.args.state) / "default-voice.json"

    def resolve(self, name):
        name = (name or "default").strip()
        if name == "default":
            return self.default_voice
        return name if name in self.voices else None

    def set_default(self, name):
        self.default_voice = name
        self.default_file.parent.mkdir(parents=True, exist_ok=True)
        self.default_file.write_text(json.dumps({"voice": name}) + "\n")
        log(logger, "voice.default", voice=name)

    async def warm(self, name):
        t0 = now_ms()
        async with aclosing(self.synthesize(name, "Ready.", None)) as stream:
            async for _ in stream:
                pass
        log(logger, "voice.warm", voice=name, ms=round(now_ms() - t0))

    @asynccontextmanager
    async def synthesis_slot(self):
        """Bounded FIFO admission; limits waiters, never preempts the active voice."""
        waiting = self.lock.locked() or self.queued > 0
        if waiting and self.queued >= self.max_queued:
            raise Overloaded("speech queue is full", "queue_full")
        acquired = False
        if waiting:
            self.queued += 1  # no await between capacity check and reservation
        try:
            try:
                async with asyncio.timeout(self.queue_wait_s):
                    await self.lock.acquire()
                    acquired = True
            except TimeoutError as e:
                raise Overloaded("speech queue wait timed out", "queue_timeout") from e
            finally:
                if waiting:
                    self.queued -= 1
            yield
        finally:
            if acquired:
                self.lock.release()

    async def synthesize(self, voice: str, text: str, instruction: str | None, timing: dict | None = None):
        """Yield PCM chunks from Breeze. Holds the GPU lock for the whole generation."""
        v = self.voices[voice]
        fields = {"text": text, "voice_id": voice, "seed": str(v["seed"]), "cfg_scale": str(v["cfg_scale"])}
        if instruction or v.get("instruction"):
            fields["instruction"] = instruction or v["instruction"]
        t_queue = now_ms()
        async with self.synthesis_slot():
            if timing is not None:
                timing["queue_ms"] = round(now_ms() - t_queue)
            for attempt in range(50):  # Breeze can still report busy briefly after a cancelled generation
                t_req = now_ms()
                resp = await self.http.post(self.url("/v1/audio/speech"), data=fields)
                if resp.status == 409:
                    resp.release()
                    await asyncio.sleep(0.1)
                    continue
                break
            else:
                raise Busy()
            try:
                if resp.status != 200:
                    raise UpstreamError(resp.status, (await resp.text())[:300])
                first = True
                async for chunk in resp.content.iter_any():
                    if first and timing is not None:
                        timing["first_chunk_ms"] = round(now_ms() - t_req)
                        first = False
                    yield chunk
                if not resp.content.is_eof():
                    raise UpstreamError(502, "speech stream ended early")
            finally:
                resp.close()  # on cancellation this drops the connection, which stops Breeze's generation


def _error(status, message, code=None):
    return web.json_response({"error": {"message": message, "type": "invalid_request_error" if status < 500
                                        else "server_error", "code": code}}, status=status)


async def speech(request):
    gw: Gateway = request.app["gateway"]
    rid = next(REQUEST_IDS)
    if gw.args.api_key:
        got = request.headers.get("Authorization", "")
        if not hmac.compare_digest(got.encode(), f"Bearer {gw.args.api_key}".encode()):
            return _error(401, "unauthorized")
    if gw.state != "ready":
        return _error(503, f"speech service is {gw.state}", "not_ready")
    try:
        body = await request.json()
    except (ValueError, UnicodeDecodeError):
        return _error(400, "body must be JSON")
    if not isinstance(body, dict):
        return _error(400, "body must be a JSON object")
    text = body.get("input")
    if not isinstance(text, str) or not text.strip():
        return _error(400, "input is required")
    if len(text) > MAX_INPUT:
        return _error(400, f"input is longer than {MAX_INPUT} characters")
    voice = gw.resolve(body.get("voice"))
    if voice is None:
        return _error(400, f"unknown voice {body.get('voice')!r}; available: default, {', '.join(gw.voices)}",
                      "unknown_voice")
    fmt = body.get("response_format", "wav")
    if fmt not in ("wav", "pcm"):
        return _error(400, f"response_format {fmt!r} is not supported; use wav or pcm")
    if body.get("stream_format", "audio") != "audio":
        return _error(400, "only stream_format audio is supported")
    instruction = body.get("instructions") or None

    timing = {}
    t0 = now_ms()
    n = 0
    outcome = "ok"
    resp = None
    try:
        if fmt == "pcm":
            resp = web.StreamResponse(headers={"Content-Type": "audio/pcm", "X-Sample-Rate": str(SAMPLE_RATE),
                                               "X-Sample-Format": "s16le", "Cache-Control": "no-store"})
            # aclosing: a cancelled write must still release the GPU lock and the upstream connection now
            async with aclosing(gw.synthesize(voice, text, instruction, timing)) as stream:
                async for chunk in stream:
                    if not resp.prepared:
                        await resp.prepare(request)
                    await resp.write(chunk)
                    n += len(chunk)
            if not resp.prepared:
                await resp.prepare(request)
            await resp.write_eof()
            return resp
        pcm = bytearray()
        async with aclosing(gw.synthesize(voice, text, instruction, timing)) as stream:
            async for chunk in stream:
                pcm += chunk
        if len(pcm) % 2:
            pcm = pcm[:-1]
        n = len(pcm)
        return web.Response(body=wav_header(n, SAMPLE_RATE) + bytes(pcm), content_type="audio/wav",
                            headers={"Cache-Control": "no-store"})
    except asyncio.CancelledError:
        outcome = "cancelled"
        raise
    except (ConnectionResetError, aiohttp.ClientConnectionResetError):
        outcome = "cancelled"
        return resp
    except Busy:
        outcome = "busy"
        return _error(503, "speech engine stayed busy", "busy")
    except Overloaded as e:
        outcome = "overloaded"
        return _error(429, str(e), e.code)
    except UpstreamError as e:
        outcome = "error"
        log(logger, "tts.upstream_error", logging.WARNING, request=rid, status=e.status, message=str(e))
        if resp is not None and resp.prepared:
            raise  # mid-stream: drop the connection so the client sees an incomplete body
        return _error(502 if e.status >= 500 else e.status, f"speech engine error: {e}")
    except (aiohttp.ClientError, asyncio.TimeoutError) as e:
        outcome = "error"
        log(logger, "tts.upstream_unreachable", logging.ERROR, request=rid, error=str(e))
        if resp is not None and resp.prepared:
            raise
        return _error(502, "speech engine unreachable")
    finally:
        total = now_ms() - t0
        audio_s = n / 2 / SAMPLE_RATE
        gen_ms = total - timing.get("queue_ms", 0)
        log(logger, "tts.request", request=rid, outcome=outcome, voice=voice, format=fmt, chars=len(text),
            audio_s=round(audio_s, 2), total_ms=round(total), **timing,
            rtf=round(gen_ms / 1000 / audio_s, 3) if audio_s else None)


async def health(request):
    gw: Gateway = request.app["gateway"]
    a = gw.args
    upstream = None
    try:
        async with gw.http.get(gw.url("/health"), timeout=aiohttp.ClientTimeout(total=2)) as r:
            upstream = {**(await r.json(content_type=None)), "http_status": r.status}
    except Exception as e:
        upstream = {"status": "unreachable", "error": type(e).__name__}
    ok = gw.state == "ready" and upstream.get("http_status") == 200
    body = {"status": "ok" if ok else (gw.state if gw.state != "ready" else "upstream_unavailable"),
            "service": "tts", "backend": "breeze-tts2-fast-streaming-api (mlx)",
            "model_id": a.model_id, "model": upstream.get("model", "loaded"),
            "idle_unload_s": upstream.get("idle_unload_s", 0), "idle_s": upstream.get("idle_s", 0),
            "revision": a.revision, "precision": a.precision, "default_voice": gw.default_voice, "voices": list(gw.voices), "queued": gw.queued,
            "busy": gw.lock.locked(), "queue_limit": gw.max_queued, "queue_wait_s": gw.queue_wait_s,
            "upstream": upstream, "uptime_s": round(time.time() - gw.started)}
    if gw.error:
        body["error"] = gw.error
    return web.json_response(body, status=200 if ok else 503)


async def list_voices(request):
    gw: Gateway = request.app["gateway"]
    return web.json_response({"default": gw.default_voice, "voices": [
        {"name": k, "label": v["label"], "reference_seconds": v["seconds"], "seed": v["seed"], "cfg_scale": v["cfg_scale"],
         "instruction": v["instruction"], "reference_text": v["ref_text"]} for k, v in gw.voices.items()]})


async def model_control(request):
    """Administrative model lifecycle only; never starts/stops a LaunchAgent."""
    gw: Gateway = request.app["gateway"]
    if request.remote not in ("127.0.0.1", "::1"):
        return _error(403, "local administration only")
    if gw.args.api_key and not hmac.compare_digest(request.headers.get("Authorization", "").encode(),
                                                 f"Bearer {gw.args.api_key}".encode()):
        return _error(401, "unauthorized")
    action = request.match_info["action"]
    if action not in ("load", "unload"):
        return _error(404, "unknown model action")
    if gw.lock.locked() or gw.queued or gw.state != "ready":
        return _error(409, "speech requests are in flight; model left untouched")
    # Hold the same lock used by synthesis so a queued request cannot race unload.
    async with gw.lock:
        async with gw.http.post(gw.url(f"/admin/model/{action}")) as r:
            body = await r.read()
            status = r.status
    if status == 200 and action == "load":
        try:
            await gw.warm(gw.default_voice)
        except Overloaded as e:
            # Speech can fill the queue after the administrative lock was
            # released. Preserve the admin busy contract, not an HTTP 500.
            return _error(409, str(e), e.code)
    return web.Response(body=body, status=status, content_type="application/json")


async def set_default_voice(request):
    gw: Gateway = request.app["gateway"]
    if gw.args.api_key:
        got = request.headers.get("Authorization", "")
        if not hmac.compare_digest(got.encode(), f"Bearer {gw.args.api_key}".encode()):
            return _error(401, "unauthorized")
    try:
        body = await request.json()
    except (ValueError, UnicodeDecodeError):
        return _error(400, "body must be JSON")
    name = gw.resolve(body.get("voice") if isinstance(body, dict) else None)
    if name is None:
        return _error(400, f"unknown voice; available: {', '.join(gw.voices)}", "unknown_voice")
    gw.set_default(name)
    return web.json_response({"default": name})


def build_app(args) -> web.Application:
    app = web.Application(client_max_size=1 << 20)
    gw = app["gateway"] = Gateway(args)
    app.router.add_get("/health", health)
    app.router.add_post("/v1/audio/speech", speech)
    app.router.add_get("/v1/voices", list_voices)
    app.router.add_put("/v1/voices/default", set_default_voice)
    app.router.add_post("/admin/model/{action}", model_control)

    async def on_startup(app):
        gw.http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=5, sock_read=60))
        app["starter"] = asyncio.create_task(gw.start())

    async def on_cleanup(app):
        app["starter"].cancel()
        await asyncio.gather(app["starter"], return_exceptions=True)
        await gw.http.close()

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--upstream", default="http://127.0.0.1:8450", help="Breeze server base URL")
    p.add_argument("--voices", required=True, help="directory of <name>.wav + <name>.txt references")
    p.add_argument("--state", required=True, help="directory for gateway state (registered voice digests)")
    p.add_argument("--default-voice", required=True, help="operator-supplied reference stem used when a request names no voice")
    p.add_argument("--model-id", default="Shoof/Gust-MLX")
    p.add_argument("--revision", default="unknown")
    p.add_argument("--precision", default="mixed")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8444)
    p.add_argument("--log-level", default="info")
    args = p.parse_args()
    args.api_key = os.environ.get("SPEECHD_TTS_API_KEY", "")
    setup_logging("tts", args.log_level)
    log(logger, "server.starting", host=args.host, port=args.port, pid=os.getpid())
    web.run_app(build_app(args), host=args.host, port=args.port, print=None, handler_cancellation=True)


if __name__ == "__main__":
    main()
