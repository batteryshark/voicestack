import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import http2 from 'node:http2';
import { CONFIG, isQuiet, callPolicy, sendSchema, settingsSchema, enrollmentSchema } from './reachout-policy.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';
import { startSender } from './push-socket.mjs';
import { main, parseArgs, socketRequest } from './reachout.mjs';
import { jwt, createAPNs } from './apns.mjs';
import { Credentials, createBridge } from './server.mjs';
import { unpairedDesktop } from './fixtures/synthetic-desktop.mjs';
import { phoneProjection } from './rich-content.mjs';

const settings = { callsEnabled: true, quietHoursEnabled: true, quietStart: '22:00', quietEnd: '09:00', timeZone: 'America/New_York', policyVersion: 1, revision: 1 };
const enrollment = { alertToken: 'a'.repeat(64), voipToken: 'b'.repeat(64), environment: 'sandbox', build: '19', revision: 1 };
const intent = (id = 'need-1', kind = 'urgent-call', reason = 'decision') => ({ id, kind, reason, session: 'ses_chief', title: 'Decision needed', body: 'Work is blocked on your decision.' });
function fixture(t, config = CONFIG) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-push-')); fs.chmodSync(root, 0o700);
  fs.mkdirSync(path.join(root, 'private'), { mode: 0o700 });
  const dir = path.join(root, 'private/push');
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  let now = Date.parse('2026-01-01T17:00:00Z'), devices = [{ deviceID: 'phone' }]; const sent = [];
  const options = { store: new PushStore(dir), chief: () => 'ses_chief', activeDevices: () => devices, now: () => now, config,
    apns: async request => { sent.push(request); return { status: 200 }; } };
  const service = new PushService(options);
  service.update(devices[0], 'enrollment', enrollment); service.update(devices[0], 'settings', settings);
  return { dir, root, service, sent, options, advance: ms => { now += ms; }, setNow: n => { now = n; }, revoke: () => { devices = []; },
    target: id => service.store.data.records['r:' + id].targets['d:phone'], record: id => service.store.data.records['r:' + id], device: devices[0] };
}
test('quiet interval: midnight, half-open edges, equal endpoints, disabled and travel', () => {
  for (const [time, expected] of [['2026-01-01T02:59Z', false], ['2026-01-01T03:00Z', true], ['2026-01-01T05:00Z', true], ['2026-01-01T13:59Z', true], ['2026-01-01T14:00Z', false]]) {
    assert.equal(isQuiet(settings, Date.parse(time)), expected);
  }
  const now = Date.parse('2026-01-01T14:00Z');
  assert.equal(isQuiet({ ...settings, timeZone: 'Asia/Tokyo' }, now), true);
  assert.equal(isQuiet({ ...settings, quietStart: '09:00', quietEnd: '09:00' }, now), true);
  assert.equal(isQuiet({ ...settings, quietHoursEnabled: false }, now), false);
});
test('DST skipped and repeated local times', () => {
  const s = { ...settings, quietStart: '01:00', quietEnd: '03:00' };
  for (const time of ['2026-03-08T06:59Z', '2026-11-01T05:30Z', '2026-11-01T06:30Z']) assert.equal(isQuiet(s, Date.parse(time)), true);
  assert.equal(isQuiet(s, Date.parse('2026-03-08T07:00Z')), false);
});
test('freshness, calls-off and invalid zone fail closed', () => {
  const now = Date.parse('2026-01-01T17:00Z'), s = { ...settings, syncedAt: now };
  assert.equal(callPolicy(s, now), 'urgent-eligible');
  assert.equal(callPolicy({ ...s, callsEnabled: false }, now), 'calls-off');
  assert.equal(callPolicy({ ...s, timeZone: 'Invalid/Zone' }, now), 'invalid-time-zone');
  for (const syncedAt of [now + 1, now - 86400000]) assert.equal(callPolicy({ ...s, syncedAt }, now), 'policy-stale');
  assert.equal(callPolicy(null, now), 'policy-stale');
});
test('schemas reject missing/unknown fields, classification mismatch, milestone and arbitrary URLs', () => {
  for (const value of [{ ...intent(), kind: 'milestone' }, { ...intent(), reason: 'build' }, { ...intent(), title: 'Milestone complete' }, { ...intent(), extra: true },
    { ...intent(), session: '../x' }, { ...intent(), expiresIn: 301 }, { ...intent(), url: 'https://evil.invalid/' }]) assert.throws(() => sendSchema(value));
  for (const value of [{ ...settings, revision: 0 }, { ...settings, quietStart: '24:00' }, { ...settings, timeZone: 'bad' }, { ...settings, policyVersion: 99 }]) assert.throws(() => settingsSchema(value));
  for (const value of [{ ...enrollment, voipToken: '' }, { ...enrollment, environment: 'dev' }, { ...enrollment, bearer: 'no' }, { revision: 1 }]) assert.throws(() => enrollmentSchema(value));
  // Messages/notifications moved to Nod: only urgent calls remain, with no install URL.
  for (const kind of ['need', 'ready-to-try']) assert.throws(() => sendSchema({ ...intent(), kind, reason: kind === 'need' ? 'hands' : 'build' }));
  assert.throws(() => sendSchema({ ...intent(), url: 'itms-services://?action=download-manifest&url=' + encodeURIComponent('https://test.example-tailnet.invalid/m.plist') }));
});
test('private atomic store modes and revision conflicts/out-of-order snapshots', t => {
  const f = fixture(t), d = f.device;
  assert.equal(fs.statSync(f.dir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(f.service.store.file).mode & 0o777, 0o600);
  f.service.update(d, 'settings', { ...settings, revision: 2 });
  assert.throws(() => f.service.update(d, 'settings', settings), /stale/);
  assert.throws(() => f.service.update(d, 'settings', { ...settings, revision: 2, callsEnabled: false }), /conflict/);
  f.service.update(d, 'settings', { ...settings, revision: 2 });
  assert.throws(() => f.service.update({ ...d, test: {} }, 'enrollment', enrollment));
  fs.chmodSync(f.service.store.file, 0o644); assert.throws(() => new PushStore(f.dir));
});
test('build 27 launch replay with reacquired-token placeholders hits revision conflict, not stale; settings is never reached', t => {
  const f = fixture(t), current = { ...enrollment, build: '27', revision: 12 };
  f.service.update(f.device, 'enrollment', current);
  const attempted = [];
  assert.throws(() => {
    attempted.push('enrollment');
    f.service.update(f.device, 'enrollment', { ...current, alertToken: null, voipToken: null });
    attempted.push('settings');
    f.service.update(f.device, 'settings', { ...settings, revision: 2, callsEnabled: false });
  }, e => e.status === 409 && e.message === 'revision conflict');
  assert.deepEqual(attempted, ['enrollment']);
  assert.equal(f.service.device('phone').settings.callsEnabled, true);
});
test('fresh per-snapshot enrollment revisions handle launch, upgrade, token callbacks and real policy edits', t => {
  const f = fixture(t), current = { ...enrollment, build: '27', revision: 12 };
  f.service.update(f.device, 'enrollment', current);
  let persistedRevision = current.revision;
  const snapshot = content => ({ ...content, revision: ++persistedRevision });
  const launch = snapshot({ ...current, alertToken: null, voipToken: null });
  assert.equal(f.service.update(f.device, 'enrollment', launch).revision, 13);
  const reacquired = snapshot(current);
  assert.equal(f.service.update(f.device, 'enrollment', reacquired).revision, 14);
  // A transient retry reuses the exact immutable payload/revision, not a new reservation.
  f.advance(10);
  assert.equal(f.service.update(f.device, 'enrollment', reacquired).revision, 14);
  const upgrade = snapshot({ ...current, build: 'next-build' });
  assert.equal(f.service.update(f.device, 'enrollment', upgrade).revision, 15);
  const editedEnrollment = snapshot({ ...upgrade });
  f.service.update(f.device, 'enrollment', editedEnrollment);
  const edited = { ...settings, revision: 2, callsEnabled: false, quietStart: '20:00' };
  const ack = f.service.update(f.device, 'settings', edited);
  assert.equal(ack.revision, 2); assert.equal(ack.callsEnabled, false); assert.equal(ack.quietStart, '20:00');
  assert.equal(callPolicy(ack, f.options.now()), 'calls-off');
  assert.equal(f.sent.length, 0, 'sync never sends a notification/call');
});
test('installed build 27 settings edit still syncs after ordinary enrollment recovery, with no new protocol fields', t => {
  const f = fixture(t), recovered = { ...enrollment, build: '27', revision: 12 };
  f.service.update(f.device, 'enrollment', recovered);
  // The installed app does not change enrollment revision for a settings edit.
  assert.equal(f.service.update(f.device, 'enrollment', { ...recovered }).revision, 12);
  assert.equal(f.service.update(f.device, 'settings', { ...settings, revision: 2, callsEnabled: false }).callsEnabled, false);
});
test('a settings edit after server token invalidation cannot be gated by an equal enrollment revision in the fixed app', t => {
  const f = fixture(t), current = { ...enrollment, build: '27', revision: 12 };
  f.service.update(f.device, 'enrollment', current);
  // Same durable mutation used when APNs invalidates a token. No key/token file is read.
  f.service.device('phone').enrollment.voipToken = null;
  assert.throws(() => f.service.update(f.device, 'enrollment', current), e => e.status === 409 && e.message === 'revision conflict');
  f.service.update(f.device, 'enrollment', { ...current, revision: 13 });
  const ack = f.service.update(f.device, 'settings', { ...settings, revision: 2, quietHoursEnabled: false });
  assert.equal(ack.quietHoursEnabled, false); assert.equal(ack.revision, 2);
});
test('revision refusal diagnostics expose the closed check and revision numbers only, without weakening admission', t => {
  const f = fixture(t), events = [], current = { ...enrollment, build: '27', revision: 12 };
  f.service.update(f.device, 'enrollment', current);
  f.service.diagnostic = event => events.push(event);
  const saved = JSON.stringify(f.service.device('phone'));
  assert.throws(() => f.service.update(f.device, 'enrollment', { ...current, revision: 11 }), e => e.status === 409 && e.message === 'stale revision');
  assert.throws(() => f.service.update(f.device, 'enrollment', { ...current, build: 'changed' }), e => e.status === 409 && e.message === 'revision conflict');
  assert.throws(() => f.service.update(f.device, 'settings', { ...settings, callsEnabled: false }), e => e.status === 409 && e.message === 'revision conflict');
  assert.deepEqual(events, [
    { stage: 'push', category: 'stale_revision', kind: 'enrollment', status: 409, incomingRevision: 11, storedRevision: 12 },
    { stage: 'push', category: 'revision_conflict', kind: 'enrollment', status: 409, incomingRevision: 12, storedRevision: 12 },
    { stage: 'push', category: 'revision_conflict', kind: 'settings', status: 409, incomingRevision: 1, storedRevision: 1 }
  ]);
  assert.equal(JSON.stringify(f.service.device('phone')), saved);
  for (const token of [current.alertToken, current.voipToken]) assert.ok(!JSON.stringify(events).includes(token));
  f.service.diagnostic = () => { throw new Error('logger unavailable'); };
  assert.throws(() => f.service.update(f.device, 'enrollment', { ...current, build: 'changed' }), e => e.status === 409 && e.message === 'revision conflict');
});
test('call intent is durable before APNs, minimal payload, coalescing and immutable chief binding', async t => {
  const f = fixture(t);
  f.service.apns = async request => {
    assert.equal(new PushStore(f.dir).data.records['r:need-1'].targets['d:phone'].state, 'call-intent');
    f.sent.push(request); return { status: 200 };
  };
  await f.service.send(intent()); await f.service.send(intent());
  assert.equal(f.sent.length, 1); assert.equal(f.sent[0].voip, true);
  assert.deepEqual(Object.keys(f.sent[0].payload).sort(), ['aps', 'callUUID', 'expiry', 'reachoutID', 'ringDeadline']);
  await assert.rejects(f.service.send({ ...intent(), body: 'different' }), /bound/);
  await assert.rejects(f.service.send({ ...intent('other'), session: 'ses_other' }), /chief/);
  assert.equal(f.service.lookup(f.device, 'need-1').session, 'ses_chief');
  assert.throws(() => f.service.lookup({ deviceID: 'other' }, 'need-1'));
});
test('ordinary calls leave phone settings, stale snapshots and quiet decisions to phone', async t => {
  for (const mode of ['off', 'quiet', 'stale']) {
    const f = fixture(t);
    if (mode === 'off') f.service.update(f.device, 'settings', { ...settings, callsEnabled: false, revision: 2 });
    if (mode === 'quiet') f.setNow(Date.parse('2026-01-01T23:00Z') + 5 * 3600000);
    if (mode === 'stale') f.advance(86400000);
    await f.service.send(intent());
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].voip, true);
    assert.ok(!JSON.stringify(f.sent[0].payload).includes(intent().body));
  }
});
test('legacy override fields remain readable and inert through recovery, coalescing and dispatch', async t => {
  for (const quiet of [true, false]) {
    const f = fixture(t);
    const record = JSON.parse(fs.readFileSync(new URL('./fixtures/legacy-push-record.json', import.meta.url)));
    f.setNow(record.createdAt);
    f.service.update(f.device, 'settings', { ...settings, quietHoursEnabled: quiet, revision: 2 });
    f.service.store.data.records['r:' + record.request.id] = record;
    f.service.store.save();
    const service = new PushService({ ...f.options, store: new PushStore(f.dir), chief: () => record.request.session });
    assert.equal(service.lookup(f.device, record.request.id).session, record.request.session);
    assert.equal(service.status(record.request.id).id, record.request.id);
    assert.equal((await service.send(record.request)).coalesced, true);
    await service.recover(); await service.drain();
    assert.equal(f.sent.length, 0, 'restart must never replay an old call');
    const stored = service.store.data.records['r:' + record.request.id];
    assert.deepEqual(stored.testOverride, record.testOverride);
    // Simulate a queued job reaching dispatch: even a formerly valid grant is inert.
    service.deliver(stored, stored.targets['d:phone'], true); await service.drain();
    assert.equal(f.sent.length, 1);
    assert.equal(f.sent[0].voip, true);
    assert.equal(Object.hasOwn(f.sent[0].payload, 'acceptance'), false);
    await assert.rejects(service.send({ ...intent('not-chief'), session: 'ses_other' }), /chief/);
  }
});
test('answer suppresses fallback, terminal receipts do not resurrect it', async t => {
  const f = fixture(t); await f.service.send(intent());
  const event = { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID };
  for (const kind of ['reported', 'ringing', 'answered', 'ended', 'declined']) await f.service.event(f.device, { ...event, event: kind });
  f.advance(60000); await f.service.recover(); assert.equal(f.sent.length, 1); assert.equal(f.target('need-1').receipt, 'answered');
});
test('decline, report failure and end only report; no follow-up notification or second call', async t => {
  for (const kind of ['declined', 'report-failed', 'ended']) {
    const f = fixture(t); await f.service.send(intent());
    const event = { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID, event: kind };
    await f.service.event(f.device, event); await f.service.event(f.device, event);
    f.advance(50000); await f.service.recover(); await f.service.drain();
    assert.equal(f.sent.length, 1); assert.equal(f.sent[0].voip, true); assert.equal(f.target('need-1').fallback, undefined);
    assert.equal(f.service.status('need-1').targets[0].receipt, kind);
    await f.service.event(f.device, { ...event, event: 'answered' }); await f.service.recover(); assert.equal(f.sent.length, 1);
  }
});
test('30-second ring deadline expires the call; restarts never send anything else', async t => {
  const f = fixture(t); await f.service.send(intent()); f.advance(30000);
  await f.service.recover(); assert.equal(f.target('need-1').receipt, 'expired'); assert.equal(f.sent.length, 1);
  f.advance(15000);
  const restarted = new PushService({ ...f.options, store: new PushStore(f.dir) });
  await restarted.recover(); await restarted.recover(); assert.equal(f.sent.length, 1);
  assert.equal(f.target('need-1').fallback, undefined); assert.equal(restarted.localStats().invitations, 0);
});

test('closed terminal reason survives progress replay and decline stays declined after ended',async t=>{
  const f=fixture(t);await f.service.send(intent());
  const binding={reachoutID:'need-1',callUUID:f.record('need-1').callUUID};
  await f.service.event(f.device,{...binding,event:'ringing',reportedRinging:true});
  await f.service.event(f.device,{...binding,event:'declined',endReason:'declined',endInitiator:'systemEndAction',reportedRinging:true});
  await f.service.event(f.device,{...binding,event:'ended',endReason:'declined',endInitiator:'systemEndAction',reportedRinging:true});
  await f.service.event(f.device,{...binding,event:'reported'});
  await f.service.event(f.device,{...binding,event:'answered'});
  await f.service.drain();
  assert.equal(f.target('need-1').receipt,'declined');
  assert.equal(f.target('need-1').terminalReceipt.endInitiator,'systemEndAction');
  assert.equal(f.target('need-1').terminalReceipt.reportedRinging,true);
  assert.ok(f.target('need-1').endedAt!==undefined && f.target('need-1').ringingAt!==undefined);
  assert.equal(f.sent.filter(v=>!v.voip).length,0);
});

test('report rejection records DND or block code without raw strings and no fallback',async t=>{
  for(const reportFailure of ['filteredByDoNotDisturb','filteredByBlockList']){
    const f=fixture(t);await f.service.send(intent());
    await f.service.event(f.device,{reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'report-failed',endReason:'reportRejected',endInitiator:'reportFailure',reportedRinging:false,reportFailure,reportErrorCode:3});
    await f.service.drain();
    assert.equal(f.target('need-1').terminalReceipt.reportFailure,reportFailure);
    assert.equal(f.target('need-1').receipt,'report-failed');assert.equal(f.sent.filter(v=>!v.voip).length,0);
  }
});

test('arbitrary end metadata and caller/error text are refused before receipt mutation',async t=>{
  const f=fixture(t);await f.service.send(intent());
  const event={reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'ended'};
  for(const bad of [{endReason:'SECRET_URL'},{endInitiator:'arbitrary'},{reportFailure:'raw error'},{reportedRinging:'true'},{reportErrorCode:'private'},{errorText:'secret'}])
    await assert.rejects(f.service.event(f.device,{...event,...bad}));
  assert.equal(f.target('need-1').terminalReceipt,undefined);
});

test('durable report failure after expiry replaces the guess without any notification',async t=>{
  const f=fixture(t);await f.service.send(intent());f.advance(50000);await f.service.recover();await f.service.drain();
  assert.equal(f.target('need-1').receipt,'expired');
  await f.service.event(f.device,{reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'report-failed',endReason:'reportRejected',endInitiator:'reportFailure',reportedRinging:false,reportFailure:'filteredByDoNotDisturb',reportErrorCode:3});
  await f.service.drain();assert.equal(f.target('need-1').receipt,'report-failed');
  assert.equal(f.target('need-1').terminalReceipt.reportFailure,'filteredByDoNotDisturb');assert.equal(f.sent.filter(v=>!v.voip).length,0);
});
test('uncertain delivery and crash mid-send never retry VoIP; 410 invalidates only matching token', async t => {
  const f = fixture(t); f.service.apns = async request => { f.sent.push(request); throw Error('synthetic loss'); };
  await f.service.send(intent()); await f.service.drain(); assert.equal(f.target('need-1').state, 'delivery-unknown');
  f.target('need-1').state = 'call-intent'; f.service.store.save();
  const restarted = new PushService({ ...f.options, store: new PushStore(f.dir) }); await restarted.recover();
  assert.equal(f.sent.length, 1); f.advance(45000); await restarted.recover(); assert.equal(f.sent.filter(s => s.voip).length, 1);
  const g = fixture(t); g.service.apns = async () => ({ status: 410 }); await g.service.send(intent()); await g.service.drain();
  assert.equal(g.service.device('phone').enrollment.voipToken, null); assert.equal(g.service.device('phone').enrollment.alertToken, enrollment.alertToken);
});
test('ordinary calls retain outstanding safety but have no spacing or daily cap', async t => {
  const f = fixture(t); await f.service.send(intent());
  await f.service.send(intent('second')); assert.equal(f.target('second').reason, 'call-outstanding');
  assert.equal(f.target('second').state, 'not-called'); assert.equal(f.sent.length, 1);
  await f.service.event(f.device, { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID, event: 'answered' });
  await f.service.event(f.device, { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID, event: 'ended' });
  for (let n = 2; n <= 5; n++) {
    await f.service.send(intent('call-' + n));
    assert.equal(f.target('call-' + n).reason, 'urgent-eligible');
    await f.service.event(f.device, { reachoutID: 'call-' + n, callUUID: f.record('call-' + n).callUUID, event: 'answered' });
    await f.service.event(f.device, { reachoutID: 'call-' + n, callUUID: f.record('call-' + n).callUUID, event: 'ended' });
  }
  assert.ok(f.sent.every(s => s.voip));
});
test('notification budget does not block ordinary VoIP and duplicate/in-flight reservations remain exact', async t => {
  const f = fixture(t); f.service.config = { ...f.service.config, notificationsPerHour:0, callsPerDay:0, callSpacingMs:86400000 };
  await f.service.send(intent()); await f.service.drain();
  assert.equal(f.sent.length,1); assert.equal(f.sent[0].voip,true);
  assert.equal(f.target('need-1').reason,'urgent-eligible');
  assert.equal((await f.service.send(intent())).coalesced,true);
  await assert.rejects(f.service.send({...intent(),body:'different'}),{status:409});
  await f.service.send(intent('another')); await f.service.drain();
  assert.equal(f.sent.length,1);
  const g = fixture(t); g.service.openVoice = {hasReservation:()=>true};
  await g.service.send(intent()); assert.equal(g.target('need-1').reason,'call-outstanding');
});
test('revocation prevents fallback and device-bound receipts reject foreign identities', async t => {
  const f = fixture(t); await f.service.send(intent());
  await assert.rejects(f.service.event({ deviceID: 'foreign' }, { reachoutID: 'need-1', event: 'answered', callUUID: f.record('need-1').callUUID }));
  await assert.rejects(f.service.event(f.device, { reachoutID: 'need-1', event: 'answered', callUUID: crypto.randomUUID() }));
  f.revoke(); f.advance(45000); await f.service.recover(); assert.equal(f.sent.length, 1);
});
test('owner ordinary end reconciliation is exact, held, durable and distinct from native receipt', async t => {
  const f=fixture(t);await f.service.send(intent());await f.service.drain();
  await f.service.event(f.device,{reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'answered'});
  const request={id:'need-1',deviceID:'phone',callUUID:f.record('need-1').callUUID,provenance:'principal-confirmed ended'};
  let held=false,resource=0,others=0;
  f.service.maintenance={refresh:async()=>{},status:()=>({held,invalid:false,counts:{...f.service.localStats(),invitations:f.service.localStats().invitations+others,mediaSessions:resource}})};
  assert.throws(()=>f.service.reconcileEnded(request),/hold/);held=true;
  for(const patch of [{id:'wrong'},{deviceID:'foreign'},{callUUID:crypto.randomUUID()},{provenance:'native-ended'}])assert.throws(()=>f.service.reconcileEnded({...request,...patch}));
  f.record('need-1').openVoice={call_id:'pilot'};assert.throws(()=>f.service.reconcileEnded(request));delete f.record('need-1').openVoice;
  resource=1;assert.throws(()=>f.service.reconcileEnded(request),/draining/);resource=0;
  others=1;assert.throws(()=>f.service.reconcileEnded(request),/other ordinary/);others=0;
  const devices=JSON.stringify(f.service.store.data.devices), before=structuredClone(f.target('need-1'));
  const sender=await startSender(f.service);
  try {
    const result=await socketRequest(sender.socketPath,{command:'reconcile-ended',request},{projectRoot:f.root});
    assert.equal(result.nativeReceipt,'answered');assert.equal(result.ownerConfirmedEnd.provenance,'principal-confirmed ended');
    assert.equal(f.service.localStats().invitations,0);
    assert.deepEqual(f.target('need-1'),{...before,ownerConfirmedEnd:result.ownerConfirmedEnd});
    assert.equal(JSON.stringify(f.service.store.data.devices),devices);
    assert.equal(f.target('need-1').endedAt,undefined);assert.equal(f.target('need-1').terminalReceipt,undefined);
    assert.deepEqual(f.service.reconcileEnded(request),result);
    assert.deepEqual(new PushStore(f.dir).data.records['r:need-1'].targets['d:phone'].ownerConfirmedEnd,result.ownerConfirmedEnd);
    await assert.rejects(f.service.event(f.device,{reachoutID:'need-1',event:'ended',callUUID:request.callUUID,ownerConfirmedEnd:result.ownerConfirmedEnd}));
    await f.service.event(f.device,{reachoutID:'need-1',event:'ended',callUUID:request.callUUID});
    assert.equal(f.target('need-1').endedAt,f.options.now());assert.deepEqual(f.target('need-1').ownerConfirmedEnd,result.ownerConfirmedEnd);
  } finally {await sender.close();}
});
test('failed reconciliation persistence keeps the outstanding invitation',async t=>{
  const f=fixture(t);await f.service.send(intent());await f.service.drain();
  await f.service.event(f.device,{reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'answered'});
  f.service.maintenance={status:()=>({held:true,invalid:false,counts:f.service.localStats()})};
  const original=f.service.store.save;f.service.store.save=()=>{throw Error('disk failed')};
  assert.throws(()=>f.service.reconcileEnded({id:'need-1',deviceID:'phone',callUUID:f.record('need-1').callUUID,provenance:'principal-confirmed ended'}),/disk failed/);
  assert.equal(f.service.localStats().invitations,1);assert.equal(f.target('need-1').ownerConfirmedEnd,undefined);f.service.store.save=original;
});
test('owner calls switch rechecked before network while quiet boundary stays phone local', async t => {
  const f = fixture(t);
  const originalSave = f.service.store.save.bind(f.service.store); let updated = false;
  f.service.store.save = () => {
    originalSave();
    if (!updated && f.service.store.data.records['r:need-1']) {
      updated = true; f.service.config = { ...f.service.config, callsEnabled:false };
    }
  };
  await f.service.send(intent()); await f.service.drain(); assert.equal(f.sent.length, 0);
  assert.equal(f.target('need-1').state, 'not-called'); assert.equal(f.target('need-1').reason, 'calls-disabled');
  const g = fixture(t); g.setNow(Date.parse('2026-01-02T02:59:45Z'));
  await g.service.send(intent()); assert.equal(g.target('need-1').reason, 'urgent-eligible'); assert.equal(g.sent[0].voip, true);
});
test('phone quiet decline returns declared window without fallback or future server gate', async t => {
  const f = fixture(t); await f.service.send(intent()); await f.service.drain();
  const r = f.record('need-1');
  await f.service.event(f.device,{reachoutID:'need-1',callUUID:r.callUUID,event:'ended',endReason:'admissionRejected',quietUntil:f.options.now()+3600000,quietEnd:'08:00'});
  const status = f.service.status('need-1');
  assert.equal(status.disposition,'declined'); assert.equal(status.targets[0].message,'in quiet hours until 08:00');
  await f.service.recover(); await f.service.drain(); assert.equal(f.sent.length,1);
  assert.equal(f.target('need-1').reservedFallback,false);
});
test('all-day phone quiet decline has no invented end time or fallback', async t => {
  const f = fixture(t); await f.service.send(intent()); await f.service.drain();
  await f.service.event(f.device,{reachoutID:'need-1',callUUID:f.record('need-1').callUUID,event:'ended',endReason:'admissionRejected',quietEnd:'all-day'});
  assert.equal(f.service.status('need-1').targets[0].message,'in quiet hours all day');
  await f.service.recover(); await f.service.drain(); assert.equal(f.sent.length,1);
});
test('origin authority and chief rotation fail before persisted intent', async t => {
  const f = fixture(t);
  f.service.validateOrigin = async () => { throw Object.assign(Error('unbound message'), { status: 409 }); };
  await assert.rejects(f.service.send({ ...intent(), messageID: 'msg_wrong' }), /unbound/);
  f.service.validateOrigin = async () => { f.service.chief = () => 'ses_new'; };
  await assert.rejects(f.service.send(intent()), /chief changed/); assert.equal(f.sent.length, 0); assert.equal(f.service.records().length, 0);
});
test('legacy crash-uncertain fallback is never re-sent; short call expiry does not expire detail lookup', async t => {
  const f = fixture(t); await f.service.send({ ...intent(), expiresIn: 30 });
  f.advance(45000); await f.service.recover();
  assert.equal(f.service.lookup(f.device, 'need-1').callExpiry < f.options.now(), true);
  // An old (pre-Nod) record left with a queued fallback settles as uncertain, never sends.
  f.target('need-1').fallback = { state: 'dispatch-queued', reservedAt: f.options.now() }; f.service.store.save();
  const restarted = new PushService({ ...f.options, store: new PushStore(f.dir) }); await restarted.recover();
  assert.equal(f.sent.length, 1); assert.equal(restarted.store.data.records['r:need-1'].targets['d:phone'].fallback.state, 'delivery-unknown');
  restarted.store.save = () => { throw Error('idle recovery must not keep writing expired records'); };
  await restarted.recover();
  f.advance(3600000); assert.throws(() => restarted.lookup(f.device, 'need-1'), /expired/);
});
test('answered calls stay outstanding until End, even beyond spacing', async t => {
  const f = fixture(t); await f.service.send(intent());
  const receipt = { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID };
  await f.service.event(f.device, { ...receipt, event: 'answered' }); f.advance(900000);
  await f.service.send(intent('blocked')); assert.equal(f.target('blocked').reason, 'call-outstanding');
  await f.service.event(f.device, { ...receipt, event: 'ended' });
  await f.service.send(intent('allowed')); assert.equal(f.sent.at(-1).voip, true);
});
test('call ledger is persistent across restart; a missing VoIP token reports not called, never a notification', async t => {
  const f = fixture(t); await f.service.send(intent());
  const restarted = new PushService({ ...f.options, store: new PushStore(f.dir) });
  assert.equal((await restarted.send(intent())).coalesced, true); assert.equal(f.sent.length, 1);
  await restarted.event(f.device, { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID, event: 'ended' });
  restarted.update(f.device, 'enrollment', { ...enrollment, revision: 2, voipToken: null, alertToken: null });
  await restarted.send(intent('no-token')); assert.equal(f.sent.length, 1);
  const t2 = restarted.store.data.records['r:no-token'].targets['d:phone'];
  assert.equal(t2.state, 'not-called'); assert.equal(t2.reason, 'no-voip-token');
  assert.throws(() => restarted.update(f.device, 'enrollment', enrollment), /stale/);
});
test('socket recovers a stale endpoint and private storage refuses symlinks', async t => {
  const f = fixture(t), sender = await startSender(f.service);
  await sender.close();
  const child = spawnSync(process.execPath, ['--input-type=module', '-e',
    "import net from 'node:net'; import fs from 'node:fs'; const p=process.argv[1]; net.createServer().listen(p,()=>{fs.chmodSync(p,0o600);process.exit(0)});", sender.socketPath]);
  assert.equal(child.status, 0); assert.equal(fs.existsSync(sender.socketPath), true);
  fs.chmodSync(sender.socketPath, 0o644); await assert.rejects(startSender(f.service), /private/); fs.chmodSync(sender.socketPath, 0o600);
  const second = await startSender(new PushService({ ...f.options, store: new PushStore(f.dir) })); await second.close();
  const link = path.join(f.dir, 'linked'); fs.symlinkSync(f.dir, link);
  assert.throws(() => new PushStore(link), /private/);
});
test('CLI dry-run is completely offline and exact flag parser rejects duplicates', async () => {
  const flags = ['send', '--kind', 'urgent-call', '--reason', 'decision', '--session', 'ses_chief', '--id', 'unlock-1', '--title', 'Decision needed', '--body', 'Please decide.', '--dry-run'];
  assert.equal((await main(flags)).disposition, 'dry-run');
  assert.throws(() => parseArgs([...flags, '--id', 'duplicate']));
  assert.throws(() => parseArgs(['status', '--id', 'a', '--body', 'bad']));
  assert.throws(() => parseArgs([...flags, '--test-approval', '/private/retired.json']));
  assert.throws(() => parseArgs([...flags, '--url', 'itms-services://?action=download-manifest&url=x']));
  assert.throws(() => parseArgs(['dev-override', 'status']));
});
test('Unix socket permissions, protocol schema, status, restart, and no HTTP sender route', async t => {
  const f = fixture(t); const sender = await startSender(f.service); t.after(() => sender.close());
  assert.equal(fs.statSync(sender.socketPath).mode & 0o777, 0o600);
  await assert.rejects(startSender(f.service), /already running/);
  const invalid = await socketRequest(sender.socketPath, { command: 'send', request: { ...intent(), kind: 'milestone' } }, { projectRoot: f.root }); assert.equal(invalid.status, 400);
  const retired = await socketRequest(sender.socketPath, { command: 'send', request: intent(), testApproval: '/private/retired.json' }, { projectRoot: f.root });
  assert.equal(retired.status, 400); assert.equal(f.sent.length, 0);
  await socketRequest(sender.socketPath, { command: 'send', request: intent() }, { projectRoot: f.root });
  assert.equal((await socketRequest(sender.socketPath, { command: 'status', id: 'need-1' }, { projectRoot: f.root })).id, 'need-1');
  const file = path.join(f.dir, 'credentials-test.json'), bearer = 'z'.repeat(43);
  fs.writeFileSync(file, JSON.stringify({ devices: { [crypto.createHash('sha256').update(bearer).digest('hex')]: { deviceID: 'phone' },
    [crypto.createHash('sha256').update('t'.repeat(43)).digest('hex')]: { deviceID: 'test', test: { sessionID: 'ses_test', expires: Date.now() + 100000 } } } }), { mode: 0o600 });
  const bridge = createBridge({ credentials: new Credentials(file), ...unpairedDesktop(t), push: f.service }); await new Promise(resolve => bridge.listen(0, '127.0.0.1', resolve));
  t.after(() => bridge.shutdown());
  async function call(route, method = 'GET', data, auth = bearer) {
    const response = await fetch(`http://127.0.0.1:${bridge.address().port}/floating-voice/v1/push/${route}`, { method,
      headers: { authorization: 'Bearer ' + auth, ...(data ? { 'content-type': 'application/json' } : {}) }, body: data ? JSON.stringify(data) : undefined });
    return { status: response.status, value: await response.json() };
  }
  for (const route of ['send', 'sender', 'status', 'urgent-call']) assert.equal((await call(route, 'POST', intent())).status, 404);
  assert.equal((await call('settings', 'GET', undefined, 'wrong')).status, 401);
  assert.equal((await call('enrollment', 'PUT', enrollment, 't'.repeat(43))).status, 403);
  assert.equal((await call('settings')).status, 200);
  assert.equal((await call('settings', 'PUT', { ...settings, revision: 2 })).status, 200);
  assert.equal((await call('settings', 'PUT', settings)).status, 409);
  assert.equal((await call('enrollment', 'PUT', { ...enrollment, revision: 2, voipToken: null })).status, 200);
  assert.equal((await call('reachouts/need-1')).value.session, 'ses_chief');
  assert.equal((await call('events', 'POST', { reachoutID: 'need-1', callUUID: f.record('need-1').callUUID, event: 'answered' })).status, 200);
  assert.equal((await call('settings', 'PUT', { ...settings, padding: 'x'.repeat(4096) })).status, 413);
  assert.equal(f.sent.length, 1);
});
test('APNs HTTP/2 uses generated throwaway ES256 key, correct topics, environments and expiration', async t => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const encoded = jwt(privateKey, 1000000), [a, b, c] = encoded.split('.');
  assert.equal(Buffer.from(c, 'base64url').length, 64);
  assert.equal(crypto.verify('sha256', Buffer.from(a + '.' + b), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(c, 'base64url')), true);
  const seen = [], origins = [], server = http2.createServer();
  server.on('stream', (stream, headers) => {
    const chunks = []; stream.on('data', c => chunks.push(c)); stream.on('end', () => { seen.push({ headers, payload: JSON.parse(Buffer.concat(chunks)) }); stream.respond({ ':status': seen.length === 3 ? 410 : 200 }); stream.end('{}'); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => new Promise(resolve => server.close(resolve)));
  const apns = createAPNs({ readKey: () => privateKey, now: () => 1000000, connect: origin => { origins.push(origin); return http2.connect(`http://127.0.0.1:${server.address().port}`); } });
  for (const [voip, environment] of [[true, 'sandbox'], [false, 'production'], [true, 'sandbox']]) {
    const result = await apns({ token: 'f'.repeat(64), voip, environment, payload: { reachoutID: 'synthetic' }, collapseID: 'same-id' }); assert.equal(result.status, seen.length === 3 ? 410 : 200);
  }
  assert.deepEqual(origins, ['https://api.sandbox.push.apple.com', 'https://api.push.apple.com', 'https://api.sandbox.push.apple.com']);
  assert.equal(seen[0].headers['apns-expiration'], '0'); assert.equal(seen[0].headers['apns-topic'], CONFIG.topic + '.voip');
  assert.equal(seen[1].headers['apns-push-type'], 'alert'); assert.equal(seen[1].headers['apns-topic'], CONFIG.topic);
  assert.equal(seen[1].headers['apns-collapse-id'].length, 64);
});
test('fake APNs connection loss is uncertain, sanitized, and never retried by transport', async t => {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const server = http2.createServer(); let attempts = 0;
  server.on('stream', stream => { attempts++; stream.session.destroy(); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => new Promise(resolve => server.close(resolve)));
  const apns = createAPNs({ readKey: () => privateKey, connect: () => http2.connect(`http://127.0.0.1:${server.address().port}`) });
  await assert.rejects(apns({ token: 'f'.repeat(64), environment: 'sandbox', voip: true, payload: {}, collapseID: 'test' }), /^Error: APNs delivery unknown$/);
  assert.equal(attempts, 1);
});
