// Runs only in a disposable process with an explicit empty owner environment.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import cp from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';

let forbiddenAttempts = 0;
const deny = () => { forbiddenAttempts++; throw new Error('fixture_forbids_network_listener_child'); };
globalThis.fetch = deny;
net.Socket.prototype.connect = deny;
net.Server.prototype.listen = deny;
http.request = deny; https.request = deny;
cp.spawn = deny; cp.exec = deny; cp.execFile = deny;
syncBuiltinESMExports();

const { createOwnedHost } = await import('./owned-host.mjs');
const root = process.env.VOICE_FIXTURE_ROOT;
const owned = await createOwnedHost({ root });
try {
  assert.equal(fs.existsSync(owned.database), true);
  assert.equal(owned.stats().closed, false);
  assert.equal(forbiddenAttempts, 0);
} finally {
  const close = owned.close(); assert.equal(owned.close(), close); await close;
}
assert.equal(owned.stats().closed, true);
assert.equal(forbiddenAttempts, 0);
console.log(JSON.stringify({ hostCreated: true, explicitDatabase: true, hostClosed: true, forbiddenAttempts }));
