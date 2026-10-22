import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import { WebSocket } from 'ws';
import { PCMResampler } from './open-voice-pcm.mjs';
import { speechSegments } from './open-voice-speech-text.mjs';

const need = (v, code = 'speech_transport_failure') => { if (!v) throw new Error(code); };
const failure = () => new Error('speech_transport_failure');
// Stable numeric terminal boundaries, never parsed from arbitrary peer text.
export const STT_TERMINAL = Object.freeze({ normal: 0, abort: 1, lifetime: 2, idle: 3,
  transport: 4, protocol: 5, peerError: 6, earlyClose: 7, abnormalClose: 8, operation: 9, cleanup: 10 });
// Exact public stt_server.py readiness/admission constants only. No regex,
// exception-name extraction or storage of an arbitrary upstream error body.
const STT_PEER_REASON = new Map([['speech recognition is loading', 1], ['speech recognition is warming', 2],
  ['speech recognition is error', 3], ['recognition busy: decode capacity exhausted', 4]]);
export const SPEECH_BOUNDS = Object.freeze({ frameBytes: 4800, wsPayloadBytes: 4096, transcriptBytes: 8192,
  maxInputSamples: 2160000, maxOutputBytes: 4320000, maxSourceBytes: 8640000,
  idleMs: 5000, lifetimeMs: 120000, bufferBudgetBytes: 196608 });
function deferred() {
  let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  promise.catch(() => {}); return { promise, resolve, reject };
}
function endpoint(value, kind) {
  const u = new URL(value);
  need(!u.username && !u.password && !u.hash && !u.search && (kind === 'stt' ? ['ws:', 'wss:'] : ['http:', 'https:']).includes(u.protocol), 'invalid_speech_endpoint');
  need(u.pathname === (kind === 'stt' ? '/v1/transcribe' : '/v1/audio/speech'), 'invalid_speech_endpoint');
  if (kind === 'stt') u.search = '?partials=1'; return u;
}
function headers(value = {}) {
  need(value && Object.keys(value).every(k => k === 'authorization'), 'invalid_speech_headers');
  need(value.authorization === undefined || typeof value.authorization === 'string' && /^[\x20-\x7e]{1,1024}$/.test(value.authorization), 'invalid_speech_headers');
  return { ...value };
}

// Pure health GETs on the configured origins; never opens recognition/synthesis.
// Contracts: speechd/stt_server.py health and speechd/tts_gateway.py health.
export async function speechHealth({ sttURL, ttsURL, sttHeaders, ttsHeaders }, { timeoutMs = 2000, inspect = false } = {}) {
  const probe = (value, kind, auth) => new Promise(resolve => {
    const url = endpoint(value, kind); url.protocol = url.protocol === 'wss:' ? 'https:' : url.protocol === 'ws:' ? 'http:' : url.protocol;
    url.pathname = '/health'; url.search = '';
    let bytes = 0, chunks = [], done = false;
    const finish = ready => { if (done) return; done = true; clearTimeout(timer); req.destroy(); resolve(ready); };
    const req = (url.protocol === 'https:' ? https : http).get(url, { headers: headers(auth), agent: false, maxHeaderSize: 2048 }, res => {
      if (res.statusCode !== 200 || res.headers.location || res.headers['content-encoding']) return finish(false);
      res.on('error', () => finish(false)); res.on('aborted', () => finish(false));
      res.on('data', chunk => { bytes += chunk.length; if (bytes > 16384) finish(false); else chunks.push(chunk); });
      res.on('end', () => {
        try {
          const b = JSON.parse(Buffer.concat(chunks));
          if (inspect) return finish(b);
          const healthy = o => o && !o.error && (!o.status || ['ok', 'ready'].includes(o.status))
            && (!o.model || !['loading', 'unloaded', 'warming', 'error', 'unknown'].includes(o.model))
            && o.busy !== true && (!Object.hasOwn(o, 'active_requests') || o.active_requests === 0);
          const ready = healthy(b) && b.status === 'ok' && b.service === kind && (kind === 'stt'
            ? typeof b.model === 'string' && b.model.length > 0 && b.active_sessions === 0
              && (b.model === 'loaded' ? b.worker_pid > 0 && b.active_requests === 0 && b.partials?.ready === true
                && b.partials.state === 'loaded' && b.partials.error === null
                : b.partials === undefined || b.partials.enabled === true && b.partials.slot_busy === false && !b.partials.error)
            : b.model === 'loaded' && b.busy === false && b.queued === 0 && healthy(b.upstream)
              && b.upstream.http_status === 200 && b.upstream.model === 'loaded');
          finish(ready === true);
        } catch { finish(false); }
      });
    });
    const timer = setTimeout(() => finish(false), timeoutMs);
    req.on('error', () => finish(false));
  });
  const [stt, tts] = await Promise.all([probe(sttURL, 'stt', sttHeaders), probe(ttsURL, 'tts', ttsHeaders)]);
  return { stt, tts };
}

// Owner contract09 pins, not CLI/model/env overrides. Gateway samples Breeze /health
// in this same bounded GET; inspect both identities and its fresh activity counters.
export const PREPARATION_SPEECH = Object.freeze({
  sttModel: 'handy-computer/parakeet-unified-en-0.6b-gguf',
  sttRevision: '7e948f21b7bdbac698d3318db9d350f1096f3b6c',
  ttsModel: 'Shoof/Gust-MLX', ttsRevision: 'dac391237f6bf6130b1c1d277f0ebc0b886e419e',
});
export function preparationSpeechState({ stt: s, tts: t }, config) {
  const unavailable = { ready: false, loadable: false };
  const p = PREPARATION_SPEECH, b = t?.upstream;
  if (config.sttURL !== 'ws://127.0.0.1:8446/v1/transcribe'
    || config.ttsURL !== 'http://127.0.0.1:8444/v1/audio/speech'
    // speech():259–314 never reads body.model. Preserve owner configuration's
    // nonempty request coordinate; backend identity is independently pinned below.
    || typeof config.model !== 'string' || !config.model.length || config.model.length > 128
    || /[\x00-\x1f\x7f]/.test(config.model) || config.model.toLowerCase() === 'auto'
    || typeof config.voice !== 'string' || !config.voice.length) return unavailable;
  // Match gateway resolve():174–180, without selecting/changing its saved default.
  const requestedVoice = config.voice.trim();
  const resolvedVoice = requestedVoice === 'default' ? t?.default_voice
    : requestedVoice === 'original' && Array.isArray(t?.voices) && t.voices.includes('female_a') ? 'female_a' : requestedVoice;
  if (!resolvedVoice || requestedVoice !== 'default' && (!Array.isArray(t?.voices) || !t.voices.includes(resolvedVoice))) return unavailable;
  const ok = o => o && o.status === 'ok' && !o.error && ['loaded', 'unloaded'].includes(o.model)
    && (o.model === 'unloaded' ? o.worker_pid === null : Number.isSafeInteger(o.worker_pid) && o.worker_pid > 0);
  if (!ok(s) || !ok(b) || s.service !== 'stt' || s.backend !== 'parakeet' || s.model_id !== p.sttModel
    || s.revision !== p.sttRevision || (s.precision !== undefined && s.precision !== 'Q8_0')
    || (s.runtime !== undefined && s.runtime !== 'transcribe.cpp') || s.active_requests !== 0 || s.active_sessions !== 0
    || s.partials?.enabled !== true
    || t?.status !== 'ok' || t.service !== 'tts' || t.error || t.backend !== 'breeze-tts2-fast-streaming-api (mlx)'
    || t.model_id !== p.ttsModel || t.revision !== p.ttsRevision || t.precision !== 'mixed' || t.default_voice !== 'mizuki'
    || t.busy !== false || t.queued !== 0 || b.http_status !== 200 || b.service !== 'breeze'
    || (b.model_id !== undefined && b.model_id !== p.ttsModel) || (b.revision !== undefined && b.revision !== p.ttsRevision)
    || (b.precision !== undefined && b.precision !== 'mixed')
    || (b.backend !== undefined && b.backend !== 'breeze-tts2-fast-streaming-api (mlx)')
    || b.active_requests !== 0 || t.model !== b.model) return unavailable;
  // Cold cached partial fields are not live native activity. Loaded partial errors
  // and incomplete initialization refuse rather than authorizing another load.
  if (s.model === 'loaded' && (s.precision !== 'Q8_0' || s.runtime !== 'transcribe.cpp'
    || s.partials?.ready !== true || s.partials.state !== 'loaded' || s.partials.error !== null)) return unavailable;
  const ready = s.model === 'loaded' && b.model === 'loaded';
  return { ready, loadable: !ready, observation: 'public_activity_snapshot_not_reservation' };
}
// A fixed documented net.Socket onread buffer caps each read at 8 KiB. The
// normal Readable path is explicitly fed exact-size, unpooled copies; it cannot
// retain an arbitrary 64-KiB backing slab through a tiny frame slice. HWM is only
// flow control; this explicit pre-copy check is the hard queue admission fence.
function boundedConnection(secure, observe) {
  return options => {
    let socket;
    const onread = { buffer: Buffer.alloc(8192), callback(n, buffer) {
      if (socket.destroyed) return false;
      if (n > 8192 || socket.readableLength + n > 8192) { socket.destroy(failure()); return false; }
      observe?.(n);
      const copy = Buffer.allocUnsafeSlow(n); buffer.copy(copy, 0, 0, n); return socket.push(copy);
    } };
    socket = (secure ? tls.connect : net.connect)({ ...options, path: undefined, onread, highWaterMark: 8192, autoSelectFamily: false });
    return socket;
  };
}
function speechAgent(secure, observe) {
  const agent = new (secure ? https.Agent : http.Agent)({ keepAlive: false, maxSockets: 1 });
  agent.createConnection = boundedConnection(secure, observe); return agent;
}
// One socket/reader per transport kind. A retired but not actually closed resource
// continues to occupy its slot. No unbounded allocation queue and no hidden retry.
export function createLocalSpeechAdapter({ sttURL, ttsURL, model, voice, sttHeaders, ttsHeaders,
  monoProfile, submit, idleMs = SPEECH_BOUNDS.idleMs, lifetimeMs = SPEECH_BOUNDS.lifetimeMs } = {}) {
  const stt = endpoint(sttURL, 'stt'), tts = endpoint(ttsURL, 'tts');
  const sh = headers(sttHeaders), th = headers(ttsHeaders);
  need([model, voice].every(v => typeof v === 'string' && v.length > 0 && v.length <= 128), 'invalid_speech_configuration');
  // This reviewed profile is explicitly bound to the injected owner endpoint,
  // never selected by a caller or inferred from an absent response header.
  need(monoProfile === undefined || monoProfile?.contract === 'speechd-mono-s16le-v1' && monoProfile.endpoint === tts.href
    && Object.keys(monoProfile).length === 2, 'invalid_speech_configuration');
  need(submit === undefined || typeof submit === 'function', 'invalid_speech_configuration');
  need(Number.isInteger(idleMs) && idleMs > 0 && idleMs <= 5000 && Number.isInteger(lifetimeMs) && lifetimeMs >= idleMs && lifetimeMs <= 120000);
  const active = { stt: 0, tts: 0 }; const peaks = { receiveChunkBytes: 0, httpBufferedBytes: 0 };
  const observe = n => { peaks.receiveChunkBytes = Math.max(peaks.receiveChunkBytes, n); };
  const acquire = kind => { need(!active[kind], 'speech_capacity'); active[kind]++; let released = false; return () => { if (!released) { released = true; active[kind]--; } }; };
  return Object.freeze({
    readyForCalls: typeof submit === 'function', bufferBudgetBytes: SPEECH_BOUNDS.bufferBudgetBytes,
    stats: () => ({ ...active }),
    bufferStats: () => ({ ...peaks }),
    async openSegment({ signal, onTerminal } = {}) {
      need(!signal?.aborted); const release = acquire('stt');
      let sink;
      try { sink = new Recognition(stt, sh, signal, { idleMs, lifetimeMs, observe, onTerminal }, release); } catch (e) { release(); throw e; }
      try { await sink.opened.promise; return sink; } catch (e) { await sink.close(); throw e; }
    },
    submit: submit || (() => { throw new Error('harness_unconfigured'); }),
    synthesize({ text, signal, format } = {}) {
      need(!signal?.aborted);
      need(!format || format.type === 'audio/pcm' && format.rate === 24000 && format.channels === 1, 'invalid_speech_format');
      const release = acquire('tts');
      try {
        need(typeof text === 'string' && text.length <= 6000);
        const segments = speechSegments(text, 6000);
        return new Narration(tts, th, { model, voice, monoProfile: monoProfile !== undefined, idleMs, lifetimeMs, observe, peaks }, segments, signal, release);
      } catch (e) { release(); throw e; }
    },
  });
}

class Recognition {
  constructor(url, auth, signal, limits, release) {
    Object.assign(this, { signal, release, limits, stable: '', partial: '', events: 0, input: 0, written: 0, ended: false, busy: false });
    this.converter = new PCMResampler(24000, 16000); this.opened = deferred(); this.closed = deferred();
    this.agent = speechAgent(url.protocol === 'wss:', limits.observe);
    this.ws = new WebSocket(url, { headers: auth, followRedirects: false, perMessageDeflate: false, autoPong: false,
      maxPayload: SPEECH_BOUNDS.wsPayloadBytes, maxFragments: 1, maxBufferedChunks: 16, maxHeaderSize: 2048,
      agent: this.agent, handshakeTimeout: limits.idleMs });
    this.abort = () => this.stop(STT_TERMINAL.abort); signal?.addEventListener('abort', this.abort, { once: true });
    this.timer = setTimeout(() => this.stop(STT_TERMINAL.lifetime), limits.lifetimeMs);
    this.touch();
    this.ws.on('open', () => { if (signal?.aborted || this.error) this.stop(); else { this.touch(); this.opened.resolve(); } });
    this.ws.on('error', () => this.stop(STT_TERMINAL.transport));
    this.ws.on('ping', data => {
      if (++this.events > 4096 || this.ws.bufferedAmount + data.length + 14 > 9600) this.stop();
      else this.ws.pong(data, e => { if (e) this.stop(); });
    });
    this.ws.on('pong', () => { if (++this.events > 4096) this.stop(); });
    this.ws.on('message', (data, binary) => {
      try {
        need(!binary && ++this.events <= 4096 && data.length <= SPEECH_BOUNDS.wsPayloadBytes);
        const event = JSON.parse(data.toString('utf8'));
        if (event.type === 'error' && typeof event.message === 'string'
          && Object.keys(event).length === 2) {
          if (this.terminalCause === undefined) this.peerReason = STT_PEER_REASON.get(event.message) ?? 0;
          this.stop(STT_TERMINAL.peerError); return;
        }
        need(['transcript', 'transcript.partial'].includes(event.type) && typeof event.text === 'string' && !/[\uD800-\uDFFF]/u.test(event.text));
        need(Buffer.byteLength(event.text) <= SPEECH_BOUNDS.transcriptBytes);
        if (event.type === 'transcript.partial') this.partial = event.text;
        else { need(Buffer.byteLength(this.stable) + Buffer.byteLength(event.text) <= SPEECH_BOUNDS.transcriptBytes); this.stable += event.text; this.partial = ''; }
        // Partial hypotheses never become stable/final text.
      } catch { this.stop(STT_TERMINAL.protocol); }
    });
    this.ws.on('close', code => {
      clearTimeout(this.timer); clearTimeout(this.idle); signal?.removeEventListener('abort', this.abort);
      if (!this.ended || code !== 1000 || signal?.aborted) this.error ||= failure();
      this.terminalCause ??= signal?.aborted ? STT_TERMINAL.abort : !this.ended ? STT_TERMINAL.earlyClose
        : code !== 1000 ? STT_TERMINAL.abnormalClose : STT_TERMINAL.normal;
      try { limits.onTerminal?.(Object.freeze({ cause: this.terminalCause, endSent: Number(this.endSent === true),
        peerReason: this.peerReason ?? 0, closeCode: code, inputBytes: this.input * 2, writtenBytes: this.written })); } catch { /* Diagnostic failure cannot delay cleanup. */ }
      this.opened.reject(this.error || failure()); this.agent.destroy(); this.closed.resolve();
    });
    if (signal?.aborted) this.stop(STT_TERMINAL.abort);
  }
  touch() { clearTimeout(this.idle); if (this.ws.readyState !== WebSocket.CLOSED) this.idle = setTimeout(() => this.stop(STT_TERMINAL.idle), this.limits.idleMs); }
  stop(cause = STT_TERMINAL.operation) { this.terminalCause ??= cause; this.error ||= failure(); this.opened.reject(this.error); this.ws.terminate(); }
  async exclusive(fn) {
    need(!this.busy && !this.error && !this.ended); this.busy = true;
    try { return await fn(); } catch (e) { this.stop(); throw e; } finally { this.busy = false; }
  }
  async send(data) {
    need(!this.error && !this.signal?.aborted && this.ws.readyState === WebSocket.OPEN && this.ws.bufferedAmount + Buffer.byteLength(data) <= 9600);
    this.touch();
    await new Promise((resolve, reject) => this.ws.send(data, e => e ? reject(failure()) : resolve()));
    if (Buffer.isBuffer(data)) this.written += data.length; // Socket callback, not remote receipt/recognition.
    else this.endSent = true;
    need(!this.error && !this.signal?.aborted);
  }
  write(pcm) {
    return this.exclusive(async () => {
      need(Buffer.isBuffer(pcm) && pcm.length > 0 && pcm.length % 2 === 0 && pcm.length <= SPEECH_BOUNDS.frameBytes);
      need(this.input + pcm.length / 2 <= SPEECH_BOUNDS.maxInputSamples); this.input += pcm.length / 2;
      for (const frame of this.converter.push(pcm)) await this.send(frame);
    });
  }
  finish() {
    return this.exclusive(async () => {
      for (const frame of this.converter.finish()) await this.send(frame);
      this.ended = true; await this.send(JSON.stringify({ type: 'input_audio.end' })); this.touch();
      await this.closed.promise; need(!this.error);
      return { normal: true, transcript: this.stable.trim() };
    });
  }
  close() {
    if (!this.cleanup) {
      this.converter.discard(); if (this.ws.readyState !== WebSocket.CLOSED) this.stop(STT_TERMINAL.cleanup);
      this.cleanup = this.closed.promise.then(() => { this.stable = ''; this.partial = ''; this.release(); });
    }
    return this.cleanup;
  }
}

// Explicit iterator rather than async-generator return(): return/abort destroys
// a currently blocked HTTP read immediately, then waits for actual socket close.
class Narration {
  constructor(url, auth, config, segments, signal, release) {
    Object.assign(this, { url, auth, config, segments, signal, release, index: 0, output: 0, source: 0, pending: [], closed: false, busy: false });
    this.abort = () => { this.cancel().catch(() => {}); }; signal?.addEventListener('abort', this.abort, { once: true });
    this.timer = setTimeout(() => {
      if (this.closed) return; // Earlier explicit cancel/return or actual EOF wins.
      this.error ||= Object.assign(new Error('speech_timeout'), { code: 'speech_timeout' });
      this.cancel().catch(() => {});
    }, config.lifetimeMs); if (signal?.aborted) this.abort();
  }
  [Symbol.asyncIterator]() { return this; }
  async next() {
    // Failure is terminal state, not EOF. In particular, credit-paused callers
    // may pull only AFTER timeout cleanup has already closed the HTTP socket.
    if (this.error) { await this.cancel(); throw this.error; }
    need(!this.busy); if (this.closed) return { done: true }; this.busy = true;
    try {
      while (!this.closed) {
        need(!this.signal?.aborted);
        if (this.pending.length) {
          const value = this.pending.shift(); this.output += value.length;
          need(this.output <= SPEECH_BOUNDS.maxOutputBytes); return { done: false, value };
        }
        if (!this.reader) {
          if (this.index === this.segments.length) { await this.cancel(); return { done: true }; }
          this.reader = new SpeechReader(this.url, this.auth, this.config, this.segments[this.index++]);
          await this.reader.ready.promise; need(!this.closed && !this.signal?.aborted);
          this.converter = new PCMResampler(this.reader.rate, 24000);
        }
        const chunk = await this.reader.read(); need(!this.closed && !this.signal?.aborted);
        if (chunk === null) {
          this.pending = this.converter.finish(); await this.reader.close(); this.reader = null;
        } else {
          this.source += chunk.length; need(this.source <= SPEECH_BOUNDS.maxSourceBytes);
          this.pending = this.converter.push(chunk);
        }
      }
      throw failure();
    } catch (e) {
      if (!this.closed) this.error ||= e;
      await this.cancel(); throw this.error || e;
    } finally { this.busy = false; }
  }
  async cancel() {
    if (this.cleanup) return this.cleanup;
    this.closed = true; clearTimeout(this.timer); this.signal?.removeEventListener('abort', this.abort);
    this.pending = []; this.segments = []; this.converter?.discard(); this.converter = null;
    this.cleanup = Promise.resolve(this.reader?.close()).finally(() => { this.reader = null; this.release(); }); return this.cleanup;
  }
  async return() { await this.cancel(); return { done: true }; }
}

class SpeechReader {
  constructor(url, auth, config, text) {
    this.ready = deferred(); this.closed = deferred(); this.limits = config;
    const json = JSON.stringify({ model: config.model, voice: config.voice, input: text, response_format: 'pcm' });
    const body = Buffer.allocUnsafeSlow(Buffer.byteLength(json)); body.write(json);
    this.agent = speechAgent(url.protocol === 'https:', config.observe);
    this.req = (url.protocol === 'https:' ? https : http).request(url, { method: 'POST', agent: this.agent,
      highWaterMark: 8192, maxHeaderSize: 2048,
      headers: { ...auth, 'content-type': 'application/json', 'content-length': body.length } });
    this.req.on('socket', socket => { this.socket = socket; socket.on('close', () => { this.closed.resolve(); this.wake?.(); }); });
    this.req.on('error', () => this.fail());
    this.req.on('close', () => { clearTimeout(this.timer); if (!this.socket) this.closed.resolve(); this.wake?.(); });
    this.req.on('response', res => {
      this.res = res; res.on('error', () => this.fail()); res.on('aborted', () => this.fail());
      res.on('readable', () => {
        config.peaks.httpBufferedBytes = Math.max(config.peaks.httpBufferedBytes, res.readableLength);
        if (res.readableLength > 16384) this.fail(); this.wake?.();
      }); res.on('end', () => this.wake?.()); res.on('close', () => this.wake?.());
      try {
        need(res.statusCode === 200 && res.headers['content-type'] === 'audio/pcm' && res.headers['x-sample-format'] === 's16le');
        need(res.headers['x-channels'] === '1' || res.headers['x-channels'] === undefined && config.monoProfile === true);
        need(Object.keys(res.headers).filter(k => k.includes('channel')).every(k => k === 'x-channels'));
        need(/^(16000|22050|24000|44100|48000)$/.test(res.headers['x-sample-rate'] || ''));
        for (const key of ['content-type', 'x-sample-rate', 'x-sample-format', 'x-channels']) need(res.rawHeaders.filter((_, i) => i % 2 === 0).filter(k => k.toLowerCase() === key).length <= 1);
        need(!res.headers['content-encoding'] && !res.headers.location);
        this.rate = Number(res.headers['x-sample-rate']); this.ready.resolve();
      } catch { this.fail(); }
    });
    this.touch(); this.req.end(body);
  }
  touch() { clearTimeout(this.timer); this.timer = setTimeout(() => this.fail(), this.limits.idleMs); }
  fail() { this.error ||= failure(); this.ready.reject(this.error); this.req?.destroy(); this.res?.destroy(); this.wake?.(); }
  async read() {
    this.touch();
    for (;;) {
      need(!this.error);
      const data = this.res.read(Math.min(SPEECH_BOUNDS.frameBytes, this.res.readableLength || SPEECH_BOUNDS.frameBytes));
      if (data) { need(data.length <= SPEECH_BOUNDS.frameBytes); return data; }
      if (this.res.readableEnded) { need(this.res.complete && Object.keys(this.res.trailers).length === 0); return null; }
      need(!this.res.destroyed);
      await new Promise(resolve => { this.wake = resolve; }); this.wake = null;
    }
  }
  close() {
    if (!this.cleanup) {
      this.fail(); clearTimeout(this.timer); this.agent.destroy();
      this.cleanup = this.closed.promise.then(() => { this.req = null; this.res = null; this.socket = null; this.agent = null; });
    }
    return this.cleanup;
  }
}
