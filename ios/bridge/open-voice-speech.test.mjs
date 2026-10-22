import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { WebSocketServer } from 'ws';
import { createLocalSpeechAdapter, SPEECH_BOUNDS } from './open-voice-speech.mjs';
import { PCMResampler } from './open-voice-pcm.mjs';

const audio = n => { const b = Buffer.alloc(n * 2); for (let i = 0; i < n; i++) b.writeInt16LE(Math.round(9000 * Math.sin(i / 7)), i * 2); return b; };
const expected = (input, from, to) => { const c = new PCMResampler(from, to); return Buffer.concat([...c.push(input), ...c.finish()]); };
const strict = { 'content-type': 'audio/pcm', 'x-sample-format': 's16le', 'x-sample-rate': '24000', 'x-channels': '1' };
async function fixture(t, { ws, handle, upgrade } = {}) {
  const sockets = new Set(), peers = new Set(), requests = [];
  const server = http.createServer((req, res) => { requests.push(req.url); if (handle) handle(req, res); else { res.writeHead(404); res.end(); } });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  server.on('upgrade', (req, socket, head) => {
    requests.push(req.url); if (upgrade) { upgrade(req, socket); return; }
    wss.handleUpgrade(req, socket, head, peer => { peers.add(peer); peer.on('error', () => {}); peer.on('close', () => peers.delete(peer)); ws?.(peer, req); });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    const closing = [...sockets].map(s => new Promise(resolve => { s.once('close', resolve); s.destroy(); }));
    for (const p of peers) p.terminate();
    await Promise.all([...closing, new Promise(resolve => server.close(resolve)), new Promise(resolve => wss.close(resolve))]);
    assert.equal(sockets.size, 0); assert.equal(peers.size, 0);
  });
  const base = `127.0.0.1:${server.address().port}`;
  return { requests, ttsURL: `http://${base}/v1/audio/speech`, make: (options = {}) => createLocalSpeechAdapter({ sttURL: `ws://${base}/v1/transcribe`, ttsURL: `http://${base}/v1/audio/speech`, model: 'synthetic', voice: 'synthetic', idleMs: 300, lifetimeMs: 3000, ...options }) };
}
async function collect(iterator) {
  const chunks = []; for await (const b of iterator) { assert.ok(b.length > 0 && b.length % 2 === 0 && b.length <= 4800 && b.buffer.byteLength <= 4800); chunks.push(b); }
  return Buffer.concat(chunks);
}
const assertIdle = a => assert.deepEqual(a.stats(), { stt: 0, tts: 0 });

test('STT exact public warming constant retains only numeric peer reason', async t => {
  const f = await fixture(t, { ws(peer) {
    peer.on('message', (_, binary) => {
      if (binary) { peer.send('{"type":"error","message":"speech recognition is warming"}'); peer.close(1013); }
    });
  } });
  const a = f.make(), records = [];
  const segment = await a.openSegment({ onTerminal: row => records.push(row) });
  await segment.write(audio(480)); await segment.closed.promise;
  await assert.rejects(segment.finish()); await segment.close(); assertIdle(a);
  assert.equal(records.length, 1); assert.equal(records[0].cause, 6); assert.equal(records[0].peerReason, 2);
  assert.equal(records[0].endSent, 0); assert.ok([1006, 1013].includes(records[0].closeCode));
  assert.equal(records[0].inputBytes, 960);
  assert.equal(JSON.stringify(records).includes('speech recognition is warming'), false);
});

test('actual STT WS converts 24 to 16, appends stable deltas, replaces/discards partial hypotheses', { timeout: 5000 }, async t => {
  const received = [], input = audio(2400);
  const f = await fixture(t, { ws(peer, req) {
    assert.equal(req.url, '/v1/transcribe?partials=1'); assert.equal(req.headers['sec-websocket-extensions'], undefined);
    peer.on('message', (data, binary) => {
      if (binary) received.push(data);
      else {
        assert.deepEqual(JSON.parse(data), { type: 'input_audio.end' });
        for (const e of [{ type: 'transcript.partial', text: 'wrong' }, { type: 'transcript.partial', text: 'replacement' },
          { type: 'transcript', text: ' hello' }, { type: 'transcript', text: ' world ' }, { type: 'transcript.partial', text: 'never final' }]) peer.send(JSON.stringify(e));
        peer.close(1000);
      }
    });
  } });
  const a = f.make(), s = await a.openSegment();
  for (let i = 0; i < input.length; i += 958) await s.write(input.subarray(i, i + 958));
  assert.deepEqual(await s.finish(), { normal: true, transcript: 'hello world' });
  assert.deepEqual(Buffer.concat(received), expected(input, 24000, 16000));
  await s.close(); assertIdle(a); assert.equal(a.readyForCalls, false); assert.throws(() => a.submit({}), /harness_unconfigured/);
});
test('STT explicit end plus normal close is successful even with empty stable text', async t => {
  const f = await fixture(t, { ws: p => p.on('message', (_, binary) => { if (!binary) p.close(1000); }) });
  const a = f.make(), s = await a.openSegment(); await s.write(audio(480));
  assert.deepEqual(await s.finish(), { normal: true, transcript: '' }); await s.close(); assertIdle(a);
});
test('STT abnormal/early/oversized/malformed/binary close is never successful', async t => {
  for (const mode of ['abnormal', 'early', 'oversized', 'malformed', 'binary', 'unknown', 'overflow']) {
    await t.test(mode, async t => {
      const f = await fixture(t, { ws(p) {
        if (mode === 'early') p.close(1000);
        p.on('message', (_, binary) => {
          if (binary) return;
          if (mode === 'abnormal') p.close(1011);
          else if (mode === 'oversized') p.send('x'.repeat(SPEECH_BOUNDS.wsPayloadBytes + 1));
          else if (mode === 'malformed') p.send('{');
          else if (mode === 'binary') p.send(Buffer.from('{}'));
          else if (mode === 'unknown') p.send('{"type":"error","text":"bad"}');
          else if (mode === 'overflow') for (let i = 0; i < 3; i++) p.send(JSON.stringify({ type: 'transcript', text: 'x'.repeat(3000) }));
        });
      } });
      const a = f.make(); let s;
      await assert.rejects(async () => { s = await a.openSegment(); if (mode === 'early') await s.closed.promise; await s.finish(); });
      await s?.close(); assertIdle(a);
    });
  }
});
test('STT bounds concurrent writes, frame bytes, capacity and timeout; abort closes late handshake', async t => {
  await t.test('write bounds and same slot retained until close', async t => {
    const f = await fixture(t, { ws() {} }), a = f.make(); const s = await a.openSegment();
    await assert.rejects(a.openSegment(), /speech_capacity/);
    const pending = s.write(audio(2400)); await assert.rejects(s.write(audio(480))); await pending;
    await assert.rejects(s.write(Buffer.alloc(4802))); await s.close(); assertIdle(a);
    const successor = await a.openSegment(); await assert.rejects(successor.finish()); await successor.close(); assertIdle(a);
  });
  await t.test('abort connecting and no leaked late resource', async t => {
    let resolve; const seen = new Promise(r => resolve = r);
    const f = await fixture(t, { upgrade() { resolve(); } }), a = f.make(), abort = new AbortController();
    const pending = a.openSegment({ signal: abort.signal }); await seen; abort.abort();
    await assert.rejects(pending); assertIdle(a);
  });
});
test('actual TTS HTTP checks request schema, streams odd chunks and statefully converts all supported rates', async t => {
  for (const rate of [16000, 22050, 24000, 44100, 48000]) await t.test(String(rate), async t => {
    const raw = audio(2399), bodies = [];
    const f = await fixture(t, { handle(req, res) {
      const chunks = []; req.on('data', b => chunks.push(b)); req.on('end', () => {
        bodies.push(JSON.parse(Buffer.concat(chunks))); res.writeHead(200, { ...strict, 'x-sample-rate': String(rate) });
        res.write(raw.subarray(0, 1)); setImmediate(() => { res.write(raw.subarray(1, 2002)); setImmediate(() => res.end(raw.subarray(2002))); });
      });
    } });
    const a = f.make(), result = await collect(a.synthesize({ text: '**Hello** 🙂.' }));
    assert.deepEqual(result, expected(raw, rate, 24000));
    assert.deepEqual(bodies, [{ model: 'synthetic', voice: 'synthetic', input: 'Hello 🙂.', response_format: 'pcm' }]);
    assert.deepEqual(f.requests, ['/v1/audio/speech']); assertIdle(a);
    assert.ok(a.bufferStats().receiveChunkBytes > 0 && a.bufferStats().receiveChunkBytes <= 8192);
    assert.ok(a.bufferStats().httpBufferedBytes <= 16384);
  });
});
test('TTS rejects missing/ambiguous/wrong actual format/rate/channels, redirects and incomplete samples', async t => {
  const cases = [
    ['rate absent', { 'x-sample-rate': undefined }], ['rate invalid', { 'x-sample-rate': '24000junk' }],
    ['format absent', { 'x-sample-format': undefined }], ['wrong format', { 'x-sample-format': 'f32le' }],
    ['channels absent', { 'x-channels': undefined }], ['stereo', { 'x-channels': '2' }],
    ['wrong content type', { 'content-type': 'audio/wav' }], ['encoded', { 'content-encoding': 'gzip' }],
    ['duplicate', { 'x-sample-rate': ['24000', '24000'] }], ['redirect', { location: 'http://127.0.0.1:1/no' }, 302],
    ['odd end', {}, 200, Buffer.from([1])],
  ];
  for (const [name, replace, status = 200, body = audio(10)] of cases) await t.test(name, async t => {
    const f = await fixture(t, { handle(req, res) {
      req.resume(); const h = { ...strict, ...replace }; for (const k of Object.keys(h)) if (h[k] === undefined) delete h[k];
      res.writeHead(status, h); res.end(body);
    } });
    const a = f.make(); await assert.rejects(collect(a.synthesize({ text: 'synthetic' }))); assertIdle(a); assert.equal(f.requests.length, 1);
  });
});
test('TTS abort and iterator.return interrupt blocked read and delayed allocation, retaining capacity until cleanup', async t => {
  for (const mode of ['headers-pending', 'read-pending', 'return']) await t.test(mode, async t => {
    let resolve; const seen = new Promise(r => resolve = r);
    const f = await fixture(t, { handle(req, res) { req.resume(); if (mode !== 'headers-pending') { res.writeHead(200, strict); res.flushHeaders(); } resolve(); } });
    const a = f.make(), abort = new AbortController(), iterator = a.synthesize({ text: 'x'.repeat(300), signal: abort.signal });
    const next = iterator.next(); await seen;
    assert.throws(() => a.synthesize({ text: 'ninth' }), /speech_capacity/);
    if (mode === 'return') await iterator.return(); else abort.abort();
    await assert.rejects(next); await iterator.return(); assertIdle(a); assert.equal(f.requests.length, 1);
    const lateAbort = new AbortController(), late = a.synthesize({ text: 'test', signal: lateAbort.signal });
    lateAbort.abort(); await late.return(); assertIdle(a); assert.deepEqual(await late.next(), { done: true });
  });
});
test('missing channels needs exact owner-pinned mono profile; contradictory or unknown channel metadata always fails', async t => {
  for (const mode of ['mono', 'contradiction', 'unknown', 'no-rate']) await t.test(mode, async t => {
    const f = await fixture(t, { handle(req, res) {
      req.resume(); const h = { ...strict }; delete h['x-channels'];
      if (mode === 'contradiction') h['x-channels'] = '2';
      if (mode === 'unknown') h['x-audio-channels'] = '1';
      if (mode === 'no-rate') delete h['x-sample-rate'];
      res.writeHead(200, h); res.end(audio(10));
    } });
    assert.throws(() => f.make({ monoProfile: true }));
    assert.throws(() => f.make({ monoProfile: { contract: 'speechd-mono-s16le-v1', endpoint: f.ttsURL + '/wrong' } }));
    const a = f.make({ monoProfile: { contract: 'speechd-mono-s16le-v1', endpoint: f.ttsURL } });
    if (mode === 'mono') assert.deepEqual(await collect(a.synthesize({ text: 'test' })), audio(10));
    else await assert.rejects(collect(a.synthesize({ text: 'test' })));
    assertIdle(a);
  });
});
test('immediate return during HTTP allocation closes even before socket assignment; no late request reuse', async t => {
  const f = await fixture(t), a = f.make(), i = a.synthesize({ text: 'test' });
  const next = i.next(); await i.return(); await assert.rejects(next); assertIdle(a);
  assert.ok(f.requests.length <= 1);
});
test('TTS final speech segments make serial bounded requests with independent PCM stream boundaries', async t => {
  const inputs = [];
  const f = await fixture(t, { handle(req, res) {
    const chunks = []; req.on('data', b => chunks.push(b)); req.on('end', () => {
      inputs.push(JSON.parse(Buffer.concat(chunks)).input);
      res.writeHead(200, { ...strict, 'x-sample-rate': '16000' }); res.end(audio(320));
    });
  } });
  const a = f.make(); assert.equal((await collect(a.synthesize({ text: 'x'.repeat(300) }))).length, 1920);
  assert.deepEqual(inputs.map(s => s.length), [240, 60]); assertIdle(a);
  assert.throws(() => a.synthesize({ text: 'x'.repeat(6001) })); assertIdle(a);
});
test('STT abort while awaiting final close shuts actual socket and keeps admission until owner cleanup', async t => {
  let resolve; const seen = new Promise(r => resolve = r);
  const f = await fixture(t, { ws: p => p.on('message', (_, binary) => { if (!binary) resolve(); }) });
  const a = f.make(), abort = new AbortController(), s = await a.openSegment({ signal: abort.signal });
  const pending = s.finish(); await seen; abort.abort(); await assert.rejects(pending);
  await assert.rejects(a.openSegment(), /speech_capacity/);
  await s.close(); assertIdle(a);
});
test('STT enforces cumulative input and frame-fragment limits on actual sockets', async t => {
  await t.test('input duration cap', async t => {
    const f = await fixture(t, { ws: p => p.on('message', () => {}) }), a = f.make({ idleMs: 5000, lifetimeMs: 10000 }), s = await a.openSegment();
    const frame = Buffer.alloc(4800);
    for (let samples = 0; samples < SPEECH_BOUNDS.maxInputSamples; samples += 2400) await s.write(frame);
    await assert.rejects(s.write(Buffer.alloc(2))); await s.close(); assertIdle(a);
  });
  await t.test('fragment accumulation bounded', async t => {
    const f = await fixture(t, { ws: p => p.on('message', (_, binary) => {
      if (!binary) { p.send('{"type":"transcript",', { fin: false }); p.send('"text":"test"}', { fin: true }); }
    }) });
    const a = f.make(), s = await a.openSegment(); await assert.rejects(s.finish()); await s.close(); assertIdle(a);
  });
});
test('TTS timeout, abnormal body and normal empty completion clean actual reader', async t => {
  for (const mode of ['timeout', 'broken', 'empty']) await t.test(mode, async t => {
    const f = await fixture(t, { handle(req, res) {
      req.resume(); res.writeHead(200, strict); res.flushHeaders();
      if (mode === 'broken') { res.write(audio(10)); setImmediate(() => res.destroy()); }
      if (mode === 'empty') res.end();
    } });
    const a = f.make(); if (mode === 'empty') assert.equal((await collect(a.synthesize({ text: 'test' }))).length, 0);
    else await assert.rejects(collect(a.synthesize({ text: 'test' })));
    assertIdle(a);
  });
});
test('TTS lifetime failure survives between pulls, pending reads and cleanup; prior cancellation/EOF stay normal', async t => {
  for (const mode of ['between-pulls', 'pending-read', 'return-first', 'abort-first', 'normal-eof', 'failure-first']) await t.test(mode, async t => {
    let failBody;
    const f = await fixture(t, { handle(req, res) {
      req.resume(); res.writeHead(200, strict);
      if (mode === 'pending-read') res.write(Buffer.alloc(4800));
      else if (mode === 'failure-first') { res.write(Buffer.alloc(4800)); failBody = () => res.destroy(); }
      else res.end(Buffer.alloc(mode === 'normal-eof' ? 4800 : 9600));
    } });
    const a = f.make({ idleMs: 200, lifetimeMs: 200 }), abort = new AbortController();
    const iterator = a.synthesize({ text: 'test', signal: abort.signal });
    t.after(() => iterator.return());
    assert.equal((await iterator.next()).value.length, 4800);
    let firstError;
    if (mode === 'pending-read' || mode === 'failure-first') {
      if (mode === 'failure-first') failBody();
      await assert.rejects(iterator.next(), e => { firstError = e; return true; });
      if (mode === 'pending-read') assert.equal(firstError.code, 'speech_timeout');
      else assert.notEqual(firstError.code, 'speech_timeout');
    } else if (mode === 'return-first') await iterator.return();
    else if (mode === 'abort-first') { abort.abort(); await iterator.cleanup; }
    else if (mode === 'normal-eof') assert.deepEqual(await iterator.next(), { done: true });
    // The deadline expires while there is NO pending pull in between-pulls.
    await new Promise(resolve => setTimeout(resolve, 250)); await iterator.cleanup;
    assertIdle(a);
    if (['return-first', 'abort-first', 'normal-eof'].includes(mode)) {
      assert.deepEqual(await iterator.next(), { done: true }); assert.equal(iterator.error, undefined);
    } else {
      await assert.rejects(iterator.next(), e => { firstError ||= e; return e === firstError; });
      if (mode === 'between-pulls') assert.equal(firstError.code, 'speech_timeout');
      await iterator.return(); abort.abort();
      for (let n = 0; n < 2; n++) await assert.rejects(iterator.next(), e => e === firstError);
    }
  });
});
test('TTS bounded paused consumption applies actual HTTP backpressure and abort cleanup', async t => {
  let written = 0, resolve; const first = new Promise(r => resolve = r); const total = 20 * 1024 * 1024;
  const f = await fixture(t, { handle(req, res) {
    req.resume(); res.writeHead(200, strict); const chunk = Buffer.alloc(8192);
    const pump = () => { while (!res.destroyed && written < total) { written += chunk.length; if (!res.write(chunk)) { res.once('drain', pump); return; } } if (written >= total) res.end(); };
    pump(); resolve();
  } });
  const a = f.make(), i = a.synthesize({ text: 'test' }); await firstIfStarted(i, first);
  assert.ok(written < total); assert.ok(a.stats().tts === 1); await i.return(); assertIdle(a);
});
async function firstIfStarted(i, first) { const result = i.next(); await first; const value = await result; assert.ok(value.value.length <= 4800); }
test('TTS cumulative output bound terminates the actual stream, no unbounded accumulation', async t => {
  const f = await fixture(t, { handle(req, res) {
    req.resume(); res.writeHead(200, strict); let written = 0; const chunk = Buffer.alloc(8192);
    const pump = () => { while (!res.destroyed && written < SPEECH_BOUNDS.maxOutputBytes + 8192) { written += chunk.length; if (!res.write(chunk)) { res.once('drain', pump); return; } } if (!res.destroyed) res.end(); }; pump();
  } });
  const a = f.make(); let received = 0;
  await assert.rejects(async () => { for await (const chunk of a.synthesize({ text: 'test' })) { received += chunk.length; assert.ok(received <= SPEECH_BOUNDS.maxOutputBytes); } });
  assertIdle(a);
});
