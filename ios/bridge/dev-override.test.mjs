import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readDevOverride, writeDevOverride } from './dev-override.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { CONFIG } from './reachout-policy.mjs';
import { main, parseArgs } from './reachout.mjs';

function fixture(t, config = CONFIG) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-dev-override-'));
  fs.mkdirSync(path.join(root, 'private'), { mode: 0o700 });
  const directory = path.join(root, 'private/push'), store = new PushStore(directory);
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let at = Date.parse('2026-10-16T12:00:00Z');
  const device = { deviceID: 'synthetic' }, sent = [], diagnostics = [];
  const service = new PushService({ store, config, chief: () => 'ses_fixture', activeDevices: () => [device], now: () => at,
    apns: async item => { sent.push(item); return { status: 200 }; }, diagnostic: entry => diagnostics.push(entry) });
  service.update(device, 'enrollment', { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64), environment: 'sandbox', build: '27', revision: 1 });
  service.update(device, 'settings', { callsEnabled: true, quietHoursEnabled: false, quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 });
  const input = (id, kind = 'urgent-call') => ({ id, kind, reason: 'decision', session: 'ses_fixture', title: 'Synthetic development test', body: 'Synthetic only' });
  const target = id => store.data.records['r:' + id].targets['d:synthetic'];
  const seed = (count, age = 1) => { for (let i = 0; i < count; i++) store.data.records['r:seed' + i] = { targets: { 'd:synthetic': { callAttemptAt: at - age, receipt: 'ended', endedAt: at - age } } }; };
  const on = (minutes = 30) => writeDevOverride(directory, { enabled: true, minutes, reason: 'Synthetic tests' }, at);
  const end = async id => {
    const callUUID = store.data.records['r:' + id].callUUID;
    await service.event(device, { reachoutID: id, callUUID, event: 'answered' });
    await service.event(device, { reachoutID: id, callUUID, event: 'ended', endReason: 'requested', endInitiator: 'app' });
  };
  return { root, directory, store, service, sent, diagnostics, device, input, target, seed, on, end, now: () => at, advance: ms => { at += ms; } };
}

test('spacing bypass is fresh-read, audited in ledger/status and off restores it without restart', async t => {
  const f = fixture(t); f.seed(1);
  await f.service.send(f.input('normal')); assert.equal(f.target('normal').reason, 'call-spacing');
  f.on(); await f.service.send(f.input('dev')); await f.service.drain();
  assert.equal(f.target('dev').reason, 'urgent-eligible'); assert.equal(f.target('dev').override, 'dev');
  assert.equal(f.service.status('dev').targets[0].override, 'dev');
  assert.deepEqual(f.diagnostics, [{ stage: 'push', category: 'dev_override', override: 'dev' }]);
  assert.equal(f.sent.filter(x => x.voip).length, 1);
  await f.end('dev');
  writeDevOverride(f.directory, { enabled: false }, f.now());
  await f.service.send(f.input('off')); assert.equal(f.target('off').reason, 'call-spacing');
  assert.equal(f.target('off').override, undefined);
});
test('daily cap bypass expires and normal daily limits include the test call', async t => {
  const f = fixture(t, { ...CONFIG, callSpacingMs: 0 }); f.seed(3, 7200000);
  await f.service.send(f.input('normal')); assert.equal(f.target('normal').reason, 'call-daily-limit');
  f.on(1); await f.service.send(f.input('dev')); await f.service.drain(); await f.end('dev');
  assert.equal(f.target('dev').override, 'dev'); f.advance(60000);
  assert.equal(readDevOverride(f.directory, f.now()).active, false);
  await f.service.send(f.input('expired')); assert.equal(f.target('expired').reason, 'call-daily-limit');
});
test('notification hourly cap bypass applies only while active and keeps normal payload priority', async t => {
  const f = fixture(t, { ...CONFIG, notificationsPerHour: 0 });
  await f.service.send(f.input('normal', 'need')); assert.equal(f.target('normal').reason, 'notification-limit');
  f.on(1); await f.service.send(f.input('dev', 'need')); await f.service.drain();
  assert.equal(f.target('dev').override, 'dev'); assert.equal(f.sent.length, 1);
  assert.equal(f.sent[0].payload.aps['interruption-level'], 'active');
  f.advance(60000); await f.service.send(f.input('expired', 'need'));
  assert.equal(f.target('expired').reason, 'notification-limit');
});
test('invalid, future-dated, expired and over-24h files fail closed, including permissions and symlinks', t => {
  const f = fixture(t), file = path.join(f.directory, 'dev-override.json');
  assert.equal(readDevOverride(f.directory, f.now()).active, false);
  const base = { version: 1, enabled: true, setAt: f.now(), until: f.now() + 60000, reason: 'Synthetic' };
  for (const changes of [{ version: 2 }, { enabled: 'true' }, { until: f.now() }, { until: f.now() + 86400001 }, { setAt: f.now() + 1 }, { reason: '' }, { reason: 'bad\nreason' }, { extra: true }]) {
    fs.writeFileSync(file, JSON.stringify({ ...base, ...changes }), { mode: 0o600 });
    assert.equal(readDevOverride(f.directory, f.now()).active, false);
  }
  fs.writeFileSync(file, '{bad'); assert.equal(readDevOverride(f.directory, f.now()).active, false);
  f.on(1440); assert.equal(readDevOverride(f.directory, f.now()).active, true);
  fs.chmodSync(file, 0o644); assert.equal(readDevOverride(f.directory, f.now()).active, false); fs.chmodSync(file, 0o600);
  fs.renameSync(file, file + '.saved'); fs.symlinkSync(file + '.saved', file);
  assert.equal(readDevOverride(f.directory, f.now()).active, false);
});
test('quiet hours and quiet boundary remain enforced with override active', async t => {
  for (const boundary of [false, true]) {
    const f = fixture(t); f.on();
    const settings = f.store.data.devices['d:synthetic'].settings;
    Object.assign(settings, { quietHoursEnabled: true, quietStart: boundary ? '12:01' : '11:00', quietEnd: '13:00' });
    if (boundary) f.advance(40000);
    await f.service.send(f.input(boundary ? 'boundary' : 'quiet')); await f.service.drain();
    assert.equal(f.target(boundary ? 'boundary' : 'quiet').reason, boundary ? 'quiet-boundary' : 'quiet-hours');
    assert.equal(f.sent.filter(x => x.voip).length, 0);
  }
});
test('outstanding call, calls-off, stale policy and token checks remain enforced', async t => {
  for (const mode of ['outstanding', 'calls-off', 'policy-stale', 'no-voip-token', 'no-alert-token']) {
    const f = fixture(t); f.on(); const d = f.store.data.devices['d:synthetic'];
    if (mode === 'outstanding') f.store.data.records['r:prior'] = { targets: { 'd:synthetic': { callAttemptAt: f.now(), fallbackDeadline: f.now() + 60000 } } };
    if (mode === 'calls-off') d.settings.callsEnabled = false;
    if (mode === 'policy-stale') d.settings.syncedAt -= CONFIG.policyFreshMs;
    if (mode === 'no-voip-token') d.enrollment.voipToken = null;
    if (mode === 'no-alert-token') d.enrollment.alertToken = null;
    await f.service.send(f.input('blocked')); await f.service.drain();
    assert.equal(f.target('blocked').reason, mode === 'outstanding' ? 'call-outstanding' : mode);
    assert.equal(f.sent.filter(x => x.voip).length, 0);
  }
});
test('override keeps ledger bound/id uniqueness/fullness and normal Focus failure receipts/fallback', async t => {
  const f = fixture(t); f.seed(1); f.on();
  await f.service.send(f.input('dev')); await f.service.drain();
  assert.equal((await f.service.send(f.input('dev'))).coalesced, true);
  await assert.rejects(f.service.send({ ...f.input('dev'), body: 'Different' }), { status: 409 });
  await f.service.event(f.device, { reachoutID: 'dev', callUUID: f.store.data.records['r:dev'].callUUID,
    event: 'report-failed', reportFailure: 'filteredByDoNotDisturb' });
  await f.service.drain(); assert.ok(f.target('dev').fallback);
  assert.equal(f.target('dev').terminalReceipt.reportFailure, 'filteredByDoNotDisturb');
  const full = fixture(t, { ...CONFIG, maxRecords: 1 }); full.seed(1); full.on();
  await assert.rejects(full.service.send(full.input('new')), { status: 429 });
});
test('CLI on/status/off uses existing private storage, max1440, mode0600 and no sender socket', async t => {
  const f = fixture(t), options = { projectRoot: f.root, now: f.now };
  const on = await main(['dev-override', 'on', '--minutes', '30', '--reason', 'Synthetic test'], options);
  assert.equal(on.active, true); assert.ok(on.until); assert.equal(on.reason, 'Synthetic test');
  assert.equal(fs.statSync(path.join(f.directory, 'dev-override.json')).mode & 0o777, 0o600);
  assert.equal((await main(['dev-override', 'status'], options)).active, true);
  assert.equal((await main(['dev-override', 'off'], options)).active, false);
  assert.equal((await main(['dev-override', 'status'], options)).active, false);
  for (const args of [[], ['on'], ['on', '--minutes', '0', '--reason', 'Test'], ['on', '--minutes', '1441', '--reason', 'Test'], ['off', '--minutes', '1']]) {
    assert.throws(() => parseArgs(['dev-override', ...args]));
  }
});
