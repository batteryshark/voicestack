import fs from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual as same } from 'node:util';
import crypto from 'node:crypto';
import { createLocalSpeechAdapter, speechHealth, preparationSpeechState } from './open-voice-speech.mjs';
import { startOpenVoiceAdmin } from './open-voice-admin.mjs';
import { exact, stableID, requireThat as check } from './reachout-policy.mjs';
import { installEndPolicy, futureEndCall, inertEndAssembly } from './open-voice-end-policy.mjs';

const text = (v, n = 128) => typeof v === 'string' && v.length > 0 && v.length <= n && !/[\x00-\x1f\x7f]/.test(v);
const explicit = v => text(v) && v.toLowerCase() !== 'auto';
const absolute = v => text(v, 1024) && path.isAbsolute(v);
const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(v);
const ownedDirectory = directory => {
  const s = fs.lstatSync(directory);
  check(s.isDirectory() && !s.isSymbolicLink() && s.uid === process.getuid() && (s.mode & 0o777) === 0o700, 503);
};

// The file supplies owner choices, never a caller-selected module or production defaults.
export function readOpenVoiceConfig(file) {
  check(absolute(file), 503); ownedDirectory(path.dirname(file));
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const s = fs.fstatSync(fd);
    check(s.isFile() && s.uid === process.getuid() && (s.mode & 0o777) === 0o600 && s.nlink === 1 && s.size <= 16384, 503);
    const o = JSON.parse(fs.readFileSync(fd, 'utf8'));
    exact(o, ['version', 'principal_id', 'audience', 'device_id', 'harnessRoot', 'target', 'speech']);
    check(o.version === 1 && [o.principal_id, o.audience, o.device_id].every(stableID) && absolute(o.harnessRoot), 503);
    exact(o.target, ['caller_id', 'project_id', 'directory', 'agent', 'model']);
    check([o.target.caller_id, o.target.project_id].every(stableID) && absolute(o.target.directory) && explicit(o.target.agent), 503);
    exact(o.target.model, ['providerID', 'id', 'variant']);
    check([o.target.model.providerID, o.target.model.id, o.target.model.variant].every(explicit), 503);
    exact(o.speech, ['sttURL', 'ttsURL', 'model', 'voice', 'sttHeaders', 'ttsHeaders', 'monoProfile']);
    check([o.speech.sttURL, o.speech.ttsURL].every(v => text(v, 2048)) && [o.speech.model, o.speech.voice].every(explicit), 503);
    return o;
  } catch { throw new Error('open_voice_configuration_refused'); }
  finally { fs.closeSync(fd); }
}

// Hook initialization is lazy and parent-side: no SDK import or environment mutation.
export async function startOpenVoiceBootstrap({ config, push, startHarness = async options => {
  const module = await import('./harness-client.mjs'); return module.startHarness(options);
}, speechFactory = createLocalSpeechAdapter, healthCheck = speechHealth,
  inspectSpeech = async config => preparationSpeechState(await speechHealth(config, { inspect: true }), config), now = Date.now }) {
  check(push && config, 503);
  const speech = speechFactory({ ...config.speech, submit: input => submit(input) });
  const harness = await startHarness({ root: config.harnessRoot });
  let control, admin, prepared, sealed, instanceID, armed = false, attempted = false, submitted = false,
    signInAttempted = false, closing = false, advancing = false, ownerPreparing = false, pending = 0, cleanup, refreshing, workUnknown = true;
  const pins = { directory: config.target.directory, agent: config.target.agent, model: structuredClone(config.target.model) };
  const track = async work => {
    check(!closing && !advancing && pending < 4, 503); pending++;
    try { return await work(); } finally { pending--; }
  };
  const sdkWork = () => {
    const s = harness.stats();
    return workUnknown || s.localWorkKnown !== true || s.localWorkPending !== false ? 1 : 0;
  };
  const refresh = () => {
    if (refreshing) return refreshing;
    workUnknown = true;
    refreshing = Promise.resolve().then(async () => {
      try {
        const s = await harness.runtimeStats();
        check(typeof s.localWorkKnown === 'boolean' && typeof s.localWorkPending === 'boolean'
          && Number.isSafeInteger(s.localWorkRevision) && s.localWorkRevision >= 0, 503);
        // The client generation fence, not this query's potentially old zero,
        // is authoritative if another submit began while it was in flight.
        workUnknown = false;
      } catch { workUnknown = true; }
    }).finally(() => { refreshing = undefined; });
    return refreshing;
  };
  const validateMapping = binding => {
    check(prepared && !sealed && binding.caller_id === config.target.caller_id && binding.project_id === config.target.project_id
      && binding.target_session === prepared.target_session && binding.directory === pins.directory, 409);
    return { authority: prepared.authority, pins: prepared.pins };
  };
  const instance = result => {
    check(uuid(result?.instance_id), 503);
    if (instanceID) check(result.instance_id === instanceID, 503);
    else instanceID = result.instance_id;
  };
  const identity = result => { instance(result); check(result.runtime_version === '2.0.32', 503); };
  const verified = result => {
    identity(result);
    check(result.target_session === prepared.target_session && result.authority === prepared.authority
      && same(result.pins, pins) && result.exclusive === true && result.single_use === true, 503);
  };
  const claim = binding => {
    const mapping = control.state.mappings[control.mappingKey(binding.caller_id, binding.project_id)];
    check(mapping && same(control.binding(mapping), binding), 409);
    if (!mapping.claimed_call_id) return null;
    const call = control.state.calls['v:' + mapping.claimed_call_id];
    check(call && same(call.binding, binding) && control.current(call), 409);
    return call;
  };
  const ready = async (requireUnused = true) => {
    const result = await harness.capability(); identity(result);
    check(result.target_session === prepared.target_session && result.authority === prepared.authority && same(result.pins, pins)
      && result.modelAvailable === true && result.agentAvailable === true && result.providerConnected === true
      && result.outboundEnabled === true && result.bindingVerified === true, 503);
    if (requireUnused) check(result.singleUseAvailable === true && result.ready === true, 503);
  };
  const verify = binding => track(async () => {
    check(armed && sealed && same(binding, sealed), 409);
    try {
      // A consumed admission slot is not revocation of the same durable call.
      await ready(!claim(binding));
      const result = await harness.verify({ binding }); verified(result);
      return result;
    } catch (error) { armed = false; throw error; }
  });
  async function submit(input) {
    check(armed && same(input.binding, sealed), 503);
    const call = claim(input.binding), operation = call?.operations['v:' + input.operation_id];
    check(call?.id === input.call_id && call.exchange_operation === input.operation_id
      && operation?.state === 'dispatching' && operation.planned_inbox_id === input.planned_inbox_id && !submitted, 409);
    return track(async () => {
      await ready(); check(!submitted && control.current(call), 409);
      submitted = true; // An uncertain response never authorizes another IPC submission.
      return harness.submit(input);
    });
  }
  const adapter = Object.freeze({ ...speech, get readyForCalls() { return armed && !closing && harness.stats().childAlive; } });
  const endFacts = (payload, phase) => {
    const c = control.state.calls['v:' + payload.call_id], op = c?.operations['v:' + payload.operation_id];
    const m = control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)];
    check(armed && !closing && !advancing && sealed && prepared && !control.poisoned
      && c && futureEndCall(control, c) && c.state === 'ended' && c.owner_epoch === payload.owner_epoch
      && !c.lease && !c.media_ready && Number.isSafeInteger(c.media_epoch) && c.media_epoch > 0
      && c.end_operation === payload.operation_id && op?.operation_id === payload.operation_id
      && op.kind === 'end' && op.state === phase && /^[a-f0-9]{64}$/.test(op.hash)
      && Object.keys(op).sort().join(',') === 'hash,kind,operation_id,state'
      && m?.claimed_call_id === c.id && same(control.binding(m), sealed) && same(c.binding, sealed)
      && same(payload.binding, sealed) && control.bindingCurrent(c)
      && payload.role === 'system' && payload.text === '[voice] ended' && payload.assistant_response === false, 403);
  };
  const verifyEnd = payload => track(async () => {
    endFacts(payload, 'prepared');
    // Deliberately NOT ready()/claim()/quiet: already submitted work may continue.
    verified(await harness.verify({ binding: payload.binding }));
    endFacts(payload, 'prepared');
  });
  const appendEnd = payload => track(async () => {
    endFacts(payload, 'dispatching');
    return harness.appendEnd(payload);
  });
  const readiness = () => {
    const started = now();
    const unavailable = reason => ({ ready: false, reason, providerAcceptance: 'not_proven' });
    // Fingerprint only: no enrollment tokens, credentials or private binding exported.
    const facts = () => {
      const m = control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)];
      check(armed && !closing && !advancing && prepared && sealed && m && !m.claimed_call_id && !control.poisoned
        && same(control.binding(m), sealed), 409);
      check(m.expires_at - now() >= 180000, 410);
      const maintenance = push.maintenance?.status();
      check(maintenance && !maintenance.held && !maintenance.invalid && maintenance.listening, 409);
      control.policy(); // Reuse the exact production recipient/policy/quota guards.
      const d = push.device(config.device_id), cap = control.state.capabilities['v:' + config.device_id];
      return { m, cap, fingerprint: crypto.createHash('sha256').update(JSON.stringify([maintenance.nonce, instanceID,
        pins, m, cap, d.settings, d.enrollment, control.principal_id, control.audience, control.device_id])).digest('hex') };
    };
    const work = track(async () => {
      try {
        const before = facts();
        await ready(); await refresh();
        check(!sdkWork(), 409);
        const ownerSpeech = config.speech.sttURL === 'ws://127.0.0.1:8446/v1/transcribe'
          && config.speech.ttsURL === 'http://127.0.0.1:8444/v1/audio/speech';
        const health = healthCheck === speechHealth && ownerSpeech ? await inspectSpeech(config.speech) : await healthCheck(config.speech);
        if (health.ready !== true && (health.stt !== true || health.tts !== true)) return unavailable('speech_unavailable');
        check(!sdkWork(), 409);
        const after = facts();
        if (after.fingerprint !== before.fingerprint) return unavailable('changed');
        const expires_at = Math.min(started + 10000, after.cap.expires_at, after.m.expires_at);
        if (now() >= started + 4000 || now() >= expires_at) return unavailable('expired');
        return { ready: true, reason: 'configured_not_executed', providerAcceptance: 'not_proven',
          checked_at: started, expires_at, fingerprint: after.fingerprint,
          caller_id: config.target.caller_id, project_id: config.target.project_id, mapping_expires_at: after.m.expires_at };
      } catch { return unavailable('target_or_policy_unavailable'); }
    });
    // Abandon only this wait. track/IPC accounting retains underlying pending work.
    let timer;
    return Promise.race([work, new Promise(resolve => { timer = setTimeout(() => resolve(unavailable('deadline')), 4000); })])
      .finally(() => clearTimeout(timer));
  };
  return {
    candidate: { enabled: true, principal_id: config.principal_id, audience: config.audience, device_id: config.device_id,
      productionFresh: true, validateMapping, resolveTarget: verify },
    media: { enabled: true, ownerAssembly: true, adapter },
    stats: () => ({ ownerWork: pending + (refreshing ? 1 : 0) + (advancing ? 1 : 0), harnessPending: harness.stats().pendingRequests, SDKWork: sdkWork() }),
    refresh,
    async attach(candidate) {
      control = candidate;
      installEndPolicy(control, verifyEnd, appendEnd);
      const actions = {
        readiness,
        speechStatus: () => track(async () => {
          const current = () => {
            const m = control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)];
            const s = push.maintenance?.status();
            check(armed && !ownerPreparing && !closing && !advancing && !control.poisoned && sealed && m
              && !Object.hasOwn(m, 'claimed_call_id') && same(control.binding(m), sealed) && m.expires_at - now() >= 180000
              && s && !s.held && !s.invalid && s.listening, 409);
            control.policy();
          };
          current(); await ready(); await refresh();
          const local = speech.stats();
          check(armed && !sdkWork() && local.stt === 0 && local.tts === 0, 409);
          const result = await inspectSpeech(config.speech);
          current(); check(!sdkWork() && speech.stats().stt === 0 && speech.stats().tts === 0, 409);
          return result;
        }),
        mutationAllowed: () => !advancing && !closing && !ownerPreparing,
        advanceUnusedTarget: async (value, ownTransition = false) => {
          exact(value, ['target_id', 'target_session', 'binding_revision', 'next_binding_revision', 'expires_at']);
          check(!closing && !advancing && !pending && !submitted, 409);
          await refresh();
          const maintenance = push.maintenance, quiet = maintenance?.status();
          check(!pending && !advancing && !closing && (!maintenance?.changing || ownTransition && ownerPreparing)
            && quiet?.localQuiet === true && !quiet.invalid, 409);
          const mapping = () => control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)];
           const old = control.binding(mapping() ?? {});
           const claimedCallID = mapping()?.claimed_call_id;
           // Absence is deliberate: null/empty/malformed claims are not unused proof.
           const expiredUnclaimed = !Object.hasOwn(mapping() ?? {}, 'claimed_call_id');
          check(old.target_id === value.target_id && old.target_session === value.target_session && old.binding_revision === value.binding_revision
            && old.principal_id === config.principal_id && old.audience === config.audience && old.device_id === config.device_id
            && same(old.pins, pins) && (!sealed || same(old, sealed)) && Number.isSafeInteger(value.next_binding_revision)
            && value.next_binding_revision > old.binding_revision && Number.isSafeInteger(value.expires_at)
            && value.expires_at > Date.now() && value.expires_at <= Date.now() + 86400000, 409);
          advancing = true; armed = false; maintenance.changing = true;
          try { return await push.serial(async () => {
            const unusedOperations = c => {
              if (!inertEndAssembly(control, c) || (control.pendingEndNotes ?? 0) !== 0) return false;
              const entries = Object.entries(c.operations);
              if (entries.length === 0) return !c.end_operation;
              const [key, op] = entries[0];
              // No future-call policy marker: this exact old intent never dispatched.
              // Preserve it verbatim; this is not reconciliation of external work.
              return entries.length === 1 && c.state === 'ended' && !c.exchange_operation && !c.lease && !c.media_ready
                && uuid(c.end_operation)
                && key === 'v:' + c.end_operation && op?.operation_id === c.end_operation
                && Object.keys(op).sort().join(',') === 'hash,kind,operation_id,state'
                && op.kind === 'end' && op.state === 'prepared' && /^[a-f0-9]{64}$/.test(op.hash);
            };
            const guards = (expected = old) => {
              const s = maintenance.status();
              check(s.held && !s.invalid && !s.listening && !maintenance.sealing && !control.poisoned
                && Object.entries(s.counts).every(([k, n]) => n === ({ ownerWork: 1, pushPending: 1 }[k] ?? 0))
                && same(control.binding(mapping()), expected), 409);
              if (expiredUnclaimed) {
                check(Number.isSafeInteger(old.expires_at) && old.expires_at <= now()
                  && !Object.hasOwn(mapping(), 'claimed_call_id') && (control.pendingEndNotes ?? 0) === 0
                  && !Object.values(control.state.calls).some(c => c.binding.target_session === old.target_session
                    || c.binding.target_id === old.target_id || c.binding.authority === old.authority), 409);
              } else {
                const claimed = control.state.calls['v:' + claimedCallID];
                check(claimed && (expected !== old || mapping().claimed_call_id === claimedCallID)
                  && same(claimed.binding, old) && ['ended', 'rejected', 'expired'].includes(claimed.state)
                  && !claimed.lease && !claimed.media_ready && !claimed.exchange_operation && unusedOperations(claimed), 409);
              }
              check(!Object.values(control.state.grants).some(g => g.caller_id === old.caller_id && g.project_ids.includes(old.project_id)
                && (expiredUnclaimed || g.scopes.includes('call:request')) && control.grantCurrent(g)), 409);
              check(!control.liveMedia.size && Object.values(control.state.calls).filter(c => c.binding.target_session === old.target_session)
                .every(c => same(c.binding, old) && ['ended', 'rejected', 'expired'].includes(c.state)
                  && !c.lease && !c.media_ready && !c.exchange_operation && unusedOperations(c)), 409);
            };
            guards();
            const metadata = await harness.providerSetup({ pins }); instance(metadata);
            check(same(metadata.pins, pins) && metadata.providerConnected && metadata.modelAvailable && metadata.agentAvailable && metadata.outboundEnabled, 503);
            guards(); attempted = true;
            prepared = await harness.advanceUnused({ binding: old, pins }); identity(prepared);
            check(same(prepared.pins, pins) && prepared.target_session !== old.target_session && prepared.authority !== old.authority, 503);
            await refresh(); guards();
            sealed = undefined;
            control.configureMapping({ caller_id: config.target.caller_id, project_id: config.target.project_id, directory: pins.directory,
              target_session: prepared.target_session, binding_revision: value.next_binding_revision, expires_at: value.expires_at });
            sealed = control.binding(mapping());
            check(sealed.target_id !== old.target_id, 503);
            verified(await harness.verify({ binding: sealed })); await ready(); await refresh(); guards(sealed); armed = true;
            return { prepared: true, armed, target_session: prepared.target_session, target_id: sealed.target_id, binding_revision: sealed.binding_revision };
          }); } finally { advancing = false; maintenance.changing = ownTransition && ownerPreparing; }
        },
        prepareTarget: value => track(async () => {
          exact(value, ['binding_revision', 'expires_at']);
          check(!attempted && Number.isSafeInteger(value.binding_revision) && value.binding_revision > 0
            && Number.isSafeInteger(value.expires_at) && value.expires_at > Date.now() && value.expires_at <= Date.now() + 86400000, 409);
          const capability = await harness.capability({ pins }); identity(capability);
          check(same(capability.pins, pins) && capability.modelAvailable === true && capability.agentAvailable === true
            && capability.providerConnected === true && capability.outboundEnabled === true, 503);
          check(!attempted && !closing, 409); // A concurrent preflight must not allocate a second target.
          attempted = true; // Intent is single-attempt even if the owner socket disappears.
          prepared = await harness.prepare(pins);
          identity(prepared); check(same(prepared.pins, pins), 503);
          await push.serial(() => {
            check(!closing, 503);
            control.configureMapping({ caller_id: config.target.caller_id, project_id: config.target.project_id,
              directory: pins.directory, target_session: prepared.target_session, ...value });
            sealed = control.binding(control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)]);
          });
          const result = await harness.verify({ binding: sealed });
          verified(result); await ready(); check(!closing, 503); armed = true;
          return { prepared: true, armed, target_session: prepared.target_session };
        }),
        status: async () => {
          await refresh();
          return { attempted, prepared: !!prepared, armed: adapter.readyForCalls, pending, SDKWork: sdkWork(), ...harness.stats() };
        },
        providerSetup: () => track(async () => {
          const result = await harness.providerSetup({ pins }); instance(result);
          check(same(result.pins, pins), 503); return result;
        }),
        reconcileProvider: () => track(async () => {
          const result = await harness.reconcileProvider({ pins }); instance(result);
          check(same(result.pins, pins), 503); return result;
        }),
        beginSignIn: () => track(async () => {
          check(!signInAttempted, 409); signInAttempted = true;
          const result = await harness.beginSignIn({ pins }); instance(result); return result;
        }),
        signInStatus: () => track(async () => {
          const result = await harness.signInStatus(); instance(result); return result;
        }),
      };
      admin = await startOpenVoiceAdmin(control, push.store.directory, { ...actions,
        prepareOutreach: async () => {
          check(!ownerPreparing && !closing && !advancing && !pending, 409);
          ownerPreparing = true;
          let held = false, failure;
          try {
            const currentMaintenance = push.maintenance?.status();
            check(currentMaintenance && !currentMaintenance.held && !currentMaintenance.invalid && !push.maintenance.changing, 409);
            control.policy({ preparation: true }); // Same capability/policy, except the not-yet-armed adapter.
            const m = control.state.mappings[control.mappingKey(config.target.caller_id, config.target.project_id)];
            if (armed && sealed && prepared && m && !Object.hasOwn(m, 'claimed_call_id')
              && same(control.binding(m), sealed) && m.expires_at - now() >= 180000) {
              check(currentMaintenance.listening, 409);
              await ready(); await refresh(); check(!sdkWork(), 409);
            } else {
              const maintenance = push.maintenance, s = maintenance?.status();
              // Never take ownership of/release somebody else's existing hold.
              check(s && !s.held && !s.invalid && !maintenance.changing, 409);
              await maintenance.command('hold'); held = true;
              await maintenance.command('seal');
              maintenance.changing = true; // Existing local transition fence, NOT a speech/host lock.
              const metadata = await actions.providerSetup();
              check(metadata.providerConnected && metadata.modelAvailable && metadata.agentAvailable, 503);
              if (!metadata.outboundEnabled) {
                const r = await actions.reconcileProvider();
                check(r.reconciled && r.outboundEnabled, 503); // Saved metadata only; never sign in.
              }
              control.policy({ preparation: true });
              if (m) await actions.advanceUnusedTarget({ target_id: m.target_id, target_session: m.target_session,
                binding_revision: m.binding_revision, next_binding_revision: m.binding_revision + 1, expires_at: now() + 900000 }, true);
              else {
                const s = maintenance.status();
                check(s.held && !s.invalid && !s.listening && s.localQuiet, 409);
                await actions.prepareTarget({ binding_revision: 1, expires_at: now() + 900000 });
              }
            }
            control.policy(); // Actual media/target prerequisite must now hold.
          } catch { failure = 'target_preparation_unavailable'; }
          finally {
            if (held) {
              push.maintenance.changing = false;
              try { await push.maintenance.command('release'); }
              catch { failure = 'maintenance_release_unavailable'; }
            }
            ownerPreparing = false;
          }
          // Release ordinary voice before any caller waits on shared speech.
          return failure ? { prepared: false, reason: failure, providerAcceptance: 'not_proven' }
            : { prepared: true, providerAcceptance: 'not_proven' };
        },
      });
    },
    close: () => cleanup ??= (async () => {
      closing = true;
      check(!ownerPreparing && !advancing && !pending && !harness.stats().pendingRequests, 409);
      await refresh();
      check(!sdkWork() && !pending && !harness.stats().pendingRequests, 409);
      // The real parent/child also requery and refuse busy/unknown. A refusal
      // leaves the owner socket available and never forces child termination.
      await harness.close();
      armed = false; await admin?.close();
    })().catch(error => { closing = false; cleanup = undefined; throw error; }),
  };
}
