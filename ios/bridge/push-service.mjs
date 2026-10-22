import crypto from 'node:crypto';
import http from 'node:http';
import { CONFIG, requireThat, exact, stableID, sendSchema, enrollmentSchema, settingsSchema, callPolicy, localParts, validZone } from './reachout-policy.mjs';

const canonical = o => JSON.stringify(Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b))));
const dk = id => 'd:' + id, rk = id => 'r:' + id;
const endReasons = ['requested','declined','ringExpired','admissionRejected','reportRejected','providerReset','answerTimeout','answerFailed','readinessTimeout','actionTimeout','mediaFailed','mediaReset','policyRestricted','targetChanged'];
const endInitiators = ['app','systemEndAction','providerReset','reportFailure','ringDeadline','answerDeadline','readinessDeadline','actionTimeout','mediaFailure','mediaReset','policyChange','targetChange'];
// One cheap request through each idle proxy counts as model use (idle_proxy.py
// proxy(): pins, ensure_loaded, refreshes last_used). /health is NOT proxied.
export function touchSpeech() {
  const get = (port, path) => new Promise(resolve => {
    const req = http.get({ host: '127.0.0.1', port, path, agent: false }, res => { res.resume(); res.on('end', resolve); res.on('error', resolve); });
    req.setTimeout(5000, () => req.destroy()); req.on('error', resolve); req.on('close', resolve);
  });
  return Promise.all([get(8446, '/v1/transcribe'), get(8450, '/v1/voices')]);
}
const reportFailures = ['filteredByDoNotDisturb','filteredByBlockList','callUUIDAlreadyExists','maximumCallGroupsReached','unentitled','other'];
export class PushService {
  constructor({ store, apns, chief, activeDevices, validateOrigin = async () => {}, config = CONFIG, now = Date.now, diagnostic = () => {},
    speechKeepalive = touchSpeech, keepaliveMs = 240000 }) {
    Object.assign(this, { store, apns, chief, activeDevices, validateOrigin, config, now, diagnostic, speechKeepalive, keepaliveMs });
    this.keepalives = new Map();
    this.queue = Promise.resolve();
    // One bounded call lane: Voicestack sends no alert notifications (Nod handles
    // messages). Only state transitions use serial(); HTTP/2 promises never hold it.
    this.lanes = { call: { active: 0, queue: [] } };
    this.jobs = new Set(); this.network = new Set();
  }
  serial(work, internal = false) {
    if (!internal && (this.pending ?? 0) >= 32) return Promise.reject(Object.assign(new Error('push work limit'), { status: 429 }));
    this.pending = (this.pending ?? 0) + 1;
    const next = this.queue.then(work).finally(() => { this.pending--; }); this.queue = next.catch(() => {}); return next;
  }
  device(id) { return this.store.data.devices[dk(id)] ??= {}; }
  records() { return Object.values(this.store.data.records); }
  save(record) {
    // Shared delivery helpers must use candidate durability/poison semantics too.
    if (record.openVoice) { requireThat(this.openVoice, 503); this.openVoice.save(); }
    else this.store.save();
  }
  // Only the installed candidate authority can enter this path; never impersonate chief.
  requestOpenVoice(authority, input) {
    requireThat(authority === this.openVoice && authority, 403);
    return authority.request(input);
  }
  update(device, kind, input) {
    requireThat(!device.test, 403, 'test identities cannot use push');
    const value = kind === 'settings' ? settingsSchema(input) : enrollmentSchema(input);
    const d = this.device(device.deviceID), previous = d[kind];
    // Closed diagnostics distinguish refusals without logging tokens, policy values or request text.
    const revisionRefused = category => {
      try { this.diagnostic({ stage: 'push', category, kind: kind === 'settings' ? 'settings' : 'enrollment', status: 409,
        incomingRevision: value.revision, storedRevision: previous.revision }); } catch { /* logging cannot change admission */ }
    };
    if (previous && value.revision < previous.revision) revisionRefused('stale_revision');
    requireThat(!previous || value.revision >= previous.revision, 409, 'stale revision');
    if (previous && value.revision === previous.revision) {
      const { syncedAt, ...old } = previous;
      const identical = canonical(value) === canonical(old);
      if (!identical) revisionRefused('revision_conflict');
      requireThat(identical, 409, 'revision conflict');
      // A repeated, identical settings snapshot is an explicit fresh acknowledgement.
    }
    d[kind] = { ...value, syncedAt: this.now() }; this.store.save();
    return kind === 'settings' ? d.settings : { revision: value.revision, syncedAt: d[kind].syncedAt };
  }
  lookup(device, id) {
    requireThat(!device.test, 403);
    requireThat(stableID(id));
    const record = this.store.data.records[rk(id)];
    requireThat(record?.targets[dk(device.deviceID)], 404, 'reach-out unavailable');
    if (record.openVoice) {
      requireThat(this.openVoice, 503);
      this.openVoice.readLimit('device:' + device.deviceID);
      this.openVoice.recover();
      requireThat(this.openVoice.current(this.openVoice.state.calls['v:' + record.openVoice]), 403);
      return this.openVoice.recipient(device, record.openVoice);
    }
    requireThat(record.expiry > this.now(), 410, 'reach-out expired');
    return { ...record.request, reachoutID: id, callUUID: record.callUUID, expiry: record.expiry, callExpiry: record.callExpiry,
      state: record.targets[dk(device.deviceID)].state };
  }
  status(id) {
    requireThat(stableID(id));
    const r = this.store.data.records[rk(id)]; requireThat(r, 404, 'unknown reach-out');
    const targets = Object.values(r.targets).map(t => ({ disposition: t.receipt ?? t.state, delivery: t.state, policyReason: t.reason,
      ...(t.ownerConfirmedEnd ? { ownerConfirmedEnd:t.ownerConfirmedEnd } : {}),
      ...(t.quietEnd ? { quietUntil:t.quietUntil, message:t.quietEnd === 'all-day' ? 'in quiet hours all day' : `in quiet hours until ${t.quietEnd}` } : {}),
      ...(t.terminalReceipt?.endReason ? { endReason: t.terminalReceipt.endReason } : {}),
      fallback: t.fallback?.state, receipt: t.receipt, opened: t.openedAt !== undefined, ringDeadline: t.ringDeadline,
      ...(t.override === 'dev' ? { override: 'dev' } : {}) }));
    return { id, disposition: targets.length === 1 ? targets[0].disposition : 'multiple-devices',
      policyReason: targets.length === 1 ? targets[0].policyReason : 'per-device', targets };
  }
  counts(deviceID, now, zone) {
    const targets = this.records().map(r => r.targets[dk(deviceID)]).filter(Boolean);
    const calls = targets.filter(t => t.callAttemptAt !== undefined);
    return { calls, daily: calls.filter(t => localParts(t.callAttemptAt, zone).day === localParts(now, zone).day).length };
  }
  async send(input, dryRun = false) {
    this.maintenance?.requireOpen();
    this.activeSends = (this.activeSends ?? 0) + 1;
    try {
      const request = sendSchema(input, this.config);
      requireThat(this.chief() === request.session, 409, 'origin is not current chief');
      if (!dryRun) await this.validateOrigin(request);
      // No await within admit: one run-to-completion durable state turn. Production
      // origin lookups happen outside serial(), so they cannot hold receipt/deadline work.
      return this.admit(request, dryRun);
    } finally { this.activeSends--; }
  }
  localStats() {
    const now = this.now();
    return { senderWork: this.activeSends ?? 0, pushPending: this.pending ?? 0,
      pushJobs: this.jobs.size, pushNetwork: this.network.size,
      pushLanes: Object.values(this.lanes).reduce((n, l) => n + l.active + l.queue.length, 0),
      invitations: this.records().reduce((n, r) => n + (r.openVoice ? 0 : Object.values(r.targets).filter(t =>
        t.callAttemptAt !== undefined && (t.receipt === 'answered' ? t.endedAt === undefined && !t.ownerConfirmedEnd
          : !['declined', 'ended', 'report-failed', 'expired'].includes(t.receipt) && now < t.ringDeadline)).length), 0),
      candidateCalls: Object.values(this.openVoice?.state.calls ?? {}).filter(c => !['ended', 'rejected', 'expired'].includes(c.state)).length,
      candidateFallbacks: 0, // No missed-call fallback notifications exist any more; key kept for status shape.
      candidateResolves: this.openVoice?.resolving ?? 0, endNotes: this.openVoice?.pendingEndNotes ?? 0 };
  }
  reconcileEnded(o) {
    exact(o,['id','deviceID','callUUID','provenance']);
    requireThat(stableID(o.id) && stableID(o.deviceID) && o.provenance === 'principal-confirmed ended',400);
    const r = this.store.data.records[rk(o.id)], t = r?.targets?.[dk(o.deviceID)];
    requireThat(r && !r.openVoice && r.request?.kind === 'urgent-call' && r.callUUID === o.callUUID
      && Object.keys(r.targets).length === 1 && t?.receipt === 'answered' && t.voipAttemptedAt !== undefined,409,'ordinary answered call binding required');
    requireThat(this.activeDevices().some(d => !d.test && d.deviceID === o.deviceID),409,'own paired device required');
    const s = this.maintenance?.status();
    requireThat(s?.held === true && s.invalid === false && !this.maintenance.changing && !this.maintenance.sealing,409,'stable owner hold required');
    requireThat(Object.entries(s.counts).every(([k,v]) => k === 'invitations' || v === 0),409,'real work still draining');
    requireThat(s.counts.invitations === (t.endedAt === undefined && !t.ownerConfirmedEnd ? 1 : 0),409,'other ordinary call outstanding');
    if (!t.ownerConfirmedEnd) {
      requireThat(t.endedAt === undefined,409,'native end already received');
      t.ownerConfirmedEnd = { provenance:o.provenance, at:this.now(), callUUID:o.callUUID, ownerUID:process.getuid() };
      try { this.store.save(); } catch (error) { delete t.ownerConfirmedEnd; throw error; }
    }
    this.keepSpeechWarm(o.id, o.deviceID);
    // Never fabricate endedAt, a device receipt, media success, or pilot authority.
    return { id:o.id, nativeReceipt:t.receipt, ownerConfirmedEnd:t.ownerConfirmedEnd };
  }
  admit(request, dryRun) {
    requireThat(this.chief() === request.session, 409, 'chief changed during validation');
    const now = this.now();
    const old = this.store.data.records[rk(request.id)];
    if (old) { requireThat(canonical(old.request) === canonical(request), 409, 'id bound to different intent'); return { ...this.status(request.id), coalesced: true }; }
    requireThat(this.records().length < this.config.maxRecords, 429, 'reach-out ledger full');
    const targets = {};
    for (const device of this.activeDevices().filter(d => !d.test)) {
      const d = this.store.data.devices[dk(device.deviceID)];
      if (!d?.enrollment) continue;
      // Ordinary Chief calls: quiet hours and local Calls toggle belong to the
      // receiving phone. No cached timezone/freshness policy gates this route.
      let reason = this.config.callsEnabled ? 'urgent-eligible' : 'calls-disabled';
      const count = this.counts(device.deviceID, now, validZone(d.settings?.timeZone) ? d.settings.timeZone : 'UTC');
      if (reason === 'urgent-eligible') {
        if (!d.enrollment.voipToken) reason = 'no-voip-token';
        else if (this.openVoice?.hasReservation()) reason = 'call-outstanding';
        else if (count.calls.some(t => t.receipt === 'answered' ? t.endedAt === undefined && !t.ownerConfirmedEnd
          : !['declined', 'ended', 'expired', 'report-failed'].includes(t.receipt) && now < t.fallbackDeadline)) reason = 'call-outstanding';
        // Completed ordinary calls impose no count or spacing restriction.
        // Duplicate IDs and live call reservations still fence delivery above.
      }
      const call = reason === 'urgent-eligible';
      // A call that cannot be placed is reported, never turned into a notification.
      targets[dk(device.deviceID)] = { deviceID: device.deviceID, reason, state: call ? 'call-intent' : 'not-called',
        ...(call ? { callAttemptAt: now, ringDeadline: now + this.config.ringMs, fallbackDeadline: now + this.config.fallbackMs } : {}) };
    }
    requireThat(Object.keys(targets).length, 409, 'no enrolled paired device');
    if (dryRun) return { id: request.id, disposition: 'dry-run', policyReason: 'validated', targets: Object.values(targets).map(t => ({ disposition: t.state, policyReason: t.reason })) };
    const record = { request, createdAt: now, expiry: now + this.config.notificationTTL * 1000,
      callUUID: crypto.randomUUID(), callExpiry: now + (request.expiresIn ?? 60) * 1000, targets };
    this.store.data.records[rk(request.id)] = record;
    this.store.save(); // Commit ALL intents before any external side effect.
    for (const t of Object.values(targets)) if (t.state === 'call-intent') this.deliver(record, t, true);
    return this.status(request.id);
  }
  jobKey(r, t, lane) { return `${r.request.id}:${t.deviceID}:${lane}`; }
  deliver(r, t) { // Call (VoIP) pushes only.
    const lane = this.lanes.call, key = this.jobKey(r, t, 'call');
    if (this.jobs.has(key)) return;
    if (lane.queue.length >= this.config.dispatchQueueLimit) { t.state = 'dispatch-limit'; this.save(r); return; }
    this.jobs.add(key); lane.queue.push({ r, t, key }); this.pump(lane);
  }
  pump(lane) {
    while (lane.active < this.config.dispatchConcurrency && lane.queue.length) {
      const job = lane.queue.shift(); lane.active++;
      let delivery;
      try { delivery = this.beginDelivery(job.r, job.t); }
      catch { delivery = null; /* An intent without a network result remains uncertain. */ }
      if (!delivery) { lane.active--; this.jobs.delete(job.key); continue; }
      const done = result => this.serial(() => {
        try { delivery.finish(result); }
        finally { lane.active--; this.jobs.delete(job.key); this.pump(lane); }
      }, true);
      const work = delivery.pending.then(done, () => done(null));
      this.network.add(work); work.catch(() => {}).finally(() => this.network.delete(work));
    }
  }
  async drain() { // Test/shutdown observation only; never used by request/state queues.
    while (this.network.size) await Promise.allSettled([...this.network]);
    await this.queue;
  }
  beginDelivery(r, t) {
    if (r.openVoice) return this.openVoice?.delivery(r, t, true, false);
    // Recheck pairing at each network boundary; revoked devices receive nothing further.
    if (!this.activeDevices().some(d => !d.test && d.deviceID === t.deviceID)) { t.state = 'revoked'; this.save(r); return; }
    const d = this.device(t.deviceID), enrollment = d.enrollment, token = enrollment?.voipToken;
    if (!token) { t.state = 'no-token'; this.save(r); return; }
    let reason = this.config.callsEnabled ? 'urgent-eligible' : 'calls-disabled';
    if (this.openVoice?.hasReservation()) reason = 'call-outstanding';
    if (this.now() >= r.callExpiry) reason = 'call-expired';
    if (reason !== 'urgent-eligible') { t.reason = reason; t.state = 'not-called'; delete t.callAttemptAt; this.save(r); return; }
    t.callAttemptAt = this.now(); t.ringDeadline = Math.min(this.now() + this.config.ringMs, r.callExpiry);
    t.fallbackDeadline = this.now() + this.config.fallbackMs;
    t.voipAttemptedAt = this.now(); this.save(r);
    const payload = { aps: {}, reachoutID: r.request.id, callUUID: r.callUUID, expiry: r.callExpiry, ringDeadline: t.ringDeadline };
    // Token snapshot exists only in memory, never in the durable intent or results.
    let pending;
    try { pending = Promise.resolve(this.apns({ token, environment: enrollment.environment, voip: true, payload, collapseID: r.request.id })); }
    catch { pending = Promise.resolve(null); }
    return { pending, finish: result => {
      t.state = !result ? 'delivery-unknown' : result.status === 200 ? 'apns-accepted' : 'apns-rejected';
      if (result?.status === 410 && d.enrollment.voipToken === token && d.enrollment.revision === enrollment.revision && d.enrollment.environment === enrollment.environment) d.enrollment.voipToken = null;
      this.save(r);
    } };
  }
  // Answered, not-ended ordinary call: keep STT and Breeze loaded. Each tick
  // re-reads durable state and stops itself at any end/confirmed end.
  keepSpeechWarm(id, deviceID) {
    const key = id + ':' + deviceID;
    const live = () => {
      const r = this.store.data.records[rk(id)], t = r?.targets?.[dk(deviceID)];
      return !!r && !r.openVoice && r.request?.kind === 'urgent-call' && t?.receipt === 'answered'
        && t.endedAt === undefined && !t.ownerConfirmedEnd;
    };
    const stop = () => { clearInterval(this.keepalives.get(key)); this.keepalives.delete(key); };
    if (!live()) { if (this.keepalives.has(key)) stop(); return; }
    if (this.keepalives.has(key)) return;
    const started = this.now();
    const timer = setInterval(() => {
      if (!live() || this.now() - started > 4 * 3600000) { stop(); return; }
      try { Promise.resolve(this.speechKeepalive()).catch(() => {}); } catch {}
    }, this.keepaliveMs);
    timer.unref?.();
    this.keepalives.set(key, timer);
  }
  async event(device, o) {
    requireThat(!device.test, 403); exact(o, ['reachoutID', 'callUUID', 'event','endReason','endInitiator','reportedRinging','reportFailure','reportErrorCode','quietUntil','quietEnd']);
    if (o.quietUntil !== undefined || o.quietEnd !== undefined) requireThat(o.event === 'ended' && o.endReason === 'admissionRejected'
      && ((o.quietEnd === 'all-day' && o.quietUntil === undefined)
        || (Number.isFinite(o.quietUntil) && o.quietUntil > 0 && o.quietUntil <= this.now() + 48*3600000
          && typeof o.quietEnd === 'string' && /^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(o.quietEnd))), 400);
    requireThat(stableID(o.reachoutID) && ['reported', 'ringing', 'answered', 'declined', 'ended', 'report-failed', 'notification-opened'].includes(o.event));
    requireThat(o.endReason === undefined || endReasons.includes(o.endReason));
    requireThat(o.endInitiator === undefined || endInitiators.includes(o.endInitiator));
    requireThat(o.reportFailure === undefined || reportFailures.includes(o.reportFailure));
    requireThat(o.reportedRinging === undefined || typeof o.reportedRinging === 'boolean');
    requireThat(o.reportErrorCode === undefined || Number.isSafeInteger(o.reportErrorCode) && Math.abs(o.reportErrorCode) <= 2147483647);
    const r = this.store.data.records[rk(o.reachoutID)], t = r?.targets[dk(device.deviceID)];
    requireThat(t, 404, 'reach-out unavailable');
    if (r.openVoice) { requireThat(this.openVoice, 503); return this.openVoice.receipt(device, r, t, o); }
    // 'notification-opened' stays accepted: an older app may still flush one from its outbox.
    if (o.event !== 'notification-opened') requireThat(t.voipAttemptedAt !== undefined && o.callUUID === r.callUUID, 409, 'call binding mismatch');
    else requireThat(o.callUUID === undefined || o.callUUID === r.callUUID);
    if (o.event === 'reported') t.reportedAt ??= this.now();
    if (o.event === 'ringing') t.ringingAt ??= this.now();
    if (o.event === 'notification-opened') t.openedAt ??= this.now();
    else if (o.event === 'answered') {
      if (['declined','ended','report-failed'].includes(t.receipt)) return { acknowledged:true };
      t.receipt = 'answered'; t.reservedFallback = false;
    }
    else if (['declined', 'report-failed'].includes(o.event)) {
      if (t.receipt === 'answered') return { acknowledged: true };
      // A durable terminal receipt may arrive after timeout/fallback. Replace the
      // guessed expiration with that truth, without creating another fallback.
      if (!['declined','report-failed','ended'].includes(t.receipt)) t.receipt = o.event;
    }
    else if (!['answered', 'declined', 'ended', 'report-failed', 'expired'].includes(t.receipt)) t.receipt = o.event;
    if (o.event === 'ended' && !['answered','declined','report-failed'].includes(t.receipt)) t.receipt = 'ended';
    if (o.event === 'ended') t.endedAt ??= this.now();
    if (o.quietEnd !== undefined && t.receipt !== 'answered') {
      t.quietUntil = o.quietUntil; t.quietEnd = o.quietEnd; t.reason = 'phone-quiet-hours'; t.receipt = 'declined'; t.reservedFallback = false;
    }
    if (['declined','ended','report-failed'].includes(o.event)) {
      t.terminalReceipt ??= { event:o.event, at:this.now(), ...Object.fromEntries(['endReason','endInitiator','reportedRinging','reportFailure','reportErrorCode'].filter(k=>o[k]!==undefined).map(k=>[k,o[k]])) };
    }
    this.store.save();
    this.keepSpeechWarm(o.reachoutID, device.deviceID);
    return { acknowledged: true };
  }
  async recover() {
    try { this.openVoice?.recover(); } catch { /* Candidate failure must not stop legacy deadlines. */ }
    for (const r of this.records()) for (const t of Object.values(r.targets)) {
      if (r.openVoice) continue;
      // Legacy notification records (before Nod) settle as uncertain; nothing is re-sent.
      for (const kind of ['alert', 'fallback']) {
        const item = t[kind];
        if (item?.state === 'dispatch-queued' && !this.jobs.has(this.jobKey(r, t, kind))) {
          item.state = 'delivery-unknown'; item.attemptAt = item.reservedAt; this.store.save();
        }
      }
      if (t.state === 'notification-intent') { t.state = 'delivery-unknown'; this.store.save(); }
      if (t.callAttemptAt === undefined) continue;
      if (t.voipAttemptedAt === undefined && this.jobs.has(this.jobKey(r, t, 'call'))) continue;
      if (t.state === 'call-intent') { t.state = 'delivery-unknown'; this.store.save(); }
      if (t.receipt === 'answered') continue;
      if (this.now() >= t.ringDeadline && !['declined', 'ended', 'report-failed', 'expired'].includes(t.receipt)) { t.receipt = 'expired'; this.store.save(); }
    }
  }
}
