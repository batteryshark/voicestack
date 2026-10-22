import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { createBridge } from './server.mjs';
import { unpairedDesktop } from './fixtures/synthetic-desktop.mjs';

async function listen(server) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return server.address().port; }
for (const mode of ['refused', 'reset']) {
  test(`speech ${mode}: closed envelopes on HTTP and ASR upgrade, no upstream text`, async t => {
    // Ephemeral listeners stand in for 8444/8450 TTS and 8446 ASR; never bind live ports.
    const upstream = net.createServer(s => s.once('data', bytes => {
      assert.ok(!/\r\nauthorization:/i.test(bytes.toString()), 'speech reset/refusal must never receive any bearer');
      s.destroy();
    }));
    const port = await listen(upstream);
    if (mode === 'refused') await new Promise(resolve => upstream.close(resolve));
    else t.after(() => upstream.close());
    let desktopPrepares = 0;
    const ocClient = { prepare: async () => { desktopPrepares++; throw new Error('Speech must not enter desktop auth context'); }, check: async () => {}, note() {} };
    const bridge = createBridge({ credentials: { device: () => ({}) }, discover: () => port, ttsPort: port, asrPort: port, ocClient });
    const bp = await listen(bridge); t.after(() => bridge.shutdown());
    for (const [route, service] of [['asr/health', 'asr'], ['tts/health', 'tts'], ['tts/v1/voices', 'tts'], ['tts/v1/audio/speech', 'tts']]) {
      const options = route.endsWith('speech') ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ model: 'default', voice: 'default', input: 'Hello', response_format: 'wav' }) } : {};
      const r = await fetch(`http://127.0.0.1:${bp}/floating-voice/${route}`, { ...options, headers: { Authorization: 'Bearer synthetic-phone', ...options.headers } });
      assert.equal(r.status, 503);
      assert.deepEqual(await r.json(), { error: 'speech_unavailable', service, endpoint: `127.0.0.1:${port}` });
    }
    const result = await new Promise((resolve, reject) => {
      const r = http.get({ host: '127.0.0.1', port: bp, path: '/floating-voice/asr/v1/transcribe?partials=1', headers: {
        Authorization: 'Bearer synthetic-phone', Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ=='
      } }, res => { let body = ''; res.on('data', d => body += d); res.on('end', () => resolve({ code: res.statusCode, body })); });
      r.on('error', reject);
    });
    assert.equal(result.code, 503);
    assert.deepEqual(JSON.parse(result.body), { error: 'speech_unavailable', service: 'asr', endpoint: `127.0.0.1:${port}` });
    assert.equal(desktopPrepares, 0, 'speech_unavailable paths do not prepare desktop authentication');
  });
}
test('health forwards direct and nested state without sending synthesis or websocket work', async t => {
  const paths = [];
  const upstream = http.createServer((req, res) => { assert.equal(req.headers.authorization, undefined); paths.push(req.url); res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ model: 'loaded', upstream: { model: 'unloaded' } })); });
  const port = await listen(upstream); t.after(() => upstream.close());
  const bridge = createBridge({ credentials: { device: () => ({}) }, ...unpairedDesktop(t, upstream), ttsPort: port, asrPort: port });
  const bp = await listen(bridge); t.after(() => bridge.shutdown());
  for (const service of ['tts', 'asr']) {
    const r = await fetch(`http://127.0.0.1:${bp}/floating-voice/${service}/health`);
    assert.equal(r.status, 200); assert.equal((await r.json()).upstream.model, 'unloaded');
  }
  assert.deepEqual(paths, ['/health', '/health']);
});
