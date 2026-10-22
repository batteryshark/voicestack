import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { once } from 'node:events';
import { Credentials, SessionEvents, createBridge } from './server.mjs';
import { OpenChamberClient } from './oc-client.mjs';

let fake, bridge, dir, store, credential, base, generation, chief = 'ses_testA';
const mutations = [], seen = [];
const stages = [];
let rejectUpstreamAuth = false, holdEvents = false, eventClosed;
let hangingPath, trickle = false;
let installedScenario = false;
let senderScenario = false;
let slowSenderScenario = false;
const fixture = name => JSON.parse(fs.readFileSync(new URL('./fixtures/' + name + '.json', import.meta.url)));
const wav = Buffer.from('524946462600000057415645666d74201000000001000100803e0000007d00000200100064617461020000000000', 'hex');
const listen = s => new Promise(resolve => s.listen(0, '127.0.0.1', resolve));
const close = s => new Promise(resolve => s.close(resolve));
async function call(url, { method = 'GET', data, auth = credential, gen = generation, headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const bytes = data === undefined ? undefined : Buffer.from(JSON.stringify(data));
    const req = http.request(base + url, { method, headers: {
      ...(auth ? { Authorization: 'Bearer ' + auth } : {}), ...(gen ? { 'X-FV-Generation': gen } : {}),
      ...(bytes ? { 'Content-Type': 'application/json', 'Content-Length': bytes.length } : {}), ...headers
    } }, res => {
      const chunks = []; res.on('data', c => chunks.push(c));
      res.on('end', () => { const text = Buffer.concat(chunks).toString(); resolve({ status: res.statusCode, text, headers: res.headers, json: () => JSON.parse(text) }); });
    }); req.on('error', reject); req.end(bytes);
  });
}
before(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-bridge-test-'));
  const file = path.join(dir, 'store.json');
  fs.writeFileSync(file, JSON.stringify({ bootstrap: crypto.createHash('sha256').update('test-only-bootstrap').digest('hex'), expires: Date.now() + 60000, devices: {} }), { mode: 0o600 });
  store = new Credentials(file);
  fake = http.createServer((req, res) => {
    seen.push(req.url);
    if (hangingPath && req.url.startsWith(hangingPath)) {
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('{');
      const timer = trickle ? setInterval(() => res.write(' '), 10) : null;
      res.on('close', () => clearInterval(timer)); fake.emit('hanging', res); return;
    }
    if (req.url === '/api/system/info') { if (rejectUpstreamAuth) { res.writeHead(401); res.end('{}'); } else res.end(JSON.stringify({ runtime: 'desktop' })); return; }
    if (req.url.startsWith('/api/session?')) { res.end(JSON.stringify({ data: [{ id: 'ses_testA', title: 'Synthetic A', time: { updated: 1 } }, { id: 'ses_testB', title: 'Synthetic B', time: { updated: 2 } }] })); return; }
    if (/^\/api\/session\/ses_test[AB]$/.test(req.url)) { res.end(JSON.stringify({ data: { id: req.url.split('/').at(-1) } })); return; }
    if (req.url === '/api/session/active') { res.end(JSON.stringify({ data: { ses_testA: {}, ses_unrelated: {} } })); return; }
    if (slowSenderScenario && /^\/api\/session\/ses_slow[0-7]$/.test(req.url)) {
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.write('{');
      // Never finishes: optional title discovery MUST abort the actual request.
      return;
    }
    if (senderScenario && req.url === '/api/session/ses_source') { res.end(JSON.stringify({ data: { id: 'ses_source', title: '[lead] Dream Studio' } })); return; }
    if (req.url.includes('/message?')) {
      res.end(JSON.stringify(slowSenderScenario ? { data: Array.from({ length: 8 }, (_, i) => ({ id: `msg_slow${i}`, type: 'user', text: 'Healthy history body.', metadata: { a2a: { v: 1, from: `local/ses_slow${i}`, traceId: 'a2a_slow', hop: 0, kind: 'request' } } })) }
        : senderScenario ? { data: [{ id: 'msg_sender', type: 'user', text: '[chief]\nMetadata-owned payload.', metadata: { a2a: { v: 1, from: 'local/ses_source', traceId: 'a2a_sender', hop: 0, kind: 'request' } } }] } : fixture(req.url.includes('cursor=fixture_next') ? 'history-asc-page2' : 'history-asc-page1'))); return;
    }
    if (req.url === '/api/event') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      if (installedScenario) {
        const block = { sessionID: 'ses_testA', assistantMessageID: 'msg_fixture', ordinal: 0 };
        const events = [
          { id: 'evt_started', created: 1, type: 'session.execution.started', data: { sessionID: 'ses_testA' } },
          { directory: '/synthetic', payload: { id: 'evt_delta', created: 2, type: 'session.text.delta', data: { ...block, delta: 'Synthetic reply.' } } },
          { type: 'session.text.delta', data: { ...block, delta: ' Same' } },
          { type: 'session.text.delta', data: { ...block, delta: ' Same' } },
          { id: 'evt_tool', created: 3, type: 'session.tool.success', data: { ...block, ordinal: 1 } },
          { id: 'evt_ended', created: 4, type: 'session.text.ended', data: { ...block, text: 'Synthetic reply. Same Same' } },
          { id: 'evt_done', created: 5, type: 'session.execution.succeeded', data: { sessionID: 'ses_testA' } },
          { payload: { type: 'session.text.delta', data: { ...block, sessionID: 'ses_other', delta: 'PRIVATE' } } }
        ];
        const bytes = Buffer.from(events.map(event => 'data: '+JSON.stringify(event)+'\n\n').join(''));
        for (let offset = 0; offset < bytes.length; offset += 37) res.write(bytes.subarray(offset, offset + 37));
        res.end(); return;
      }
      if (holdEvents) { res.flushHeaders(); res.on('close', () => eventClosed?.()); return; }
      res.write('data: {"type":"session.text.delta","data":{"sessionID":"ses_unrelated","delta":"PRIVATE"}}\n\n');
      res.write('data: {"type":"session.text.delta","data":{"sessionID":"ses_testA","delta":"syn');
      res.end('thetic"}}\n\n'); return;
    }
    if (req.url === '/v1/audio/speech') {
      const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => {
        const obj = JSON.parse(Buffer.concat(chunks));
        if (obj.response_format === 'wav') { res.writeHead(200, { 'Content-Type': 'audio/wav' }); res.end(wav); }
        else { res.writeHead(200, { 'Content-Type': 'audio/pcm', 'X-Sample-Rate': '24000' }); res.write(Buffer.from([0, 1])); res.end(Buffer.from([2, 3])); }
      }); return;
    }
    const chunks = []; req.on('data', c => chunks.push(c)); req.on('end', () => {
      mutations.push({ url: req.url, body: JSON.parse(Buffer.concat(chunks)) });
      if (mutations.at(-1).body.text === 'synthetic ambiguous acceptance') { req.socket.destroy(); return; }
      res.end(JSON.stringify({ interrupted: true }));
    });
  });
  fake.on('upgrade', (req, socket, head) => {
    assert.equal(req.url, '/v1/transcribe?partials=1');
    assert.equal(req.headers.authorization, undefined, 'phone credential must not reach ASR');
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    if (head.length) socket.write(head);
    socket.on('data', b => socket.write(b)); // Byte tunnel fake, not a speech service.
  });
  await listen(fake);
  bridge = createBridge({ credentials: store, ocClient: new OpenChamberClient({ file: path.join(dir, 'absent-client.json') }), discover: () => fake.address().port, chief: () => chief, ttsPort: fake.address().port, asrPort: fake.address().port, diagnostic: entry => stages.push(entry) });
  await listen(bridge); base = 'http://127.0.0.1:' + bridge.address().port;
});
after(async () => { bridge.shutdown(); await close(fake); fs.rmSync(dir, { recursive: true }); });

test('one-use pairing produces separate device credential and consumes bootstrap', async () => {
  const result = await call('/floating-voice/v1/pair', { method: 'POST', auth: null, data: { bootstrap: 'test-only-bootstrap' } });
  assert.equal(result.status, 200); credential = result.json().credential;
  assert.notEqual(credential, 'test-only-bootstrap');
  assert.equal((fs.statSync(store.file).mode & 0o777), 0o600);
  assert.ok(!fs.readFileSync(store.file, 'utf8').includes(credential));
  assert.equal((await call('/floating-voice/v1/pair', { method: 'POST', data: { bootstrap: 'test-only-bootstrap' } })).status, 401);
});
test('device-bound pairing loss recovery is bounded and proof-specific', () => {
  const file = path.join(dir, 'recovery.json'), bootstrap = 'synthetic-recovery-only', proposed = 'p'.repeat(43);
  fs.writeFileSync(file, JSON.stringify({ bootstrap: crypto.createHash('sha256').update(bootstrap).digest('hex'), expires: Date.now() + 60000, devices: {} }), { mode: 0o600 });
  const credentials = new Credentials(file);
  const first = credentials.pair(bootstrap, proposed);
  assert.deepEqual(new Credentials(file).pair(bootstrap, proposed), first);
  assert.throws(() => credentials.pair(bootstrap, 'q'.repeat(43)));
  assert.throws(() => credentials.pair(bootstrap));
  const device = credentials.device('Bearer ' + proposed);
  device.pairRecovery.expires = Date.now() - 1; credentials.save();
  assert.throws(() => new Credentials(file).pair(bootstrap, proposed));
  delete device.pairRecovery; credentials.save();
  assert.throws(() => credentials.pair(bootstrap, proposed));
  assert.equal(credentials.device('Bearer ' + proposed).deviceID, first.deviceID);
  assert.ok(!fs.readFileSync(file, 'utf8').includes(proposed));
});
test('authentication and browser-origin refusal precede upstream requests', async () => {
  const before = seen.length;
  for (const auth of [null, 'test-only-bootstrap', 'a'.repeat(43)]) assert.equal((await call('/floating-voice/v1/health', { auth })).status, 401);
  assert.equal((await call('/floating-voice/v1/health', { headers: { Origin: 'https://attacker.invalid' } })).status, 403);
  assert.equal(seen.length, before);
});
test('exact unstripped prefix; no URL, file, traversal, control or query proxy', async () => {
  for (const url of ['/v1/health', '/floating-voice-evil/v1/health', '/floating-voice/api/openchamber/control', '/floating-voice/v1/health?url=http://localhost', '/floating-voice/../secret', '/floating-voice/%2e%2e/secret', '/floating-voice//v1/health']) {
    const r = await call(url); assert.ok([400, 404].includes(r.status), `${url}: ${r.status}`);
  }
  assert.equal((await call('/floating-voice/v1/health')).status, 200);
});
test('explicit selection grants one target and requires its generation', async () => {
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/messages')).status, 409);
  const r = await call('/floating-voice/v1/selection', { method: 'POST', data: { sessionID: 'ses_testA', mode: 'chief' } });
  assert.equal(r.status, 200); generation = r.json().generation;
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/state', { gen: 'stale' })).status, 409);
  assert.equal((await call('/floating-voice/v1/sessions/ses_testB/state')).status, 409);
  assert.deepEqual((await call('/floating-voice/v1/sessions/ses_testA/state')).json(), { active: true });
  assert.ok(!(await call('/floating-voice/v1/sessions/ses_testA/state')).text.includes('ses_unrelated'));
});
test('history retains raw content records; server filters SSE across chunk boundaries', async () => {
  const r = await call('/floating-voice/v1/sessions/ses_testA/messages');
  assert.equal(r.json().data[0].files[0].mime, 'image/png');
  assert.equal(r.json().data[1].content[2].state.content[0].type, 'file');
  const events = await call('/floating-voice/v1/sessions/ses_testA/events');
  assert.equal(events.status, 200); assert.ok(events.text.includes('synthetic')); assert.ok(!events.text.includes('PRIVATE')); assert.ok(!events.text.includes('unrelated'));
});
test('history resolves per-message source title through desktop reads before prefix fallback', async () => {
  senderScenario = true;
  try {
    const response = await call('/floating-voice/v1/sessions/ses_testA/messages');
    assert.equal(response.status, 200);
    const row = response.json().data[0];
    assert.deepEqual(row.sender, { kind: 'agent', label: 'Agent · [lead] Dream Studio' });
    assert.equal(row.text, '[chief]\nMetadata-owned payload.');
    assert.equal(row.displayText, undefined);
    assert.ok(seen.includes('/api/session/ses_source'));
  } finally { senderScenario = false; }
});
test('healthy history has one short aggregate budget for eight hung optional titles', { timeout: 1500 }, async () => {
  slowSenderScenario = true;
  try {
    const started = performance.now();
    const response = await call('/floating-voice/v1/sessions/ses_testA/messages');
    const elapsed = performance.now() - started;
    assert.equal(response.status, 200); assert.equal(response.json().data.length, 8);
    assert.ok(response.json().data.every(row => row.sender.label === 'Agent message' && row.text === 'Healthy history body.'));
    assert.ok(elapsed < 650, `Optional titles delayed healthy history ${elapsed}ms`);
    assert.equal(seen.filter(url => /^\/api\/session\/ses_slow[0-7]$/.test(url)).length, 8);
    if (bridge.workStats().activeUpstreams) await once(bridge, 'upstreamIdle');
    assert.equal(bridge.workStats().activeUpstreams, 0, 'Budget cancels sockets, not just a Promise.race');
  } finally { slowSenderScenario = false; }
});
test('SSE parser bounds unterminated events', async () => {
  const parser = new SessionEvents('ses_testA');
  parser.resume(); parser.end(Buffer.alloc(262145));
  await once(parser, 'end');
  assert.ok(parser.maxBufferedBytes <= 262144);
  assert.equal(parser.bufferedBytes, 0);
});
test('session filter preserves sanitized upstream heartbeat without leaking global comments', async () => {
  const filter = new SessionEvents('ses_testA');
  const chunks = [];
  filter.on('data', chunk => chunks.push(chunk));
  filter.end(': PRIVATE GLOBAL COMMENT\n\n');
  await once(filter, 'end');
  assert.equal(Buffer.concat(chunks).toString(), ': heartbeat\n\n');
});
test('restricted native bridge preserves installed direct/enveloped frames without SSE ids and filters before publication', async () => {
  installedScenario = true;
  try {
    const response = await call('/floating-voice/v1/sessions/ses_testA/events');
    assert.equal(response.status, 200);
    const events = response.text.split('\n\n').filter(frame => frame.startsWith('data: ')).map(frame => JSON.parse(frame.slice(6)));
    assert.equal(events.length, 7);
    assert.ok(events.every(event => event.data.sessionID === 'ses_testA' && !event.payload));
    assert.equal(events[1].id, 'evt_delta');
    assert.equal(events[2].id, undefined);
    assert.equal(events[2].data.delta, events[3].data.delta, 'identical unnumbered frames must both survive');
    assert.equal(events[5].data.text, 'Synthetic reply. Same Same');
    assert.equal(events[6].type, 'session.execution.succeeded');
    assert.ok(!response.text.includes('PRIVATE') && !response.text.includes('id:'));
  } finally { installedScenario = false; }
});
test('strict prompt/interrupt payload; each mutation forwarded once to fake only', async () => {
  const n = mutations.length;
  for (const data of [{ text: '' }, { text: 'synthetic', directory: '/' }, { text: 'synthetic', resume: true }, { text: 'synthetic', delivery: 'evil' }]) assert.equal((await call('/floating-voice/v1/sessions/ses_testA/prompt', { method: 'POST', data })).status, 400);
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/prompt', { method: 'POST', data: { text: 'synthetic fixture only', delivery: 'queue' } })).status, 200);
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/interrupt', { method: 'POST', data: {} })).status, 200);
  assert.deepEqual(mutations.slice(n).map(x => x.url), ['/api/session/ses_testA/prompt', '/api/session/ses_testA/interrupt?resume=false']);
});
test('body limits refuse large prompts before mutation', async () => {
  const n = mutations.length;
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/prompt', { method: 'POST', data: { text: 'x'.repeat(33000) } })).status, 413);
  assert.equal(mutations.length, n);
});
test('ambiguously accepted prompt is never automatically retried', async () => {
  const n = mutations.length;
  const r = await call('/floating-voice/v1/sessions/ses_testA/prompt', { method: 'POST', data: { text: 'synthetic ambiguous acceptance' } });
  assert.equal(r.status, 502); assert.match(r.text, /unknown/); assert.equal(mutations.length, n + 1);
});
test('upstream authentication requirement fails clearly without discovery', async () => {
  rejectUpstreamAuth = true;
  const r = await call('/floating-voice/v1/health');
  assert.equal(r.status, 502); assert.match(r.text, /authentication required; no credentials discovered/);
  rejectUpstreamAuth = false;
});
test('phone SSE cancellation closes the upstream stream', async () => {
  holdEvents = true;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('cancellation timeout')), 3000);
    eventClosed = () => { clearTimeout(timer); resolve(); };
    const req = http.get(base + '/floating-voice/v1/sessions/ses_testA/events', { headers: { Authorization: 'Bearer ' + credential, 'X-FV-Generation': generation } }, res => {
      res.once('data', () => res.destroy());
    }); req.on('error', reject);
  });
  holdEvents = false;
});
test('chief rotation never redirects an existing generation', async () => {
  chief = 'ses_testB'; const n = mutations.length;
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/prompt', { method: 'POST', data: { text: 'held synthetic' } })).status, 409);
  assert.equal(mutations.length, n); chief = 'ses_testA';
});
test('TTS streams exact bytes and sample rate', async () => {
  const r = await call('/floating-voice/tts/v1/audio/speech', { method: 'POST', data: { model: 'tts-1', voice: 'alloy', input: 'Synthetic', response_format: 'pcm' } });
  assert.equal(r.status, 200); assert.equal(r.headers['x-sample-rate'], '24000'); assert.equal(r.text, String.fromCharCode(0, 1, 2, 3));
});
test('actual Swift default WAV request and explicit WAV fallback pass restricted bridge', async () => {
  const r = await call('/floating-voice/tts/v1/audio/speech', { method: 'POST', data: fixture('tts-default-request') });
  assert.equal(r.status, 200); assert.equal(r.headers['content-type'], 'audio/wav'); assert.equal(r.text, wav.toString());
});
test('history pagination narrowly forwards opaque cursors and requested order', async () => {
  const first = await call('/floating-voice/v1/sessions/ses_testA/messages?limit=2&order=asc');
  assert.equal(first.status, 200); assert.equal(first.json().cursor.next, 'fixture_next');
  const second = await call('/floating-voice/v1/sessions/ses_testA/messages?limit=2&cursor=fixture_next');
  assert.equal(second.status, 200); assert.equal(second.json().data[1].id, 'msg_fixture3');
  assert.ok(seen.includes('/api/session/ses_testA/message?limit=2&cursor=fixture_next'));
  for (const query of ['limit=201', 'limit=0', 'order=evil', 'cursor=', 'cursor=x&order=asc', 'cursor=x&cursor=y', 'url=evil', 'cursor=a/b']) {
    assert.equal((await call('/floating-voice/v1/sessions/ses_testA/messages?' + query)).status, 400, query);
  }
});
async function upgrade(url, auth) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(bridge.address().port, '127.0.0.1'); let buffer = Buffer.alloc(0);
    const timer = setTimeout(() => { socket.destroy(); reject(new Error('WS timeout')); }, 3000);
    socket.on('error', reject);
    socket.on('connect', () => socket.write(`GET ${url} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n${auth ? 'Authorization: Bearer ' + auth + '\r\n' : ''}\r\n`));
    socket.on('data', c => {
      buffer = Buffer.concat([buffer, c]);
      const end = buffer.indexOf('\r\n\r\n');
      if (end < 0) return;
      if (!buffer.toString().startsWith('HTTP/1.1 101')) { clearTimeout(timer); socket.destroy(); resolve(buffer.toString()); return; }
      const payload = buffer.subarray(end + 4);
      if (payload.length >= 4) { assert.deepEqual(payload, Buffer.from([0x82, 2, 1, 2])); clearTimeout(timer); socket.destroy(); resolve('101 + binary echo'); }
      else socket.write(Buffer.from([0x82, 2, 1, 2]));
    });
  });
}
test('ASR exact upgrade path, authentication, bidirectional byte transport', async () => {
  assert.match(await upgrade('/floating-voice/asr/v1/transcribe?partials=1', null), /401/);
  assert.match(await upgrade('/floating-voice/asr/other?partials=1', credential), /404/);
  assert.equal(await upgrade('/floating-voice/asr/v1/transcribe?partials=1', credential), '101 + binary echo');
  const asr = stages.filter(entry => entry.stage === 'asr');
  assert.ok(asr.some(entry => entry.category === 'ready' && entry.status === 101));
  assert.ok(asr.some(entry => entry.category === 'failed' && entry.status === 401));
  assert.ok(asr.every(entry => Object.keys(entry).every(key => ['stage', 'category', 'elapsedMs', 'status', 'attempt', 'initiator', 'reason'].includes(key))));
  assert.ok(asr.every(entry => /^[a-f0-9-]{36}$/i.test(entry.attempt)));
  assert.ok(!JSON.stringify(asr).includes(credential), 'upgrade diagnostics contain no bearer');
});
test('reselection rotates generation even for the same target', async () => {
  const old = generation;
  const r = await call('/floating-voice/v1/selection', { method: 'POST', data: { sessionID: 'ses_testA', mode: 'explicit' } });
  assert.equal(r.status, 200); generation = r.json().generation; assert.notEqual(generation, old);
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/messages', { gen: old })).status, 409);
  assert.equal((await call('/floating-voice/v1/sessions/ses_testA/messages')).status, 200);
});
test('20 aborted discovery calls plus history and selection validation close every upstream', async () => {
  const other = createBridge({ credentials: store, ocClient: new OpenChamberClient({ file: path.join(dir, 'absent-client.json') }), discover: () => fake.address().port, chief: () => chief, maxUpstreams: 3, jsonDeadlineMs: 500 });
  await listen(other);
  try {
    const stages = Array.from({ length: 20 }, () => ['/api/system/info', '/floating-voice/v1/health']);
    stages.push(['/api/session/ses_testA/message?', '/floating-voice/v1/sessions/ses_testA/messages']);
    stages.push(['/api/session/ses_testA', '/floating-voice/v1/selection']);
    for (const [hang, url] of stages) {
      hangingPath = hang;
      const waiting = once(fake, 'hanging', { signal: AbortSignal.timeout(2000) });
      const data = url.endsWith('/selection') ? JSON.stringify({ sessionID: 'ses_testA', mode: 'explicit' }) : undefined;
      const req = http.request({ host: '127.0.0.1', port: other.address().port, path: url, method: data ? 'POST' : 'GET', headers: { Authorization: 'Bearer ' + credential, 'X-FV-Generation': generation, ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}) } });
      req.on('error', () => {}); req.end(data);
      const [response] = await waiting;
      const closed = once(response, 'close', { signal: AbortSignal.timeout(2000) });
      const idle = once(other, 'upstreamIdle', { signal: AbortSignal.timeout(2000) });
      req.destroy(); await Promise.all([closed, idle]);
      assert.equal(other.workStats().activeUpstreams, 0);
    }
    assert.ok(other.workStats().peakUpstreams <= 3);
  } finally { hangingPath = undefined; other.shutdown(); }
});
test('slow trickle cannot extend elapsed deadline and aggregate work admission is bounded', async () => {
  const other = createBridge({ credentials: store, ocClient: new OpenChamberClient({ file: path.join(dir, 'absent-client.json') }), discover: () => fake.address().port, chief: () => chief, maxUpstreams: 3, jsonDeadlineMs: 120 });
  await listen(other);
  hangingPath = '/api/system/info'; trickle = true;
  try {
    const started = Date.now();
    const results = await Promise.all(Array.from({ length: 6 }, () => new Promise((resolve, reject) => {
      const req = http.get({ host: '127.0.0.1', port: other.address().port, path: '/floating-voice/v1/health', headers: { Authorization: 'Bearer ' + credential } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); }); req.on('error', reject);
    })));
    assert.equal(results.filter(x => x === 429).length, 3);
    assert.equal(results.filter(x => x === 503).length, 3);
    assert.ok(Date.now() - started < 2000, 'elapsed deadline defeats continuous 10ms trickles');
    if (other.workStats().activeUpstreams) await once(other, 'upstreamIdle', { signal: AbortSignal.timeout(2000) });
    assert.equal(other.workStats().activeUpstreams, 0); assert.equal(other.workStats().peakUpstreams, 3);
  } finally { hangingPath = undefined; trickle = false; other.shutdown(); }
});
test('local revocation affects running bridge immediately', async () => {
  const d = store.device('Bearer ' + credential);
  new Credentials(store.file).revoke(d.deviceID);
  assert.equal((await call('/floating-voice/v1/health')).status, 401);
});
