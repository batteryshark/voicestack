import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import crypto from 'node:crypto';
import { once } from 'node:events';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { CONFIG } from './reachout-policy.mjs';
import { OpenVoiceControl, CONTROL_PREFIX } from './open-voice-control.mjs';
import { startOpenVoiceAdmin } from './open-voice-admin.mjs';
import { createBridge } from './server.mjs';
const v = JSON.parse(fs.readFileSync(new URL('./fixtures/open-voice/control-vectors.json', import.meta.url)));
const clone = x => structuredClone(x);
const opID = () => crypto.randomUUID();
const freshAuthority = 'd483606c-9040-49ca-8570-ed5f767c5e53';
const freshPins = { directory: '/synthetic/project', agent: 'build', model: { providerID: 'fixture', id: 'fixture', variant: 'default' } };
function fixture(t, extra = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-control-')); fs.chmodSync(root, 0o700);
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let now = Date.parse('2026-10-19T17:00:00Z'), devices = [{ deviceID: 'fixture-phone' }], resolver = b => ({ ...b, authenticated: true, paired: true, available: true, idle: true });
  const sent = [], closed = [], notes = [], device = devices[0];
  const credentials = { device: auth => { assert.equal(auth, 'Bearer fixture-device-token'); return device; } };
  const options = { store: new PushStore(root), apns: async x => { sent.push(x); return { status: 200 }; },
    chief: () => 'ses_SYNTHETIC0028', activeDevices: () => devices, now: () => now, config: CONFIG };
  const push = new PushService(options);
  push.update(device, 'settings', { callsEnabled: true, quietHoursEnabled: true, quietStart: '22:00', quietEnd: '09:00', timeZone: 'UTC', policyVersion: 1, revision: 1 });
  push.update(device, 'enrollment', { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64), environment: 'sandbox', build: v.capability.build, revision: 1 });
  const config = { enabled: true, push, principal_id: 'fixture-principal', audience: 'fixture-bridge', device_id: device.deviceID,
    mediaAvailable: () => true, // Explicit isolated fake-media capability, never a caller field.
    authenticateDevice: credentials.device, resolveTarget: b => resolver(b), closeOwner: x => closed.push(x), now: () => now,
    endNote: async x => notes.push(x), ...extra };
  const control = new OpenVoiceControl(config);
  control.configureMapping(v.mapping); const grant = control.issue(v.grant); control.capability(device, v.capability);
  const request = (body = v.request) => push.requestOpenVoice(control, { token: grant.token, body });
  const owner = c => Object.fromEntries(['call_uuid', 'owner_epoch', 'binding_revision', 'target_id'].map(k => [k, c[k]]));
  const invite = async body => { const c = await request(body); await push.drain(); return control.recipient(device, c.call_id); };
  const accepted = async body => { const c = await invite(body); await control.act(device, c.call_id, 'accept', owner(c)); return c; };
  const media = async body => { const c = await accepted(body), lease = await control.act(device, c.call_id, 'media', owner(c));
    const attachment = await control.attach(lease.media_lease); return { c, lease, epoch: attachment.media_epoch }; };
  return { root, config, options, credentials, control, push, device, grant, request, invite, accepted, media, owner, sent, closed, notes,
    addDevice: id => { const d = { deviceID: id }; devices.push(d);
      const old = push.device(device.deviceID);
      push.device(id).settings = clone(old.settings); push.device(id).enrollment = clone(old.enrollment); push.store.save(); return d; },
    advance: n => { now += n; }, resolve: r => { resolver = r; }, revokeDevice: () => { devices = []; } };
}
test('production fresh: atomic single-use claim, stable sealed binding, dedupe and restart', async t => {
  const bindings = [];
  const extra = { productionFresh: true,
    validateMapping: () => ({ authority: freshAuthority, pins: freshPins }),
    resolveTarget: async binding => {
      bindings.push(structuredClone(binding));
      assert.equal(Object.hasOwn(binding, 'claimed_call_id'), false);
      return { target_session: binding.target_session, authority: binding.authority, exclusive: true, single_use: true };
    } };
  const f = fixture(t, extra);
  const mapping = f.control.state.mappings[f.control.mappingKey(v.mapping.caller_id, v.mapping.project_id)];
  const before = structuredClone(mapping);
  const c = await f.invite();
  assert.equal(mapping.claimed_call_id, c.call_id);
  assert.deepEqual(f.control.state.calls['v:' + c.call_id].binding, before);
  assert.ok(bindings.length >= 2); for (const binding of bindings) assert.deepEqual(binding, before);
  await f.control.act(f.device, c.call_id, 'decline', f.owner(c));
  f.advance(61000); f.control.capability(f.device, v.capability);
  await assert.rejects(f.request({ ...v.request, operation_id: opID() }), { status: 409 });
  assert.equal((await f.request()).call_id, c.call_id);
  assert.throws(() => f.control.configureMapping({ ...v.mapping, binding_revision: v.mapping.binding_revision + 1 }), { status: 409 });
  const push = new PushService({ ...f.options, store: new PushStore(f.root) });
  const restored = new OpenVoiceControl({ ...f.config, push });
  assert.equal(restored.state.mappings[restored.mappingKey(v.mapping.caller_id, v.mapping.project_id)].claimed_call_id, c.call_id);
  await assert.rejects(push.requestOpenVoice(restored, { token: f.grant.token, body: { ...v.request, operation_id: opID() } }), { status: 409 });
  assert.equal(f.sent.filter(x => x.voip).length, 1);
});
test('production fresh: policy/hold failures do not claim; concurrent callers claim only once', async t => {
  const f = fixture(t, { productionFresh: true, validateMapping: () => ({ authority: freshAuthority, pins: freshPins }),
    resolveTarget: async b => ({ target_session: b.target_session, authority: b.authority, exclusive: true, single_use: true }) });
  const mapping = f.control.state.mappings[f.control.mappingKey(v.mapping.caller_id, v.mapping.project_id)];
  f.push.maintenance = { requireOpen() { throw Object.assign(new Error('held'), { status: 503 }); } };
  await assert.rejects(f.request(), { status: 503 }); assert.equal(mapping.claimed_call_id, undefined);
  delete f.push.maintenance;
  const cap = f.control.state.capabilities['v:fixture-phone']; cap.enabled = false;
  await assert.rejects(f.request()); assert.equal(mapping.claimed_call_id, undefined); cap.enabled = true;
  const results = await Promise.allSettled([f.request(), f.request({ ...v.request, operation_id: opID() })]);
  assert.equal(results.filter(x => x.status === 'fulfilled').length, 1);
  assert.equal(results.filter(x => x.status === 'rejected').length, 1);
  await f.push.drain(); assert.equal(f.sent.filter(x => x.voip).length, 1);
});
test('real store/service: durable candidate intent, opaque payload, no legacy chief impersonation', async t => {
  const f = fixture(t); const c = await f.invite(); assert.equal(f.sent.length, 1);
  assert.equal(c.context, 'open-voice'); assert.deepEqual(Object.keys(await f.control.http('GET', '/calls/' + c.call_id, f.grant.token)).sort(), ['call_id', 'status']);
  assert.deepEqual(Object.keys(c).sort(), Object.keys(v.recipient_response).sort());
  const payload = f.sent[0].payload;
  assert.deepEqual(Object.keys(payload).sort(), ['aps', 'callUUID', 'expiry', 'reachoutID', 'ringDeadline']);
  const persisted = fs.readFileSync(f.push.store.file, 'utf8'); assert.ok(!persisted.includes(f.grant.token));
  assert.equal(f.push.store.data.records['r:' + c.call_id].request.session, undefined);
  assert.equal(f.push.lookup(f.device, c.call_id).context, 'open-voice');
});
test('dedupe survives terminal/restart; changed payload conflicts; durable APNs intent never resends', async t => {
  const f = fixture(t), c = await f.invite(); await f.control.act(f.device, c.call_id, 'decline', f.owner(c));
  assert.equal((await f.request()).call_id, c.call_id);
  await assert.rejects(f.request({ ...v.request, summary: 'changed' }), { status: 409 });
  const push = new PushService({ ...f.options, store: new PushStore(f.root) });
  const control = new OpenVoiceControl({ ...f.config, push });
  assert.equal((await push.requestOpenVoice(control, { token: f.grant.token, body: v.request })).status, 'rejected');
  await push.recover(); await push.drain(); assert.equal(f.sent.filter(s => s.voip).length, 1);
  assert.equal(f.sent.filter(s => !s.voip).length, 0); // a declined call reports its outcome only; never another ring
});
test('caller has no device/media/end/operations/admin authority or identity/URL/path override', async t => {
  const f = fixture(t), c = await f.invite();
  for (const field of ['caller_id', 'principal_id', 'target_session', 'directory', 'url', 'apnsToken', 'identity', 'token'])
    await assert.rejects(f.request({ ...v.request, [field]: 'forbidden' }));
  for (const action of ['accept', 'decline', 'media', 'end']) await assert.rejects(f.control.http('POST', '/calls/' + c.call_id + '/' + action, f.grant.token, f.owner(c)));
  await assert.rejects(f.control.http('GET', '/calls/' + c.call_id + '/operations/' + opID(), f.grant.token));
  await assert.rejects(f.control.http('POST', '/admin', f.grant.token, {}));
  assert.throws(() => f.push.requestOpenVoice({}, {}), { status: 403 });
});
test('grant scope, expiry, revocation, audience, principal and projects fail closed', async t => {
  const f = fixture(t), stored = f.control.state.grants['v:' + f.grant.grant_id];
  for (const [field, value] of [['audience', 'other'], ['principal_id', 'other'], ['scopes', []], ['project_ids', []], ['expires_at', 0]]) {
    const before = clone(stored[field]); stored[field] = value; await assert.rejects(f.request()); stored[field] = before;
  }
  f.control.revoke(f.grant.grant_id); await assert.rejects(f.request()); assert.equal(f.sent.length, 0);
});
test('absent/old/disabled capability, unavailable/busy/unpaired target never push', async t => {
  const f = fixture(t);
  for (const cap of [undefined, { ...v.capability, enabled: false, expires_at: Infinity }, { ...v.capability, build: 'old', expires_at: Infinity }]) {
    f.control.state.capabilities['v:fixture-phone'] = cap; await assert.rejects(f.request());
  }
  f.control.capability(f.device, v.capability);
  for (const field of ['authenticated', 'paired', 'available', 'idle']) {
    f.resolve(b => ({ ...b, authenticated: true, paired: true, available: true, idle: true, [field]: false }));
    await assert.rejects(f.request());
  }
  assert.equal(f.sent.length, 0);
});
test('real policy quiet, freshness and restrictive settings block candidate', async t => {
  const f = fixture(t), d = f.push.device(f.device.deviceID), settings = clone(d.settings);
  for (const patch of [{ callsEnabled: false }, { syncedAt: 0 }, { quietStart: '00:00', quietEnd: '00:00' }]) {
    Object.assign(d.settings, patch); await assert.rejects(f.request()); d.settings = clone(settings);
  }
  const c = await f.accepted(); f.advance(61000); f.control.capability(f.device, v.capability);
  await assert.rejects(f.request({ ...v.request, operation_id: opID() }));
  assert.equal(c.context, 'open-voice');
});
test('legacy reservation blocks candidate', async t => {
  const f = fixture(t);
  const legacy = { id: 'fixture-legacy', session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' };
  await f.push.send(legacy); await assert.rejects(f.request()); assert.equal(f.sent.length, 1);
});
test('candidate reservation counted by unchanged legacy policy', async t => {
  const f = fixture(t); await f.accepted();
  const r = await f.push.send({ id: 'fixture-legacy', session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' });
  assert.equal(r.policyReason, 'call-outstanding'); await f.push.drain(); assert.equal(f.sent.filter(s => s.voip).length, 1);
});
test('exact owner, atomic accept, decline/expiry cannot resurrect; answered receipt is not accept', async t => {
  const f = fixture(t), c = await f.invite();
  await f.push.event(f.device, { reachoutID: c.call_id, callUUID: c.call_uuid, event: 'answered' });
  await assert.rejects(f.control.act(f.device, c.call_id, 'media', f.owner(c)));
  for (const field of ['call_uuid', 'owner_epoch', 'binding_revision', 'target_id'])
    await assert.rejects(f.control.act(f.device, c.call_id, 'accept', { ...f.owner(c), [field]: 'wrong' }));
  await f.control.act(f.device, c.call_id, 'decline', f.owner(c));
  await assert.rejects(f.control.act(f.device, c.call_id, 'accept', f.owner(c))); assert.equal(f.notes.length, 0);
});
test('ring expiry rejects late acceptance', async t => {
  const f = fixture(t), c = await f.invite(); f.advance(30000); await assert.rejects(f.control.act(f.device, c.call_id, 'accept', f.owner(c)));
  assert.equal(f.control.recipient(f.device, c.call_id).status, 'expired');
});
test('media replacement fences prior lease/owner; token cannot reattach; active current-authority independent of attachment TTL', async t => {
  const f = fixture(t), { c, lease, epoch } = await f.media();
  assert.deepEqual(Object.keys(lease).sort(), v.media_response_keys.slice().sort());
  await assert.rejects(f.control.attach(lease.media_lease));
  f.advance(61000); assert.ok(f.control.currentAuthority(c.call_id, epoch));
  const replacement = await f.control.act(f.device, c.call_id, 'media', f.owner(c));
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
  await assert.rejects(f.control.attach(lease.media_lease)); await f.control.attach(replacement.media_lease);
  assert.ok(f.closed.some(x => x.media_epoch === epoch));
});
test('revocation after APNs handoff records delivery facts, closes authority, retains historical operations', async t => {
  const f = fixture(t), { c, epoch } = await f.media(), id = opID();
  await f.control.prepare(c.call_id, epoch, id, v.canonical_item);
  f.control.revoke(f.grant.grant_id);
  assert.equal(f.control.state.calls['v:' + c.call_id].push_delivery, 'apns-accepted');
  assert.throws(() => f.push.lookup(f.device, c.call_id)); assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
  assert.equal((await f.control.http('GET', '/calls/' + c.call_id + '/operations/' + id, 'fixture-device-token')).state, 'prepared');
  assert.equal(f.notes.length, 0);
});
test('mapping rotation or busy target cannot retarget accept/attach/admission', async t => {
  const f = fixture(t), { c, epoch } = await f.media();
  f.resolve(b => ({ ...b, authenticated: true, paired: true, available: true, idle: false }));
  await assert.rejects(f.control.prepare(c.call_id, epoch, opID(), v.canonical_item));
  f.control.configureMapping({ ...v.mapping, binding_revision: 2, target_session: 'ses_newfixture' });
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
});
test('prepare/dispatch/result durable seam, one claimed exchange across IDs and reconnect', async t => {
  const f = fixture(t), { c, epoch } = await f.media(), id = opID();
  const p = await f.control.prepare(c.call_id, epoch, id, v.canonical_item);
  assert.equal(p.state, 'prepared'); assert.deepEqual(Object.keys(p).sort(), v.operation_response_keys.slice().sort());
  assert.deepEqual(await f.control.prepare(c.call_id, epoch, id, v.canonical_item), p);
  const changed = clone(v.canonical_item); changed.content[0].text += ' changed';
  await assert.rejects(f.control.prepare(c.call_id, epoch, id, changed), { status: 409 });
  await assert.rejects(f.control.prepare(c.call_id, epoch, opID(), v.canonical_item), { status: 409 });
  await f.control.dispatch(c.call_id, epoch, id); await assert.rejects(f.control.dispatch(c.call_id, epoch, id));
  f.control.result(c.call_id, id, { state: 'uncertain' });
  assert.equal((await f.control.prepare(c.call_id, epoch, id, v.canonical_item)).state, 'uncertain');
  f.control.result(c.call_id, id, { state: 'completed', source_user_id: 'user_fixture', source_assistant_id: 'assistant_fixture', delivery: { state: 'unknown', rendered_samples: 0 } });
  await assert.rejects(f.control.prepare(c.call_id, epoch, opID(), v.canonical_item));
});
test('restart dispatching -> uncertain; prepared remains claimed, no external replay', async t => {
  const f = fixture(t), { c, epoch } = await f.media(), id = opID();
  await f.control.prepare(c.call_id, epoch, id, v.canonical_item); await f.control.dispatch(c.call_id, epoch, id);
  const push = new PushService({ ...f.options, store: new PushStore(f.root) }); const control = new OpenVoiceControl({ ...f.config, push });
  assert.equal((await control.http('GET', '/calls/' + c.call_id + '/operations/' + id, 'fixture-device-token')).state, 'uncertain');
  assert.throws(() => control.currentAuthority(c.call_id, epoch)); assert.equal(f.notes.length, 0);
});
test('deliberate End persists exact scoped intent before single system hook, no assistant response', async t => {
  const f = fixture(t), c = await f.accepted(), body = { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' };
  await f.control.act(f.device, c.call_id, 'end', body); await new Promise(resolve => setImmediate(resolve));
  await f.control.act(f.device, c.call_id, 'end', body);
  assert.equal(f.notes.length, 1); assert.equal(f.notes[0].text, '[voice] ended'); assert.equal(f.notes[0].role, 'system');
  assert.equal(f.notes[0].assistant_response, false); assert.equal(f.notes[0].binding.target_session, v.mapping.target_session);
  await assert.rejects(f.control.act(f.device, c.call_id, 'end', { ...body, operation_id: opID() }));
  await assert.rejects(f.control.act(f.device, c.call_id, 'end', { ...body, reason: 'route-failure' }));
});
test('end callback failure uncertain, never retried; receipt alone produces no note', async t => {
  let attempts = 0; const f = fixture(t, { endNote: async () => { attempts++; throw new Error('secret URL'); } });
  const c = await f.accepted(), body = { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' };
  await f.control.act(f.device, c.call_id, 'end', body); await new Promise(resolve => setImmediate(resolve));
  assert.equal((await f.control.act(f.device, c.call_id, 'end', body)).state, 'uncertain'); assert.equal(attempts, 1);
});
test('status read cap and full ledger refuse new work without eviction', async t => {
  const f = fixture(t), c = await f.invite();
  for (let i = 0; i < 30; i++) await f.control.http('GET', '/calls/' + c.call_id, f.grant.token);
  await assert.rejects(f.control.http('GET', '/calls/' + c.call_id, f.grant.token), { status: 429 });
  for (let i = 0; i < 4096; i++) f.control.state.grants['limit:' + i] = {};
  assert.throws(() => f.control.issue(v.grant), { status: 429 });
});
test('owner admin separate 0600 socket in owned 0700 root; only redacted list', async t => {
  const f = fixture(t), admin = await startOpenVoiceAdmin(f.control, f.root); t.after(() => admin.close());
  assert.equal(fs.statSync(admin.socketPath).mode & 0o777, 0o600);
  const request = async o => {
    const s = net.connect(admin.socketPath); s.setTimeout(2000, () => s.destroy()); s.end(JSON.stringify(o) + '\n');
    const chunks = []; for await (const b of s) chunks.push(b); return JSON.parse(Buffer.concat(chunks));
  };
  const issued = await request({ command: 'issue', value: v.grant }); assert.match(issued.token, /^[A-Za-z0-9_-]{43}$/);
  const listed = await request({ command: 'list' }); assert.ok(!JSON.stringify(listed).includes(issued.token)); assert.ok(!JSON.stringify(listed).includes('hash'));
  assert.equal((await request({ command: 'revoke', grant_id: issued.grant_id })).revoked, true);
  assert.equal((await request({ command: 'send', session: 'ses_SYNTHETIC0028' })).error, 'control_refused');
});
test('default-off real HTTP route before legacy auth; enabled strict and sanitized', async t => {
  const f = fixture(t);
  const open = async options => {
    const s = createBridge({ credentials: f.credentials, push: options.push, ocClient: { check: async () => {} }, ...options });
    s.listen(0, '127.0.0.1'); await once(s, 'listening'); t.after(() => new Promise(r => { s.closeAllConnections(); s.close(r); }));
    return 'http://127.0.0.1:' + s.address().port + CONTROL_PREFIX;
  };
  const off = await open({ push: f.push });
  assert.equal((await fetch(off + '/calls', { method: 'POST' })).status, 404);
  // New injected instance in same synthetic store only. No production discovery or real credentials.
  delete f.push.openVoice;
  const url = await open({ push: f.push, openVoiceCandidate: f.config });
  const send = (path, body, token = f.grant.token, headers = {}) => fetch(url + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token, ...headers }, body: JSON.stringify(body) });
  const response = await send('/calls', v.request); assert.equal(response.status, 409); // No assembled WS/adapter yet, even with a caller-inaccessible fake gate in config.
  for (const [path, body, headers] of [['/calls', { ...v.request, upstream_url: 'secret' }, {}], ['/unknown', {}, {}], ['/calls?token=secret', v.request, {}], ['/calls', v.request, { Origin: 'https://fixture.invalid' }]]) {
    const r = await send(path, body, f.grant.token, headers); assert.ok(r.status >= 400); assert.deepEqual(await r.json(), { error: 'control_refused' });
  }
  assert.equal(f.sent.length, 0);
  await f.push.drain();
});
test('capability disable/expiry and fresh re-opt-in cannot restore terminal authority', async t => {
  const f = fixture(t), { c, epoch } = await f.media(); f.advance(300000);
  f.control.capability(f.device, v.capability);
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
  assert.equal(f.control.recipient(f.device, c.call_id).status, 'rejected');
  await assert.rejects(f.control.act(f.device, c.call_id, 'media', f.owner(c)));
});
test('grant expiry and device revocation fence active owner without end-note authority', async t => {
  const f = fixture(t), { c, epoch } = await f.media(); f.revokeDevice(); f.control.recover();
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch)); assert.equal(f.notes.length, 0);
  assert.ok(f.closed.some(x => x.call_id === c.call_id && x.media_epoch === epoch));
});
test('APNs dispatch revalidates grant after authenticated resolver await', async t => {
  const f = fixture(t); let n = 0;
  f.resolve(b => { if (++n === 2) f.control.revoke(f.grant.grant_id); return { ...b, authenticated: true, paired: true, available: true, idle: true }; });
  const c = await f.request(); await f.push.drain(); assert.equal(f.sent.length, 0);
  assert.equal(f.control.state.calls['v:' + c.call_id].push_delivery, 'delivery-unknown');
  assert.throws(() => f.push.lookup(f.device, c.call_id));
});
test('accept/mint/attach reject authority changed while resolving target', async t => {
  const f = fixture(t), c = await f.accepted();
  const lease = await f.control.act(f.device, c.call_id, 'media', f.owner(c));
  f.resolve(b => { f.control.revoke(f.grant.grant_id); return { ...b, authenticated: true, paired: true, available: true, idle: true }; });
  await assert.rejects(f.control.attach(lease.media_lease));
  await assert.rejects(f.control.act(f.device, c.call_id, 'media', f.owner(c)));
});
test('failed durable intent poisons candidate and causes zero APNs side effects', async t => {
  const f = fixture(t); f.push.store.save = () => { throw new Error('fixture fsync failure'); };
  await assert.rejects(f.request()); assert.equal(f.sent.length, 0);
  await assert.rejects(f.control.http('POST', '/calls', f.grant.token, v.request), { status: 503 });
});
test('caller rate cap is identity-wide across grants and no dev override bypass', async t => {
  const f = fixture(t), c = await f.invite(); await f.control.act(f.device, c.call_id, 'decline', f.owner(c));
  const g2 = f.control.issue(v.grant);
  await assert.rejects(f.push.requestOpenVoice(f.control, { token: g2.token, body: { ...v.request, operation_id: opID() } }));
  // Candidate never reads the developer override; even the presence of an owned file cannot bypass spacing.
  fs.writeFileSync(path.join(f.root, 'dev-override.json'), JSON.stringify({ active: true }), { mode: 0o600 });
  f.advance(61000); f.control.capability(f.device, v.capability);
  await assert.rejects(f.request({ ...v.request, operation_id: opID() }));
});
test('end lifecycle receipt ends exact candidate owner but never authorizes deliberate note', async t => {
  const f = fixture(t), { c, epoch } = await f.media();
  await f.push.event(f.device, { reachoutID: c.call_id, callUUID: c.call_uuid, event: 'ended' });
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch)); assert.equal(f.notes.length, 0);
  await assert.rejects(f.control.act(f.device, c.call_id, 'end', { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' }));
});
test('candidate 410 invalidates only dispatched enrollment snapshot', async t => {
  const f = fixture(t); f.push.apns = async x => { f.sent.push(x); return { status: 410 }; };
  await f.invite(); assert.equal(f.push.device(f.device.deviceID).enrollment.voipToken, null);
});
test('accepted call outlives ring deadline but never its grant', async t => {
  const f = fixture(t), c = await f.accepted(); f.advance(61000);
  assert.equal(f.control.recipient(f.device, c.call_id).status, 'accepted');
  const g = f.control.state.grants['v:' + f.grant.grant_id]; g.expires_at = Date.parse('2026-10-19T17:01:01Z'); f.control.recover();
  assert.equal(f.control.recipient(f.device, c.call_id).status, 'rejected');
  await assert.rejects(f.control.act(f.device, c.call_id, 'media', f.owner(c))); assert.equal(f.notes.length, 0);
});
test('End hook sees fsynced scoped intent and terminal authority, never a legacy prompt', async t => {
  const f = fixture(t), c = await f.accepted(), operation_id = opID(); let seen = 0;
  f.control.endNote = async payload => {
    const saved = JSON.parse(fs.readFileSync(f.push.store.file)); const call = saved.openVoice.calls['v:' + c.call_id];
    assert.equal(call.state, 'ended'); assert.equal(call.operations['v:' + operation_id].state, 'dispatching');
    assert.equal(call.end_operation, operation_id); assert.equal(payload.owner_epoch, c.owner_epoch);
    assert.equal(payload.assistant_response, false); seen++;
  };
  await f.control.act(f.device, c.call_id, 'end', { ...f.owner(c), operation_id, reason: 'deliberate-user' });
  await new Promise(resolve => setImmediate(resolve)); assert.equal(seen, 1);
});
test('restart with a pre-side-effect push intent marks uncertainty and never rings it', async t => {
  const f = fixture(t);
  // Reserve a real lane so the next candidate intent is persisted but cannot run.
  f.push.lanes.call.active = CONFIG.dispatchConcurrency;
  const c = await f.request(); assert.equal(f.sent.length, 0);
  const push = new PushService({ ...f.options, store: new PushStore(f.root) }); const control = new OpenVoiceControl({ ...f.config, push });
  await push.recover(); await push.drain(); assert.equal(f.sent.length, 0);
  assert.equal(push.store.data.records['r:' + c.call_id].targets['d:fixture-phone'].state, 'delivery-unknown');
  assert.equal((await push.requestOpenVoice(control, { token: f.grant.token, body: v.request })).call_id, c.call_id);
});
test('public media epoch is a canonical decimal string; private attachment/owner epoch remains integer', async t => {
  const f = fixture(t), { c, lease, epoch } = await f.media();
  assert.deepEqual({ ...lease, media_lease: v.media_response.media_lease }, v.media_response);
  assert.equal(typeof lease.media_epoch, 'string'); assert.match(lease.media_epoch, /^(0|[1-9][0-9]*)$/);
  assert.equal(typeof epoch, 'number'); assert.ok(Number.isSafeInteger(epoch)); assert.equal(String(epoch), lease.media_epoch);
  assert.equal(f.control.state.calls['v:' + c.call_id].media_epoch, epoch);
  for (const untrusted of [lease.media_epoch, '01', '1e0', '1.0', [epoch], { valueOf: () => epoch }])
    assert.throws(() => f.control.currentAuthority(c.call_id, untrusted));
  const replacement = await f.control.act(f.device, c.call_id, 'media', f.owner(c));
  assert.equal(replacement.media_epoch, String(epoch + 1)); assert.ok(f.closed.some(x => x.media_epoch === epoch && typeof x.media_epoch === 'number'));
});
for (const field of ['idle', 'available']) test(`exact owner End fences locally when target ${field} is false, without posting note`, async t => {
  const f = fixture(t), { c, epoch } = await f.media();
  f.resolve(b => ({ ...b, authenticated: true, paired: true, available: true, idle: true, [field]: false }));
  for (const ownerField of ['call_uuid', 'owner_epoch', 'binding_revision', 'target_id']) {
    await assert.rejects(f.control.act(f.device, c.call_id, 'end', { ...f.owner(c), [ownerField]: 'stale', operation_id: opID(), reason: 'deliberate-user' }));
    assert.ok(f.control.currentAuthority(c.call_id, epoch));
  }
  const body = { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' };
  assert.equal((await f.control.act(f.device, c.call_id, 'end', body)).state, 'prepared');
  assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
  assert.ok(f.closed.some(x => x.call_id === c.call_id && x.media_epoch === epoch));
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.notes.length, 0);
  assert.equal((await f.control.act(f.device, c.call_id, 'end', body)).state, 'prepared');
  f.resolve(b => ({ ...b, authenticated: true, paired: true, available: true, idle: true }));
  await f.control.act(f.device, c.call_id, 'end', body); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.notes.length, 0); // No blind repost after target recovery.
});
test('candidate reservation prevents legacy ringing a different paired device until terminal release', async t => {
  const f = fixture(t); const b = f.addDevice('fixture-phone-b'), c = await f.accepted();
  const legacy = id => ({ id, session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' });
  await f.push.send(legacy('legacy-during-candidate')); await f.push.drain();
  assert.equal(f.sent.filter(x => x.voip).length, 1);
  const blocked = f.push.store.data.records['r:legacy-during-candidate'];
  assert.equal(blocked.targets['d:' + b.deviceID].reason, 'call-outstanding');
  await f.control.act(f.device, c.call_id, 'end', { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' });
  // Late answered receipt cannot resurrect the ended candidate or its reservation.
  await f.push.event(f.device, { reachoutID: c.call_id, callUUID: c.call_uuid, event: 'answered' });
  const r = await f.push.send(legacy('legacy-after-candidate'));
  assert.equal(r.targets[1].policyReason, 'urgent-eligible'); await f.push.drain();
  assert.ok(r.targets.every(t => t.policyReason === 'urgent-eligible'));
  assert.equal(f.sent.filter(x => x.voip).length, 3); // A and B; no spacing limit after terminal release.
  await f.push.send(legacy('legacy-after-candidate')); await f.push.drain();
  assert.equal(f.sent.filter(x => x.voip).length, 3); // Same ID never rings twice.
});
test('legacy reservation on B prevents candidate A, including late answer; explicit terminal receipt releases it', async t => {
  const f = fixture(t), b = f.addDevice('fixture-phone-b'), settings = f.push.device(f.device.deviceID).settings;
  settings.callsEnabled = false; f.push.store.save();
  await f.push.send({ id: 'legacy-b', session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' });
  await f.push.drain(); assert.equal(f.sent.filter(x => x.voip).length, 2);
  const r = f.push.store.data.records['r:legacy-b'];
  assert.equal(r.targets['d:' + f.device.deviceID].reason, 'urgent-eligible');
  // Ordinary Calls/quiet-hours settings are enforced by the receiving phone.
  await f.push.event(f.device, { reachoutID: 'legacy-b', callUUID: r.callUUID, event: 'declined' });
  settings.callsEnabled = true; f.push.store.save();
  await assert.rejects(f.request());
  await f.push.event(b, { reachoutID: 'legacy-b', callUUID: r.callUUID, event: 'answered' });
  f.advance(16 * 60000); f.control.capability(f.device, v.capability);
  await assert.rejects(f.request()); assert.equal(f.sent.filter(x => x.voip).length, 2);
  await f.push.event(b, { reachoutID: 'legacy-b', callUUID: r.callUUID, event: 'ended' });
  const c = await f.invite(); assert.equal(c.status, 'ringing'); assert.equal(f.sent.filter(x => x.voip).length, 3);
});
test('expired pending candidate releases aggregate guard but a late accept never restores it', async t => {
  const f = fixture(t), b = f.addDevice('fixture-phone-b'), c = await f.invite(); f.advance(30000); f.control.recover();
  await assert.rejects(f.control.act(f.device, c.call_id, 'accept', f.owner(c)));
  await f.push.send({ id: 'legacy-after-expiry', session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' });
  await f.push.drain(); assert.equal(f.push.store.data.records['r:legacy-after-expiry'].targets['d:' + b.deviceID].reason, 'urgent-eligible');
  assert.equal(f.push.store.data.records['r:legacy-after-expiry'].targets['d:' + f.device.deviceID].reason, 'urgent-eligible');
  assert.equal(f.sent.filter(x => x.voip).length, 3); // Both devices eligible after expiry; no pacing cap.
});
test('failed epoch persistence still synchronously closes the previously attached generation', async t => {
  const f = fixture(t), { c, epoch } = await f.media(); let saves = 0;
  f.push.store.save = () => { saves++; throw new Error('synthetic fsync failure'); };
  await assert.rejects(f.control.act(f.device, c.call_id, 'media', f.owner(c)));
  assert.equal(saves, 1); assert.ok(f.closed.some(x => x.call_id === c.call_id && x.media_epoch === epoch));
  assert.equal(f.control.poisoned, true); assert.throws(() => f.control.currentAuthority(c.call_id, epoch));
});
test('persistence poison blocks a queued deliberate-note hook', async t => {
  const f = fixture(t), c = await f.accepted();
  let release; const gate = new Promise(resolve => { release = resolve; });
  f.resolve(async b => { await gate; return { ...b, authenticated: true, paired: true, available: true, idle: true }; });
  await f.control.act(f.device, c.call_id, 'end', { ...f.owner(c), operation_id: opID(), reason: 'deliberate-user' });
  // Trigger poison before the async resolver can authorize note dispatch.
  f.push.store.save = () => { throw new Error('synthetic fsync failure'); };
  assert.throws(() => f.control.save());
  const effects = f.sent.length; release();
  await new Promise(resolve => setImmediate(resolve)); assert.equal(f.notes.length, 0);
  await f.push.drain(); assert.equal(f.sent.length, effects);
});
test('legacy queued delivery rechecks a later candidate reservation at APNs boundary', async t => {
  const f = fixture(t), b = f.addDevice('fixture-phone-b');
  f.push.config = { ...CONFIG, callSpacingMs: 0 }; // isolate pending-deadline race from spacing
  const settings = f.push.device(f.device.deviceID).settings; settings.callsEnabled = false; f.push.store.save();
  f.push.lanes.call.active = CONFIG.dispatchConcurrency;
  await f.push.send({ id: 'legacy-queued-b', session: 'ses_SYNTHETIC0028', kind: 'urgent-call', reason: 'decision', title: 'Decision', body: 'Fixture decision' });
  f.advance(CONFIG.fallbackMs); await f.push.recover(); settings.callsEnabled = true; f.push.store.save();
  const call = await f.request(); // accepted while both VoIP jobs remain queued
  const c = f.control.recipient(f.device, call.call_id); await f.control.act(f.device, c.call_id, 'accept', f.owner(c));
  f.push.lanes.call.active = 0; f.push.pump(f.push.lanes.call); await f.push.drain();
  assert.equal(f.sent.filter(x => x.voip).length, 0); // legacy downgrades; accepted candidate no longer rings
  assert.equal(f.push.store.data.records['r:legacy-queued-b'].targets['d:' + b.deviceID].reason, 'call-outstanding');
});
test('media-ready requires exact paired owner, attached live effective-configured session, and string epoch', async t => {
  const f = fixture(t), { c, lease, epoch } = await f.media(); let live = true;
  const body = { ...f.owner(c), media_epoch: lease.media_epoch, session_id: 'sess_fixture', native_capture_ready: true };
  const route = '/calls/' + c.call_id + '/media-ready';
  await assert.rejects(f.control.http('POST', route, 'fixture-device-token', body));
  f.control.registerMediaSession(c.call_id, epoch, body.session_id, () => live);
  await assert.rejects(f.control.http('POST', route, 'fixture-device-token', body));
  f.control.effectiveConfigured(c.call_id, epoch, body.session_id);
  for (const patch of [{ media_epoch: epoch }, { media_epoch: '01' }, { session_id: 'sess_wrong' }, { native_capture_ready: false }, { owner_epoch: opID() }, { extra: true }])
    await assert.rejects(f.control.http('POST', route, 'fixture-device-token', { ...body, ...patch }));
  await assert.rejects(f.control.http('POST', route, f.grant.token, body));
  assert.deepEqual(await f.control.http('POST', route, 'fixture-device-token', body), { ...v.media_ready_response, call_id: c.call_id });
  f.control.readyAuthority(c.call_id, epoch, body.session_id);
  live = false;
  await assert.rejects(f.control.http('POST', route, 'fixture-device-token', body));
  assert.throws(() => f.control.readyAuthority(c.call_id, epoch, body.session_id));
  f.control.unregisterMediaSession(c.call_id, epoch, body.session_id);
  assert.equal(f.control.state.calls['v:' + c.call_id].media_ready, undefined);
});
test('replacement and revocation durably fence media readiness; old true cannot survive new owner', async t => {
  const f = fixture(t), { c, lease, epoch } = await f.media();
  const body = { ...f.owner(c), media_epoch: lease.media_epoch, session_id: 'sess_fixture', native_capture_ready: true };
  f.control.registerMediaSession(c.call_id, epoch, body.session_id, () => true);
  f.control.effectiveConfigured(c.call_id, epoch, body.session_id); f.control.mediaReady(f.device, c.call_id, body);
  const replacement = await f.control.act(f.device, c.call_id, 'media', f.owner(c));
  assert.equal(f.control.state.calls['v:' + c.call_id].media_ready, undefined);
  assert.equal(JSON.parse(fs.readFileSync(f.push.store.file)).openVoice.calls['v:' + c.call_id].media_ready, undefined);
  await assert.rejects(f.control.http('POST', '/calls/' + c.call_id + '/media-ready', 'fixture-device-token', body));
  const a = await f.control.attach(replacement.media_lease);
  f.control.registerMediaSession(c.call_id, a.media_epoch, 'sess_new', () => true);
  f.control.effectiveConfigured(c.call_id, a.media_epoch, 'sess_new');
  assert.throws(() => f.control.readyAuthority(c.call_id, a.media_epoch, 'sess_new'));
  f.control.revoke(f.grant.grant_id); assert.equal(f.control.state.calls['v:' + c.call_id].media_ready, undefined);
});
