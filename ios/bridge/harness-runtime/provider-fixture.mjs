// Exercise normal SDK OAuth attempt/storage/status plumbing with synthetic
// credentials in a fresh owned DB. No actual authorization request or provider.
import assert from 'node:assert/strict';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
let networkAttempts = 0;
const deny = () => { networkAttempts++; throw new Error('fixture_network_forbidden'); };
globalThis.fetch = deny; net.Socket.prototype.connect = deny; net.Server.prototype.listen = deny; syncBuiltinESMExports();
const { Effect, Layer, Logger } = await import('effect');
const { HttpClient, HttpClientResponse } = await import('effect/http');
const { httpClient } = await import('@opencode/util/effect/app-node-platform');
const { Credential } = await import('@opencode/schema/credential');
const { createExchange } = await import('./exchange.mjs');
// ctx controls are used only by this disposable fixture. Give these explicit
// Effect runs a quiet logger too, rather than the process default console logger.
const control = effect => Effect.runPromise(effect.pipe(Effect.provide(Logger.layer([]))));
const gate = Promise.withResolvers();
let context, badRoute = false, begins = 0;
const plugin = { id: 'voice.synthetic-auth-fixture', effect: ctx => Effect.gen(function* () {
  context = ctx;
  yield* ctx.provider.transform(editor => { if (badRoute) editor.update('openai', provider => { provider.settings.baseURL = 'https://fixture.invalid/wrong-route'; }); });
  yield* ctx.integration.transform(editor => editor.method.update({
    integrationID: 'openai', method: { id: 'chatgpt-headless', type: 'oauth', label: 'Synthetic device flow' },
    authorize: () => Effect.sync(() => { begins++; return { mode: 'auto', url: 'https://fixture.invalid/device', instructions: 'Synthetic fixture only',
      callback: Effect.promise(() => gate.promise).pipe(Effect.map(() => Credential.OAuth.make({ type: 'oauth', methodID: 'chatgpt-headless',
        access: 'synthetic-no-authority', refresh: 'synthetic-no-authority', expires: Date.now() + 3600000, metadata: { accountID: 'synthetic' } }))),
    }; }),
  }));
}) };
const root = process.env.VOICE_FIXTURE_ROOT;
const overrides = [
  httpClient.replace(Layer.succeed(HttpClient.HttpClient, HttpClient.make(request => Effect.succeed(HttpClientResponse.fromWeb(request,
    new Response('{}', { headers: { 'content-type': 'application/json' } })))))),
];
let phase = 'closed';
const options = { root, bundledModels: true, plugins: [plugin], overrides, authPollMs: 5, onProviderPhase: value => { phase = value; } };
let exchange = await createExchange(options);
try {
  const pins = { directory: root, agent: 'build', model: { providerID: 'openai', id: 'gpt-6.1-sol', variant: 'high' } };
  const setup = await exchange.providerSetup({ pins });
  assert.equal(setup.methods[0].id, 'chatgpt-headless');
  assert.equal(setup.outboundEnabled, false); assert.equal(setup.providerConnected, false);
  assert.equal((await exchange.reconcileProvider({ pins })).reconciled, false); assert.equal(phase, 'closed');
  assert.equal((await exchange.capability({ pins })).providerConnected, false);
  const attempt = await exchange.beginSignIn({ pins });
  assert.equal(attempt.mode, 'auto');
  assert.equal((await exchange.signInStatus()).status, 'pending');
  assert.equal((await exchange.runtimeStats()).localWorkPending, true);
  await assert.rejects(exchange.close());
  await assert.rejects(exchange.reconcileProvider({ pins })); // Cannot interrupt auth work.
  assert.equal(phase, 'auth');
  await assert.rejects(exchange.beginSignIn({ pins }));
  assert.equal(phase, 'auth'); // Duplicate input must not cancel the existing auth work.
  if (process.argv[2] === 'missing') {
    // Actual native pending-attempt removal, not an invented pending status.
    await control(context.integration.oauth.cancel({ integrationID: 'openai', attemptID: attempt.attemptID }));
    await exchange.waitUntilLocalQuiet();
    const missing = await exchange.signInStatus();
    assert.equal(missing.status, 'receipt_unavailable'); assert.equal(missing.reason, 'native_attempt_not_found');
    assert.equal((await exchange.runtimeStats()).localWorkPending, false); assert.equal(phase, 'closed');
    assert.equal((await exchange.reconcileProvider({ pins })).reconciled, false);
    assert.equal(begins, 1); assert.equal(networkAttempts, 0); assert.equal(exchange.stats().targets, 0);
    console.log(JSON.stringify({ nativeReceiptUnavailable: true, noTargetAllocation: true, networkAttempts }));
  } else {
    gate.resolve();
    await exchange.waitUntilLocalQuiet();
    const status = await exchange.signInStatus();
    assert.equal(status.status, 'complete');
    assert.equal(phase, 'provider');
    const capability = await exchange.capability({ pins });
    assert.equal(capability.modelAvailable, true); assert.equal(capability.agentAvailable, true);
    assert.equal(capability.providerConnected, true); assert.equal(capability.ready, false); // Still no target/binding.
    assert.equal(capability.providerAcceptance, 'not_proven');
    const identity = setup.instance_id;
    await exchange.close(); phase = 'closed';
    exchange = await createExchange(options); // Same disposable own DB; no auth copy or new flow.
    assert.equal((await exchange.signInStatus()).status, 'receipt_unavailable');
    assert.equal((await exchange.providerSetup({ pins })).providerConnected, true);
    assert.equal((await exchange.providerSetup({ pins })).outboundEnabled, false); assert.equal(phase, 'closed');
    assert.equal((await exchange.reconcileProvider({ pins: { ...pins, model: { ...pins.model, providerID: 'anthropic' } } })).reconciled, false);
    assert.equal((await exchange.reconcileProvider({ pins: { ...pins, model: { ...pins.model, id: 'missing-model' } } })).reconciled, false);
    assert.equal((await exchange.reconcileProvider({ pins: { ...pins, agent: 'missing-agent' } })).reconciled, false);
    assert.equal(phase, 'closed');
    const { data: integration } = await control(context.integration.get({ integrationID: 'openai' }));
    await control(context.integration.connection.status({ integrationID: 'openai', connection: integration.connections[0], status: { status: 'needs_auth', message: 'Synthetic invalid connection' } }));
    assert.equal((await exchange.reconcileProvider({ pins })).reconciled, false); assert.equal(phase, 'closed');
    await control(context.integration.connection.status({ integrationID: 'openai', connection: integration.connections[0] }));
    badRoute = true; await control(context.provider.reload());
    assert.equal((await exchange.reconcileProvider({ pins })).reconciled, false); assert.equal(phase, 'closed');
    badRoute = false; await control(context.provider.reload());
    const recovered = await exchange.reconcileProvider({ pins });
    assert.equal(recovered.instance_id, identity); assert.equal(recovered.reconciled, true); assert.equal(recovered.outboundEnabled, true);
    assert.equal(recovered.receipt, 'receipt_unavailable'); assert.equal(recovered.providerAcceptance, 'not_proven');
    assert.equal(phase, 'provider'); assert.equal(begins, 1);
    await assert.rejects(exchange.reconcileProvider({ pins: { ...pins, agent: 'different' } })); assert.equal(phase, 'closed');
    assert.equal(exchange.stats().targets, 0); assert.equal(networkAttempts, 0);
    console.log(JSON.stringify({ ownSdkOAuthPlumbing: true, noTargetAllocation: true, providerProof: false, networkAttempts }));
  }
} finally { gate.resolve(); await exchange.waitUntilLocalQuiet(); await exchange.close(); }
