import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { SpeechTransferTiming } from './speech-timing.mjs';
import { createBridge } from './server.mjs';

test('bounded arrival histogram counts bytes, first byte, max and nearest-rank p95', () => {
  const timing = new SpeechTransferTiming(0);
  assert.equal(timing.snapshot(10).firstByteMs, -1);
  assert.equal(timing.receive(0, 50), false);
  assert.equal(timing.receive(100, 500), true);
  for (let i = 1; i <= 19; i++) timing.receive(100, 500 + i * 125);
  timing.receive(100, 4875);
  const value = timing.snapshot(10000);
  assert.equal(value.bytesReceived, 2100); assert.equal(value.chunksReceived, 21);
  assert.equal(value.firstByteMs, 500); assert.equal(value.chunkGapP95Ms, 125);
  assert.equal(value.chunkGapMaxMs, 2000); assert.equal(value.chunkGapSamples, 20);
  timing.receive(1, 24875);
  assert.equal(timing.snapshot(25000).chunkGapClipped, 1);
  assert.equal(timing.buckets.length, 2001);
});

const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const close = server => new Promise(resolve => server.close(resolve));
test('real loopback proxy records upstream TTFB/chunks/total with existing attempt and no payload', async () => {
  const stages = [], attempt = '12345678-1234-4234-8234-123456789abc';
  const upstream = http.createServer((req, res) => {
    req.resume(); req.once('end', () => {
      res.writeHead(200, { 'Content-Type': 'audio/pcm', 'X-Sample-Rate': '24000' });
      setTimeout(() => { res.write(Buffer.from([0, 1])); setTimeout(() => res.end(Buffer.from([2, 3])), 25); }, 25);
    });
  });
  await listen(upstream);
  const bridge = createBridge({ credentials: { device: () => ({}) }, ttsPort: upstream.address().port, diagnostic: entry => stages.push(entry) });
  await listen(bridge);
  try {
    const received = await new Promise((resolve, reject) => {
      const body = JSON.stringify({ model: 'default', voice: 'default', input: 'PRIVATE payload must never be logged', response_format: 'pcm' });
      const request = http.request({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/tts/v1/audio/speech', method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'X-FV-Attempt': attempt } }, response => {
        const chunks = []; response.on('data', chunk => chunks.push(chunk)); response.on('end', () => resolve(Buffer.concat(chunks)));
      }); request.on('error', reject); request.end(body);
    });
    assert.deepEqual(received, Buffer.from([0, 1, 2, 3]));
    const rows = stages.filter(row => row.playbackEvent);
    assert.deepEqual(rows.map(row => row.playbackEvent), ['upstreamRequest', 'upstreamFirstByte', 'upstreamComplete']);
    assert.ok(rows.every(row => row.stage === 'tts' && row.attempt === attempt));
    const end = rows.at(-1);
    assert.equal(end.category, 'complete'); assert.equal(end.bytesReceived, 4);
    assert.ok(end.firstByteMs >= 10 && end.requestTotalMs >= end.firstByteMs);
    assert.ok(end.chunksReceived >= 2 && end.chunkGapMaxMs >= 10);
    assert.ok(!JSON.stringify(rows).includes('PRIVATE') && !JSON.stringify(rows).includes('/speech'));
  } finally { bridge.shutdown(); await close(upstream); }
});

test('upstream refusal without bytes has one failed completion and no fake first byte', async () => {
  const upstream = http.createServer((req, res) => { req.resume(); req.once('end', () => { res.writeHead(503); res.end(); }); });
  await listen(upstream);
  const stages = [], bridge = createBridge({ credentials: { device: () => ({}) }, ttsPort: upstream.address().port, diagnostic: entry => stages.push(entry) });
  await listen(bridge);
  try {
    await new Promise((resolve, reject) => {
      const body = JSON.stringify({ model: 'default', voice: 'default', input: 'synthetic', response_format: 'wav' });
      const request = http.request({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/tts/v1/audio/speech', method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, res => { res.resume(); res.once('end', resolve); });
      request.on('error', reject); request.end(body);
    });
    const end = stages.filter(row => row.playbackEvent === 'upstreamComplete');
    assert.equal(end.length, 1); assert.equal(end[0].category, 'failed'); assert.equal(end[0].firstByteMs, -1); assert.equal(end[0].bytesReceived, 0);
  } finally { bridge.shutdown(); await close(upstream); }
});
