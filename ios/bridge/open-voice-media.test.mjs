import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import http from 'node:http';
import { once, EventEmitter } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';
import { createBridge, rotatingDiagnostics } from './server.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { CONFIG } from './reachout-policy.mjs';
import { validateServerEvent, LIMITS } from './open-voice-profile.mjs';
import { OpenVoiceMedia, MEDIA_PATH, MEDIA_BOUNDS } from './open-voice-media.mjs';
import { createLocalSpeechAdapter, SPEECH_BOUNDS } from './open-voice-speech.mjs';
const v = JSON.parse(fs.readFileSync(new URL('./fixtures/open-voice/control-vectors.json', import.meta.url)));
const vectors = JSON.parse(fs.readFileSync(new URL('./fixtures/open-voice/media-session-vectors.json', import.meta.url)));
const uuid = () => crypto.randomUUID();
const turn = () => new Promise(resolve => setImmediate(resolve));
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
class Peer {
  constructor(url, headers = {}, options = {}) {
    this.events = []; this.used = new Set(); this.waiters = [];
    this.ws = new WebSocket(url, { perMessageDeflate: false, headers, ...options }); this.ws.on('error', () => {});
    this.closed = new Promise(resolve => this.ws.once('close', (code) => resolve(code)));
    this.ws.on('message', b => {
      const e = JSON.parse(b.toString()); this.events.push(e);
      for (const waiter of [...this.waiters]) waiter();
    });
  }
  send(e) { this.ws.send(JSON.stringify(e)); }
  wait(type, predicate = () => true) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { cleanup(); reject(new Error('missing event: ' + type)); }, 2000);
      const cleanup = () => { clearTimeout(timer); this.waiters = this.waiters.filter(w => w !== find); };
      const find = () => {
        const i = this.events.findIndex((e, n) => !this.used.has(n) && e.type === type && predicate(e));
        if (i >= 0) { this.used.add(i); cleanup(); resolve(this.events[i]); }
      };
      this.waiters.push(find); find();
    });
  }
  validate() { for (const e of this.events) assert.ok(validateServerEvent(e).ok, JSON.stringify(e)); }
}
async function fixture(t, { stallMs = 300, adapter: provided, diagnostic = () => {} } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-media-')); fs.chmodSync(root, 0o700);
  let now = Date.parse('2026-10-19T17:00:00Z'); const device = { deviceID: 'fixture-phone' }, sent = [], peers = [];
  const records = { segments: [], submissions: [], syntheses: [] }, closedSessions = new EventEmitter();
  const adapter = provided ?? {
    openSegment: async args => {
      const record = { ...args, bytes: 0 }; records.segments.push(record);
      return { write: async pcm => { record.bytes += pcm.length; }, finish: async () => ({ normal: true, transcript: 'Synthetic speech.' }) };
    },
    submit: async args => { records.submissions.push(args); return { admission_inbox_id: args.planned_inbox_id, source_user_id: 'user_fixture', source_assistant_id: 'assistant_fixture', text: 'Synthetic reply.' }; },
    synthesize: async function* (args) { records.syntheses.push(args); yield Buffer.alloc(4800, 1); yield Buffer.alloc(4800, 1); }
  };
  const push = new PushService({ store: new PushStore(root), apns: async r => { sent.push(r); return { status: 200 }; },
    chief: () => 'ses_SYNTHETIC0030', activeDevices: () => [device], now: () => now, config: CONFIG });
  push.update(device, 'settings', { callsEnabled: true, quietHoursEnabled: true, quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 });
  push.update(device, 'enrollment', { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64), environment: 'sandbox', build: v.capability.build, revision: 1 });
  const credentials = { device: auth => { if (auth !== 'Bearer fixture-device-token') throw Object.assign(new Error('refused'), { status: 403 }); return device; } };
  const server = createBridge({ push, credentials, diagnostic, ocClient: { check: async () => {} },
    openVoiceCandidate: { enabled: true, principal_id: 'fixture-principal', audience: 'fixture-bridge', device_id: device.deviceID, now: () => now,
      resolveTarget: async b => ({ ...b, paired: true, authenticated: true, available: true, idle: true }) },
    openVoiceMedia: { enabled: true, adapter, stallMs, authorityMs: 20, onSessionClosed: owner => closedSessions.emit('closed', owner) } });
  const control = push.openVoice; control.configureMapping(v.mapping); const grant = control.issue(v.grant); control.capability(device, v.capability);
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const base = 'http://127.0.0.1:' + server.address().port, wsURL = base.replace('http:', 'ws:') + MEDIA_PATH;
  t.after(async () => {
    for (const peer of peers) peer.ws.terminate();
    const closed = once(server, 'close'); server.shutdown(); await closed;
    await push.drain(); await turn(); const stats = server.openVoiceStats();
    for (const field of ['sessions','pendingJobs','pendingUpgrades','inputPCMBytes','rawBytes']) assert.equal(stats[field] ?? 0, 0, field);
    assert.ok((stats.inputPeakBytes ?? 0) <= 96000);
    assert.ok((stats.aggregatePeakBytes ?? 0) <= 524288);
    fs.rmSync(root, { recursive: true, force: true });
  });
  const request = async (route, body, token = 'fixture-device-token') => {
    const r = await fetch(base + '/floating-voice/voice/v1' + route, { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const value = await r.json(); return { status: r.status, value };
  };
  const owner = c => Object.fromEntries(['call_uuid', 'owner_epoch', 'binding_revision', 'target_id'].map(k => [k, c[k]]));
  const prepare = async () => {
    const call = await request('/calls', v.request, grant.token); assert.equal(call.status, 200); await push.drain();
    const c = control.recipient(device, call.value.call_id); assert.equal((await request('/calls/' + c.call_id + '/accept', owner(c))).status, 200);
    const mint = await request('/calls/' + c.call_id + '/media', owner(c)); assert.equal(mint.status, 200); return { c, lease: mint.value };
  };
  const connect = async (lease, opts = {}) => {
    const peer = new Peer(opts.url ?? wsURL, { Authorization: 'Bearer ' + (opts.token ?? lease.media_lease), ...opts.headers }, opts.options); peers.push(peer);
    await once(peer.ws, 'open'); const created = await peer.wait('session.created'); return { peer, session: created.session };
  };
  const ready = async ({ c, lease, peer, session }) => {
    peer.send({ type: 'session.update', session: { type: 'realtime' } }); await peer.wait('session.updated');
    assert.equal((await peer.wait('vs.flow')).input_consumed_samples, 0);
    const receipt = await request('/calls/' + c.call_id + '/media-ready', { ...owner(c), media_epoch: lease.media_epoch, session_id: session.id, native_capture_ready: true });
    assert.equal(receipt.status, 200); return receipt.value;
  };
  const start = async () => { const p = await prepare(), connection = await connect(p.lease); const all = { ...p, ...connection }; await ready(all); return all; };
  const compose = async peer => { peer.send({ type: 'conversation.item.create', item: v.canonical_item }); await peer.wait('conversation.item.done', e => e.item.id === v.canonical_item.id); };
  const respond = (peer, operation_id = uuid(), modality = 'audio') => { peer.send({ type: 'response.create', response: { input: [v.canonical_item], metadata: { operation_id }, output_modalities: [modality] } }); return operation_id; };
  return { server, control, push, device, grant, sent, peers, adapter, records, closedSessions, root, base, wsURL, request, owner, prepare, connect, ready, start, compose, respond, advance: ms => { now += ms; } };
}
test('new wire: real HTTP/WS handshake, explicit recognition/composition, one fake admission and PCM reply', async t => {
  const f = await fixture(t), { peer, c, lease, session } = await f.start();
  assert.equal(peer.events[0].type, 'session.created'); assert.equal(session.audio.input.format.rate, 24000);
  for (let i = 0; i < 2; i++) { peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960, 1).toString('base64') }); assert.equal((await peer.wait('vs.flow')).input_consumed_samples, (i + 1) * 480); }
  peer.send({ type: 'input_audio_buffer.commit' }); const transcript = await peer.wait('conversation.item.input_audio_transcription.completed');
  assert.equal(transcript.transcript, 'Synthetic speech.'); assert.equal(transcript.usage.seconds, 0.04); assert.equal(f.records.submissions.length, 0);
  await f.compose(peer); const operation = f.respond(peer); const done = await peer.wait('response.done');
  assert.equal(done.response.status, 'completed'); assert.equal(f.records.submissions.length, 1); assert.equal(f.records.syntheses.length, 1);
  assert.deepEqual(f.records.submissions[0].item, v.canonical_item);
  const op = f.control.operation(c.call_id, operation); assert.equal(op.admission_inbox_id, op.planned_inbox_id);
  assert.notEqual(op.source_user_id, op.admission_inbox_id); assert.equal(op.delivery.state, 'unknown');
  const deltas = peer.events.filter(e => e.type === 'response.output_audio.delta'); assert.equal(deltas.length, 2);
  const order = peer.events.map(e => e.type);
  assert.deepEqual(vectors.bounds, MEDIA_BOUNDS); assert.equal(vectors.path, MEDIA_PATH);
  assert.deepEqual(order.slice(0, 3), vectors.startup);
  let cursor = -1;
  for (const type of vectors.audio_response) { cursor = order.findIndex((value, i) => i > cursor && value === type); assert.ok(cursor >= 0, type); }
  assert.ok(order.indexOf('response.created') < order.indexOf('response.output_item.added'));
  assert.ok(order.indexOf('response.content_part.added') < order.indexOf('response.output_audio.delta'));
  assert.ok(order.indexOf('response.output_audio.done') < order.indexOf('response.done'));
  peer.send({ type: 'vs.playback', media_epoch: lease.media_epoch, response_id: done.response.id, item_id: deltas[0].item_id,
    content_index: 0, playback_epoch: 'play_fixture', rendered_samples: 4800, state: 'completed' });
  peer.send({ type: 'session.update', session: { type: 'realtime' } }); await peer.wait('session.updated');
  assert.deepEqual(f.control.operation(c.call_id, operation).delivery, { state: 'completed', rendered_samples: 4800 }); peer.validate();
});
test('media-close diagnostics use normal durable logger and distinguish peer close despite failing sink', async t => {
  let write = () => {};
  const f = await fixture(t, { diagnostic(row) {
    if (row.stage !== 'open_voice_media') return;
    write(row); throw Error('diagnostic sink failure after write');
  } });
  const file = path.join(f.root, 'terminal-diagnostics.jsonl'); write = rotatingDiagnostics(file);
  const { peer, c, lease } = await f.start();
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await peer.wait('vs.flow');
  peer.ws.close(1000); await peer.closed; await turn(); await turn();
  const rows = fs.readFileSync(file, 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].call_id, c.call_id); assert.equal(rows[0].media_epoch, Number(lease.media_epoch));
  assert.equal(rows[0].cause, 1); assert.equal(rows[0].closeCode, 1000);
  assert.equal(rows[0].requestedCloseCode, 0);
  assert.equal(rows[0].sequence, 1); assert.equal(rows[0].ingressBytes, 960);
  assert.equal(rows[0].consumedSamples, 480);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(JSON.stringify(rows).includes(f.grant.token), false);
  assert.equal(JSON.stringify(rows).includes(lease.media_lease), false);
  assert.equal(f.records.submissions.length, 0);
});
test('speech adapter without configured harness cannot ring or admit a media session', async t => {
  const adapter = createLocalSpeechAdapter({ sttURL: 'ws://127.0.0.1:1/v1/transcribe', ttsURL: 'http://127.0.0.1:1/v1/audio/speech', model: 'synthetic', voice: 'synthetic' });
  const f = await fixture(t, { adapter });
  assert.equal(adapter.readyForCalls, false);
  const result = await f.request('/calls', v.request, f.grant.token);
  assert.equal(result.status, 409); assert.equal(f.sent.length, 0);
  assert.throws(() => adapter.submit({}), /harness_unconfigured/);
  assert.deepEqual(adapter.stats(), { stt: 0, tts: 0 });
});
test('adapter reservation is validated and charged inside aggregate admission, unchanged fake adapters need none', () => {
  const adapter = { openSegment() {}, submit() {}, synthesize() {} };
  for (const n of [NaN, Infinity, -1, 1.5, null, '196608', 524288]) assert.throws(() => new OpenVoiceMedia({ control: {}, adapter: { ...adapter, bufferBudgetBytes: n } }));
  const engine = new OpenVoiceMedia({ control: {}, adapter: { ...adapter, bufferBudgetBytes: 196608 } });
  try {
    engine.reservePCM(96000); engine.reserveRaw(62208);
    assert.throws(() => engine.reserveRaw(1)); assert.throws(() => engine.reservePCM(1));
    assert.equal(engine.stats().aggregatePeakBytes, 524288);
  } finally { engine.close(); }
});
test('assembled new-wire engine uses actual synthetic STT/TTS transports and one explicitly fake harness admission', async t => {
  const service = http.createServer((req, res) => {
    assert.equal(req.url, '/v1/audio/speech'); req.resume(); req.on('end', () => {
      res.writeHead(200, { 'content-type': 'audio/pcm', 'x-sample-format': 's16le', 'x-sample-rate': '16000', 'x-channels': '1' }); res.end(Buffer.alloc(640));
    });
  });
  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false }), sockets = new Set(); let submissions = 0, inputBytes = 0;
  service.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  service.on('upgrade', (req, s, head) => wss.handleUpgrade(req, s, head, p => {
    assert.equal(req.url, '/v1/transcribe?partials=1'); p.on('error', () => {});
    p.on('message', (b, binary) => { if (binary) inputBytes += b.length; else { p.send('{"type":"transcript","text":"synthetic input"}'); p.close(1000); } });
  }));
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  const base = '127.0.0.1:' + service.address().port;
  const adapter = createLocalSpeechAdapter({ sttURL: `ws://${base}/v1/transcribe`, ttsURL: `http://${base}/v1/audio/speech`, model: 'synthetic', voice: 'synthetic',
    submit: async args => { submissions++; return { admission_inbox_id: args.planned_inbox_id, source_user_id: 'user_synthetic', source_assistant_id: 'assistant_synthetic', text: '**Synthetic** reply.' }; } });
  const f = await fixture(t, { adapter, stallMs: 1000 });
  t.after(async () => {
    wss.clients.forEach(p => p.terminate());
    const closing = [...sockets].map(s => new Promise(r => { s.once('close', r); s.destroy(); }));
    await Promise.all([...closing, new Promise(r => wss.close(r)), new Promise(r => service.close(r))]);
    assert.deepEqual(adapter.stats(), { stt: 0, tts: 0 }); assert.equal(sockets.size, 0);
  });
  const { peer } = await f.start();
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await peer.wait('vs.flow');
  peer.send({ type: 'input_audio_buffer.commit' });
  assert.equal((await peer.wait('conversation.item.input_audio_transcription.completed')).transcript, 'synthetic input'); assert.equal(inputBytes, 640);
  await f.compose(peer); f.respond(peer); assert.equal((await peer.wait('response.done')).response.status, 'completed');
  assert.equal(submissions, 1); assert.equal(Buffer.concat(peer.events.filter(e => e.type === 'response.output_audio.delta').map(e => Buffer.from(e.delta, 'base64'))).length, 960);
  assert.ok(f.server.openVoiceStats().aggregatePeakBytes >= SPEECH_BOUNDS.bufferBudgetBytes);
  peer.validate(); assert.deepEqual(adapter.stats(), { stt: 0, tts: 0 });
});
test('effective config and authenticated matching readiness gate audio/items/response; device claim is not enough', async t => {
  const f = await fixture(t), p = await f.prepare(), connection = await f.connect(p.lease), { peer, session } = connection;
  const body = { ...f.owner(p.c), media_epoch: p.lease.media_epoch, session_id: session.id, native_capture_ready: true };
  assert.equal((await f.request('/calls/' + p.c.call_id + '/media-ready', body)).status, 409);
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); assert.equal((await peer.wait('error')).error.code, 'context_required');
  peer.send({ type: 'session.update', session: { type: 'realtime' } }); await peer.wait('session.updated');
  peer.send({ type: 'conversation.item.create', item: v.canonical_item }); assert.equal((await peer.wait('error')).error.code, 'context_required');
  assert.equal((await f.request('/calls/' + p.c.call_id + '/media-ready', { ...body, session_id: 'sess_wrong' })).status, 409);
  assert.equal((await f.request('/calls/' + p.c.call_id + '/media-ready', body, f.grant.token)).status, 403);
  assert.equal((await f.request('/calls/' + p.c.call_id + '/media-ready', body)).status, 200); await f.compose(peer); peer.validate();
});
for (const bad of ['caller', 'device', 'origin', 'query', 'model', 'subprotocol']) test(`upgrade refuses ${bad} without alternative transport`, async t => {
  const f = await fixture(t), { lease } = await f.prepare();
  const opts = bad === 'caller' ? { token: f.grant.token } : bad === 'device' ? { token: 'fixture-device-token' }
    : bad === 'origin' ? { headers: { Origin: 'https://fixture.invalid' } }
    : bad === 'query' ? { url: f.wsURL + '&token=forbidden' } : bad === 'model' ? { url: f.wsURL.replace('local-chain-m1', 'other') }
    : { headers: { 'Sec-WebSocket-Protocol': 'forbidden' } };
  await assert.rejects(f.connect(lease, opts)); assert.equal(f.server.openVoiceStats().sessions, 0);
});
test('compression offers are not negotiated; actual WS frames remain uncompressed', async t => {
  const f = await fixture(t), { lease } = await f.prepare(); const { peer } = await f.connect(lease, { options: { perMessageDeflate: true } });
  assert.equal(peer.ws.extensions, ''); assert.equal(peer.events[0].type, 'session.created');
});
test('once-only/expired/replaced lease cannot reconnect; current epoch replacement closes old WS synchronously', async t => {
  const f = await fixture(t), all = await f.start(); await assert.rejects(f.connect(all.lease));
  const mint = await f.request('/calls/' + all.c.call_id + '/media', f.owner(all.c)); assert.equal(mint.status, 200);
  assert.equal(await all.peer.closed, 1008); await assert.rejects(f.connect(all.lease));
  f.advance(60001); await assert.rejects(f.connect(mint.value)); assert.equal(f.server.openVoiceStats().sessions, 0);
});
for (const expiry of ['grant', 'capability']) test(`attached socket survives token TTL then closes on ${expiry} authority expiry`, async t => {
  const f = await fixture(t), { peer } = await f.start();
  if (expiry === 'grant') f.control.state.grants['v:' + f.grant.grant_id].expires_at = Date.parse('2026-10-19T17:02:00Z');
  f.advance(61000); peer.send({ type: 'session.update', session: { type: 'realtime' } }); await peer.wait('session.updated');
  f.advance(expiry === 'grant' ? 60000 : 240000); assert.equal(await peer.closed, 1008);
});
test('RFC fragmented text accepted; binary and aggregate oversize frames close fail-closed', async t => {
  const f = await fixture(t), { peer } = await f.start();
  const text = JSON.stringify({ type: 'session.update', session: { type: 'realtime' } });
  peer.ws.send(text.slice(0, 12), { fin: false }); peer.ws.send(text.slice(12), { fin: true }); await peer.wait('session.updated');
  peer.ws.send(Buffer.alloc(2)); assert.equal(await peer.closed, 1003);
});
test('maxPayload applies across fragments and malformed/invalid audio never reaches adapter', async t => {
  const f = await fixture(t), { peer } = await f.start();
  peer.ws.send('x'.repeat(33000), { fin: false }); peer.ws.send('x'.repeat(33000), { fin: true });
  assert.equal(await peer.closed, 1009); assert.equal(f.records.segments.length, 0);
});
test('normal empty ASR result succeeds, abnormal finish is failure, segments have unique IDs and never submit', async t => {
  const f = await fixture(t), { peer } = await f.start(); let n = 0;
  f.adapter.openSegment = async () => ({ write: async () => {}, finish: async () => ++n === 1 ? { normal: true, transcript: '' } : { normal: false, transcript: '' } });
  const ids = [];
  for (let i = 0; i < 2; i++) {
    peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await peer.wait('vs.flow');
    peer.send({ type: 'input_audio_buffer.commit' }); ids.push((await peer.wait('input_audio_buffer.committed')).item_id);
    const result = await peer.wait(i ? 'conversation.item.input_audio_transcription.failed' : 'conversation.item.input_audio_transcription.completed');
    if (!i) assert.equal(result.transcript, '');
  }
  assert.notEqual(ids[0], ids[1]); assert.equal(f.records.submissions.length, 0); peer.validate();
});
test('clear fences an uncooperative old write and stale callbacks cannot credit/finalize the next segment', async t => {
  const f = await fixture(t), { peer } = await f.start(), gate = deferred(), opened = deferred(); let n = 0;
  f.adapter.openSegment = async () => ++n === 1 ? { write: () => { opened.resolve(); return gate.promise; }, finish: async () => ({ normal: true, transcript: 'STALE' }) }
    : { write: async () => {}, finish: async () => ({ normal: true, transcript: 'NEW' }) };
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await opened.promise;
  assert.equal((await peer.wait('vs.flow')).input_consumed_samples, 480);
  peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); assert.equal((await peer.wait('vs.flow')).input_consumed_samples, 960);
  peer.send({ type: 'input_audio_buffer.commit' }); assert.equal((await peer.wait('conversation.item.input_audio_transcription.completed')).transcript, 'NEW');
  gate.resolve(); await turn(); assert.equal(peer.events.filter(e => e.type === 'conversation.item.input_audio_transcription.completed').length, 1); peer.validate();
});
test('one exchange across duplicate IDs, changed IDs and fresh sockets; no submit/audio replay', async t => {
  const f = await fixture(t), { peer, c } = await f.start(); await f.compose(peer); const operation = f.respond(peer); await peer.wait('response.done');
  f.respond(peer, operation); assert.equal((await peer.wait('response.done')).response.id, f.control.operation(c.call_id, operation).response_id);
  f.respond(peer); await peer.wait('error'); assert.equal(f.records.submissions.length, 1);
  peer.ws.close(); await peer.closed;
  const mint = await f.request('/calls/' + c.call_id + '/media', f.owner(c)); const connection = await f.connect(mint.value);
  await f.ready({ c, lease: mint.value, ...connection }); await f.compose(connection.peer); f.respond(connection.peer, operation);
  assert.equal((await connection.peer.wait('response.done')).response.output.length, 0); assert.equal(f.records.submissions.length, 1);
  assert.equal(connection.peer.events.filter(e => e.type === 'response.output_audio.delta').length, 0);
});
test('disconnect during submit records uncertainty; late authoritative fake result reconciles but never outputs', async t => {
  const f = await fixture(t), { peer, c } = await f.start(), gate = deferred(), entered = deferred();
  f.adapter.submit = args => { f.records.submissions.push(args); entered.resolve(args); return gate.promise; };
  await f.compose(peer); const operation = f.respond(peer); const args = await entered.promise;
  const ownerClosed = once(f.closedSessions, 'closed'); peer.ws.close(); await ownerClosed; await peer.closed;
  assert.equal(f.control.operation(c.call_id, operation).state, 'uncertain');
  gate.resolve({ admission_inbox_id: args.planned_inbox_id, source_user_id: 'user_late', source_assistant_id: 'assistant_late', text: 'Late reply.' });
  await turn(); assert.equal(f.control.operation(c.call_id, operation).state, 'completed'); assert.equal(f.records.syntheses.length, 0);
});
test('output producer is bounded by rendered credit, unknown cursor cannot grant credit, stall fails started streams', async t => {
  const f = await fixture(t, { stallMs: 100 }), { peer, c, lease } = await f.start(); let generated = 0;
  f.adapter.synthesize = async function* () { for (let n = 0; n < 30; n++) { generated++; yield Buffer.alloc(4800, 1); } };
  await f.compose(peer); const operation = f.respond(peer); const first = await peer.wait('response.output_audio.delta');
  peer.send({ type: 'vs.playback', media_epoch: lease.media_epoch, response_id: first.response_id, item_id: first.item_id,
    content_index: 0, playback_epoch: 'play_fixture', rendered_samples: 1, state: 'unknown' });
  assert.equal((await peer.wait('error')).error.code, 'invalid_position'); const done = await peer.wait('response.done');
  assert.equal(done.response.status, 'failed'); assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 20);
  assert.equal(generated, 21); assert.equal(f.control.operation(c.call_id, operation).delivery.rendered_samples, 0);
  assert.ok(peer.events.find(e => e.type === 'response.output_audio.done')); peer.validate();
});
test('actual speech lifetime expiry during engine credit pause fails after valid playback resumes, never truncated completion', { timeout: 5000 }, async t => {
  const sourceBytes = 153600, paused = deferred(), sockets = new Set(); let iterator, pulled = 0, submissions = 0;
  const service = http.createServer((req, res) => {
    assert.equal(req.url, '/v1/audio/speech'); req.resume(); req.on('end', () => {
      res.writeHead(200, { 'content-type': 'audio/pcm', 'x-sample-format': 's16le', 'x-sample-rate': '24000', 'x-channels': '1' });
      res.end(Buffer.alloc(sourceBytes));
    });
  });
  service.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  const base = '127.0.0.1:' + service.address().port;
  const actual = createLocalSpeechAdapter({ sttURL: `ws://${base}/v1/transcribe`, ttsURL: `http://${base}/v1/audio/speech`, model: 'synthetic', voice: 'synthetic', idleMs: 300, lifetimeMs: 300,
    submit: async args => { submissions++; return { admission_inbox_id: args.planned_inbox_id, source_user_id: 'user_synthetic', source_assistant_id: 'assistant_synthetic', text: 'Synthetic reply.' }; } });
  // Observe actual yielded bytes, without replacing transport/timeout/cleanup.
  const adapter = { ...actual, synthesize(args) {
    iterator = actual.synthesize(args);
    return { [Symbol.asyncIterator]() { return this; }, async next() {
      const result = await iterator.next();
      if (!result.done && (pulled += result.value.length) > LIMITS.windowSamples * 2) paused.resolve();
      return result;
    }, return: () => iterator.return() };
  } };
  const f = await fixture(t, { adapter, stallMs: 1500 });
  t.after(async () => {
    await iterator?.return();
    const closing = [...sockets].map(s => new Promise(resolve => { s.once('close', resolve); s.destroy(); }));
    await Promise.all([...closing, new Promise(resolve => service.close(resolve))]);
    assert.equal(sockets.size, 0); assert.deepEqual(actual.stats(), { stt: 0, tts: 0 });
  });
  const { peer, c, lease } = await f.start(); await f.compose(peer); const operation = f.respond(peer);
  await paused.promise;
  const outputBytes = () => peer.events.filter(e => e.type === 'response.output_audio.delta').reduce((n, e) => n + Buffer.from(e.delta, 'base64').length, 0);
  const first = await peer.wait('response.output_audio.delta', () => outputBytes() >= 90000);
  await new Promise(resolve => setTimeout(resolve, 350)); await iterator.cleanup;
  assert.deepEqual(actual.stats(), { stt: 0, tts: 0 });
  assert.equal(peer.events.some(e => e.type === 'response.done'), false);
  assert.equal(f.server.openVoiceStats().pendingJobs, 1); // Held engine resource, not an early-release shortcut.
  peer.send({ type: 'vs.playback', media_epoch: lease.media_epoch, response_id: first.response_id, item_id: first.item_id,
    content_index: 0, playback_epoch: 'play_fixture', rendered_samples: outputBytes() / 2, state: 'playing' });
  assert.equal((await peer.wait('response.done')).response.status, 'failed');
  assert.ok(outputBytes() < sourceBytes); assert.equal(submissions, 1);
  assert.equal(f.control.operation(c.call_id, operation).state, 'completed'); // Admission not cancelled/retried.
  await iterator.return(); await assert.rejects(iterator.next(), e => e.code === 'speech_timeout'); peer.validate();
});
test('cancel aborts narration but not an already submitted operation; truncate is bounded by reported rendered cursor', async t => {
  const f = await fixture(t), { peer, c, lease } = await f.start(), stop = deferred();
  f.adapter.synthesize = async function* ({ signal }) { yield Buffer.alloc(4800, 1); await stop.promise; if (!signal.aborted) yield Buffer.alloc(4800, 1); };
  await f.compose(peer); const operation = f.respond(peer); const first = await peer.wait('response.output_audio.delta');
  const playback = { type: 'vs.playback', media_epoch: lease.media_epoch, response_id: first.response_id, item_id: first.item_id, content_index: 0,
    playback_epoch: 'play_fixture', rendered_samples: 2400, state: 'playing' };
  peer.send(playback); peer.send({ type: 'response.cancel', response_id: first.response_id });
  assert.equal((await peer.wait('response.done')).response.status, 'cancelled'); assert.equal(f.control.operation(c.call_id, operation).state, 'completed');
  peer.send({ type: 'conversation.item.truncate', item_id: first.item_id, content_index: 0, audio_end_ms: 101 });
  assert.equal((await peer.wait('error')).error.code, 'invalid_position');
  peer.send({ type: 'conversation.item.truncate', item_id: first.item_id, content_index: 0, audio_end_ms: 100 }); await peer.wait('conversation.item.truncated');
  stop.resolve(); await turn(); assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 1); peer.validate();
});
test('revocation closes live owner and no delayed adapter callback can restore readiness', async t => {
  const f = await fixture(t), { peer, c, lease, session } = await f.start(), gate = deferred(), entered = deferred();
  f.adapter.openSegment = async () => ({ write: () => { entered.resolve(); return gate.promise; }, finish: async () => ({ normal: true, transcript: 'late' }) });
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await entered.promise;
  f.control.revoke(f.grant.grant_id); assert.equal(f.server.openVoiceStats().sessions, 0); assert.equal(await peer.closed, 1008);
  gate.resolve(); await turn(); assert.equal(peer.events.filter(e => e.type === 'vs.flow' && e.input_consumed_samples > 0).length, 1); // Accepted FIFO handoff, never a late second credit.
  const result = await f.request('/calls/' + c.call_id + '/media-ready', { ...f.owner(c), media_epoch: lease.media_epoch, session_id: session.id, native_capture_ready: true });
  assert.ok(result.status >= 400);
});
test('atomic invalid session update retains defaults; text-only response has no audio or TTS', async t => {
  const f = await fixture(t), { peer } = await f.start();
  peer.send({ type: 'session.update', session: { type: 'realtime', audio: { input: { format: { type: 'audio/pcm', rate: 16000 } } } } });
  assert.equal((await peer.wait('error')).error.code, 'unsupported_feature');
  peer.send({ type: 'session.update', session: { type: 'realtime', output_modalities: ['text'] } });
  assert.equal((await peer.wait('session.updated')).session.audio.input.format.rate, 24000);
  await f.compose(peer); f.respond(peer, uuid(), 'text'); assert.equal((await peer.wait('response.done')).response.status, 'completed');
  assert.equal(f.records.syntheses.length, 0); assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 0);
  assert.ok(peer.events.find(e => e.type === 'response.output_text.delta')); peer.validate();
});
test('a composed item arriving during target validation cannot change the prepared submitted thought', async t => {
  const f = await fixture(t), { peer } = await f.start(), gate = deferred(), entered = deferred();
  await f.compose(peer);
  const resolve = f.control.resolveTarget; let calls = 0;
  f.control.resolveTarget = async (...args) => { if (++calls === 2) { entered.resolve(); await gate.promise; } return resolve(...args); };
  f.respond(peer); await entered.promise;
  peer.send({ type: 'conversation.item.create', item: { ...v.canonical_item, id: 'different_thought', content: [{ type: 'input_text', text: 'DO NOT SUBSTITUTE' }] } });
  await peer.wait('conversation.item.done', e => e.item.id === 'different_thought'); gate.resolve(); await peer.wait('response.done');
  assert.deepEqual(f.records.submissions[0].item, v.canonical_item);
});
for (const shared of [true, false]) test(`submit lineage accepts ${shared ? 'shared inbox/user' : 'distinct inbox/user'} IDs with a distinct final assistant`, async t => {
  const f = await fixture(t), { peer, c } = await f.start(); let receipt;
  f.adapter.submit = async args => {
    f.records.submissions.push(args);
    receipt = { admission_inbox_id: args.planned_inbox_id,
      source_user_id: shared ? args.planned_inbox_id : 'u'.repeat(100), source_assistant_id: 'a'.repeat(100), text: 'Synthetic final reply.' };
    return receipt;
  };
  await f.compose(peer); const operation = f.respond(peer);
  assert.equal((await peer.wait('response.done')).response.status, 'completed');
  const op = f.control.operation(c.call_id, operation);
  assert.equal(op.state, 'completed'); assert.equal(op.admission_inbox_id, op.planned_inbox_id);
  assert.equal(op.source_user_id, receipt.source_user_id); assert.equal(op.source_assistant_id, receipt.source_assistant_id);
  assert.equal(f.records.submissions.length, 1); assert.deepEqual(f.records.submissions[0].item, v.canonical_item);
  assert.equal(f.records.submissions[0].call_id, c.call_id); assert.equal(f.records.submissions[0].operation_id, operation);
  assert.equal(f.records.syntheses[0].text, receipt.text);
  f.respond(peer, operation); await peer.wait('response.done');
  assert.equal(f.records.submissions.length, 1); assert.equal(f.records.syntheses.length, 1); peer.validate();
});
for (const [label, patch] of [
  ['assistant aliases shared input', r => ({ source_assistant_id: r.admission_inbox_id })],
  ['assistant aliases distinct user', () => ({ source_user_id: 'distinct_user', source_assistant_id: 'distinct_user' })],
  ['assistant aliases inbox with distinct user', r => ({ source_user_id: 'distinct_user', source_assistant_id: r.admission_inbox_id })],
  ['missing user', () => ({ source_user_id: undefined })],
  ['empty user', () => ({ source_user_id: '' })],
  ['invalid user characters', () => ({ source_user_id: 'user/invalid' })],
  ['overlong user', () => ({ source_user_id: 'u'.repeat(101) })],
  ['non-string user', () => ({ source_user_id: 42 })],
  ['missing assistant', () => ({ source_assistant_id: undefined })],
  ['invalid assistant characters', () => ({ source_assistant_id: 'assistant invalid' })],
  ['overlong assistant', () => ({ source_assistant_id: 'a'.repeat(101) })],
  ['non-string assistant', () => ({ source_assistant_id: {} })],
  ['extra provenance field', () => ({ guessed: true })],
  ['invalid text', () => ({ text: null })],
  ['overlong text', () => ({ text: 'x'.repeat(64001) })],
]) test(`submit lineage refuses ${label} without narration or retry`, async t => {
  const f = await fixture(t), { peer, c } = await f.start();
  f.adapter.submit = async args => {
    f.records.submissions.push(args);
    const result = { admission_inbox_id: args.planned_inbox_id, source_user_id: args.planned_inbox_id,
      source_assistant_id: 'assistant_fixture', text: 'Not authoritative' };
    return { ...result, ...patch(result) };
  };
  await f.compose(peer); const operation = f.respond(peer);
  assert.equal((await peer.wait('response.done')).response.status, 'failed');
  const op = f.control.operation(c.call_id, operation); assert.equal(op.state, 'uncertain');
  assert.equal(op.source_user_id, undefined); assert.equal(op.source_assistant_id, undefined);
  assert.equal(f.records.syntheses.length, 0); assert.equal(peer.events.some(e => e.type === 'response.output_audio.delta'), false);
  f.respond(peer, operation); await peer.wait('response.done'); assert.equal(f.records.submissions.length, 1); peer.validate();
});
test('submit lineage equality cannot bypass revoked owner before dispatch', async t => {
  const f = await fixture(t), { peer, c } = await f.start(), entered = deferred(), gate = deferred();
  t.after(() => gate.resolve());
  await f.compose(peer);
  const resolve = f.control.resolveTarget; let calls = 0;
  f.control.resolveTarget = async (...args) => { if (++calls === 2) { entered.resolve(); await gate.promise; } return resolve(...args); };
  const operation = f.respond(peer); await entered.promise;
  f.control.revoke(f.grant.grant_id); await peer.closed; gate.resolve(); await turn();
  assert.equal(f.records.submissions.length, 0); assert.equal(f.records.syntheses.length, 0);
  assert.equal(f.control.operation(c.call_id, operation).state, 'prepared');
});
test('submit lineage equality reconciles late completion but cannot narrate to a revoked owner', async t => {
  const f = await fixture(t), { peer, c } = await f.start(), entered = deferred(), gate = deferred();
  f.adapter.submit = args => { f.records.submissions.push(args); entered.resolve(args); return gate.promise; };
  await f.compose(peer); const operation = f.respond(peer), args = await entered.promise;
  f.control.revoke(f.grant.grant_id); await peer.closed;
  assert.equal(f.control.operation(c.call_id, operation).state, 'uncertain');
  gate.resolve({ admission_inbox_id: args.planned_inbox_id, source_user_id: args.planned_inbox_id,
    source_assistant_id: 'assistant_late', text: 'Late synthetic final reply.' });
  await turn(); assert.equal(f.control.operation(c.call_id, operation).state, 'completed');
  assert.equal(f.records.submissions.length, 1); assert.equal(f.records.syntheses.length, 0);
  assert.equal(peer.events.some(e => e.type === 'response.output_audio.delta'), false);
});
test('wrong admission inbox or ambiguous adapter failure retains uncertainty, never guessed source lineage', async t => {
  const f = await fixture(t), { peer, c } = await f.start();
  f.adapter.submit = async () => ({ admission_inbox_id: 'wrong_inbox', source_user_id: 'user', source_assistant_id: 'assistant', text: 'Not authoritative' });
  await f.compose(peer); const operation = f.respond(peer); assert.equal((await peer.wait('response.done')).response.status, 'failed');
  assert.equal(f.control.operation(c.call_id, operation).state, 'uncertain'); assert.equal(f.records.syntheses.length, 0);
});
for (const kind of ['malformed', 'pcm-frame']) test(`invalid ${kind} closes before recognition`, async t => {
  const f = await fixture(t), { peer } = await f.start();
  if (kind === 'malformed') peer.ws.send('{"type":"input_audio_buffer.append","type":"session.update"}');
  else peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(LIMITS.maxFrameBytes + 2).toString('base64') });
  assert.equal(await peer.closed, 1008); assert.equal(f.records.segments.length, 0);
});
test('bounded ingress closes on overflow; handoff credit is truthful while a hung backend write retains PCM ownership', async t => {
  const f = await fixture(t), { peer } = await f.start(), gate = deferred(), entered = deferred();
  t.after(() => gate.resolve());
  f.adapter.openSegment = async () => ({ write: () => { entered.resolve(); return gate.promise; }, finish: async () => ({ normal: true, transcript: '' }) });
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800).toString('base64') }); await entered.promise;
  for (let i = 0; i < 24; i++) peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800).toString('base64') });
  assert.equal(await peer.closed, 1009);
  const credit = peer.events.filter(e => e.type === 'vs.flow' && e.input_consumed_samples > 0);
  assert.equal(credit.length, 20); assert.equal(credit.at(-1).input_consumed_samples, 48000);
  assert.equal(f.server.openVoiceStats().inputPCMBytes, 4800); // Retired unsettled write still owns its frame.
  gate.resolve(); await turn(); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
});
test('uncooperative cancelled segment jobs keep bounded slots until underlying jobs actually settle', async t => {
  const f = await fixture(t, { stallMs: 1000 }), { peer } = await f.start(), jobs = [], opened = new EventEmitter();
  t.after(() => jobs.forEach(g => g.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }) })));
  f.adapter.openSegment = () => { const g = deferred(); jobs.push(g); opened.emit('open'); return g.promise; };
  for (let i = 0; i < 8; i++) {
    const entering = once(opened, 'open'); peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await entering;
    peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
  }
  assert.equal(f.server.openVoiceStats().pendingJobs, 8);
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); assert.equal(await peer.closed, 1009);
  assert.equal(jobs.length, 8); jobs.forEach(g => g.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }) }));
  await turn(); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
});
test('rendered credit resumes output; stale epoch, cursor beyond sent and paused advancement never grant credit', async t => {
  const f = await fixture(t, { stallMs: 1000 }), { peer, lease } = await f.start();
  f.adapter.synthesize = async function* () { for (let i = 0; i < 21; i++) yield Buffer.alloc(4800, 1); };
  await f.compose(peer); f.respond(peer);
  let first;
  for (let i = 0; i < 20; i++) { const e = await peer.wait('response.output_audio.delta'); first ??= e; }
  const playback = { type: 'vs.playback', media_epoch: lease.media_epoch, response_id: first.response_id, item_id: first.item_id,
    content_index: 0, playback_epoch: 'play_fixture', rendered_samples: 0, state: 'paused' };
  for (const patch of [{ media_epoch: 'old' }, { rendered_samples: 48001 }, { media_epoch: 1 }]) {
    peer.send({ ...playback, ...patch }); assert.equal((await peer.wait('error')).error.code, typeof patch.media_epoch === 'number' ? 'invalid_request' : 'invalid_position');
  }
  peer.send(playback); peer.send({ ...playback, rendered_samples: 2400 }); assert.equal((await peer.wait('error')).error.code, 'invalid_position');
  peer.send({ ...playback, state: 'playing' });
  peer.send({ ...playback, state: 'completed', rendered_samples: 48000 });
  await peer.wait('response.output_audio.delta'); assert.equal((await peer.wait('response.done')).response.status, 'completed'); peer.validate();
});
test('candidate persistence poison synchronously clears WS owner before a late recognition callback', async t => {
  const f = await fixture(t), { peer, c } = await f.start(), gate = deferred(), entered = deferred();
  t.after(() => gate.resolve());
  f.adapter.openSegment = async () => ({ write: () => { entered.resolve(); return gate.promise; }, finish: async () => ({ normal: true, transcript: 'late' }) });
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await entered.promise;
  f.push.store.save = () => { throw new Error('fixture fsync failure'); }; assert.throws(() => f.control.save());
  assert.equal(f.server.openVoiceStats().sessions, 0); assert.equal(await peer.closed, 1008);
  assert.equal(f.control.state.calls['v:' + c.call_id].media_ready, undefined); gate.resolve(); await turn();
  assert.equal(peer.events.filter(e => e.type === 'vs.flow' && e.input_consumed_samples > 0).length, 1);
});
test('late normal finish from a timed-out segment cannot finalize its successor', async t => {
  const f = await fixture(t, { stallMs: 60 }), { peer } = await f.start(), old = deferred(); let n = 0;
  t.after(() => old.resolve({ normal: true, transcript: 'OLD' }));
  f.adapter.openSegment = async () => ({ write: async () => {}, finish: () => ++n === 1 ? old.promise : Promise.resolve({ normal: true, transcript: 'NEW' }) });
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await peer.wait('vs.flow');
  peer.send({ type: 'input_audio_buffer.commit' }); const first = await peer.wait('input_audio_buffer.committed'); await peer.wait('conversation.item.input_audio_transcription.failed');
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await peer.wait('vs.flow');
  peer.send({ type: 'input_audio_buffer.commit' }); const next = await peer.wait('conversation.item.input_audio_transcription.completed');
  assert.notEqual(next.item_id, first.item_id); assert.equal(next.transcript, 'NEW'); old.resolve({ normal: true, transcript: 'OLD' });
  await turn(); assert.equal(peer.events.filter(e => e.type === 'conversation.item.input_audio_transcription.completed').length, 1);
});
test('incoming control event rate is bounded even without adapter work', async t => {
  const f = await fixture(t), { peer } = await f.start();
  for (let i = 0; i < 220; i++) peer.send({ type: 'input_audio_buffer.clear' });
  assert.equal(await peer.closed, 1009); assert.equal(f.records.submissions.length, 0);
});
test('write budget measured at 256 KiB fences the actual server socket before another event is queued', async t => {
  const f = await fixture(t), { peer } = await f.start();
  const original = Object.getOwnPropertyDescriptor(WebSocket.prototype, 'bufferedAmount');
  Object.defineProperty(WebSocket.prototype, 'bufferedAmount', { ...original,
    get() { return this._isServer ? LIMITS.maxWritableBytes : original.get.call(this); } });
  t.after(() => Object.defineProperty(WebSocket.prototype, 'bufferedAmount', original));
  peer.send({ type: 'conversation.item.create', item: v.canonical_item });
  assert.equal(await peer.closed, 1008); assert.equal(f.records.submissions.length, 0);
});
test('library rejects unmasked client frames rather than parsing them as media', async t => {
  const f = await fixture(t), { peer } = await f.start();
  peer.ws._socket.write(Buffer.from([0x81, 2, 0x7b, 0x7d])); assert.equal(await peer.closed, 1002);
  assert.equal(f.records.segments.length, 0);
});
test('authenticated target availability is revalidated at the actual WS attach', async t => {
  const f = await fixture(t), { lease } = await f.prepare();
  f.control.resolveTarget = async b => ({ ...b, authenticated: true, paired: false, available: false, idle: false });
  await assert.rejects(f.connect(lease)); assert.equal(f.server.openVoiceStats().sessions, 0);
});
for (const stop of ['capability-disable', 'deliberate-end']) test(`${stop} fences actual socket and persisted readiness`, async t => {
  const f = await fixture(t), { peer, c } = await f.start();
  if (stop === 'capability-disable') f.control.capability(f.device, { ...v.capability, enabled: false });
  else assert.equal((await f.request('/calls/' + c.call_id + '/end', { ...f.owner(c), operation_id: uuid(), reason: 'deliberate-user' })).status, 200);
  assert.equal(f.server.openVoiceStats().sessions, 0); assert.equal(await peer.closed, 1008);
  assert.equal(f.control.state.calls['v:' + c.call_id].media_ready, undefined);
});
test('a late-opened sink is closed after clear instead of becoming an owner of the next segment', async t => {
  const f = await fixture(t), { peer } = await f.start(), gate = deferred(), entered = deferred(); let closed = 0;
  t.after(() => gate.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }), close: () => { closed++; } }));
  f.adapter.openSegment = () => { entered.resolve(); return gate.promise; };
  peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await entered.promise;
  peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
  gate.resolve({ write: async () => { assert.fail('stale sink write'); }, finish: async () => { assert.fail('stale sink finish'); }, close: () => { closed++; } });
  await turn(); assert.equal(closed, 1); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
});
test('standard ping/pong keeps a legitimately quiet application healthy beyond ten seconds without application heartbeats', { timeout: 15000 }, async t => {
  const f = await fixture(t), { peer } = await f.start(); const count = peer.events.length;
  // Actual owned WS control frames, no app traffic while waiting for the server's 10s ping.
  await once(peer.ws, 'ping'); assert.equal(peer.events.length, count);
  const pong = once(peer.ws, 'pong'); peer.ws.ping(); await pong;
  assert.equal(peer.events.length, count); assert.equal(f.records.segments.length, 0); assert.equal(f.records.submissions.length, 0);
  peer.send({ type: 'session.update', session: { type: 'realtime' } }); await peer.wait('session.updated');
  assert.equal(peer.events.filter(e => e.type === 'vs.flow').length, 1); // Initial configured flow only, never a liveness event.
});
test('twenty cleared pending writes release ownership on settlement without losing or duplicating ingress credit', async t => {
  const f = await fixture(t), { peer } = await f.start(), writes = new EventEmitter(); const gates = [];
  t.after(() => gates.forEach(g => g.resolve()));
  f.adapter.openSegment = async () => ({ write: () => { const g = deferred(); gates.push(g); writes.emit('write', g); return g.promise; },
    finish: async () => ({ normal: true, transcript: 'After clear.' }) });
  for (let i = 1; i <= 20; i++) {
    const entering = once(writes, 'write'); peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800, 1).toString('base64') });
    assert.equal((await peer.wait('vs.flow')).input_consumed_samples, i * 2400); const [g] = await entering;
    peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
    assert.equal(f.server.openVoiceStats().inputPCMBytes, 4800);
    const credits = peer.events.filter(e => e.type === 'vs.flow').length; g.resolve(); await turn();
    assert.equal(f.server.openVoiceStats().pendingJobs, 0); assert.equal(f.server.openVoiceStats().inputPCMBytes, 0);
    assert.equal(peer.events.filter(e => e.type === 'vs.flow').length, credits);
  }
  const entering = once(writes, 'write'); peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800, 2).toString('base64') });
  assert.equal((await peer.wait('vs.flow')).input_consumed_samples, 50400); const [g] = await entering; g.resolve();
  peer.send({ type: 'input_audio_buffer.commit' }); assert.equal((await peer.wait('conversation.item.input_audio_transcription.completed')).transcript, 'After clear.');
  assert.equal(f.server.openVoiceStats().acceptedInputSamples, 50400);
});
test('receive-ordered queued appends are handed into bounded ingress before clear; late open cannot migrate PCM', async t => {
  const f = await fixture(t), { peer } = await f.start(), firstOpen = deferred(), entered = deferred(); let opens = 0, staleClose = 0;
  const newWrites = [];
  t.after(() => firstOpen.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }) }));
  f.adapter.openSegment = () => {
    if (++opens === 1) { entered.resolve(); return firstOpen.promise; }
    return { write: async pcm => newWrites.push(pcm[0]), finish: async () => ({ normal: true, transcript: 'NEW' }) };
  };
  const append = byte => peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800, byte).toString('base64') });
  append(1); await entered.promise; append(1); append(1); peer.send({ type: 'input_audio_buffer.clear' });
  await peer.wait('input_audio_buffer.cleared');
  const beforeClear = peer.events.slice(0, peer.events.findIndex(e => e.type === 'input_audio_buffer.cleared'));
  assert.deepEqual(beforeClear.filter(e => e.type === 'vs.flow').map(e => e.input_consumed_samples), [0,2400,4800,7200]);
  assert.equal(f.server.openVoiceStats().inputPCMBytes, 0); append(2); peer.send({ type: 'input_audio_buffer.commit' });
  assert.equal((await peer.wait('conversation.item.input_audio_transcription.completed')).transcript, 'NEW');
  firstOpen.resolve({ write: async () => assert.fail('stale write'), finish: async () => assert.fail('stale finish'), close: () => { staleClose++; } });
  await turn(); assert.deepEqual(newWrites, [2]); assert.equal(staleClose, 1);
  assert.equal(f.server.openVoiceStats().acceptedInputSamples, 9600);
});
test('commit is captured before later priority clear, and successor generation never enters a committed sink', async t => {
  const f = await fixture(t), { peer } = await f.start(), writeGate = deferred(), entered = deferred(); let opens = 0, writes = 0;
  t.after(() => writeGate.resolve());
  f.adapter.openSegment = async () => { opens++; return { write: pcm => { assert.equal(pcm[0], 1); if (++writes === 1) { entered.resolve(); return writeGate.promise; } },
    finish: async () => ({ normal: true, transcript: 'COMMITTED' }) }; };
  const append = byte => peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800, byte).toString('base64') });
  append(1); await entered.promise; append(1); peer.send({ type: 'input_audio_buffer.commit' }); peer.send({ type: 'input_audio_buffer.clear' });
  const committed = await peer.wait('input_audio_buffer.committed'); await peer.wait('input_audio_buffer.cleared');
  append(2); peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared'); writeGate.resolve();
  const result = await peer.wait('conversation.item.input_audio_transcription.completed');
  assert.equal(result.item_id, committed.item_id); assert.equal(result.transcript, 'COMMITTED'); assert.equal(result.usage.seconds, 0.2);
  await turn(); assert.equal(opens, 1); assert.equal(writes, 2); assert.equal(f.server.openVoiceStats().inputPCMBytes, 0);
});
test('96000-byte input ownership is global across retired writes and current queued PCM, with terminal pre-ingress refusal', async t => {
  const f = await fixture(t), { peer } = await f.start(), entered = new EventEmitter(), gates = [];
  t.after(() => gates.forEach(g => g.resolve()));
  f.adapter.openSegment = async () => ({ write: () => { const g = deferred(); gates.push(g); entered.emit('write'); return g.promise; }, finish: async () => ({ normal: true, transcript: '' }) });
  const append = () => peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(4800, 1).toString('base64') });
  for (let i = 0; i < 7; i++) {
    const writing = once(entered, 'write'); append(); await writing; await peer.wait('vs.flow');
    peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
  }
  const writing = once(entered, 'write'); append(); await writing; await peer.wait('vs.flow');
  for (let i = 0; i < 12; i++) { append(); await peer.wait('vs.flow'); }
  assert.equal(f.server.openVoiceStats().inputPCMBytes, 96000); assert.equal(f.server.openVoiceStats().inputPeakBytes, 96000);
  append(); assert.equal(await peer.closed, 1009);
  assert.equal(f.server.openVoiceStats().inputPCMBytes, 38400); assert.equal(f.server.openVoiceStats().pendingJobs, 8);
  assert.equal(f.server.openVoiceStats().acceptedInputSamples, 48000);
  gates.forEach(g => g.resolve()); await turn(); assert.equal(f.server.openVoiceStats().inputPCMBytes, 0); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
});
for (const action of ['cancel','disconnect']) test(`late synthesis after ${action} retires once at full eight-slot capacity and holds its slot through cleanup`, async t => {
  const f = await fixture(t, { stallMs: 1000 }), { peer, c } = await f.start(), allocation = deferred(), synthesisStarted = deferred(), cleanup = deferred(), recognition = new EventEmitter();
  const opens = []; let returns = 0, activeResource = false, nexts = 0;
  t.after(() => { opens.forEach(g => g.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }) })); allocation.resolve({ [Symbol.asyncIterator]: () => ({ next: async () => ({ done: true }), return: async () => {} }) }); cleanup.resolve(); });
  f.adapter.synthesize = () => { synthesisStarted.resolve(); return allocation.promise; };
  f.adapter.openSegment = () => { const g = deferred(); opens.push(g); recognition.emit('open'); return g.promise; };
  await f.compose(peer); const operation = f.respond(peer); await synthesisStarted.promise;
  for (let i = 0; i < 7; i++) {
    const opening = once(recognition, 'open'); peer.send({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }); await opening; await peer.wait('vs.flow');
    peer.send({ type: 'input_audio_buffer.clear' }); await peer.wait('input_audio_buffer.cleared');
  }
  assert.equal(f.server.openVoiceStats().pendingJobs, 8);
  if (action === 'cancel') { peer.send({ type: 'response.cancel' }); assert.equal((await peer.wait('response.done')).response.status, 'cancelled'); }
  else { const closed = once(f.closedSessions, 'closed'); peer.ws.close(); await closed; await peer.closed; }
  activeResource = true;
  allocation.resolve({ [Symbol.asyncIterator]: () => ({ next: async () => { nexts++; return { done: true }; }, return: () => { returns++; return cleanup.promise.then(() => { activeResource = false; return { done: true }; }); } }) });
  await turn(); assert.equal(returns, 1); assert.equal(activeResource, true); assert.equal(nexts, 0); assert.equal(f.server.openVoiceStats().pendingJobs, 8);
  opens.forEach(g => g.resolve({ write: async () => {}, finish: async () => ({ normal: true, transcript: '' }) })); await turn();
  assert.equal(f.server.openVoiceStats().pendingJobs, 1); cleanup.resolve(); await turn();
  assert.equal(activeResource, false); assert.equal(f.server.openVoiceStats().pendingJobs, 0); assert.equal(returns, 1);
  assert.equal(f.control.operation(c.call_id, operation).state, 'completed'); assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 0);
});
test('late synthesis cleanup rejection is observed after disconnect without resource/output resurrection', async t => {
  const f = await fixture(t), { peer } = await f.start(), allocation = deferred(), entered = deferred(); let returns = 0;
  f.adapter.synthesize = () => { entered.resolve(); return allocation.promise; };
  await f.compose(peer); f.respond(peer); await entered.promise;
  const closed = once(f.closedSessions, 'closed'); peer.ws.close(); await closed; await peer.closed;
  allocation.resolve({ [Symbol.asyncIterator]: () => ({ next: async () => assert.fail('late next'), return: async () => { returns++; throw new Error('private failure must stay internal'); } }) });
  await turn(); assert.equal(returns, 1); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
  assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 0);
});
test('late synthesis allocation rejection is observed and releases only the actually settled allocation slot', async t => {
  const f = await fixture(t), { peer } = await f.start(), entered = deferred(); let reject;
  const allocation = new Promise((_, failure) => { reject = failure; });
  f.adapter.synthesize = () => { entered.resolve(); return allocation; };
  await f.compose(peer); f.respond(peer); await entered.promise;
  peer.send({ type: 'response.cancel' }); await peer.wait('response.done'); assert.equal(f.server.openVoiceStats().pendingJobs, 1);
  reject(new Error('late private allocation failure')); await turn(); assert.equal(f.server.openVoiceStats().pendingJobs, 0);
  assert.equal(peer.events.filter(e => e.type === 'response.output_audio.delta').length, 0);
});
test('synthesis slot remains occupied until BOTH uncooperative next and return settle', async t => {
  const f = await fixture(t), { peer } = await f.start(), next = deferred(), cleanup = deferred(), entered = deferred(); let returns = 0;
  t.after(() => { next.resolve({ done: true }); cleanup.resolve({ done: true }); });
  f.adapter.synthesize = () => ({ [Symbol.asyncIterator]: () => ({ next: () => { entered.resolve(); return next.promise; }, return: () => { returns++; return cleanup.promise; } }) });
  await f.compose(peer); f.respond(peer); await entered.promise;
  peer.send({ type: 'response.cancel' }); await peer.wait('response.done'); await turn();
  assert.equal(returns, 1); assert.equal(f.server.openVoiceStats().pendingJobs, 1);
  cleanup.resolve({ done: true }); await turn(); assert.equal(f.server.openVoiceStats().pendingJobs, 1);
  next.resolve({ done: true }); await turn(); assert.equal(f.server.openVoiceStats().pendingJobs, 0); assert.equal(returns, 1);
});
test('raw payload reservations survive closed handlers and remain aggregate-bounded across replacement owners', async t => {
  const f = await fixture(t), first = await f.start(), gates = []; let current = first, hold = false;
  const resolveTarget = f.control.resolveTarget, entered = new EventEmitter();
  f.control.resolveTarget = async b => {
    if (hold) { hold = false; const g = deferred(); gates.push(g); entered.emit('held'); await g.promise; }
    return resolveTarget(b);
  };
  t.after(() => gates.forEach(g => g.resolve()));
  const thought = { ...v.canonical_item, content: [{ type: 'input_text', text: '😀'.repeat(16000) }] };
  for (let i = 0; i < 3; i++) {
    if (i) {
      const minted = await f.request('/calls/' + first.c.call_id + '/media', f.owner(first.c));
      current = { c: first.c, lease: minted.value, ...await f.connect(minted.value) }; await f.ready(current);
    }
    current.peer.send({ type: 'conversation.item.create', item: thought });
    if (i < 2) {
      await current.peer.wait('conversation.item.done', e => e.item.id === thought.id); hold = true; const waiting = once(entered, 'held');
      current.peer.send({ type: 'response.create', response: { input: [thought], metadata: { operation_id: uuid() }, output_modalities: ['audio'] } });
      await waiting; const closed = once(f.closedSessions, 'closed'); current.peer.ws.close(); await closed; await current.peer.closed;
    } else assert.equal(await current.peer.closed, 1009);
    assert.ok(f.server.openVoiceStats().aggregatePeakBytes <= 524288);
  }
  assert.ok(f.server.openVoiceStats().rawBytes > 2 * 120000); assert.equal(f.records.submissions.length, 0);
  gates.forEach(g => g.resolve()); await f.push.drain(); await turn(); assert.equal(f.server.openVoiceStats().rawBytes, 0);
});
