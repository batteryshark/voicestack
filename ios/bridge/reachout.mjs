#!/usr/bin/env node
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { CONFIG, REACHOUT_REASONS, sendSchema, stableID, requireThat } from './reachout-policy.mjs';
import { owned } from './push-store.mjs';
import { readDevOverride, writeDevOverride, validOverride } from './dev-override.mjs';

export const USAGE = `Voicestack reach-out sender (does not prompt a session)
Usage: node bridge/reachout.mjs send --kind KIND --reason REASON --session SESSION --id UNIQUE_ID --title TEXT --body TEXT [--dry-run]
       node bridge/reachout.mjs status --id ID
       node bridge/reachout.mjs dev-override on --minutes N --reason "Development test"
       node bridge/reachout.mjs dev-override off
       node bridge/reachout.mjs dev-override status
Allowed --kind and --reason values:
${Object.entries(REACHOUT_REASONS).map(([kind,reasons])=>`  ${kind}: ${reasons.join('|')}`).join('\n')}
Examples (offline schema checks; --dry-run sends nothing and does not evaluate live policy):
  node bridge/reachout.mjs send --kind need --reason hands --session ses_CHIEF --id UNIQUE_NEED_ID --title "Voicestack test" --body "Tap to open" --dry-run
  node bridge/reachout.mjs send --kind ready-to-try --reason build --session ses_CHIEF --id UNIQUE_BUILD_ID --title "Voicestack test" --body "Ready to review" --dry-run
  node bridge/reachout.mjs send --kind urgent-call --reason decision --session ses_CHIEF --id UNIQUE_CALL_ID --title "Voicestack test call" --body "Voicestack test call" --dry-run
Real calls require explicit approval. Development override (1..1440 minutes) bypasses only call spacing/daily and notification-hour caps; quiet hours, Focus and outstanding-call safety remain. Normal policy (15-minute spacing, 3/day, 6 notifications/hour) applies when OFF/expired. Never retry an uncertain send or reuse its ID.`;

export function parseArgs(args) {
  if (args.length === 1 && ['--help','-h'].includes(args[0])) return { command:'help', help:USAGE };
  try { return parseValidatedArgs(args); }
  catch (error) { error.message += '\n'+USAGE; error.status ??= 400; throw error; }
}
function parseValidatedArgs(args) {
  const [command, ...rest] = args, values = {};
  if (command === 'dev-override') {
    const [action, ...options] = rest;
    requireThat(['on', 'off', 'status'].includes(action));
    if (action !== 'on') { requireThat(options.length === 0); return { command, action }; }
    for (let i = 0; i < options.length; i += 2) {
      const key = options[i];
      requireThat(['--minutes', '--reason'].includes(key) && !Object.hasOwn(values, key) && i + 1 < options.length);
      values[key] = options[i + 1];
    }
    requireThat(/^\d+$/.test(values['--minutes'] ?? ''));
    const minutes = Number(values['--minutes']), reason = values['--reason']?.trim();
    requireThat(Number.isInteger(minutes) && minutes >= 1 && minutes <= 1440);
    requireThat(validOverride({ version: 1, enabled: true, setAt: 0, until: minutes * 60000, reason }, 0));
    return { command, action, minutes, reason };
  }
  const flags = { '--kind': 'kind', '--reason': 'reason', '--session': 'session', '--id': 'id', '--title': 'title', '--body': 'body', '--url': 'url', '--expires-in': 'expiresIn', '--message-id': 'messageID' };
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
export function socketRequest(socketPath, request, { projectRoot = PROJECT_ROOT } = {}) {
  // Trust the code's project directory, not a path supplied by the socket or CLI.
  // Canonicalize that anchor only; lstat every untrusted descendant before connect.
  const root = path.resolve(projectRoot);
  requireThat(path.isAbsolute(socketPath) && path.resolve(socketPath) === path.join(root, 'private/push/sender.sock'), 503, 'untrusted sender path');
  const anchor = fs.realpathSync(root);
  owned(path.join(anchor, 'private'), 'directory', 0o700);
  owned(path.join(anchor, 'private/push'), 'directory', 0o700);
  socketPath = path.join(anchor, 'private/push/sender.sock');
  owned(socketPath, 'socket', 0o600);
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath); let size = 0, chunks = [];
    const timer = setTimeout(() => socket.destroy(new Error('sender deadline; check status before any new id')), 15000);
    socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'));
    socket.on('data', chunk => { size += chunk.length; if (size > 65536) socket.destroy(new Error('sender response limit')); else chunks.push(chunk); });
    socket.on('close', () => clearTimeout(timer)); socket.on('error', reject);
    socket.on('end', () => { try { resolve(JSON.parse(Buffer.concat(chunks))); } catch { reject(new Error('sender result unknown; check status')); } });
  });
}
export async function main(args, { projectRoot = PROJECT_ROOT, now = Date.now } = {}) {
  const request = parseArgs(args);
  if (request.command === 'help') return { help: USAGE };
  if (request.command === 'dev-override') {
    const root = fs.realpathSync(projectRoot), directory = path.join(root, 'private/push');
    owned(path.join(root, 'private'), 'directory', 0o700); owned(directory, 'directory', 0o700);
    const at = now();
    const value = request.action === 'status' ? readDevOverride(directory, at)
      : writeDevOverride(directory, { enabled: request.action === 'on', minutes: request.minutes, reason: request.reason }, at);
    return { active: value.active, until: value.until === undefined ? null : new Date(value.until).toLocaleString(), reason: value.reason ?? null };
  }
  // Offline validation only: no store, key, socket or network access.
  if (request.dryRun) return { id: request.request.id, disposition: 'dry-run', policyReason: 'schema-valid; live policy not evaluated' };
  return socketRequest(path.join(projectRoot, 'private/push/sender.sock'), request, { projectRoot });
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { const result = await main(process.argv.slice(2)); console.log(result.help ?? JSON.stringify(result.error ? {...result,help:USAGE} : result)); if (result.error) process.exitCode = 1; }
  catch (e) { console.log(JSON.stringify({ error: e.status ? e.message : 'sender unavailable; check status before a new id' })); process.exitCode = 1; }
}
