import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { startHarness } from './harness-client.mjs';

test('real SDK child is owned, exclusive and joined without changing bridge environment', async () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'voice-ipc-'))); fs.chmodSync(root, 0o700);
  const original = { ...process.env }; let client;
  try {
    client = await startHarness({ root });
    assert.deepEqual(client.stats(), { childAlive: true, pendingRequests: 0, localWorkKnown: true, localWorkPending: false, localWorkRevision: 0 });
    assert.deepEqual(await client.runtimeStats(), { closed: false, targets: 0, operations: 0, pendingRequests: 0, localWorkKnown: true, localWorkPending: false, localWorkRevision: 0 });
    const capability = await client.capability();
    assert.equal(capability.ready, false); assert.equal(capability.runtime_version, '2.0.32');
    assert.match(capability.instance_id, /^[a-f0-9-]{36}$/);
    const pins = { directory: root, agent: 'build', model: { providerID: 'openai', id: 'gpt-6.1-sol', variant: 'high' } };
    const preflight = await client.capability({ pins });
    assert.equal(preflight.instance_id, capability.instance_id); assert.deepEqual(preflight.pins, pins);
    assert.equal(preflight.agentAvailable, true); assert.equal(preflight.modelAvailable, false); assert.equal(preflight.providerConnected, false);
    assert.equal(preflight.outboundEnabled, false); assert.equal(preflight.ready, false); assert.equal(preflight.target_session, undefined);
    assert.equal(fs.existsSync(path.join(root, 'exchange.json')), false);
    assert.equal((await client.runtimeStats()).targets, 0);
    const setup = await client.providerSetup({ pins });
    assert.equal(setup.instance_id, capability.instance_id); assert.equal(setup.providerID, 'openai');
    assert.equal(setup.integrationID, 'openai'); assert.equal(setup.methods.length, 1);
    assert.equal(setup.methods[0].id, 'chatgpt-headless');
    assert.equal(setup.providerConnected, false); assert.equal(setup.outboundEnabled, false);
    assert.equal((await client.signInStatus()).status, 'receipt_unavailable'); // No process receipt, not pending or failed.
    const reconciliation = await client.reconcileProvider({ pins });
    assert.equal(reconciliation.reconciled, false); assert.equal(reconciliation.outboundEnabled, false);
    assert.equal(reconciliation.providerAcceptance, 'not_proven');
    await assert.rejects(client.capability({ pins: { ...pins, model: { ...pins.model, id: 'auto' } } }));
    await assert.rejects(startHarness({ root }));
    await assert.rejects(client.read({ call_id: 'wrong', operation_id: 'wrong' }));
    await client.close(); await client.close();
    assert.deepEqual(client.stats(), { childAlive: false, pendingRequests: 0, localWorkKnown: true, localWorkPending: false, localWorkRevision: 0 });
    assert.equal(fs.existsSync(path.join(root, 'owner.lock')), false);
    assert.deepEqual({ ...process.env }, original);
  } finally { await client?.close(); fs.rmSync(root, { recursive: true, force: true }); }
});
