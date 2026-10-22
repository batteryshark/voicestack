import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

async function runFixture(file, args = []) {
  const base = args[0]?.startsWith('advance-') ? fileURLToPath(new URL('../../output/', import.meta.url))
    : fs.realpathSync(os.tmpdir());
  const root = fs.mkdtempSync(path.join(base, 'voice-sdk-fixture-')); fs.chmodSync(root, 0o700);
  const env = { PATH: process.env.PATH, TMPDIR: root, VOICE_FIXTURE_ROOT: root };
  try {
    for (const [key, name] of Object.entries({ HOME: 'home', XDG_CONFIG_HOME: 'config', XDG_DATA_HOME: 'data', XDG_CACHE_HOME: 'cache', XDG_STATE_HOME: 'state' })) {
      const directory = path.join(root, name); fs.mkdirSync(directory, { mode: 0o700 }); env[key] = directory;
    }
    env.GIT_CONFIG_NOSYSTEM = '1';
    // Preserve this fixture checkout's hook identity when its pinned modules are read-only linked.
    const flags = args[0]?.startsWith('advance-') ? ['--preserve-symlinks'] : [];
    const { stdout } = await promisify(execFile)(process.execPath, [...flags, fileURLToPath(new URL(file, import.meta.url)), ...args], {
      env, cwd: root, timeout: 30000, killSignal: 'SIGKILL', maxBuffer: 32768,
    });
    return JSON.parse(stdout.trim());
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
test('actual pinned SDK host owns its database and closes without network, listener, child or principal configuration', async () => {
  assert.deepEqual(await runFixture('./owned-host-fixture.mjs'), { hostCreated: true, explicitDatabase: true, hostClosed: true, forbiddenAttempts: 0 });
});
test('private candidate hook executes inside the actual SDK runner after admitted input', async () => {
  assert.deepEqual(await runFixture('./hook-fixture.mjs'), { actualRunnerCandidate: true, actualInboxDelivery: true, actualExecutionTerminal: true, forbiddenAttempts: 0 });
});
test('actual SDK exchange returns the true final assistant after real synthetic tool execution', async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs'), { actualAgentToolCompletion: true, toolsExecuted: 1, noResubmit: true, forbiddenAttempts: 0 });
});
test('actual SDK background job holds the preliminary final candidate until notification and resumed final run', async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs', ['background']), { actualAgentToolCompletion: true, toolsExecuted: 1, noResubmit: true, forbiddenAttempts: 0 });
});
for (const mode of ['lost-receipt', 'competing', 'ambiguous']) test(`actual owned SDK exchange fails closed on ${mode} without resubmission`, async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs', [mode]), { negative: mode, uncertain: true, noResubmit: true, forbiddenAttempts: 0 });
});
test('completed actual SDK result survives restart as read-only evidence, never reexecution', async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs', ['restart']), { actualAgentToolCompletion: true, toolsExecuted: 1, noResubmit: true, forbiddenAttempts: 0 });
});
test('own provider initialization delegates to SDK OAuth without exporting credentials or allocating a target', async () => {
  assert.deepEqual(await runFixture('./provider-fixture.mjs'), { ownSdkOAuthPlumbing: true, noTargetAllocation: true, providerProof: false, networkAttempts: 0 });
});
test('own provider missing native attempt is receipt unavailable, not pending or failed', async () => {
  assert.deepEqual(await runFixture('./provider-fixture.mjs', ['missing']), { nativeReceiptUnavailable: true, noTargetAllocation: true, networkAttempts: 0 });
});
test('actual SDK local work remains busy after uncertain submit until background notification and resumed work settle', async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs', ['deadline']), { negative: 'deadline', uncertain: true, noResubmit: true, forbiddenAttempts: 0 });
});
test('unused advance retains both old sessions and snapshots, per-binding intent and size refusal across reopen', async () => {
  assert.deepEqual(await runFixture('./exchange-fixture.mjs', ['advance-unused']), { unusedAdvance: 'advance-unused', preserved: true, forbiddenAttempts: 0 });
});
test('unused advance refuses actual busy jobs, foreign input and uncertain admission without allocation', async () => {
  for (const mode of ['advance-foreign', 'advance-operation']) assert.deepEqual(await runFixture('./exchange-fixture.mjs', [mode]), { unusedAdvance: mode, preserved: true, forbiddenAttempts: 0 });
});
