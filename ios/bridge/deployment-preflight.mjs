// Offline deployment admission only: no discovery, writes, requests or token output.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { OpenChamberClient } from './oc-client.mjs';

export class PreflightError extends Error {
  constructor(category) { super(`Deployment preflight refused: ${category}`); }
}
function refuse(category) { throw new PreflightError(category); }
function readPrivate(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const s = fs.fstatSync(fd);
    if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o777) !== 0o600
      || s.nlink !== 1 || s.size > 65536) throw new Error();
    const buffer = Buffer.alloc(65537);
    const size = fs.readSync(fd, buffer, 0, buffer.length, 0);
    if (size > 65536) throw new Error();
    const value = JSON.parse(buffer.subarray(0, size).toString('utf8'));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch { refuse('private binding configuration invalid or missing'); }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
export function deploymentPreflight(directory = process.env.FV_OC_CLIENT_DIR
  ?? fileURLToPath(new URL('../private/openchamber', import.meta.url))) {
  if (typeof directory !== 'string' || !path.isAbsolute(directory)
    || directory.split('/').some(p => p === '..' || p === '.')) refuse('private directory invalid');
  try {
    let cursor = '/';
    for (const part of directory.split('/').filter(Boolean)) {
      cursor = path.join(cursor, part);
      const s = fs.lstatSync(cursor);
      if (!s.isDirectory() || s.isSymbolicLink()) throw new Error();
    }
    const s = fs.lstatSync(directory);
    if (s.uid !== process.getuid() || (s.mode & 0o777) !== 0o700) throw new Error();
  } catch { refuse('private directory invalid'); }
  const file = path.join(directory, 'client.json');
  const b = readPrivate(file), identity = readPrivate(path.join(directory, 'identity.json'));
  if (typeof identity.dedupeKey !== 'string' || !/^voicestack:[0-9a-f]{32}$/.test(identity.dedupeKey)
    || b.dedupeKey !== identity.dedupeKey || typeof b.fingerprint !== 'string' || !b.fingerprint.trim()) {
    refuse('own-client identity mismatch');
  }
  // Retain inherited canonical-origin rules; deployment also requires a producer-valid port.
  try {
    const loaded = new OpenChamberClient({ file }).load(true);
    if (!loaded || loaded.dedupeKey !== b.dedupeKey || loaded.clientId !== b.clientId
      || loaded.clientToken !== b.clientToken || loaded.fingerprint !== b.fingerprint) throw new Error();
    const u = new URL(loaded.enrolledOrigin);
    const port = Number(u.port);
    if (u.hostname !== '127.0.0.1' || !Number.isInteger(port) || port < 1 || port > 65535) throw new Error();
  } catch { refuse('own-client binding invalid'); }
  return { ready: true, authentication: 'not verified offline' };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 2) refuse('no command-line values accepted');
    console.log(JSON.stringify(deploymentPreflight()));
  } catch (e) {
    console.error(e instanceof PreflightError ? e.message : 'Deployment preflight refused');
    process.exitCode = 1;
  }
}
