import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import { CONFIG, requireThat, exact, stableID, sendSchema, enrollmentSchema, settingsSchema, callPolicy, localParts, validZone } from './reachout-policy.mjs';
import { readDevOverride } from './dev-override.mjs';

const canonical = o => JSON.stringify(Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b))));
const { assistantLabel } = JSON.parse(readFileSync(new URL('../shared/presentation.json', import.meta.url), 'utf8'));
const dk = id => 'd:' + id, rk = id => 'r:' + id;
const endReasons = ['requested','declined','ringExpired','admissionRejected','reportRejected','providerReset','answerTimeout','answerFailed','readinessTimeout','actionTimeout','mediaFailed','mediaReset','policyRestricted','targetChanged'];
const endInitiators = ['app','systemEndAction','providerReset','reportFailure','ringDeadline','answerDeadline','readinessDeadline','actionTimeout','mediaFailure','mediaReset','policyChange','targetChange'];
const reportFailures = ['filteredByDoNotDisturb','filteredByBlockList','callUUIDAlreadyExists','maximumCallGroupsReached','unentitled','other'];
export class PushService {
  constructor({ store, apns, chief, activeDevices, validateOrigin = async () => {}, config = CONFIG, now = Date.now, diagnostic = () => {} }) {
    Object.assign(this, { store, apns, chief, activeDevices, validateOrigin, config, now, diagnostic });
    this.queue = Promise.resolve();
    // Independent bounded lanes reserve capacity for fallbacks. Only state transitions
    // use serial(); HTTP/2 promises never hold that queue.
    this.lanes = Object.fromEntries(['alert', 'call', 'fallback'].map(k => [k, { active: 0, queue: [] }]));
    this.jobs = new Set(); this.network = new Set();
  }
  serial(work, internal = false) {
    if (!internal && (this.pending ?? 0) >= 32) return Promise.reject(Object.assign(new Error('push work limit'), { status: 429 }));
    this.pending = (this.pending ?? 0) + 1;
    const next = this.queue.then(work).finally(() => { this.pending--; }); this.queue = next.catch(() => {}); return next;
  }
  device(id) { return this.store.data.devices[dk(id)] ??= {}; }
  records() { return Object.values(this.store.data.records); }
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
    requireThat(record.expiry > this.now(), 410, 'reach-out expired');
    return { ...record.request, reachoutID: id, callUUID: record.callUUID, expiry: record.expiry, callExpiry: record.callExpiry,
      state: record.targets[dk(device.deviceID)].state };
  }
  status(id) {
    requireThat(stableID(id));
    const r = this.store.data.records[rk(id)]; requireThat(r, 404, 'unknown reach-out');
    const targets = Object.values(r.targets).map(t => ({ disposition: t.receipt ?? t.state, delivery: t.state, policyReason: t.reason,
      fallback: t.fallback?.state, receipt: t.receipt, opened: t.openedAt !== undefined, ringDeadline: t.ringDeadline,
      ...(t.override === 'dev' ? { override: 'dev' } : {}) }));
    return { id, disposition: targets.length === 1 ? targets[0].disposition : 'multiple-devices',
      policyReason: targets.length === 1 ? targets[0].policyReason : 'per-device', targets };
  }
  counts(deviceID, now, zone) {
    const targets = this.records().map(r => r.targets[dk(deviceID)]).filter(Boolean);
    const calls = targets.filter(t => t.callAttemptAt !== undefined);
    const recentOrReserved = item => item && ((item.attemptAt === undefined && item.state === 'dispatch-queued')
      || now - (item.attemptAt ?? item.reservedAt) < 3600000);
    const notifications = targets.filter(t => recentOrReserved(t.alert) || recentOrReserved(t.fallback) || (t.reservedFallback && !t.fallback));
    return { calls, notifications: notifications.length, daily: calls.filter(t => localParts(t.callAttemptAt, zone).day === localParts(now, zone).day).length };
  }
  async send(input, dryRun = false) {
    const request = sendSchema(input, this.config);
    requireThat(this.chief() === request.session, 409, 'origin is not current chief');
    if (!dryRun) await this.validateOrigin(request);
    // No await within admit: one run-to-completion durable state turn. Production
    // origin lookups happen outside serial(), so they cannot hold receipt/deadline work.
    return this.admit(request, dryRun);
  }
  admit(request, dryRun) {
    requireThat(this.chief() === request.session, 409, 'chief changed during validation');
    const now = this.now(), override = readDevOverride(this.store.directory, now);
    const old = this.store.data.records[rk(request.id)];
    if (old) { requireThat(canonical(old.request) === canonical(request), 409, 'id bound to different intent'); return { ...this.status(request.id), coalesced: true }; }
    requireThat(this.records().length < this.config.maxRecords, 429, 'reach-out ledger full');
    const targets = {};
    for (const device of this.activeDevices().filter(d => !d.test)) {
      const d = this.store.data.devices[dk(device.deviceID)];
      if (!d?.enrollment) continue;
      let reason = request.kind === 'urgent-call' ? callPolicy(d.settings, now, this.config) : 'ordinary';
      // Do not begin ringing across the next quiet-hours boundary.
      if (reason === 'urgent-eligible' && callPolicy(d.settings, now + this.config.ringMs, this.config) !== 'urgent-eligible') reason = 'quiet-boundary';
      const count = this.counts(device.deviceID, now, validZone(d.settings?.timeZone) ? d.settings.timeZone : 'UTC');
      let overrideUsed = false;
      if (reason === 'urgent-eligible') {
        if (!d.enrollment.voipToken) reason = 'no-voip-token';
        else if (count.calls.some(t => t.receipt === 'answered' ? t.endedAt === undefined
          : !['declined', 'ended', 'expired', 'report-failed'].includes(t.receipt) && now < t.fallbackDeadline)) reason = 'call-outstanding';
        else {
          const spacing = count.calls.some(t => now - t.callAttemptAt < this.config.callSpacingMs);
          const daily = count.daily >= this.config.callsPerDay;
          if (!override.active && spacing) reason = 'call-spacing';
          else if (!override.active && daily) reason = 'call-daily-limit';
          else overrideUsed = override.active && (spacing || daily);
        }
      }
      const call = reason === 'urgent-eligible';
      const notificationLimit = count.notifications >= this.config.notificationsPerHour;
      const blocked = (!override.active && notificationLimit) || !d.enrollment.alertToken;
      overrideUsed ||= override.active && notificationLimit;
      targets[dk(device.deviceID)] = { deviceID: device.deviceID, reason: blocked ? (!d.enrollment.alertToken ? 'no-alert-token' : 'notification-limit') : reason,
        state: blocked ? 'suppressed' : call ? 'call-intent' : 'notification-intent',
        ...(overrideUsed && !blocked ? { override: 'dev' } : {}),
        ...(call && !blocked ? { callAttemptAt: now, ringDeadline: now + this.config.ringMs,
          fallbackDeadline: now + this.config.fallbackMs, reservedFallback: true } : {}) };
    }
    requireThat(Object.keys(targets).length, 409, 'no enrolled paired device');
    if (dryRun) return { id: request.id, disposition: 'dry-run', policyReason: 'validated', targets: Object.values(targets).map(t => ({ disposition: t.state, policyReason: t.reason, ...(t.override ? { override: t.override } : {}) })) };
    const record = { request, createdAt: now, expiry: now + this.config.notificationTTL * 1000,
      ...(request.kind === 'urgent-call' ? { callUUID: crypto.randomUUID(), callExpiry: now + (request.expiresIn ?? 60) * 1000 } : {}), targets };
    this.store.data.records[rk(request.id)] = record;
    this.store.save(); // Commit ALL intents before any external side effect.
    for (const t of Object.values(targets)) {
      if (t.override === 'dev') { try { this.diagnostic({ stage: 'push', category: 'dev_override', override: 'dev' }); } catch {} }
      if (t.state === 'call-intent') this.deliver(record, t, true);
      else if (t.state === 'notification-intent') this.alert(record, t, false);
    }
    return this.status(request.id);
  }
  jobKey(r, t, lane) { return `${r.request.id}:${t.deviceID}:${lane}`; }
  deliver(r, t, voip, fallback = false) {
    const laneName = voip ? 'call' : fallback ? 'fallback' : 'alert', lane = this.lanes[laneName];
    const key = this.jobKey(r, t, laneName);
    if (this.jobs.has(key)) return;
    if (lane.queue.length >= this.config.dispatchQueueLimit) {
      if (voip || !fallback) t.state = 'dispatch-limit';
      if (!voip) (fallback ? t.fallback : t.alert).state = 'dispatch-limit';
      this.store.save(); return;
    }
    this.jobs.add(key); lane.queue.push({ r, t, voip, fallback, key }); this.pump(lane);
  }
  pump(lane) {
    while (lane.active < this.config.dispatchConcurrency && lane.queue.length) {
      const job = lane.queue.shift(); lane.active++;
      let delivery;
      try { delivery = this.beginDelivery(job.r, job.t, job.voip, job.fallback); }
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
  beginDelivery(r, t, voip, fallback) {
    if (fallback && t.receipt === 'answered') { t.fallback.state = 'suppressed-answer'; this.store.save(); return; }
    // Recheck pairing at each network boundary; revoked devices receive nothing further.
    if (!this.activeDevices().some(d => !d.test && d.deviceID === t.deviceID)) { t.state = 'revoked'; this.store.save(); return; }
    const d = this.device(t.deviceID), enrollment = d.enrollment;
    const key = voip ? 'voipToken' : 'alertToken', token = enrollment?.[key];
    if (!token) {
      if (voip || !fallback) t.state = 'no-token';
      if (!voip) (fallback ? t.fallback : t.alert).state = 'no-token';
      this.store.save(); return;
    }
    if (voip) {
      let reason = callPolicy(d.settings, this.now(), this.config);
      if (reason === 'urgent-eligible' && callPolicy(d.settings, this.now() + this.config.ringMs, this.config) !== 'urgent-eligible') reason = 'quiet-boundary';
      if (this.now() >= r.callExpiry) reason = 'call-expired';
      if (reason !== 'urgent-eligible' || this.now() >= r.callExpiry) {
        t.reason = reason; t.state = 'notification-only'; t.reservedFallback = false; delete t.callAttemptAt;
        this.alert(r, t, false); return;
      }
      t.callAttemptAt = this.now(); t.ringDeadline = Math.min(this.now() + this.config.ringMs, r.callExpiry);
      t.fallbackDeadline = this.now() + this.config.fallbackMs;
      t.voipAttemptedAt = this.now(); this.store.save();
    }
    const payload = { aps: voip ? {} : { alert: { title: 'Voicestack', body: r.request.kind === 'ready-to-try' ? 'Something is ready to try' : `${assistantLabel} needs a decision` },
      category: fallback ? 'URGENT_FALLBACK' : r.request.kind === 'ready-to-try' ? 'READY_TO_TRY' : 'NEED', 'interruption-level': 'active' },
      reachoutID: r.request.id, ...(r.callUUID ? { callUUID: r.callUUID } : {}), expiry: voip ? r.callExpiry : r.expiry,
      ...(voip ? { ringDeadline: t.ringDeadline } : {}) };
    if (!voip) { const item = fallback ? t.fallback : t.alert; item.attemptAt = this.now(); item.state = 'delivery-unknown'; this.store.save(); }
    // Token snapshot exists only in memory, never in the durable intent or results.
    let pending;
    try { pending = Promise.resolve(this.apns({ token, environment: enrollment.environment, voip, payload, collapseID: r.request.id })); }
    catch { pending = Promise.resolve(null); }
    return { pending, finish: result => {
      const state = !result ? 'delivery-unknown' : result.status === 200 ? 'apns-accepted' : 'apns-rejected';
      if (result?.status === 410 && d.enrollment[key] === token && d.enrollment.revision === enrollment.revision && d.enrollment.environment === enrollment.environment) d.enrollment[key] = null;
      if (voip) t.state = state;
      else { (fallback ? t.fallback : t.alert).state = state; if (!fallback) t.state = state; }
      this.store.save();
    } };
  }
  alert(r, t, fallback) {
    if (fallback && t.fallback) return;
    const intent = { state: 'dispatch-queued', reservedAt: this.now() };
    if (fallback) { t.fallback = intent; t.reservedFallback = false; r.expiry = Math.max(r.expiry, this.now() + this.config.notificationTTL * 1000); }
    else { if (t.alert) return; t.alert = intent; }
    this.store.save(); // A crash here is uncertain, never automatically re-dispatch.
    this.deliver(r, t, false, fallback);
  }
  async event(device, o) {
    requireThat(!device.test, 403); exact(o, ['reachoutID', 'callUUID', 'event','endReason','endInitiator','reportedRinging','reportFailure','reportErrorCode']);
    requireThat(stableID(o.reachoutID) && ['reported', 'ringing', 'answered', 'declined', 'ended', 'report-failed', 'notification-opened'].includes(o.event));
    requireThat(o.endReason === undefined || endReasons.includes(o.endReason));
    requireThat(o.endInitiator === undefined || endInitiators.includes(o.endInitiator));
    requireThat(o.reportFailure === undefined || reportFailures.includes(o.reportFailure));
    requireThat(o.reportedRinging === undefined || typeof o.reportedRinging === 'boolean');
    requireThat(o.reportErrorCode === undefined || Number.isSafeInteger(o.reportErrorCode) && Math.abs(o.reportErrorCode) <= 2147483647);
    const r = this.store.data.records[rk(o.reachoutID)], t = r?.targets[dk(device.deviceID)];
    requireThat(t, 404, 'reach-out unavailable');
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
    if (['declined','ended','report-failed'].includes(o.event)) {
      t.terminalReceipt ??= { event:o.event, at:this.now(), ...Object.fromEntries(['endReason','endInitiator','reportedRinging','reportFailure','reportErrorCode'].filter(k=>o[k]!==undefined).map(k=>[k,o[k]])) };
    }
    this.store.save();
    if (['declined', 'report-failed', 'ended'].includes(t.receipt)) this.alert(r, t, true);
    return { acknowledged: true };
  }
  async recover() {
    for (const r of this.records()) for (const t of Object.values(r.targets)) {
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
      if (this.now() >= t.fallbackDeadline || ['declined', 'ended', 'report-failed'].includes(t.receipt)) this.alert(r, t, true);
    }
  }
}
