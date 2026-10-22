// Project-owned authenticated boundary is the parent/child IPC channel, not HTTP.
// No principal OpenChamber token, provider environment, or SDK import here.
import fs from 'node:fs';
import path from 'node:path';
import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const refused = () => new Error('harness_unavailable_or_uncertain');
export async function startHarness({ root }) {
  if (typeof root !== 'string' || !path.isAbsolute(root) || fs.realpathSync(root) !== root) throw refused();
  const st = fs.lstatSync(root);
  if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o700) throw refused();
  const env = { PATH: process.env.PATH, TMPDIR: root, VOICE_HARNESS_ROOT: root, GIT_CONFIG_NOSYSTEM: '1' };
  for (const [key, name] of Object.entries({ HOME: 'home', XDG_CONFIG_HOME: 'config', XDG_DATA_HOME: 'data', XDG_CACHE_HOME: 'cache', XDG_STATE_HOME: 'state' })) {
    const directory = path.join(root, name); fs.mkdirSync(directory, { mode: 0o700, recursive: true });
    const owned = fs.lstatSync(directory);
    if (!owned.isDirectory() || owned.isSymbolicLink() || owned.uid !== process.getuid() || (owned.mode & 0o777) !== 0o700) throw refused();
    env[key] = directory;
  }
  const lockPath = path.join(root, 'owner.lock');
  const lock = fs.openSync(lockPath, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
  const lockStat = fs.fstatSync(lock);
  const release = () => {
    const current = fs.lstatSync(lockPath, { throwIfNoEntry: false });
    if (current?.ino === lockStat.ino && current.dev === lockStat.dev) fs.unlinkSync(lockPath);
  };
  let child;
  try { child = fork(fileURLToPath(new URL('./harness-runtime/child.mjs', import.meta.url)), [], {
    cwd: root, env, execArgv: [], stdio: ['ignore', 'ignore', 'ignore', 'ipc', lock],
  }); } catch (error) { release(); throw error; } finally { fs.closeSync(lock); }
  let sequence = 0, exited = false, initialized = false, closing, closingRequested = false, workGeneration = 0;
  let localWork = { localWorkKnown: false, localWorkPending: true, localWorkRevision: 0 };
  const pending = new Map();
  let readyResolve, readyReject;
  const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const exit = new Promise(resolve => child.once('close', () => {
    exited = true; release(); readyReject(refused());
    for (const p of pending.values()) { clearTimeout(p.timer); p.reject?.(refused()); }
    pending.clear(); resolve();
  }));
  child.on('error', () => { readyReject(refused()); });
  child.on('message', wire => {
    try {
      if (typeof wire !== 'string' || Buffer.byteLength(wire) > 131072) throw refused();
      const message = JSON.parse(wire);
      if (typeof message.ready === 'boolean' && !initialized) {
        initialized = true; if (message.ready) readyResolve(); else readyReject(refused()); return;
      }
      const p = pending.get(message.id); if (!p) return;
      if (p.action === 'stats' && message.ok === true) {
        const value = message.value;
        if (typeof value?.localWorkKnown !== 'boolean' || typeof value.localWorkPending !== 'boolean' || !Number.isSafeInteger(value.localWorkRevision) || value.localWorkRevision < 0) throw refused();
        if (value.localWorkPending || !value.localWorkKnown || p.generation === workGeneration && value.localWorkRevision >= localWork.localWorkRevision) {
          localWork = { localWorkKnown: value.localWorkKnown, localWorkPending: value.localWorkPending, localWorkRevision: value.localWorkRevision };
        }
      }
      clearTimeout(p.timer); pending.delete(message.id);
      if (message.ok === true) p.resolve?.(message.value); else p.reject?.(refused());
    } catch { localWork = { ...localWork, localWorkKnown: false, localWorkPending: true }; }
  });
  const request = (action, input) => new Promise((resolve, reject) => {
    if (exited || !child.connected || pending.size >= 4 || closingRequested && !['stats', 'close'].includes(action)) return reject(refused());
    if (['submit', 'appendEnd', 'beginSignIn', 'advanceUnused'].includes(action)) {
      workGeneration++; localWork = { ...localWork, localWorkKnown: false, localWorkPending: true };
    }
    const id = ++sequence, wire = JSON.stringify({ id, action, input });
    if (Buffer.byteLength(wire) > 131072) return reject(refused());
    const record = { resolve, reject, action, generation: workGeneration };
    // A timeout abandons only the caller wait. Keep its slot until the actual
    // child response/exit; never resubmit or cancel admitted work on timeout.
    record.timer = setTimeout(() => { record.resolve = null; record.reject = null; reject(refused()); }, action === 'submit' ? 125000 : 30000);
    pending.set(id, record);
    child.send(wire, error => { if (error) { clearTimeout(record.timer); record.resolve = null; record.reject = null; reject(refused()); } });
  });
  const join = ms => Promise.race([exit.then(() => true), new Promise(resolve => { const t = setTimeout(() => resolve(false), ms); exit.then(() => clearTimeout(t)); })]);
  const terminate = async (startupFailure = false) => {
    if (exited) return;
    if (startupFailure) request('close').catch(() => {});
    else await request('close'); // A busy/unknown child refusal must NOT escalate into a kill.
    if (!await join(5000)) { child.kill('SIGTERM'); if (!await join(5000)) child.kill('SIGKILL'); }
    await exit;
  };
  const close = () => {
    if (closing) return closing;
    closingRequested = true;
    closing = (async () => {
      if (exited) return;
      if (pending.size) throw new Error('harness_requests_pending');
      const local = await request('stats');
      if (!local.localWorkKnown || local.localWorkPending) throw new Error('harness_local_work_pending');
      await terminate();
    })().catch(error => { closing = undefined; closingRequested = false; throw error; });
    return closing;
  };
  const initTimer = setTimeout(() => { readyReject(refused()); child.kill('SIGTERM'); }, 30000);
  try { await ready; await request('stats'); }
  catch (error) { await terminate(true); throw error; }
  finally { clearTimeout(initTimer); }
  return {
    prepare: pins => request('prepare', pins),
    advanceUnused: input => request('advanceUnused', input),
    verify: binding => request('verify', binding),
    submit: input => request('submit', input),
    appendEnd: input => request('appendEnd', input),
    read: input => request('read', input),
    capability: input => request('capability', input),
    providerSetup: input => request('providerSetup', input),
    reconcileProvider: input => request('reconcileProvider', input),
    beginSignIn: input => request('beginSignIn', input),
    signInStatus: () => request('signInStatus'),
    stats: () => ({ childAlive: !exited, pendingRequests: pending.size, ...localWork }),
    runtimeStats: () => request('stats'),
    close,
  };
}
