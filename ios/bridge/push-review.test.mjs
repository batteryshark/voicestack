import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import { createAPNs } from './apns.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { PushStore } from './push-store.mjs';
import { CONFIG } from './reachout-policy.mjs';
import { Credentials, createBridge } from './server.mjs';
const moduleURL = name => process.env.M4_REVIEW_MODULE_DIR ? pathToFileURL(path.join(process.env.M4_REVIEW_MODULE_DIR, name)).href : new URL(name, import.meta.url).href;
const { PushService } = await import(moduleURL('./push-service.mjs'));
const { startSender } = await import(moduleURL('./push-socket.mjs'));
const { socketRequest } = await import(moduleURL('./reachout.mjs'));

const settings = { callsEnabled: true, quietHoursEnabled: false, quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 };
const intent = (id, kind = 'urgent-call', reason = 'decision') => ({ id, kind, reason, session: 'ses_fixture', title: 'Decision needed', body: 'A decision is blocking work.' });
const turns = async () => { for (let i = 0; i < 20; i++) await new Promise(setImmediate); };
function fixture(t, config = CONFIG) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'm4r-'));
  fs.mkdirSync(path.join(root, 'private'), { mode: 0o700 });
  const devices = [{ deviceID: 'A' }, { deviceID: 'B' }], sent = [], release = [];
  let now = Date.parse('2026-01-01T17:00Z');
  const service = new PushService({ store: new PushStore(path.join(root, 'private/push')), config, now: () => now,
    chief: () => 'ses_fixture', activeDevices: () => devices, apns: async request => { sent.push(request); return { status: 200 }; } });
  for (const [i, device] of devices.entries()) {
    service.update(device, 'enrollment', { alertToken: String(i + 1).repeat(64), voipToken: String(i + 3).repeat(64), environment: 'sandbox', build: 'fixture', revision: 1 });
    service.update(device, 'settings', settings);
  }
  t.after(async () => {
    service.apns = async () => ({ status: 200 });
    for (const done of release) done({ status: 200 });
    await service.drain?.(); fs.rmSync(root, { recursive: true, force: true });
  });
  return { root, service, devices, sent, release, advance: ms => { now += ms; }, now: () => now,
    target: (id, device = 'A') => service.store.data.records['r:' + id].targets['d:' + device],
    receipt: (id, event) => ({ reachoutID: id, callUUID: service.store.data.records['r:' + id].callUUID, event }) };
}

test('provider JWT is reused for call/fallback and concurrent sends, refreshing only at forty minutes', async () => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  let now = 1000000, reads = 0; const headers = [];
  const apns = createAPNs({ now: () => now, readKey: () => { reads++; return privateKey; }, connect: () => {
    const client = new EventEmitter(); client.destroy = () => {};
    client.request = h => {
      headers.push(h); const request = new EventEmitter(); request.close = () => {};
      request.end = () => queueMicrotask(() => { request.emit('response', { ':status': 200 }); request.emit('end'); });
      return request;
    }; return client;
  } });
  const send = () => apns({ token: 'f'.repeat(64), environment: 'sandbox', voip: true, payload: {}, collapseID: 'fixture' });
  await send(); now += 45000; await Promise.all([send(), send()]);
  assert.equal(reads, 1); assert.equal(new Set(headers.map(h => h.authorization)).size, 1);
  now = 1000000 + 40 * 60000 - 1; await send(); assert.equal(reads, 1);
  now++; await Promise.all([send(), send()]); assert.equal(reads, 2);
  assert.notEqual(headers[0].authorization, headers.at(-1).authorization);
  assert.equal(headers.at(-1).authorization, headers.at(-2).authorization);
});
test('two-device fallback at 45 seconds and state work bypass held ordinary APNs backlog', async t => {
  const f = fixture(t); await f.service.send(intent('call')); await f.service.drain?.();
  let hold = true; const fallbackAt = [];
  f.service.apns = request => {
    f.sent.push(request);
    if (request.payload.aps.category === 'URGENT_FALLBACK') { fallbackAt.push(f.now()); return Promise.resolve({ status: 200 }); }
    return hold ? new Promise(resolve => f.release.push(resolve)) : Promise.resolve({ status: 200 });
  };
  const sender = await startSender(f.service); const requests = [];
  try {
    for (let i = 0; i < 5; i++) requests.push(socketRequest(sender.socketPath, { command: 'send', request: intent('alert-' + i, 'need', 'hands') }, { projectRoot: f.root }));
    await turns(); f.advance(45000);
    let synced = false, recovered = false;
    const recovery = f.service.serial(() => f.service.recover()).then(() => { recovered = true; });
    const sync = f.service.serial(() => f.service.update(f.devices[0], 'settings', { ...settings, revision: 2 })).then(() => { synced = true; });
    const receipt = f.service.serial(() => f.service.event(f.devices[0], f.receipt('call', 'reported')));
    await turns();
    assert.equal(recovered, true, 'deadline recovery must not wait for ordinary HTTP/2 completion');
    assert.equal(synced, true); assert.deepEqual(fallbackAt, [f.now(), f.now()]);
    assert.equal(f.sent.filter(r => !r.voip && r.payload.aps.category !== 'URGENT_FALLBACK').length, 2, 'ordinary concurrency is bounded');
    hold = false; for (const done of f.release) done({ status: 200 });
    await Promise.all([...requests, recovery, sync, receipt]); await f.service.drain?.();
    assert.equal(f.sent.filter(r => r.voip).length, 2);
  } finally { hold = false; for (const done of f.release) done({ status: 200 }); await Promise.allSettled(requests); await f.service.drain?.(); await sender.close(); }
});
for (const component of ['private', 'private/push', 'private/push/sender.sock']) test('CLI rejects symlink at ' + component + ' beneath trusted project anchor', async t => {
  const f = fixture(t); const sender = await startSender(f.service);
  const source = path.join(f.root, component), moved = source + '-real';
  try {
    fs.renameSync(source, moved); fs.symlinkSync(moved, source);
    await assert.rejects(async () => socketRequest(sender.socketPath, { command: 'status', id: 'unknown' }, { projectRoot: f.root }), /private/);
  } finally { fs.unlinkSync(source); fs.renameSync(moved, source); await sender.close(); }
});
test('phone receipts require its own actual VoIP dispatch and cannot replay or alter a resolved fallback', async t => {
  const f = fixture(t, { ...CONFIG, dispatchConcurrency: 1 });
  let hold = true;
  f.service.apns = request => { f.sent.push(request); return hold && request.voip ? new Promise(resolve => f.release.push(resolve)) : Promise.resolve({ status: 200 }); };
  await f.service.send(intent('call'));
  const decline = f.receipt('call', 'declined');
  await assert.rejects(f.service.event(f.devices[1], decline), /binding/); // B is queued, not attempted.
  await assert.rejects(f.service.event({ deviceID: 'foreign' }, decline), /unavailable/);
  await assert.rejects(f.service.event(f.devices[0], { ...decline, reachoutID: 'unknown' }), /unavailable/);
  await assert.rejects(f.service.event(f.devices[0], { ...decline, callUUID: crypto.randomUUID() }), /binding/);
  for (const extra of [{ body: 'Change fallback text' }, { session: 'ses_other' }, { deviceID: 'B' }, { kind: 'urgent-call' }]) {
    await assert.rejects(f.service.event(f.devices[0], { ...decline, ...extra }), /schema/);
  }
  await f.service.event(f.devices[0], decline); await turns();
  const before = JSON.stringify(f.target('call'));
  for (const event of ['declined', 'report-failed']) await f.service.event(f.devices[0], { ...decline, event });
  assert.equal(JSON.stringify(f.target('call')), before, 'resolved receipt replays cannot mutate state');
  const fallback = f.sent.filter(r => r.payload.aps.category === 'URGENT_FALLBACK');
  assert.equal(fallback.length, 1); assert.equal(fallback[0].token, '1'.repeat(64));
  assert.equal(fallback[0].payload.aps.alert.body, 'Agent needs a decision');
  assert.equal(f.sent.filter(r => r.voip).length, 1);
  hold = false; for (const done of f.release) done({ status: 200 }); await f.service.drain?.();
  await f.service.event(f.devices[1], f.receipt('call', 'answered'));
  await f.service.event(f.devices[1], f.receipt('call', 'report-failed'));
  assert.equal(f.sent.filter(r => r.payload.aps.category === 'URGENT_FALLBACK').length, 1);
});
test('tokens stay private; HTTP permits only an immutable single fallback for an unresolved device-bound call', async t => {
  const f = fixture(t), diagnostics = [], outputs = [], errors = [];
  const tokens = ['1', '2', '3', '4'].map(s => s.repeat(64));
  f.service.apns = async request => { f.sent.push(request); throw Error('synthetic transport ' + request.token); };
  await f.service.send(intent('call')); await f.service.drain?.();
  const bearer = 'z'.repeat(43), other = 'y'.repeat(43), unpaired = 'x'.repeat(43);
  const file = path.join(f.root, 'private/fixture-auth.json');
  fs.writeFileSync(file, JSON.stringify({ devices: Object.fromEntries([[bearer, 'A'], [other, 'B'], [unpaired, 'foreign']].map(([key, deviceID]) =>
    [crypto.createHash('sha256').update(key).digest('hex'), { deviceID }])) }), { mode: 0o600 });
  const bridge = createBridge({ credentials: new Credentials(file), push: f.service, diagnostic: entry => diagnostics.push(entry) });
  await new Promise(resolve => bridge.listen(0, '127.0.0.1', resolve)); t.after(() => bridge.shutdown());
  const sender = await startSender(f.service); t.after(() => sender.close());
  async function call(route, method = 'GET', data, auth = bearer) {
    const response = await fetch(`http://127.0.0.1:${bridge.address().port}/floating-voice/v1/push/${route}`, { method,
      headers: { authorization: 'Bearer ' + auth, ...(data ? { 'content-type': 'application/json' } : {}) }, body: data ? JSON.stringify(data) : undefined });
    const text = await response.text(); outputs.push(text); return response.status;
  }
  const baseline = f.sent.length;
  for (const route of ['send', 'sender', 'urgent-call', 'call', 'status', 'events/declined', 'reachouts/call/send']) assert.equal(await call(route, 'POST', intent('inject')), 404);
  assert.equal(await call('settings'), 200);
  assert.equal(await call('settings', 'PUT', { ...settings, revision: 2 }), 200);
  const enrollment = f.service.device('A').enrollment;
  const { syncedAt, ...snapshot } = enrollment;
  assert.equal(await call('enrollment', 'PUT', { ...snapshot, revision: 2 }), 200);
  assert.equal(await call('enrollment', 'PUT', { ...snapshot, revision: 1 }), 409);
  assert.equal(await call('reachouts/call'), 200);
  const receipt = f.receipt('call', 'report-failed');
  assert.equal(await call('events', 'POST', receipt, unpaired), 404);
  assert.equal(await call('events', 'POST', { ...receipt, callUUID: crypto.randomUUID() }, other), 409);
  assert.equal(await call('events', 'POST', { ...receipt, reachoutID: 'unknown' }), 404);
  for (const extra of [{ body: tokens[0] }, { deviceID: 'B' }, { session: 'ses_other' }, { reason: 'goal-risk' }]) {
    assert.equal(await call('events', 'POST', { ...receipt, ...extra }), 400);
  }
  assert.equal(f.sent.length, baseline, 'no HTTP lookup/update/rejected path may dispatch');
  assert.equal(await call('events', 'POST', receipt), 200); await f.service.drain?.();
  const resolved = JSON.stringify(f.target('call'));
  assert.equal(await call('events', 'POST', receipt), 200);
  assert.equal(await call('events', 'POST', { ...receipt, event: 'declined' }), 200);
  assert.equal(JSON.stringify(f.target('call')), resolved);
  assert.equal(f.sent.length, baseline + 1); assert.equal(f.sent.at(-1).voip, false);
  assert.equal(f.sent.at(-1).token, tokens[0]); assert.equal(f.sent.at(-1).payload.aps.alert.body, 'Agent needs a decision');
  outputs.push(JSON.stringify(f.service.status('call')));
  outputs.push(JSON.stringify(await socketRequest(sender.socketPath, { command: 'status', id: 'call' }, { projectRoot: f.root })));
  // Exercise the real CLI stdout/stderr against this synthetic project's socket.
  const cliDir = path.join(f.root, 'bridge'); fs.mkdirSync(cliDir, { mode: 0o700 });
  for (const name of ['reachout.mjs', 'reachout-policy.mjs', 'push-store.mjs', 'dev-override.mjs']) fs.copyFileSync(new URL(name, import.meta.url), path.join(cliDir, name));
  const cli = await promisify(execFile)(process.execPath, [fs.realpathSync(path.join(cliDir, 'reachout.mjs')), 'status', '--id', 'call']);
  outputs.push(cli.stdout, cli.stderr); assert.equal(JSON.parse(cli.stdout).id, 'call');
  try { f.service.update(f.devices[0], 'enrollment', { ...snapshot, extra: tokens[0] }); } catch (e) { errors.push(e.message); }
  await turns();
  for (const token of tokens) {
    assert.equal(JSON.stringify({ outputs, errors, diagnostics }).includes(token), false);
    assert.equal(JSON.stringify(f.sent.map(r => r.payload)).includes(token), false);
  }
  const files = fs.readdirSync(path.join(f.root, 'private'), { recursive: true }).map(p => path.join(f.root, 'private', p)).filter(p => fs.lstatSync(p).isFile());
  for (const p of files) {
    if (p !== f.service.store.file) for (const token of tokens) assert.equal(fs.readFileSync(p, 'utf8').includes(token), false);
  }
  assert.equal(fs.statSync(f.service.store.directory).mode & 0o777, 0o700);
  assert.equal(fs.statSync(f.service.store.file).mode & 0o777, 0o600);
  assert.equal(tokens.every(token => fs.readFileSync(f.service.store.file, 'utf8').includes(token)), true);
  assert.deepEqual(fs.readdirSync(f.service.store.directory).sort(), ['sender.sock', 'state.json']);
});
test('failed atomic replacement retains prior state and removes temporary token-bearing files', t => {
  const f = fixture(t), previous = fs.readFileSync(f.service.store.file, 'utf8'), rename = fs.renameSync;
  try {
    fs.renameSync = () => { throw Error('synthetic rename failure'); };
    assert.throws(() => f.service.store.save(), /rename failure/);
  } finally { fs.renameSync = rename; }
  assert.equal(fs.readFileSync(f.service.store.file, 'utf8'), previous);
  assert.deepEqual(fs.readdirSync(f.service.store.directory), ['state.json']);
});
test('late answer suppresses queued fallback; crash-uncertain queued alerts are never dispatched on recovery', async t => {
  const f = fixture(t, { ...CONFIG, dispatchConcurrency: 1 });
  await f.service.send(intent('call')); await f.service.drain();
  let hold = true;
  f.service.apns = request => { f.sent.push(request); return hold ? new Promise(resolve => f.release.push(resolve)) : Promise.resolve({ status: 200 }); };
  f.advance(45000); await f.service.recover();
  assert.equal(f.sent.filter(r => r.payload.aps.category === 'URGENT_FALLBACK').length, 1);
  await f.service.event(f.devices[1], f.receipt('call', 'answered'));
  hold = false; for (const done of f.release) done({ status: 200 }); await f.service.drain();
  assert.equal(f.target('call', 'B').fallback.state, 'suppressed-answer');
  assert.equal(f.sent.filter(r => r.payload.aps.category === 'URGENT_FALLBACK').length, 1);
  hold = true;
  await f.service.send(intent('ordinary-1', 'need', 'hands')); await f.service.send(intent('ordinary-2', 'need', 'hands'));
  let restartedAttempts = 0;
  const before = f.sent.length, restarted = new PushService({ store: new PushStore(f.service.store.directory), apns: async () => { restartedAttempts++; throw Error('must not send'); },
    chief: () => 'ses_fixture', activeDevices: () => f.devices, now: f.now });
  await restarted.recover(); await restarted.recover();
  assert.equal(restarted.device('B').enrollment.alertToken, '2'.repeat(64));
  assert.equal(restarted.store.data.records['r:ordinary-2'].targets['d:B'].alert.state, 'delivery-unknown');
  assert.equal(f.sent.length, before);
  assert.equal(restartedAttempts, 0);
  hold = false; for (const done of f.release) done({ status: 200 }); await f.service.drain();
});
