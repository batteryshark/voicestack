import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { Worker } from 'node:worker_threads';
import child from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { deflateSync } from 'node:zlib';
import { validateBytes, readAsset, phoneProjection } from './rich-content.mjs';
import { createBridge } from './server.mjs';
import { syntheticDesktop } from './fixtures/synthetic-desktop.mjs';

function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  let crc = 0xffffffff;
  for (const byte of body) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  const length = Buffer.alloc(4), tail = Buffer.alloc(4);
  length.writeUInt32BE(data.length); tail.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, body, tail]);
}
function png({ width = 1, height = 1, interlace = 0, depth = 8, color = 2, decoded = Buffer.from([0, 1, 2, 3]), compressed = deflateSync(decoded) } = {}) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4);
  header[8] = depth; header[9] = color; header[12] = interlace;
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header), chunk('IDAT', compressed), chunk('IEND', Buffer.alloc(0))]);
}
const original = png(), replacement = png({ decoded: Buffer.from([0, 4, 5, 6]) });
const jpegHeader = (width = 1, height = 1) => {
  const bytes = Buffer.from('ffc00008080001000101', 'hex');
  bytes.writeUInt16BE(height, 5); bytes.writeUInt16BE(width, 7); return bytes;
};
const jpeg = (...segments) => Buffer.concat([Buffer.from('ffd8', 'hex'), ...segments, Buffer.from('ffd9', 'hex')]);

test('only PNG/JPEG previews: GIF, WebP, SVG and HTML fail explicit MIME and sniffing', () => {
  for (const [mime, bytes] of [
    ['image/gif', Buffer.from('GIF89a synthetic fixture')],
    ['image/webp', Buffer.from('RIFF\x10\0\0\0WEBPVP8 synthetic fixture')],
    ['image/svg+xml', Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>')],
    ['text/html', Buffer.from('<!doctype html><p>fixture</p>')],
  ]) {
    for (const declared of [mime, undefined, 'image/png', 'image/jpeg']) assert.throws(() => validateBytes(bytes, declared));
    assert.throws(() => validateBytes(original, mime), { status: 415 });
  }
  assert.equal(validateBytes(original).mime, 'image/png');
  const markdown = { type: 'assistant', content: [{ type: 'text', text: '# Native Markdown\n**normal** [link](https://example.com)\n![fixture](image.png)' }] };
  assert.deepEqual(phoneProjection(markdown), markdown);
});

test('PNG CRC, framing, bounded inflate, scanline, interlace and size gates', async t => {
  assert.equal(validateBytes(original, 'image/png').width, 1);
  const badCRC = Buffer.from(original); badCRC[29] ^= 1;
  const badLength = Buffer.from(original); badLength.writeUInt32BE(0xffffffff, 33);
  for (const [name, bytes, status] of [
    ['CRC', badCRC, 403], ['chunk length', badLength, 403],
    ['truncated', original.subarray(0, -1), 403], ['trailing bytes', Buffer.concat([original, Buffer.from('x')]), 403],
    ['invalid deflate', png({ compressed: Buffer.from('not zlib') }), 403],
    ['short inflate', png({ decoded: Buffer.from([0, 1, 2]) }), 403],
    ['excess inflate', png({ decoded: Buffer.alloc(1024 * 1024) }), 403],
    ['invalid row filter', png({ decoded: Buffer.from([5, 1, 2, 3]) }), 403],
    ['interlace', png({ interlace: 1 }), 415], ['invalid depth', png({ depth: 3 }), 403],
    ['invalid color', png({ color: 7 }), 415], ['zero width', png({ width: 0 }), 413],
    ['zero height', png({ height: 0 }), 413], ['width limit', png({ width: 8193 }), 413],
    ['height limit', png({ height: 8193 }), 413], ['pixel limit', png({ width: 5000, height: 5000 }), 413],
  ]) await t.test(name, () => assert.throws(() => validateBytes(bytes, 'image/png'), { status }));
});

test('JPEG is bounded first-SOF header screening, NOT full decoder validation', async t => {
  const sof = jpegHeader();
  assert.equal(validateBytes(jpeg(sof), 'image/jpeg').width, 1); // Intentionally no scan/entropy data.
  const app = Buffer.from('ffe000040000', 'hex');
  assert.equal(validateBytes(jpeg(app, app, sof), 'image/jpeg').width, 1);
  // Current contract stops at the first supported SOF: later headers are not validated.
  assert.equal(validateBytes(jpeg(sof, jpegHeader(9000)), 'image/jpeg').width, 1);
  for (const [name, bytes, status] of [
    ['missing EOI', jpeg(sof).subarray(0, -2), 403], ['missing SOI', jpeg(sof).subarray(2), 403],
    ['truncated segment', jpeg(Buffer.from('ffe000ff', 'hex')), 403],
    ['short segment length', jpeg(Buffer.from('ffe00001', 'hex'), sof), 403],
    ['short SOF', jpeg(Buffer.from('ffc000070800010001', 'hex')), 403],
    ['headers without SOF', jpeg(app, app), 403],
    ['SOS before SOF', jpeg(Buffer.from('ffda0002', 'hex'), sof), 403],
    ['oversize first SOF not rescued by second', jpeg(jpegHeader(9000), sof), 413],
    ...[[0, 1], [1, 0], [8193, 1], [1, 8193], [5000, 5000]].map(([w, h]) => [`dimensions ${w}x${h}`, jpeg(jpegHeader(w, h)), 413]),
  ]) await t.test(name, () => assert.throws(() => validateBytes(bytes, 'image/jpeg'), { status }));
});

test('deterministic realpath-to-helper swaps refuse final, ancestor and approved-root symlinks', async t => {
  for (const mode of ['final', 'ancestor', 'root']) await t.test(mode, () => {
    const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fv-preopen-gate-')));
    const root = path.join(base, 'approved'), outside = path.join(base, 'outside');
    fs.mkdirSync(root); fs.mkdirSync(path.join(root, 'nested')); fs.mkdirSync(outside);
    fs.writeFileSync(path.join(root, 'nested/image.png'), original);
    fs.writeFileSync(path.join(outside, 'image.png'), 'OUTSIDE SYNTHETIC SENTINEL');
    fs.mkdirSync(path.join(outside, 'nested'));
    fs.writeFileSync(path.join(outside, 'nested/image.png'), 'OUTSIDE SYNTHETIC SENTINEL');
    const spawn = child.spawnSync;
    let calls = 0;
    try {
      child.spawnSync = (...args) => {
        calls++;
        // readAsset has completed canonical authorization, but helper has not opened anything.
        const target = mode === 'final' ? path.join(root, 'nested/image.png') : mode === 'ancestor' ? path.join(root, 'nested') : root;
        fs.renameSync(target, target + '.parked');
        fs.symlinkSync(mode === 'final' ? path.join(outside, 'image.png') : outside, target);
        const result = spawn(...args);
        assert.notEqual(result.status, 0); assert.equal(result.stdout.length, 0);
        return result;
      };
      syncBuiltinESMExports();
      assert.throws(() => readAsset({ uri: 'nested/image.png' }, root), { status: 403 });
      assert.equal(calls, 1);
    } finally {
      child.spawnSync = spawn; syncBuiltinESMExports(); fs.rmSync(base, { recursive: true });
    }
  });
});

for (const mode of ['final', 'ancestor']) test(`bounded concurrent ${mode} rename/symlink swaps never return outside bytes`, { timeout: 25000 }, async t => {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fv-swap-gate-')));
  const root = path.join(base, 'approved'), outside = path.join(base, 'outside');
  fs.mkdirSync(root); fs.mkdirSync(outside); fs.mkdirSync(path.join(root, 'nested'));
  fs.writeFileSync(path.join(root, 'nested/image.png'), original);
  fs.writeFileSync(path.join(outside, 'image.png'), 'OUTSIDE SYNTHETIC SENTINEL');
  const target = path.join(root, mode === 'final' ? 'nested/image.png' : 'nested');
  const control = new Int32Array(new SharedArrayBuffer(12));
  const worker = new Worker(`
    const fs = require('node:fs');
    const { workerData, parentPort } = require('node:worker_threads');
    const { target, outside, mode, buffer } = workerData, control = new Int32Array(buffer);
    const parked = target + '.parked', deadline = Date.now() + 18000;
    let cycles = 0;
    try {
      Atomics.store(control, 0, 1); Atomics.notify(control, 0);
      while (!Atomics.load(control, 1) && Date.now() < deadline && cycles < 100000) {
        fs.renameSync(target, parked);
        fs.symlinkSync(mode === 'final' ? outside + '/image.png' : outside, target);
        fs.unlinkSync(target); fs.renameSync(parked, target);
        Atomics.add(control, 2, 1); cycles++;
      }
      parentPort.postMessage({ cycles });
    } finally {
      if (fs.existsSync(parked)) {
        try { fs.unlinkSync(target); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        fs.renameSync(parked, target);
      }
    }
  `, { eval: true, workerData: { target, outside, mode, buffer: control.buffer } });
  // Register error/exit listeners before synchronous reads block the main thread.
  const finished = new Promise((resolve, reject) => { worker.once('error', reject); worker.once('exit', code => code === 0 ? resolve() : reject(Error(`swap worker exit ${code}`))); });
  let approved = 0, refused = 0, overlapping = 0;
  try {
    if (!Atomics.load(control, 0)) Atomics.wait(control, 0, 0, 5000);
    assert.equal(Atomics.load(control, 0), 1, 'worker startup watchdog');
    const deadline = Date.now() + 15000;
    for (let iteration = 0; iteration < 40; iteration++) {
      assert.ok(Date.now() < deadline, 'stress loop watchdog');
      const before = Atomics.load(control, 2);
      let bytes;
      try { bytes = readAsset({ uri: 'nested/image.png' }, root); }
      catch (error) {
        assert.ok(error.status === 403 || ['ENOENT', 'ENOTDIR', 'ELOOP', 'EINVAL'].includes(error.code), `unexpected refusal: ${error}`);
        refused++;
      }
      if (bytes !== undefined) { assert.deepEqual(bytes, original); approved++; }
      if (Atomics.load(control, 2) > before) overlapping++;
    }
    assert.ok(overlapping > 0, 'must exercise actual overlapping swaps, not an idle worker');
    assert.equal(approved + refused, 40);
    t.diagnostic(`${mode}: ${approved} approved / ${refused} closed refusals / ${overlapping} overlapping reads / zero outside bytes`);
  } finally {
    Atomics.store(control, 1, 1);
    const watchdog = setTimeout(() => worker.terminate(), 5000);
    try { await finished; } finally { clearTimeout(watchdog); await worker.terminate(); fs.rmSync(base, { recursive: true }); }
  }
});

test('file capabilities reject replacement, changed authority and real reselection, including in-flight delivery', { timeout: 15000 }, async t => {
  const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'fv-cap-gate-')));
  const filename = path.join(directory, 'image.png'); fs.writeFileSync(filename, original);
  const device = { deviceID: 'fixture-device', sessionID: 'ses_A', generation: 'one', mode: 'explicit' };
  let release, started, hold = false, source = 'image.png';
  const arrived = new Promise(resolve => { started = resolve; });
  const barrier = new Promise(resolve => { release = resolve; });
  const fake = http.createServer(async (req, res) => {
    if (!desktop.accept(req, res)) return;
    if (req.url === '/api/system/info') res.end('{"runtime":"desktop"}');
    else if (/^\/api\/session\/ses_[AB]$/.test(req.url)) res.end(JSON.stringify({ data: { id: req.url.split('/').at(-1), location: { directory } } }));
    else if (req.url === '/api/session/ses_A/message/msg_A') {
      if (hold) { started(); await barrier; }
      res.end(JSON.stringify({ id: 'msg_A', type: 'assistant', content: [{ type: 'text', text: `![fixture](${source})` }] }));
    } else { res.writeHead(404); res.end('{}'); }
  });
  let bridge, desktop;
  try {
    fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
    desktop = syntheticDesktop(t, fake);
    bridge = createBridge({ credentials: { device: () => device, save() {} }, discover: () => fake.address().port, ocClient: desktop.ocClient });
    bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
    const base = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/`;
    const headers = generation => ({ Authorization: 'Bearer fixture', 'X-FV-Generation': generation, 'Content-Type': 'application/json' });
    const request = (route, options = {}, generation = device.generation) => fetch(base + route, { ...options, headers: headers(generation), signal: AbortSignal.timeout(5000) });
    const resolve = await request('sessions/ses_A/assets/resolve', { method: 'POST', body: JSON.stringify({ messageID: 'msg_A', reference: { kind: 'markdownImage', blockOrdinal: 0, source: 'image.png' } }) });
    assert.equal(resolve.status, 200); const { assetID } = await resolve.json(); assert.ok(assetID);
    const route = `sessions/ses_A/assets/${assetID}`;
    const first = await request(route); assert.equal(first.status, 200); assert.deepEqual(Buffer.from(await first.arrayBuffer()), original);
    fs.writeFileSync(path.join(directory, 'replacement.png'), replacement);
    fs.renameSync(path.join(directory, 'replacement.png'), filename);
    const changed = await request(route); assert.equal(changed.status, 409);
    assert.ok(!Buffer.from(await changed.arrayBuffer()).includes(replacement), 'refusal must not contain changed image bytes');
    fs.writeFileSync(filename, original);
    source = 'other.png'; assert.equal((await request(route)).status, 403); source = 'image.png';
    hold = true;
    const pending = request(route, {}, 'one');
    // The request's independent five-second watchdog also bounds barrier arrival.
    await Promise.race([arrived, pending.then(() => assert.fail('delivery completed before barrier'))]);
    const select = sid => request('selection', { method: 'POST', body: JSON.stringify({ sessionID: sid, mode: 'explicit' }) });
    const away = await select('ses_B'); assert.equal(away.status, 200);
    const back = await select('ses_A'); assert.equal(back.status, 200); assert.notEqual(device.generation, 'one');
    release(); hold = false;
    const stale = await pending; assert.equal(stale.status, 409);
    assert.ok(!Buffer.from(await stale.arrayBuffer()).includes(original), 'stale lease must not receive image bytes');
    assert.equal((await request(route, {}, 'one')).status, 409);
    assert.equal((await request(route)).status, 409); // Fresh lease does not revive the old capability.
  } finally {
    release(); bridge?.shutdown(); fake.closeAllConnections(); await new Promise(resolve => fake.close(resolve));
    fs.rmSync(directory, { recursive: true });
  }
});
