// Project-owned bridge. Candidate WS uses pinned ws; no shared service configuration writes.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { Transform, pipeline } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { deploymentPreflight } from './deployment-preflight.mjs';
import { eventLifetime } from './event-lifetime.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { Maintenance } from './maintenance.mjs';
import { OpenVoiceControl, CONTROL_PREFIX } from './open-voice-control.mjs';
import { OpenVoiceMedia } from './open-voice-media.mjs';
import { createAPNs } from './apns.mjs';
import { startSender } from './push-socket.mjs';
import { Capabilities, exactReference, readAsset, validateBytes, assetDescription, canvasAssociation, canvasShowAssociation, showRevision, byteRange, check, phoneProjection, learnCanvasOrigin, learnCanvasMessageOrigins } from './rich-content.mjs';
import { canvasPage, canvasLibrary, canvasChunk } from './canvas-page.mjs';
import { OpenChamberClient, OCError, discoverDesktop } from './oc-client.mjs';
import { classifySender, messageOrigin } from './sender.mjs';
import { SpeechTransferTiming } from './speech-timing.mjs';
export { discoverDesktop } from './oc-client.mjs';

const PREFIX = '/floating-voice';
const SID = /^ses_[a-zA-Z0-9]{1,100}$/;
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
const token = () => crypto.randomBytes(32).toString('base64url');
function canvasDeliveryResult(id, interaction) {
  const known = ['queued', 'sending', 'delivered', 'unsent', 'uncertain'];
  if (!interaction || !known.includes(interaction.status)) return { id, status: 'uncertain', detail: 'Delivery unknown; check History; never retry automatically' };
  return { id, status: interaction.status, detail: typeof interaction.detail === 'string' ? phoneProjection(interaction.detail) : '' };
}
// Closed categories only; never serialize request URLs, headers, errors or response bodies.
export function diagnosticStage(url) {
  const clean = url.split('?')[0];
  if (/\/messages$/.test(clean)) return 'history';
  if (/\/events$/.test(clean)) return 'events';
  if (/\/prompt$/.test(clean)) return 'prompt';
  if (/\/interrupt$/.test(clean)) return 'interrupt';
  if (/\/state$/.test(clean)) return 'state';
  if (/\/pair(?:\/ack)?$/.test(clean)) return 'pairing';
  if (/\/selection$/.test(clean)) return 'selection';
  if (/\/health$/.test(clean)) return 'health';
  if (/\/voices$/.test(clean)) return 'voices';
  if (/\/speech$/.test(clean)) return 'tts';
  if (/\/transcribe$/.test(clean)) return 'asr';
  return 'other';
}
export function rotatingDiagnostics(file) {
  return entry => {
    try {
      if (fs.existsSync(file) && fs.statSync(file).size >= 131072) {
        fs.renameSync(file, file + '.1');
      }
      fs.appendFileSync(file, JSON.stringify({ time: Date.now(), ...entry }) + '\n', { mode: 0o600 });
    } catch { /* Never break a request for diagnostics. */ }
  };
}
export const pairingWindowMs = 8 * 3600000;
class Refusal extends Error { constructor(status, message) { super(message); this.status = status; } }
const refuse = (ok, status, message) => { if (!ok) throw new Refusal(status, message); };

export class Credentials {
  constructor(file) {
    this.file = file;
    const stat = fs.lstatSync(file);
    refuse(stat.isFile() && (stat.mode & 0o777) === 0o600 && stat.uid === process.getuid(), 500, 'private credential file required');
    this.data = JSON.parse(fs.readFileSync(file));
  }
  save() {
    const tmp = this.file + '.new';
    fs.writeFileSync(tmp, JSON.stringify(this.data), { mode: 0o600, flag: 'wx' });
    fs.renameSync(tmp, this.file);
  }
  pair(secret, proposed) {
    if (proposed !== undefined) refuse(typeof proposed === 'string' && /^[\w-]{43}$/.test(proposed), 400, 'invalid device proof');
    const proof = proposed && hash(proposed);
    const recovery = proof && this.data.devices[proof]?.pairRecovery;
    if (recovery && recovery.expires > Date.now() && typeof secret === 'string' && recovery.bootstrap === hash(secret)) {
      return { credential: proposed, deviceID: this.data.devices[proof].deviceID };
    }
    refuse(typeof secret === 'string' && secret.length <= 128 && this.data.bootstrap === hash(secret)
      && this.data.expires > Date.now(), 401, 'pairing unavailable');
    const credential = proposed || token(), deviceID = crypto.randomUUID();
    const pairRecovery = proposed ? { bootstrap: this.data.bootstrap, expires: Date.now() + 10 * 60000 } : undefined;
    delete this.data.bootstrap; delete this.data.expires;
    this.data.devices[hash(credential)] = { deviceID, ...(pairRecovery ? { pairRecovery } : {}) };
    this.save();
    return { credential, deviceID };
  }
  device(auth) {
    // Revocation through the local CLI takes effect without a process restart.
    const stat = fs.lstatSync(this.file);
    refuse(stat.isFile() && (stat.mode & 0o777) === 0o600 && stat.uid === process.getuid(), 500, 'private credential file required');
    this.data = JSON.parse(fs.readFileSync(this.file));
    refuse(typeof auth === 'string' && /^Bearer [\w-]{43}$/.test(auth), 401, 'device credential required');
    const digest = Buffer.from(hash(auth.slice(7)), 'hex');
    let d;
    for (const [key, value] of Object.entries(this.data.devices)) {
      if (/^[a-f0-9]{64}$/.test(key) && crypto.timingSafeEqual(digest, Buffer.from(key, 'hex'))) d = value;
    }
    refuse(d, 401, 'device credential revoked or unknown');
    if (d.test) refuse(d.test.expires > Date.now() && SID.test(d.test.sessionID), 401, 'test identity expired');
    return d;
  }
  revoke(deviceID) {
    for (const [key, d] of Object.entries(this.data.devices)) if (d.deviceID === deviceID) delete this.data.devices[key];
    this.save();
  }
  activeDevices() {
    const stat = fs.lstatSync(this.file);
    refuse(stat.isFile() && (stat.mode & 0o777) === 0o600 && stat.uid === process.getuid(), 500, 'private credential file required');
    return Object.values(JSON.parse(fs.readFileSync(this.file)).devices);
  }
}

function json(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}
async function body(req, max = 32768) {
  refuse(!req.headers['transfer-encoding'], 400, 'chunked request bodies not accepted');
  refuse(/^application\/json(?:;.*)?$/.test(req.headers['content-type'] || ''), 415, 'JSON required');
  const size = Number(req.headers['content-length']);
  refuse(Number.isSafeInteger(size) && size > 0 && size <= max, 413, 'body limit');
  const chunks = []; let n = 0;
  for await (const chunk of req) { n += chunk.length; refuse(n <= max, 413, 'body limit'); chunks.push(chunk); }
  let obj;
  try { obj = JSON.parse(Buffer.concat(chunks)); } catch { throw new Refusal(400, 'invalid JSON'); }
  refuse(obj && typeof obj === 'object' && !Array.isArray(obj), 400, 'object required');
  return obj;
}
function keys(obj, allowed) { refuse(Object.keys(obj).every(k => allowed.includes(k)), 400, 'unexpected field'); }

export function readChief() {
  const id = JSON.parse(fs.readFileSync(path.join(process.env.HOME, '.chief-of-staff/chief.json'))).session;
  refuse(SID.test(id), 503, 'chief unavailable');
  return id;
}
function upstream(port, method, url, data, headers = {}, signal) {
  return http.request({ host: '127.0.0.1', port, method, path: url, headers: {
    ...headers, ...(data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {})
  }, timeout: 75000, signal });
}
async function getJSON(port, url, { open = upstream, signal, deadlineMs = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const req = open(port, 'GET', url, null, {}, signal);
    const deadline = setTimeout(() => req.destroy(new Error('upstream deadline')), deadlineMs);
    req.on('close', () => clearTimeout(deadline));
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.on('response', res => {
      if (res.authError) { res.destroy(); reject(res.authError); return; }
      let size = 0; const chunks = [];
      res.on('data', c => { size += c.length; if (size > 8 * 1024 * 1024) res.destroy(new Error('upstream body limit')); else chunks.push(c); });
      res.on('error', reject);
      res.on('end', () => {
        try { refuse(res.statusCode === 200, 502, res.statusCode === 401 || res.statusCode === 403 ? 'upstream authentication required; no credentials discovered' : 'upstream unavailable'); resolve(JSON.parse(Buffer.concat(chunks))); }
        catch (e) { reject(e); }
      });
    }); req.end();
  });
}

export class SessionEvents extends Transform {
  constructor(sid, { diagnostic = () => {}, project = phoneProjection } = {}) {
    super(); this.sid = sid; this.diagnostic = diagnostic; this.project = project;
    this.record = Buffer.alloc(262144); this.bufferedBytes = 0; this.maxBufferedBytes = 0;
    this.skipping = false; this.delimiterState = 0; this.refreshPending = false;
    this.decoder = new TextDecoder('utf-8', { fatal: true });
  }
  skipped(reason) {
    // A truncated/malformed prefix cannot prove another session owns the *whole* record.
    // Conservatively refresh only our selected session, without forwarding any upstream bytes.
    this.refreshPending = true;
    try { this.diagnostic({ reason, bufferedBytes: this.bufferedBytes, refresh: 1 }); } catch { /* diagnostics never affect delivery */ }
  }
  refresh() {
    if (!this.refreshPending) return;
    this.refreshPending = false;
    // Existing build 18: dirty/trailing history refresh; no execution, text or inbox item mutation.
    this.push('data: ' + JSON.stringify({ type: 'session.inbox.delivered', data: { sessionID: this.sid } }) + '\n\n');
  }
  complete(delimiterBytes) {
    if (this.skipping) {
      // Also refresh after the tail: a read started at overflow may predate persistence.
      this.refreshPending = true;
    } else {
      let record;
      try { record = this.decoder.decode(this.record.subarray(0, this.bufferedBytes - delimiterBytes)); }
      catch { this.skipped('invalid_utf8'); return this.resetRecord(); }
      const lines = record.split(/\r?\n/);
      const data = lines.filter(l => l.startsWith('data:')).map(l => l.slice(5).trimStart()).join('\n');
      if (!data) {
        if (lines.some(line => line.startsWith(':'))) this.push(': heartbeat\n\n');
      } else {
        let event;
        try { event = JSON.parse(data); }
        catch { this.skipped('invalid_json'); return this.resetRecord(); }
        const payload = event?.payload ?? event;
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) this.skipped('invalid_shape');
        else if (payload?.data?.sessionID === this.sid) {
          if (typeof payload.type !== 'string') this.skipped('invalid_shape');
          else {
            try { this.push('data: ' + JSON.stringify(this.project(payload)) + '\n\n'); }
            catch { this.skipped('projection_failed'); }
          }
        }
      }
    }
    this.resetRecord();
  }
  resetRecord() { this.bufferedBytes = 0; this.skipping = false; this.delimiterState = 0; }
  _transform(chunk, _, cb) {
    try {
      // Scan raw bytes, not a concatenated decoded chunk. Retain at most 256 KiB per
      // record (including delimiter), even for a multi-megabyte chunk or endless tail.
      // Two integer delimiter states survive chunk boundaries, including CRLF splits.
      for (const byte of chunk) {
        if (!this.skipping) {
          if (this.bufferedBytes === this.record.length) {
            this.skipped('event_oversize'); this.bufferedBytes = 0; this.skipping = true;
          } else {
            this.record[this.bufferedBytes++] = byte;
            this.maxBufferedBytes = Math.max(this.maxBufferedBytes, this.bufferedBytes);
          }
        }
        if (byte === 10 && this.delimiterState) this.complete(this.delimiterState === 2 ? 3 : 2);
        else this.delimiterState = byte === 10 ? 1 : (byte === 13 && this.delimiterState === 1 ? 2 : 0);
      }
      this.refresh();
      cb();
    } catch (e) { cb(e); }
  }
  _flush(cb) {
    if (this.skipping || this.bufferedBytes) this.skipped('unterminated_record');
    this.resetRecord(); this.refresh(); cb();
  }
}

export function createBridge({ credentials, discover = discoverDesktop, chief = readChief, ttsPort = 8444, asrPort = 8446,
  maxUpstreams = 12, jsonDeadlineMs = 5000, requestDeadlineMs = 120000, diagnostic = () => {}, eventClock = globalThis, push,
  ocClient = new OpenChamberClient({ diagnostic }), openVoiceCandidate, openVoiceMedia, maintenance, ownerStats = () => ({}) }) {
  let media;
  const hasMethods = openVoiceMedia?.enabled === true
    && ['openSegment', 'submit', 'synthesize'].every(k => typeof openVoiceMedia.adapter?.[k] === 'function');
  const hasAdapter = hasMethods && openVoiceMedia.adapter?.readyForCalls !== false;
  const candidate = openVoiceCandidate?.enabled === true ? new OpenVoiceControl({ ...openVoiceCandidate, push,
    mediaAvailable: () => openVoiceMedia?.adapter?.readyForCalls !== false && (media ? media.available() : hasAdapter),
    closeOwner: owner => { media?.fence(owner); openVoiceCandidate.closeOwner?.(owner); },
    authenticateDevice: authorization => credentials.device(authorization) }) : null;
  if (candidate && (hasAdapter || hasMethods && openVoiceMedia.ownerAssembly === true)) media = new OpenVoiceMedia({ ...openVoiceMedia, control: candidate, diagnostic });
  const sockets = new Set(); let connections = 0;
  let activeHandlers = 0, startupChecks = 0;
  let activeUpstreams = 0, peakUpstreams = 0;
  function open(...args) {
    refuse(activeUpstreams < maxUpstreams, 429, 'bridge upstream work limit');
    const context = typeof args[0] === 'object' ? args[0] : null;
    if (context) { args[0] = context.port; args[4] = { ...args[4], ...context.headers }; }
    const request = upstream(...args);
    if (context?.paired) request.on('response', response => {
      if ([401, 403].includes(response.statusCode)) response.authError = ocClient.rejected();
    });
    activeUpstreams++; peakUpstreams = Math.max(peakUpstreams, activeUpstreams);
    // Admission is held until the socket/request actually closes, not just until the client aborts.
    let upgraded = false, released = false;
    const release = () => { if (!released) { released = true; activeUpstreams--; if (!activeUpstreams) server.emit('upstreamIdle'); } };
    request.once('upgrade', (_, socket) => { upgraded = true; socket.once('close', release); });
    request.once('close', () => { if (!upgraded) release(); });
    return request;
  }
  const target = (port, signal) => port?.desktop ? ocClient.prepare(discover(), signal) : port;
  const readJSON = async (port, url, signal) => getJSON(await target(port, signal), url, { open, signal, deadlineMs: jsonDeadlineMs });
  const senderTitles = new Map(), senderTitleExpiry = new Map();
  async function learnSenderTitles(page, port, signal) {
    const identities = new Map();
    for (const record of Array.isArray(page?.data) ? page.data : []) {
      if (!['user', 'synthetic'].includes(record.type)) continue;
      const from = messageOrigin(record.metadata) ?? classifySender(record.text).sourceSession;
      if (from) identities.set(`${from.server}/${from.id}`, from.id);
    }
    const cold = [...identities].filter(([key]) => (senderTitleExpiry.get(key) ?? 0) <= Date.now()).slice(0, 8);
    if (!cold.length) return;
    // Optional decoration has ONE short aggregate budget, not eight serial
    // upstream deadlines. Abort actual requests at the budget boundary (and on
    // disconnect); do not leave background work competing with history/SSE.
    const controller = new AbortController(), abort = () => controller.abort();
    if (signal.aborted) return;
    signal.addEventListener('abort', abort, { once: true });
    const deadline = setTimeout(abort, 200);
    try {
      await Promise.all(cold.map(async ([key, id]) => {
        try {
          const result = await readJSON(port, `/api/session/${id}`, controller.signal), session = result.data ?? result;
          if (!controller.signal.aborted && session.id === id && typeof session.title === 'string') senderTitles.set(key, session.title);
        } catch { /* A missing title never makes authoritative history fail. */ }
        senderTitleExpiry.set(key, Date.now() + 60000);
        if (senderTitleExpiry.size > 256) {
          const oldest = senderTitleExpiry.keys().next().value;
          senderTitleExpiry.delete(oldest); senderTitles.delete(oldest);
        }
      }));
    } finally { clearTimeout(deadline); signal.removeEventListener('abort', abort); }
  }
  async function canvasReceiptConfirmed(port, sid, panel, interaction, id, signal) {
    // Canvas's stable message id is derived from the exact UUID (case preserved).
    // Never accept an arbitrary message path, session or an approximate prompt match.
    const messageID = 'msg_canvas' + id.replaceAll('-', '');
    if (interaction?.sessionKey !== panel.sessionKey || interaction?.messageId !== messageID || typeof interaction?.prompt !== 'string' || !interaction.prompt) return false;
    try {
      const payload = await readJSON(port, `/api/session/${sid}/message/${messageID}`, signal);
      const message = payload.data ?? payload;
      // V2 User has no sessionID field: ownership is the authenticated, session-scoped
      // message endpoint plus the verified session and Canvas sessionKey binding.
      // Reject any explicit contradictory owner returned by an adapter.
      return message?.id === messageID && message.type === 'user' && message.text === interaction.prompt
        && (message.sessionID === undefined || message.sessionID === sid)
        && (message.sessionId === undefined || message.sessionId === sid);
    } catch (error) {
      if (error instanceof OCError) throw error; // Revoked desktop auth stays a calm 503, never a fallback.
      return false; // Missing, refused, timed out or malformed proof is NOT delivery.
    }
  }
  const assets = new Capabilities(), panels = new Capabilities(), submissions = new Map();
  async function hostCanvas(port, endpoint, value, signal, definiteFailure = false) {
    port = await target(port, signal);
    const bytes = Buffer.from(JSON.stringify({ method: 'POST', path: endpoint, body: JSON.stringify(value) }));
    const envelope = await new Promise((resolve, reject) => {
      const request = open(port, 'POST', '/api/guests/agent-canvas/service/request', bytes, {}, signal);
      request.on('error', reject); request.on('timeout', () => request.destroy());
      request.on('response', response => {
        if (response.authError) { response.destroy(); reject(response.authError); return; }
        let n = 0; const chunks = [];
        response.on('error', reject); response.on('data', chunk => { n += chunk.length; if (n > 8 * 1024 * 1024) response.destroy(); else chunks.push(chunk); });
        response.on('end', () => { try { check(response.statusCode === 200, 502); resolve(JSON.parse(Buffer.concat(chunks))); } catch (e) { reject(e); } });
      }); request.end(bytes);
    });
    if (definiteFailure && [400, 413, 409].includes(envelope.status)) check(false, envelope.status, envelope.status === 409 ? 'Canvas revision changed' : 'Canvas input rejected; correct it and submit again');
    check(envelope.status === 200 && typeof envelope.body === 'string', 502);
    const result = JSON.parse(envelope.body);
    if (endpoint === '/connect') learnCanvasOrigin(result.publicUrl);
    return result;
  }
  async function authoritative(port, sid, messageID, signal) {
    check(typeof messageID === 'string' && /^[a-zA-Z0-9_-]{1,200}$/.test(messageID), 400);
    const session = await readJSON(port, `/api/session/${sid}`, signal);
    const record = await readJSON(port, `/api/session/${sid}/message/${messageID}`, signal);
    const s = session.data ?? session, r = record.data ?? record;
    const directory = s.location?.directory;
    check(s.id === sid && typeof directory === 'string' && path.isAbsolute(directory) && r.id === messageID, 404);
    learnCanvasMessageOrigins(r);
    return { directory, record: r };
  }
  function route(req) {
    refuse(!req.headers.origin, 403, 'browser origins not accepted');
    refuse(req.url.length <= 2048 && !/[\\%#]/.test(req.url), 400, 'invalid path encoding');
    refuse(req.url.startsWith(PREFIX + '/'), 404, 'prefix required');
    return req.url.slice(PREFIX.length);
  }
  function lease(req, sid) {
    const d = credentials.device(req.headers.authorization);
    refuse(!d.test || d.test.sessionID === sid, 403, 'test target scope');
    refuse(d.sessionID === sid && d.generation && req.headers['x-fv-generation'] === d.generation, 409, 'select target; stale or mismatched generation');
    refuse(d.mode !== 'chief' || chief() === sid, 409, 'chief changed; explicit reselection required');
    return d;
  }
  async function desktop(signal) {
    signal?.throwIfAborted();
    const port = { desktop: true };
    const info = await readJSON(port, '/api/system/info', signal);
    refuse(info.runtime === 'desktop', 503, 'not desktop OpenChamber');
    return port;
  }
  async function proxy(req, res, signal, port, url, data, filter, valid = () => true, responseLimit = 16 * 1024 * 1024) {
    port = await target(port, signal);
    const up = open(port, req.method, url, data, filter ? { Accept: 'text/event-stream' } : {}, signal);
    let response, lifetime;
    const speechTiming = req.method === 'POST' && url === '/v1/audio/speech' ? new SpeechTransferTiming() : null;
    let speechDone = false;
    const speechRecord = (event, category) => {
      if (!speechTiming) return;
      try { diagnostic({ stage: 'tts', attempt: req.diagnosticAttempt, category, playbackEvent: event,
        status: response?.statusCode ?? 0, ...speechTiming.snapshot() }); } catch { /* Observations never fail media. */ }
    };
    const speechFinish = category => {
      if (!speechTiming || speechDone) return;
      speechDone = true; speechRecord('upstreamComplete', category);
    };
    speechRecord('upstreamRequest', 'begin');
    const stop = () => { up.destroy(); response?.destroy(); };
    const timer = setTimeout(() => { stop(); res.destroy(); }, filter ? 300000 : 120000);
    res.on('close', () => { speechFinish('cancelled'); clearTimeout(timer); lifetime?.stop(); stop(); });
    up.on('timeout', () => { if (lifetime) lifetime.end('watchdog', 'upstream_idle'); else up.destroy(new Error('timeout')); });
    up.on('error', e => {
      speechFinish('failed');
      if (lifetime) { lifetime.end('upstream', 'transport'); return; }
      const service = req.url.startsWith(PREFIX + '/asr/') ? 'asr' : req.url.startsWith(PREFIX + '/tts/') ? 'tts' : null;
      if (!response && !res.headersSent && service && ['ECONNREFUSED', 'ECONNRESET'].includes(e.code)) {
        json(res, 503, { error: 'speech_unavailable', service, endpoint: `127.0.0.1:${port}` });
      } else if (!res.headersSent) json(res, 502, { error: 'upstream disconnected; mutation delivery may be unknown; never retry automatically' });
      else res.destroy();
    });
    up.on('response', r => {
      response = r;
      if (speechTiming) {
        r.on('data', chunk => { if (speechTiming.receive(chunk.length)) speechRecord('upstreamFirstByte', 'ready'); });
        r.once('end', () => speechFinish('complete'));
        r.once('error', () => speechFinish('failed'));
        r.once('aborted', () => speechFinish('failed'));
        r.once('close', () => speechFinish('failed'));
      }
      if (r.authError) { speechFinish('failed'); r.destroy(); json(res, 503, { error: r.authError.message }); return; }
      if (r.statusCode < 200 || r.statusCode >= 300) { speechFinish('failed'); r.destroy(); json(res, 502, { error: r.statusCode === 401 || r.statusCode === 403 ? 'upstream authentication required; no credentials discovered' : 'upstream refused; mutation delivery may be unknown' }); return; }
      const headers = { 'Content-Type': r.headers['content-type'] || 'application/octet-stream', 'Cache-Control': 'no-store' };
      if (filter) Object.assign(headers, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store, no-transform', 'X-Accel-Buffering': 'no', 'Content-Encoding': 'identity' });
      if (r.headers['x-sample-rate']) headers['X-Sample-Rate'] = r.headers['x-sample-rate'];
      res.writeHead(r.statusCode, headers);
      if (filter) {
        res.flushHeaders(); res.write(': connected\n\n');
        lifetime = eventLifetime({ clock: eventClock, heartbeat: () => {
          // Never accumulate heartbeats behind a stalled downstream.
          if (res.writableLength > 262144) lifetime.end('watchdog', 'downstream_stalled');
          else res.write(': heartbeat\n\n');
        }, validate: valid, close: (initiator, reason, clean) => {
          res.networkClose = { initiator, reason };
          r.unpipe(filter); filter.unpipe(res);
          if (clean) res.end(); else res.destroy();
          stop(); filter.destroy();
        } });
        r.on('data', () => lifetime.bytes());
        r.on('end', () => { res.networkClose = { initiator: 'upstream', reason: 'clean_end' }; lifetime.stop(); });
        r.on('error', () => lifetime.end('upstream', 'transport'));
        filter.on('error', () => lifetime.end('filter', 'internal_error'));
        pipeline(r, filter, res, () => {});
      }
      else {
        let bytes = 0;
        const bounded = new Transform({ transform(chunk, _, cb) { bytes += chunk.length; if (bytes > responseLimit) cb(new Error('upstream body limit')); else cb(null, chunk); } });
        pipeline(r, bounded, res, () => {});
      }
    });
    up.end(data);
  }
  const server = http.createServer({ maxHeaderSize: 8192 }, async (req, res) => {
    activeHandlers++;
    const started = performance.now(), stage = diagnosticStage(req.url);
    const proposedAttempt = req.headers['x-fv-attempt'];
    const attempt = typeof proposedAttempt === 'string' && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(proposedAttempt) ? proposedAttempt : crypto.randomUUID();
    req.diagnosticAttempt = attempt; // Already closed/validated; never a raw header or URL.
    diagnostic({ stage, attempt, category: 'begin', elapsedMs: 0 });
    res.once('close', () => diagnostic({ stage, attempt, category: res.writableFinished ? 'complete' : 'cancelled', elapsedMs: Math.round(performance.now() - started), status: res.statusCode,
      ...(res.networkClose || { initiator: res.writableFinished ? 'bridge' : 'client', reason: res.writableFinished ? 'clean_end' : 'downstream_closed' }) }));
    const controller = new AbortController(), signal = controller.signal;
    const deadline = setTimeout(() => { res.networkClose = { initiator: 'watchdog', reason: 'hard_deadline' }; controller.abort(); res.destroy(); }, req.url.endsWith('/events') ? 300000 : requestDeadlineMs);
    req.once('aborted', () => controller.abort());
    res.once('close', () => { clearTimeout(deadline); controller.abort(); });
    try {
      if (maintenance?.held) {
        // Admission at dispatch also covers requests on pre-existing keepalive
        // sockets. Only observation and existing call continuation remain open.
        const observation = (req.method === 'GET' && !req.url.split('?')[0].endsWith('/events'))
          || (req.method === 'POST' && /^\/floating-voice\/v1\/sessions\/ses_[a-zA-Z0-9]{1,100}\/canvas(?:-show)?\/status$/.test(req.url));
        const continuation = (req.method === 'POST' && (req.url === PREFIX + '/v1/push/events'
          || /^\/floating-voice\/voice\/v1\/calls\/[0-9a-f-]{36}\/(accept|decline|media|media-ready|end)$/.test(req.url)))
          || (req.method === 'PUT' && [CONTROL_PREFIX + '/device-capability', PREFIX + '/v1/push/settings', PREFIX + '/v1/push/enrollment'].includes(req.url));
        refuse(observation || continuation, 503, 'bridge maintenance hold');
      }
      // Candidate namespace is closed before legacy device-only authentication.
      if (req.url.startsWith('/floating-voice/voice/')) {
        try {
          refuse(candidate, 404);
          refuse(req.headers.origin === undefined && req.url.length <= 256 && !/[\\%#?]/.test(req.url), 403);
          refuse(req.url.startsWith(CONTROL_PREFIX + '/'), 404);
          const token = /^Bearer ([A-Za-z0-9_-]{1,512})$/.exec(req.headers.authorization || '')?.[1];
          refuse(token, 401);
          let obj;
          const bodyTimer = setTimeout(() => req.destroy(), 5000);
          try { obj = req.method === 'GET' ? {} : await body(req, 4096); } finally { clearTimeout(bodyTimer); }
          if (req.method === 'GET') refuse(!req.headers['transfer-encoding'] && (!req.headers['content-length'] || req.headers['content-length'] === '0'), 400);
          const result = await candidate.http(req.method, req.url.slice(CONTROL_PREFIX.length), token, obj);
          json(res, 200, result);
        } catch (e) { json(res, [400, 401, 403, 404, 409, 410, 413, 415, 429, 503].includes(e.status) ? e.status : 503, { error: 'control_refused' }); }
        return;
      }
      const url = route(req);
      if (url === '/v1/pair' && req.method === 'POST') { const obj = await body(req, 1024); keys(obj, ['bootstrap', 'credential']); json(res, 200, credentials.pair(obj.bootstrap, obj.credential)); return; }
      const device = credentials.device(req.headers.authorization);
      if (url.startsWith('/v1/push/')) {
        refuse(push, 503, 'push not enabled');
        refuse(!device.test, 403, 'test identities cannot use push');
        const getRecord = /^\/v1\/push\/reachouts\/([A-Za-z0-9_-]{1,100})$/.exec(url);
        if (req.method === 'GET' && getRecord) { json(res, 200, push.lookup(device, getRecord[1])); return; }
        if (url === '/v1/push/settings' && req.method === 'GET') { json(res, 200, { settings: push.device(device.deviceID).settings ?? null }); return; }
        const kind = url === '/v1/push/enrollment' ? 'enrollment' : url === '/v1/push/settings' ? 'settings' : null;
        if ((kind && req.method === 'PUT') || (url === '/v1/push/events' && req.method === 'POST')) {
          const timeout = setTimeout(() => req.destroy(), 5000);
          let obj;
          try { obj = await body(req, 4096); } finally { clearTimeout(timeout); }
          const result = await push.serial(() => {
            const current = credentials.device(req.headers.authorization);
            return kind ? push.update(current, kind, obj) : push.event(current, obj);
          });
          json(res, 200, result); return;
        }
        throw new Refusal(404, 'push route not allowed');
      }
      if (url === '/v1/pair/ack' && req.method === 'POST') {
        refuse(!device.test, 403, 'test identity cannot acknowledge phone pairing');
        const obj = await body(req, 1024); keys(obj, []);
        delete device.pairRecovery; credentials.save(); json(res, 200, { acknowledged: true }); return;
      }
      if (url === '/v1/health' && req.method === 'GET') { await desktop(signal); json(res, 200, { version: 1 }); return; }
      if (url === '/v1/chief' && req.method === 'GET') { refuse(!device.test, 403, 'test identity has no chief access'); json(res, 200, { sessionID: chief() }); return; }
      if (/^\/v1\/sessions(?:\?|$)/.test(url) && req.method === 'GET') {
        const params = new URLSearchParams(url.split('?')[1] || '');
        refuse([...params.keys()].every(k => ['limit', 'cursor'].includes(k) && params.getAll(k).length === 1), 400, 'unexpected session pagination field');
        const limit = params.get('limit') ?? '200', cursor = params.get('cursor');
        refuse(/^[1-9][0-9]{0,2}$/.test(limit) && Number(limit) <= 200, 400, 'invalid session limit');
        refuse(!params.has('cursor') || /^[A-Za-z0-9_-]{1,1024}$/.test(cursor), 400, 'invalid session cursor');
        const port = await desktop(signal);
        // A synthetic identity sees only its own target, even if it lives beyond
        // the first page. Never expose another session's metadata or cursor.
        const obj = device.test
          ? { data: [(await readJSON(port, `/api/session/${device.test.sessionID}`, signal)).data] }
          : await readJSON(port, `/api/session?limit=${limit}&${cursor ? `cursor=${cursor}` : 'order=desc'}`, signal);
        refuse(Array.isArray(obj.data), 502, 'invalid session page');
        const next = device.test ? null : obj.cursor?.next;
        refuse(next == null || (typeof next === 'string' && /^[A-Za-z0-9_-]{1,1024}$/.test(next)), 502, 'invalid upstream session cursor');
        json(res, 200, { data: obj.data.filter(s => s && (!device.test || s.id === device.test.sessionID)).map(s => ({ id: s.id, title: s.title, time: s.time, parentID: s.parentID })),
          ...(next ? { cursor: { next } } : {}) }); return;
      }
      // Explicit picker action is the only boundary granting session access. No automatic chief grant.
      if (url === '/v1/selection' && req.method === 'POST') {
        const obj = await body(req, 1024); keys(obj, ['sessionID', 'mode']);
        refuse(SID.test(obj.sessionID) && ['chief', 'explicit'].includes(obj.mode), 400, 'invalid selection');
        refuse(!device.test || (obj.mode === 'explicit' && obj.sessionID === device.test.sessionID), 403, 'test target scope');
        const port = await desktop(signal);
        const session = await readJSON(port, `/api/session/${obj.sessionID}`, signal);
        refuse((session.data ?? session)?.id === obj.sessionID, 404, 'session unavailable');
        refuse(obj.mode !== 'chief' || chief() === obj.sessionID, 409, 'chief changed');
        const current = credentials.device(req.headers.authorization);
        Object.assign(current, { sessionID: obj.sessionID, mode: obj.mode, generation: token() }); credentials.save();
        json(res, 200, { sessionID: current.sessionID, generation: current.generation }); return;
      }
      const rich = /^\/v1\/sessions\/(ses_[a-zA-Z0-9]{1,100})\/(assets|canvas|canvas-show)\/([a-zA-Z0-9_-]+)$/.exec(url);
      if (rich) {
        const [, sid, kind, action] = rich;
        const owner = lease(req, sid), binding = { device: owner.deviceID, sid, generation: owner.generation };
        const port = await desktop(signal); lease(req, sid);
        if (kind === 'assets' && action === 'resolve' && req.method === 'POST') {
          const obj = await body(req); keys(obj, ['messageID', 'reference']);
          const { directory, record } = await authoritative(port, sid, obj.messageID, signal);
          const file = exactReference(record, obj.reference), bytes = readAsset(file, directory), info = assetDescription(file, bytes);
          lease(req, sid);
          if (!info.preview) { json(res, 200, info); return; }
          const assetID = assets.grant(binding, { messageID: obj.messageID, reference: obj.reference, digest: hash(bytes), info });
          json(res, 200, { assetID, ...info }); return;
        }
        if (kind === 'assets' && req.method === 'GET') {
          const cap = assets.get(action, binding);
          const { directory, record } = await authoritative(port, sid, cap.messageID, signal);
          const file = exactReference(record, cap.reference), bytes = readAsset(file, directory); validateBytes(bytes, file.mime);
          check(hash(bytes) === cap.digest, 409); lease(req, sid); signal.throwIfAborted();
          const [start, end] = byteRange(req.headers.range, bytes.length);
          res.writeHead(req.headers.range ? 206 : 200, { 'Content-Type': cap.info.mime, 'Content-Length': end - start + 1, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Accept-Ranges': 'bytes', ...(req.headers.range ? { 'Content-Range': `bytes ${start}-${end}/${bytes.length}` } : {}) });
          res.end(bytes.subarray(start, end + 1)); return;
        }
        if (kind === 'canvas-show' && req.method === 'POST') {
          const obj = await body(req, 256 * 1024);
          if (action === 'resolve') {
            keys(obj, ['messageID', 'blockOrdinal', 'latest']);
            check(obj.latest === undefined || typeof obj.latest === 'boolean', 400);
            const { directory, record } = await authoritative(port, sid, obj.messageID, signal);
            const association = canvasShowAssociation(record, obj.blockOrdinal);
            const { key } = await hostCanvas(port, '/connect', { directory, sessionId: sid }, signal);
            check(typeof key === 'string', 502);
            const snapshot = await hostCanvas(port, '/request', { key, path: '/api/snapshot' }, signal);
            check(snapshot.session?.sessionId === sid && snapshot.session?.directory === directory, 403);
            const latest = snapshot.views?.find(v => v.id === association.viewId)?.latest;
            check(Number.isSafeInteger(latest) && latest >= association.revision, 502);
            const panel = { key, ...association, association, revision: obj.latest === true ? latest : association.revision, sessionKey: snapshot.session.key, messageID: obj.messageID, ordinal: obj.blockOrdinal };
            const revision = await hostCanvas(port, '/request', { key, path: `/api/revision?id=${panel.viewId}&revision=${panel.revision}` }, signal);
            if (obj.latest === true && ['openui', 'html'].includes(revision.content?.format)) panel.format = revision.content.format;
            const content = showRevision(revision, panel);
            panel.latest = latest;
            lease(req, sid);
            const panelID = panels.grant(binding, panel, 4 * 60 * 60 * 1000);
            json(res, 200, { panelID, viewId: panel.viewId, revision: panel.revision, latest, ...content }); return;
          }
          if (['page', 'library'].includes(action)) {
            keys(obj, action === 'page' ? ['panelID', 'offset'] : ['panelID', 'name', 'offset']);
            const panel = panels.get(obj.panelID, binding); check(panel.viewId, 409);
            const { record } = await authoritative(port, sid, panel.messageID, signal);
            check(JSON.stringify(canvasShowAssociation(record, panel.ordinal)) === JSON.stringify(panel.association), 409);
            if (action === 'page' && (obj.offset ?? 0) === 0) {
              const snapshot = await hostCanvas(port, '/request', { key: panel.key, path: '/api/snapshot' }, signal);
              check(snapshot.session.key === panel.sessionKey, 403);
              panel.latest = snapshot.views.find(v => v.id === panel.viewId)?.latest;
              panel.pageDigest = undefined;
            }
            const revision = await hostCanvas(port, '/request', { key: panel.key, path: `/api/revision?id=${panel.viewId}&revision=${panel.revision}` }, signal);
            const content = showRevision(revision, panel);
            lease(req, sid);
            const source = action === 'page' ? canvasPage({ ...content, viewId: panel.viewId, revision: panel.revision, disabled: panel.latest !== panel.revision }) : canvasLibrary(obj.name, content.source, content.format);
            if (action === 'page') {
              const digest = hash(Buffer.from(source));
              check(!panel.pageDigest || panel.pageDigest === digest, 409); panel.pageDigest = digest;
            }
            json(res, 200, { latest: panel.latest, ...canvasChunk(source, obj.offset ?? 0) }); return;
          }
          check(['submit', 'retry', 'status'].includes(action), 404);
          keys(obj, ['panelID', 'id', 'action', 'data', 'notes']);
          const panel = panels.get(obj.panelID, binding);
          check(panel.viewId, 409);
          const { directory, record } = await authoritative(port, sid, panel.messageID, signal);
          check(JSON.stringify(canvasShowAssociation(record, panel.ordinal)) === JSON.stringify(panel.association), 409);
          check(typeof obj.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(obj.id), 400);
          check(typeof obj.action === 'string' && obj.action.trim().length > 0 && obj.action.length <= 120 && JSON.stringify(obj.data ?? null).length <= 32000 && typeof (obj.notes ?? '') === 'string' && (obj.notes ?? '').length <= 4000, 400);
          // Installed Canvas SubmissionSchema canonicalizes action with .trim().
          // Bind identity, dispatch and status matching to that SAME canonical text.
          const submission = { id: obj.id, sessionKey: panel.sessionKey, viewId: panel.viewId, revision: panel.revision, action: obj.action.trim(), data: obj.data ?? null, notes: obj.notes ?? '' };
          const origin = { messageID: panel.messageID, blockOrdinal: panel.ordinal, toolID: panel.toolID };
          const identity = JSON.stringify({ binding, origin, submission }), previous = submissions.get(obj.id);
          check(!previous || previous.identity === identity, 409);
          if (action === 'status') {
            check(previous, 404);
            if (previous.receiptConfirmed) { lease(req, sid); json(res, 200, previous.result); return; }
            const snapshot = await hostCanvas(port, '/request', { key: panel.key, path: '/api/snapshot' }, signal);
            check(snapshot.session.key === panel.sessionKey && snapshot.session.sessionId === sid && snapshot.session.directory === directory, 403);
            const interaction = snapshot.interactions.find(i => i.id === obj.id && i.viewId === panel.viewId && i.revision === panel.revision && i.action === submission.action);
            previous.result = canvasDeliveryResult(obj.id, interaction);
            if (['queued', 'sending', 'uncertain'].includes(previous.result.status)) {
              previous.receiptConfirmed = await canvasReceiptConfirmed(port, sid, panel, interaction, obj.id, signal);
              // Absence of a durable receipt is expected while a worker is queued/busy.
              // Keep the host's pending state so the native bounded poller can continue.
              // Genuine host uncertainty remains terminal unless exact proof upgrades it.
              if (previous.receiptConfirmed) previous.result = { id: obj.id, status: 'delivered', detail: 'Delivery confirmed from the exact user message in this session record.' };
            }
            lease(req, sid); json(res, 200, previous.result); return;
          }
          if (action === 'submit' && previous) { lease(req, sid); json(res, 200, previous.result); return; }
          check(action !== 'retry' || previous?.result.status === 'unsent', 409);
          const snapshot = await hostCanvas(port, '/request', { key: panel.key, path: '/api/snapshot' }, signal);
          check(snapshot.session.key === panel.sessionKey && snapshot.views.find(v => v.id === panel.viewId)?.latest === panel.revision, 409, 'Canvas revision changed');
          const revision = await hostCanvas(port, '/request', { key: panel.key, path: `/api/revision?id=${panel.viewId}&revision=${panel.revision}` }, signal);
          showRevision(revision, panel); lease(req, sid);
          check(submissions.size < 4096, 429);
          const entry = { identity, result: { id: obj.id, status: 'uncertain', detail: 'Delivery unknown; never retry automatically' } }; submissions.set(obj.id, entry);
          try {
            const result = await hostCanvas(port, '/request', { key: panel.key, path: `/api/${action}`, body: action === 'retry' ? { id: obj.id } : submission }, signal, true);
            entry.result = canvasDeliveryResult(obj.id, result);
          } catch (error) {
            if (error instanceof OCError) throw error;
            if ([400, 413, 409].includes(error.status)) { submissions.delete(obj.id); throw error; }
            /* Unknown delivery retains identity, without a second dispatch. */
          }
          // A lease can change while the host is accepting input. That is unknown delivery,
          // not a pre-dispatch 409 that the phone may safely correct/reload.
          try { lease(req, sid); } catch { check(false, 503, 'Delivery unknown; target changed after dispatch'); }
          json(res, 200, entry.result); return;
        }
        if (kind === 'canvas' && req.method === 'POST') {
          const obj = await body(req);
          if (action === 'resolve') {
            keys(obj, ['messageID', 'blockOrdinal']);
            const { directory, record } = await authoritative(port, sid, obj.messageID, signal);
            const association = canvasAssociation(record, obj.blockOrdinal);
            const { key } = await hostCanvas(port, '/connect', { directory, sessionId: sid }, signal);
            check(typeof key === 'string', 502);
            const snapshot = await hostCanvas(port, '/request', { key, path: '/api/snapshot' }, signal);
            check(snapshot.session?.sessionId === sid && snapshot.session?.directory === directory, 403);
            const revision = await hostCanvas(port, '/request', { key, path: `/api/revision?id=${association.artifactID}&revision=${association.revision}` }, signal);
            check(revision.sessionKey === snapshot.session.key, 403);
            const latest = snapshot.views?.find(v => v.id === association.artifactID)?.latest;
            lease(req, sid);
            const panelID = panels.grant(binding, { key, ...association, sessionKey: revision.sessionKey, messageID: obj.messageID, ordinal: obj.blockOrdinal });
            json(res, 200, { panelID, artifactID: association.artifactID, revision: association.revision, latest, document: revision.document }); return;
          }
          check(['submit', 'retry', 'status'].includes(action), 404);
          keys(obj, ['panelID', 'id', 'choiceID', 'notes']);
          const panel = panels.get(obj.panelID, binding);
          const { record } = await authoritative(port, sid, panel.messageID, signal);
          check(JSON.stringify(canvasAssociation(record, panel.ordinal)) === JSON.stringify({ artifactID: panel.artifactID, revision: panel.revision, toolID: panel.toolID }), 409);
          check(typeof obj.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(obj.id), 400);
          const submission = { id: obj.id, sessionKey: panel.sessionKey, artifactId: panel.artifactID, revision: panel.revision, choiceId: obj.choiceID, notes: obj.notes ?? '' };
          check(typeof submission.choiceId === 'string' && typeof submission.notes === 'string' && submission.notes.length <= 4000, 400);
          const origin = { messageID: panel.messageID, blockOrdinal: panel.ordinal, toolID: panel.toolID };
          const identity = JSON.stringify({ binding, origin, submission }), previous = submissions.get(obj.id);
          check(!previous || previous.identity === identity, 409);
          if (action === 'status') {
            check(previous, 404);
            const snapshot = await hostCanvas(port, '/request', { key: panel.key, path: '/api/snapshot' }, signal);
            check(snapshot.session.key === panel.sessionKey, 403);
            const interaction = snapshot.interactions.find(i => i.id === obj.id && i.artifactId === panel.artifactID && i.revision === panel.revision && i.choiceId === obj.choiceID);
            if (interaction) previous.result = { id: obj.id, status: interaction.status, detail: interaction.detail };
            lease(req, sid); json(res, 200, previous.result); return;
          }
          if (action === 'submit' && previous) { json(res, 200, previous.result); return; }
          check(action !== 'retry' || previous?.result.status === 'unsent', 409);
          const snapshot = await hostCanvas(port, '/request', { key: panel.key, path: '/api/snapshot' }, signal);
          check(snapshot.session.key === panel.sessionKey && snapshot.views.find(v => v.id === panel.artifactID)?.latest === panel.revision, 409, 'Canvas revision changed');
          const revision = await hostCanvas(port, '/request', { key: panel.key, path: `/api/revision?id=${panel.artifactID}&revision=${panel.revision}` }, signal);
          check(revision.sessionKey === panel.sessionKey && revision.document.choices.some(c => c.id === submission.choiceId), 409);
          lease(req, sid);
          check(submissions.size < 4096, 429);
          const entry = { identity, result: { id: obj.id, status: 'uncertain', detail: 'Delivery unknown; never retry automatically' } }; submissions.set(obj.id, entry);
          try {
            const result = await hostCanvas(port, '/request', { key: panel.key, path: `/api/${action}`, body: action === 'retry' ? { id: obj.id } : submission }, signal);
            entry.result = { id: obj.id, status: result.status, detail: result.detail };
          } catch (error) { if (error instanceof OCError) throw error; /* Stable UUID retained as uncertain; no duplicate dispatch. */ }
          lease(req, sid); json(res, 200, entry.result); return;
        }
        throw new Refusal(404, 'content operation not allowed');
      }
      const match = /^\/v1\/sessions\/(ses_[a-zA-Z0-9]{1,100})\/(messages|state|events|prompt|interrupt)(\?[^#]*)?$/.exec(url);
      if (match) {
        const [, sid, action, query] = match;
        refuse(!query || (action === 'messages' && req.method === 'GET'), 400, 'query not allowed');
        let historyQuery;
        if (action === 'messages') {
          const params = new URLSearchParams(query?.slice(1) || '');
          refuse([...params.keys()].every(k => ['limit', 'order', 'cursor'].includes(k) && params.getAll(k).length === 1), 400, 'unexpected pagination field');
          const limit = params.get('limit') || '100', order = params.get('order'), cursor = params.get('cursor');
          refuse(/^[1-9][0-9]{0,2}$/.test(limit) && Number(limit) <= 200, 400, 'invalid history limit');
          refuse(!params.has('order') || ['asc', 'desc'].includes(order), 400, 'invalid history order');
          refuse(!params.has('cursor') || (cursor && /^[A-Za-z0-9_-]{1,1024}$/.test(cursor) && !params.has('order')), 400, 'invalid history cursor/order');
          historyQuery = `limit=${limit}&` + (cursor ? `cursor=${cursor}` : `order=${order || 'asc'}`);
        }
        lease(req, sid);
        const port = await desktop(signal); lease(req, sid);
        if (req.method === 'GET' && action === 'messages') {
          const obj = await readJSON(port, `/api/session/${sid}/message?${historyQuery}`, signal);
          await learnSenderTitles(obj, port, signal);
          // Projection learns viewing-link origins in memory. No extra Canvas calls just to redact prose.
          lease(req, sid); json(res, 200, phoneProjection(obj, { sessionTitles: senderTitles })); return;
        }
        if (req.method === 'GET' && action === 'state') { const obj = await readJSON(port, '/api/session/active', signal); lease(req, sid); json(res, 200, { active: Object.hasOwn(obj.data, sid) }); return; }
        if (req.method === 'GET' && action === 'events') {
          const filter = new SessionEvents(sid, { project: payload => phoneProjection(payload, { sessionTitles: senderTitles }), diagnostic: fields => diagnostic({ stage: 'events', attempt,
            category: 'skipped', initiator: 'filter', elapsedMs: Math.round(performance.now() - started), ...fields }) });
          await proxy(req, res, signal, port, '/api/event', null, filter, () => lease(req, sid)); return;
        }
        if (req.method === 'POST' && action === 'prompt') {
          const obj = await body(req); keys(obj, ['text', 'delivery', 'resume']);
          refuse(typeof obj.text === 'string' && obj.text.trim().length > 0 && obj.text.length <= 16000, 400, 'invalid text');
          refuse(obj.delivery === undefined || ['queue', 'steer'].includes(obj.delivery), 400, 'invalid delivery');
          refuse(obj.resume === undefined || obj.resume === false, 400, 'invalid resume');
          lease(req, sid); await proxy(req, res, signal, port, `/api/session/${sid}/prompt`, Buffer.from(JSON.stringify(obj))); return;
        }
        if (req.method === 'POST' && action === 'interrupt') {
          const obj = await body(req, 1024); keys(obj, []); lease(req, sid);
          await proxy(req, res, signal, port, `/api/session/${sid}/interrupt?resume=false`, Buffer.from('{}')); return;
        }
      }
      if (req.method === 'GET' && url === '/tts/v1/voices') { await proxy(req, res, signal, ttsPort, '/v1/voices'); return; }
      if (req.method === 'GET' && url === '/asr/health') { await proxy(req, res, signal, asrPort, '/health'); return; }
      if (req.method === 'GET' && url === '/tts/health') { await proxy(req, res, signal, ttsPort, '/health'); return; }
      if (req.method === 'POST' && url === '/tts/v1/audio/speech') {
        const obj = await body(req); keys(obj, ['model', 'voice', 'input', 'response_format']);
        refuse(['model', 'voice', 'input'].every(k => typeof obj[k] === 'string' && obj[k].length > 0 && obj[k].length <= (k === 'input' ? 16000 : 128)) && ['pcm', 'wav'].includes(obj.response_format), 400, 'invalid speech request');
        await proxy(req, res, signal, ttsPort, '/v1/audio/speech', Buffer.from(JSON.stringify(obj))); return;
      }
      throw new Refusal(404, 'route not allowed');
    } catch (e) { if (!res.headersSent && !res.destroyed) json(res, e.status || 503, { error: e.status ? e.message : 'bridge dependency unavailable' }); else res.destroy(); }
    finally { activeHandlers--; }
  });
  server.on('upgrade', (req, socket, head) => {
    // Existing candidate invitations may attach their media while draining;
    // their durable nonterminal call remains a seal blocker throughout attach.
    if (maintenance?.held && !req.url.startsWith('/floating-voice/v1/realtime')) {
      socket.end('HTTP/1.1 503 Refused\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); return;
    }
    if (req.url.startsWith('/floating-voice/v1/realtime')) {
      if (media) media.upgrade(req, socket, head).catch(() => socket.destroy());
      else socket.end('HTTP/1.1 404 Refused\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    // WebSocket upgrades never enter http.createServer's request handler. Capture
    // the missing ASR boundary without retaining URL, bearer, PCM or transcript.
    const started = performance.now();
    let status = 0;
    const proposed = req.headers['x-fv-attempt'];
    const attempt = typeof proposed === 'string' && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(proposed) ? proposed : crypto.randomUUID();
    let closeInfo = { initiator: 'client', reason: 'downstream_closed' };
    diagnostic({ stage: 'asr', attempt, category: 'begin', elapsedMs: 0 });
    socket.once('close', () => diagnostic({ stage: 'asr', attempt, category: status === 101 ? 'complete' : 'failed', elapsedMs: Math.round(performance.now() - started), status, ...closeInfo }));
    let up;
    try {
      refuse(route(req) === '/asr/v1/transcribe?partials=1' && req.method === 'GET', 404, 'upgrade route not allowed');
      credentials.device(req.headers.authorization);
      refuse(req.headers.upgrade?.toLowerCase() === 'websocket' && req.headers['sec-websocket-version'] === '13' && /^[A-Za-z0-9+/]{22}==$/.test(req.headers['sec-websocket-key'] || ''), 400, 'invalid upgrade');
      up = open(asrPort, 'GET', '/v1/transcribe?partials=1', null, { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Key': req.headers['sec-websocket-key'], 'Sec-WebSocket-Version': '13' });
      let remote;
      const timer = setTimeout(() => { closeInfo = { initiator: 'watchdog', reason: 'hard_deadline' }; socket.destroy(); }, 180000);
      const check = setInterval(() => { try { credentials.device(req.headers.authorization); } catch { closeInfo = { initiator: 'bridge', reason: 'lease_invalid' }; socket.destroy(); } }, 1000);
      socket.on('close', () => { clearTimeout(timer); clearInterval(check); up.destroy(); remote?.destroy(); });
      socket.on('error', () => socket.destroy());
      up.on('error', e => {
        if (closeInfo.reason === 'downstream_closed') closeInfo = { initiator: 'upstream', reason: 'transport' };
        if (!status && ['ECONNREFUSED', 'ECONNRESET'].includes(e.code)) {
          status = 503;
          const body = JSON.stringify({ error: 'speech_unavailable', service: 'asr', endpoint: `127.0.0.1:${asrPort}` });
          socket.end(`HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Type: application/json\r\nX-FV-Speech-Service: asr\r\nX-FV-Speech-Endpoint: 127.0.0.1:${asrPort}\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
        } else socket.destroy();
      }); up.on('timeout', () => { closeInfo = { initiator: 'watchdog', reason: 'upstream_idle' }; up.destroy(); });
      up.on('response', r => { status = 502; r.destroy(); socket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n'); });
      up.on('upgrade', (r, peer, first) => {
        remote = peer;
        const expected = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        if (r.statusCode !== 101 || r.headers['sec-websocket-accept'] !== expected) { peer.destroy(); socket.destroy(); return; }
        status = 101;
        diagnostic({ stage: 'asr', attempt, category: 'ready', elapsedMs: Math.round(performance.now() - started), status });
        peer.on('end', () => { closeInfo = { initiator: 'upstream', reason: 'clean_end' }; });
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${expected}\r\n\r\n`);
        if (first.length) socket.write(first); if (head.length) peer.write(head);
        // A duplex cycle is not a linear pipeline: passing socket twice installs
        // duplicate pipeline/eos close watchers (11 on one upgraded socket).
        // Pipes retain backpressure; couple failures/closure explicitly instead.
        peer.on('error', () => socket.destroy());
        peer.once('close', () => socket.destroy());
        // A client FIN ends only the peer's writable side. Keep the return path
        // open for its final transcript; idle/hard deadlines still bound silence.
        socket.pipe(peer).pipe(socket);
      }); up.end();
    } catch (e) { status = e.status || 503; socket.end(`HTTP/1.1 ${status} Refused\r\nConnection: close\r\n\r\n`); }
  });
  server.on('connection', s => {
    if (++connections > 12) s.destroy();
    sockets.add(s); s.on('close', () => { sockets.delete(s); connections--; });
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000; server.keepAliveTimeout = 1000;
  const finalizers = [];
  server.shutdown = () => { for (const fn of finalizers) fn(); media?.close(); for (const s of sockets) s.destroy(); server.close(); };
  server.workStats = () => ({ activeUpstreams, peakUpstreams });
  server.openVoiceStats = () => media?.stats() ?? { sessions: 0, pendingJobs: 0, pendingUpgrades: 0 };
  server.localStats = () => ({ connections, activeHandlers, activeUpstreams, startupChecks,
    ...ownerStats(),
    ...(push?.localStats() ?? {}),
    mediaSessions: media?.stats().sessions ?? 0, mediaJobs: media?.stats().pendingJobs ?? 0,
    mediaUpgrades: media?.stats().pendingUpgrades ?? 0, mediaPCM: media?.stats().inputPCMBytes ?? 0,
    mediaRaw: media?.stats().rawBytes ?? 0 });
  if (maintenance) {
    maintenance.counts = server.localStats;
    maintenance.listening = () => server.listening;
    maintenance.stopListening = () => server.listening ? new Promise((resolve, reject) => server.close(e => e ? reject(e) : resolve())) : Promise.resolve();
  }
  if (candidate) {
    const timer = setInterval(() => { push.serial(() => candidate.recover()).catch(() => {}); }, 1000);
    timer.unref(); finalizers.push(() => clearInterval(timer));
  }
  server.once('listening', () => {
    startupChecks++;
    ocClient.check(discover).catch(() => ocClient.note('self_check_failed')).finally(() => { startupChecks--; });
  });
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [command, file, arg] = process.argv.slice(2);
  if (command === 'provision') {
    // Secret goes ONLY into ignored private config for signing, never stdout/argv/URLs.
    const bootstrap = token();
    fs.writeFileSync(file, JSON.stringify({ bootstrap: hash(bootstrap), expires: Date.now() + pairingWindowMs, devices: {} }), { flag: 'wx', mode: 0o600 });
    fs.writeFileSync(arg, JSON.stringify({ bootstrap }), { flag: 'wx', mode: 0o600 });
  } else if (command === 'revoke') { new Credentials(file).revoke(arg); }
  else if (command === 'serve') {
    const port = Number(arg);
    refuse(Number.isInteger(port) && port > 1024 && port < 65536, 400, 'explicit loopback port required');
    deploymentPreflight();
    const credentials = new Credentials(file);
    const diagnostic = rotatingDiagnostics(path.join(path.dirname(file), 'bridge-stages.jsonl'));
    const ocClient = new OpenChamberClient({ diagnostic });
    const desktopJSON = async url => {
      const context = await ocClient.prepare(discoverDesktop());
      return getJSON(context.port, url, { open: (port, method, route, data, headers, signal) => {
        const request = upstream(port, method, route, data, { ...headers, ...context.headers }, signal);
        request.on('response', response => {
          if (context.paired && [401, 403].includes(response.statusCode)) response.authError = ocClient.rejected();
        });
        return request;
      } });
    };
    let push, sender, maintenance, owner, server;
    // Deployment is deliberately opt-in; this lane never restarts the installed bridge.
    if (process.env.FV_PUSH_ENABLED === '1') {
      push = new PushService({ store: new PushStore(path.join(path.dirname(file), 'push')), apns: createAPNs(), chief: readChief, activeDevices: () => credentials.activeDevices(), diagnostic,
        validateOrigin: async request => {
          const session = await desktopJSON(`/api/session/${request.session}`);
          refuse((session.data ?? session).id === request.session, 409, 'origin session unavailable');
          if (request.messageID) {
            const message = await desktopJSON(`/api/session/${request.session}/message/${request.messageID}`);
            const record = message.data ?? message;
            refuse((record.id ?? record.info?.id) === request.messageID && (!record.info?.sessionID || record.info.sessionID === request.session), 409, 'origin message unavailable');
          }
        } });
      maintenance = new Maintenance(push.store.directory);
      push.maintenance = maintenance;
    }
    // Disabling push must not bypass a persisted hold in its existing directory.
    if (!maintenance && fs.existsSync(path.join(path.dirname(file), 'push'))) maintenance = new Maintenance(path.join(path.dirname(file), 'push'));
    try {
      const candidateEnabled = process.env.FV_OPEN_VOICE_ENABLED === '1';
      const mediaEnabled = process.env.FV_OPEN_VOICE_MEDIA_ENABLED === '1';
      if (candidateEnabled || mediaEnabled) {
        refuse(candidateEnabled && mediaEnabled && push, 503, 'explicit owner candidate/media/push opt-ins required');
        const { readOpenVoiceConfig, startOpenVoiceBootstrap } = await import('./open-voice-bootstrap.mjs');
        owner = await startOpenVoiceBootstrap({ config: readOpenVoiceConfig(process.env.FV_OPEN_VOICE_CONFIG), push });
      }
      server = createBridge({ credentials, push, diagnostic, ocClient, maintenance,
        openVoiceCandidate: owner?.candidate, openVoiceMedia: owner?.media, ownerStats: () => owner?.stats() ?? {} });
      const listen = () => server.listening ? Promise.resolve() : new Promise((resolve, reject) => {
        const failed = e => { server.removeListener('listening', ready); reject(e); };
        const ready = () => { server.removeListener('error', failed); console.error(`Bridge listening on port ${port}`); resolve(); };
        server.once('error', failed); server.once('listening', ready); server.listen(port, '127.0.0.1');
      });
      if (maintenance) maintenance.startListening = listen;
      if (maintenance && owner) maintenance.refresh = owner.refresh;
      if (owner) await owner.attach(push.openVoice);
      if (push) sender = await startSender(push);
      if (!maintenance?.held) await listen();
      let shuttingDown;
      const shutdown = () => shuttingDown ??= (async () => {
        server.shutdown();
        await owner?.close();
        await sender?.close();
        while (server.openVoiceStats().pendingJobs || server.openVoiceStats().pendingUpgrades) await new Promise(resolve => setTimeout(resolve, 25));
        process.exit(0);
      })().catch(() => { shuttingDown = undefined; diagnostic({ stage: 'owner_shutdown', category: 'work_pending' }); });
      process.on('SIGTERM', shutdown);
      process.on('SIGINT', shutdown);
    } catch {
      server?.shutdown();
      await Promise.all([sender?.close(), owner?.close()]);
      throw new Error('bridge_startup_refused');
    }
  } else { throw new Error('use provision PRIVATE_STORE PRIVATE_BUILD_CONFIG | revoke PRIVATE_STORE DEVICE_ID | serve PRIVATE_STORE PORT'); }
}
