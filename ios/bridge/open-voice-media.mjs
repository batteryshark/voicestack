import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { createSession, validateClientEvent, validateServerEvent, ERROR_CODES, LIMITS } from './open-voice-profile.mjs';

const id = prefix => prefix + '_' + crypto.randomUUID().replaceAll('-', '');
const fail = (code = 'local_failure') => { throw Object.assign(new Error(code), { code }); };
const need = (v, code = 'invalid_request') => { if (!v) fail(code); };
const wireError = (code = 'local_failure') => ({ type: code === 'local_failure' ? 'server_error' : 'invalid_request_error', code, message: ERROR_CODES[code], param: null });
const item = (id, role, status, content) => ({ id, object: 'realtime.item', type: 'message', role, status, content });
export const MEDIA_PATH = '/floating-voice/v1/realtime?model=local-chain-m1';
export const MEDIA_CLOSE = Object.freeze({ internal: 0, peer: 1, transport: 2, authority: 3,
  protocol: 4, input: 5, owner: 6 });
export const MEDIA_BOUNDS = Object.freeze({ maxAdapterJobs: 8, maxPendingUpgrades: 4, maxQueuedEvents: 32,
  maxQueuedJSONBytes: 128000, maxEventsPerSecond: 200, stallMs: 15000, authorityMs: 1000,
  closeMs: 250, pongMs: 30000, pingAfterMs: 10000, maxItems: 256 });

// A slot belongs to the underlying job, NOT to a timeout/cancellation race.
class Jobs {
  pending = new Set();
  run(fn) {
    need(this.pending.size < MEDIA_BOUNDS.maxAdapterJobs);
    const p = Promise.resolve().then(fn); this.pending.add(p);
    p.finally(() => this.pending.delete(p)).catch(() => {}); return p;
  }
  own(create, dispose) { return new OwnedJob(this, create, dispose); }
}
// One admitted resource slot spans allocation, one pending operation and retirement.
// Cleanup uses that SAME slot even at capacity; it is never a ninth queued job.
class OwnedJob {
  constructor(pool, create, dispose) {
    need(pool.pending.size < MEDIA_BOUNDS.maxAdapterJobs);
    Object.assign(this, { pool, dispose }); pool.pending.add(this);
    this.done = new Promise((resolve, reject) => { this.resolve = resolve; this.reject = reject; }); this.done.catch(() => {});
    this.ready = Promise.resolve().then(create).then(value => {
      this.value = value; this.allocated = true;
      if (this.retired) this.cleanup(); return value;
    }, error => { this.allocationFailed = true; this.release(); throw error; });
    this.ready.catch(() => {});
  }
  invoke(fn) {
    need(!this.retired && !this.operation);
    const work = this.ready.then(value => { need(!this.retired); return fn(value); }); this.operation = work;
    work.finally(() => { if (this.operation === work) this.operation = null; this.release(); }).catch(() => {});
    return work;
  }
  retire() {
    if (!this.retired) { this.retired = true; if (this.allocated) this.cleanup(); }
    this.release(); return this.done;
  }
  cleanup() {
    if (this.cleanupStarted) return; this.cleanupStarted = true;
    Promise.resolve().then(() => this.dispose(this.value)).then(() => {
      this.cleaned = true; this.release();
    }, error => { this.cleanupError = error; this.cleaned = true; this.release(); });
  }
  release() {
    if (this.released || !this.allocationFailed && (!this.retired || !this.cleaned || this.operation)) return;
    this.released = true; this.pool.pending.delete(this);
    if (this.cleanupError) this.reject(this.cleanupError); else this.resolve();
  }
}
function bounded(p, signal, ms) {
  return new Promise((resolve, reject) => {
    const abort = () => finish(reject, new Error('cancelled'));
    const timer = setTimeout(() => finish(reject, new Error('stalled')), ms);
    const finish = (fn, value) => { clearTimeout(timer); signal?.removeEventListener('abort', abort); fn(value); };
    if (signal?.aborted) abort();
    else { signal?.addEventListener('abort', abort, { once: true }); Promise.resolve(p).then(v => finish(resolve, v), e => finish(reject, e)); }
    // Even an already-aborted race must observe a late rejection.
    Promise.resolve(p).catch(() => {});
  });
}

/** Injected adapter only. Concrete speech transports never configure a harness. */
export class OpenVoiceMedia {
  constructor({ control, adapter, stallMs = MEDIA_BOUNDS.stallMs, authorityMs = MEDIA_BOUNDS.authorityMs, onSessionClosed = () => {}, diagnostic = () => {} }) {
    need(control && typeof adapter?.openSegment === 'function' && typeof adapter.submit === 'function' && typeof adapter.synthesize === 'function');
    const adapterBufferBytes = adapter.bufferBudgetBytes === undefined ? 0 : adapter.bufferBudgetBytes;
    need(Number.isSafeInteger(adapterBufferBytes) && adapterBufferBytes >= 0
      && adapterBufferBytes + 2 * LIMITS.maxMessageBytes + 8 * LIMITS.maxFrameBytes <= LIMITS.maxAggregateBytes);
    need(Number.isInteger(stallMs) && stallMs > 0 && stallMs <= 15000 && Number.isInteger(authorityMs) && authorityMs > 0 && authorityMs <= 1000);
    Object.assign(this, { control, adapter, adapterBufferBytes, stallMs, authorityMs, onSessionClosed, diagnostic });
    this.jobs = new Jobs(); this.sessions = new Map(); this.pendingUpgrades = 0; this.closed = false;
    this.inputPCMBytes = 0; this.inputPeakBytes = 0; this.rawBytes = 0; this.acceptedInputSamples = 0; this.aggregatePeakBytes = 0;
    this.wss = new WebSocketServer({ noServer: true, clientTracking: false, perMessageDeflate: false, maxPayload: LIMITS.maxMessageBytes });
    this.wss.on('error', () => {});
  }
  available() { return !this.closed; }
  fence({ call_id, media_epoch }) {
    const s = this.sessions.get(call_id); if (s?.epoch === media_epoch) s.close(1008, MEDIA_CLOSE.authority);
  }
  async upgrade(req, socket, head) {
    socket.on('error', () => {});
    if (this.closed || this.pendingUpgrades >= MEDIA_BOUNDS.maxPendingUpgrades) { socket.destroy(); return; }
    this.pendingUpgrades++;
    const deadline = setTimeout(() => socket.destroy(), 3000);
    try {
      need(req.url === MEDIA_PATH && req.method === 'GET' && req.headers.origin === undefined && req.headers['sec-websocket-protocol'] === undefined
        && req.headers.upgrade?.toLowerCase() === 'websocket'
        && req.headers['sec-websocket-version'] === '13' && /^[A-Za-z0-9+/]{22}==$/.test(req.headers['sec-websocket-key'] || ''));
      const token = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.authorization || '')?.[1]; need(token);
      const attachment = await this.control.attach(token); need(!socket.destroyed && !this.closed);
      this.control.currentAuthority(attachment.call_id, attachment.media_epoch);
      this.wss.handleUpgrade(req, socket, head, ws => {
        const s = new MediaSession(this, ws, attachment); this.sessions.set(s.callID, s);
        try { s.start(); } catch { s.close(1011); }
      });
    } catch { if (!socket.destroyed) socket.end('HTTP/1.1 403 Refused\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); }
    finally { clearTimeout(deadline); this.pendingUpgrades--; }
  }
  close() { this.closed = true; for (const s of [...this.sessions.values()]) s.close(1001, MEDIA_CLOSE.owner); this.wss.close(); }
  // Two bounded receiver/parser scratch allowances cover the wire buffer and
  // transient receive-order inspection while the validated payload is retained.
  recordBufferPeak() { this.aggregatePeakBytes = Math.max(this.aggregatePeakBytes, this.rawBytes + this.inputPCMBytes + this.adapterBufferBytes + 2 * LIMITS.maxMessageBytes + 8 * LIMITS.maxFrameBytes); }
  reserveRaw(n) { need(this.rawBytes + n + this.inputPCMBytes + this.adapterBufferBytes + 2 * LIMITS.maxMessageBytes + 8 * LIMITS.maxFrameBytes <= LIMITS.maxAggregateBytes); this.rawBytes += n; this.recordBufferPeak(); }
  reservePCM(n) {
    need(this.inputPCMBytes + n <= LIMITS.maxQueueBytes
      && this.rawBytes + this.inputPCMBytes + n + this.adapterBufferBytes + 2 * LIMITS.maxMessageBytes + 8 * LIMITS.maxFrameBytes <= LIMITS.maxAggregateBytes);
    this.inputPCMBytes += n; this.inputPeakBytes = Math.max(this.inputPeakBytes, this.inputPCMBytes); this.recordBufferPeak();
  }
  releaseFrame(frame) {
    if (!frame.released) { frame.released = true; frame.pcm = null; this.inputPCMBytes -= frame.bytes; }
  }
  stats() { return { sessions: this.sessions.size, pendingJobs: this.jobs.pending.size, pendingUpgrades: this.pendingUpgrades,
    inputPCMBytes: this.inputPCMBytes, inputPeakBytes: this.inputPeakBytes, rawBytes: this.rawBytes, acceptedInputSamples: this.acceptedInputSamples, aggregatePeakBytes: this.aggregatePeakBytes }; }
}

class MediaSession {
  constructor(engine, ws, attachment) {
    Object.assign(this, { engine, ws, callID: attachment.call_id, epoch: attachment.media_epoch, binding: Object.freeze(attachment.binding) });
    this.sessionID = id('sess'); this.effective = createSession(this.sessionID).value;
    this.alive = true; this.configured = false; this.queue = []; this.queueBytes = 0; this.running = false;
    this.received = 0; this.consumed = 0; this.itemHashes = new Map(); this.previousItem = null;
    this.segments = new Set(); this.recognitionTail = Promise.resolve();
    this.lifetime = new AbortController(); this.rate = { at: Date.now(), count: 0 }; this.pongAt = Date.now();
    this.lastPingAt = Date.now();
    this.diagnosticSequence = 0; this.segmentOrdinal = 0; this.startedAt = performance.now();
  }
  diagnostic(stage, fields) {
    try { this.engine.diagnostic({ stage, call_id: this.callID, media_epoch: this.epoch,
      sequence: ++this.diagnosticSequence, elapsedMs: Math.round(performance.now() - this.startedAt), ...fields }); }
    catch { /* Never affect authority, media or resource settlement for diagnostics. */ }
  }
  authority(ready = false) {
    need(this.alive);
    this.engine.control.currentAuthority(this.callID, this.epoch);
    if (ready) { need(this.configured, 'context_required'); this.engine.control.readyAuthority(this.callID, this.epoch, this.sessionID); }
  }
  start() {
    this.engine.control.registerMediaSession(this.callID, this.epoch, this.sessionID, () => this.alive && this.ws.readyState === WebSocket.OPEN);
    this.ws.on('error', () => this.close(1008, MEDIA_CLOSE.transport));
    this.ws.on('close', code => this.close(undefined, MEDIA_CLOSE.peer, code));
    this.ws.on('pong', () => { this.pongAt = Date.now(); });
    this.ws.on('ping', () => { if (!this.rateOK()) this.close(1008, MEDIA_CLOSE.protocol); });
    this.ws.on('message', (data, binary) => this.receive(data, binary));
    this.timer = setInterval(() => {
      let cause = MEDIA_CLOSE.authority;
      try {
        this.authority(); cause = MEDIA_CLOSE.transport; need(Date.now() - this.pongAt < MEDIA_BOUNDS.pongMs);
        if (Date.now() - this.lastPingAt >= MEDIA_BOUNDS.pingAfterMs) {
          need(this.ws.bufferedAmount + 128 <= LIMITS.maxWritableBytes); this.lastPingAt = Date.now(); this.ws.ping();
        }
      } catch { this.close(1008, cause); }
    }, this.engine.authorityMs); this.timer.unref();
    this.send({ type: 'session.created', session: this.effective });
  }
  rateOK() {
    if (Date.now() - this.rate.at >= 1000) this.rate = { at: Date.now(), count: 0 };
    return ++this.rate.count <= MEDIA_BOUNDS.maxEventsPerSecond;
  }
  send(event, written = false) {
    this.authority(); const e = { event_id: id('evt'), ...event };
    need(validateServerEvent(e).ok);
    const json = JSON.stringify(e), bytes = Buffer.byteLength(json);
    need(bytes <= LIMITS.maxMessageBytes && this.ws.bufferedAmount + bytes + 14 <= LIMITS.maxWritableBytes);
    if (!written) { this.ws.send(json, err => { if (err) this.close(1011, MEDIA_CLOSE.transport); }); return; }
    return bounded(new Promise((resolve, reject) => this.ws.send(json, err => err ? reject(err) : resolve())), this.lifetime.signal, this.engine.stallMs);
  }
  error(code = 'invalid_request', event_id) {
    try { this.send({ type: 'error', error: { ...wireError(code), ...(event_id ? { event_id } : {}) } }); } catch { this.close(1008); }
  }
  receive(data, binary) {
    if (!this.alive) return;
    if (binary || !this.rateOK() || data.length > LIMITS.maxMessageBytes) { this.close(binary ? 1003 : 1009, MEDIA_CLOSE.protocol); return; }
    const raw = data.length * 2; // Owned text + parsed payload; retain charge through any await.
    try { this.engine.reserveRaw(raw); } catch { this.close(1009, MEDIA_CLOSE.input); return; }
    const text = data.toString('utf8');
    let peek; try { peek = JSON.parse(text); } catch { this.engine.rawBytes -= raw; this.close(1008, MEDIA_CLOSE.protocol); return; }
    // PCM admission/commit/clear are synchronous receive-order transactions. Never
    // queue old append text for a later generation after a priority clear.
    if (['input_audio_buffer.append','input_audio_buffer.commit','input_audio_buffer.clear'].includes(peek?.type)) {
      try { this.inputEvent(text, peek); } finally { this.engine.rawBytes -= raw; } return;
    }
    if (['vs.playback', 'response.cancel', 'conversation.item.truncate'].includes(peek?.type)) {
      this.handle(text).catch(() => this.error()).finally(() => { this.engine.rawBytes -= raw; }); return;
    }
    if (this.queue.length >= MEDIA_BOUNDS.maxQueuedEvents || this.queueBytes + data.length > MEDIA_BOUNDS.maxQueuedJSONBytes) { this.engine.rawBytes -= raw; this.close(1009, MEDIA_CLOSE.input); return; }
    this.queue.push({ text, bytes: data.length, raw }); this.queueBytes += data.length; this.pump();
  }
  async pump() {
    if (this.running) return; this.running = true;
    try {
      while (this.alive && this.queue.length) {
        const entry = this.queue.shift();
        try { await this.handle(entry.text); } catch { if (this.alive) this.error('local_failure'); }
        finally { this.queueBytes = Math.max(0, this.queueBytes - entry.bytes); this.engine.rawBytes -= entry.raw; }
      }
    } finally { this.running = false; }
  }
  async handle(text) {
    this.authority();
    const v = validateClientEvent(text, { effectiveSession: this.effective, bufferSamples: this.segment?.samples ?? 0,
      canonicalItem: this.canonical, activeResponseId: this.response?.active ? this.response.id : undefined,
      truncateTarget: this.response?.itemID ? { item_id: this.response.itemID, generatedSamples: this.response.sent } : undefined });
    if (!v.ok) {
      if (['invalid_json', 'message_too_large', 'invalid_audio'].includes(v.error.code)) { this.close(1008, MEDIA_CLOSE.protocol); return; }
      this.error(v.error.code, v.error.event_id); return;
    }
    const e = v.value;
    if (e.type === 'session.update') {
      this.effective = v.effect.session; this.send({ type: 'session.updated', session: this.effective });
      this.engine.control.effectiveConfigured(this.callID, this.epoch, this.sessionID); this.configured = true;
      if (!this.initialFlow) { this.initialFlow = true; this.send({ type: 'vs.flow', media_epoch: String(this.epoch), input_consumed_samples: 0 }); }
      return;
    }
    try { this.authority(true); } catch { this.error('context_required', e.event_id); return; }
    try { switch (e.type) {
      case 'conversation.item.create': return this.compose(e.item);
      case 'response.create': return this.respond(e);
      case 'response.cancel': this.cancel(); return;
      case 'vs.playback': return this.playback(e);
      case 'conversation.item.truncate': {
        const r = this.response;
        need(e.audio_end_ms <= Math.floor(r.rendered / 24), 'invalid_position');
        r.truncated = e.audio_end_ms;
        r.text = ''; if (r.finalItem?.content[0]?.type === 'output_audio') r.finalItem.content[0].transcript = '';
        this.send({ type: 'conversation.item.truncated', item_id: e.item_id, content_index: 0, audio_end_ms: e.audio_end_ms }); return;
      }
    } } catch (err) { this.error(typeof err.code === 'string' && Object.hasOwn(ERROR_CODES, err.code) ? err.code
      : err.status === 409 && e.type === 'response.create' ? 'operation_conflict' : 'local_failure', e.event_id); }
  }
  remember(itemID, value) {
    const hash = crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
    const old = this.itemHashes.get(itemID);
    if (old) { need(old === hash, 'item_mismatch'); return false; }
    need(this.itemHashes.size < MEDIA_BOUNDS.maxItems); this.itemHashes.set(itemID, hash); return true;
  }
  compose(value) {
    if (this.remember(value.id, value)) {
      const i = item(value.id, 'user', 'completed', value.content);
      this.send({ type: 'conversation.item.added', previous_item_id: this.previousItem, item: i });
      this.send({ type: 'conversation.item.done', previous_item_id: this.previousItem, item: i }); this.previousItem = value.id;
    }
    this.canonical = value;
  }
  inputEvent(text, peek) {
    let reservation = 0;
    try {
      try { this.authority(true); } catch { this.error('context_required'); return; }
      if (peek.type === 'input_audio_buffer.append') {
        need(typeof peek.audio === 'string' && peek.audio.length > 0 && peek.audio.length <= 6400
          && /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(peek.audio), 'invalid_audio');
        const bytes = peek.audio.length / 4 * 3 - (peek.audio.endsWith('==') ? 2 : peek.audio.endsWith('=') ? 1 : 0);
        need(bytes > 0 && bytes % 2 === 0 && bytes <= LIMITS.maxFrameBytes, 'invalid_audio');
        // Reserve BEFORE the shared validator's temporary PCM decode. Once it
        // returns, no reference to that temporary survives; the SAME reservation
        // then owns the FIFO frame, with no unaccounted retained decoded copy.
        this.engine.reservePCM(bytes); reservation = bytes;
      }
      const v = validateClientEvent(text, { bufferSamples: this.segment?.samples ?? 0 });
      if (!v.ok) {
        if (reservation || ['invalid_json','invalid_audio','message_too_large'].includes(v.error.code)) this.close(1008, MEDIA_CLOSE.protocol);
        else this.error(v.error.code, v.error.event_id);
        return;
      }
      if (peek.type === 'input_audio_buffer.append') {
        let s = this.segment;
        if (!s) s = this.newSegment();
        need(!s.committed && s.samples + v.effect.samples <= LIMITS.maxSegmentSamples);
        need(this.received + v.effect.samples - this.consumed <= LIMITS.windowSamples);
        const frame = { pcm: Buffer.from(v.value.audio, 'base64'), bytes: reservation };
        s.frames.push(frame); reservation = 0; s.samples += v.effect.samples;
        // Truthful handoff into the REAL bounded STT-ingress FIFO, not recognition
        // or remote write completion. Clear NEVER fabricates or repeats credit.
        this.received += v.effect.samples; this.consumed += v.effect.samples; this.engine.acceptedInputSamples += v.effect.samples;
        this.send({ type: 'vs.flow', media_epoch: String(this.epoch), input_consumed_samples: this.consumed }); s.wake?.();
      } else if (peek.type === 'input_audio_buffer.clear') {
        this.clear(); this.send({ type: 'input_audio_buffer.cleared' });
      } else this.commit(); // Capture commit in receive order before any later clear.
    } catch (error) { this.close(error.code === 'invalid_audio' ? 1008 : 1009, MEDIA_CLOSE.input); }
    finally { if (reservation) this.engine.inputPCMBytes -= reservation; }
  }
  newSegment() {
    const s = { id: id('segment'), ordinal: ++this.segmentOrdinal, samples: 0, frames: [], abort: new AbortController(), committed: false };
    const prior = this.recognitionTail;
    s.resource = this.engine.jobs.own(async () => {
      await prior; this.authority(true); need(!s.abort.signal.aborted);
      const sink = await this.engine.adapter.openSegment({ call_id: this.callID, binding: this.binding, segment_id: s.id, signal: s.abort.signal,
        onTerminal: value => {
          if (s.terminalRecorded) return; s.terminalRecorded = true;
          // Copy ONLY closed numeric adapter fields. Never spread adapter/peer data.
          const fields = ['cause', 'peerReason', 'endSent', 'closeCode', 'inputBytes', 'writtenBytes'];
          if (!value || !fields.every(k => Number.isSafeInteger(value[k]) && value[k] >= 0)
            || value.cause > 10 || value.peerReason > 4 || value.endSent > 1 || value.closeCode > 4999
            || value.inputBytes > 4320000 || value.writtenBytes > 2880000) return;
          this.diagnostic('open_voice_stt', { category: value.cause === 0 ? 'complete' : 'failed', segment: s.ordinal,
            cause: value.cause, peerReason: value.peerReason, endSent: value.endSent, closeCode: value.closeCode,
            inputBytes: value.inputBytes, writtenBytes: value.writtenBytes });
        } });
      return sink; // Late sinks are still observed/retired by the SAME owned slot.
    }, sink => sink?.close?.());
    this.segment = s; this.segments.add(s);
    s.resource.done.finally(() => this.segments.delete(s)).catch(() => {});
    this.recognitionTail = this.driveSegment(s).catch(() => { if (this.alive) this.close(1011); });
    return s;
  }
  dropQueued(s) { for (const frame of s.frames.splice(0)) this.engine.releaseFrame(frame); }
  retireSegment(s) {
    s.abort.abort(); this.dropQueued(s); s.wake?.(); s.resource.retire().catch(() => {});
  }
  clear() {
    const s = this.segment; this.segment = null;
    if (s) this.retireSegment(s); // Only the current uncommitted generation.
  }
  waitInput(s) {
    return new Promise(resolve => {
      const wake = () => { s.abort.signal.removeEventListener('abort', wake); if (s.wake === wake) s.wake = null; resolve(); };
      s.wake = wake; s.abort.signal.addEventListener('abort', wake, { once: true }); if (s.abort.signal.aborted) wake();
    });
  }
  commit() {
    const s = this.segment; need(s?.samples > 0); this.segment = null; s.committed = true;
    const itemID = id('item'), previous = this.previousItem; this.remember(itemID, s.id); this.previousItem = itemID;
    Object.assign(s, { itemID, previous });
    this.send({ type: 'input_audio_buffer.committed', item_id: itemID, previous_item_id: previous });
    this.send({ type: 'conversation.item.added', previous_item_id: previous, item: item(itemID, 'user', 'in_progress', [{ type: 'input_audio', transcript: '' }]) });
    s.wake?.();
  }
  async driveSegment(s) {
    try {
      const sink = await bounded(s.resource.ready, s.abort.signal, this.engine.stallMs);
      need(typeof sink?.write === 'function' && typeof sink.finish === 'function');
      while (!s.abort.signal.aborted) {
        const frame = s.frames.shift();
        if (frame) {
          const write = s.resource.invoke(value => { this.authority(true); need(!s.abort.signal.aborted); return value.write(frame.pcm); });
          // Release only on ACTUAL settlement, not on abort/timeout winning its race.
          write.finally(() => this.engine.releaseFrame(frame)).catch(() => {});
          await bounded(write, s.abort.signal, this.engine.stallMs);
        } else if (s.committed) break;
        else await this.waitInput(s);
      }
      need(!s.abort.signal.aborted);
      const result = await bounded(s.resource.invoke(value => { this.authority(true); return value.finish(); }), s.abort.signal, this.engine.stallMs);
      this.authority(true); need(!s.abort.signal.aborted && result?.normal === true && typeof result.transcript === 'string');
      const completed = { type: 'conversation.item.input_audio_transcription.completed', item_id: s.itemID, content_index: 0,
        transcript: result.transcript, usage: { type: 'duration', seconds: s.samples / LIMITS.sampleRate } };
      need(validateServerEvent({ event_id: 'validate', ...completed }).ok);
      this.send({ type: 'conversation.item.done', previous_item_id: s.previous, item: item(s.itemID, 'user', 'completed', [{ type: 'input_audio', transcript: result.transcript }]) });
      this.send(completed);
    } catch {
      if (this.alive && !s.abort.signal.aborted) {
        if (s.committed) {
          this.send({ type: 'conversation.item.input_audio_transcription.failed', item_id: s.itemID, content_index: 0, error: wireError() });
          this.send({ type: 'conversation.item.done', previous_item_id: s.previous, item: item(s.itemID, 'user', 'incomplete', [{ type: 'input_audio', transcript: '' }]) });
        } else this.error('local_failure');
      }
    } finally { if (this.segment === s) this.segment = null; this.retireSegment(s); }
  }
  async respond(e) {
    const operationID = e.response.metadata.operation_id;
    const canonical = this.canonical;
    const prior = this.engine.control.operation(this.callID, operationID);
    const op = await this.engine.control.prepare(this.callID, this.epoch, operationID, canonical);
    if (prior || op.state !== 'prepared') {
      if (op.response_status) this.send({ type: 'response.done', response: this.responseValue({ id: op.response_id, operationID }, op.response_status) });
      else this.error('context_required', e.event_id); // HTTP snapshot for nonterminal/uncertain admission; no invented GA status.
      return; // Recorded IDs/status only, never submit or replay audio/items.
    }
    this.authority(true);
    const r = this.response = { id: op.response_id, operationID, active: true, abort: new AbortController(),
      canonical, itemID: id('item'), sent: 0, rendered: 0, modality: e.response.output_modalities[0], text: '', wake: null };
    this.send({ type: 'response.created', response: this.responseValue(r, 'in_progress') });
    this.runResponse(r, op).catch(() => { if (this.alive) this.close(1011); });
  }
  responseValue(r, status) {
    const status_details = ['completed', 'in_progress'].includes(status) ? null : status === 'cancelled'
      ? { type: status, reason: 'client_cancelled' } : { type: 'failed', error: { type: 'server_error', code: 'local_failure', message: ERROR_CODES.local_failure } };
    return { id: r.id, object: 'realtime.response', status, status_details, output: r.finalItem ? [r.finalItem] : [], metadata: { operation_id: r.operationID } };
  }
  async runResponse(r, op) {
    let status = 'completed';
    try {
      await this.engine.control.dispatch(this.callID, this.epoch, r.operationID); this.authority(true);
      const work = this.engine.jobs.run(() => {
        this.authority(true); // Last check before the adapter's one and only submit.
        return this.engine.adapter.submit({ call_id: this.callID, binding: this.binding, operation_id: r.operationID,
          planned_inbox_id: op.planned_inbox_id, item: r.canonical });
      }).then(result => {
        need(result && Object.keys(result).every(k => ['admission_inbox_id', 'source_user_id', 'source_assistant_id', 'text'].includes(k))
          && result.admission_inbox_id === op.planned_inbox_id && typeof result.text === 'string' && Buffer.byteLength(result.text) <= 64000
          && result.source_assistant_id !== result.admission_inbox_id && result.source_assistant_id !== result.source_user_id);
        // Fake authoritative lineage only. This does not prove the real harness boundary.
        this.engine.control.result(this.callID, r.operationID, { state: 'completed', admission_inbox_id: result.admission_inbox_id,
          source_user_id: result.source_user_id, source_assistant_id: result.source_assistant_id, delivery: { state: 'unknown', rendered_samples: 0 } });
        return result;
      });
      work.catch(() => { try { this.engine.control.result(this.callID, r.operationID, { state: 'uncertain' }); } catch {} });
      const result = await bounded(work, r.abort.signal, this.engine.stallMs); this.authority(true); need(r.active);
      need(validateServerEvent({ event_id: 'validate', type: 'response.output_text.delta', ...this.coordinates(r), delta: result.text }).ok);
      r.text = result.text;
      this.remember(r.itemID, r.operationID);
      r.previous = this.previousItem; this.previousItem = r.itemID;
      this.send({ type: 'response.output_item.added', response_id: r.id, output_index: 0, item: item(r.itemID, 'assistant', 'in_progress', []) });
      this.send({ type: 'conversation.item.added', previous_item_id: r.previous, item: item(r.itemID, 'assistant', 'in_progress', []) });
      const part = r.modality === 'audio' ? { type: 'audio', transcript: '' } : { type: 'text', text: '' };
      this.send({ type: 'response.content_part.added', ...this.coordinates(r), part }); r.started = true;
      if (r.modality === 'text') this.send({ type: 'response.output_text.delta', ...this.coordinates(r), delta: r.text });
      else {
        this.send({ type: 'response.output_audio_transcript.delta', ...this.coordinates(r), delta: r.text });
        r.synthesis = this.engine.jobs.own(async () => {
          this.authority(true);
          const iterable = await this.engine.adapter.synthesize({ text: r.text, signal: r.abort.signal, call_id: this.callID,
            format: { type: 'audio/pcm', rate: 24000, channels: 1 } });
          // Observe allocation even if cancellation won its await: the owned slot must retire it.
          const iterator = iterable[Symbol.asyncIterator](); need(typeof iterator?.next === 'function'); return iterator;
        }, iterator => iterator.return?.());
        await bounded(r.synthesis.ready, r.abort.signal, this.engine.stallMs);
        while (r.active) {
          const next = await bounded(r.synthesis.invoke(iterator => { this.authority(true); need(!r.abort.signal.aborted); return iterator.next(); }), r.abort.signal, this.engine.stallMs);
          if (next.done) break;
          const pcm = next.value; need(Buffer.isBuffer(pcm) && pcm.length > 0 && pcm.length % 2 === 0 && pcm.length <= LIMITS.maxFrameBytes);
          const samples = pcm.length / 2;
          const deadline = Date.now() + this.engine.stallMs;
          while (r.sent + samples - r.rendered > LIMITS.windowSamples) {
            need(Date.now() < deadline);
            await bounded(new Promise(resolve => { r.wake = resolve; }), r.abort.signal, Math.max(1, deadline - Date.now()));
          }
          this.authority(true); need(r.active && !r.abort.signal.aborted);
          r.sent += samples;
          await this.send({ type: 'response.output_audio.delta', ...this.coordinates(r), delta: pcm.toString('base64') }, true);
        }
      }
    } catch {
      status = r.cancelled ? 'cancelled' : 'failed';
      if (!r.cancelled && this.engine.control.operation(this.callID, r.operationID)?.state === 'dispatching') {
        try { this.engine.control.result(this.callID, r.operationID, { state: 'uncertain' }); } catch {}
      }
    }
    finally {
      if (this.alive && r.active) {
        try { this.finishResponse(r, status); } catch { this.close(1011); }
      }
      r.active = false; r.abort.abort(); r.wake?.(); r.wake = null;
      r.synthesis?.retire().catch(() => {});
    }
  }
  coordinates(r) { return { response_id: r.id, item_id: r.itemID, output_index: 0, content_index: 0 }; }
  finishResponse(r, status) {
    this.authority(true);
    if (r.started) {
      if (r.modality === 'audio') {
        this.send({ type: 'response.output_audio.done', ...this.coordinates(r) });
        this.send({ type: 'response.output_audio_transcript.done', ...this.coordinates(r), transcript: r.text });
      } else this.send({ type: 'response.output_text.done', ...this.coordinates(r), text: r.text });
      const part = r.modality === 'audio' ? { type: 'audio', transcript: r.text } : { type: 'text', text: r.text };
      this.send({ type: 'response.content_part.done', ...this.coordinates(r), part });
      r.finalItem = item(r.itemID, 'assistant', status === 'completed' ? 'completed' : 'incomplete',
        [r.modality === 'audio' ? { type: 'output_audio', transcript: r.text } : { type: 'output_text', text: r.text }]);
      this.send({ type: 'response.output_item.done', response_id: r.id, output_index: 0, item: r.finalItem });
      this.send({ type: 'conversation.item.done', previous_item_id: r.previous, item: r.finalItem });
    }
    this.engine.control.recordResponse(this.callID, r.operationID, status);
    this.send({ type: 'response.done', response: this.responseValue(r, status) });
    r.generatedDone = status === 'completed';
  }
  cancel() { const r = this.response; if (r?.active) { r.cancelled = true; r.abort.abort(); r.wake?.(); } }
  playback(e) {
    const r = this.response; need(r && e.media_epoch === String(this.epoch) && e.response_id === r.id && e.item_id === r.itemID, 'invalid_position');
    need(!r.playbackEpoch || r.playbackEpoch === e.playback_epoch, 'invalid_position');
    need(e.rendered_samples >= r.rendered && e.rendered_samples <= r.sent, 'invalid_position');
    need(e.state !== 'unknown' || e.rendered_samples === r.rendered, 'invalid_position');
    need(!['paused', 'stopped', 'unknown'].includes(r.playbackState) || e.rendered_samples === r.rendered, 'invalid_position');
    const now = Date.now();
    if (e.state === r.playbackState) need(now - (r.playbackAt ?? 0) >= 250, 'invalid_position');
    r.playbackEpoch = e.playback_epoch; r.playbackAt = now; r.playbackState = e.state; r.rendered = e.rendered_samples;
    if (this.engine.control.operation(this.callID, r.operationID)?.state === 'completed') this.engine.control.recordDelivery(this.callID, r.operationID,
      { state: r.generatedDone && e.state === 'completed' && r.rendered === r.sent ? 'completed' : r.rendered > 0 ? 'partial' : 'unknown', rendered_samples: r.rendered });
    r.wake?.(); r.wake = null;
  }
  close(code, cause = MEDIA_CLOSE.internal, peerCode = 0) {
    if (!this.alive) return;
    this.diagnostic('open_voice_media', { category: cause === MEDIA_CLOSE.owner ? 'cancelled'
      : cause === MEDIA_CLOSE.peer && [1000, 1001].includes(peerCode) ? 'complete' : 'failed',
      cause, closeCode: peerCode, requestedCloseCode: code ?? 0,
      ingressBytes: this.received * 2, consumedSamples: this.consumed });
    this.alive = false; clearInterval(this.timer); this.lifetime.abort(); this.clear();
    for (const s of this.segments) this.retireSegment(s);
    for (const entry of this.queue.splice(0)) { this.engine.rawBytes -= entry.raw; this.queueBytes -= entry.bytes; }
    const r = this.response;
    if (r) {
      if (r.active && !this.engine.control.operation(this.callID, r.operationID)?.response_status) {
        try { this.engine.control.recordResponse(this.callID, r.operationID, 'failed'); } catch {}
      }
      r.active = false; r.abort.abort(); r.wake?.(); r.wake = null;
      r.synthesis?.retire().catch(() => {});
      const o = this.engine.control.operation(this.callID, r.operationID);
      if (o?.state === 'dispatching') { try { this.engine.control.result(this.callID, r.operationID, { state: 'uncertain' }); } catch {} }
    }
    try { this.engine.control.unregisterMediaSession(this.callID, this.epoch, this.sessionID); } catch {}
    if (this.engine.sessions.get(this.callID) === this) this.engine.sessions.delete(this.callID);
    try { this.engine.onSessionClosed({ call_id: this.callID, media_epoch: this.epoch }); } catch {}
    if (this.ws.readyState === WebSocket.OPEN && code) {
      this.ws.close(code); const timer = setTimeout(() => this.ws.terminate(), MEDIA_BOUNDS.closeMs); timer.unref(); this.ws.once('close', () => clearTimeout(timer));
    } else if (this.ws.readyState !== WebSocket.CLOSED) this.ws.terminate();
  }
}
