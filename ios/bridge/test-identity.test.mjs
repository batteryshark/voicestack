import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { once } from 'node:events';
import { Credentials, createBridge } from './server.mjs';
import { provision, remove, fingerprints } from './test-identity.mjs';

test('offline scoped identity append/use/expiry/remove preserves all original fields and records', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-owned-identity-'));
  const file = path.join(dir, 'store.json'), request = path.join(dir, 'request.json');
  const auth = path.join(dir, 'auth.json'), ledger = path.join(dir, 'ledger.json');
  const original = { arbitrary: { keep: true }, bootstrap: 'synthetic-consumed-fingerprint', expires: 123,
    devices: { syntheticPhoneHash: { deviceID: 'phone', sessionID: 'ses_phone', generation: 'keep', mode: 'chief' } } };
  fs.writeFileSync(file, JSON.stringify(original), { mode: 0o600 });
  fs.writeFileSync(request, JSON.stringify({ sessionID: 'ses_owned', durationMs: 60000 }), { mode: 0o600 });
  let bridge, fake;
  try {
    const receipt = provision(file, request, auth, ledger);
    assert.ok(receipt.preexistingRecordsUnchanged);
    assert.equal(fs.statSync(auth).mode & 0o777, 0o600);
    const credentials = new Credentials(file), secret = JSON.parse(fs.readFileSync(auth)).credential;
    const ownKey = JSON.parse(fs.readFileSync(ledger)).key;
    assert.deepEqual(fingerprints(credentials.data, ownKey), fingerprints(original));
    fake = http.createServer((req, res) => {
      if (req.url === '/api/system/info') return res.end(JSON.stringify({ runtime: 'desktop' }));
      if (req.url.startsWith('/api/session?')) return res.end(JSON.stringify({ data: [{ id: 'ses_owned', title: 'Simulator proof' }, { id: 'ses_phone', title: 'MUST NOT LEAK' }] }));
      if (req.url === '/api/session/ses_owned') return res.end(JSON.stringify({ data: { id: 'ses_owned', title: 'Simulator proof' } }));
      if (req.url === '/api/session/active') return res.end('{"data":{}}');
      res.end('{"data":[]}');
    });
    fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
    bridge = createBridge({ credentials, discover: () => fake.address().port, chief: () => 'ses_phone' });
    bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
    const call = (route, body, generation) => fetch(`http://127.0.0.1:${bridge.address().port}/floating-voice${route}`, {
      method: body ? 'POST' : 'GET', headers: { Authorization: 'Bearer ' + secret, ...(generation ? { 'X-FV-Generation': generation } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
    assert.equal((await call('/v1/chief')).status, 403);
    const listed = await (await call('/v1/sessions')).json();
    assert.deepEqual(listed.data.map(s => s.id), ['ses_owned']);
    assert.equal((await call('/v1/selection', { sessionID: 'ses_phone', mode: 'explicit' })).status, 403);
    assert.equal((await call('/v1/selection', { sessionID: 'ses_owned', mode: 'chief' })).status, 403);
    const selected = await (await call('/v1/selection', { sessionID: 'ses_owned', mode: 'explicit' })).json();
    assert.ok(selected.generation);
    for (const action of ['messages', 'state', 'events', 'prompt', 'interrupt']) {
      assert.equal((await call('/v1/sessions/ses_phone/' + action, ['prompt', 'interrupt'].includes(action) ? { text: 'synthetic' } : undefined, selected.generation)).status, 403);
    }
    assert.equal((await call('/v1/sessions/ses_owned/state', undefined, selected.generation)).status, 200);
    const state = new Credentials(file); state.data.devices[ownKey].test.expires = 1; state.save();
    assert.equal((await call('/v1/health')).status, 401);
    assert.deepEqual(remove(file, ledger), { removedOnlyOwnedTestRecord: true, preexistingRecordsUnchanged: true });
    assert.deepEqual(JSON.parse(fs.readFileSync(file)), original);
    assert.equal((await call('/v1/health')).status, 401);
  } finally {
    if (bridge) bridge.shutdown();
    if (fake) { fake.closeAllConnections(); await new Promise(resolve => fake.close(resolve)); }
    fs.rmSync(dir, { recursive: true });
  }
});

test('cleanup refuses altered original records and never replaces them', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-identity-preserve-'));
  try {
    const paths = ['store', 'request', 'auth', 'ledger'].map(name => path.join(dir, name + '.json'));
    fs.writeFileSync(paths[0], JSON.stringify({ devices: { phone: { marker: 1 } } }), { mode: 0o600 });
    fs.writeFileSync(paths[1], JSON.stringify({ sessionID: 'ses_owned', durationMs: 60000 }), { mode: 0o600 });
    provision(...paths);
    const store = new Credentials(paths[0]); store.data.devices.phone.marker = 2; store.save();
    const before = fs.readFileSync(paths[0]);
    assert.throws(() => remove(paths[0], paths[3]), /preexisting content changed/);
    assert.deepEqual(fs.readFileSync(paths[0]), before);
  } finally { fs.rmSync(dir, { recursive: true }); }
});
