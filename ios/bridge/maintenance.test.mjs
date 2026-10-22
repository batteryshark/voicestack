import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { Maintenance } from './maintenance.mjs';
import { PushService } from './push-service.mjs';
import { PushStore } from './push-store.mjs';
import { startSender } from './push-socket.mjs';
import { createBridge } from './server.mjs';
import { socketRequest, parseArgs } from './reachout.mjs';

function directory(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fv-maint-')));
  fs.mkdirSync(path.join(root, 'private'), { mode: 0o700 });
  const dir = path.join(root, 'private/push'); fs.mkdirSync(dir, { mode: 0o700 });
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return { root, dir };
}
function stub(m) {
  m.counts = () => ({ active: 0 }); m.listening = () => false;
  m.stopListening = async () => {}; m.startListening = async () => {};
  return m;
}
test('durable hold, distinct quiet ACK, invalid/symlink state fails closed; owner release only', async t => {
  const { dir } = directory(t); const m = stub(new Maintenance(dir));
  assert.equal(m.held, false);
  m.counts = () => ({ active: 1 });
  assert.equal((await m.command('hold')).localQuiet, false);
  await assert.rejects(m.command('seal'), { status: 409 });
  assert.equal(new Maintenance(dir).held, true);
  fs.writeFileSync(m.file, '{}');
  assert.equal(new Maintenance(dir).invalid, true);
  fs.unlinkSync(m.file); fs.symlinkSync(path.join(dir, 'absent'), m.file);
  assert.equal(new Maintenance(dir).held, true);
  await assert.rejects(m.command('release'));
  fs.unlinkSync(m.file); m.counts = () => ({ active: 0 });
  await m.command('release'); assert.equal(new Maintenance(dir).held, false);
  fs.chmodSync(m.file, 0o644); assert.equal(new Maintenance(dir).invalid, true);
});
test('pre-hold sender validation settles naturally; new enqueue refused', async t => {
  const { dir } = directory(t); let finish;
  const ready = new Promise(resolve => { finish = resolve; });
  const service = new PushService({ store: new PushStore(dir), chief: () => 'ses_TEST', activeDevices: () => [],
    validateOrigin: () => ready });
  service.maintenance = stub(new Maintenance(dir));
  service.admit = () => ({ settled: true }); // No APNs, token, policy or ledger reads.
  const work = service.send({ id: 'test', kind: 'urgent-call', reason: 'decision', session: 'ses_TEST', title: 'Test', body: 'Test' });
  assert.equal(service.localStats().senderWork, 1);
  await service.maintenance.command('hold');
  await assert.rejects(service.send({}), { status: 503 });
  assert.equal(service.localStats().senderWork, 1);
  finish(); assert.deepEqual(await work, { settled: true });
  assert.equal(service.localStats().senderWork, 0);
});
test('local jobs, invitations, leases/calls and callbacks block; historical uncertainty does not', t => {
  const { dir } = directory(t);
  const p = new PushService({ store: new PushStore(dir), now: () => 100, activeDevices: () => [] });
  p.store.data.records.x = { targets: { d: { callAttemptAt: 0, receipt: 'answered' } } };
  assert.equal(p.localStats().invitations, 1);
  p.store.data.records.x.targets.d.endedAt = 99;
  p.store.data.records.y = { targets: { d: { state: 'delivery-unknown' } } };
  p.openVoice = { state: { calls: { c: { state: 'accepted', lease: {}, operations: {} } } }, pendingEndNotes: 1 };
  assert.equal(p.localStats().candidateCalls, 1); assert.equal(p.localStats().endNotes, 1);
  p.openVoice.state.calls.c = { state: 'ended', operations: { old: { state: 'uncertain', operation_id: 'preserved' } } };
  p.openVoice.pendingEndNotes = 0;
  p.jobs.add('live'); assert.equal(p.localStats().pushJobs, 1); p.jobs.delete('live');
  assert.ok(Object.values(p.localStats()).every(n => n === 0));
  assert.equal(p.openVoice.state.calls.c.operations.old.operation_id, 'preserved');
});
test('every exposed local blocker prevents seal even without an active client socket', async t => {
  const { dir } = directory(t); const m = stub(new Maintenance(dir));
  await m.command('hold');
  for (const field of ['activeHandlers', 'activeUpstreams', 'startupChecks', 'senderWork', 'pushPending', 'pushJobs',
    'pushNetwork', 'pushLanes', 'invitations', 'candidateCalls', 'candidateFallbacks', 'candidateResolves', 'endNotes',
    'mediaSessions', 'mediaJobs', 'mediaUpgrades', 'mediaPCM', 'mediaRaw']) {
    m.counts = () => ({ connections: 0, [field]: 1 });
    assert.equal(m.status().localQuiet, false, field);
    await assert.rejects(m.command('seal'), { status: 409 }, field);
  }
  m.counts = () => ({ connections: 0 });
  assert.equal((await m.command('seal')).localQuiet, true);
});
test('disconnected request still draining its async dependency cannot falsely seal', { timeout: 5000 }, async t => {
  const { dir } = directory(t); const m = new Maintenance(dir);
  let began, finish;
  const started = new Promise(resolve => { began = resolve; });
  const pending = new Promise((resolve, reject) => { finish = () => reject(new Error('synthetic dependency settled')); });
  const server = createBridge({ maintenance: m, credentials: { device: () => ({}) }, discover: () => 1,
    ocClient: { check: async () => {}, prepare: () => { began(); return pending; } } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening'); t.after(() => server.shutdown());
  const request = http.get({ host: '127.0.0.1', port: server.address().port, path: '/floating-voice/v1/health' });
  request.on('error', () => {}); await started;
  await m.command('hold');
  const closed = new Promise(resolve => request.once('close', resolve)); request.destroy(); await closed;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(server.localStats().activeHandlers, 1);
  await assert.rejects(m.command('seal'), { status: 409 });
  finish(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(server.localStats().activeHandlers, 0);
  assert.equal((await m.command('seal')).localQuiet, true);
});

test('fake service socket: hold/drain/seal, natural event stream finish, held restart and release', { timeout: 10000 }, async t => {
  const { root, dir } = directory(t);
  const p = new PushService({ store: new PushStore(dir), activeDevices: () => [] });
  const m = new Maintenance(dir); p.maintenance = m;
  const upstream = http.createServer((req, res) => {
    if (req.url === '/api/system/info') res.end(JSON.stringify({ runtime: 'desktop' }));
    else if (req.url === '/api/event') { res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.write(': live\n\n'); stream = res; }
    else res.end('{}');
  });
  let stream;
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const credentials = { device: auth => { if (auth !== 'Bearer test') throw Object.assign(new Error('auth'), { status: 401 });
    return { deviceID: 'fake', sessionID: 'ses_TEST', generation: 'g' }; } };
  const ocClient = { prepare: async port => ({ port }), check: async () => {}, note() {} };
  let server;
  function make(state) {
    server = createBridge({ credentials, push: p, maintenance: state, ocClient, discover: () => upstream.address().port });
    state.startListening = async () => { server.listen(0, '127.0.0.1'); await once(server, 'listening'); };
    return server;
  }
  make(m); t.after(() => server.shutdown());
  await m.startListening();
  const sender = await startSender(p); t.after(() => sender.close());
  const command = action => socketRequest(path.join(dir, 'sender.sock'), { command: 'maintenance', action }, { projectRoot: root });
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 }); t.after(() => agent.destroy());
  const request = (method, url, auth = 'Bearer test', keepalive = false) => new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: server.address().port, method, path: '/floating-voice' + url,
      agent: keepalive ? agent : false,
      headers: { authorization: auth, 'x-fv-generation': 'g', Connection: keepalive ? 'keep-alive' : 'close' } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject); req.end();
  });
  assert.equal(await request('GET', '/v1/health', 'Bearer test', true), 200);
  const event = http.get({ host: '127.0.0.1', port: server.address().port, path: '/floating-voice/v1/sessions/ses_TEST/events',
    headers: { authorization: 'Bearer test', 'x-fv-generation': 'g' } });
  const [response] = await once(event, 'response'); response.resume();
  const ended = once(response, 'end');
  const held = await command('hold'); assert.equal(held.held, true); assert.equal(held.localQuiet, false);
  assert.equal((await command('seal')).status, 409);
  assert.equal(await request('POST', '/v1/sessions/ses_TEST/prompt'), 503);
  assert.equal(await request('POST', '/v1/sessions/ses_TEST/prompt', 'Bearer test', true), 503);
  agent.destroy();
  assert.equal(await request('POST', '/voice/v1/calls', 'Bearer caller'), 503);
  const upgrade = net.connect(server.address().port, '127.0.0.1');
  upgrade.write('GET /floating-voice/asr/v1/transcribe?partials=1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
  let reply = ''; upgrade.on('data', chunk => { reply += chunk; }); await once(upgrade, 'close');
  assert.match(reply, /^HTTP\/1.1 503/);
  assert.equal(await request('GET', '/v1/health'), 200);
  assert.equal(await request('GET', '/v1/health', 'Bearer wrong'), 401);
  assert.equal(await request('POST', '/v1/maintenance/release'), 503);
  // Existing SSE is not closed by hold. Its peer ends it naturally.
  assert.equal(response.readableEnded, false); stream.end(); await ended;
  // Observe actual close events, not repeated zero samples, before the seal.
  if (server.localStats().activeUpstreams) await once(server, 'upstreamIdle');
  await new Promise(resolve => setImmediate(resolve));
  const sealed = await command('seal'); assert.equal(sealed.localQuiet, true); assert.equal(sealed.listening, false);
  assert.equal(sealed.pid, process.pid); assert.equal(typeof sealed.nonce, 'string');
  const oldNonce = sealed.nonce;
  server.shutdown();
  const restarted = new Maintenance(dir); p.maintenance = restarted; make(restarted);
  assert.equal(server.listening, false); assert.equal(restarted.held, true);
  assert.notEqual((await command('status')).nonce, oldNonce);
  assert.equal((await command('status')).localQuiet, true);
  await command('release'); assert.equal(server.listening, true);
  assert.equal(await request('GET', '/v1/health'), 200);
  assert.deepEqual(parseArgs(['maintenance', 'status']), { command: 'maintenance', action: 'status' });
});
