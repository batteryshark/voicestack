import test from 'node:test';
import assert from 'node:assert/strict';
import { pairingWindowMs } from './server.mjs';
test('pairing bootstrap window remains eight hours independently of server lifetime', () => {
  assert.equal(pairingWindowMs, 8 * 3600000);
});
