// Deliberately pure: no server, sockets, credentials, APNs or app imports.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { CONFIG, manifestAllowed, sendSchema } from './reachout-policy.mjs';
const rows = JSON.parse(fs.readFileSync(new URL('../shared/install-policy-fixtures.json', import.meta.url)));
for (const row of rows) test(row.name, () => {
  const config = { ...CONFIG, deploymentSuffix: row.deploymentSuffix, approvedManifests: row.approvedManifests };
  assert.equal(manifestAllowed(row.url, config), row.expected);
  const value = { id: 'fixture', kind: 'ready-to-try', reason: 'install', session: 'ses_fixture', title: 'Fixture', body: 'Synthetic build', url: row.url };
  if (row.expected) assert.doesNotThrow(() => sendSchema(value, config));
  else assert.throws(() => sendSchema(value, config));
});
test('default denies and malformed typed config fails closed', () => {
  assert.equal(manifestAllowed(rows[1].url), false);
  for (const config of [{ deploymentSuffix: 3, approvedManifests: [] }, { deploymentSuffix: null, approvedManifests: [rows[1].raw] }, { deploymentSuffix: '.demo.ts.net', approvedManifests: 'bad' }, { deploymentSuffix: '.demo.ts.net', approvedManifests: [1] }]) {
    assert.equal(manifestAllowed(rows[1].url, config), false);
  }
});
