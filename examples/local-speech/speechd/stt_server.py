"""Speech-to-text behind the agent-voice /v1/transcribe protocol.

One WebSocket per utterance:
  client -> binary frames of PCM s16le, mono, 16 kHz, as captured
  client -> {"type":"input_audio.end"} when the speaker pauses
  server -> {"type":"transcript","text":<delta>}  committed text; clients append successive deltas
  server -> {"type":"error","message":...}       then closes
  server closes with 1000 once the final text is sent; that close is the client's completion signal.

Opt-in live words (parakeet): connect with ?partials=1 and, while audio streams, the server also sends
  server -> {"type":"transcript.partial","text":<whole hypothesis so far>,"seq":n,"audio_ms":ms}
Partials are display-only snapshots (replace, don't append; append-only in practice, never revised). The
final is unchanged: one {"type":"transcript"} with the whole-utterance pass, then close 1000. Without
?partials=1 nothing here applies and behaviour is exactly as before.

Backends:
  parakeet (default)  nvidia parakeet-unified-en-0.6b GGUF through transcribe.cpp (Metal), the model Handy uses.
                      Audio is buffered while the user speaks and the whole utterance is transcribed at
                      input_audio.end, then sent as one transcript message. With ?partials=1 a
                      second model instance also streams the audio for the live partials (see StreamingUtterance).
  voxtral             Voxtral Mini 4B Realtime on MLX, streaming: append-only deltas while the user speaks
                      (an incomplete trailing UTF-8 sequence is held back).

All model work runs on one executor thread; concurrent utterances queue there. The parakeet live-partials
stream has its own model instance and its own thread, so streaming never blocks (or is blocked by) final passes.

    python -m speechd.stt_server --backend parakeet --model <file.gguf> --port 8446
"""
import argparse
import asyncio
import hmac
import itertools
import json
import logging
import os
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from aiohttp import WSMsgType, web

from speechd.common import log, now_ms, setup_logging

logger = logging.getLogger("stt")
SAMPLE_RATE = 16000
SESSION_IDS = itertools.count(1)


class VoxtralBackend:
    name, runtime = "voxtral", "mlx-audio"

    def __init__(self, args):
        self.args = args
        self.model = None

    def load(self):
        import mlx.core as mx
        from mlx.utils import tree_map
        from mlx_audio.stt.utils import load

        model = load(self.args.model)
        # The mlx-community fp16 snapshot keeps norms, biases and the adaptive-norm MLPs in fp32. Mixed with fp16
        # activations, every decoder FFN matmul is promoted to fp32 (~4.5x slower decode, ~4x slower encoder).
        # Cast them once and recompute the adaptive-norm scales in fp16.
        if self.args.precision == "fp16":
            model.update(tree_map(lambda v: v.astype(mx.float16) if v.dtype == mx.float32 else v, model.parameters()))
            mx.eval(model.parameters())
            model._ada_scale_delay = None
        model._ensure_ada_scales(self.args.delay_ms)
        # MLX keeps freed buffers for reuse; uncapped, the cast's discarded fp32 tensors and per-session
        # activations kept the process at ~26 GB for an ~8 GB model.
        mx.set_cache_limit(int(self.args.cache_gb * 2**30))
        mx.clear_cache()
        self.model = model

    def memory(self):
        import mlx.core as mx
        gb = lambda n: round(n / 2**30, 2)
        return {"active_gb": gb(mx.get_active_memory()), "cache_gb": gb(mx.get_cache_memory()),
                "peak_gb": gb(mx.get_peak_memory())}

    def transcribe(self, pcm: np.ndarray, chunk: int = 1280) -> str:
        sess = self.model.create_streaming_session(transcription_delay_ms=self.args.delay_ms)
        out = []
        for i in range(0, len(pcm), chunk):
            sess.feed(pcm[i:i + chunk])
            out += sess.step(max_decode_tokens=self.args.step_tokens)
        sess.close()
        while not sess.done:
            out += sess.step(max_decode_tokens=64)
        return "".join(out).strip()

    def utterance(self, engine, partials=False):  # already streams transcript deltas; ?partials=1 is a no-op
        return VoxtralUtterance(engine, self)


class ParakeetBackend:
    name, runtime = "parakeet", "transcribe.cpp"
    STREAM_LEFT_MS = 5600  # fixed by the model's training menu

    def __init__(self, args):
        self.args = args
        self.model = self.session = None
        # Live partials: a second Model instance (~0.75 GB) so a stream never takes the lease the final passes
        # need (transcribe_cpp raises Busy for any run() on a Model while one of its streams is active), plus
        # its own thread. One stream at a time; a connection that can't get the slot just gets no partials.
        self.stream_model = self.stream_session = self.active_stream = None
        self.stream_ready = self.stream_busy = False
        self.stream_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stream")
        self.stream_error = None

    def load(self):
        # ggml prints Metal start-up chatter straight to stderr while the library loads; keep the log JSON-only
        # and surface it only if loading fails. Afterwards native warnings/errors go through our logger.
        saved = os.dup(2)
        with tempfile.TemporaryFile() as capture:
            os.dup2(capture.fileno(), 2)
            try:
                import transcribe_cpp
                transcribe_cpp.set_log_callback(_native_log)
                self.model = transcribe_cpp.Model(self.args.model)
                # All 18 cores (the default) gave sporadic 130-1170 ms runs for ~50 ms of work; 8 threads stay flat.
                self.session = self.model.session(n_threads=self.args.threads)
            except Exception:
                capture.seek(0)
                os.dup2(saved, 2)
                logger.error("native start-up output:\n%s", capture.read().decode(errors="replace")[-4000:])
                raise
            finally:
                os.dup2(saved, 2)
                os.close(saved)
        self.device = getattr(self.model, "device", None)

    def memory(self):
        return {}

    def transcribe(self, pcm: np.ndarray) -> str:
        import transcribe_cpp
        if len(pcm) < SAMPLE_RATE // 10:  # under 100 ms: nothing to transcribe
            return ""
        try:
            return self.session.run(pcm, timestamps="none").text.strip()
        except transcribe_cpp.InputTooShort:
            return ""

    def utterance(self, engine, partials=False):
        if partials and self.stream_ready:
            return StreamingUtterance(engine, self)
        return BufferedUtterance(engine, self)

    # ---- live-partials stream (all of it runs on stream_executor, one thread owns the stream Model)

    async def stream_run(self, fn, *args):
        return await asyncio.get_running_loop().run_in_executor(self.stream_executor, fn, *args)

    def load_stream(self):
        """Load the second model instance. Failure only disables partials; the server stays fully usable."""
        saved = os.dup(2)
        with tempfile.TemporaryFile() as capture:
            os.dup2(capture.fileno(), 2)
            try:
                import transcribe_cpp
                self.stream_model = transcribe_cpp.Model(self.args.model)
                self.stream_session = self.stream_model.session(n_threads=self.args.threads)
            except Exception as e:
                capture.seek(0)
                os.dup2(saved, 2)
                self.stream_error = f"{type(e).__name__}: {e}"
                logger.error("stream model load failed, live partials disabled: %s\n%s", self.stream_error,
                             capture.read().decode(errors="replace")[-2000:])
            finally:
                os.dup2(saved, 2)
                os.close(saved)

    def warm_stream(self, pcm: np.ndarray) -> dict:
        """Run the whole warm-up clip through a stream (compiles the streaming Metal kernels, ~170 ms saved on
        the first real feed), then reset. Metal prints pipeline-compile chatter on first use; keep the log JSON."""
        saved = os.dup(2)
        t0, steps, text = now_ms(), 0, ""
        with tempfile.TemporaryFile() as capture:
            os.dup2(capture.fileno(), 2)
            try:
                self.open_stream()
                step = SAMPLE_RATE * 80 // 1000
                for i in range(0, len(pcm), step):
                    text = self.stream_step(pcm[i:i + step]) or text
                    steps += 1
                self.stream_ready = True
            except Exception as e:
                self.stream_error = f"warm-up: {type(e).__name__}: {e}"
                capture.seek(0)
                os.dup2(saved, 2)
                logger.error("stream warm-up failed, live partials disabled: %s\n%s", self.stream_error,
                             capture.read().decode(errors="replace")[-2000:])
            finally:
                os.dup2(saved, 2)
                os.close(saved)
                self.reset_stream()
        return {"ms": round(now_ms() - t0), "steps": steps, "chars": len(text)}

    def open_stream(self):
        import transcribe_cpp
        a = self.args
        opts = transcribe_cpp.ParakeetBufferedStreamOptions(
            left_ms=self.STREAM_LEFT_MS, chunk_ms=a.partial_chunk_ms, right_ms=a.partial_right_ms)
        self.active_stream = self.stream_session.stream(family=opts)

    def stream_step(self, pcm: np.ndarray):
        """Feed audio; the whole hypothesis so far when it changed, else None."""
        s = self.active_stream
        if s is None:
            raise RuntimeError("no active stream")
        if s.feed(pcm).result_changed:
            return s.text().full.strip()
        return None

    def reset_stream(self):
        s, self.active_stream = self.active_stream, None
        if s is not None:
            try:
                s.reset()  # releases the stream Model's lease
            except Exception as e:
                log(logger, "stt.stream_reset_failed", logging.WARNING, error=repr(e))

    def claim_stream(self) -> bool:
        """Event-loop thread only. Take the single stream slot if it is free and healthy."""
        if not self.stream_ready or self.stream_busy:
            return False
        self.stream_busy = True
        return True

    def release_stream(self):
        """Event-loop thread only. Reset the stream behind any in-flight step, then free the slot."""
        loop = asyncio.get_running_loop()
        fut = self.stream_executor.submit(self.reset_stream)
        fut.add_done_callback(lambda _: loop.call_soon_threadsafe(setattr, self, "stream_busy", False))


def _native_log(level, message):
    if level in (2, 3) and message.strip():  # TRANSCRIBE_LOG_LEVEL_WARN / ERROR
        log(logger, "native", logging.WARNING if level == 2 else logging.ERROR, message=message.strip()[:500])


class BufferedUtterance:
    """Collect the utterance; transcribe it in one pass at the end."""

    def __init__(self, engine, backend):
        self.engine, self.backend = engine, backend
        self.chunks = []
        self.ended = asyncio.Event()
        self.cancelled = False
        self.tokens = 0

    def feed(self, pcm):
        self.chunks.append(pcm)

    def end(self):
        self.ended.set()

    def cancel(self):
        self.cancelled = True
        self.ended.set()

    async def run(self, emit, stats):
        await self.ended.wait()
        if self.cancelled:
            return False
        pcm = np.concatenate(self.chunks) if self.chunks else np.zeros(0, np.float32)
        self.chunks = []
        t0 = now_ms()
        text = await self.engine.run(self.backend.transcribe, pcm)
        stats["gpu_ms"] += now_ms() - t0
        if self.cancelled:
            return False
        if text:
            await emit(text)
        return True


class StreamingUtterance(BufferedUtterance):
    """BufferedUtterance plus live partials for display. The final text is still the whole-utterance pass, so
    accuracy is exactly the buffered path's; the stream (a separate model instance, see ParakeetBackend) only
    produces `transcript.partial` snapshots. Any stream trouble degrades to a plain buffered utterance."""

    def __init__(self, engine, backend):
        super().__init__(engine, backend)
        self.on_partial = None  # async (text, seq, audio_ms); set by the connection handler
        self.pending, self.wake = [], asyncio.Event()
        self.feeder = None
        self.slot = False  # we hold the backend's single stream slot
        self.seq = self.fed = 0
        self.stream_ms = 0.0
        self.first_partial_audio_ms = None

    def feed(self, pcm):
        super().feed(pcm)
        if self.ended.is_set():
            return
        if self.feeder is None:  # first audio: try for the slot; without it this is a plain buffered utterance
            self.feeder = False
            if self.backend.claim_stream():
                self.slot = True
                self.feeder = asyncio.ensure_future(self._feed_loop())
        if self.feeder and not self.feeder.done():
            self.pending.append(pcm)  # audio ingestion never waits on the model; steps coalesce what piled up
            self.wake.set()

    def end(self):
        super().end()
        self.wake.set()

    def cancel(self):
        super().cancel()
        self.wake.set()

    async def _feed_loop(self):
        be, last = self.backend, ""
        try:
            await be.stream_run(be.open_stream)
            while True:
                await self.wake.wait()
                self.wake.clear()
                if self.ended.is_set():
                    return
                pcm, self.pending = np.concatenate(self.pending), []
                t0 = now_ms()
                text = await be.stream_run(be.stream_step, pcm)
                self.stream_ms += now_ms() - t0
                self.fed += len(pcm)
                if text and text != last and not self.ended.is_set():
                    last, self.seq = text, self.seq + 1
                    audio_ms = round(self.fed * 1000 / SAMPLE_RATE)
                    if self.first_partial_audio_ms is None:
                        self.first_partial_audio_ms = audio_ms
                    await self.on_partial(text, self.seq, audio_ms)
        except asyncio.CancelledError:
            raise
        except Exception as e:  # the final pass doesn't depend on the stream: keep buffering, drop the partials
            log(logger, "stt.stream_failed", logging.WARNING, error=repr(e))
            self.pending = []
            self._release_slot()

    def _release_slot(self):
        if self.slot:
            self.slot = False
            self.backend.release_stream()

    def _release(self):
        if self.feeder:
            self.feeder.cancel()
        self._release_slot()

    async def _wind_down(self):
        """Let the in-flight stream step finish so no partial can follow the final."""
        if self.feeder:
            await asyncio.wait({self.feeder})
        self._release()  # reset runs on the stream thread, in parallel with the final pass

    async def run(self, emit, stats):
        try:
            await self.ended.wait()
            if self.cancelled:
                return False
            pcm = np.concatenate(self.chunks) if self.chunks else np.zeros(0, np.float32)
            self.chunks = []

            async def final_pass():
                t0 = now_ms()
                text = await self.engine.run(self.backend.transcribe, pcm)
                stats["gpu_ms"] += now_ms() - t0
                return text

            text, _ = await asyncio.gather(final_pass(), self._wind_down())
            if self.cancelled:
                return False
            if text:
                await emit(text)
            return True
        finally:
            self._release()


class VoxtralUtterance:
    """Stream committed deltas while audio arrives; finish after input_audio.end."""

    def __init__(self, engine, backend):
        self.engine, self.backend = engine, backend
        self.sess = None
        self.wake = asyncio.Event()
        self.ended = self.cancelled = False

    @property
    def tokens(self):
        return len(self.sess.generated) if self.sess else 0

    async def start(self):
        # Session construction evaluates MLX arrays, so it belongs on the MLX thread too.
        a = self.backend.args
        self.sess = await self.engine.run(
            lambda: self.backend.model.create_streaming_session(transcription_delay_ms=a.delay_ms))

    def feed(self, pcm):
        self.sess.feed(pcm)
        self.wake.set()

    def end(self):
        self.ended = True
        self.sess.close()
        self.wake.set()

    def cancel(self):
        self.cancelled = True
        self.wake.set()

    async def run(self, emit, stats):
        sess, steps = self.sess, self.backend.args.step_tokens
        sent = ""
        while True:
            await self.wake.wait()
            self.wake.clear()
            while not self.cancelled:
                before = len(sess.generated)
                t0 = now_ms()
                await self.engine.run(lambda: sess.step(max_decode_tokens=steps))
                stats["gpu_ms"] += now_ms() - t0
                full = sess._prev_text  # the session's decoded text so far (pinned mlx-audio)
                stable = full if sess.done else full.rstrip("�")
                if stable.startswith(sent) and len(stable) > len(sent):
                    delta, sent = stable[len(sent):], stable
                    await emit(delta)
                elif not stable.startswith(sent):
                    log(logger, "stt.text_diverged", logging.WARNING)
                if sess.done:
                    return True
                if len(sess.generated) == before and not self.ended:
                    break  # caught up with the audio received so far
            if self.cancelled:
                return False


class Engine:
    """Owns the backend and the single model thread."""

    def __init__(self, args):
        self.args = args
        self.backend = {"parakeet": ParakeetBackend, "voxtral": VoxtralBackend}[args.backend](args)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="model")
        self.state = "loading"
        self.error = None
        self.warmup = {}
        self.stream_warmup = {}
        self.stream_loader = None
        self.active = 0
        self.started = time.time()

    async def run(self, fn, *args):
        return await asyncio.get_running_loop().run_in_executor(self.executor, fn, *args)

    async def start(self):
        try:
            t0 = now_ms()
            await self.run(self.backend.load)
            a = self.args
            log(logger, "model.loaded", backend=self.backend.name, runtime=self.backend.runtime, model=a.model_id,
                revision=a.revision, precision=a.precision, load_ms=round(now_ms() - t0))
            if a.warmup:
                self.state = "warming"
                pcm = np.fromfile(a.warmup, dtype="<i2").astype(np.float32) / 32768.0
                for _ in range(2):
                    t0 = now_ms()
                    text = await self.run(self.backend.transcribe, pcm)
                    self.warmup = {"ms": round(now_ms() - t0), "audio_s": round(len(pcm) / SAMPLE_RATE, 2),
                                   "chars": len(text)}
                if a.warmup_text:  # self-test: the reference clip must transcribe (nearly) to its transcript
                    wer = _wer(Path(a.warmup_text).read_text(), text)
                    self.warmup.update(reference_wer=round(wer, 3), matches_reference=wer <= 0.1)
                log(logger, "model.warm", **self.warmup)
            self.state = "ready"
            if a.backend == "parakeet" and a.partials:
                # The offline model is ready now. Stream-model loading/warm-up has
                # its own executor and must never delay the plain final path.
                self.stream_loader = asyncio.create_task(self.start_stream())
        except Exception as e:  # keep serving /health so a supervisor can see why
            self.state, self.error = "error", f"{type(e).__name__}: {e}"
            logger.exception("model.load_failed")

    async def start_stream(self):
        a, b = self.args, self.backend
        try:
            await b.stream_run(b.load_stream)
            if b.stream_model is not None:
                pcm = (np.fromfile(a.warmup, dtype="<i2").astype(np.float32) / 32768.0 if a.warmup
                       else np.zeros(SAMPLE_RATE * 2, np.float32))
                self.stream_warmup = await b.stream_run(b.warm_stream, pcm)
                log(logger, "stream.warm", ready=b.stream_ready, error=b.stream_error, **self.stream_warmup)
        except Exception as e:
            b.stream_error = f"{type(e).__name__}: {e}"
            logger.exception("stream.load_failed")


def _norm(text: str) -> str:
    return " ".join("".join(c for c in text.lower() if c.isalnum() or c.isspace()).split())


def _wer(ref: str, hyp: str) -> float:
    r, h = _norm(ref).split(), _norm(hyp).split()
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)] / max(len(r), 1)


def _authorized(request, key):
    if not key:
        return True
    got = request.headers.get("Authorization", "")
    return hmac.compare_digest(got.encode(), f"Bearer {key}".encode())


async def health(request):
    eng: Engine = request.app["engine"]
    a = eng.args
    body = {"status": "ok" if eng.state == "ready" else eng.state, "service": "stt", "backend": eng.backend.name,
            "runtime": eng.backend.runtime, "model": a.model_id, "revision": a.revision, "precision": a.precision,
            "streaming_partials": eng.backend.name == "voxtral" or getattr(eng.backend, "stream_ready", False),
            "warmup": eng.warmup, "active_sessions": eng.active, "uptime_s": round(time.time() - eng.started)}
    if eng.backend.name == "voxtral":
        body["delay_ms"] = a.delay_ms
    if eng.backend.name == "parakeet":  # opt-in live partials: ws://.../v1/transcribe?partials=1
        b = eng.backend
        body["partials"] = {"enabled": b.stream_ready, "opt_in": "?partials=1", "message": "transcript.partial",
                            "lookahead_ms": a.partial_chunk_ms + a.partial_right_ms, "slot_busy": b.stream_busy,
                            "warmup": eng.stream_warmup or None, "error": b.stream_error}
    if eng.state == "ready":
        body["memory"] = eng.backend.memory() or None
    if eng.error:
        body["error"] = eng.error
    return web.json_response(body, status=200 if eng.state == "ready" else 503)


async def transcribe(request):
    eng: Engine = request.app["engine"]
    a = eng.args
    if not _authorized(request, a.api_key):
        return web.json_response({"type": "error", "message": "unauthorized"}, status=401)

    ws = web.WebSocketResponse(max_msg_size=1 << 20, autoping=True)
    await ws.prepare(request)
    sid = next(SESSION_IDS)
    if eng.state != "ready":
        await ws.send_json({"type": "error", "message": f"speech recognition is {eng.state}"})
        await ws.close(code=1013)
        return ws

    want_partials = request.query.get("partials", "").lower() in ("1", "true")
    utt = eng.backend.utterance(eng, want_partials)
    if hasattr(utt, "start"):
        await utt.start()
    st = {"samples": 0, "ended": False, "completed": False, "outcome": "ok", "t_first_audio": None,
          "t_end": None, "t_first_text": None, "gpu_ms": 0.0, "chars": 0}
    eng.active += 1

    async def emit(text):
        if st["t_first_text"] is None:
            st["t_first_text"] = now_ms()
        st["chars"] += len(text)
        if not ws.closed:
            await ws.send_json({"type": "transcript", "text": text})

    async def emit_partial(text, seq, audio_ms):  # display-only; deliberately not counted as t_first_text
        if not ws.closed:
            await ws.send_json({"type": "transcript.partial", "text": text, "seq": seq, "audio_ms": audio_ms})

    if isinstance(utt, StreamingUtterance):
        utt.on_partial = emit_partial

    async def fail(message, code=1011):
        if st["outcome"] == "ok":
            st["outcome"] = "error"
        utt.cancel()
        if not ws.closed:
            await ws.send_json({"type": "error", "message": message})
            await ws.close(code=code)

    async def finish():
        if await utt.run(emit, st):
            st["completed"] = True
            if not ws.closed:
                await ws.close(code=1000)

    worker = asyncio.create_task(finish())

    def worker_done(task):  # a model failure must end the session now, not at the idle timeout
        if not task.cancelled() and task.exception() is not None:
            log(logger, "stt.decode_failed", logging.ERROR, session=sid, error=repr(task.exception()))
            asyncio.ensure_future(fail(f"recognition failed: {type(task.exception()).__name__}"))

    worker.add_done_callback(worker_done)
    max_samples = a.max_seconds * SAMPLE_RATE
    try:
        while True:
            try:
                msg = await ws.receive(timeout=a.idle_timeout)
            except asyncio.TimeoutError:
                await fail("no audio received; recognition timed out")
                break
            if msg.type == WSMsgType.BINARY:
                if st["ended"]:
                    continue
                if len(msg.data) % 2:
                    await fail("audio must be 16-bit PCM (odd byte count)", code=1003)
                    break
                pcm = np.frombuffer(msg.data, dtype="<i2").astype(np.float32) / 32768.0
                if st["t_first_audio"] is None:
                    st["t_first_audio"] = now_ms()
                st["samples"] += pcm.size
                if st["samples"] > max_samples:
                    await fail(f"utterance longer than {a.max_seconds} s", code=1009)
                    break
                utt.feed(pcm)
            elif msg.type == WSMsgType.TEXT:
                try:
                    event = json.loads(msg.data)
                except ValueError:
                    await fail("text frames must be JSON", code=1003)
                    break
                if event.get("type") == "input_audio.end" and not st["ended"]:
                    st["ended"], st["t_end"] = True, now_ms()
                    utt.end()
            else:  # CLOSE / CLOSING / CLOSED / ERROR: the client went away or we closed
                break
        if not st["completed"]:
            if st["outcome"] == "ok":
                st["outcome"] = "cancelled"
            utt.cancel()
        await asyncio.wait({worker}, timeout=10)
    except asyncio.CancelledError:  # aiohttp cancels the handler when the connection drops, even after a normal close
        if not st["completed"]:
            if st["outcome"] == "ok":
                st["outcome"] = "cancelled"
            utt.cancel()
        raise
    except Exception as e:
        logger.exception("stt.session_failed")
        await fail(f"recognition failed: {type(e).__name__}")
    finally:
        eng.active -= 1
        if not worker.done():
            worker.cancel()
        t_close = now_ms()
        audio_s = st["samples"] / SAMPLE_RATE
        fields = {"session": sid, "outcome": st["outcome"], "audio_s": round(audio_s, 2), "chars": st["chars"],
                  "tokens": utt.tokens, "gpu_ms": round(st["gpu_ms"]),
                  "gpu_duty": round(st["gpu_ms"] / 1000 / audio_s, 3) if audio_s else None}
        if st["t_end"] is not None:
            fields["final_ms"] = round(t_close - st["t_end"])  # input_audio.end -> close (final text delivered)
        if st["t_first_text"] is not None and st["t_first_audio"] is not None:
            fields["first_text_ms"] = round(st["t_first_text"] - st["t_first_audio"])
        if want_partials and eng.backend.name == "parakeet":
            fields["partials"] = utt.seq if isinstance(utt, StreamingUtterance) else None  # None: not served
            if isinstance(utt, StreamingUtterance):
                fields["stream_ms"] = round(utt.stream_ms)
                fields["first_partial_audio_ms"] = utt.first_partial_audio_ms
        log(logger, "stt.session", **fields)
    return ws


def build_app(args) -> web.Application:
    app = web.Application()
    app["engine"] = Engine(args)
    app.router.add_get("/health", health)
    app.router.add_get("/v1/transcribe", transcribe)

    async def on_startup(app):
        app["loader"] = asyncio.create_task(app["engine"].start())

    app.on_startup.append(on_startup)
    return app


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--backend", default="parakeet", choices=["parakeet", "voxtral"])
    p.add_argument("--model", required=True, help="parakeet: GGUF file; voxtral: MLX snapshot directory")
    p.add_argument("--model-id", default="handy-computer/parakeet-unified-en-0.6b-gguf")
    p.add_argument("--revision", default="unknown")
    p.add_argument("--precision", default="Q8_0", help="reported in /health; voxtral: fp16 casts fp32 tensors")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8446)
    p.add_argument("--delay-ms", type=int, default=480, help="voxtral: decoder lag behind audio")
    p.add_argument("--threads", type=int, default=8, help="parakeet: CPU threads for transcribe.cpp")
    p.add_argument("--step-tokens", type=int, default=16, help="voxtral: max decode tokens per MLX step")
    p.add_argument("--cache-gb", type=float, default=1.0, help="voxtral: MLX buffer cache cap")
    p.add_argument("--no-partials", dest="partials", action="store_false",
                   help="parakeet: don't load the second model instance for ?partials=1 live words")
    p.add_argument("--partial-chunk-ms", type=int, default=160, help="parakeet partials: stream chunk")
    p.add_argument("--partial-right-ms", type=int, default=160, help="parakeet partials: stream lookahead")
    p.add_argument("--max-seconds", type=int, default=300)
    p.add_argument("--idle-timeout", type=float, default=30.0)
    p.add_argument("--warmup", help="16 kHz s16le PCM clip transcribed at startup")
    p.add_argument("--warmup-text", help="its expected transcript (self-test)")
    p.add_argument("--log-level", default="info")
    args = p.parse_args()
    args.api_key = os.environ.get("SPEECHD_STT_API_KEY", "")
    setup_logging("stt", args.log_level)
    log(logger, "server.starting", host=args.host, port=args.port, backend=args.backend, pid=os.getpid())
    web.run_app(build_app(args), host=args.host, port=args.port, print=None, handler_cancellation=True)


if __name__ == "__main__":
    main()
