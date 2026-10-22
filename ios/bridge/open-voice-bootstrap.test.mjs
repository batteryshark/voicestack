import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { once } from 'node:events';
import crypto from 'node:crypto';
import http from 'node:http';
import { performance } from 'node:perf_hooks';
import { speechHealth, preparationSpeechState, PREPARATION_SPEECH } from './open-voice-speech.mjs';
import { main as outreachMain, openVoice, hostCapacity, SPEECHCTL, speechOwnerMapping, speechLaunchArguments, SPEECH_EXEC_WRAPPER } from './reachout.mjs';
import { readOpenVoiceConfig, startOpenVoiceBootstrap } from './open-voice-bootstrap.mjs';
import { createBridge } from './server.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { Maintenance } from './maintenance.mjs';
import { CONTROL_PROFILE } from './open-voice-control.mjs';

const authority = '8194f5d4-f05c-47b2-b61b-6d7b87aa4b9c';
const instance_id = '6b9fa76c-ed50-4750-b364-c84174b6ee75';
const runtime_version = '2.0.32';
const config = {
  version: 1, principal_id: 'fixture-owner', audience: 'fixture-bridge', device_id: 'fixture-phone', harnessRoot: '/synthetic/owned-host',
  target: { caller_id: 'fixture-caller', project_id: 'fixture-project', directory: '/synthetic/project', agent: 'build',
    model: { providerID: 'fixture', id: 'fixture', variant: 'default' } },
  speech: { sttURL: 'ws://127.0.0.1:1/v1/transcribe', ttsURL: 'http://127.0.0.1:1/v1/audio/speech', model: 'fixture-tts', voice: 'fixture-voice' },
};
function directory(t) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(path.resolve('output'), 'fv-bootstrap-'))); fs.chmodSync(dir, 0o700);
  t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir;
}
async function command(socketPath, input) {
  const socket = net.connect(socketPath); socket.on('error', () => {});
  await once(socket, 'connect'); let text = ''; socket.on('data', b => { text += b; });
  socket.write(JSON.stringify(input) + '\n'); await once(socket, 'close'); return JSON.parse(text);
}
test('owner config: bounded private no-follow file, exact fields and explicit model coordinates', t => {
  const dir = directory(t), file = path.join(dir, 'owner.json');
  const write = value => fs.writeFileSync(file, JSON.stringify(value), { mode: 0o600 });
  write(config); assert.deepEqual(readOpenVoiceConfig(file), config);
  fs.chmodSync(file, 0o644); assert.throws(() => readOpenVoiceConfig(file)); fs.chmodSync(file, 0o600);
  for (const model of [{ ...config.target.model, id: 'Auto' }, { providerID: 'fixture', id: 'fixture' }, { ...config.target.model, variant: 'Auto' }]) {
    write({ ...config, target: { ...config.target, model } }); assert.throws(() => readOpenVoiceConfig(file));
  }
  write({ ...config, module: './arbitrary.mjs' }); assert.throws(() => readOpenVoiceConfig(file));
  write(config); const link = path.join(dir, 'link.json'); fs.symlinkSync(file, link); assert.throws(() => readOpenVoiceConfig(link));
  fs.writeFileSync(file, 'x'.repeat(16385)); assert.throws(() => readOpenVoiceConfig(file));
});

async function fixture(t, overrides = {}, bootstrapOptions = {}) {
  const dir = directory(t), pushDir = path.join(dir, 'push'), sent = [];
  const device = { deviceID: config.device_id };
  const push = new PushService({ store: new PushStore(pushDir), activeDevices: () => [device], apns: async p => { sent.push(p); return { status: 200 }; } });
  push.update(device, 'settings', { callsEnabled: true, quietHoursEnabled: false, quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 });
  push.update(device, 'enrollment', { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64), environment: 'sandbox', build: 'fixture-build', revision: 1 });
  const maintenance = new Maintenance(pushDir); push.maintenance = maintenance;
  let prepares = 0, closed = false, sealed, prepared;
  const harness = {
    capability: async input => ({ instance_id, runtime_version, target_session: prepared?.target_session, authority: prepared?.authority, pins: input?.pins ?? prepared?.pins,
      modelAvailable: true, agentAvailable: true, providerConnected: true, outboundEnabled: true,
      singleUseAvailable: !!prepared, bindingVerified: !!sealed, ready: !!sealed, providerAcceptance: 'not_proven', reason: sealed ? 'local_configuration_available' : 'unprepared' }),
    prepare: async pins => { prepares++; assert.equal(prepares, 1); return prepared = { instance_id, runtime_version, target_session: 'ses_SYNTHETIC0027', authority, pins }; },
    providerSetup: async ({ pins }) => ({ instance_id, pins, modelAvailable: true, agentAvailable: true, providerConnected: true, outboundEnabled: true }),
    advanceUnused: async ({ binding, pins }) => {
      assert.deepEqual(binding, sealed); sealed = undefined; prepares++;
      return prepared = { instance_id, runtime_version, target_session: 'ses_nextfixture' + prepares, authority: crypto.randomUUID(), pins };
    },
    verify: async ({ binding }) => {
      if (sealed) assert.deepEqual(binding, sealed); else sealed = structuredClone(binding);
      assert.equal(Object.hasOwn(binding, 'claimed_call_id'), false);
      return { instance_id, runtime_version, target_session: binding.target_session, authority: prepared.authority, pins: binding.pins,
        exclusive: true, single_use: true, single_use_available: true, continuation: false };
    },
    submit: async () => { throw new Error('not used'); },
    stats: () => ({ childAlive: !closed, pendingRequests: 0, localWorkKnown: true, localWorkPending: false, localWorkRevision: 0 }),
    runtimeStats: async () => ({ closed, targets: prepared ? 1 : 0, operations: 0, pendingRequests: 0,
      localWorkKnown: true, localWorkPending: false, localWorkRevision: 0 }),
    close: async () => { closed = true; }, ...overrides,
  };
  const owner = await startOpenVoiceBootstrap({ config, push, startHarness: async () => harness, ...bootstrapOptions });
  const server = createBridge({ credentials: { device: () => device }, push, maintenance,
    openVoiceCandidate: owner.candidate, openVoiceMedia: owner.media, ownerStats: owner.stats,
    ocClient: { check: async () => {}, note() {} } });
  maintenance.refresh = owner.refresh;
  await owner.attach(push.openVoice);
  t.after(async () => { server.shutdown(); await owner.close(); });
  const control = push.openVoice;
  control.capability(device, { enabled: true, profile: CONTROL_PROFILE, build: 'fixture-build', expires_in: 300 });
  const socketPath = path.join(pushDir, 'open-voice-admin.sock');
  return { owner, harness, push, control, server, socketPath, sent, maintenance,
    command: input => command(socketPath, input), get prepares() { return prepares; }, get closed() { return closed; } };
}
test('production owner assembly exists while unready; protected status works under sealed hold', async t => {
  const f = await fixture(t);
  assert.equal(f.owner.media.adapter.readyForCalls, false);
  assert.equal(f.control.mediaAvailable(), false);
  assert.equal(f.server.listening, false);
  assert.equal((await f.command({ command: 'target-status' })).armed, false);
  await f.maintenance.command('hold');
  await f.maintenance.command('seal');
  assert.equal((await f.command({ command: 'target-status' })).armed, false);
  assert.equal(f.server.listening, false);
  assert.throws(() => f.control.configureMapping({ caller_id: config.target.caller_id, project_id: config.target.project_id,
    directory: config.target.directory, target_session: 'ses_arbitrary', binding_revision: 1, expires_at: Date.now() + 60000 }));
  assert.equal(f.sent.length, 0); assert.equal(f.prepares, 0);
});

// Only these three outreach cases are needed for the bounded control adaptation.
const readyHealth = { stt: true, tts: true };
async function outreachFixture(t, options = {}) {
  const f = await fixture(t, {}, { healthCheck: async () => readyHealth, ...options });
  await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 900000 } });
  await new Promise(resolve => f.server.listen(0, '127.0.0.1', resolve));
  return f;
}
const ringRequest = snapshot => ({ command: 'open-voice', action: 'ring', snapshot, operation_id: crypto.randomUUID(),
  port: 8794, reason: 'decision', summary: 'Synthetic fixture' });
test('outreach positive: actual health GETs and owner projection create no outreach authority or execution', async t => {
  const begin = performance.now(), peers = [], requests = [];
  const serve = async body => {
    const server = http.createServer((req, res) => { requests.push([req.method, req.url, req.headers.authorization]);
      res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(body)); });
    peers.push(server); await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); return server.address().port;
  };
  t.after(async () => { await Promise.all(peers.map(s => new Promise(resolve => s.close(resolve)))); });
  const sttBody = { status: 'ok', service: 'stt', model: 'parakeet-model-id', active_sessions: 0,
    partials: { enabled: true, slot_busy: false, error: null } };
  const ttsBody = { status: 'ok', service: 'tts', model: 'loaded', busy: false, queued: 0,
    upstream: { status: 'ok', http_status: 200, model: 'loaded', active_requests: 0 } };
  const sttPort = await serve(sttBody), ttsPort = await serve(ttsBody);
  const speech = { ...config.speech, sttURL: `ws://127.0.0.1:${sttPort}/v1/transcribe`, ttsURL: `http://127.0.0.1:${ttsPort}/v1/audio/speech` };
  const f = await outreachFixture(t, { config: { ...config, speech }, healthCheck: speechHealth });
  const before = structuredClone(f.control.state);
  const snapshot = await f.command({ command: 'readiness' });
  assert.equal(snapshot.ready, true); assert.equal(snapshot.providerAcceptance, 'not_proven');
  assert.equal(snapshot.expires_at, snapshot.checked_at + 10000);
  assert.match(snapshot.fingerprint, /^[a-f0-9]{64}$/); assert.deepEqual(f.control.state, before);
  assert.equal(f.prepares, 1); assert.equal(f.sent.length, 0); assert.equal(f.control.list().length, 0);
  assert.deepEqual(requests, [['GET', '/health', undefined], ['GET', '/health', undefined]]);
  for (const bad of [
    () => { sttBody.partials.slot_busy = true; },
    () => { sttBody.partials.slot_busy = false; ttsBody.upstream.model = 'loading'; },
    () => { ttsBody.upstream.model = 'loaded'; ttsBody.busy = true; },
    () => { ttsBody.busy = false; delete sttBody.active_sessions; },
  ]) { bad(); assert.equal((await f.command({ command: 'readiness' })).ready, false); }
  assert.equal(f.sent.length, 0); assert.equal(f.control.list().length, 0);
  console.log(`outreach positive fixture wall_ms=${(performance.now() - begin).toFixed(1)} (synthetic peers, not live latency)`);
});
test('outreach invalidation: expiry, identity/nonce/recipient change and late query cannot ring or rearm', async t => {
  let clock = Date.now(), resolveHealth;
  const f = await outreachFixture(t, { now: () => clock });
  const snapshot = await f.command({ command: 'readiness' }); assert.equal(snapshot.ready, true);
  let issues = 0, posts = 0;
  const admin = async input => { if (input.command === 'issue') issues++; return f.command(input); };
  const run = s => openVoice(ringRequest(s), { admin, now: () => clock, post: async () => { posts++; } });
  clock = snapshot.expires_at; assert.equal((await run(snapshot)).reason, 'expired'); clock = Date.now();
  const nonce = f.maintenance.nonce; f.maintenance.nonce = crypto.randomUUID();
  assert.equal((await run(snapshot)).reason, 'changed_or_expired'); f.maintenance.nonce = nonce;
  const device = f.push.device(config.device_id); device.settings.revision++;
  assert.equal((await run(snapshot)).reason, 'changed_or_expired'); device.settings.revision--;
  const capability = f.harness.capability;
  f.harness.capability = async input => ({ ...await capability(input), instance_id: crypto.randomUUID() });
  assert.equal((await run(snapshot)).reason, 'not_ready'); f.harness.capability = capability;
  const late = await outreachFixture(t, { now: () => clock, healthCheck: () => new Promise(resolve => { resolveHealth = resolve; }) });
  const query = late.command({ command: 'readiness' });
  // A separate status round-trip observes actual pending owner work, no time polling.
  await late.command({ command: 'target-status' });
  clock += 11000; resolveHealth(readyHealth);
  assert.equal((await query).reason, 'expired'); assert.equal(late.owner.stats().ownerWork, 0);
  let releaseStall;
  const stalled = await outreachFixture(t, { healthCheck: () => new Promise(resolve => { releaseStall = resolve; }) });
  const deadline = await stalled.command({ command: 'readiness' });
  assert.equal(deadline.reason, 'deadline'); assert.equal(stalled.owner.stats().ownerWork, 1);
  releaseStall(readyHealth); await stalled.command({ command: 'target-status' });
  assert.equal(stalled.owner.stats().ownerWork, 0); assert.equal(stalled.sent.length, 0);
  const mapping = f.control.state.mappings[f.control.mappingKey(config.target.caller_id, config.target.project_id)];
  mapping.claimed_call_id = crypto.randomUUID(); assert.equal((await f.command({ command: 'readiness' })).ready, false);
  assert.equal(issues, 0); assert.equal(posts, 0); assert.equal(f.sent.length, 0); assert.equal(late.sent.length, 0);
});
test('outreach explicit ring: one normal issue/HTTP POST, token memory-only, lost receipts never replay', async t => {
  const begin = performance.now(), f = await outreachFixture(t);
  const snapshot = await f.command({ command: 'readiness' });
  const request = ringRequest(snapshot), fixturePort = f.server.address().port;
  let issues = 0, fixturePosts = 0;
  const admin = async input => { if (input.command === 'issue') issues++; return f.command(input); };
  // Only injected fixture transport may address an ephemeral port; production is fixed at 8794.
  const fixturePost = async (_port, token, body) => {
    fixturePosts++;
    const response = await fetch(`http://127.0.0.1:${fixturePort}/floating-voice/voice/v1/calls`, {
      method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json', connection: 'close' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(4000) });
    return { status: response.status, body: await response.json() };
  };
  const args = ['open-voice', 'ring', '--snapshot', JSON.stringify(snapshot), '--operation-id', request.operation_id,
    '--reason', request.reason, '--summary', request.summary];
  await assert.rejects(outreachMain([...args, '--port', '8795'], { admin, post: fixturePost }), /unowned call destination/);
  assert.equal((await openVoice({ ...request, port: 8795 }, { admin, post: fixturePost })).reason, 'unowned_call_destination');
  assert.equal(issues, 0); assert.equal(fixturePosts, 0);
  const result = await outreachMain(args, { admin, post: fixturePost });
  await f.push.drain(); assert.equal(result.outcome, 'submitted'); assert.equal(issues, 1);
  assert.equal(fixturePosts, 1);
  assert.equal(f.sent.filter(x => x.voip).length, 1); assert.equal(f.control.list().length, 1);
  assert.equal(JSON.stringify(result).includes('token'), false);
  const grant = f.control.state.grants['v:' + result.grant_id]; assert.equal(grant.token, undefined);
  assert.deepEqual(grant.scopes, ['call:request', 'call:status:own']); assert.deepEqual(grant.project_ids, [config.target.project_id]);
  let calls = [], posts = 0;
  const fakeSnapshot = { ...snapshot, expires_at: Date.now() + 10000, mapping_expires_at: Date.now() + 900000 };
  const fakeAdmin = async input => { calls.push(input.command); if (input.command === 'readiness') return fakeSnapshot;
    if (input.command === 'issue') return { grant_id: crypto.randomUUID(), token: 'a'.repeat(43) }; return { revoked: true }; };
  const post = async () => { posts++; throw new Error('synthetic lost POST receipt'); };
  assert.equal((await openVoice(ringRequest(fakeSnapshot), { admin: fakeAdmin, post })).outcome, 'unknown');
  assert.deepEqual(calls, ['readiness', 'issue']); assert.equal(posts, 1);
  calls = []; posts = 0;
  const lostIssue = async input => { calls.push(input.command); if (input.command === 'readiness') return fakeSnapshot; throw new Error('lost issue'); };
  assert.equal((await openVoice(ringRequest(fakeSnapshot), { admin: lostIssue, post })).reason, 'issue_receipt_unknown');
  assert.deepEqual(calls, ['readiness', 'issue']); assert.equal(posts, 0);
  calls = [];
  await openVoice(ringRequest(fakeSnapshot), { admin: fakeAdmin, post: async () => ({ status: 409, body: { error: 'control_refused' } }) });
  assert.deepEqual(calls, ['readiness', 'issue', 'revoke']);
  calls = [];
  await openVoice(ringRequest(fakeSnapshot), { admin: async input => { calls.push(input.command); return { ready: false, reason: 'speech_unavailable' }; }, post });
  assert.deepEqual(calls, ['readiness']); assert.equal(posts, 0);
  console.log(`outreach explicit fixture wall_ms=${(performance.now() - begin).toFixed(1)} (synthetic call, not phone latency)`);
});
test('preparation owner target: prerequisites before allocation, release before speech, reuse and failure release', async t => {
  for (const failure of [false, true]) {
    const f = await fixture(t);
    f.maintenance.startListening = () => new Promise(resolve => f.server.listen(0, '127.0.0.1', resolve));
    if (failure) f.harness.providerSetup = async () => { throw Error('synthetic metadata unavailable'); };
    const r = await f.command({ command: 'prepare' });
    assert.equal(r.prepared, !failure); assert.equal(f.maintenance.held, false); assert.equal(f.server.listening, true);
    assert.equal(f.prepares, failure ? 0 : 1); assert.equal(f.sent.length, 0); assert.equal(f.control.list().length, 0);
    if (!failure) {
      assert.equal((await f.command({ command: 'prepare' })).prepared, true); assert.equal(f.prepares, 1);
      const r = await outreachMain(['open-voice', 'prepare'], { admin: f.command, ownerMapping: async () => true,
        admitHost: async () => true, runFixed: async () => { assert.equal(f.maintenance.held, false); throw Error('must not load invalid identity'); } });
      assert.equal(r.ready, false); assert.equal(f.maintenance.held, false); assert.equal(f.prepares, 1);
    }
  }
  const blocked = await fixture(t); await blocked.maintenance.command('hold');
  assert.equal((await blocked.command({ command: 'prepare' })).prepared, false);
  assert.equal(blocked.maintenance.held, true); assert.equal(blocked.prepares, 0); // Not our hold to release.
  const cap = await fixture(t); cap.control.state.capabilities['v:' + config.device_id].enabled = false;
  assert.equal((await cap.command({ command: 'prepare' })).prepared, false); assert.equal(cap.prepares, 0);
  let nativeHold = false;
  const held = await fixture(t, {}, { speechFactory: () => ({ stats: () => ({ stt: Number(nativeHold), tts: 0 }),
    openSegment() { assert.fail('no recognition'); }, submit() { assert.fail('no submit'); }, synthesize() { assert.fail('no synthesis'); } }),
    inspectSpeech: async () => ({ ready: false, loadable: true }) });
  held.maintenance.startListening = () => new Promise(resolve => held.server.listen(0, '127.0.0.1', resolve));
  assert.equal((await held.command({ command: 'prepare' })).prepared, true);
  nativeHold = true;
  assert.equal((await held.command({ command: 'speech-status' })).error, 'control_refused');
  nativeHold = false;
  assert.equal((await held.command({ command: 'speech-status' })).loadable, true);
  let clock = Date.now(), outbound = false, reconciles = 0;
  const advance = await fixture(t, {
    providerSetup: async ({ pins }) => ({ instance_id, pins, providerConnected: true, modelAvailable: true, agentAvailable: true, outboundEnabled: outbound }),
    reconcileProvider: async ({ pins }) => { reconciles++; outbound = true; return { instance_id, pins, reconciled: true, outboundEnabled: true }; },
  }, { now: () => clock });
  advance.maintenance.startListening = () => new Promise(resolve => advance.server.listen(0, '127.0.0.1', resolve));
  // Ordinary initial preparation reuses saved account metadata only when required.
  assert.equal((await advance.command({ command: 'prepare' })).prepared, true); assert.equal(reconciles, 1);
  clock += 900000;
  assert.equal((await advance.command({ command: 'prepare' })).prepared, true);
  assert.equal(advance.prepares, 2); assert.equal(reconciles, 1); assert.equal(advance.maintenance.held, false);
});
test('preparation deterministic CLI: cold once, loaded skip, denied/failed/timeout/unready no issue or POST', async () => {
  for (const mode of ['cold', 'loaded', 'host-denied', 'owner-denied', 'busy', 'load-failed', 'timeout', 'exit-zero-unready', 'expires']) {
    let clock = 1000, loads = 0, posts = 0; const commands = [];
    const ready = { ready: true, fingerprint: 'a'.repeat(64), checked_at: 50000, expires_at: 60000,
      mapping_expires_at: 900000, caller_id: 'fixture-caller', project_id: 'fixture-project', providerAcceptance: 'not_proven' };
    const admin = async input => {
      commands.push(input.command);
      if (input.command === 'prepare') return { prepared: true };
      if (input.command === 'speech-status') return mode === 'loaded' ? { ready: true } : { ready: false, loadable: mode !== 'busy' };
      if (input.command === 'readiness') return mode === 'exit-zero-unready' ? { ready: false } : ready;
      throw Error('must not issue');
    };
    const result = await outreachMain(['open-voice', 'prepare'], { admin, now: () => clock,
      admitHost: async () => mode !== 'host-denied', ownerMapping: async () => mode !== 'owner-denied',
      post: async () => { posts++; }, runFixed: async (file, args, ms) => {
        assert.equal(file, SPEECHCTL); assert.deepEqual(args, ['load', 'all']); assert.ok(ms > 0 && ms <= 145200); loads++;
        clock = mode === 'expires' ? 70000 : 50000; // Startup exceeds old short readiness lifetime.
        if (mode === 'timeout') throw Error('synthetic timeout');
        return { ok: mode !== 'load-failed' };
      } });
    assert.equal(result.ready, ['cold', 'loaded'].includes(mode), mode);
    assert.equal(loads, ['cold', 'load-failed', 'timeout', 'exit-zero-unready', 'expires'].includes(mode) ? 1 : 0, mode);
    assert.equal(posts, 0); assert.equal(commands.includes('issue'), false);
    if (mode === 'timeout') assert.equal(result.reason, 'load_outcome_unknown');
  }
  await assert.rejects(outreachMain(['open-voice', 'prepare', '--command', 'anything']));
});
test('preparation host and public speech schema: required identity, activity, cold omissions and genuine partial readiness', () => {
  assert.equal(hostCapacity('8\n', 'System-wide memory free percentage: 20%\n', 7.99), true);
  for (const args of [['8', 'System-wide memory free percentage: 19%', 0], ['8', 'System-wide memory free percentage: 99%', 8],
    [null, null, 0], ['8', 'unknown', 0]]) assert.equal(hostCapacity(...args), false);
  const p = PREPARATION_SPEECH;
  const cfg = { sttURL: 'ws://127.0.0.1:8446/v1/transcribe', ttsURL: 'http://127.0.0.1:8444/v1/audio/speech', model: p.ttsModel, voice: 'mizuki' };
  const stt = { status: 'ok', service: 'stt', backend: 'parakeet', model_id: p.sttModel, revision: p.sttRevision,
    model: 'unloaded', worker_pid: null, active_requests: 0, active_sessions: 0, partials: { enabled: true, ready: false, state: 'unloaded', error: 'stale cached' } };
  const tts = { status: 'ok', service: 'tts', backend: 'breeze-tts2-fast-streaming-api (mlx)', model_id: p.ttsModel, revision: p.ttsRevision,
    precision: 'mixed', default_voice: 'mizuki', voices: ['mizuki'], model: 'unloaded', busy: false, queued: 0,
    upstream: { status: 'ok', http_status: 200, service: 'breeze', model: 'unloaded', worker_pid: null, active_requests: 0 } };
  const bodies = { stt, tts }, state = () => preparationSpeechState(bodies, cfg);
  assert.equal(state().loadable, true); assert.equal(state().ready, false);
  for (const [obj, key, bad] of [[stt, 'model_id', undefined], [stt, 'revision', 'wrong'], [stt, 'active_sessions', undefined],
    [stt, 'active_requests', 1], [stt, 'worker_pid', 1], [tts, 'busy', true], [tts, 'queued', 1], [tts, 'default_voice', 'other'],
    [tts.upstream, 'active_requests', undefined], [tts.upstream, 'model', 'loading'], [tts.upstream, 'model_id', 'wrong']]) {
    const prior = obj[key]; obj[key] = bad; assert.equal(state().loadable, false, key); obj[key] = prior;
  }
  stt.model = tts.model = tts.upstream.model = 'loaded'; stt.worker_pid = 100; tts.upstream.worker_pid = 101;
  stt.precision = 'Q8_0'; stt.runtime = 'transcribe.cpp';
  stt.partials = { enabled: true, ready: true, state: 'loaded', error: null };
  assert.equal(state().ready, true); // Breeze identity fields legitimately absent, backed by separate owner mapping.
  stt.warmup = { matches_reference: false }; assert.equal(state().ready, true); // Diagnostic, not availability gate.
  stt.partials.ready = false; assert.equal(state().ready, false); assert.equal(state().loadable, false);
});
test('preparation deadline includes startup; lost fixed command wait is unknown and never retried', async () => {
  const started = performance.now(), gate = Promise.withResolvers(); let loads = 0, readiness = 0;
  const r = await outreachMain(['open-voice', 'prepare'], { budgetMs: 4900, ownerMapping: async () => true, admitHost: async () => true,
    admin: async ({ command }) => {
      if (command === 'prepare') return { prepared: true };
      if (command === 'speech-status') return { loadable: true, ready: false };
      readiness++; throw Error('must not reach readiness/issue');
    }, runFixed: async () => { loads++; return gate.promise; } });
  assert.equal(r.ready, false); assert.equal(r.reason, 'load_outcome_unknown'); assert.equal(loads, 1); assert.equal(readiness, 0);
  assert.ok(performance.now() - started < 2000); gate.resolve({ ok: true });
});
test('preparation ring still rechecks minimum authority lifetime after issue, without a POST', async () => {
  let clock = Date.now(), posts = 0, revoked = 0;
  const snapshot = { ready: true, fingerprint: 'a'.repeat(64), expires_at: clock + 10000, mapping_expires_at: clock + 180001 };
  const r = await openVoice(ringRequest(snapshot), { now: () => clock, post: async () => { posts++; }, admin: async input => {
    if (input.command === 'readiness') return snapshot;
    if (input.command === 'issue') { clock += 2; return { grant_id: crypto.randomUUID(), token: 'a'.repeat(43) }; }
    assert.equal(input.command, 'revoke'); revoked++; return { revoked: true };
  } });
  assert.equal(r.outcome, 'refused'); assert.equal(posts, 0); assert.equal(revoked, 1);
});
test('preparation running owner identity uses selective public argv, exact PID/UID/listener association, no env dump', async () => {
  const root = SPEECHCTL.slice(0, -'/scripts/speechctl'.length), p = PREPARATION_SPEECH;
  const args = {
    stt: [root + '/.venv/bin/python', root + '/speechd/idle_proxy.py', '--service', 'stt', '--host', '127.0.0.1', '--port', '8446', '--idle-unload-s', '900', '--',
      root + '/.venv/bin/python', '-m', 'speechd.stt_server', '--backend', 'parakeet', '--model-id', p.sttModel, '--revision', p.sttRevision, '--precision', 'Q8_0'],
    tts: [root + '/.venv/bin/python', '-m', 'speechd.tts_gateway', '--upstream', 'http://127.0.0.1:8450', '--host', '127.0.0.1', '--port', '8444',
      '--model-id', p.ttsModel, '--revision', p.ttsRevision, '--precision', 'mixed', '--default-voice', 'mizuki'],
    breeze: [root + '/.venv/bin/python', root + '/speechd/idle_proxy.py', '--service', 'breeze', '--host', '127.0.0.1', '--port', '8450', '--idle-unload-s', '900', '--',
      root + '/upstream/breeze-server/.venv/bin/python', '-m', 'breeze_infer.api', process.env.HOME + '/.cache/huggingface/hub/models--Shoof--Gust-MLX/snapshots/' + p.ttsRevision],
  };
  let bad = '';
  const read = async (file, argv) => {
    const names = ['stt', 'tts', 'breeze'];
    if (file === '/bin/launchctl') { assert.deepEqual(argv, ['list']); return names.map((n, i) => `${100 + i}\t0\tlocal.speechd.${n}`).join('\n'); }
    if (file.endsWith('PlistBuddy')) { assert.equal(argv[1], 'Print :ProgramArguments'); const n = names.find(n => argv[2].endsWith(n + '.plist')); return 'Array {\n' + args[n].join('\n') + '\n}'; }
    const port = argv.find(a => a.startsWith('-iTCP:'))?.slice(6);
    const pid = file.endsWith('lsof') ? ({ 8446: 100, 8444: 101, 8450: 102 }[port]) : Number(argv[argv.indexOf('-p') + 1]), n = names[pid - 100];
    if (file === '/bin/ps') return `${bad === 'uid' ? -1 : process.getuid()} ${args[n].join(' ')}${bad === 'argv' ? ' changed' : ''}`;
    if (file.endsWith('lsof')) return `p${pid}\nn${bad === 'listener' ? '*' : '127.0.0.1'}:${{ stt: 8446, tts: 8444, breeze: 8450 }[n]}\n`;
    throw Error('not an allowed observation');
  };
  assert.equal(await speechOwnerMapping({ read }), true);
  for (bad of ['uid', 'argv', 'listener']) assert.equal(await speechOwnerMapping({ read }), false);
});
test('preparation deployed wrapper and request aliases preserve exact inner pins and effective default identity', () => {
  const root = SPEECHCTL.slice(0, -'/scripts/speechctl'.length), p = PREPARATION_SPEECH;
  const inner = [root + '/.venv/bin/python', '-m', 'speechd.tts_gateway', '--upstream', 'http://127.0.0.1:8450',
    '--host', '127.0.0.1', '--port', '8444', '--model-id', p.ttsModel, '--revision', p.ttsRevision,
    '--precision', 'mixed', '--default-voice', 'mizuki'];
  const canonical = '/fixture/canonical/python', realpath = file => { assert.equal(file, inner[0]); return canonical; };
  const wrapped = [canonical, '-c', SPEECH_EXEC_WRAPPER, root, root + '/logs/tts.log', ...inner];
  assert.deepEqual(speechLaunchArguments('tts', wrapped, { realpath }), inner);
  for (const [i, value] of [[0, '/other/python'], [2, SPEECH_EXEC_WRAPPER + ';pass'], [3, '/other/cwd'], [4, '/other/log'],
    [wrapped.indexOf('--model-id') + 1, 'wrong-model'], [wrapped.indexOf('--default-voice') + 1, 'other-voice']]) {
    const bad = [...wrapped]; bad[i] = value; assert.equal(speechLaunchArguments('tts', bad, { realpath }), null);
  }
  const config = { sttURL: 'ws://127.0.0.1:8446/v1/transcribe', ttsURL: 'http://127.0.0.1:8444/v1/audio/speech', model: 'breeze-tts-2', voice: 'default' };
  const stt = { status: 'ok', service: 'stt', backend: 'parakeet', model_id: p.sttModel, revision: p.sttRevision,
    model: 'unloaded', worker_pid: null, active_requests: 0, active_sessions: 0, partials: { enabled: true, ready: false, state: 'unloaded', error: null } };
  const tts = { status: 'ok', service: 'tts', backend: 'breeze-tts2-fast-streaming-api (mlx)', model_id: p.ttsModel,
    revision: p.ttsRevision, precision: 'mixed', default_voice: 'mizuki', voices: ['mizuki', 'female_a'], model: 'unloaded', busy: false, queued: 0,
    upstream: { status: 'ok', service: 'breeze', http_status: 200, model: 'unloaded', worker_pid: null, active_requests: 0 } };
  assert.equal(preparationSpeechState({ stt, tts }, config).loadable, true);
  assert.equal(preparationSpeechState({ stt, tts }, { ...config, model: 'arbitrary-nonempty-request-label' }).loadable, true);
  for (const voice of [' default ', 'mizuki', 'original', 'female_a'])
    assert.equal(preparationSpeechState({ stt, tts }, { ...config, voice }).loadable, true);
  for (const bad of [{ ...config, model: '' }, { ...config, voice: 'unpublished' }, { ...config, voice: '   ' }, { ...config, voice: 'Default' }])
    assert.equal(preparationSpeechState({ stt, tts }, bad).loadable, false);
  tts.voices = ['mizuki']; assert.equal(preparationSpeechState({ stt, tts }, { ...config, voice: 'original' }).loadable, false);
  tts.default_voice = 'female_a'; assert.equal(preparationSpeechState({ stt, tts }, config).loadable, false);
  tts.default_voice = 'mizuki'; tts.model_id = 'breeze-tts-2';
  assert.equal(preparationSpeechState({ stt, tts }, config).loadable, false); // Request alias is NOT health identity.
});
test('unused advance owner boundary preserves terminal history and fences authority, work, races and lost receipt', async t => {
  const f = await fixture(t);
  await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 60000 } });
  const mapping = () => f.control.state.mappings[f.control.mappingKey(config.target.caller_id, config.target.project_id)];
  const old = structuredClone(mapping()), callID = crypto.randomUUID();
  const grant = f.control.issue({ caller_id: old.caller_id, project_ids: [old.project_id], scopes: ['call:request'], expires_at: old.expires_at });
  const call = { id: callID, binding: structuredClone(old), grant_id: grant.grant_id, state: 'rejected', media_epoch: 2, operations: {} };
  f.control.state.calls['v:' + callID] = call; mapping().claimed_call_id = callID; f.control.save();
  const value = { target_id: old.target_id, target_session: old.target_session, binding_revision: 1, next_binding_revision: 2, expires_at: Date.now() + 60000 };
  const advance = input => f.command({ command: 'advance-unused-target', value: input ?? value });
  assert.equal((await advance()).error, 'control_refused'); // Not held/quiet.
  await f.maintenance.command('hold'); await f.maintenance.command('seal');
  assert.equal((await advance()).error, 'control_refused'); // Every effective matching grant, not just the pilot ID.
  f.control.revoke(grant.grant_id);
  const other = f.control.issue({ caller_id: old.caller_id, project_ids: [old.project_id], scopes: ['call:request'], expires_at: old.expires_at });
  assert.equal((await advance()).error, 'control_refused'); f.control.revoke(other.grant_id);
  assert.equal((await advance({ ...value, next_binding_revision: 1 })).error, 'control_refused');
  assert.equal((await advance({ ...value, target_id: crypto.randomUUID() })).error, 'control_refused');
  call.state = 'accepted'; assert.equal((await advance()).error, 'control_refused'); f.control.stop(call, 'rejected');
  call.lease = {}; assert.equal((await advance()).error, 'control_refused'); delete call.lease;
  const stats = f.harness.stats, runtimeStats = f.harness.runtimeStats;
  f.harness.stats = () => ({ ...stats(), localWorkKnown: false, localWorkPending: true });
  f.harness.runtimeStats = async () => ({ ...await runtimeStats(), localWorkKnown: false, localWorkPending: true });
  assert.equal((await advance()).error, 'control_refused');
  f.harness.stats = stats; f.harness.runtimeStats = runtimeStats;
  const history = structuredClone(call), revocations = structuredClone(f.control.state.grants);
  const entered = Promise.withResolvers(), released = Promise.withResolvers(), nativeAdvance = f.harness.advanceUnused;
  f.harness.advanceUnused = async input => { entered.resolve(); await released.promise; return nativeAdvance(input); };
  const pending = advance(); await entered.promise;
  assert.equal(f.owner.stats().ownerWork, 1);
  for (const command of ['issue', 'configure-mapping', 'prepare-target', 'advance-unused-target'])
    assert.equal((await f.command({ command, value: {} })).error, 'control_refused');
  await assert.rejects(f.maintenance.command('release')); await assert.rejects(f.owner.close());
  released.resolve(); const result = await pending;
  assert.equal(result.armed, true); assert.equal(result.binding_revision, 2); assert.equal(f.prepares, 2);
  assert.notEqual(result.target_session, old.target_session); assert.notEqual(result.target_id, old.target_id);
  assert.notEqual(mapping().authority, old.authority);
  assert.deepEqual(call, history); assert.deepEqual(f.control.state.grants, revocations); assert.equal(f.sent.length, 0);
  assert.equal((await advance()).error, 'control_refused');
  const next = mapping();
  const nextValue = { ...value, target_id: next.target_id, target_session: next.target_session, binding_revision: 2, next_binding_revision: 3 };
  assert.equal((await advance(nextValue)).error, 'control_refused'); // Never silently retire an unclaimed prepared target.
  assert.equal(f.prepares, 2);
  next.claimed_call_id = callID; // A terminal claim for a DIFFERENT binding is not proof.
  assert.equal((await advance(nextValue)).error, 'control_refused'); assert.equal(f.prepares, 2);
  const nextBinding = f.control.binding(next), nextCallID = crypto.randomUUID();
  const nextCall = { id: nextCallID, binding: structuredClone(nextBinding), state: 'rejected', media_epoch: 2, operations: {} };
  f.control.state.calls['v:' + nextCallID] = nextCall; next.claimed_call_id = nextCallID; f.control.save();
  const nextHistory = structuredClone(nextCall);
  const third = await advance(nextValue);
  assert.equal(third.armed, true); assert.equal(third.binding_revision, 3); assert.equal(f.prepares, 3);
  assert.equal(new Set([old.target_session, next.target_session, third.target_session]).size, 3);
  assert.equal(new Set([old.target_id, next.target_id, third.target_id]).size, 3);
  assert.equal(new Set([old.authority, next.authority, mapping().authority]).size, 3);
  assert.deepEqual(call, history); assert.deepEqual(nextCall, nextHistory); assert.deepEqual(f.control.state.grants, revocations);
  for (const prior of [value, nextValue]) assert.equal((await advance(prior)).error, 'control_refused');
  assert.equal(f.prepares, 3); assert.equal(f.sent.length, 0);
  const lost = await fixture(t);
  await lost.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 60000 } });
  const before = structuredClone(lost.control.state.mappings[lost.control.mappingKey(config.target.caller_id, config.target.project_id)]);
  const lostCallID = crypto.randomUUID();
  lost.control.state.calls['v:' + lostCallID] = { id: lostCallID, binding: structuredClone(before), state: 'rejected', media_epoch: 2, operations: {} };
  lost.control.state.mappings[lost.control.mappingKey(config.target.caller_id, config.target.project_id)].claimed_call_id = lostCallID;
  lost.control.save();
  await lost.maintenance.command('hold'); await lost.maintenance.command('seal');
  const create = lost.harness.advanceUnused;
  lost.harness.advanceUnused = async input => { await create(input); throw Error('synthetic_lost_advance_reply'); };
  const request = { command: 'advance-unused-target', value: { ...value, target_id: before.target_id, target_session: before.target_session } };
  assert.equal((await lost.command(request)).error, 'control_refused');
  assert.equal((await lost.command(request)).error, 'control_refused'); assert.equal(lost.prepares, 2);
  assert.deepEqual(lost.control.state.mappings[lost.control.mappingKey(config.target.caller_id, config.target.project_id)], { ...before, claimed_call_id: lostCallID });
});
test('expired unclaimed advance requires absolute expiry, no related work/grants and stable CAS across awaits', async t => {
  let clock = Date.now();
  const f = await fixture(t, {}, { now: () => clock });
  const expiry = clock + 60000;
  await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: expiry } });
  const mapping = () => f.control.state.mappings[f.control.mappingKey(config.target.caller_id, config.target.project_id)];
  const old = structuredClone(mapping());
  const request = { command: 'advance-unused-target', value: { target_id: old.target_id, target_session: old.target_session,
    binding_revision: 1, next_binding_revision: 2, expires_at: Date.now() + 900000 } };
  await f.maintenance.command('hold'); await f.maintenance.command('seal');
  const refuse = async () => { assert.equal((await f.command(request)).error, 'control_refused'); assert.equal(f.prepares, 1); };
  await refuse(); // Live unclaimed is NOT eligible.
  clock = expiry; // Absolute expiry, not a near-expiry threshold.
  const g = f.control.issue({ caller_id: old.caller_id, project_ids: [old.project_id], scopes: ['call:status:own'], expires_at: expiry });
  await refuse(); f.control.revoke(g.grant_id);
  for (const claim of [null, '', crypto.randomUUID()]) {
    mapping().claimed_call_id = claim; await refuse(); delete mapping().claimed_call_id;
  }
  for (const field of ['target_id', 'target_session', 'authority']) {
    const id = crypto.randomUUID();
    f.control.state.calls['v:' + id] = { id, binding: { [field]: old[field] }, state: 'ended', operations: {} };
    await refuse(); delete f.control.state.calls['v:' + id];
  }
  const stats = f.harness.stats;
  f.harness.stats = () => ({ ...stats(), localWorkKnown: false }); await refuse(); f.harness.stats = stats;
  const setup = f.harness.providerSetup;
  for (const mutate of [() => { clock = expiry - 1; }, () => { mapping().claimed_call_id = crypto.randomUUID(); },
    () => { mapping().target_id = crypto.randomUUID(); }, () => { f.maintenance.held = false; }]) {
    f.harness.providerSetup = async input => { const result = await setup(input); mutate(); return result; };
    await refuse(); clock = expiry; Object.assign(mapping(), old); delete mapping().claimed_call_id; f.maintenance.held = true;
  }
  f.harness.providerSetup = setup;
  const grants = structuredClone(f.control.state.grants), calls = structuredClone(f.control.state.calls);
  const result = await f.command(request);
  assert.equal(result.armed, true); assert.equal(result.binding_revision, 2); assert.equal(f.prepares, 2);
  assert.notEqual(mapping().target_id, old.target_id); assert.notEqual(mapping().target_session, old.target_session);
  assert.notEqual(mapping().authority, old.authority);
  assert.deepEqual(f.control.state.grants, grants); assert.deepEqual(f.control.state.calls, calls);
  assert.equal((await f.command(request)).error, 'control_refused'); assert.equal(f.prepares, 2); assert.equal(f.sent.length, 0);
});
test('unused advance recognizes only a normal inert End and preserves its history', async t => {
  const f = await fixture(t), expiry = Date.now() + 120000;
  await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: expiry } });
  // Reconstruct the predecessor ordinary no-hook creation, NOT marker deletion/backfill.
  const trustedHook = f.control.endNote; f.control.endNote = undefined;
  const grant = f.control.issue({ caller_id: config.target.caller_id, project_ids: [config.target.project_id], scopes: ['call:request'], expires_at: expiry });
  const call = await f.control.request({ token: grant.token, body: { operation_id: crypto.randomUUID(), project_id: config.target.project_id,
    reason: 'decision', summary: 'Synthetic normal End fixture', expires_in: 60 } });
  await f.push.drain();
  const c = f.control.state.calls['v:' + call.call_id], binding = structuredClone(c.binding);
  const owner = { call_uuid: c.call_uuid, owner_epoch: c.owner_epoch, binding_revision: binding.binding_revision, target_id: binding.target_id };
  await f.control.act({ deviceID: config.device_id }, c.id, 'accept', owner);
  const endID = crypto.randomUUID();
  const end = await f.control.act({ deviceID: config.device_id }, c.id, 'end', { ...owner, operation_id: endID, reason: 'deliberate-user' });
  assert.equal(end.kind, 'end'); assert.equal(end.state, 'prepared'); assert.equal(c.state, 'ended');
  assert.equal(c.end_operation, endID); assert.equal(c.exchange_operation, undefined);
  assert.equal(f.control.endNote, undefined); assert.equal(f.push.localStats().endNotes, 0);
  f.control.endNote = trustedHook;
  const replay = await f.control.act({ deviceID: config.device_id }, c.id, 'end', { ...owner, operation_id: endID, reason: 'deliberate-user' });
  assert.deepEqual(replay, end); assert.equal(Object.hasOwn(c, 'end_note_version'), false);
  assert.deepEqual(Object.keys(end).sort(), ['hash', 'kind', 'operation_id', 'state']);
  f.control.revoke(grant.grant_id);
  await f.maintenance.command('hold'); await f.maintenance.command('seal');
  const request = { command: 'advance-unused-target', value: { target_id: binding.target_id, target_session: binding.target_session,
    binding_revision: 1, next_binding_revision: 2, expires_at: expiry } };
  const key = 'v:' + endID, history = structuredClone(c), revoked = structuredClone(f.control.state.grants);
  const refuse = async change => {
    const restore = change();
    try { assert.equal((await f.command(request)).error, 'control_refused'); assert.equal(f.prepares, 1); }
    finally { restore(); }
  };
  await refuse(() => { f.control.endNote = async () => { throw Error('must never dispatch'); }; return () => { f.control.endNote = trustedHook; }; });
  await refuse(() => { c.end_note_version = 1; return () => { delete c.end_note_version; }; });
  await refuse(() => { f.control.pendingEndNotes = 1; return () => { f.control.pendingEndNotes = 0; }; });
  for (const state of ['dispatching', 'uncertain', 'completed']) await refuse(() => {
    c.operations[key] = { ...end, state }; return () => { c.operations[key] = end; };
  });
  for (const malformed of [{ ...end, kind: 'exchange' }, { ...end, operation_id: 'not-a-uuid' }, { ...end, hash: 'not-a-hash' },
    { ...end, admission_inbox_id: null }]) await refuse(() => { c.operations[key] = malformed; return () => { c.operations[key] = end; }; });
  await refuse(() => { c.end_operation = crypto.randomUUID(); return () => { c.end_operation = endID; }; });
  await refuse(() => { c.operations['v:extra'] = { ...end }; return () => { delete c.operations['v:extra']; }; });
  assert.deepEqual(c, history);
  const result = await f.command(request);
  assert.equal(result.armed, true); assert.notEqual(result.target_session, binding.target_session); assert.equal(f.prepares, 2);
  assert.deepEqual(c, history); assert.deepEqual(f.control.state.grants, revoked);
  assert.equal(c.end_operation, endID); assert.deepEqual(c.operations[key], end);
  assert.equal(f.control.endNote, trustedHook); assert.equal(f.push.localStats().endNotes, 0);
});
for (const mode of ['success', 'lost-receipt', 'revoked', 'changed-target', 'stale-epoch', 'transport']) test(`future terminal End policy: ${mode}`, async t => {
  const notes = [];
  const f = await fixture(t, { appendEnd: async payload => {
    notes.push(payload);
    if (mode === 'lost-receipt') throw Error('lost');
    return { target_session: payload.binding.target_session, message_id: 'msg_fixture' };
  } });
  const expiry = Date.now() + 120000;
  await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: expiry } });
  const grant = f.control.issue({ caller_id: config.target.caller_id, project_ids: [config.target.project_id], scopes: ['call:request'], expires_at: expiry });
  const call = await f.control.request({ token: grant.token, body: { operation_id: crypto.randomUUID(), project_id: config.target.project_id,
    reason: 'decision', summary: 'Synthetic End', expires_in: 60 } });
  await f.push.drain();
  const c = f.control.state.calls['v:' + call.call_id];
  assert.equal(c.end_note_version, 1);
  const owner = { call_uuid: c.call_uuid, owner_epoch: c.owner_epoch, binding_revision: c.binding.binding_revision, target_id: c.binding.target_id };
  await f.control.act({ deviceID: config.device_id }, c.id, 'accept', owner);
  await assert.rejects(f.control.act({ deviceID: config.device_id }, c.id, 'end', { ...owner, owner_epoch: crypto.randomUUID(), operation_id: crypto.randomUUID(), reason: 'deliberate-user' }));
  assert.equal(notes.length, 0);
  if (mode === 'transport') { f.control.stop(c, 'ended'); await new Promise(r => setImmediate(r)); assert.equal(notes.length, 0); return; }
  const verify = f.harness.verify;
  f.harness.verify = async input => {
    const result = await verify(input);
    if (mode === 'revoked') f.control.revoke(grant.grant_id);
    if (mode === 'stale-epoch') c.owner_epoch = crypto.randomUUID();
    if (mode === 'changed-target') f.control.state.mappings[f.control.mappingKey(config.target.caller_id, config.target.project_id)].target_id = crypto.randomUUID();
    // Consumed single-use slot is not admission authority and must not block End.
    return { ...result, single_use_available: false, continuation: true };
  };
  const operation_id = crypto.randomUUID(), value = { ...owner, operation_id, reason: 'deliberate-user' };
  await f.control.act({ deviceID: config.device_id }, c.id, 'end', value);
  while (f.control.pendingEndNotes) await new Promise(r => setImmediate(r));
  const op = c.operations['v:' + operation_id];
  const expected = ['success', 'lost-receipt'].includes(mode) ? 1 : 0;
  assert.equal(notes.length, expected);
  assert.equal(op.state, mode === 'success' ? 'completed' : mode === 'lost-receipt' ? 'uncertain' : 'prepared');
  if (expected) {
    assert.deepEqual(notes[0].binding, c.binding); assert.equal(notes[0].owner_epoch, c.owner_epoch);
    assert.equal(notes[0].role, 'system'); assert.equal(notes[0].text, '[voice] ended'); assert.equal(notes[0].assistant_response, false);
  }
  if (mode === 'stale-epoch') await assert.rejects(f.control.act({ deviceID: config.device_id }, c.id, 'end', value));
  else await f.control.act({ deviceID: config.device_id }, c.id, 'end', value);
  assert.equal(notes.length, expected); assert.equal(c.lease, undefined);
});
test('owner preparation is single-attempt, outside push serial, and seals actual generated binding', async t => {
  const f = await fixture(t);
  const result = await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 60000 } });
  assert.equal(result.prepared, true); assert.equal(result.target_session, 'ses_SYNTHETIC0027');
  assert.equal(result.armed, true); assert.equal(f.control.mediaAvailable(), true);
  assert.equal(f.prepares, 1);
  const mapping = f.control.state.mappings[f.control.mappingKey(config.target.caller_id, config.target.project_id)];
  assert.equal(mapping.authority, authority); assert.deepEqual(mapping.pins.model, config.target.model);
  assert.ok(mapping.target_id);
  assert.equal((await f.command({ command: 'prepare-target', value: { binding_revision: 2, expires_at: Date.now() + 60000 } })).error, 'control_refused');
  assert.equal(f.prepares, 1);
});
test('actual-shape provider-unready preflight creates nothing, never admits media or sends APNs', async t => {
  const f = await fixture(t, { capability: async ({ pins } = {}) => ({ instance_id, runtime_version, pins,
    modelAvailable: false, agentAvailable: true, providerConnected: false, outboundEnabled: false,
    bindingVerified: false, singleUseAvailable: false, ready: false, providerAcceptance: 'not_proven', reason: 'unprepared' }) });
  const response = await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 60000 } });
  assert.equal(response.error, 'control_refused'); assert.equal(f.prepares, 0);
  assert.equal(Object.keys(f.control.state.mappings).length, 0);
  assert.equal((await f.command({ command: 'target-status' })).attempted, false);
  assert.equal(f.control.mediaAvailable(), false);
  await assert.rejects(f.control.attach('x'.repeat(43)));
  await assert.rejects(f.control.request({ token: 'x'.repeat(43), body: { operation_id: crypto.randomUUID(), project_id: config.target.project_id,
    reason: 'decision', summary: 'Synthetic fixture', expires_in: 60 } }));
  assert.equal(f.sent.length, 0); assert.equal(f.server.openVoiceStats().sessions, 0);
});
test('actual-shape preflight ignores composite readiness; arm then ring/attach on same assembly without restart', async t => {
  const f = await fixture(t);
  const expiry = Date.now() + 120000;
  assert.equal(f.control.mediaAvailable(), false);
  const result = await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: expiry } });
  assert.equal(result.armed, true); // Fake private hook has real-shaped capability; no production override.
  const grant = await f.command({ command: 'issue', value: { caller_id: config.target.caller_id, project_ids: [config.target.project_id],
    scopes: ['call:request', 'call:status:own'], expires_at: expiry } });
  assert.ok(grant.token);
  const body = { operation_id: crypto.randomUUID(), project_id: config.target.project_id, reason: 'decision', summary: 'Synthetic fixture', expires_in: 60 };
  const call = await f.control.request({ token: grant.token, body }); await f.push.drain();
  assert.equal(f.sent.filter(x => x.voip).length, 1);
  const stored = f.control.state.calls['v:' + call.call_id];
  const owner = { call_uuid: stored.call_uuid, owner_epoch: stored.owner_epoch, binding_revision: stored.binding.binding_revision, target_id: stored.binding.target_id };
  await f.control.act({ deviceID: config.device_id }, call.call_id, 'accept', owner);
  const media = await f.control.act({ deviceID: config.device_id }, call.call_id, 'media', owner);
  const attachment = await f.control.attach(media.media_lease);
  assert.equal(attachment.binding.target_session, result.target_session);
  assert.equal(Object.keys(attachment.binding).length, 12);
  assert.equal(Object.hasOwn(attachment.binding, 'claimed_call_id'), false);
  await assert.rejects(f.control.request({ token: grant.token, body: { ...body, operation_id: crypto.randomUUID() } }), { status: 409 });
  assert.equal(f.control.mediaAvailable(), true); // Consumed target is not a revocation of this reply.
  assert.equal((await f.control.request({ token: grant.token, body })).call_id, call.call_id);
});
test('failed owner preparation never retries and pending work blocks maintenance seal', async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const f = await fixture(t, { prepare: async () => { await held; throw new Error('uncertain'); } });
  const result = f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: Date.now() + 60000 } });
  // Observe the admitted callback through the existing socket, not a sleep race.
  while (!(await f.command({ command: 'target-status' })).attempted) { /* one bounded owner callback */ }
  assert.ok(f.owner.stats().ownerWork > 0);
  await f.maintenance.command('hold'); await assert.rejects(f.maintenance.command('seal'), { status: 409 });
  await f.push.serial(() => {}); // A held prepare does not hold receipt/end transitions.
  release(); assert.equal((await result).error, 'control_refused');
  assert.equal((await f.command({ command: 'prepare-target', value: { binding_revision: 2, expires_at: Date.now() + 60000 } })).error, 'control_refused');
  assert.equal(f.owner.media.adapter.readyForCalls, false);
});
test('consumed hook slot permits only exact current-call replacement media, never a second submission', async t => {
  const f = await fixture(t), expiry = Date.now() + 120000;
  let consumed = false, submissions = 0;
  const capability = f.harness.capability;
  f.harness.capability = async input => ({ ...await capability(input), ...(consumed ? { singleUseAvailable: false, ready: false } : {}) });
  const verify = f.harness.verify;
  f.harness.verify = async input => ({ ...await verify(input), continuation: consumed, single_use_available: !consumed });
  f.harness.submit = async input => {
    submissions++; consumed = true;
    return { admission_inbox_id: input.planned_inbox_id, source_user_id: input.planned_inbox_id,
      source_assistant_id: 'msg_SYNTHETIC0014', text: 'Synthetic verified final.' };
  };
  assert.equal((await f.command({ command: 'prepare-target', value: { binding_revision: 1, expires_at: expiry } })).armed, true);
  const grant = await f.command({ command: 'issue', value: { caller_id: config.target.caller_id, project_ids: [config.target.project_id], scopes: ['call:request'], expires_at: expiry } });
  const body = { operation_id: crypto.randomUUID(), project_id: config.target.project_id, reason: 'decision', summary: 'Synthetic fixture', expires_in: 60 };
  const call = await f.control.request({ token: grant.token, body }); await f.push.drain();
  const c = f.control.state.calls['v:' + call.call_id], device = { deviceID: config.device_id };
  const owner = { call_uuid: c.call_uuid, owner_epoch: c.owner_epoch, binding_revision: c.binding.binding_revision, target_id: c.binding.target_id };
  await f.control.act(device, c.id, 'accept', owner);
  const lease = await f.control.act(device, c.id, 'media', owner), first = await f.control.attach(lease.media_lease);
  const operation_id = crypto.randomUUID(), item = { id: 'item_fixture', type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Synthetic input' }] };
  const op = await f.control.prepare(c.id, first.media_epoch, operation_id, item);
  await f.control.dispatch(c.id, first.media_epoch, operation_id);
  const input = { call_id: c.id, binding: first.binding, operation_id, planned_inbox_id: op.planned_inbox_id, item };
  await assert.rejects(f.owner.media.adapter.submit({ ...input, call_id: crypto.randomUUID() }), { status: 409 });
  const result = await f.owner.media.adapter.submit(input);
  f.control.result(c.id, operation_id, { state: 'completed', admission_inbox_id: result.admission_inbox_id,
    source_user_id: result.source_user_id, source_assistant_id: result.source_assistant_id });
  assert.equal((await f.harness.capability()).singleUseAvailable, false);
  const replacement = await f.control.act(device, c.id, 'media', owner);
  const attached = await f.control.attach(replacement.media_lease);
  assert.ok(attached.media_epoch > first.media_epoch); assert.deepEqual(attached.binding, first.binding);
  assert.equal(f.owner.media.adapter.readyForCalls, true);
  await assert.rejects(f.control.attach(lease.media_lease));
  await assert.rejects(f.owner.candidate.resolveTarget({ ...attached.binding, directory: '/changed' }), { status: 409 });
  await assert.rejects(f.control.prepare(c.id, attached.media_epoch, crypto.randomUUID(), item), { status: 409 });
  await assert.rejects(f.owner.media.adapter.submit(input), { status: 409 });
  await assert.rejects(f.control.request({ token: grant.token, body: { ...body, operation_id: crypto.randomUUID() } }), { status: 409 });
  assert.equal(submissions, 1); assert.equal(f.owner.media.adapter.readyForCalls, true);
});
test('RPC zero does not clear SDK busy/unknown: seal and close refuse until actual known idle', async t => {
  let known = true, busy = true, revision = 1, closed = false, closes = 0, failQuery = false;
  const stats = () => ({ childAlive: !closed, pendingRequests: 0, localWorkKnown: known, localWorkPending: busy, localWorkRevision: revision });
  const f = await fixture(t, { stats, runtimeStats: async () => {
    if (failQuery) throw new Error('query failed');
    return { closed, targets: 1, operations: 1, pendingRequests: 0, ...stats() };
  }, close: async () => { closes++; closed = true; } });
  await f.maintenance.command('hold');
  assert.equal((await f.maintenance.command('status')).counts.SDKWork, 1);
  await assert.rejects(f.maintenance.command('seal'), { status: 409 });
  await assert.rejects(f.owner.close(), { status: 409 }); assert.equal(closes, 0);
  known = false; busy = false; revision++;
  assert.equal((await f.command({ command: 'target-status' })).SDKWork, 1);
  await assert.rejects(f.maintenance.command('seal'), { status: 409 });
  await assert.rejects(f.owner.close(), { status: 409 }); assert.equal(closes, 0);
  known = true; failQuery = true; revision++;
  assert.equal((await f.maintenance.command('status')).counts.SDKWork, 1); // Failed query cannot reuse cached zero.
  await assert.rejects(f.owner.close(), { status: 409 }); assert.equal(closes, 0);
  failQuery = false; revision++;
  const quiet = await f.maintenance.command('seal');
  assert.equal(quiet.counts.SDKWork, 0); assert.equal(quiet.localQuiet, true);
  await f.owner.close(); assert.equal(closes, 1);
});
test('provider owner commands use configured pins and the same child, only on explicit request', async t => {
  const calls = [];
  const f = await fixture(t, {
    providerSetup: async input => { calls.push(['setup', input]); return { instance_id, pins: input.pins, providerID: 'fixture', integrationID: 'fixture', methods: [] }; },
    reconcileProvider: async input => { calls.push(['reconcile', input]); return { instance_id, pins: input.pins, reconciled: true, outboundEnabled: true, providerAcceptance: 'not_proven' }; },
    beginSignIn: async input => { calls.push(['begin', input]); return { instance_id, attemptID: 'fixture-attempt', url: 'https://example.invalid/device', instructions: 'Synthetic owner instructions', mode: 'auto', time: {} }; },
    signInStatus: async () => { calls.push(['status']); return { instance_id, status: 'pending', time: {} }; },
  });
  assert.deepEqual(calls, []); assert.equal(f.prepares, 0);
  assert.equal((await f.command({ command: 'provider-setup' })).providerID, 'fixture');
  assert.equal((await f.command({ command: 'reconcile-provider' })).reconciled, true);
  assert.equal((await f.command({ command: 'reconcile-provider', value: { pins: {} } })).error, 'control_refused');
  assert.equal((await f.command({ command: 'begin-sign-in' })).attemptID, 'fixture-attempt');
  assert.equal((await f.command({ command: 'sign-in-status' })).status, 'pending');
  assert.equal((await f.command({ command: 'begin-sign-in' })).error, 'control_refused');
  assert.equal((await f.command({ command: 'provider-setup', value: { pins: { model: 'caller override' } } })).error, 'control_refused');
  const pins = { directory: config.target.directory, agent: config.target.agent, model: config.target.model };
  assert.deepEqual(calls, [['setup', { pins }], ['reconcile', { pins }], ['begin', { pins }], ['status']]);
  assert.equal(f.prepares, 0); assert.equal(f.sent.length, 0);
});
