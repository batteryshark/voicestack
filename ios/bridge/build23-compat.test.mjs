import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { createBridge } from './server.mjs';
import { PushStore } from './push-store.mjs';
import { PushService } from './push-service.mjs';

const exec = promisify(execFile), root = fileURLToPath(new URL('../', import.meta.url));
const ref = '0618f79'; // Build 23 app/core, before any build-24 Canvas changes.
test('unmodified build-23 core works against build-24 projection, routes, push and event lifetime', { timeout: 120000 }, async () => {
  const env = { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
  const parent = path.join(root, 'output/compatibility'); await fs.mkdir(parent, { recursive: true });
  const dir = await fs.mkdtemp(path.join(parent, 'build23-'));
  const { stdout: commit } = await exec('git', ['rev-parse', ref], { cwd: root });
  const { stdout: build } = await exec('git', ['show', `${ref}:native/build.py`], { cwd: root });
  assert.match(build, /BUILD = 23/);
  const { stdout: listing } = await exec('git', ['ls-tree', '-r', '--name-only', ref, 'app/Sources/FloatingVoiceCore'], { cwd: root });
  const sources = [], hashes = {};
  for (const file of listing.trim().split('\n').filter(f => f.endsWith('.swift'))) {
    const { stdout: bytes } = await exec('git', ['show', `${ref}:${file}`], { cwd: root, encoding: 'buffer', maxBuffer: 4 * 1024 * 1024 });
    const target = path.join(dir, path.basename(file)); await fs.writeFile(target, bytes); sources.push(target);
    hashes[file] = crypto.createHash('sha256').update(bytes).digest('hex');
  }
  // UIKit itself cannot run offline on macOS. Verify its pinned wire entry points;
  // the real old transport, backend, presentation, policy/context and receipt serializers run below.
  const { stdout: coordinator } = await exec('git', ['show', `${ref}:native/PushCoordinator.swift`], { cwd: root });
  for (const token of ['/v1/push/enrollment', '/v1/push/settings', '/v1/push/events', '/v1/push/reachouts/', 'entry.body()', '"build": String(InstalledBuild.number)']) assert.ok(coordinator.includes(token), token);
  hashes['native/PushCoordinator.swift'] = crypto.createHash('sha256').update(coordinator).digest('hex');
  const { stdout: richView } = await exec('git', ['show', `${ref}:native/RichContentViews.swift`], { cwd: root });
  assert.ok(richView.includes('DisclosureGroup("Worked · " + label) {'), 'old native renderer defaults tool rows to collapsed DisclosureGroup');
  hashes['native/RichContentViews.swift'] = crypto.createHash('sha256').update(richView).digest('hex');
  await fs.writeFile(path.join(dir, 'source-manifest.json'), JSON.stringify({ commit: commit.trim(), hashes, adapter: 'test-only URLProtocol HTTPS-fixture-host → loopback HTTP; no TLS trust edits; application sources unmodified' }, null, 2));
  const binary = path.join(dir, 'client');
  await exec('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', ...sources, path.join(root, 'bridge/fixtures/build23-client.swift'), '-o', binary], { cwd: root, env, timeout: 90000, maxBuffer: 4 * 1024 * 1024 });

  const sid = 'ses_compat23', device = { deviceID: 'synthetic23', sessionID: '', generation: '', mode: 'explicit' };
  const mutations = [], receipts = [], requests = [], logs = [], apns = [], selectionModes = [], eventResponses = new Set();
  let repaired = false, seeded = false, initialHistory = false, eventConnections = 0;
  const record = { id: 'msg_canvas_fixture', type: 'assistant', content: [
    { type: 'text', text: 'Canvas created. Before learning: https://host-19.example.ts.net:9444/path. [Apple](https://apple.com/iphone) [Panel](https://opaque-viewer.fixture.invalid/#key=\nSYNTHETIC_WRAPPED_TOKEN&view=11111111-1111-4111-8111-111111111111)' },
    { type: 'tool', id: 'call_fixture', name: 'canvas_show', executed: false, state: { status: 'completed', metadata: { title: 'Synthetic panel', viewId: '11111111-1111-4111-8111-111111111111', revision: 1, truncated: false }, input: { title: 'Synthetic panel', summary: 'Synthetic only', format: 'openui', source: 'root = Stack([TextContent("DO_NOT_PROJECT_SOURCE")])' }, content: [{ type: 'text', text: 'https://opaque-viewer.fixture.invalid/#key=SYNTHETIC_VIEWER_TOKEN&view=11111111-1111-4111-8111-111111111111' }] } }
  ] };
  const dataEvent = () => 'data: ' + JSON.stringify({ type: 'fixture.projection', data: { sessionID: sid, record } }) + '\n\n';
  const skip = response => { repaired = true; response.write('data: {SYNTHETIC_MALFORMED\n\n' + dataEvent()); };
  const pushDir = path.join(dir, 'push');
  const push = new PushService({ store: new PushStore(pushDir), chief: () => sid, activeDevices: () => [device], apns: async value => { apns.push(value); return { status: 200 }; } });
  const oldEvent = push.event.bind(push); push.event = (d, obj) => { receipts.push(obj); return oldEvent(d, obj); };
  const upstream = http.createServer(async (req, res) => {
    req.on('error', () => {}); res.on('error', () => {});
    try {
      assert.equal(req.headers.authorization, undefined, 'phone credential forwarded upstream'); requests.push(req.method + ' ' + req.url);
      const send = obj => res.end(JSON.stringify(obj));
      if (req.url === '/api/system/info') return send({ runtime: 'desktop' });
      if (req.url.startsWith('/api/session?')) return send({ data: [{ id: sid, title: 'Synthetic build23', time: { updated: 1 } }] });
      if (req.url === `/api/session/${sid}`) return send({ data: { id: sid, title: 'Synthetic build23' } });
      if (req.url === '/api/session/active') return send({ data: {} });
      if (req.url.startsWith(`/api/session/${sid}/message?`)) {
        send({ data: [record, ...(repaired ? [{ id: 'msg_after_skip', type: 'user', text: 'Synthetic repair marker' }] : []), ...(eventConnections >= 2 ? [{ id: 'msg_after_rotation', type: 'user', text: 'Synthetic reconnect marker' }] : [])], cursor: {} });
        if (!initialHistory) { initialHistory = true; const timer = setTimeout(() => { for (const response of eventResponses) skip(response); }, 25); timer.unref(); }
        return;
      }
      if (req.url === '/api/event') {
        eventConnections++;
        res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.flushHeaders(); eventResponses.add(res);
        res.write('data: ' + JSON.stringify({ type: 'fixture.foreign', data: { sessionID: 'ses_other', text: 'OTHER_SESSION_SECRET' } }) + '\n\n');
        res.write(': fixture connected\n\n' + dataEvent());
        if (repaired) skip(res);
        const keepAlive = setInterval(() => res.write(': fixture upstream liveness\n\n'), 25);
        res.on('close', () => { clearInterval(keepAlive); eventResponses.delete(res); }); return;
      }
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks)); mutations.push({ method: req.method, path: req.url, body });
      if (req.url === `/api/session/${sid}/prompt`) {
        if (!seeded) {
          seeded = true;
          await push.send({ id: 'compat-ready', kind: 'ready-to-try', reason: 'build', session: sid, title: 'Synthetic update', body: 'Synthetic only', url: 'itms-services://?action=download-manifest&url=' + encodeURIComponent('https://build-fixture.ts.net/build/manifest.plist') });
          await push.send({ id: 'compat-call', kind: 'urgent-call', reason: 'decision', session: sid, title: 'Synthetic call', body: 'Never sent to a phone' });
        }
        return send({ accepted: true });
      }
      assert.equal(req.url, `/api/session/${sid}/interrupt?resume=false`); send({ interrupted: true });
    } catch { if (!res.destroyed && !res.writableEnded) { res.writeHead(503); res.end('{}'); } }
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  // Shorten only bridge event-lifetime scheduling; the old client/HTTP/parser/debounce remain unmodified.
  const clock = { setTimeout: (f, ms) => setTimeout(f, ms / 1000), clearTimeout, setInterval: (f, ms) => setInterval(f, ms / 1000), clearInterval };
  const bridge = createBridge({ credentials: { device: auth => { assert.equal(auth, 'Bearer synthetic-build23-phone'); return device; }, save() { selectionModes.push(device.mode); } }, chief: () => sid, discover: () => upstream.address().port, push, eventClock: clock, diagnostic: e => logs.push(e) });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  try {
    const { stdout, stderr } = await exec(binary, [String(bridge.address().port)], { cwd: root, env, timeout: 30000, maxBuffer: 2 * 1024 * 1024 });
    assert.match(stdout, /BUILD23_BUILD24_COMPATIBILITY_PASS/);
    assert.match(stdout, /stream=1 PASS/); assert.match(stdout, /stream=2 PASS/);
    assert.ok(logs.filter(x => x.reason === 'rotation').length >= 2);
    assert.ok(logs.some(x => x.reason === 'invalid_json'));
    assert.deepEqual(selectionModes, ['chief', 'explicit']);
    assert.deepEqual(mutations.filter(x => x.path.endsWith('/prompt')).map(x => x.body), [
      { text: 'Synthetic build23 compatibility prompt', delivery: 'queue' },
      { text: 'Synthetic build23 admission', resume: false },
      { text: 'Synthetic build23 default prompt' }
    ]);
    assert.deepEqual(mutations.find(x => x.path.includes('/interrupt')).body, {});
    assert.equal(push.device(device.deviceID).enrollment.build, '23');
    assert.deepEqual(receipts.map(x => x.event), ['notification-opened', 'reported', 'ringing', 'answered', 'ended', 'ended']);
    assert.equal(apns.length, 2, 'receipt replay must not dispatch another notification/call');
    const terminal = push.store.data.records['r:compat-call'].targets['d:synthetic23'];
    assert.equal(terminal.receipt, 'answered'); // Preserve answered truth; termination is a separate durable field.
    assert.ok(terminal.endedAt); assert.equal(terminal.terminalReceipt.event, 'ended');
    assert.equal(terminal.terminalReceipt.endReason, 'requested'); assert.equal(terminal.terminalReceipt.endInitiator, 'app');
    await fs.writeFile(path.join(parent, 'build23-build24.log'), stdout);
    await fs.writeFile(path.join(parent, 'build23-build24-result.json'), JSON.stringify({ sourceCommit: commit.trim(), manifest: path.relative(root, path.join(dir, 'source-manifest.json')), oldCoreFiles: sources.length, selectionModes, mutations, receiptEvents: receipts.map(x => x.event), fakeAPNsOnly: apns.length, rotations: logs.filter(x => x.reason === 'rotation').length, skipHints: logs.filter(x => x.reason === 'invalid_json').length, stdout, compilerRuntimeNotes: stderr }, null, 2));
  } finally { bridge.shutdown(); upstream.closeAllConnections(); await new Promise(r => upstream.close(r)); }
});
