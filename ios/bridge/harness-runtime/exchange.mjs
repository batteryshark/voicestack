// One owner-prepared target, one exclusive operation. Private child-process API.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { Effect } from 'effect';
import { Bus } from '@opencode/core/bus';
import { Job } from '@opencode/core/job';
import { Model as CoreModel } from '@opencode/core/model';
import { Provider as CoreProvider } from '@opencode/core/provider';
import { Agent } from '@opencode/core/agent';
import { Integration } from '@opencode/core/integration';
import { Plugin } from '@opencode/core/plugin';
import { LocationServiceMap } from '@opencode/core/location-service-map';
import { Session } from '@opencode/schema/session';
import { SessionEvent } from '@opencode/core/session/event';
import { SessionMessage } from '@opencode/schema/session-message';
import { observeRuntime } from './direct-hooks.mjs';
import { createOwnedHost, validateOwnedRoot } from './owned-host.mjs';
import { observeAuthReceipt } from './auth-receipt.mjs';

const need = value => { if (!value) throw new Error('exchange_refused'); };
const same = isDeepStrictEqual;
const sameModel = (a, b) => !!a && !!b && ['providerID', 'id', 'variant'].every(k => a[k] === b[k]);
const stable = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(value);
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const bindingKeys = ['caller_id', 'project_id', 'target_session', 'directory', 'binding_revision', 'expires_at', 'principal_id', 'audience', 'device_id', 'target_id', 'authority', 'pins'];
const validBinding = binding => binding && Object.keys(binding).length === bindingKeys.length && bindingKeys.every(k => Object.hasOwn(binding, k))
  && ['caller_id', 'project_id', 'principal_id', 'audience', 'device_id'].every(k => stable(binding[k])) && uuid(binding.target_id)
  && Number.isSafeInteger(binding.binding_revision) && binding.binding_revision > 0 && Number.isSafeInteger(binding.expires_at) && binding.expires_at > Date.now();
const copy = value => structuredClone(value);
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(k => [k, ordered(value[k])])) : value;
const validPins = pins => pins && Object.keys(pins).length === 3 && Object.keys(pins).every(k => ['directory', 'agent', 'model'].includes(k)) && stable(pins.agent)
  && path.isAbsolute(pins.directory) && fs.realpathSync(pins.directory) === pins.directory
  && stable(pins.model?.providerID) && typeof pins.model?.id === 'string' && /^[A-Za-z0-9_.:/-]{1,128}$/.test(pins.model.id) && pins.model.id.toLowerCase() !== 'auto'
  && Object.keys(pins.model).every(k => ['providerID', 'id', 'variant'].includes(k)) && stable(pins.model.variant);

export async function createExchange({ root, plugins = [], overrides = [], bundledModels = false, deadlineMs = 120000,
  onProviderPhase = () => {}, authPollMs = 1000, authMaxMs = 635000 }) {
  validateOwnedRoot(root);
  need(Number.isInteger(deadlineMs) && deadlineMs > 0 && deadlineMs <= 120000);
  need(Number.isInteger(authPollMs) && authPollMs > 0 && authPollMs <= 1000 && Number.isInteger(authMaxMs) && authMaxMs > 0 && authMaxMs <= 635000);
  const identityFile = path.join(root, 'instance-id');
  if (!fs.existsSync(identityFile)) {
    const fd = fs.openSync(identityFile, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(fd, crypto.randomUUID()); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    const dir = fs.openSync(root, 'r'); try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  }
  const identityStat = fs.lstatSync(identityFile);
  need(identityStat.isFile() && !identityStat.isSymbolicLink() && identityStat.uid === process.getuid() && identityStat.nlink === 1 && identityStat.size === 36);
  const instanceID = fs.readFileSync(identityFile, 'utf8'); need(uuid(instanceID));
  const file = path.join(root, 'exchange.json');
  let state = null, closed = false, poisoned = false, preparing = false, owned, unsubscribe;
  let accountingUnknown = false;
  let workRevision = 0;
  let expectedText, submitting = false, appending = false;
  let signIn, signInPins, authReceipt, authStarting = false, authKnown = true, outboundEnabled = false;
  const providerPhase = phase => { outboundEnabled = phase === 'provider'; onProviderPhase(phase); };
  const waiters = new Set();
  const workWaiters = new Set();
  const save = () => {
    try {
      workRevision = Math.max(workRevision + 1, (state.revision ?? 0) + 1);
      state.revision = workRevision;
      state.localAccountingUnknown = accountingUnknown;
      const bytes = JSON.stringify(state); need(Buffer.byteLength(bytes) <= 131072);
      const tmp = file + '.tmp';
      const fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_NOFOLLOW, 0o600);
      try { fs.writeFileSync(fd, bytes); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      fs.renameSync(tmp, file); const dir = fs.openSync(root, 'r'); try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
    } catch (error) { poisoned = true; accountingUnknown = true; throw error; }
  };
  const wake = () => {
    for (const resolve of [...waiters, ...workWaiters]) resolve();
    waiters.clear(); workWaiters.clear();
  };
  const uncertain = reason => {
    if (reason === 'event_gap' || reason === 'descendant_bound') accountingUnknown = true;
    if (state) {
      if (reason !== 'process_restarted') state.retirement_blocked = true;
      state.unsafe ??= reason;
      if (state.status !== 'completed') { state.status = 'uncertain'; state.reason ??= reason; state.candidate = null; }
      save();
    }
    wake();
  };
  if (fs.existsSync(file)) {
    const st = fs.lstatSync(file); need(st.isFile() && !st.isSymbolicLink() && st.uid === process.getuid() && st.nlink === 1 && st.size <= 131072);
    state = JSON.parse(fs.readFileSync(file, 'utf8')); need(state.version === 1);
    accountingUnknown = state.localAccountingUnknown === true || ['event_gap', 'job_bound', 'descendant_bound'].includes(state.unsafe ?? state.reason);
    if (state.status !== 'completed') uncertain('process_restarted');
  }
  const tracked = sessionID => state && Object.hasOwn(state.sessions, sessionID);
  const rootSession = sessionID => state?.target_session === sessionID;
  const jobOwner = data => data.recovery?.parentSessionID ?? data.recovery?.sessionID ?? data.metadata?.sessionID;
  const stopHooks = observeRuntime((type, data) => {
    if (closed) return;
    if (!state) { if (type === 'job-start') accountingUnknown = true; return; }
    if (poisoned) { accountingUnknown = true; return; }
    const proofActive = !['completed', 'uncertain'].includes(state.status);
    if (type === 'job-start') {
      if (Object.keys(state.jobs).length >= 128 && !state.jobs[data.id]) { accountingUnknown = true; return uncertain('job_bound'); }
      state.jobs[data.id] = { owner: jobOwner(data), status: 'running' };
      if (!tracked(jobOwner(data))) return uncertain('unowned_job');
    }
    else if (type === 'job-settled' && state.jobs[data.id]) state.jobs[data.id].status = data.status;
    else if (type === 'job-background' && state.jobs[data.id]) {
      if (!stable(data.notificationID)) return uncertain('unidentified_background_notification');
      state.jobs[data.id].notificationID = data.notificationID;
    } else if (type === 'execution-settled' && tracked(data.sessionID)) { /* Coordinator truth is queried at reconciliation. */ }
    else if (type === 'step-enter' && rootSession(data.sessionID) && proofActive) state.candidate = null;
    else if (type === 'candidate' && rootSession(data.sessionID) && proofActive) {
      if (data.needsContinuation) state.candidate = null;
      else {
        if (data.agent !== state.pins.agent || !sameModel(data.model, state.pins.model)) return uncertain('candidate_pin_mismatch');
        if (state.candidate && state.candidate !== data.assistantMessageID) return uncertain('ambiguous_final_candidate');
        state.candidate = data.assistantMessageID;
      }
    } else return;
    save(); wake();
  });
  try {
    need(SessionEvent.VoiceEnded?.type === 'session.voice.ended' && SessionMessage.System.fields.historyOnly);
    for (const [chunk, marker] of [['instance-71svxegq.js', 'runtimeHook("candidate"'], ['instance-xnn7a7ef.js', 'runtimeHook("job-start"'], ['instance-yp2x3t23.js', 'runtimeHook("execution-settled"'],
      ['instance-6btvgc07.js', 'bus.project(SessionEvent2.VoiceEnded'], ['instance-xt4njr3s.js', 'message.historyOnly === true ? []']]) {
      need(fs.readFileSync(new URL(`./node_modules/@opencode/core/dist/chunks/${chunk}`, import.meta.url), 'utf8').includes(marker));
    }
    owned = await createOwnedHost({ root, plugins, overrides, bundledModels });
    const run = effect => owned.host.runtime.runPromise(effect);
    unsubscribe = await run(Bus.Service.use(bus => bus.listen(event => Effect.sync(() => {
      if (!state || closed || !event.durable) return;
      if (poisoned) { accountingUnknown = true; return; }
      const data = event.data, sid = data.sessionID;
      if (event.type === 'session.created' && !tracked(sid)) {
        if (Object.keys(state.sessions).length >= 128) return uncertain('descendant_bound');
        state.sessions[sid] = { seq: -1, terminal: false };
        if (!tracked(data.parentID)) return uncertain('unowned_session');
      }
      if (!tracked(sid)) return;
      const trackedSession = state.sessions[sid];
      if (event.durable.aggregateID !== sid || event.durable.seq !== trackedSession.seq + 1) return uncertain('event_gap');
      trackedSession.seq = event.durable.seq;
      if (rootSession(sid)) {
        if (event.type === 'session.inbox.enqueued') {
          state.candidate = null;
          const op = state.operation;
          if (op && data.inboxID === op.planned_inbox_id && data.item.type === 'user' && !op.admission_inbox_id) {
            if (data.item.payload.text !== expectedText || ['files', 'agents', 'skills'].some(k => data.item.payload[k]?.length)) return uncertain('canonical_input_changed');
            op.admission_inbox_id = data.inboxID; state.status = 'admitted';
          } else if (!(data.item.type === 'synthetic' && Object.values(state.jobs).some(job => job.notificationID === data.inboxID))) return uncertain('competing_input');
        }
        if (event.type === 'session.inbox.delivered' && data.inboxID === state.operation?.planned_inbox_id) state.operation.source_user_id = data.inboxID;
        if (event.type === 'session.execution.started' || event.type === 'session.step.started') state.candidate = null;
        if (event.type === 'session.model.selected' && !sameModel(data.model, state.pins.model) || event.type === 'session.agent.selected' && data.agent !== state.pins.agent) return uncertain('target_pin_changed');
        if (['session.moved', 'session.deleted', 'session.revert.committed'].includes(event.type)) return uncertain('target_changed');
      }
      if (event.type === 'session.execution.started') trackedSession.terminal = false;
      if (event.type === 'session.execution.succeeded') trackedSession.terminal = true;
      if (event.type === 'session.execution.failed' || event.type === 'session.execution.interrupted') {
        if (rootSession(sid)) return uncertain('execution_not_successful');
        trackedSession.terminal = true; // Parent may truthfully handle a failed child tool result.
      }
      save(); wake();
    }))));
    const verifyPins = async () => {
      need(state && !closed && !poisoned && !state.unsafe && state.status !== 'uncertain');
      const session = await run(owned.host.sessions.get(state.target_session));
      if (session.location.directory !== state.pins.directory) throw new Error('directory_pin_mismatch');
      if (session.agent !== state.pins.agent) throw new Error('agent_pin_mismatch');
      if (!sameModel(session.model, state.pins.model)) throw new Error('model_pin_mismatch');
      return session;
    };
    const reconcile = async () => {
      if (!state || poisoned || closed || state.status === 'completed' || state.status === 'uncertain' || !state.candidate) return;
      const candidate = state.candidate, revision = state.revision;
      if (!state.operation?.source_user_id || !Object.values(state.sessions).every(s => s.terminal)) return;
      const active = await run(owned.host.sessions.active);
      if (Object.keys(state.sessions).some(sid => active.has(sid))) return;
      const pending = await run(Job.Service.use(jobs => jobs.pendingBackground));
      if (pending.some(item => tracked(item.recovery.parentSessionID ?? item.recovery.sessionID))) return;
      for (const id of Object.keys(state.jobs)) {
        const job = await run(Job.Service.use(jobs => jobs.get(id)));
        // A consumed foreground result may be absent; our actual settlement
        // callback is required then. Missing running work is never success.
        if (job?.status === 'running' || !job && state.jobs[id].status === 'running') return;
      }
      if ((await run(owned.host.sessions.inbox(state.target_session))).length) return;
      await verifyPins();
      const message = await run(owned.host.sessions.message({ sessionID: state.target_session, messageID: candidate }));
      if (state.status === 'uncertain' || state.candidate !== candidate || state.revision !== revision) return;
      need(message?.type === 'assistant' && message.time.completed !== undefined && !message.error && message.finish === 'stop');
      need(message.content.every(part => part.type !== 'tool' || ['completed', 'error'].includes(part.state.status)));
      const text = message.content.filter(part => part.type === 'text').map(part => part.text).join('');
      need(Buffer.byteLength(text) <= 64000 && stable(candidate) && candidate !== state.operation.source_user_id);
      state.result = { admission_inbox_id: state.operation.admission_inbox_id, source_user_id: state.operation.source_user_id, source_assistant_id: candidate, text };
      state.status = 'completed'; save(); wake();
    };
    const snapshot = () => copy(state ? { status: state.status, reason: state.reason, target_session: state.target_session,
      operation_id: state.operation?.operation_id, admission_inbox_id: state.operation?.admission_inbox_id,
      source_user_id: state.operation?.source_user_id, result: state.result } : { status: 'unprepared' });
    const capability = async ({ pins } = {}) => {
      if (pins !== undefined) { need(validPins(pins)); if (state) need(same(pins, state.pins)); }
      const selected = copy(pins ?? state?.pins);
      const result = { instance_id: instanceID, runtime_version: '2.0.32', target_session: state?.target_session, authority: state?.authority, pins: selected,
        modelAvailable: false, agentAvailable: false, providerConnected: false, bindingVerified: false, singleUseAvailable: false,
        ready: false, providerAcceptance: 'not_proven', reason: 'unprepared' };
      if (!selected || closed || poisoned) return result;
      result.singleUseAvailable = state?.status === 'prepared' && !state.operation && !state.end_note;
      result.bindingVerified = !!state?.binding && validBinding(state.binding);
      if (state?.unsafe || state?.status === 'uncertain') { result.reason = 'exchange_uncertain'; return result; }
      if (state) await verifyPins();
      const available = await run(Effect.gen(function* () {
        yield* Plugin.Service.use(plugins => plugins.awaitActivation);
        const models = yield* CoreModel.Service, providers = yield* CoreProvider.Service;
        const agents = yield* Agent.Service, integrations = yield* Integration.Service;
        const provider = yield* providers.get(selected.model.providerID);
        const model = (yield* models.available()).find(m => m.providerID === selected.model.providerID && m.id === selected.model.id);
        const agent = yield* agents.get(selected.agent);
        const integration = provider?.integrationID ? yield* integrations.get(provider.integrationID) : undefined;
        // Metadata-only supported accessor, never resolve or export a secret.
        const connection = integration?.connections[0];
        return { model: !!model && model.enabled && model.capabilities.tools && model.capabilities.output.includes('text')
          && (selected.model.variant === 'default' || model.variants.some(v => v.id === selected.model.variant)),
          agent: !!agent && ['primary', 'all'].includes(agent.mode), connected: !!connection && connection.status?.status !== 'needs_auth'
            && (provider.integrationID !== 'openai' || connection.method === 'oauth'
              && provider.settings?.baseURL === 'https://chatgpt.com/backend-api/codex') };
      }).pipe(Effect.provide(LocationServiceMap.Service.get({ directory: selected.directory }))));
      result.modelAvailable = available.model; result.agentAvailable = available.agent; result.providerConnected = available.connected;
      result.singleUseAvailable = state?.status === 'prepared' && !state.operation && !state.end_note;
      result.bindingVerified = !!state?.binding && validBinding(state.binding);
      result.ready = result.singleUseAvailable && result.modelAvailable && result.agentAvailable && result.providerConnected && result.bindingVerified && !closed && !poisoned && !accountingUnknown;
      result.reason = result.ready ? 'local_configuration_available' : !result.providerConnected ? 'provider_not_connected'
        : !result.modelAvailable ? 'model_unavailable' : !result.agentAvailable ? 'agent_unavailable' : 'binding_unverified';
      if (!state && available.model && available.agent && available.connected) result.reason = 'target_unprepared';
      if (state && !result.singleUseAvailable) result.reason = 'single_use_unavailable';
      return result;
    };
    const providerOperation = async (pins, callback) => {
      const selected = copy(pins ?? state?.pins ?? signInPins);
      need(validPins(selected) && !preparing && !closed && !poisoned && !state?.operation);
      if (state) need(same(selected, state.pins));
      if (signInPins) need(same(selected, signInPins));
      return run(Effect.gen(function* () {
        yield* Plugin.Service.use(plugins => plugins.awaitActivation);
        const providers = yield* CoreProvider.Service, integrations = yield* Integration.Service;
        const provider = yield* providers.get(selected.model.providerID);
        const integration = provider?.integrationID ? yield* integrations.get(provider.integrationID) : undefined;
        need(integration);
        return yield* callback(integrations, integration, selected);
      }).pipe(Effect.provide(LocationServiceMap.Service.get({ directory: selected.directory }))));
    };
    const providerMetadata = (pins) => providerOperation(pins, (_, integration, selected) => Effect.gen(function* () {
      const providers = yield* CoreProvider.Service, models = yield* CoreModel.Service, agents = yield* Agent.Service;
      const provider = yield* providers.get(selected.model.providerID);
      const model = (yield* models.available()).find(m => m.providerID === selected.model.providerID && m.id === selected.model.id);
      const agent = yield* agents.get(selected.agent);
      const connection = integration.connections[0]; // Normal saved-connection metadata only.
      const modelAvailable = !!model && model.enabled && model.capabilities.tools && model.capabilities.output.includes('text')
        && (selected.model.variant === 'default' || model.variants.some(v => v.id === selected.model.variant));
      const agentAvailable = !!agent && ['primary', 'all'].includes(agent.mode);
      const providerConnected = selected.model.providerID === 'openai' && provider?.id === 'openai' && integration.id === 'openai'
        && connection?.type === 'credential' && connection.method === 'oauth' && connection.status === undefined
        && provider.settings?.baseURL === 'https://chatgpt.com/backend-api/codex';
      return { instance_id: instanceID, pins: selected, providerID: selected.model.providerID, integrationID: integration.id,
        methods: integration.methods.filter(method => selected.model.providerID === 'openai' && integration.id === 'openai'
          && method.type === 'oauth' && method.id === 'chatgpt-headless').map(method => ({ id: method.id, type: method.type, label: method.label })),
        modelAvailable, agentAvailable, providerConnected, outboundEnabled, providerAcceptance: 'not_proven' };
    }));
    const authChanged = () => { workRevision++; wake(); };
    const runtimeStats = async (ownPreparation = false) => {
      const base = { closed, targets: state ? 1 : 0, operations: state?.operation ? 1 : 0, pendingRequests: Number(submitting) + Number(appending) };
      if (closed) return { ...base, localWorkKnown: true, localWorkPending: false, localWorkRevision: workRevision };
      const revision = workRevision;
      try {
        let pending = appending || submitting || preparing && !ownPreparation || authStarting || !!authReceipt?.work().busy;
        const active = await run(owned.host.sessions.active); pending ||= active.size > 0;
        const notifications = await run(Job.Service.use(jobs => jobs.pendingBackground)); pending ||= notifications.length > 0;
        let known = !poisoned && !accountingUnknown && authKnown && (authReceipt?.work().known ?? true);
        for (const [id, remembered] of Object.entries(state?.jobs ?? {})) {
          const actual = await run(Job.Service.use(jobs => jobs.get(id)));
          pending ||= actual?.status === 'running';
          if (!actual && remembered.status === 'running') known = false;
        }
        for (const sid of Object.keys(state?.sessions ?? {})) pending ||= (await run(owned.host.sessions.inbox(sid))).length > 0;
        if (workRevision !== revision) known = false;
        return { ...base, localWorkKnown: known, localWorkPending: !known || pending, localWorkRevision: workRevision };
      } catch {
        return { ...base, localWorkKnown: false, localWorkPending: true, localWorkRevision: workRevision };
      }
    };
    const newTarget = async (pins, retired_unused) => {
      const id = Session.ID.create();
      const next = { version: 1, authority: crypto.randomUUID(), target_session: id, pins: copy(pins), status: 'prepared',
        sessions: { [id]: { seq: -1, terminal: false } }, jobs: {}, operation: null, candidate: null,
        ...(retired_unused ? { retired_unused: copy(retired_unused) } : {}) };
      need(Buffer.byteLength(JSON.stringify({ ...next, revision: workRevision + 1, localAccountingUnknown: false })) <= 131072);
      state = next; save(); // Fail-closed intent, including immutable old evidence, BEFORE native allocation.
      await run(owned.host.sessions.create({ id, location: { directory: pins.directory }, agent: pins.agent, model: pins.model, title: 'Private single-use voice exchange' }));
      await verifyPins();
      need(!(await run(owned.host.sessions.context(id))).some(m => ['user', 'assistant', 'synthetic', 'shell', 'system'].includes(m.type)));
      return { instance_id: instanceID, runtime_version: '2.0.32', target_session: id, authority: state.authority, pins: copy(state.pins) };
    };
    return {
      capability,
      runtimeStats,
      async waitUntilLocalQuiet() {
        while (!closed) {
          let resolve;
          const changed = new Promise(r => { resolve = r; workWaiters.add(r); });
          const local = await runtimeStats();
          if (local.localWorkKnown && !local.localWorkPending) { workWaiters.delete(resolve); return local; }
          await changed;
        }
      },
      providerSetup: ({ pins } = {}) => providerMetadata(pins),
      async reconcileProvider({ pins } = {}) {
        need(!preparing && !closed && !state?.operation && !accountingUnknown && !poisoned && !authStarting && !authReceipt?.work().busy && authKnown && (authReceipt?.work().known ?? true));
        providerPhase('closed'); // Explicit idle revalidation never inherits a prior phase.
        const metadata = await providerMetadata(pins);
        need(!closed && !poisoned && !accountingUnknown && !state?.operation && !authStarting && !authReceipt?.work().busy && authKnown && (authReceipt?.work().known ?? true));
        if (signInPins) need(same(metadata.pins, signInPins));
        const reconciled = metadata.providerConnected && metadata.modelAvailable && metadata.agentAvailable;
        if (reconciled) { signInPins ??= copy(metadata.pins); providerPhase('provider'); }
        return { ...metadata, outboundEnabled, reconciled, receipt: authReceipt?.snapshot().status ?? 'receipt_unavailable' };
      },
      async beginSignIn({ pins } = {}) {
        need(!preparing && !signIn); // Explicit owner attempt only, never retry after a lost reply.
        signIn = { status: 'starting' }; authStarting = true; authChanged();
        let nativeStarted = false;
        try { return await providerOperation(pins, (integrations, integration, selected) => Effect.gen(function* () {
          need(selected.model.providerID === 'openai' && integration.id === 'openai'
            && integration.methods.some(method => method.type === 'oauth' && method.id === 'chatgpt-headless'));
          signInPins = selected;
          providerPhase('auth');
          nativeStarted = true;
          const attempt = yield* integrations.oauth.connect({ integrationID: integration.id, methodID: 'chatgpt-headless' }).pipe(Effect.timeout('30 seconds'));
          signIn = { status: 'pending', integrationID: integration.id, attemptID: attempt.attemptID };
          // Capture THIS service and exact IDs, never reselect via a changed provider.
          const input = { integrationID: integration.id, attemptID: attempt.attemptID };
          authReceipt = observeAuthReceipt({ expires: attempt.time.expires, pollMs: authPollMs, maxMs: authMaxMs, changed: authChanged,
            read: ms => run(integrations.oauth.status(input).pipe(
              Effect.map(status => ({ status: status.status, time: { created: status.time.created, expires: status.time.expires } })),
              Effect.catchTag('Integration.AttemptNotFound', () => Effect.succeed({ status: 'receipt_unavailable', reason: 'native_attempt_not_found' })),
              Effect.timeout(ms))),
            cancel: ms => run(integrations.oauth.cancel(input).pipe(Effect.timeout(ms))),
            terminal: status => providerPhase(status === 'complete' ? 'provider' : 'closed'),
          });
          return { instance_id: instanceID, ...attempt };
        })); }
        catch (error) { authKnown = !nativeStarted; if (nativeStarted) providerPhase('closed'); throw error; }
        finally { authStarting = false; authChanged(); }
      },
      async signInStatus() {
        need(!closed);
        return { instance_id: instanceID, ...(authReceipt?.snapshot() ?? { status: 'receipt_unavailable', reason: signIn ? 'attempt_start_unobserved' : 'no_process_receipt' }) };
      },
      async prepare(pins) {
        need(!state && !preparing && !closed && !poisoned && !accountingUnknown); preparing = true;
        try {
          need(validPins(pins));
          if (signInPins) need(same(pins, signInPins));
          return await newTarget(pins);
        } catch (error) { if (state) uncertain('prepare_uncertain'); throw error; } finally { preparing = false; }
      },
      async advanceUnused({ binding, pins }) {
        const old = state;
        need(old && !closed && !poisoned && !accountingUnknown && !preparing && !submitting && !appending && !old.end_note);
        // Exact seal comparison intentionally permits EXPIRED old authority for retirement, not reuse.
        need(binding && Object.keys(binding).length === bindingKeys.length && bindingKeys.every(k => Object.hasOwn(binding, k))
          && same(binding, old.binding) && validPins(pins) && same(pins, old.pins) && (!signInPins || same(pins, signInPins)));
        need(!old.retirement_blocked && !old.operation && !old.result && !old.candidate && Object.keys(old.jobs).length === 0
          && Object.keys(old.sessions).length === 1 && tracked(old.target_session)
          && (old.status === 'prepared' && !old.unsafe || old.status === 'uncertain' && old.reason === 'process_restarted' && old.unsafe === 'process_restarted'));
        preparing = true; authChanged();
        try {
          const revision = workRevision, quiet = await runtimeStats(true);
          need(quiet.localWorkKnown && !quiet.localWorkPending);
          const session = await run(owned.host.sessions.get(old.target_session));
          need(session.location.directory === pins.directory && session.agent === pins.agent && sameModel(session.model, pins.model));
          need(!(await run(owned.host.sessions.context(old.target_session))).some(m => ['user', 'assistant', 'synthetic', 'shell', 'system'].includes(m.type)));
          need((await run(owned.host.sessions.inbox(old.target_session))).length === 0);
          const final = await runtimeStats(true);
          need(final.localWorkKnown && !final.localWorkPending && workRevision === revision && state === old && same(binding, old.binding));
          return await newTarget(pins, old);
        } catch (error) { if (state !== old) uncertain('advance_uncertain'); throw error; }
        finally { preparing = false; authChanged(); }
      },
      async verify({ binding }) {
        const safe = () => state && !preparing && !closed && !poisoned && !accountingUnknown && !state.unsafe && ['prepared', 'dispatching', 'admitted', 'completed'].includes(state.status);
        need(safe());
        need(validBinding(binding) && binding.target_session === state.target_session && binding.directory === state.pins.directory);
        need(binding.authority === state.authority && same(binding.pins, state.pins));
        if (state.binding) need(same(state.binding, binding));
        else need(state.status === 'prepared' && !state.operation);
        await verifyPins(); need(safe());
        // Recheck after the asynchronous pin read. First verification may race
        // another verification/admission; an existing seal is never replaced.
        if (state.binding) need(same(state.binding, binding));
        else { need(state.status === 'prepared' && !state.operation); state.binding = copy(binding); save(); }
        return { instance_id: instanceID, runtime_version: '2.0.32', target_session: state.target_session, authority: state.authority,
          pins: copy(state.pins), exclusive: true, single_use: true, single_use_available: !state.operation && !state.end_note, continuation: !!state.operation };
      },
      async submit(input) {
        need(!preparing && !submitting && !appending && !state?.end_note && state?.status === 'prepared' && state.binding && !state.operation && !poisoned && !closed);
        need(validBinding(input?.binding) && input && Object.keys(input).length === 5 && ['call_id', 'binding', 'operation_id', 'planned_inbox_id', 'item'].every(k => Object.hasOwn(input, k))
          && uuid(input.call_id) && uuid(input.operation_id) && /^msg_[A-Za-z0-9]{8,64}$/.test(input.planned_inbox_id) && same(input.binding, state.binding)
          && input.item?.type === 'message' && input.item.role === 'user' && stable(input.item.id) && input.item.content?.length === 1
          && input.item.content[0].type === 'input_text' && typeof input.item.content[0].text === 'string' && input.item.content[0].text.length <= 16000);
        submitting = true;
        state.operation = { call_id: input.call_id, operation_id: input.operation_id, planned_inbox_id: input.planned_inbox_id,
          hash: crypto.createHash('sha256').update(JSON.stringify(input.item)).digest('hex') };
        expectedText = input.item.content[0].text; state.status = 'dispatching'; save();
        let timer, timeout = false;
        timer = setTimeout(() => { timeout = true; wake(); }, deadlineMs);
        try {
          await verifyPins();
          const receipt = await run(owned.host.sessions.prompt({ sessionID: state.target_session, id: input.planned_inbox_id, text: expectedText, resume: false }));
          need(receipt.id === input.planned_inbox_id && receipt.sessionID === state.target_session && state.operation.admission_inbox_id === receipt.id);
          // Starts only the once-admitted exchange. No automatic recovery retry.
          run(owned.host.sessions.resume(state.target_session)).then(wake, () => uncertain('execution_failed'));
          while (!['completed', 'uncertain'].includes(state.status)) {
            const changed = new Promise(resolve => waiters.add(resolve));
            await reconcile();
            if (state.status === 'completed' || state.status === 'uncertain') break;
            if (timeout) { uncertain('completion_deadline'); break; }
            await changed;
          }
          need(state.status === 'completed'); return copy(state.result);
        } catch (error) { if (state.status !== 'completed') uncertain(state.reason ?? 'admission_or_completion_uncertain'); throw error; }
        finally { clearTimeout(timer); waiters.clear(); submitting = false; expectedText = undefined; }
      },
      async appendEnd(input) {
        need(state && !closed && !poisoned && !accountingUnknown && !preparing && !appending);
        need(input && Object.keys(input).sort().join(',') === 'assistant_response,binding,call_id,operation_id,owner_epoch,role,text'
          && validBinding(input.binding) && same(input.binding, state.binding) && uuid(input.call_id)
          && uuid(input.operation_id) && uuid(input.owner_epoch) && input.role === 'system'
          && input.text === '[voice] ended' && input.assistant_response === false
          && (!state.operation || state.operation.call_id === input.call_id));
        const hash = crypto.createHash('sha256').update(JSON.stringify(ordered([input.binding,
          input.call_id, input.owner_epoch, input.operation_id, input.text]))).digest('hex');
        const eventID = 'evt_voiceend' + hash, messageID = SessionMessage.ID.fromEvent(eventID);
        if (state.end_note) {
          need(state.end_note.hash === hash && state.end_note.state === 'completed');
          return copy(state.end_note.receipt); // No publish, including after reopen.
        }
        appending = true; workRevision++; wake();
        try {
          await verifyPins();
          need(!closed && !poisoned && !accountingUnknown && !state.unsafe && state.status !== 'uncertain'
            && !state.end_note && same(state.binding, input.binding));
          state.end_note = { hash, event_id: eventID, state: 'dispatching' }; save();
          await run(Bus.Service.use(bus => bus.publish(SessionEvent.VoiceEnded, {
            sessionID: state.target_session, callID: input.call_id, operationID: input.operation_id,
            ownerEpoch: input.owner_epoch, text: '[voice] ended',
          }, { id: eventID })));
          const note = await run(owned.host.sessions.message({ sessionID: state.target_session, messageID }));
          need(note?.type === 'system' && note.historyOnly === true && note.text === '[voice] ended');
          state.end_note.receipt = { target_session: state.target_session, message_id: messageID };
          state.end_note.state = 'completed'; save();
          return copy(state.end_note.receipt);
        } catch (error) {
          if (state.end_note && !poisoned) { state.end_note.state = 'uncertain'; save(); }
          throw error;
        } finally { appending = false; workRevision++; wake(); }
      },
      async read({ call_id, operation_id }) {
        need(state?.operation?.call_id === call_id && state.operation.operation_id === operation_id);
        await reconcile(); return snapshot();
      },
      stats: () => ({ closed, targets: state ? 1 : 0, operations: state?.operation ? 1 : 0, pendingRequests: Number(submitting) + Number(appending) }),
      async close() {
        if (closed) return;
        need(!appending && !preparing && !authStarting && !authReceipt?.work().busy && authKnown && (authReceipt?.work().known ?? true));
        if (submitting) uncertain('owner_closing');
        closed = true; wake();
        await run(unsubscribe); stopHooks(); await owned.close();
      },
    };
  } catch (error) { stopHooks(); await owned?.close(); throw error; }
}
