import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ensureCallSpeech, main } from './reachout.mjs';
import { PushService } from './push-service.mjs';

const harness = (states, { synth = true, mapping = true, host = true, load = { ok: true } } = {}) => {
  const calls = { load: 0, synth: 0, inspect: 0 };
  return { calls, deps: {
    inspect: async () => states[Math.min(calls.inspect++, states.length - 1)],
    synthesize: async () => { calls.synth++; return synth; },
    ownerMapping: async () => mapping, admitHost: async () => host,
    runFixed: async (file, args) => { calls.load++; assert.deepEqual(args, ['load', 'all']); return load; } } };
};
const warm = { ready: true, loadable: false }, cold = { ready: false, loadable: true }, busy = { ready: false, loadable: false };

test('warm speech skips load but still proves a real synthesis and readiness', async () => {
  const { calls, deps } = harness([warm]);
  assert.deepEqual(await ensureCallSpeech(deps), { ready: true, load: 'skipped_ready' });
  assert.equal(calls.load, 0); assert.equal(calls.synth, 1);
});
test('cold speech loads once through the fixed command, then synthesizes', async () => {
  const { calls, deps } = harness([cold, cold, warm]);
  assert.deepEqual(await ensureCallSpeech(deps), { ready: true, load: 'completed' });
  assert.equal(calls.load, 1); assert.equal(calls.synth, 1);
});
test('any speech failure refuses before ringing', async () => {
  for (const [states, options, reason] of [[[busy], {}, 'speech_admission_denied'], [[cold], { host: false }, 'host_admission_denied'],
    [[warm], { mapping: false }, 'speech_owner_identity_unavailable'], [[cold, cold], { load: { ok: false } }, 'load_failed'],
    [[warm], { synth: false }, 'test_synthesis_failed'], [[warm, busy], {}, 'speech_not_ready_after_warm']]) {
    const { calls, deps } = harness(states, options);
    const result = await ensureCallSpeech(deps);
    assert.equal(result.ready, false); assert.equal(result.reason, reason);
    if (reason !== 'load_failed') assert.equal(calls.load, 0);
  }
});
test('ordinary urgent-call send refuses with one line and never reaches the sender socket', async () => {
  const args = ['send', '--kind', 'urgent-call', '--reason', 'decision', '--session', 'ses_A', '--id', 'speech-cold-1', '--title', 'T', '--body', 'B'];
  const result = await main(args, { projectRoot: '/nonexistent-voicestack-root', ensureSpeech: async () => ({ ready: false, reason: 'load_failed', load: 'failed' }) });
  assert.equal(result.outcome, 'refused'); assert.equal(result.reason, 'speech_not_ready');
  assert.match(result.detail, /^Call not placed: speech not ready \(load_failed, load failed\); nothing was sent$/);
  let checked = false;
  const dry = await main([...args, '--dry-run'], { ensureSpeech: async () => { checked = true; return { ready: false }; } });
  assert.equal(dry.disposition, 'dry-run'); assert.equal(checked, false);
});
test('answered ordinary call keeps speech in use until it ends', async () => {
  const target = { receipt: 'answered', voipAttemptedAt: 1 };
  const store = { data: { records: { 'r:call-1': { request: { kind: 'urgent-call', id: 'call-1' }, targets: { 'd:D': target } } }, devices: {} }, save() {} };
  let touches = 0;
  const push = new PushService({ store, apns: () => null, chief: () => 'ses_A', activeDevices: () => [], speechKeepalive: async () => { touches++; }, keepaliveMs: 15 });
  push.keepSpeechWarm('call-1', 'D'); push.keepSpeechWarm('call-1', 'D');
  assert.equal(push.keepalives.size, 1);
  await new Promise(r => setTimeout(r, 70));
  assert.ok(touches >= 2, `touches ${touches}`);
  target.endedAt = 2;
  await new Promise(r => setTimeout(r, 40));
  assert.equal(push.keepalives.size, 0);
  const after = touches; await new Promise(r => setTimeout(r, 40)); assert.equal(touches, after);
  target.endedAt = undefined; target.receipt = 'ringing';
  push.keepSpeechWarm('call-1', 'D'); assert.equal(push.keepalives.size, 0);
});
