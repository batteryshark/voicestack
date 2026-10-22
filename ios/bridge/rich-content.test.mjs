import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { deflateSync } from 'node:zlib';
import child from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { Capabilities, validateBytes, assetDescription, base64, exactReference, readAsset, canvasAssociation, byteRange, phoneProjection } from './rich-content.mjs';
import { createBridge } from './server.mjs';
import { syntheticDesktop } from './fixtures/synthetic-desktop.mjs';

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGPwWPEBAAMcAeFR2BKRAAAAAElFTkSuQmCC', 'base64');
function tinyPDF() {
  let text = '%PDF-1.4\n'; const offsets = [0];
  for (const [index, object] of ['<</Type /Catalog /Pages 2 0 R>>', '<</Type /Pages /Kids [3 0 R] /Count 1>>', '<</Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources <<>>>>'].entries()) {
    offsets.push(Buffer.byteLength(text)); text += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = Buffer.byteLength(text);
  text += 'xref\n0 4\n0000000000 65535 f \n' + offsets.slice(1).map(n => `${String(n).padStart(10, '0')} 00000 n \n`).join('');
  return Buffer.from(text + `trailer\n<</Size 4 /Root 1 0 R>>\nstartxref\n${xref}\n%%EOF\n`);
}
const pdf = tinyPDF();
test('synthetic paired fixture client uses only its explicit binding and owned loopback server', async t => {
  const fake = http.createServer((req, res) => { desktop.accept(req, res); });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const desktop = syntheticDesktop(t, fake);
  const originalRequest = http.request;
  const requests = [];
  t.mock.method(http, 'request', function (options, ...args) {
    assert.equal(options.hostname ?? options.host, '127.0.0.1', 'no external hostname or DNS request');
    assert.equal(Number(options.port), fake.address().port, 'no service outside the owned listener');
    requests.push(options.path);
    return originalRequest.call(this, options, ...args);
  });
  try {
    assert.ok(desktop.ocClient.file.startsWith(path.join(os.tmpdir(), 'fv-synthetic-desktop-')));
    assert.equal(desktop.ocClient.file, desktop.file);
    const context = await desktop.ocClient.prepare(fake.address().port);
    assert.deepEqual(context, { port: fake.address().port, paired: true, headers: { Authorization: 'Bearer oc_client_SYNTHETIC_RICH_FIXTURE' } });
    assert.deepEqual(requests, ['/health']);
    assert.deepEqual(desktop.requests, ['/health']);
    assert.throws(() => desktop.ocClient.prepare(0), /only the owned fixture listener/);
    assert.deepEqual(requests, ['/health'], 'wrong targets are rejected before any request');
  } finally { t.mock.restoreAll(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});
test('history and live projection strip viewer capabilities while preserving unknown fields', () => {
  const raw = { future: { keep: true }, viewerKey: 'SECRET', tool: JSON.stringify({ browserUrl: 'https://canvas.invalid/#key=SECRET&view=panel' }), text: '[panel](https://canvas.invalid/#key=SECRET&view=panel)' };
  const projected = phoneProjection(raw);
  assert.ok(!JSON.stringify(projected).includes('SECRET')); assert.equal(projected.future.keep, true); assert.equal(raw.viewerKey, 'SECRET');
});
test('bounded signatures, MIME, base64 and decoded dimensions', () => {
  assert.equal(validateBytes(png, 'image/png').width, 1);
  assert.throws(() => validateBytes(pdf, 'application/pdf'), { status: 415 });
  for (const value of ['AA=', '%%%=', 'AA==\n', '', 'a'.repeat(12000000)]) assert.throws(() => validateBytes(base64(value), 'image/png'));
  for (const mime of ['image/svg+xml', 'text/html', 'application/octet-stream']) assert.throws(() => validateBytes(png, mime));
  const enormous = Buffer.from(png); enormous.writeUInt32BE(100000, 16); assert.throws(() => validateBytes(enormous, 'image/png'));
  assert.throws(() => validateBytes(Buffer.alloc(9 * 1024 * 1024), 'image/png'));
  assert.throws(() => validateBytes(Buffer.alloc(9 * 1024 * 1024), 'image/jpeg'), { status: 413 });
  // SOF dimension parsing must reject both per-axis and total decoded pixel limits.
  for (const [width, height] of [[8193, 1], [1, 8193], [5000, 5000]]) {
    const jpeg = Buffer.from('ffd8ffc00008080001000101ffd9', 'hex');
    jpeg.writeUInt16BE(height, 7); jpeg.writeUInt16BE(width, 9);
    assert.throws(() => validateBytes(jpeg, 'image/jpeg'), { status: 413 });
  }
  for (const [width, height] of [[8193, 1], [1, 8193], [5000, 5000]]) {
    const oversized = Buffer.from(png); oversized.writeUInt32BE(width, 16); oversized.writeUInt32BE(height, 20);
    assert.throws(() => validateBytes(oversized, 'image/png'), { status: 413 });
  }
});
test('review regression: compressed PDF bomb is never an inline preview or byte capability', async t => {
  const decodedLength = 128 * 1024 * 1024, compressed = deflateSync(Buffer.alloc(decodedLength, 32));
  const bomb = Buffer.concat([Buffer.from(`%PDF-1.4\n1 0 obj << /Length ${compressed.length} /Filter /FlateDecode >>\nstream\n`), compressed, Buffer.from('\nendstream\nendobj\n%%EOF')]);
  assert.ok(bomb.length < 140000);
  assert.throws(() => validateBytes(bomb, 'application/pdf'), { status: 415 });
  assert.deepEqual(assetDescription({ mime: 'application/pdf', name: 'untrusted.pdf' }, bomb), { mime: 'application/pdf', name: 'untrusted.pdf', length: bomb.length, preview: false });
  const fake = http.createServer((req, res) => {
    if (!desktop.accept(req, res)) return;
    if (req.url === '/api/system/info') res.end('{"runtime":"desktop"}');
    else if (req.url === '/api/session/ses_A') res.end(JSON.stringify({ data: { id: 'ses_A', location: { directory: '/fixture' } } }));
    else if (req.url === '/api/session/ses_A/message/msg_A') res.end(JSON.stringify({ data: { id: 'msg_A', type: 'user', files: [{ name: 'untrusted.pdf', mime: 'application/pdf', data: bomb.toString('base64') }] } }));
    else { res.writeHead(404); res.end('{}'); }
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const desktop = syntheticDesktop(t, fake);
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'device', sessionID: 'ses_A', generation: 'one', mode: 'explicit' }) }, discover: () => fake.address().port, ocClient: desktop.ocClient });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const url = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_A/assets/`;
  const headers = { Authorization: 'Bearer fixture', 'X-FV-Generation': 'one', 'Content-Type': 'application/json' };
  try {
    const response = await fetch(url + 'resolve', { method: 'POST', headers, body: JSON.stringify({ messageID: 'msg_A', reference: { kind: 'userFile', blockOrdinal: 0 } }) });
    assert.equal(response.status, 200);
    const card = await response.json(); assert.deepEqual(card, { mime: 'application/pdf', name: 'untrusted.pdf', length: bomb.length, preview: false });
    assert.equal(card.assetID, undefined); assert.equal(card.data, undefined);
    assert.equal((await fetch(url + 'untrusted', { headers })).status, 409);
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});
test('review regression: Python helper uses isolated mode, list arguments and bounded minimal environment', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-python-isolation-'));
  const original = child.spawnSync;
  try {
    fs.writeFileSync(path.join(root, 'tiny.png'), png);
    let calls = 0;
    child.spawnSync = (executable, args, options) => {
      calls++; assert.equal(executable, '/usr/bin/python3'); assert.equal(args[0], '-I');
      assert.equal(args.length, 4); assert.ok(args[1].endsWith('/bridge/read-asset.py'));
      assert.equal(args[2], fs.realpathSync(root)); assert.equal(args[3], 'tiny.png');
      assert.equal(options.timeout, 5000); assert.equal(options.maxBuffer, 8 * 1024 * 1024 + 65536);
      assert.deepEqual(options.env, { PATH: '/usr/bin:/bin' }); assert.ok(!options.shell);
      return original(executable, args, options);
    };
    syncBuiltinESMExports();
    assert.deepEqual(readAsset({ uri: 'tiny.png' }, root), png); assert.equal(calls, 1);
  } finally { child.spawnSync = original; syncBuiltinESMExports(); fs.rmSync(root, { recursive: true }); }
});
test('reference authority and no external fetching, traversal, symlink or outside root', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-rich-'));
  try {
    fs.writeFileSync(path.join(root, 'tiny.png'), png);
    fs.symlinkSync(path.join(root, 'tiny.png'), path.join(root, 'link.png'));
    fs.symlinkSync(root, path.join(root, 'linked-directory'));
    assert.deepEqual(readAsset({ uri: 'tiny.png' }, root), png);
    for (const uri of ['link.png', 'linked-directory/tiny.png', '../outside.png', 'https://example.com/tiny.png', '/etc/hosts']) assert.throws(() => readAsset({ uri }, root));
    const record = { type: 'user', files: [{ data: png.toString('base64'), mime: 'image/png', source: { type: 'uri', uri: '/etc/hosts' } }] };
    assert.deepEqual(readAsset(exactReference(record, { kind: 'userFile', blockOrdinal: 0 }), root), png);
    assert.throws(() => exactReference(record, { kind: 'toolFile', blockOrdinal: 0 }));
    assert.throws(() => exactReference(record, { kind: 'userFile', blockOrdinal: 1 }));
    const markdown = { type: 'assistant', content: [{ type: 'text', text: '![tiny](tiny.png)\n```\n![secret](/etc/hosts)\n```' }] };
    assert.equal(exactReference(markdown, { kind: 'markdownImage', blockOrdinal: 0, source: 'tiny.png' }).uri, 'tiny.png');
    assert.throws(() => exactReference(markdown, { kind: 'markdownImage', blockOrdinal: 0, source: '/etc/hosts' }));
  } finally { fs.rmSync(root, { recursive: true }); }
});
test('capabilities bind device/session/generation, expire and ranges are bounded', () => {
  let now = 1; const caps = new Capabilities(() => now), binding = { device: 'a', sid: 'A', generation: 'one' };
  const id = caps.grant(binding, { message: 'm', ref: 0 });
  const form = caps.grant(binding, { message: 'form' }, 4 * 60 * 60 * 1000);
  for (const change of [{ device: 'b' }, { sid: 'B' }, { generation: 'two' }]) assert.throws(() => caps.get(id, { ...binding, ...change }));
  assert.equal(caps.get(id, binding).message, 'm'); now += 60001; assert.throws(() => caps.get(id, binding));
  assert.equal(caps.get(form, binding).message, 'form');
  assert.deepEqual(byteRange('bytes=0-2', 8), [0, 2]);
  for (const value of ['bytes=0-8', 'bytes=-1', 'bytes=5-2', 'bytes=0-1,3-4']) assert.throws(() => byteRange(value, 8));
});
test('synthetic Canvas tool association only, never arbitrary content or pinned views', () => {
  const record = { type: 'assistant', content: [{ type: 'tool', name: 'canvas_present', id: 'tool', state: { status: 'completed', content: [{ type: 'text', text: JSON.stringify({ id: 'panel', revision: 2, browserUrl: 'https://privileged.invalid/#key=secret' }) }] } }] };
  assert.deepEqual(canvasAssociation(record, 0), { artifactID: 'panel', revision: 2, toolID: 'tool' });
  assert.throws(() => canvasAssociation(record, 1));
  record.content[0].name = 'webfetch'; assert.throws(() => canvasAssociation(record, 0));
});
test('HTTP assets revalidate message and lease on delivery, never forward phone credentials', async t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-rich-http-'));
  let generation = 'one', changed = false;
  const fake = http.createServer((req, res) => {
    if (!desktop.accept(req, res)) return;
    if (req.url === '/api/system/info') res.end(JSON.stringify({ runtime: 'desktop' }));
    else if (req.url === '/api/session/ses_A') res.end(JSON.stringify({ data: { id: 'ses_A', location: { directory } } }));
    else if (req.url === '/api/session/ses_A/message/msg_A') res.end(JSON.stringify({ id: 'msg_A', type: 'user', files: [{ mime: 'image/png', data: changed ? pdf.toString('base64') : png.toString('base64') }] }));
    else { res.writeHead(404); res.end('{}'); }
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const desktop = syntheticDesktop(t, fake);
  const bridge = createBridge({ credentials: { device: auth => { if (auth !== 'Bearer fixture') throw Object.assign(Error(), { status: 401 }); return { deviceID: 'device', sessionID: 'ses_A', generation, mode: 'explicit' }; } }, discover: () => fake.address().port, ocClient: desktop.ocClient });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const base = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_A/assets/`;
  const headers = { Authorization: 'Bearer fixture', 'X-FV-Generation': 'one', 'Content-Type': 'application/json' };
  try {
    const resolve = await fetch(base + 'resolve', { method: 'POST', headers, body: JSON.stringify({ messageID: 'msg_A', reference: { kind: 'userFile', blockOrdinal: 0 } }) });
    assert.equal(resolve.status, 200); const { assetID } = await resolve.json();
    const delivered = await fetch(base + assetID, { headers: { ...headers, Range: 'bytes=0-7' } }); assert.equal(delivered.status, 206); assert.equal((await delivered.arrayBuffer()).byteLength, 8);
    changed = true; assert.equal((await fetch(base + assetID, { headers })).status, 403); changed = false;
    generation = 'two'; assert.equal((await fetch(base + assetID, { headers })).status, 409);
    generation = 'three'; assert.equal((await fetch(base + assetID, { headers: { ...headers, 'X-FV-Generation': 'three' } })).status, 409);
    assert.equal((await fetch(base + assetID)).status, 401);
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); fs.rmSync(directory, { recursive: true }); }
});

test('Canvas broker binds UUID to message/block/tool origin, filters history and retains uncertain delivery', async t => {
  let generation = 'one', latest = 1, sessionKey = 'sessionA', uncertain = false, dispatches = 0, interactions = [], toolID = 'toolA';
  const document = { title: 'Fixture', diagram: { nodes: [{ id: 'a', label: 'A', detail: '' }, { id: 'b', label: 'B', detail: '' }], edges: [{ from: 'a', to: 'b', label: 'next' }] }, sections: [], choices: [{ id: 'go', label: 'Go', description: 'Fixture only', prompt: 'Never sent to a real session' }] };
  const fake = http.createServer(async (req, res) => {
    if (!desktop.accept(req, res)) return;
    if (req.url === '/api/system/info') { res.end(JSON.stringify({ runtime: 'desktop' })); return; }
    if (req.url === '/api/session/ses_A') { res.end(JSON.stringify({ data: { id: 'ses_A', location: { directory: '/fixture' } } })); return; }
    if (/^\/api\/session\/ses_A\/message\/msg_[AB]$/.test(req.url)) {
      const id = req.url.split('/').at(-1);
      const tool = { type: 'tool', name: 'canvas_present', id: toolID, state: { status: 'completed', content: [{ type: 'text', text: JSON.stringify({ id: 'artifactA', revision: 1, browserUrl: 'https://canvas.invalid/#key=NEVER_RETURN' }) }] } };
      res.end(JSON.stringify({ id, type: 'assistant', content: [tool, tool] })); return;
    }
    assert.equal(req.url, '/api/guests/agent-canvas/service/request');
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    const outer = JSON.parse(Buffer.concat(chunks)), inner = JSON.parse(outer.body);
    assert.equal(outer.method, 'POST');
    let result;
    if (outer.path === '/connect') { assert.deepEqual(inner, { directory: '/fixture', sessionId: 'ses_A' }); result = { key: 'NEVER_RETURN' }; }
    else {
      assert.equal(inner.key, 'NEVER_RETURN');
      if (inner.path === '/api/snapshot') result = { session: { key: 'sessionA', sessionId: 'ses_A', directory: '/fixture' }, views: [{ id: 'artifactA', latest }, { id: 'pinnedOther', latest: 10, revision: { document: { secret: true } } }], interactions };
      else if (inner.path === '/api/revision?id=artifactA&revision=1') result = { sessionKey, number: 1, document };
      else if (inner.path === '/api/submit') {
        dispatches++; assert.equal(inner.body.sessionKey, 'sessionA'); assert.equal(inner.body.artifactId, 'artifactA'); assert.equal(inner.body.revision, 1);
        if (uncertain) { req.socket.destroy(); return; }
        result = { status: 'queued', detail: 'Fixture queue' };
      } else if (inner.path === '/api/retry') { dispatches++; result = { status: 'queued', detail: 'Fixture retry' }; }
      else { assert.fail('untyped Canvas operation'); }
    }
    res.end(JSON.stringify({ status: 200, body: JSON.stringify(result) }));
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const desktop = syntheticDesktop(t, fake);
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'deviceA', sessionID: 'ses_A', generation, mode: 'explicit' }) }, discover: () => fake.address().port, ocClient: desktop.ocClient });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const base = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_A/canvas/`;
  const call = (action, body, gen = generation) => fetch(base + action, { method: 'POST', headers: { Authorization: 'Bearer fixture', 'X-FV-Generation': gen, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  try {
    const response = await call('resolve', { messageID: 'msg_A', blockOrdinal: 0 }); assert.equal(response.status, 200);
    const text = await response.text(); assert.ok(!text.includes('NEVER_RETURN') && !text.includes('pinnedOther'));
    const panel = JSON.parse(text); assert.equal(panel.document.diagram.edges[0].to, 'b');
    sessionKey = 'sessionOther'; assert.equal((await call('resolve', { messageID: 'msg_A', blockOrdinal: 0 })).status, 403); sessionKey = 'sessionA';
    assert.equal((await call('resolve', { messageID: 'msg_A', blockOrdinal: 4 })).status, 403);
    const submission = { panelID: panel.panelID, id: '00000000-0000-4000-8000-000000000001', choiceID: 'go' };
    assert.equal((await call('submit', { ...submission, action: 'Go', data: null })).status, 400);
    latest = 2; assert.equal((await call('submit', submission)).status, 409); assert.equal(dispatches, 0); latest = 1;
    assert.equal((await (await call('submit', submission)).json()).status, 'queued');
    assert.equal((await (await call('submit', submission)).json()).status, 'queued'); assert.equal(dispatches, 1);
    // Same artifact/revision/choice/device/lease, different authoritative origins: 409.
    // Deliberately keep tool IDs equal to independently exercise message and ordinal identity.
    for (const origin of [{ messageID: 'msg_B', blockOrdinal: 0 }, { messageID: 'msg_A', blockOrdinal: 1 }]) {
      const other = await (await call('resolve', origin)).json();
      for (const action of ['submit', 'retry', 'status']) assert.equal((await call(action, { ...submission, panelID: other.panelID })).status, 409);
    }
    toolID = 'changedTool';
    const changedToolPanel = await (await call('resolve', { messageID: 'msg_A', blockOrdinal: 0 })).json();
    assert.equal((await call('submit', { ...submission, panelID: changedToolPanel.panelID })).status, 409);
    toolID = 'toolA';
    const sameOrigin = await (await call('resolve', { messageID: 'msg_A', blockOrdinal: 0 })).json();
    assert.equal((await call('submit', { ...submission, panelID: sameOrigin.panelID })).status, 200); assert.equal(dispatches, 1);
    assert.equal((await call('submit', { ...submission, notes: 'conflict' })).status, 409);
    assert.equal((await call('retry', submission)).status, 409);
    uncertain = true; const ambiguous = { ...submission, id: '00000000-0000-4000-8000-000000000002' };
    assert.equal((await (await call('submit', ambiguous)).json()).status, 'uncertain');
    assert.equal((await (await call('submit', ambiguous)).json()).status, 'uncertain'); assert.equal(dispatches, 2);
    assert.equal((await call('retry', ambiguous)).status, 409);
    interactions = [{ id: submission.id, artifactId: 'artifactA', revision: 1, choiceId: 'go', status: 'unsent', detail: 'Confirmed not delivered' }];
    assert.equal((await (await call('status', submission)).json()).status, 'unsent');
    assert.equal((await (await call('retry', submission)).json()).status, 'queued'); assert.equal(dispatches, 3);
    generation = 'B'; assert.equal((await call('submit', submission, 'one')).status, 409);
    generation = 'Aagain'; assert.equal((await call('submit', submission)).status, 409);
    assert.equal((await call('pin', {})).status, 404);
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});

test('cancelled rich-asset authority lookup closes upstream before any capability delivery', async t => {
  let signalStart, signalClose;
  const started = new Promise(r => { signalStart = r; }), closed = new Promise(r => { signalClose = r; });
  const fake = http.createServer((req, res) => {
    if (!desktop.accept(req, res)) return;
    if (req.url === '/api/system/info') { res.end('{"runtime":"desktop"}'); return; }
    res.on('close', signalClose); res.writeHead(200); res.write('{'); signalStart();
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const desktop = syntheticDesktop(t, fake);
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'device', sessionID: 'ses_A', generation: 'one', mode: 'explicit' }) }, discover: () => fake.address().port, ocClient: desktop.ocClient });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const controller = new AbortController();
  try {
    const request = fetch(`http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_A/assets/resolve`, { signal: controller.signal, method: 'POST', headers: { Authorization: 'Bearer fixture', 'X-FV-Generation': 'one', 'Content-Type': 'application/json' }, body: JSON.stringify({ messageID: 'msg_A', reference: { kind: 'userFile', blockOrdinal: 0 } }) });
    const rejection = assert.rejects(request);
    await started; controller.abort(); await rejection; await closed;
    assert.ok(bridge.workStats().peakUpstreams <= 1);
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});
