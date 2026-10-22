#!/usr/bin/env node
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { CONFIG, REACHOUT_REASONS, sendSchema, stableID, requireThat } from './reachout-policy.mjs';
import { owned } from './push-store.mjs';

export const USAGE = `Voicestack call sender (does not prompt a session; messages and notifications go through Nod)
Usage: node bridge/reachout.mjs send --kind KIND --reason REASON --session SESSION --id UNIQUE_ID --title TEXT --body TEXT [--dry-run]
        node bridge/reachout.mjs open-voice readiness
        node bridge/reachout.mjs open-voice prepare
       node bridge/reachout.mjs open-voice ring --snapshot JSON --operation-id UUID --reason decision|goal-risk --summary TEXT [--port 8794]
        node bridge/reachout.mjs maintenance hold|status|seal|release
        node bridge/reachout.mjs reconcile-ended --id ID --device-id DEVICE --call-uuid UUID --principal-confirmed-ended
       node bridge/reachout.mjs status --id ID
Allowed --kind and --reason values:
${Object.entries(REACHOUT_REASONS).map(([kind,reasons])=>`  ${kind}: ${reasons.join('|')}`).join('\n')}
Examples (offline schema checks; --dry-run sends nothing and does not evaluate live policy):
  node bridge/reachout.mjs send --kind urgent-call --reason decision --session ses_CHIEF --id UNIQUE_CALL_ID --title "Voicestack test call" --body "Voicestack test call" --dry-run
Calls follow the principal's standing permission and the phone's Calls/quiet-hours settings. Focus and outstanding-call safety apply. A call that is not answered only reports its outcome (no follow-up notification). Ordinary calls have no daily/spacing cap. Never retry an uncertain send or reuse its ID.`;

export function parseArgs(args) {
  if (args.length === 1 && ['--help','-h'].includes(args[0])) return { command:'help', help:USAGE };
  try { return parseValidatedArgs(args); }
  catch (error) { error.message += '\n'+USAGE; error.status ??= 400; throw error; }
}
function parseValidatedArgs(args) {
  const [command, ...rest] = args, values = {};
  if (command === 'reconcile-ended') {
    const fields = {'--id':'id','--device-id':'deviceID','--call-uuid':'callUUID'};
    let confirmed = false;
    for (let i=0;i<rest.length;i++) {
      if (rest[i] === '--principal-confirmed-ended') { requireThat(!confirmed); confirmed=true; continue; }
      const field=fields[rest[i]]; requireThat(field && !Object.hasOwn(values,field) && i+1<rest.length);
      values[field]=rest[++i];
    }
    requireThat(confirmed && stableID(values.id) && stableID(values.deviceID) && /^[0-9a-f-]{36}$/i.test(values.callUUID??''));
    return {command,request:{...values,provenance:'principal-confirmed ended'}};
  }
  if (command === 'open-voice') {
    const [action, ...options] = rest;
    if (['readiness', 'prepare'].includes(action)) { requireThat(!options.length); return { command, action }; }
    requireThat(action === 'ring');
    for (let i = 0; i < options.length; i += 2) {
      const k = options[i]; requireThat(['--snapshot', '--operation-id', '--reason', '--summary', '--port'].includes(k)
        && !Object.hasOwn(values, k) && i + 1 < options.length); values[k] = options[i + 1];
    }
    requireThat(typeof values['--snapshot'] === 'string' && values['--snapshot'].length <= 4096);
    const snapshot = JSON.parse(values['--snapshot']);
    requireThat(snapshot?.ready === true && /^[a-f0-9]{64}$/.test(snapshot.fingerprint) && Number.isSafeInteger(snapshot.expires_at));
    const operation_id = values['--operation-id'], reason = values['--reason'], summary = values['--summary'];
    requireThat(typeof operation_id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(operation_id));
    requireThat(['decision', 'goal-risk'].includes(reason) && typeof summary === 'string' && summary.trim()
      && summary.length <= 240 && !/[\x00-\x1f\x7f\uD800-\uDFFF]/u.test(summary) && !/\bmilestone\b/i.test(summary));
    requireThat(/^\d{1,5}$/.test(values['--port'] ?? '8794'));
    const port = Number(values['--port'] ?? 8794); requireThat(port === 8794, 400, 'unowned call destination');
    return { command, action, snapshot, operation_id, reason, summary, port };
  }
  if (command === 'maintenance') {
    requireThat(rest.length === 1 && ['hold', 'status', 'seal', 'release'].includes(rest[0]));
    return { command, action: rest[0] };
  }
  const flags = { '--kind': 'kind', '--reason': 'reason', '--session': 'session', '--id': 'id', '--title': 'title', '--body': 'body', '--expires-in': 'expiresIn', '--message-id': 'messageID' };
  let dryRun = false;
  for (let i = 0; i < rest.length; i++) {
    const flag = rest[i];
    if (flag === '--dry-run') { requireThat(!dryRun); dryRun = true; continue; }
    requireThat(Object.hasOwn(flags, flag) && !Object.hasOwn(values, flags[flag]) && i + 1 < rest.length);
    values[flags[flag]] = rest[++i];
  }
  if (values.expiresIn !== undefined) { requireThat(/^\d+$/.test(values.expiresIn)); values.expiresIn = Number(values.expiresIn); }
  if (command === 'send') return { command, request: sendSchema(values, CONFIG), dryRun };
  requireThat(command === 'status' && Object.keys(values).length === 1 && stableID(values.id) && !dryRun);
  return { command, id: values.id };
}
const PROJECT_ROOT = fs.realpathSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'));
export function socketRequest(socketPath, request, { projectRoot = PROJECT_ROOT, admin = false } = {}) {
  // Trust the code's project directory, not a path supplied by the socket or CLI.
  // Canonicalize that anchor only; lstat every untrusted descendant before connect.
  const root = path.resolve(projectRoot);
  const name = admin ? 'open-voice-admin.sock' : 'sender.sock';
  requireThat(path.isAbsolute(socketPath) && path.resolve(socketPath) === path.join(root, 'private/push', name), 503, 'untrusted sender path');
  const anchor = fs.realpathSync(root);
  owned(path.join(anchor, 'private'), 'directory', 0o700);
  owned(path.join(anchor, 'private/push'), 'directory', 0o700);
  socketPath = path.join(anchor, 'private/push', name);
  owned(socketPath, 'socket', 0o600);
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath); let size = 0, chunks = [];
    const timer = setTimeout(() => socket.destroy(new Error('sender deadline; check status before any new id')), admin ? 4800 : 15000);
    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'));
    socket.on('data', chunk => { size += chunk.length; if (size > 65536) socket.destroy(new Error('sender response limit')); else chunks.push(chunk); });
    socket.on('close', () => clearTimeout(timer)); socket.on('error', reject);
    socket.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks))); } catch { reject(new Error('sender result unknown; check status')); } });
  });
}

// Fixed loopback caller route; no redirect, discovery, token file or hidden retry.
export function callPost(port, token, body) {
  requireThat(port === 8794, 400, 'unowned call destination');
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: '/floating-voice/voice/v1/calls', method: 'POST', agent: false,
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' } }, res => {
      let size = 0, chunks = [];
      res.on('data', b => { size += b.length; if (size > 4096) req.destroy(new Error('unknown')); else chunks.push(b); });
      res.on('error', reject); res.on('aborted', () => reject(new Error('unknown')));
      res.on('end', () => { try { resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks)) }); } catch { reject(new Error('unknown')); } });
    });
    const timer = setTimeout(() => req.destroy(new Error('unknown')), 4000);
    req.on('error', reject); req.on('close', () => clearTimeout(timer)); req.end(JSON.stringify(body));
  });
}

// No shell, environment-selected command, model override or service lifecycle action.
export const SPEECHCTL = path.join(os.homedir(), '.local/share/voicestack/speech/scripts/speechctl');
const SPEECH_ROOT = path.dirname(path.dirname(SPEECHCTL));
const commandEnv = () => ({ HOME: os.homedir(), PATH: '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' });
export function fixedCommand(file, args, timeout) {
  return new Promise(resolve => {
    execFile(file, args, { timeout, killSignal: 'SIGKILL', maxBuffer: 16384, env: commandEnv() }, error => {
      resolve({ ok: !error, unknown: !!error && (error.killed || error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') });
    });
  });
}
export async function hostAdmission() {
  const read = (file, args) => new Promise(resolve => execFile(file, args,
    { timeout: 2000, killSignal: 'SIGKILL', maxBuffer: 4096, env: commandEnv() }, (error, stdout) => resolve(error ? null : stdout)));
  const [cpu, memory] = await Promise.all([read('/usr/sbin/sysctl', ['-n', 'hw.logicalcpu']), read('/usr/bin/memory_pressure', ['-Q'])]);
  return hostCapacity(cpu, memory, os.loadavg()[0]);
}
export function hostCapacity(cpu, memory, load) {
  const logicalCPU = /^\s*\d+\s*$/.test(cpu ?? '') ? Number(cpu) : NaN;
  const match = memory?.match(/System-wide memory free percentage:\s*(\d+)%/);
  const free = match ? Number(match[1]) : NaN;
  return Number.isFinite(load) && load >= 0 && logicalCPU > 0 && load < logicalCPU && free >= 20 && free <= 100;
}

// Read only public ProgramArguments, UID/argv, PID table and loopback listeners.
// No launchctl print, EnvironmentVariables, client config or credential projection.
export async function speechOwnerMapping({ read = publicCommand, realpath = fs.realpathSync } = {}) {
  try {
    const jobs = await read('/bin/launchctl', ['list']);
    for (const [name, port] of [['stt', 8446], ['tts', 8444], ['breeze', 8450]]) {
      const label = 'local.speechd.' + name;
      const rows = jobs.split('\n').map(l => l.trim().split(/\s+/)).filter(r => r[2] === label);
      if (rows.length !== 1 || !/^\d+$/.test(rows[0][0]) || Number(rows[0][0]) <= 1) return false;
      const pid = rows[0][0];
      const projection = await read('/usr/libexec/PlistBuddy', ['-c', 'Print :ProgramArguments', path.join(os.homedir(), 'Library/LaunchAgents', label + '.plist')]);
      const lines = projection.trim().split('\n').map(l => l.trim());
      if (lines.shift() !== 'Array {' || lines.pop() !== '}') return false;
      const args = speechLaunchArguments(name, lines, { realpath });
      if (!args) return false;
      const actual = (await read('/bin/ps', ['-ww', '-p', pid, '-o', 'uid=,command='])).trim();
      if (actual !== process.getuid() + ' ' + args.join(' ')) return false;
      const listeners = await read('/usr/sbin/lsof', ['-nP', '-iTCP:' + port, '-sTCP:LISTEN', '-Fpn']);
      const addresses = listeners.split('\n').filter(l => l.startsWith('n'));
      const owners = listeners.split('\n').filter(l => l.startsWith('p'));
      if (owners.length !== 1 || owners[0] !== 'p' + pid || addresses.length !== 1 || addresses[0] !== 'n127.0.0.1:' + port) return false;
      const current = (await read('/bin/launchctl', ['list'])).split('\n').map(l => l.trim().split(/\s+/)).filter(r => r[2] === label);
      if (current.length !== 1 || current[0][0] !== pid) return false;
    }
    return true;
  } catch { return false; }
}
// Exact deployed launchd log/chdir wrapper execs the original argv in-place. It
// is not a generic '-c' equivalence or permission to trust arbitrary wrappers.
export const SPEECH_EXEC_WRAPPER = 'import os,sys; os.chdir(sys.argv[1]); fd=os.open(sys.argv[2],os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o644); os.dup2(fd,1); os.dup2(fd,2); os.close(fd); os.execv(sys.argv[3],sys.argv[3:])';
export function speechLaunchArguments(name, supplied, { realpath = fs.realpathSync } = {}) {
  let args = supplied;
  if (supplied[1] === '-c') {
    args = supplied.slice(5);
    const cwd = SPEECH_ROOT + (name === 'breeze' ? '/upstream/breeze-server' : '');
    if (!args[0] || supplied[2] !== SPEECH_EXEC_WRAPPER || supplied[3] !== cwd
      || supplied[4] !== SPEECH_ROOT + '/logs/' + name + '.log' || supplied[0] !== realpath(args[0])) return null;
  }
  return speechProgramArguments(name, args) ? args : null;
}
function publicCommand(file, args) {
  return new Promise((resolve, reject) => execFile(file, args, { env: commandEnv(), timeout: 1500, maxBuffer: 65536 },
    (error, stdout) => error ? reject(Error('owner_identity_unavailable')) : resolve(stdout)));
}
export function speechProgramArguments(name, args) {
  const pair = (key, value, list = args) => list.filter(v => v === key).length === 1 && list[list.indexOf(key) + 1] === value;
  if (!args.every(v => typeof v === 'string' && v && !/[\r\n\0]/.test(v)) || args[0] !== SPEECH_ROOT + '/.venv/bin/python') return false;
  const revision = 'dac391237f6bf6130b1c1d277f0ebc0b886e419e';
  if (name === 'tts') return args[1] === '-m' && args[2] === 'speechd.tts_gateway'
    && pair('--upstream', 'http://127.0.0.1:8450') && pair('--host', '127.0.0.1') && pair('--port', '8444')
    && pair('--model-id', 'Shoof/Gust-MLX') && pair('--revision', revision) && pair('--precision', 'mixed') && pair('--default-voice', 'mizuki');
  const split = args.indexOf('--'), proxy = args.slice(0, split), child = args.slice(split + 1);
  if (split < 0 || args[1] !== SPEECH_ROOT + '/speechd/idle_proxy.py' || !pair('--service', name, proxy)
    || !pair('--host', '127.0.0.1', proxy) || !pair('--port', name === 'stt' ? '8446' : '8450', proxy)
    || !pair('--idle-unload-s', '900', proxy)) return false;
  if (name === 'stt') return child[0] === SPEECH_ROOT + '/.venv/bin/python' && child[1] === '-m' && child[2] === 'speechd.stt_server'
    && !child.includes('--no-partials')
    && pair('--backend', 'parakeet', child) && pair('--model-id', 'handy-computer/parakeet-unified-en-0.6b-gguf', child)
    && pair('--revision', '7e948f21b7bdbac698d3318db9d350f1096f3b6c', child) && pair('--precision', 'Q8_0', child);
  return name === 'breeze' && child[0] === SPEECH_ROOT + '/upstream/breeze-server/.venv/bin/python'
    && child[1] === '-m' && child[2] === 'breeze_infer.api'
    && child[3] === os.homedir() + '/.cache/huggingface/hub/models--Shoof--Gust-MLX/snapshots/' + revision;
}

function budgeted(budgetMs) {
  const started = performance.now(), remaining = () => Math.floor(budgetMs - (performance.now() - started));
  const bounded = async (work, ms) => {
    if (ms <= 0) throw Error('deadline');
    let timer;
    try { return await Promise.race([work(), new Promise((_, reject) => { timer = setTimeout(() => reject(Error('deadline')), ms); })]); }
    finally { clearTimeout(timer); }
  };
  return { remaining, bounded };
}
// Shared guarded warm: owner mapping, public activity snapshot, host admission,
// then the fixed `speechctl load all` only when cold. Never unloads or restarts.
async function warmSpeech({ status, runFixed, admitHost, ownerMapping, bounded, remaining, state }) {
  if (!await bounded(ownerMapping, remaining() - 4800)) return 'speech_owner_identity_unavailable';
  const before = await bounded(status, remaining() - 4800);
  if (before?.ready === true) { state.load = 'skipped_ready'; return null; }
  if (before?.loadable !== true) return 'speech_admission_denied';
  if (!await bounded(admitHost, remaining() - 4800)) return 'host_admission_denied';
  // Refresh activity immediately after the host commands, just before mutation.
  const fresh = await bounded(status, remaining() - 4800);
  if (fresh?.ready === true) { state.load = 'skipped_ready'; return null; }
  if (fresh?.loadable !== true) return 'speech_admission_denied';
  state.load = 'unknown';
  const result = await bounded(() => runFixed(SPEECHCTL, ['load', 'all'], Math.max(1, remaining() - 4800)), remaining() - 4800);
  if (result?.ok !== true) { state.load = result?.unknown ? 'unknown' : 'failed'; return result?.unknown ? 'load_outcome_unknown' : 'load_failed'; }
  state.load = 'completed';
  if (!await bounded(ownerMapping, remaining() - 4800)) return 'speech_owner_identity_unavailable';
  return null;
}

export async function prepareOpenVoice({ admin, now = Date.now, runFixed = fixedCommand, admitHost = hostAdmission,
  ownerMapping = speechOwnerMapping, budgetMs = 150000 }) {
  // DI is code-only; CLI accepts no command, environment, budget or resource bypass.
  requireThat(Number.isInteger(budgetMs) && budgetMs > 4800 && budgetMs <= 150000);
  const { remaining, bounded } = budgeted(budgetMs);
  const failed = (reason, load = 'not_attempted') => ({ ready: false, reason, load, providerAcceptance: 'not_proven' });
  const state = { load: 'not_attempted' };
  let load = 'not_attempted';
  try {
    const target = await bounded(() => admin({ command: 'prepare' }), remaining() - 4800);
    if (target?.prepared !== true) return failed(target?.reason ?? 'target_preparation_unknown');
    try {
      const refused = await warmSpeech({ status: () => admin({ command: 'speech-status' }), runFixed, admitHost, ownerMapping, bounded, remaining, state });
      if (refused) return failed(refused, state.load);
    } finally { load = state.load; }
    // The fresh readiness clock starts AFTER cold startup; no old 10s observation.
    const status = await bounded(() => admin({ command: 'readiness' }), Math.min(4800, remaining()));
    if (status?.ready !== true || !/^[a-f0-9]{64}$/.test(status.fingerprint) || !stableID(status.caller_id) || !stableID(status.project_id)
      || !Number.isSafeInteger(status.expires_at) || !Number.isSafeInteger(status.mapping_expires_at)
      || now() >= status.expires_at || status.expires_at > status.mapping_expires_at || status.mapping_expires_at - now() < 180000)
      return failed(status?.reason ?? 'not_ready', load);
    return { ...status, load, speechAdmission: 'bounded_public_snapshot_not_shared_reservation' };
  } catch { return failed(load === 'unknown' ? 'load_outcome_unknown' : 'preparation_unknown', load); }
}

// Ordinary calls use the bridge's fixed loopback speech routes (server.mjs ttsPort/asrPort).
export const CALL_SPEECH = Object.freeze({ sttURL: 'ws://127.0.0.1:8446/v1/transcribe', ttsURL: 'http://127.0.0.1:8444/v1/audio/speech', model: 'tts-1', voice: 'default' });
export const inspectCallSpeech = async () => {
  const { speechHealth, preparationSpeechState } = await import('./open-voice-speech.mjs');
  return preparationSpeechState(await speechHealth(CALL_SPEECH, { inspect: true }), CALL_SPEECH);
};
// One tiny real synthesis through the local gateway; proof is non-empty PCM.
export function testSynthesis(timeoutMs = 20000) {
  return new Promise(resolve => {
    let bytes = 0, done = false;
    const finish = ok => { if (done) return; done = true; clearTimeout(timer); req.destroy(); resolve(ok); };
    const req = http.request({ host: '127.0.0.1', port: 8444, path: '/v1/audio/speech', method: 'POST', agent: false,
      headers: { 'content-type': 'application/json' } }, res => {
      const type = res.headers['content-type'] ?? '';
      if (res.statusCode !== 200 || /wav|mpeg|json|text/i.test(type)) return finish(false);
      res.on('data', b => { bytes += b.length; if (bytes > 4320000) finish(false); });
      res.on('error', () => finish(false)); res.on('aborted', () => finish(false));
      res.on('end', () => finish(bytes > 0 && bytes % 2 === 0));
    });
    const timer = setTimeout(() => finish(false), timeoutMs);
    req.on('error', () => finish(false));
    req.end(JSON.stringify({ model: CALL_SPEECH.model, voice: CALL_SPEECH.voice, input: 'Ready.', response_format: 'pcm' }));
  });
}
export async function ensureCallSpeech({ runFixed = fixedCommand, admitHost = hostAdmission, ownerMapping = speechOwnerMapping,
  inspect = inspectCallSpeech, synthesize = testSynthesis, budgetMs = 150000 } = {}) {
  const { remaining, bounded } = budgeted(budgetMs);
  const state = { load: 'not_attempted' };
  try {
    const refused = await warmSpeech({ status: inspect, runFixed, admitHost, ownerMapping, bounded, remaining, state });
    if (refused) return { ready: false, reason: refused, load: state.load };
    if (!await bounded(() => synthesize(Math.min(20000, Math.max(1, remaining() - 4800))), remaining() - 4800))
      return { ready: false, reason: 'test_synthesis_failed', load: state.load };
    // STT (partials loaded) and Breeze readiness after the synthesis, not before it.
    const after = await bounded(inspect, remaining());
    if (after?.ready !== true) return { ready: false, reason: 'speech_not_ready_after_warm', load: state.load };
    return { ready: true, load: state.load };
  } catch { return { ready: false, reason: state.load === 'unknown' ? 'load_outcome_unknown' : 'speech_check_unknown', load: state.load }; }
}

export async function openVoice(request, { admin, post = callPost, now = Date.now, runFixed, admitHost, ownerMapping, budgetMs }) {
  const unavailable = reason => ({ ready: false, reason, providerAcceptance: 'not_proven' });
  if (request.action === 'prepare') return prepareOpenVoice({ admin, now, runFixed, admitHost, ownerMapping, budgetMs });
  if (request.action === 'readiness') {
    try { const r = await admin({ command: 'readiness' }); return typeof r?.ready === 'boolean' ? r : unavailable('owner_unavailable'); }
    catch { return unavailable('owner_unavailable'); }
  }
  const { operation_id, snapshot } = request;
  const result = (outcome, reason, extra = {}) => ({ outcome, reason, operation_id, ...extra });
  if (request.port !== 8794) return result('refused', 'unowned_call_destination');
  if (now() >= snapshot.expires_at) return result('refused', 'expired');
  let fresh;
  try { fresh = await admin({ command: 'readiness' }); } catch { return result('refused', 'owner_unavailable'); }
  if (!fresh?.ready) return result('refused', 'not_ready');
  if (fresh.fingerprint !== snapshot.fingerprint || now() >= snapshot.expires_at || now() >= fresh.expires_at
    || fresh.mapping_expires_at - now() < 180000) return result('refused', 'changed_or_expired');
  let grant;
  try {
    grant = await admin({ command: 'issue', value: { caller_id: fresh.caller_id, project_ids: [fresh.project_id],
      scopes: ['call:request', 'call:status:own'], expires_at: Math.min(fresh.mapping_expires_at, now() + 900000) } });
  } catch { return result('unknown', 'issue_receipt_unknown'); }
  // A generic owner error is not proof that durable issuance never happened.
  if (grant?.error) return result('unknown', 'issue_receipt_unknown');
  if (!grant?.grant_id || !/^[A-Za-z0-9_-]{43}$/.test(grant.token)) return result('unknown', 'issue_receipt_unknown');
  const grant_id = grant.grant_id;
  const revoke = async () => {
    try { return (await admin({ command: 'revoke', grant_id }))?.revoked === true; } catch { return false; }
  };
  // An issue ACK can arrive after the observation expired. Never force a late call.
  if (now() >= snapshot.expires_at || now() >= fresh.expires_at || fresh.mapping_expires_at - now() < 180000) {
    grant.token = undefined; return result('refused', 'expired', { grant_id, revoked: await revoke() });
  }
  try {
    const response = await post(request.port, grant.token, { operation_id, project_id: fresh.project_id,
      reason: request.reason, summary: request.summary, expires_in: 60 });
    if (response.status === 200 && /^[0-9a-f-]{36}$/i.test(response.body?.call_id)
      && ['ringing', 'accepted', 'ended', 'rejected', 'expired'].includes(response.body.status))
      return result('submitted', 'call_intent_not_delivery', { grant_id, call_id: response.body.call_id, status: response.body.status });
    if ([400, 401, 403, 404, 409, 410, 413, 415, 429].includes(response.status))
      return result('refused', 'call_refused', { grant_id, revoked: await revoke() });
    return result('unknown', 'call_receipt_unknown', { grant_id });
  } catch { return result('unknown', 'call_receipt_unknown', { grant_id }); }
  finally { grant.token = undefined; }
}

// One plain line for the Chief from the first phone receipt. Read-only; never resends.
const SETTLED = ['ringing', 'answered', 'declined', 'ended', 'report-failed', 'expired'];
export function callAnswer(status) {
  const t = status?.targets?.length === 1 ? status.targets[0] : null;
  if (!t) return status?.targets?.length ? 'several devices; see status (not retried)' : 'no answer from the phone yet (not retried)';
  if (t.message) return 'declined: ' + t.message;
  if (['not-called', 'notification-intent', 'notification-only'].includes(t.delivery) || t.policyReason !== 'urgent-eligible')
    return `not called: ${t.policyReason}` + (t.policyReason === 'calls-disabled' ? ' (calls are off on the bridge)' : '');
  switch (t.receipt) {
    case 'ringing': case 'answered': return t.receipt;
    case 'declined': return 'declined';
    case 'report-failed': return 'the phone could not show the call (not retried)';
    case 'expired': return 'no answer before the ring deadline (not retried)';
    case 'ended': return t.endReason === 'admissionRejected' ? 'declined by the phone: calls are off on the phone, or it could not take a call now'
      : 'ended' + (t.endReason ? ` (${t.endReason})` : '');
  }
  if (t.delivery === 'apns-rejected') return 'Apple rejected the call push (not retried)';
  return 'no answer from the phone yet (not retried)';
}
export async function awaitCallAnswer(id, status, { timeoutMs = 15000, intervalMs = 1000, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last;
  for (;;) {
    try { last = await status({ command: 'status', id }); } catch { /* keep the last observation */ }
    const t = last?.targets?.length === 1 ? last.targets[0] : null;
    if (t && (t.message || SETTLED.includes(t.receipt) || t.delivery === 'apns-rejected' || t.policyReason !== 'urgent-eligible')) break;
    if (Date.now() + intervalMs > deadline) break;
    await sleep(intervalMs);
  }
  return callAnswer(last);
}

export async function main(args, { projectRoot = PROJECT_ROOT, now = Date.now, post = callPost, admin, runFixed, admitHost, ownerMapping, budgetMs,
  ensureSpeech = ensureCallSpeech, sender, answerWait } = {}) {
  const request = parseArgs(args);
  if (request.command === 'help') return { help: USAGE };
  if (request.command === 'open-voice') return openVoice(request, { now, post, runFixed, admitHost, ownerMapping, budgetMs,
    admin: admin ?? (input => socketRequest(path.join(projectRoot, 'private/push/open-voice-admin.sock'), input, { projectRoot, admin: true })) });
  // Offline validation only: no store, key, socket or network access.
  if (request.dryRun) return { id: request.request.id, disposition: 'dry-run', policyReason: 'schema-valid; live policy not evaluated' };
  if (request.command === 'send') {
    // Warm speech before any APNs ring; a cold or unproven speech path never rings.
    const speech = await ensureSpeech();
    if (speech?.ready !== true) return { id: request.request.id, outcome: 'refused', reason: 'speech_not_ready',
      detail: `Call not placed: speech not ready (${speech?.reason ?? 'unknown'}, load ${speech?.load ?? 'unknown'}); nothing was sent` };
  }
  sender ??= input => socketRequest(path.join(projectRoot, 'private/push/sender.sock'), input, { projectRoot });
  const result = await sender(request);
  if (request.command === 'send' && result && !result.error && result.id === request.request.id)
    return { ...result, answer: await awaitCallAnswer(request.request.id, sender, answerWait) };
  return result;
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { const result = await main(process.argv.slice(2)); console.log(result.help ?? JSON.stringify(result.error ? {...result,help:USAGE} : result));
    if (result.answer) console.error(result.answer); if (result.error || result.ready === false || ['refused', 'unknown'].includes(result.outcome)) process.exitCode = 1; }
  catch (e) { console.log(JSON.stringify({ error: e.status ? e.message : 'sender unavailable; check status before a new id' })); process.exitCode = 1; }
}
