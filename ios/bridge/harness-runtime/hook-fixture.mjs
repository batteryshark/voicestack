import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
let forbiddenAttempts = 0;
const denied = [];
const deny = () => { forbiddenAttempts++; const e = new Error('fixture_network_forbidden'); denied.push(e.stack.split('\n').slice(1, 5)); throw e; };
globalThis.fetch = deny; net.Socket.prototype.connect = deny; net.Server.prototype.listen = deny; syncBuiltinESMExports();
const { Effect, Layer } = await import('effect');
const { HttpClient, HttpClientResponse } = await import('effect/http');
const { httpClient } = await import('@opencode/util/effect/app-node-platform');
const { TestLLM } = await import('@opencode/ai/testing');
const { llmClient } = await import('@opencode/core/effect/app-node-platform');
const { Provider } = await import('@opencode/schema/provider');
const { Model } = await import('@opencode/schema/model');
const { Bus } = await import('@opencode/core/bus');
const { createOwnedHost } = await import('./owned-host.mjs');
const { observeRuntime } = await import('./direct-hooks.mjs');
const root = process.env.VOICE_FIXTURE_ROOT, hooks = [], events = [];
const stop = observeRuntime((type, data) => hooks.push({ type, ...data }));
const plugin = { id: 'voice.synthetic-fixture', effect: ctx => ctx.provider.transform(editor => {
  const providerID = Provider.ID.make('voice-synthetic');
  editor.add({ info: { ...Provider.Info.empty(providerID), activation: 'enabled', package: '@opencode/ai/providers/openai-compatible', settings: { baseURL: 'http://fixture.invalid' } },
    models: [Model.Info.default(providerID, Model.ID.make('fixture'))] });
}) };
const owned = await createOwnedHost({ root, plugins: [plugin], overrides: [
  llmClient.replace(TestLLM.testLayer({ fallback: TestLLM.text('Actual synthetic final reply.', 'text_fixture') })),
  httpClient.replace(Layer.succeed(HttpClient.HttpClient, HttpClient.make(request => Effect.succeed(
    HttpClientResponse.fromWeb(request, new Response('{}', { headers: { 'content-type': 'application/json' } })))))),
] });
let unsubscribe;
try {
  unsubscribe = await owned.host.runtime.runPromise(Bus.Service.use(bus => bus.listen(event => Effect.sync(() => events.push(event)))));
  const directory = path.join(root, 'work'); fs.mkdirSync(directory, { mode: 0o700 });
  const session = await owned.host.runtime.runPromise(owned.host.sessions.create({ location: { directory }, agent: 'build', model: { providerID: 'voice-synthetic', id: 'fixture' } }));
  const receipt = await owned.host.runtime.runPromise(owned.host.sessions.prompt({ sessionID: session.id, id: 'msg_SYNTHETIC0015', text: 'Synthetic task', resume: false }));
  await owned.host.runtime.runPromise(owned.host.sessions.resume(session.id));
  assert.equal(receipt.id, 'msg_SYNTHETIC0015');
  assert.ok(events.some(e => e.type === 'session.inbox.delivered' && e.data.inboxID === receipt.id));
  assert.ok(events.some(e => e.type === 'session.execution.succeeded'));
  assert.equal(hooks.filter(h => h.type === 'candidate' && !h.needsContinuation).length, 1);
  assert.equal(forbiddenAttempts, 0, JSON.stringify(denied));
  console.log(JSON.stringify({ actualRunnerCandidate: true, actualInboxDelivery: true, actualExecutionTerminal: true, forbiddenAttempts }));
} finally {
  if (unsubscribe) await owned.host.runtime.runPromise(unsubscribe);
  stop(); await owned.close();
}
