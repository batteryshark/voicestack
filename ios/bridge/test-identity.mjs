// Offline-only maintenance. The caller must first verify and stop ONLY its owned bridge.
// Secret inputs/outputs are private files, never stdout/argv/query strings.
import fs from 'node:fs';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Credentials } from './server.mjs';

const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const canonical = value => value && typeof value === 'object'
  ? (Array.isArray(value) ? value.map(canonical) : Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]))) : value;
const digest = value => hash(JSON.stringify(canonical(value)));
export function fingerprints(data, except) {
  const { devices, ...top } = data;
  return { top: digest(top), records: Object.fromEntries(Object.entries(devices).filter(([key]) => key !== except).map(([key, value]) => [key, digest(value)])) };
}
function privateRead(file) {
  const s = fs.lstatSync(file);
  if (!s.isFile() || (s.mode & 0o777) !== 0o600 || s.uid !== process.getuid()) throw Error('private owned file required');
  return JSON.parse(fs.readFileSync(file));
}
function privateWrite(file, data) { fs.writeFileSync(file, JSON.stringify(data), { flag: 'wx', mode: 0o600 }); }
export function provision(storeFile, requestFile, authFile, ledgerFile) {
  const request = privateRead(requestFile);
  if (!/^ses_[A-Za-z0-9]{1,100}$/.test(request.sessionID) || !Number.isInteger(request.durationMs) || request.durationMs < 60000 || request.durationMs > 2 * 3600000) throw Error('bounded explicit session required');
  const credentials = new Credentials(storeFile), before = fingerprints(credentials.data);
  const credential = crypto.randomBytes(32).toString('base64url'), key = hash(credential), owner = crypto.randomUUID();
  if (credentials.data.devices[key]) throw Error('identity collision');
  const record = { deviceID: crypto.randomUUID(), test: { sessionID: request.sessionID, expires: Date.now() + request.durationMs, owner } };
  privateWrite(ledgerFile, { key, owner, before, sessionID: request.sessionID, expires: record.test.expires });
  privateWrite(authFile, { sessionID: request.sessionID, credential });
  credentials.data.devices[key] = record;
  if (digest(fingerprints(credentials.data, key)) !== digest(before)) throw Error('preexisting content changed');
  credentials.save();
  return { testDeviceID: record.deviceID, expires: record.test.expires, preexistingRecordsUnchanged: true };
}
export function remove(storeFile, ledgerFile) {
  const ledger = privateRead(ledgerFile), credentials = new Credentials(storeFile);
  if (digest(fingerprints(credentials.data, ledger.key)) !== digest(ledger.before)) throw Error('preexisting content changed; stop and investigate, never overwrite');
  const own = credentials.data.devices[ledger.key];
  if (!own || own.test?.owner !== ledger.owner || own.test.sessionID !== ledger.sessionID) throw Error('test identity ownership changed');
  delete credentials.data.devices[ledger.key];
  credentials.save();
  if (digest(fingerprints(credentials.data)) !== digest(ledger.before)) throw Error('cleanup fingerprint mismatch');
  return { removedOnlyOwnedTestRecord: true, preexistingRecordsUnchanged: true };
}
// Node's test discovery also picks up this test-* CLI helper without arguments.
if (process.argv[1] === fileURLToPath(import.meta.url) && !(process.env.NODE_TEST_CONTEXT && process.argv.length === 2)) {
  const [command, store, ...files] = process.argv.slice(2);
  if (command === 'create') console.log(JSON.stringify(provision(store, ...files)));
  else if (command === 'remove') console.log(JSON.stringify(remove(store, ...files)));
  else throw Error('create STORE PRIVATE_REQUEST PRIVATE_AUTH PRIVATE_LEDGER | remove STORE PRIVATE_LEDGER; bridge must be offline');
}
