import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
let forbiddenAttempts = 0;
const deny = () => { forbiddenAttempts++; throw new Error('fixture_network_forbidden'); };
globalThis.fetch = deny; net.Socket.prototype.connect = deny; net.Server.prototype.listen = deny; syncBuiltinESMExports();
const { Context, Effect, Layer, Logger, Scope } = await import('effect');
const { LLMClient } = await import('@opencode/ai');
const { TestLLM } = await import('@opencode/ai/testing');
const { HttpClient, HttpClientResponse } = await import('effect/http');
const { httpClient } = await import('@opencode/util/effect/app-node-platform');
const { llmClient } = await import('@opencode/core/effect/app-node-platform');
const { Provider } = await import('@opencode/schema/provider');
const { Model } = await import('@opencode/schema/model');
const { Job } = await import('@opencode/core/job');
const { Bus } = await import('@opencode/core/bus');
const { Session: CoreSession } = await import('@opencode/core/session');
const { Credential: CoreCredential } = await import('@opencode/core/credential');
const { runtimeHook } = await import('./direct-hooks.mjs');
const { createExchange } = await import('./exchange.mjs');
const root = process.env.VOICE_FIXTURE_ROOT, mode = process.argv[2] ?? 'foreground';
const endMode = mode.startsWith('end-note');
const background = endMode || ['background', 'competing', 'ambiguous', 'deadline'].includes(mode);
const lostEnd = ['end-note-lost', 'end-note-dispatched'].includes(mode);
const events = []; let testLLM, loseReceipt = lostEnd, endInput, endReceipt, endProof;
let toolsExecuted = 0, allocations = 0, realJobs, realSessions, realCredentials, unknownWork = false;
const fixtureRun = effect => Effect.runPromise(effect.pipe(Effect.provide(Logger.layer([]))));
const gate = Promise.withResolvers();
const plugin = { id: 'voice.synthetic-fixture', effect: ctx => Effect.gen(function* () {
  const scope = yield* Scope.Scope;
  yield* ctx.provider.transform(editor => {
    const providerID = Provider.ID.make('voice-synthetic');
    editor.add({ info: { ...Provider.Info.empty(providerID), activation: 'enabled', package: '@opencode/ai/providers/openai-compatible', settings: { baseURL: 'http://fixture.invalid' } }, models: [Model.Info.default(providerID, Model.ID.make('fixture'))] });
  });
  yield* ctx.session.hook('title', event => Effect.sync(() => { event.result = 'Synthetic fixture'; }));
  yield* ctx.tool.transform(editor => editor.add({ name: 'fixture_compute', options: { codemode: false }, description: 'Synthetic fixture arithmetic',
    input: { type: 'object', properties: {}, additionalProperties: false },
    execute: (_, context) => Effect.gen(function* () {
      toolsExecuted++;
      if (background) {
        const job = yield* realJobs.start({ id: 'job_fixture', type: 'synthetic', metadata: { sessionID: context.sessionID },
          recovery: { kind: 'shell', sessionID: context.sessionID, shellID: 'shell_fixture', command: 'synthetic-no-process' },
          run: Effect.promise(() => gate.promise).pipe(Effect.as('42')) });
        const backgrounded = yield* realJobs.background(job.id);
        yield* Effect.gen(function* () {
          yield* realJobs.wait({ id: job.id });
          yield* ctx.session.synthetic({ sessionID: context.sessionID, id: backgrounded.notificationID, text: 'Synthetic job finished: 42.' });
          yield* realJobs.completeBackground(backgrounded.notificationID);
        }).pipe(Effect.forkIn(scope, { startImmediately: true }));
        return { content: [{ type: 'text', text: 'The synthetic job is still running.' }] };
      }
      return { content: [{ type: 'text', text: '42' }] };
    }),
  }));
}) };
const overrides = [
  Bus.node.replace(Bus.node.mapLayer(layer => Layer.flatMap(layer, context => Layer.effect(Bus.Service, Effect.gen(function* () {
    const bus = Context.get(context, Bus.Service);
    // Both global and location layers can observe the same committed envelope.
    const unlisten = yield* bus.listen(event => Effect.sync(() => { if (!events.some(e => e.id === event.id)) events.push(event); }));
    yield* Effect.addFinalizer(() => unlisten);
    return bus;
  }))))),
  llmClient.replace(Layer.effect(LLMClient.Service, Effect.gen(function* () {
    const context = yield* Layer.build(TestLLM.testLayer()); const test = Context.get(context, TestLLM.Test);
    testLLM = test;
    yield* test.push(TestLLM.tool('call_fixture', 'fixture_compute', {}),
      ...background ? [TestLLM.text('Preliminary reply while the job runs.', 'text_intermediate')] : [],
      TestLLM.text('The synthetic tool returned 42.', 'text_final'));
    return test;
  }))),
  Job.node.replace(Job.node.mapLayer(layer => Layer.flatMap(layer, context => {
    realJobs = Context.get(context, Job.Service); return Layer.succeed(Job.Service, { ...realJobs,
      get pendingBackground() { return unknownWork ? Effect.fail(new Error('synthetic_accounting_unavailable')) : realJobs.pendingBackground; } });
  }))),
  CoreSession.node.replace(CoreSession.node.mapLayer(layer => Layer.flatMap(layer, context => {
    realSessions = Context.get(context, CoreSession.Service);
    return Layer.succeed(CoreSession.Service, { ...realSessions,
      message: input => realSessions.message(input).pipe(Effect.flatMap(message => {
        if (loseReceipt && input.messageID.startsWith('msg_voiceend')) { loseReceipt = false; return Effect.fail(new Error('lost_note_receipt')); }
        return Effect.succeed(message);
      })),
      create: input => Effect.sync(() => {
        allocations++;
        if (mode === 'advance-unused' && allocations >= 2) {
          const intent = JSON.parse(fs.readFileSync(path.join(root, 'exchange.json'), 'utf8'));
          assert.equal(intent.target_session, input.id); assert.ok(intent.retired_unused);
          assert.notEqual(intent.retired_unused.target_session, input.id);
        }
      }).pipe(Effect.andThen(realSessions.create(input))),
      ...(['lost-receipt', 'advance-operation'].includes(mode) ? {
      prompt: input => realSessions.prompt(input).pipe(Effect.flatMap(() => Effect.fail(new Error('synthetic_lost_admission_receipt')))),
      } : {}),
    });
  }))),
  CoreCredential.node.replace(CoreCredential.node.mapLayer(layer => Layer.flatMap(layer, context => {
    realCredentials = Context.get(context, CoreCredential.Service); return Layer.succeed(CoreCredential.Service, realCredentials);
  }))),
  httpClient.replace(Layer.succeed(HttpClient.HttpClient, HttpClient.make(request => Effect.succeed(HttpClientResponse.fromWeb(request, new Response('{}', { headers: { 'content-type': 'application/json' } })))))),
];
let exchange = await createExchange({ root, plugins: [plugin], overrides, deadlineMs: mode === 'deadline' ? 2000 : 5000 });
try {
  const directory = path.join(root, 'work'); fs.mkdirSync(directory, { mode: 0o700 });
  const prepared = await exchange.prepare({ directory, agent: 'build', model: { providerID: 'voice-synthetic', id: 'fixture', variant: 'default' } });
  const binding = { target_session: prepared.target_session, directory, binding_revision: 1, target_id: crypto.randomUUID(), expires_at: Date.now() + 120000,
    caller_id: 'caller_fixture', project_id: 'project_fixture', principal_id: 'principal_fixture', audience: 'bridge_fixture', device_id: 'device_fixture',
    authority: prepared.authority, pins: prepared.pins };
  await assert.rejects(exchange.verify({ binding: { ...binding, target_session: 'ses_wrong' } }));
  await assert.rejects(exchange.verify({ binding: { ...binding, directory: root } }));
  assert.equal((await exchange.verify({ binding })).single_use, true);
  await assert.rejects(exchange.verify({ binding: { ...binding, media_epoch: 1 } }));
  await assert.rejects(exchange.verify({ binding: { ...binding, claimed_call_id: crypto.randomUUID() } }));
  await assert.rejects(exchange.verify({ binding: { ...binding, authority: crypto.randomUUID() } }));
  const capability = await exchange.capability();
  assert.equal(capability.modelAvailable, true); assert.equal(capability.agentAvailable, true);
  assert.equal(capability.providerConnected, false); assert.equal(capability.ready, false); // TestLLM cannot arm production.
  assert.equal(capability.instance_id, prepared.instance_id);
  if (mode.startsWith('advance-')) {
    const oldFile = () => fs.readFileSync(path.join(root, 'exchange.json'), 'utf8');
    const old = JSON.parse(oldFile());
    await assert.rejects(exchange.advanceUnused({ binding: { ...binding, authority: crypto.randomUUID() }, pins: prepared.pins }));
    assert.deepEqual(JSON.parse(oldFile()), old);
    unknownWork = true;
    await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
    unknownWork = false; assert.deepEqual(JSON.parse(oldFile()), old);
    if (mode === 'advance-unused') {
      const account = await fixtureRun(realCredentials.create({ integrationID: 'openai', label: 'Synthetic own saved account', value: {
        type: 'oauth', methodID: 'chatgpt-headless', access: 'synthetic-no-authority', refresh: 'synthetic-no-authority', expires: Date.now() + 3600000 } }));
      await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
      const retired = JSON.parse(oldFile()); assert.equal(retired.reason, 'process_restarted');
      const clock = Date.now; let fresh;
      try { Date.now = () => clock() + 130000; fresh = await exchange.advanceUnused({ binding, pins: prepared.pins }); }
      finally { Date.now = clock; }
      assert.notEqual(fresh.target_session, prepared.target_session); assert.notEqual(fresh.authority, prepared.authority);
      assert.equal(fresh.instance_id, prepared.instance_id); assert.deepEqual(fresh.pins, prepared.pins);
      assert.deepEqual(JSON.parse(oldFile()).retired_unused, retired);
      assert.equal((await fixtureRun(realSessions.get(prepared.target_session))).id, prepared.target_session);
      assert.deepEqual(await fixtureRun(realSessions.context(prepared.target_session)), []);
      assert.deepEqual(await fixtureRun(realSessions.context(fresh.target_session)), []);
      assert.deepEqual(await fixtureRun(realCredentials.get(account.id)), account);
      const nextBinding = { ...binding, target_session: fresh.target_session, authority: fresh.authority, target_id: crypto.randomUUID(), binding_revision: 2 };
      await exchange.verify({ binding: nextBinding });
      await assert.rejects(exchange.verify({ binding }));
      await assert.rejects(exchange.advanceUnused({ binding, pins: fresh.pins }));
      await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
      const retiredSecond = JSON.parse(oldFile());
      const third = await exchange.advanceUnused({ binding: nextBinding, pins: fresh.pins });
      assert.equal(new Set([prepared.target_session, fresh.target_session, third.target_session]).size, 3);
      assert.equal(new Set([prepared.authority, fresh.authority, third.authority]).size, 3);
      assert.equal(third.instance_id, prepared.instance_id); assert.deepEqual(third.pins, prepared.pins);
      assert.deepEqual(JSON.parse(oldFile()).retired_unused, retiredSecond);
      assert.deepEqual(JSON.parse(oldFile()).retired_unused.retired_unused, retired);
      for (const sid of [prepared.target_session, fresh.target_session, third.target_session]) {
        assert.equal((await fixtureRun(realSessions.get(sid))).id, sid);
        assert.deepEqual(await fixtureRun(realSessions.context(sid)), []);
      }
      const thirdBinding = { ...nextBinding, target_session: third.target_session, authority: third.authority, target_id: crypto.randomUUID(), binding_revision: 3 };
      await exchange.verify({ binding: thirdBinding });
      for (const prior of [binding, nextBinding]) await assert.rejects(exchange.advanceUnused({ binding: prior, pins: third.pins }));
      await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
      for (const prior of [binding, nextBinding]) await assert.rejects(exchange.advanceUnused({ binding: prior, pins: third.pins }));
      assert.deepEqual(JSON.parse(oldFile()).retired_unused, retiredSecond);
      assert.deepEqual(await fixtureRun(realCredentials.get(account.id)), account);
      // Synthetic DISPOSABLE active metadata only: preserve the immutable retired
      // chain, seed a near-limit record while CLOSED, then prove no allocation.
      await exchange.close();
      const large = { ...JSON.parse(oldFile()), fixture_padding: '' };
      large.fixture_padding = 'x'.repeat(131040 - Buffer.byteLength(JSON.stringify(large)));
      fs.writeFileSync(path.join(root, 'exchange.json'), JSON.stringify(large));
      exchange = await createExchange({ root, plugins: [plugin], overrides });
      const beforeOverflow = oldFile();
      await assert.rejects(exchange.advanceUnused({ binding: thirdBinding, pins: third.pins }));
      assert.equal(oldFile(), beforeOverflow);
      assert.deepEqual(JSON.parse(oldFile()).retired_unused, retiredSecond);
      assert.deepEqual(await fixtureRun(realCredentials.get(account.id)), account);
    } else if (mode === 'advance-foreign') {
      const job = await fixtureRun(realJobs.start({ id: 'job_advance_fixture', type: 'synthetic', metadata: { sessionID: prepared.target_session }, run: Effect.promise(() => gate.promise) }));
      assert.equal((await exchange.runtimeStats()).localWorkPending, true);
      await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
      gate.resolve(); await fixtureRun(realJobs.wait({ id: job.id }));
      await fixtureRun(realSessions.prompt({ sessionID: prepared.target_session, id: 'msg_SYNTHETIC0016', text: 'Synthetic foreign input', resume: false }));
      assert.equal(JSON.parse(oldFile()).reason, 'competing_input');
      await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
    } else {
      await assert.rejects(exchange.submit({ call_id: crypto.randomUUID(), operation_id: crypto.randomUUID(), binding, planned_inbox_id: 'msg_SYNTHETIC0009',
        item: { id: 'thought_fixture', type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Synthetic admission only' }] } }));
      assert.ok(JSON.parse(oldFile()).operation);
      await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
    }
    assert.equal(allocations, mode === 'advance-unused' ? 3 : 1);
    if (mode !== 'advance-unused') {
      assert.equal(JSON.parse(oldFile()).target_session, prepared.target_session);
      assert.equal(Object.hasOwn(JSON.parse(oldFile()), 'retired_unused'), false);
    }
    assert.equal(toolsExecuted, 0); assert.equal(forbiddenAttempts, 0);
    console.log(JSON.stringify({ unusedAdvance: mode, preserved: true, forbiddenAttempts }));
  } else if (mode === 'end-note-unused') {
    const noteInput = { call_id: crypto.randomUUID(), operation_id: crypto.randomUUID(), owner_epoch: crypto.randomUUID(),
      binding, role: 'system', text: '[voice] ended', assistant_response: false };
    const before = events.length;
    const receipt = await exchange.appendEnd(noteInput);
    assert.equal(receipt.target_session, prepared.target_session);
    assert.deepEqual(events.slice(before).map(e => e.type), ['session.voice.ended']);
    assert.equal((await exchange.capability()).singleUseAvailable, false);
    assert.equal((await exchange.verify({ binding })).single_use_available, false);
    await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
    await assert.rejects(exchange.submit({ call_id: noteInput.call_id, operation_id: crypto.randomUUID(), binding,
      planned_inbox_id: 'msg_SYNTHETIC0010', item: { id: 'afterend', type: 'message', role: 'user', content: [{ type: 'input_text', text: 'must not admit' }] } }));
    assert.equal((await exchange.runtimeStats()).localWorkPending, false);
    assert.equal((await fixtureRun(realSessions.inbox(prepared.target_session))).length, 0);
    assert.equal(toolsExecuted, 0); assert.equal(forbiddenAttempts, 0);
    await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
    assert.deepEqual(await exchange.appendEnd(noteInput), receipt);
    assert.equal(events.filter(e => e.type === 'session.voice.ended').length, 1);
    await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
    console.log(JSON.stringify({ historyOnlyUnused: true, nonemptyRetirementRefused: true, forbiddenAttempts }));
  } else {
  const input = { call_id: crypto.randomUUID(), operation_id: crypto.randomUUID(), binding, planned_inbox_id: 'msg_SYNTHETIC0015',
    item: { id: 'thought_fixture', type: 'message', role: 'user', content: [{ type: 'input_text', text: 'Calculate the fixture result.' }] } };
  let returned = false;
  const completion = exchange.submit(input).then(value => { returned = true; return value; });
  completion.catch(() => {});
  if (background) {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { watcher.close(); reject(new Error('missing_actual_pending_job_candidate')); }, 3000);
      const watcher = fs.watch(root, () => {
        const state = JSON.parse(fs.readFileSync(path.join(root, 'exchange.json'), 'utf8'));
        if (state.candidate && state.jobs.job_fixture?.status === 'running' && state.sessions[state.target_session].terminal) {
          clearTimeout(timer); watcher.close(); resolve();
        }
      });
    });
    assert.equal(returned, false);
    const continuing = await exchange.verify({ binding });
    assert.equal(continuing.continuation, true); assert.equal(continuing.single_use_available, false);
    if (endMode) {
      endInput = { call_id: input.call_id, operation_id: crypto.randomUUID(), owner_epoch: crypto.randomUUID(),
        binding, role: 'system', text: '[voice] ended', assistant_response: false };
      const before = events.length, requests = (await fixtureRun(testLLM.requests())).length;
      for (const wrong of [{ call_id: crypto.randomUUID() }, { binding: { ...binding, target_session: 'ses_wrong' } }, { text: 'not ended' }])
        await assert.rejects(exchange.appendEnd({ ...endInput, ...wrong }));
      if (lostEnd) await assert.rejects(exchange.appendEnd(endInput));
      else {
        endReceipt = await exchange.appendEnd(endInput);
        assert.deepEqual(await exchange.appendEnd(endInput), endReceipt);
      }
      assert.equal((await fixtureRun(testLLM.requests())).length, requests);
      const delta = events.slice(before);
      assert.deepEqual(delta.map(e => e.type), ['session.voice.ended']);
      const persisted = JSON.parse(fs.readFileSync(path.join(root, 'exchange.json'), 'utf8'));
      const note = await fixtureRun(realSessions.message({ sessionID: prepared.target_session,
        messageID: persisted.end_note.event_id.replace(/^evt_/, 'msg_') }));
      assert.equal(note.type, 'system'); assert.equal(note.historyOnly, true); assert.equal(note.text, '[voice] ended');
      assert.equal(delta[0].data.sessionID, prepared.target_session);
      assert.equal(persisted.sessions[prepared.target_session].seq, delta[0].durable.seq);
      endProof = { target_session: prepared.target_session, message_id: note.id, type: note.type,
        historyOnly: note.historyOnly, text: note.text, append_events: delta.map(e => e.type),
        through_seq: persisted.sessions[prepared.target_session].seq };
      assert.equal((await exchange.runtimeStats()).localWorkPending, true);
      assert.equal((await fixtureRun(realSessions.inbox(prepared.target_session))).length, 0);
      await assert.rejects(exchange.advanceUnused({ binding, pins: prepared.pins }));
      if (lostEnd) await assert.rejects(exchange.appendEnd(endInput));
    }
    if (mode === 'competing') {
      // Real competing durable input, not a fabricated public event.
      const { Effect: E } = await import('effect');
      await E.runPromise(realSessions.prompt({ sessionID: prepared.target_session, id: 'msg_SYNTHETIC0013', text: 'Competing input', resume: false }));
    }
    if (mode === 'ambiguous') {
      runtimeHook('candidate', { sessionID: prepared.target_session, assistantMessageID: 'msg_SYNTHETIC0011',
        needsContinuation: false, agent: prepared.pins.agent, model: prepared.pins.model });
    }
    if (mode !== 'deadline') gate.resolve();
  }
  if (['lost-receipt', 'competing', 'ambiguous', 'deadline'].includes(mode)) {
    await assert.rejects(completion);
    const recorded = await exchange.read(input);
    assert.equal(recorded.status, 'uncertain');
    assert.equal(recorded.reason, { 'lost-receipt': 'admission_or_completion_uncertain', competing: 'competing_input', ambiguous: 'ambiguous_final_candidate', deadline: 'completion_deadline' }[mode]);
    assert.equal(recorded.admission_inbox_id, input.planned_inbox_id); assert.equal(recorded.result, undefined);
    await assert.rejects(exchange.submit(input));
    await assert.rejects(exchange.verify({ binding }));
    if (mode === 'deadline') {
      const busy = await exchange.runtimeStats();
      assert.equal(busy.pendingRequests, 0); assert.equal(busy.localWorkKnown, true); assert.equal(busy.localWorkPending, true);
      let drained = false;
      const quiet = exchange.waitUntilLocalQuiet().then(value => { drained = true; return value; });
      await new Promise(resolve => setImmediate(resolve)); assert.equal(drained, false);
      gate.resolve();
      const settled = await quiet;
      assert.equal(settled.localWorkKnown, true); assert.equal(settled.localWorkPending, false);
      assert.ok(settled.localWorkRevision > busy.localWorkRevision);
      assert.equal((await exchange.read(input)).status, 'uncertain'); // No fabricated provider completion/retry.
      assert.equal(toolsExecuted, 1);
    }
    if (mode === 'lost-receipt') {
      assert.equal(toolsExecuted, 0);
      await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
      assert.equal((await exchange.read(input)).status, 'uncertain');
      await assert.rejects(exchange.submit(input)); assert.equal(toolsExecuted, 0);
    }
    assert.equal(forbiddenAttempts, 0);
    console.log(JSON.stringify({ negative: mode, uncertain: true, noResubmit: true, forbiddenAttempts }));
    // The fixture's finally joins actual owned SDK cleanup.
    await exchange.close();
    process.exitCode = 0;
  } else {
    const result = await completion;
    assert.equal(toolsExecuted, 1); assert.equal(result.text, 'The synthetic tool returned 42.');
    assert.equal(result.admission_inbox_id, input.planned_inbox_id); assert.equal(result.source_user_id, result.admission_inbox_id);
    assert.notEqual(result.source_assistant_id, result.source_user_id);
    assert.deepEqual((await exchange.read(input)).result, result);
    const continuing = await exchange.verify({ binding });
    assert.equal(continuing.continuation, true); assert.equal(continuing.single_use_available, false);
    await assert.rejects(exchange.verify({ binding: { ...binding, binding_revision: 2 } }));
    const usedCapability = await exchange.capability();
    assert.equal(usedCapability.modelAvailable, true); assert.equal(usedCapability.agentAvailable, true);
    assert.equal(usedCapability.singleUseAvailable, false); assert.equal(usedCapability.ready, false);
    await assert.rejects(exchange.submit(input));
    if (endMode) {
      const requests = await fixtureRun(testLLM.requests());
      assert.equal(requests.length, 3);
      assert.equal(JSON.stringify(requests).includes('[voice] ended'), false);
      Object.assign(endProof, { legitimate_model_requests: requests.length, note_in_model_input: false, replay_events: 0 });
      assert.equal(events.filter(e => e.type === 'session.voice.ended').length, 1);
      await exchange.close();
      if (mode === 'end-note-dispatched') {
        // Disposable synthetic crash image at the persisted pre-receipt boundary.
        const file = path.join(root, 'exchange.json'), image = JSON.parse(fs.readFileSync(file, 'utf8'));
        image.end_note.state = 'dispatching'; delete image.end_note.receipt;
        fs.writeFileSync(file, JSON.stringify(image));
      }
      exchange = await createExchange({ root, plugins: [plugin], overrides });
      if (lostEnd) await assert.rejects(exchange.appendEnd(endInput));
      else assert.deepEqual(await exchange.appendEnd(endInput), endReceipt);
      assert.equal(events.filter(e => e.type === 'session.voice.ended').length, 1);
      assert.equal((await exchange.runtimeStats()).localWorkPending, false);
    }
    if (mode === 'restart') {
      await exchange.close(); exchange = await createExchange({ root, plugins: [plugin], overrides });
      assert.deepEqual((await exchange.read(input)).result, result);
      await assert.rejects(exchange.submit(input)); assert.equal(toolsExecuted, 1);
    }
    assert.equal(forbiddenAttempts, 0);
    console.log(JSON.stringify({ actualAgentToolCompletion: true, toolsExecuted, noResubmit: true, forbiddenAttempts,
      ...(endMode ? { proof: endProof } : {}) }));
  }
  }
} finally { gate.resolve(); await exchange.close(); }
