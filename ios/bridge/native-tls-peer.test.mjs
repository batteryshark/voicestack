import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import https from 'node:https';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
const source = fileURLToPath(new URL('./fixtures/open-voice/native-tls-peer.mjs', import.meta.url));
const v = JSON.parse(fs.readFileSync(new URL('./fixtures/open-voice/control-vectors.json', import.meta.url)));
function root(t, san = 'IP:127.0.0.1') {
  const base = path.join(os.tmpdir(), 'opencode'); fs.mkdirSync(base, { recursive: true, mode: 0o700 });
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(base, 'fv-native-peer-'))); fs.chmodSync(dir, 0o700);
  const children = [];
  t.after(async () => {
    for (const { child } of children) if (child.exitCode === null) child.kill('SIGTERM');
    const timer = setTimeout(() => { for (const { child } of children) if (child.exitCode === null) child.kill('SIGKILL'); }, 2000);
    await Promise.all(children.map(c => c.exit)); clearTimeout(timer); fs.rmSync(dir, { recursive: true, force: true });
  });
  const cert = path.join(dir, 'cert.pem'), key = path.join(dir, 'key.pem'), conf = path.join(dir, 'empty.cnf');
  fs.writeFileSync(conf, `[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=fixture.invalid\n[ext]\nsubjectAltName=${san}\n`, { mode: 0o600 });
  // Fresh owned test material only. The generator writes the key; only the Node peer reads that key file.
  execFileSync('openssl', ['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',conf,'-keyout',key,'-out',cert],
    { env: { PATH: process.env.PATH, HOME: dir, OPENSSL_CONF: conf }, stdio: 'ignore', timeout: 10000 });
  fs.chmodSync(cert, 0o600); fs.chmodSync(key, 0o600); return { dir, cert, key, ca: fs.readFileSync(cert), children };
}
async function peer(t, mode, material = root(t), overrides = {}) {
  const child = spawn(process.execPath, [source], { cwd: material.dir, env: { PATH: process.env.PATH, HOME: material.dir, TMPDIR: os.tmpdir() }, stdio: ['pipe','pipe','pipe'] });
  const exit = once(child, 'close'); let output = '', errors = '', buffered = ''; const events = [], waiters = [];
  material.children.push({ child, exit });
  child.stdin.on('error', () => {}); child.stderr.on('data', b => { errors += b; });
  child.stdout.on('data', b => {
    output += b; buffered += b;
    while (buffered.includes('\n')) { const at = buffered.indexOf('\n'); events.push(JSON.parse(buffered.slice(0, at))); buffered = buffered.slice(at + 1); for (const fn of [...waiters]) fn(); }
  });
  const wait = (event, request_id) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); reject(new Error('peer IPC timeout: ' + event + ' ' + JSON.stringify(events))); }, event === 'idle_elapsed' ? 19000 : 3000);
    const cleanup = () => { clearTimeout(timer); const i = waiters.indexOf(find); if (i >= 0) waiters.splice(i, 1); };
    const find = () => { const found = events.find(e => e.event === event && (request_id === undefined || e.request_id === request_id)); if (found) { cleanup(); resolve(found); } };
    waiters.push(find); find();
  });
  let requestID = 0;
  const command = async command => { const request_id = ++requestID; child.stdin.write(JSON.stringify({ command, request_id }) + '\n'); return wait(command === 'close' ? 'closed' : 'counters', request_id); };
  const config = { synthetic: true, root: material.dir, cert_path: material.cert, key_path: material.key,
    device_token: 'fixture-device-token', caller_token: 'fixture-caller-token', media_token: 'fixture-media-token', mode, ...overrides };
  t.after(async () => {
    if (child.exitCode === null) child.stdin.write(JSON.stringify({ command: 'shutdown' }) + '\n');
    const timer = setTimeout(() => child.kill('SIGKILL'), 2000);
    await exit; clearTimeout(timer); assert.equal(errors, '');
    for (const value of [config.root, config.key_path, config.cert_path, config.device_token, config.caller_token, config.media_token, 'BEGIN PRIVATE KEY']) assert.ok(!output.includes(value));
  });
  child.stdin.write(JSON.stringify(config) + '\n'); const ready = await wait('ready');
  const base = `https://127.0.0.1:${ready.port}`;
  const request = (route, token = config.device_token, body) => new Promise((resolve, reject) => {
    const bytes = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = https.request(base + '/floating-voice/voice/v1' + route, { ca: material.ca, method: bytes ? 'POST' : 'GET',
      headers: { Authorization: 'Bearer ' + token, ...(bytes ? { 'Content-Type':'application/json','Content-Length':bytes.length } : {}) } }, res => {
      const chunks = []; res.on('data', b => chunks.push(b)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString() }));
    }); req.setTimeout(2000, () => req.destroy()); req.on('error', reject); req.end(bytes);
  });
  const connect = async (token = config.media_token, options = {}) => {
    const ws = new WebSocket(base.replace('https:', 'wss:') + '/floating-voice/v1/realtime?model=local-chain-m1', { ca: material.ca,
      headers: { Authorization: 'Bearer ' + token }, perMessageDeflate: false, ...options });
    ws.on('error', () => {}); const closed = once(ws, 'close').catch(() => {}); t.after(() => ws.terminate());
    const messages = [], notifications = [];
    ws.on('message', b => { try { messages.push(JSON.parse(b.toString())); } catch {} for (const fn of [...notifications]) fn(); });
    const event = type => new Promise((resolve, reject) => {
      const timer = setTimeout(() => { cleanup(); reject(new Error('WS event timeout: ' + type)); }, 2000);
      const cleanup = () => { clearTimeout(timer); const i = notifications.indexOf(find); if (i >= 0) notifications.splice(i, 1); };
      const find = () => { const e = messages.find(e => e.type === type); if (e) { cleanup(); resolve(e); } };
      notifications.push(find); find();
    });
    await once(ws, 'open'); await event('session.created'); return { ws, event, messages, closed };
  };
  return { child, exit, config, ready, wait, command, request, connect, base, material };
}
test('TLS peer uses owned material, exact credential roles/control fields and live configured readiness', async t => {
  const p = await peer(t, 'normal'), base = '/calls/' + v.caller_response.call_id;
  assert.equal((await p.request(base, p.config.caller_token)).status, 200);
  assert.equal(Object.keys(JSON.parse((await p.request(base, p.config.caller_token)).text)).length, 2);
  assert.equal((await p.request(base + '/media', p.config.caller_token, v.owner_body)).status, 403);
  assert.equal((await p.request(base + '/media', p.config.device_token, { ...v.owner_body, owner_epoch: 'stale' })).status, 400);
  const mint = await p.request(base + '/media', p.config.device_token, v.owner_body); assert.equal(mint.status, 200);
  await assert.rejects(p.connect(p.config.caller_token));
  const c = await p.connect(); assert.equal((await p.request(base + '/media-ready', p.config.device_token, v.media_ready_body)).status, 400);
  c.ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime' } })); await c.event('session.updated');
  assert.equal((await p.request(base + '/media-ready', p.config.device_token, v.media_ready_body)).status, 200);
  await p.command('close'); await c.closed; assert.ok((await p.command('counters')).counters.role_denials >= 2);
});
test('immediate actual commit ACK/transcript frames arrive while a test decorator withholds application send completion', async t => {
  const p = await peer(t, 'immediate-commit'), c = await p.connect();
  c.ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime' } })); await c.event('session.updated');
  c.ws.send(JSON.stringify({ type: 'input_audio_buffer.append', audio: Buffer.alloc(960).toString('base64') }));
  let applicationCompletion = false, release;
  // Actual socket/send unchanged; only this exposed test callback is delayed.
  const completion = new Promise(resolve => { release = () => { applicationCompletion = true; resolve(); }; });
  c.ws.send(JSON.stringify({ type: 'input_audio_buffer.commit' }), err => { assert.ifError(err); });
  await c.event('input_audio_buffer.committed'); assert.equal((await c.event('conversation.item.input_audio_transcription.completed')).transcript, 'Synthetic transcript.');
  assert.equal(applicationCompletion, false); release(); await completion;
  const { counters } = await p.command('counters'); assert.equal(counters.commit_acks, 1); assert.equal(counters.transcripts, 1);
});
for (const mode of ['ws-302','http-302']) test(`${mode} uses only its owned TLS trap and reports no bearer values`, async t => {
  const p = await peer(t, mode); assert.ok(p.ready.trap_port > 0);
  if (mode === 'http-302') {
    const r = await p.request('/calls/' + v.caller_response.call_id); assert.equal(r.status, 302); assert.ok(r.headers.location.startsWith(`https://127.0.0.1:${p.ready.trap_port}/`));
  } else await assert.rejects(p.connect());
  const { counters } = await p.command('counters'); assert.equal(counters.redirects, 1); assert.equal(counters.trap_requests, 0); assert.equal(counters.trap_authorization_present, 0);
});
test('test-supplied wrong SAN and wrong trust anchor fail real TLS before WS admission', async t => {
  const wrong = await peer(t, 'normal', root(t, 'DNS:wrong.fixture.invalid')); await assert.rejects(wrong.connect());
  assert.equal((await wrong.command('counters')).counters.ws_opened, 0);
  const p = await peer(t, 'normal'), other = root(t); await assert.rejects(p.connect(undefined, { ca: other.ca }));
  assert.equal((await p.command('counters')).counters.ws_opened, 0);
});
test('oversized text mode exercises actual client aggregate payload guard', async t => {
  const p = await peer(t, 'oversized-text');
  // Observe the real close/error rather than assuming an application parse error.
  const ws = new WebSocket(p.base.replace('https:', 'wss:') + '/floating-voice/v1/realtime?model=local-chain-m1',
    { ca: p.material.ca, headers: { Authorization: 'Bearer ' + p.config.media_token }, perMessageDeflate: false, maxPayload: 65536 });
  let failure; ws.on('error', error => { failure = error.code; });
  const code = await new Promise(resolve => ws.on('close', resolve));
  assert.equal(failure, 'WS_ERR_UNSUPPORTED_MESSAGE_LENGTH'); assert.ok([1006, 1009].includes(code));
});
for (const mode of ['idle-auto-pong','idle-no-pong']) test(`${mode}: sixteen seconds of application silence, ping control frames never become progress`, { timeout: 23000 }, async t => {
  const p = await peer(t, mode), c = await p.connect(); c.ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime' } })); await c.event('session.updated');
  const baseline = (await p.command('counters')).counters.app_events_sent;
  const timer = setInterval(() => { if (c.ws.readyState === WebSocket.OPEN) c.ws.ping(); }, 2000); t.after(() => clearInterval(timer));
  const { counters } = await p.wait('idle_elapsed'); clearInterval(timer);
  assert.ok(counters.pings_received > 0); assert.equal(counters.pongs_sent > 0, mode === 'idle-auto-pong');
  assert.equal(counters.app_events_sent, baseline); assert.equal(counters.transcripts, 0); assert.equal(counters.commit_acks, 0);
});
test('over-8KiB startup is refused before opening files or listeners', async t => {
  const child = spawn(process.execPath, [source], { env: { PATH: process.env.PATH, TMPDIR: os.tmpdir() }, stdio: ['pipe','pipe','pipe'] });
  const exited = once(child, 'close'); let output = '', errors = '';
  child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { errors += b; }); child.stdin.on('error', () => {});
  const timer = setTimeout(() => child.kill('SIGKILL'), 2000); t.after(() => clearTimeout(timer));
  child.stdin.end('x'.repeat(8193) + '\n'); assert.deepEqual(await exited, [1, null]); clearTimeout(timer);
  assert.equal(errors, ''); const event = JSON.parse(output); assert.equal(event.event, 'stopped'); assert.equal(event.counters.startup_step, 0); assert.equal(event.counters.connections, 0);
});
test('symlink private-key path in an otherwise owned synthetic root is refused without key disclosure', async t => {
  const material = root(t), real = path.join(material.dir, 'real.pem'); fs.renameSync(material.key, real); fs.symlinkSync(real, material.key);
  const child = spawn(process.execPath, [source], { env: { PATH: process.env.PATH, TMPDIR: os.tmpdir() }, stdio: ['pipe','pipe','pipe'] });
  const exited = once(child, 'close'); material.children.push({ child, exit: exited }); let output = '', errors = '';
  child.stdout.on('data', b => { output += b; }); child.stderr.on('data', b => { errors += b; }); child.stdin.on('error', () => {});
  const timer = setTimeout(() => child.kill('SIGKILL'), 2000); t.after(() => clearTimeout(timer));
  child.stdin.write(JSON.stringify({ synthetic: true, root: material.dir, cert_path: material.cert, key_path: material.key,
    device_token: 'fixture-device', caller_token: 'fixture-caller', media_token: 'fixture-media', mode: 'normal' }) + '\n');
  assert.deepEqual(await exited, [1, null]); clearTimeout(timer); assert.equal(errors, ''); assert.ok(!output.includes(material.dir));
  assert.equal(JSON.parse(output).counters.connections, 0);
});
