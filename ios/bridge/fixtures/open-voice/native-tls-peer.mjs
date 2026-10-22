// SCRIPTED TEST PEER ONLY. No production control authority, APNs or local-chain adapter.
// Start with no arguments; configuration/credentials arrive once on bounded stdin.
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import { createSession, validateClientEvent, ERROR_CODES } from '../../open-voice-profile.mjs';

const vectors = JSON.parse(fs.readFileSync(new URL('./control-vectors.json', import.meta.url)));
const prefix = '/floating-voice/voice/v1', mediaPath = '/floating-voice/v1/realtime?model=local-chain-m1';
const modes = ['normal', 'ws-302', 'http-302', 'oversized-text', 'immediate-commit', 'idle-auto-pong', 'idle-no-pong'];
const counters = Object.fromEntries(['http_requests','ws_upgrades','ws_opened','ws_messages','app_events_sent','pings_received','pongs_sent',
  'commit_acks','transcripts','redirects','trap_requests','trap_authorization_present','role_denials','idle_elapsed','connections','tls_errors','startup_step'].map(k => [k, 0]));
const sockets = new Set(), peers = new Set(), timers = new Set(), servers = [];
let config, trapPort = null, mediaUsed = false, callState = 'accepted', active, sequence = 0, commands = 0, stopping = false, started = false, ready = false;
const hash = value => crypto.createHash('sha256').update(value).digest();
const exact = (o, keys) => {
  if (!o || typeof o !== 'object' || Array.isArray(o) || Object.keys(o).some(k => !keys.includes(k))) throw new Error();
};
function output(event) {
  if (process.stdout.writableLength > 16384) { stop(1); return; }
  process.stdout.write(JSON.stringify(event) + '\n');
}
function after(ms, fn) { const timer = setTimeout(() => { timers.delete(timer); fn(); }, ms); timers.add(timer); return timer; }
function credential(req, role, count = true) {
  const token = /^Bearer ([A-Za-z0-9_-]{1,128})$/.exec(req.headers.authorization || '')?.[1];
  const valid = token && crypto.timingSafeEqual(hash(token), hash(config[role + '_token']));
  if (!valid && count) counters.role_denials++;
  return !!valid;
}
function ownedFile(root, file) {
  if (typeof file !== 'string' || file.length > 2048 || path.dirname(file) !== root || path.resolve(file) !== file) throw new Error();
  const s = fs.lstatSync(file);
  if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o777) !== 0o600) throw new Error();
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try { const opened = fs.fstatSync(fd); if (opened.ino !== s.ino || opened.dev !== s.dev || opened.size > 32768) throw new Error(); return fs.readFileSync(fd); }
  finally { fs.closeSync(fd); }
}
function json(res, status, value) {
  const data = JSON.stringify(value);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data), 'Cache-Control': 'no-store' }); res.end(data);
}
async function body(req) {
  if (req.headers['transfer-encoding'] || !/^application\/json(?:;.*)?$/.test(req.headers['content-type'] || '')) throw new Error();
  const n = Number(req.headers['content-length']); if (!Number.isInteger(n) || n < 1 || n > 4096) throw new Error();
  const chunks = []; let count = 0;
  for await (const bytes of req) { count += bytes.length; if (count > 4096) throw new Error(); chunks.push(bytes); }
  const result = JSON.parse(Buffer.concat(chunks)); exact(result, Object.keys(result)); return result;
}
function owner(o, extra = []) {
  exact(o, [...Object.keys(vectors.owner_body), ...extra]);
  if (!Object.entries(vectors.owner_body).every(([k, v]) => o[k] === v)) throw new Error();
}
function redirect(res, ws = false) {
  counters.redirects++;
  res.writeHead(302, { Location: `${ws ? 'wss' : 'https'}://127.0.0.1:${trapPort}${ws ? mediaPath : '/fixture-trap'}`, 'Content-Length': '0' }); res.end();
}
async function control(req, res) {
  counters.http_requests++;
  req.on('error', () => res.destroy()); res.on('error', () => {});
  try {
    if (req.headers.origin !== undefined || req.url.length > 256 || /[\\%#?]/.test(req.url)) throw new Error();
    if (req.method === 'GET' && (req.headers['transfer-encoding'] || req.headers['content-length'] && req.headers['content-length'] !== '0')) throw new Error();
    const route = req.url.slice(prefix.length);
    if (!req.url.startsWith(prefix + '/')) return json(res, 404, { error: 'fixture_refused' });
    const callerRequest = route === '/calls' && req.method === 'POST';
    const base = '/calls/' + vectors.caller_response.call_id;
    const callerStatus = route === base && req.method === 'GET' && credential(req, 'caller', false);
    if (!callerStatus && !credential(req, callerRequest ? 'caller' : 'device')) return json(res, 403, { error: 'fixture_refused' });
    const reply = value => config.mode === 'http-302' ? redirect(res) : json(res, 200, value);
    const o = req.method === 'GET' ? {} : await body(req);
    if (callerRequest) {
      exact(o, Object.keys(vectors.request));
      if (!/^[0-9a-f-]{36}$/.test(o.operation_id) || o.project_id !== vectors.request.project_id || !['decision','goal-risk'].includes(o.reason)
        || typeof o.summary !== 'string' || !o.summary.trim() || o.summary.length > 240
        || o.expires_in !== undefined && (!Number.isInteger(o.expires_in) || o.expires_in < 30 || o.expires_in > 300)) throw new Error();
      callState = 'ringing'; return reply({ call_id: vectors.caller_response.call_id, status: callState });
    }
    if (route === '/device-capability' && req.method === 'PUT') {
      exact(o, Object.keys(vectors.capability));
      if (typeof o.enabled !== 'boolean' || o.profile !== vectors.profile || typeof o.build !== 'string' || o.build.length > 40
        || !Number.isInteger(o.expires_in) || o.expires_in < 1 || o.expires_in > 300) throw new Error();
      return reply({ acknowledged: true, expires_at: Date.now() + o.expires_in * 1000 });
    }
    if (route === base && req.method === 'GET') return reply(callerStatus ? { call_id: vectors.caller_response.call_id, status: callState }
      : { ...vectors.recipient_response, status: callState, expires_at: Date.now() + 60000 });
    const action = route.startsWith(base + '/') ? route.slice(base.length + 1) : '';
    if (req.method !== 'POST' || !['accept','decline','end','media','media-ready'].includes(action)) return json(res, 404, { error: 'fixture_refused' });
    owner(o, action === 'media-ready' ? ['media_epoch','session_id','native_capture_ready'] : action === 'end' ? ['operation_id','reason'] : []);
    if (action === 'accept') { if (!['ringing','accepted'].includes(callState)) throw new Error(); callState = 'accepted'; }
    if (action === 'decline') callState = 'rejected';
    if (action === 'end') {
      if (o.reason !== 'deliberate-user' || !/^[0-9a-f-]{36}$/.test(o.operation_id)) throw new Error();
      callState = 'ended'; for (const ws of peers) ws.close(1000);
      return reply({ operation_id: o.operation_id, kind: 'end', state: 'prepared' });
    }
    if (action === 'media') {
      if (callState !== 'accepted') throw new Error();
      return reply({ ...vectors.media_response, media_lease: config.media_token, expires_at: Date.now() + 60000 });
    }
    if (action === 'media-ready') {
      if (!active?.configured || active.ws.readyState !== WebSocket.OPEN || o.media_epoch !== '1' || o.session_id !== 'sess_fixture' || o.native_capture_ready !== true) throw new Error();
      return reply(vectors.media_ready_response);
    }
    reply({ call_id: vectors.caller_response.call_id, status: callState });
  } catch { if (!res.headersSent) json(res, 400, { error: 'fixture_refused' }); else res.destroy(); }
}
function send(ws, event) {
  if (ws.readyState !== WebSocket.OPEN) return;
  const data = JSON.stringify({ event_id: 'evt_fixture_' + ++sequence, ...event });
  if (ws.bufferedAmount + Buffer.byteLength(data) + 14 > 262144) { ws.terminate(); return; }
  counters.app_events_sent++; ws.send(data);
}
function session(ws) {
  counters.ws_opened++; peers.add(ws);
  const state = active = { ws, configured: false }; let effective = createSession('sess_fixture').value, samples = 0, consumed = 0, itemNumber = 0, canonical;
  ws.on('error', () => ws.terminate()); ws.on('close', () => { peers.delete(ws); if (active === state) active = undefined; });
  ws.on('ping', bytes => {
    counters.pings_received++;
    if (counters.pings_received > 256) { ws.close(1008); return; }
    if (config.mode !== 'idle-no-pong' && ws.readyState === WebSocket.OPEN && ws.bufferedAmount < 262000) { counters.pongs_sent++; ws.pong(bytes); }
  });
  send(ws, { type: 'session.created', session: effective });
  if (config.mode === 'oversized-text') ws.send('x'.repeat(65537));
  if (config.mode.startsWith('idle-')) after(16000, () => { counters.idle_elapsed++; output({ event: 'idle_elapsed', counters: { ...counters } }); });
  ws.on('message', (data, binary) => {
    if (binary || ++counters.ws_messages > 1000) { ws.close(1008); return; }
    const result = validateClientEvent(data.toString(), { effectiveSession: effective, bufferSamples: samples, canonicalItem: canonical });
    if (!result.ok) { send(ws, { type: 'error', error: result.error }); return; }
    const e = result.value;
    if (e.type === 'session.update') {
      effective = result.effect.session; state.configured = true; send(ws, { type: 'session.updated', session: effective });
      send(ws, { type: 'vs.flow', media_epoch: '1', input_consumed_samples: consumed }); return;
    }
    if (!state.configured) { send(ws, { type: 'error', error: { type: 'invalid_request_error', code: 'context_required', message: ERROR_CODES.context_required, param: null } }); return; }
    if (e.type === 'input_audio_buffer.append') {
      samples += result.effect.samples; consumed += result.effect.samples;
      if (samples > 2160000) { ws.close(1008); return; }
      send(ws, { type: 'vs.flow', media_epoch: '1', input_consumed_samples: consumed });
    } else if (e.type === 'input_audio_buffer.clear') { samples = 0; send(ws, { type: 'input_audio_buffer.cleared' }); }
    else if (e.type === 'input_audio_buffer.commit') {
      const item_id = 'item_fixture_' + ++itemNumber, seconds = samples / 24000; samples = 0;
      counters.commit_acks++;
      // Actual frames queued immediately in this receive callback; native may hold only its own send completion.
      send(ws, { type: 'input_audio_buffer.committed', item_id, previous_item_id: null });
      if (config.mode === 'immediate-commit') {
        const item = { id: item_id, object: 'realtime.item', type: 'message', role: 'user', status: 'completed', content: [{ type: 'input_audio', transcript: 'Synthetic transcript.' }] };
        send(ws, { type: 'conversation.item.added', previous_item_id: null, item: { ...item, status: 'in_progress' } });
        send(ws, { type: 'conversation.item.done', previous_item_id: null, item }); counters.transcripts++;
        send(ws, { type: 'conversation.item.input_audio_transcription.completed', item_id, content_index: 0, transcript: 'Synthetic transcript.', usage: { type: 'duration', seconds } });
      }
    } else if (e.type === 'conversation.item.create') canonical = e.item;
    else send(ws, { type: 'error', error: { type: 'invalid_request_error', code: 'unsupported_feature', message: ERROR_CODES.unsupported_feature, param: null } });
  });
}
async function listen(tls, trap = false) {
  if (stopping) throw new Error();
  const server = https.createServer({ ...tls, maxHeaderSize: 8192, handshakeTimeout: 3000 }, trap ? (req, res) => {
    counters.trap_requests++; if (req.headers.authorization !== undefined) counters.trap_authorization_present++; json(res, 403, { error: 'fixture_trap' });
  } : control);
  servers.push(server); server.requestTimeout = 3000; server.headersTimeout = 3000; server.keepAliveTimeout = 1000;
  server.on('tlsClientError', () => { counters.tls_errors++; });
  server.on('connection', socket => {
    if (sockets.size >= 8) { socket.destroy(); return; }
    sockets.add(socket); counters.connections++; socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket));
  });
  server.on('error', () => stop(1));
  const wss = new WebSocketServer({ noServer: true, autoPong: false, perMessageDeflate: false, maxPayload: 65536, clientTracking: false });
  server.once('close', () => wss.close()); wss.on('error', () => {});
  server.on('upgrade', (req, socket, head) => {
    socket.on('error', () => {});
    if (trap) {
      counters.trap_requests++; if (req.headers.authorization !== undefined) counters.trap_authorization_present++;
      socket.end('HTTP/1.1 403 Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); return;
    }
    counters.ws_upgrades++;
    if (req.url !== mediaPath || req.method !== 'GET' || req.headers.origin !== undefined || req.headers['sec-websocket-protocol'] !== undefined || !credential(req, 'media') || mediaUsed) {
      socket.end('HTTP/1.1 403 Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'); return;
    }
    mediaUsed = true;
    if (config.mode === 'ws-302') {
      counters.redirects++;
      socket.end(`HTTP/1.1 302 Found\r\nLocation: wss://127.0.0.1:${trapPort}${mediaPath}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`); return;
    }
    wss.handleUpgrade(req, socket, head, session);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); }); return server.address().port;
}
async function start(o) {
  counters.startup_step = 1;
  exact(o, ['synthetic','root','cert_path','key_path','device_token','caller_token','media_token','mode','trap']);
  if (o.synthetic !== true || !modes.includes(o.mode) || o.trap !== undefined && typeof o.trap !== 'boolean'
    || typeof o.root !== 'string' || o.root.length > 2048 || fs.realpathSync(o.root) !== o.root
    || !o.root.startsWith(fs.realpathSync(os.tmpdir()) + path.sep)) throw new Error();
  const root = fs.lstatSync(o.root);
  if (!root.isDirectory() || root.uid !== process.getuid() || (root.mode & 0o777) !== 0o700) throw new Error();
  const tokens = [o.device_token, o.caller_token, o.media_token];
  if (!tokens.every(v => typeof v === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(v)) || new Set(tokens).size !== 3) throw new Error();
  config = o;
  counters.startup_step = 2;
  const tls = { cert: ownedFile(o.root, o.cert_path), key: ownedFile(o.root, o.key_path), minVersion: 'TLSv1.2' };
  counters.startup_step = 3;
  if (o.trap || o.mode.endsWith('-302')) trapPort = await listen(tls, true);
  const port = await listen(tls); if (stopping) throw new Error(); counters.startup_step = 4; ready = true; output({ event: 'ready', port, trap_port: trapPort });
}
async function closePeers() {
  await Promise.all([...peers].map(ws => new Promise(resolve => {
    const timer = after(250, () => { ws.terminate(); resolve(); });
    ws.once('close', () => { clearTimeout(timer); timers.delete(timer); resolve(); }); ws.close(1000);
  })));
}
function stop(code = 0) {
  if (stopping) return; stopping = true; ready = false;
  for (const timer of timers) clearTimeout(timer); timers.clear();
  process.stdin.destroy(); for (const ws of peers) ws.terminate(); for (const socket of sockets) socket.destroy();
  const fallback = setTimeout(() => process.exit(code || 1), 1000);
  Promise.all(servers.map(server => new Promise(resolve => server.close(resolve)))).then(() => {
    output({ event: 'stopped', counters: { ...counters } }); process.stdout.end(() => { clearTimeout(fallback); process.exit(code); });
  });
}
let input = Buffer.alloc(0);
const startup = after(5000, () => stop(1)); after(60000, () => stop());
process.stdout.on('error', () => stop(1)); process.stdin.on('error', () => stop(1));
process.stdin.on('end', () => stop()); process.on('SIGTERM', () => stop()); process.on('SIGINT', () => stop());
process.on('uncaughtException', () => stop(1)); process.on('unhandledRejection', () => stop(1));
process.stdin.on('data', bytes => {
  if (stopping) return;
  if (input.length + bytes.length > (started ? 512 : 8192)) { stop(1); return; }
  input = Buffer.concat([input, bytes]);
  while (input.includes(10) && !stopping) {
    const index = input.indexOf(10), line = input.subarray(0, index); input = input.subarray(index + 1);
    try {
      const o = JSON.parse(line);
      if (!started) { started = true; clearTimeout(startup); timers.delete(startup); start(o).catch(() => stop(1)); }
      else {
        if (!ready || ++commands > 64) throw new Error();
        exact(o, ['command','request_id']);
        if (o.request_id !== undefined && (!Number.isInteger(o.request_id) || o.request_id < 0 || o.request_id > 1000000)) throw new Error();
        if (o.command === 'shutdown') stop();
        else if (o.command === 'close') closePeers().then(() => { if (!stopping) output({ event: 'closed', request_id: o.request_id, counters: { ...counters } }); });
        else if (o.command === 'counters') output({ event: 'counters', request_id: o.request_id, counters: { ...counters } });
        else throw new Error();
      }
    } catch { stop(1); }
  }
});
