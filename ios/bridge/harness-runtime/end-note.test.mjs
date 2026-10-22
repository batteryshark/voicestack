import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

for (const mode of ['end-note', 'end-note-lost', 'end-note-dispatched', 'end-note-unused']) test(`actual pinned history-only append: ${mode}`, async () => {
  const base = fileURLToPath(new URL('../../output/', import.meta.url));
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'end-note-fixture-')); fs.chmodSync(root, 0o700);
  const env = { PATH: process.env.PATH, TMPDIR: root, VOICE_FIXTURE_ROOT: root, GIT_CONFIG_NOSYSTEM: '1' };
  try {
    for (const [key, name] of Object.entries({ HOME: 'home', XDG_CONFIG_HOME: 'config', XDG_DATA_HOME: 'data', XDG_CACHE_HOME: 'cache', XDG_STATE_HOME: 'state' })) {
      env[key] = path.join(root, name); fs.mkdirSync(env[key], { mode: 0o700 });
    }
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(new URL('./exchange-fixture.mjs', import.meta.url)), mode],
      { env, cwd: root, timeout: 20000, killSignal: 'SIGKILL', maxBuffer: 32768 });
    const { proof, ...result } = JSON.parse(stdout.trim());
    assert.deepEqual(result, mode === 'end-note-unused'
      ? { historyOnlyUnused: true, nonemptyRetirementRefused: true, forbiddenAttempts: 0 }
      : { actualAgentToolCompletion: true, toolsExecuted: 1, noResubmit: true, forbiddenAttempts: 0 });
    if (proof) console.log(JSON.stringify({ mode, ...proof }));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
