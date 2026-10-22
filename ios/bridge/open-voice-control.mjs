import crypto from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { exact, requireThat as check, stableID, callPolicy, localParts } from './reachout-policy.mjs';
import { validateClientEvent } from './open-voice-profile.mjs';
import { trustedEndPolicy, futureEndCall, verifyTerminalEnd } from './open-voice-end-policy.mjs';

export const CONTROL_PREFIX = '/floating-voice/voice/v1';
export const CONTROL_PROFILE = 'open-voice-m1-ga-ws/1';
export const CONTROL_LIMITS = Object.freeze({ max_message_bytes: 65536, sample_rate: 24000,
  channels: 1, input_window_samples: 48000, output_window_samples: 48000 });
const uuid = s => typeof s === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s);
const digest = s => crypto.createHash('sha256').update(s).digest('hex');
const canonical = o => JSON.stringify(o, Object.keys(o).sort());
const equalHash = (a, b) => typeof a === 'string' && /^[a-f0-9]{64}$/.test(a) && crypto.timingSafeEqual(Buffer.from(a, 'hex'), Buffer.from(b, 'hex'));
const opaque = () => crypto.randomBytes(32).toString('base64url');
const key = s => 'v:' + s;
const terminal = c => ['ended', 'rejected', 'expired'].includes(c.state);
const clone = o => structuredClone(o);
const boundedText = (s, n) => typeof s === 'string' && s.trim() && s.length <= n && !/[\x00-\x1f\x7f\uD800-\uDFFF]/u.test(s);

// No defaults discover a target, credentials, network endpoint or deployment identity.
export class OpenVoiceControl {
  constructor({ enabled = false, push, principal_id, audience, device_id, resolveTarget,
    authenticateDevice, closeOwner = () => {}, endNote, mediaAvailable = () => false, now = Date.now,
    productionFresh = false, validateMapping }) {
    check(enabled === true && push && stableID(principal_id) && stableID(audience) && stableID(device_id)
      && typeof resolveTarget === 'function' && typeof authenticateDevice === 'function' && typeof mediaAvailable === 'function', 503);
    check(!push.openVoice, 409);
    Object.assign(this, { push, store: push.store, principal_id, audience, device_id, resolveTarget,
      authenticateDevice, closeOwner, endNote, mediaAvailable, now, productionFresh, validateMapping });
    check(!productionFresh || typeof validateMapping === 'function', 503);
    this.liveMedia = new Map();
    this.state = this.store.openVoice(); this.reads = new Map();
    push.openVoice = this;
    // Restart cannot recover ownership of a socket or prove an external callback outcome.
    for (const c of Object.values(this.state.calls)) {
      delete c.lease;
      delete c.media_ready;
      for (const o of Object.values(c.operations)) if (o.state === 'dispatching') o.state = 'uncertain';
    }
    this.save(); this.recover();
  }
  size() { return Object.values(this.state).reduce((n, table) => n + Object.keys(table).length, 0)
    + Object.values(this.state.calls).reduce((n, c) => n + Object.keys(c.operations).length, 0); }
  room(n = 1) { check(this.size() + n <= 4096, 429); }
  save() {
    check(!this.poisoned, 503);
    try { this.store.save(); } catch (e) { this.poison(); throw e; }
  }
  poison() {
    if (this.poisoned) return;
    this.poisoned = true;
    // Emergency in-memory invalidation MUST NOT attempt another failing save.
    for (const c of Object.values(this.state.calls)) {
      const previous = c.media_epoch; c.media_epoch++; delete c.lease;
      delete c.media_ready; this.liveMedia.delete(c.id);
      try { this.closeOwner({ call_id: c.id, media_epoch: previous }); } catch { /* authority is already invalid */ }
    }
    for (const lane of Object.values(this.push.lanes)) {
      lane.queue = lane.queue.filter(job => {
        if (!job.r.openVoice) return true;
        this.push.jobs.delete(job.key); return false;
      });
    }
  }
  hasReservation() {
    return Object.values(this.state.calls).some(c => !terminal(c) && (c.state === 'accepted'
      || this.now() < this.store.data.records['r:' + c.id]?.targets['d:' + c.binding.device_id]?.ringDeadline));
  }
  mappingKey(caller, project) { return key(JSON.stringify([caller, this.principal_id, project])); }
  binding(mapping) {
    const { claimed_call_id, ...binding } = mapping;
    return clone(binding);
  }
  configureMapping(o) {
    exact(o, ['caller_id', 'project_id', 'target_session', 'directory', 'binding_revision', 'expires_at']);
    check(stableID(o.caller_id) && stableID(o.project_id) && /^ses_[A-Za-z0-9]{1,100}$/.test(o.target_session)
      && boundedText(o.directory, 1024) && o.directory.startsWith('/') && Number.isSafeInteger(o.binding_revision)
      && o.binding_revision > 0 && Number.isSafeInteger(o.expires_at) && o.expires_at > this.now());
    const k = this.mappingKey(o.caller_id, o.project_id), old = this.state.mappings[k];
    check(!old || o.binding_revision > old.binding_revision, 409);
    if (!old) this.room();
    const mapping = { ...o, principal_id: this.principal_id, audience: this.audience, device_id: this.device_id,
      target_id: crypto.randomUUID() };
    if (this.productionFresh) {
      check(!old || old.target_session !== mapping.target_session, 409);
      check(!Object.values(this.state.calls).some(c => c.binding.target_session === mapping.target_session), 409);
      const verified = this.validateMapping(clone(mapping));
      exact(verified, ['authority', 'pins']);
      check(uuid(verified.authority) && verified.pins && typeof verified.pins === 'object', 503);
      Object.assign(mapping, clone(verified));
    }
    this.state.mappings[k] = mapping; this.save(); this.recover();
    return { target_id: mapping.target_id, binding_revision: mapping.binding_revision };
  }
  issue(o) {
    exact(o, ['caller_id', 'project_ids', 'scopes', 'expires_at']);
    check(stableID(o.caller_id) && Array.isArray(o.project_ids) && o.project_ids.length > 0 && o.project_ids.length <= 8
      && o.project_ids.every(stableID) && new Set(o.project_ids).size === o.project_ids.length
      && Array.isArray(o.scopes) && o.scopes.length > 0 && o.scopes.length <= 2
      && o.scopes.every(s => ['call:request', 'call:status:own'].includes(s))
      && new Set(o.scopes).size === o.scopes.length && Number.isSafeInteger(o.expires_at) && o.expires_at > this.now());
    if (this.productionFresh) check(o.project_ids.every(project => {
      const mapping = this.state.mappings[this.mappingKey(o.caller_id, project)];
      return mapping && o.expires_at <= mapping.expires_at;
    }), 403);
    this.room(); const token = opaque(), id = crypto.randomUUID();
    this.state.grants[key(id)] = { ...clone(o), id, principal_id: this.principal_id, audience: this.audience, hash: digest(token) };
    this.save(); return { grant_id: id, token }; // Protected owner channel only; delivered once.
  }
  list() { return Object.values(this.state.grants).map(({ hash, ...g }) => clone(g)); }
  revoke(id) { check(uuid(id)); const g = this.state.grants[key(id)]; check(g, 404); g.revoked_at ??= this.now(); this.save(); this.recover(); return { revoked: true }; }
  grantCurrent(g) { return g && g.revoked_at === undefined && g.expires_at > this.now()
    && g.principal_id === this.principal_id && g.audience === this.audience; }
  caller(token, scope) {
    check(typeof token === 'string' && /^[A-Za-z0-9_-]{43}$/.test(token), 401);
    const hash = digest(token), g = Object.values(this.state.grants).find(g => equalHash(g.hash, hash));
    check(this.grantCurrent(g) && g.scopes.includes(scope), 403); return g;
  }
  paired(d) { check(d && !d.test && d.deviceID === this.device_id
    && this.push.activeDevices().some(p => !p.test && p.deviceID === d.deviceID), 403); return d; }
  device(token) { return this.paired(this.authenticateDevice('Bearer ' + token)); }
  capability(d, o) {
    this.paired(d); exact(o, ['enabled', 'profile', 'build', 'expires_in']);
    check(typeof o.enabled === 'boolean' && o.profile === CONTROL_PROFILE && boundedText(o.build, 40)
      && Number.isInteger(o.expires_in) && o.expires_in >= 1 && o.expires_in <= 300);
    this.recover(); // A late refresh cannot restore authority already lost to expiry.
    const k = key(d.deviceID); if (!this.state.capabilities[k]) this.room();
    this.state.capabilities[k] = { ...o, expires_at: this.now() + o.expires_in * 1000 };
    this.save(); this.recover(); return { acknowledged: true, expires_at: this.state.capabilities[k].expires_at };
  }
  capabilityCurrent(requireMedia = true) {
    const cap = this.state.capabilities[key(this.device_id)], d = this.push.device(this.device_id);
    return (!requireMedia || this.mediaAvailable() === true) && cap?.enabled === true && cap.profile === CONTROL_PROFILE && cap.expires_at > this.now()
      && cap.build === d.enrollment?.build;
  }
  current(c) {
    return this.bindingCurrent(c) && !terminal(c) && (c.state === 'accepted' || c.expires_at > this.now());
  }
  bindingCurrent(c) {
    if (!c || this.poisoned) return false;
    const g = this.state.grants[key(c.grant_id)], m = this.state.mappings[this.mappingKey(c.binding.caller_id, c.binding.project_id)];
    return this.grantCurrent(g) && g.scopes.includes('call:request')
      && g.project_ids.includes(c.binding.project_id) && m?.target_id === c.binding.target_id && m.expires_at > this.now()
      && this.push.config.callsEnabled && callPolicy(this.push.device(this.device_id).settings, this.now(), this.push.config) === 'urgent-eligible'
      && this.capabilityCurrent() && this.push.activeDevices().some(d => !d.test && d.deviceID === c.binding.device_id);
  }
  async resolve(binding) {
    check((this.resolving ?? 0) < 16, 429); this.resolving = (this.resolving ?? 0) + 1;
    let timer; const controller = new AbortController();
    binding = this.binding(binding);
    const work = Promise.resolve().then(() => this.resolveTarget(clone(binding), controller.signal))
      .finally(() => { this.resolving--; });
    try {
      const r = await Promise.race([work,
        new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error()); }, 2000); })]);
      if (this.productionFresh) {
        check(r?.exclusive === true && r.single_use === true && r.target_session === binding.target_session
          && r.authority === binding.authority && isDeepStrictEqual(binding.pins, this.state.mappings[this.mappingKey(binding.caller_id, binding.project_id)]?.pins), 409);
      } else check(r?.authenticated === true && r.paired === true && r.available === true && r.idle === true
        && ['principal_id', 'audience', 'device_id', 'caller_id', 'project_id', 'target_session', 'directory', 'binding_revision', 'target_id']
          .every(k => r[k] === binding[k]), 409);
    } finally { clearTimeout(timer); }
  }
  owner(c, d, o, extra = []) {
    check(!this.poisoned, 503);
    this.paired(d); check(c?.binding.device_id === d.deviceID, 404);
    exact(o, ['call_uuid', 'owner_epoch', 'binding_revision', 'target_id', ...extra]);
    check(o.call_uuid === c.call_uuid && o.owner_epoch === c.owner_epoch
      && o.binding_revision === c.binding.binding_revision && o.target_id === c.binding.target_id, 409);
  }
  status(c) { return { call_id: c.id, status: c.state }; }
  recipient(d, id) {
    this.paired(d); const c = this.state.calls[key(id)]; check(c?.binding.device_id === d.deviceID, 404);
    this.recover();
    return { ...this.status(c), context: 'open-voice', call_uuid: c.call_uuid, owner_epoch: c.owner_epoch,
      binding_revision: c.binding.binding_revision, target_id: c.binding.target_id, project_id: c.binding.project_id,
      caller_id: c.binding.caller_id, reason: c.request.reason, summary: c.request.summary,
      expires_at: c.expires_at, profile: CONTROL_PROFILE };
  }
  policy({ preparation = false } = {}) {
    // Owner preparation checks the same current recipient/quota policy before an
    // adapter can be armed. Public call paths always use the default media gate.
    const p = this.push, d = p.device(this.device_id), now = this.now();
    check(d.enrollment?.voipToken && this.capabilityCurrent(!preparation), 409);
    check(p.config.callsEnabled && callPolicy(d.settings, now, p.config) === 'urgent-eligible'
      && callPolicy(d.settings, now + p.config.ringMs, p.config) === 'urgent-eligible', 409);
    const counts = p.counts(this.device_id, now, d.settings.timeZone);
    check(counts.daily < p.config.callsPerDay
      && !counts.calls.some(t => now - t.callAttemptAt < p.config.callSpacingMs), 429);
    const all = p.records().flatMap(r => Object.values(r.targets));
    const calls = all.filter(t => t.callAttemptAt !== undefined);
    check(!calls.some(t => now - t.callAttemptAt < p.config.callSpacingMs)
      && calls.filter(t => localParts(t.callAttemptAt, d.settings.timeZone).day === localParts(now, d.settings.timeZone).day).length < p.config.callsPerDay, 429);
    // Aggregate over ALL legacy devices, not just the selected recipient.
    check(!p.records().some(r => Object.values(r.targets).some(t => t.callAttemptAt !== undefined &&
      (t.receipt === 'answered' ? t.endedAt === undefined
        : !['declined', 'ended', 'expired', 'report-failed'].includes(t.receipt) && now < t.fallbackDeadline))), 409);
    check(!Object.values(this.state.calls).some(c => !terminal(c)), 409);
  }
  async request({ token, body }) {
    check(!this.poisoned, 503);
    exact(body, ['operation_id', 'project_id', 'reason', 'summary', 'expires_in']);
    check(uuid(body.operation_id) && stableID(body.project_id) && ['decision', 'goal-risk'].includes(body.reason)
      && boundedText(body.summary, 240) && !/\bmilestone\b/i.test(body.summary)
      && (body.expires_in === undefined || Number.isInteger(body.expires_in) && body.expires_in >= 30 && body.expires_in <= 300));
    const request = { ...body, expires_in: body.expires_in ?? 60 }, hash = digest(canonical(request));
    const g = this.caller(token, 'call:request'); check(g.project_ids.includes(body.project_id), 403);
    this.recover();
    const old = () => Object.values(this.state.calls).find(c => c.binding.caller_id === g.caller_id && c.request.operation_id === body.operation_id);
    const dedupe = c => { check(c.hash === hash, 409); return this.status(c); };
    if (old()) return dedupe(old());
    if (this.productionFresh) this.push.maintenance?.requireOpen();
    const m = this.state.mappings[this.mappingKey(g.caller_id, body.project_id)]; check(m && m.expires_at > this.now(), 403);
    if (this.productionFresh) check(!m.claimed_call_id, 409);
    await this.resolve(m);
    return this.push.serial(() => {
      this.caller(token, 'call:request'); this.recover(); if (old()) return dedupe(old());
      if (this.productionFresh) this.push.maintenance?.requireOpen();
      check(this.state.mappings[this.mappingKey(g.caller_id, body.project_id)] === m && m.expires_at > this.now(), 409);
      if (this.productionFresh) check(!m.claimed_call_id, 409);
      this.policy(); this.room(); check(this.push.records().length < this.push.config.maxRecords, 429);
      const now = this.now(), day = localParts(now, 'UTC').day;
      const prior = Object.values(this.state.calls).filter(c => c.binding.caller_id === g.caller_id);
      check(!prior.some(c => now - c.created_at < 60000) && prior.filter(c => localParts(c.created_at, 'UTC').day === day).length < 3, 429);
      const id = crypto.randomUUID(), c = { id, call_uuid: crypto.randomUUID(), owner_epoch: crypto.randomUUID(),
        grant_id: g.id, binding: this.binding(m), request, hash, state: 'ringing', created_at: now,
        expires_at: now + request.expires_in * 1000, operations: {}, media_epoch: 0 };
      if (trustedEndPolicy(this)) c.end_note_version = 1;
      const t = { deviceID: this.device_id, state: 'call-intent', reason: 'urgent-eligible', callAttemptAt: now,
        ringDeadline: Math.min(c.expires_at, now + this.push.config.ringMs), fallbackDeadline: now + this.push.config.fallbackMs, reservedFallback: true };
      const r = { openVoice: id, request: { id, kind: 'urgent-call', reason: request.reason }, createdAt: now,
        expiry: c.expires_at, callUUID: c.call_uuid, callExpiry: c.expires_at, targets: { ['d:' + this.device_id]: t } };
      this.state.calls[key(id)] = c; this.store.data.records['r:' + id] = r;
      if (this.productionFresh) m.claimed_call_id = id;
      this.save(); this.push.deliver(r, t, true); return this.status(c);
    });
  }
  // Called by real PushService lane. Dispatch intent is durable BEFORE resolver/APNs.
  delivery(r, t, voip, fallback) {
    check(voip && !fallback, 403); const c = this.state.calls[key(r.openVoice)];
    if (!this.current(c) || t.voipAttemptedAt !== undefined || t.state !== 'call-intent') return;
    const d = this.push.device(t.deviceID), now = this.now();
    if (callPolicy(d.settings, now, this.push.config) !== 'urgent-eligible'
      || callPolicy(d.settings, now + this.push.config.ringMs, this.push.config) !== 'urgent-eligible') {
      this.stop(c, 'rejected'); return;
    }
    t.state = 'delivery-unknown'; t.voipAttemptedAt = now; this.save();
    let dispatchedEnrollment;
    const pending = (async () => {
      await this.resolve(c.binding);
      check(this.current(c) && c.state === 'ringing' && this.now() < t.ringDeadline, 403);
      this.paired({ deviceID: t.deviceID });
      const latest = this.push.device(t.deviceID);
      check(callPolicy(latest.settings, this.now(), this.push.config) === 'urgent-eligible'
        && callPolicy(latest.settings, this.now() + this.push.config.ringMs, this.push.config) === 'urgent-eligible', 403);
      const enrollment = latest.enrollment; check(enrollment?.voipToken, 403); dispatchedEnrollment = { ...enrollment };
      c.push_handoff_at = this.now(); this.save();
      return this.push.apns({ token: enrollment.voipToken, environment: enrollment.environment, voip: true,
        payload: { aps: {}, reachoutID: c.id, callUUID: c.call_uuid, expiry: c.expires_at, ringDeadline: t.ringDeadline }, collapseID: c.id });
    })();
    return { pending, finish: result => {
      const enrollment = this.push.device(t.deviceID).enrollment;
      if (result?.status === 410 && dispatchedEnrollment && enrollment?.revision === dispatchedEnrollment.revision
        && enrollment.environment === dispatchedEnrollment.environment && enrollment.voipToken === dispatchedEnrollment.voipToken) enrollment.voipToken = null;
      t.state = !result ? 'delivery-unknown' : result.status === 200 ? 'apns-accepted' : 'apns-rejected';
      c.push_delivery = t.state; this.save();
    } };
  }
  fence(c) {
    const previous = c.media_epoch; c.media_epoch++; delete c.lease;
    delete c.media_ready; this.liveMedia.delete(c.id);
    try { this.save(); }
    finally {
      // Even a failed epoch save must close the previously attached generation.
      try { this.closeOwner({ call_id: c.id, media_epoch: previous }); } catch { /* authority is already fenced */ }
    }
  }
  stop(c, state) {
    if (terminal(c)) return;
    c.state = state;
    const t = this.store.data.records['r:' + c.id]?.targets['d:' + c.binding.device_id];
    if (t) { t.receipt = state === 'expired' ? 'expired' : 'ended'; t.endedAt = this.now(); t.reservedFallback = false; }
    this.fence(c);
  }
  recover() {
    check(!this.poisoned, 503);
    for (const c of Object.values(this.state.calls)) {
      const r = this.store.data.records['r:' + c.id], t = r?.targets['d:' + c.binding.device_id];
      if (!terminal(c) && (!this.current(c) || c.state === 'ringing' && this.now() >= t.ringDeadline))
        this.stop(c, c.state === 'ringing' && this.now() >= t.ringDeadline ? 'expired' : 'rejected');
      if (t?.state === 'call-intent' && !this.push.jobs.has(this.push.jobKey(r, t, 'call'))) {
        t.state = 'delivery-unknown'; this.save(); // Restart: never blindly resend.
      }
      if (t?.fallback?.state === 'dispatch-queued' && !this.push.jobs.has(this.push.jobKey(r, t, 'fallback'))) {
        t.fallback.state = 'delivery-unknown'; t.fallback.attemptAt = t.fallback.reservedAt; this.save();
      }
    }
  }
  fallbackAllowed(id) {
    const c = this.state.calls[key(id)];
    const g = c && this.state.grants[key(c.grant_id)], m = c && this.state.mappings[this.mappingKey(c.binding.caller_id, c.binding.project_id)];
    return !this.poisoned && c && c.accepted_at === undefined && this.grantCurrent(g) && g.scopes.includes('call:request')
      && g.project_ids.includes(c.binding.project_id) && m?.target_id === c.binding.target_id && m.expires_at > this.now()
      && this.capabilityCurrent() && this.push.activeDevices().some(d => !d.test && d.deviceID === c.binding.device_id);
  }
  receipt(d, r, t, o) {
    this.paired(d); const c = this.state.calls[key(r.openVoice)];
    check(c && o.callUUID === c.call_uuid && t.voipAttemptedAt !== undefined, 409);
    this.recover();
    if (['ended', 'declined', 'report-failed'].includes(o.event)) this.stop(c, o.event === 'ended' ? 'ended' : 'rejected');
    // Answered is a delivery fact, NOT acceptance; receipt never authorizes an end note.
    t.candidateReceipts ??= {}; t.candidateReceipts[o.event] ??= this.now(); this.save();
    return { acknowledged: true };
  }
  async act(d, id, action, o) {
    if (action === 'media-ready') return this.push.serial(() => this.mediaReady(d, id, o));
    let c = this.state.calls[key(id)]; this.owner(c, d, o, action === 'end' ? ['operation_id', 'reason'] : []);
    if (action === 'end' && c.operations[key(o.operation_id)]) return this.controlEnd(c, o);
    if (action !== 'decline' && action !== 'end') await this.resolve(c.binding);
    return this.push.serial(() => {
      this.owner(c, d, o, action === 'end' ? ['operation_id', 'reason'] : []); this.recover();
      if (action === 'end') return this.controlEnd(c, o);
      check(this.current(c), 403);
      if (action === 'decline') { check(c.state === 'ringing', 409); this.stop(c, 'rejected'); return this.status(c); }
      if (action === 'accept') {
        check(['ringing', 'accepted'].includes(c.state), 409);
        const t = this.store.data.records['r:' + c.id].targets['d:' + d.deviceID];
        check(c.state === 'accepted' || this.now() < t.ringDeadline, 410);
        c.state = 'accepted'; c.accepted_at ??= this.now(); t.receipt = 'answered'; t.reservedFallback = false; this.save(); return this.recipient(d, id);
      }
      check(action === 'media' && c.state === 'accepted', 409);
      this.fence(c); const lease = opaque(), expires_at = Math.min(this.now() + 60000, this.state.grants[key(c.grant_id)].expires_at);
      c.lease = { hash: digest(lease), expires_at, epoch: c.media_epoch }; this.save();
      check(Number.isSafeInteger(c.media_epoch) && c.media_epoch >= 0, 503);
      return { media_lease: lease, media_epoch: String(c.media_epoch), expires_at, binding_revision: c.binding.binding_revision,
        profile: CONTROL_PROFILE, limits: CONTROL_LIMITS, model: 'local-chain-m1', transcription: 'local-stt', voice: 'local-default',
        semantics: 'manual-text-one-exchange', cancellation: 'narration-only' };
    });
  }
  controlEnd(c, o) {
    check(uuid(o.operation_id) && o.reason === 'deliberate-user');
    const hash = digest(canonical(o)), old = c.operations[key(o.operation_id)];
    if (old) { check(old.kind === 'end' && old.hash === hash, 409); return clone(old); }
    check(this.current(c) && c.state === 'accepted' && !c.end_operation, 403); this.room();
    const op = { operation_id: o.operation_id, kind: 'end', hash, state: 'prepared' };
    c.operations[key(o.operation_id)] = op; c.end_operation = o.operation_id; this.save();
    this.stop(c, 'ended');
    // No callback is installed by default. Never retry prepared/dispatching on recovery.
    if (this.endNote && (!trustedEndPolicy(this) || futureEndCall(this, c))) {
      this.pendingEndNotes = (this.pendingEndNotes ?? 0) + 1;
      const payload = Object.freeze({ call_id: c.id, owner_epoch: c.owner_epoch,
        binding: clone(c.binding), operation_id: op.operation_id, role: 'system', text: '[voice] ended', assistant_response: false });
      Promise.resolve().then(async () => {
        check(!this.poisoned, 503);
        if (trustedEndPolicy(this)) await verifyTerminalEnd(this, payload);
        else await this.resolve(c.binding);
        check(this.bindingCurrent(c) && op.state === 'prepared', 403);
        op.state = 'dispatching'; this.save();
        return this.endNote(payload);
      })
        .then(() => { op.state = 'completed'; this.save(); }, () => {
          if (!this.poisoned && op.state === 'dispatching') { op.state = 'uncertain'; this.save(); }
          // Failure before dispatch leaves the persisted prepared intent; no automatic retry.
        })
        .catch(() => { this.poison(); })
        .finally(() => { this.pendingEndNotes--; });
    }
    return clone(op);
  }
  lease(token) {
    check(typeof token === 'string' && /^[A-Za-z0-9_-]{43}$/.test(token), 401); const hash = digest(token);
    const c = Object.values(this.state.calls).find(c => equalHash(c.lease?.hash, hash));
    check(c && this.current(c) && c.state === 'accepted' && c.lease.expires_at > this.now() && c.lease.epoch === c.media_epoch, 403);
    return c;
  }
  async attach(token) {
    const c = this.lease(token); await this.resolve(c.binding);
    return this.push.serial(() => { check(this.lease(token) === c && !c.lease.attached, 409);
      c.lease.attached = true; this.save(); return { call_id: c.id, media_epoch: c.media_epoch, binding: clone(c.binding) }; });
  }
  currentAuthority(id, epoch) {
    const c = this.state.calls[key(id)]; this.recover();
    check(c && this.current(c) && c.state === 'accepted' && c.media_epoch === epoch && c.lease?.attached, 403); return clone(c.binding);
  }
  // Internal transport hooks only. No client field can declare a socket live/configured.
  registerMediaSession(id, epoch, session_id, isLive) {
    this.currentAuthority(id, epoch);
    check(typeof session_id === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(session_id) && typeof isLive === 'function', 400);
    check(!this.liveMedia.has(id), 409);
    this.liveMedia.set(id, { epoch, session_id, isLive, configured: false });
  }
  effectiveConfigured(id, epoch, session_id) {
    this.currentAuthority(id, epoch); const live = this.liveMedia.get(id);
    check(live?.epoch === epoch && live.session_id === session_id && live.isLive(), 409); live.configured = true;
  }
  unregisterMediaSession(id, epoch, session_id) {
    const live = this.liveMedia.get(id);
    if (live?.epoch !== epoch || live.session_id !== session_id) return;
    this.liveMedia.delete(id); const c = this.state.calls[key(id)];
    if (c?.media_ready) { delete c.media_ready; this.save(); }
  }
  mediaReady(d, id, o) {
    const c = this.state.calls[key(id)]; this.owner(c, d, o, ['media_epoch', 'session_id', 'native_capture_ready']);
    this.currentAuthority(id, c.media_epoch); const live = this.liveMedia.get(id);
    check(typeof o.media_epoch === 'string' && /^(0|[1-9][0-9]*)$/.test(o.media_epoch)
      && o.media_epoch === String(c.media_epoch) && o.native_capture_ready === true
      && live?.epoch === c.media_epoch && live.session_id === o.session_id && live.configured && live.isLive(), 409);
    c.media_ready = { media_epoch: o.media_epoch, session_id: o.session_id }; this.save();
    return { call_id: c.id, ...c.media_ready, status: 'media_ready' };
  }
  readyAuthority(id, epoch, session_id) {
    this.currentAuthority(id, epoch); const live = this.liveMedia.get(id), ready = this.state.calls[key(id)].media_ready;
    check(live?.epoch === epoch && live.session_id === session_id && live.configured && live.isLive()
      && ready?.media_epoch === String(epoch) && ready.session_id === session_id, 409);
  }
  async prepare(id, epoch, operation_id, item) {
    check(uuid(operation_id) && validateClientEvent({ type: 'conversation.item.create', item }).ok);
    const hash = digest(JSON.stringify([item.id, item.type, item.role, item.content[0].type, item.content[0].text]));
    this.currentAuthority(id, epoch); const c = this.state.calls[key(id)];
    const old = c.operations[key(operation_id)];
    if (old) { check(old.kind === 'exchange' && old.hash === hash, 409); return clone(old); }
    await this.resolve(c.binding);
    return this.push.serial(() => {
      this.currentAuthority(id, epoch);
      const old = c.operations[key(operation_id)]; if (old) { check(old.kind === 'exchange' && old.hash === hash, 409); return clone(old); }
      check(!c.exchange_operation, 409); this.room();
      const op = { operation_id, kind: 'exchange', hash, state: 'prepared', response_id: crypto.randomUUID(), planned_inbox_id: 'msg_' + crypto.randomUUID().replaceAll('-', '') };
      c.operations[key(operation_id)] = op; c.exchange_operation = operation_id; this.save(); return clone(op);
    });
  }
  async dispatch(id, epoch, operation_id) {
    this.currentAuthority(id, epoch); const c = this.state.calls[key(id)]; await this.resolve(c.binding);
    return this.push.serial(() => {
      this.currentAuthority(id, epoch); const o = c.operations[key(operation_id)];
      check(o?.kind === 'exchange' && o.state === 'prepared' && c.exchange_operation === operation_id, 409);
      o.state = 'dispatching'; this.save(); return clone(o);
    });
  }
  result(id, operation_id, input) {
    exact(input, ['state', 'admission_inbox_id', 'source_user_id', 'source_assistant_id', 'delivery']);
    check(input.admission_inbox_id === undefined || stableID(input.admission_inbox_id));
    check(['admitted', 'completed', 'rejected', 'uncertain'].includes(input.state));
    for (const k of ['source_user_id', 'source_assistant_id']) check(input[k] === undefined || stableID(input[k]));
    if (input.delivery !== undefined) {
      exact(input.delivery, ['rendered_samples', 'state']); check(Number.isSafeInteger(input.delivery.rendered_samples)
        && input.delivery.rendered_samples >= 0 && ['unknown', 'partial', 'completed'].includes(input.delivery.state));
    }
    const o = this.state.calls[key(id)]?.operations[key(operation_id)];
    check(o?.kind === 'exchange' && ['dispatching', 'uncertain', 'admitted'].includes(o.state), 409);
    check(input.admission_inbox_id === undefined || input.admission_inbox_id === o.planned_inbox_id, 409);
    if (['admitted', 'completed'].includes(input.state)) check(stableID(input.source_user_id), 409);
    if (input.state === 'completed') check(stableID(input.source_assistant_id), 409);
    Object.assign(o, clone(input)); this.save(); return clone(o);
  }
  operation(id, operation_id) { const o = this.state.calls[key(id)]?.operations[key(operation_id)]; return o ? clone(o) : null; }
  recordResponse(id, operation_id, status) {
    const o = this.state.calls[key(id)]?.operations[key(operation_id)];
    check(o?.kind === 'exchange' && ['completed', 'cancelled', 'failed'].includes(status), 409);
    if (o.response_status !== undefined) { check(o.response_status === status, 409); return; }
    o.response_status = status; this.save();
  }
  recordDelivery(id, operation_id, delivery) {
    exact(delivery, ['state', 'rendered_samples']);
    const o = this.state.calls[key(id)]?.operations[key(operation_id)];
    check(o?.state === 'completed' && ['unknown', 'partial', 'completed'].includes(delivery.state)
      && Number.isSafeInteger(delivery.rendered_samples) && delivery.rendered_samples >= (o.delivery?.rendered_samples ?? 0), 409);
    o.delivery = clone(delivery); this.save();
  }
  readLimit(id) {
    const now = this.now(), old = this.reads.get(id);
    const r = old && now - old.at < 60000 ? old : { at: now, count: 0 };
    check(++r.count <= 30, 429); this.reads.set(id, r);
  }
  async http(method, path, token, body = {}) {
    check(!this.poisoned, 503);
    check(typeof token === 'string' && token.length <= 512, 401);
    if (method === 'POST' && path === '/calls') return this.push.requestOpenVoice(this, { token, body });
    if (method === 'PUT' && path === '/device-capability') return this.push.serial(() => this.capability(this.device(token), body));
    const m = /^\/calls\/([0-9a-f-]{36})(?:\/(accept|decline|media|media-ready|end)|\/operations\/([0-9a-f-]{36}))?$/.exec(path);
    check(m && uuid(m[1]) && (!m[3] || uuid(m[3])), 404);
    const c = this.state.calls[key(m[1])];
    if (method === 'GET' && !m[2]) {
      check(Object.keys(body).length === 0); let d;
      try { d = this.device(token); } catch { /* caller has a separate, narrower authority */ }
      if (d) {
        this.readLimit('device:' + d.deviceID); check(c?.binding.device_id === d.deviceID, 404);
        if (!m[3]) return this.recipient(d, c.id);
        const op = c.operations[key(m[3])]; check(op, 404); return clone(op);
      }
      check(!m[3], 403); const g = this.caller(token, 'call:status:own'); this.readLimit(g.id);
      check(c?.binding.caller_id === g.caller_id && c.binding.principal_id === g.principal_id, 404);
      this.recover(); return this.status(c);
    }
    check(method === 'POST' && m[2], 404); return this.act(this.device(token), m[1], m[2], body);
  }
}
