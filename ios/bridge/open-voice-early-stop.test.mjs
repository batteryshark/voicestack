import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { WebSocket, WebSocketServer } from 'ws';
import { OpenVoiceMedia, MEDIA_PATH } from './open-voice-media.mjs';
import { createLocalSpeechAdapter } from './open-voice-speech.mjs';

// Real production media + speech transport, synthetic authority and STT only.
// No store, credentials, harness, TTS, speech daemon or native hardware.
for (const mode of ['normal', 'peer-error']) test(`paced production recognition first 2.68 seconds: ${mode}`, { timeout: 10000 }, async t => {
  const sockets = new Set();
  const stt = http.createServer();
  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });
  let inputBytes = 0, ends = 0, submissions = 0, sttPeer;
  stt.on('upgrade', (req, socket, head) => wss.handleUpgrade(req, socket, head, peer => {
    assert.equal(req.url, '/v1/transcribe?partials=1');
    sttPeer = peer;
    peer.on('error', () => {});
    peer.on('message', (data, binary) => {
      if (binary) {
        assert.equal(data.length % 2, 0); inputBytes += data.length;
        // stt_server.py:781–783: replacement-only hypothesis, not an ASR delta.
        peer.send(JSON.stringify({ type: 'transcript.partial', text: 'neutral fixture', seq: inputBytes / 2, audio_ms: inputBytes / 32 }));
      } else {
        assert.deepEqual(JSON.parse(data), { type: 'input_audio.end' }); ends++;
        peer.send(JSON.stringify({ type: 'transcript', text: 'neutral fixture' })); peer.close(1000);
      }
    });
  }));
  const mediaServer = http.createServer();
  for (const server of [stt, mediaServer]) {
    server.on('connection', s => { sockets.add(s); s.on('close', () => sockets.delete(s)); });
    server.listen(0, '127.0.0.1'); await once(server, 'listening');
  }
  const adapter = createLocalSpeechAdapter({
    sttURL: `ws://127.0.0.1:${stt.address().port}/v1/transcribe`,
    ttsURL: `http://127.0.0.1:${stt.address().port}/v1/audio/speech`, model: 'synthetic', voice: 'synthetic',
    submit: () => { submissions++; throw new Error('submission forbidden'); }
  });
  const control = {
    attach: async () => ({ call_id: 'fixture-call', media_epoch: 1, binding: {} }),
    currentAuthority() {}, readyAuthority() {}, registerMediaSession() {},
    unregisterMediaSession() {}, effectiveConfigured() {}
  };
  const diagnostics = [];
  const media = new OpenVoiceMedia({ control, adapter, diagnostic(row) {
    diagnostics.push(row); throw Error('diagnostic sink unavailable');
  } });
  mediaServer.on('upgrade', (req, socket, head) => media.upgrade(req, socket, head));
  const ws = new WebSocket(`ws://127.0.0.1:${mediaServer.address().port}${MEDIA_PATH}`, {
    headers: { authorization: `Bearer ${'x'.repeat(43)}` }, perMessageDeflate: false
  });
  const events = [];
  ws.on('error', () => {}); ws.on('message', data => events.push(JSON.parse(data)));
  t.after(async () => {
    ws.terminate(); media.close(); wss.clients.forEach(p => p.terminate());
    for (const socket of sockets) socket.destroy();
    await Promise.all([new Promise(r => stt.close(r)), new Promise(r => mediaServer.close(r)), new Promise(r => wss.close(r))]);
    for (let i = 0; i < 100 && media.stats().pendingJobs; i++) await delay(5);
    for (let i = 0; i < 100 && sockets.size; i++) await delay(5);
    assert.deepEqual(adapter.stats(), { stt: 0, tts: 0 });
    for (const key of ['sessions', 'pendingJobs', 'inputPCMBytes', 'rawBytes']) assert.equal(media.stats()[key], 0, key);
    assert.equal(sockets.size, 0);
  });
  async function wait(predicate) {
    for (let i = 0; i < 400; i++) { if (predicate()) return; await delay(5); }
    assert.fail('bounded fixture event missing');
  }
  await once(ws, 'open'); await wait(() => events.some(e => e.type === 'session.created'));
  ws.send(JSON.stringify({ type: 'session.update', session: { type: 'realtime' } }));
  await wait(() => events.some(e => e.type === 'session.updated'));
  const pcm = Buffer.alloc(960);
  for (let i = 0; i < 480; i++) pcm.writeInt16LE(Math.round(1000 * Math.sin(i / 7)), i * 2);
  for (let i = 0; i < 134; i++) {
    assert.equal(ws.readyState, WebSocket.OPEN);
    ws.send(JSON.stringify({ type: 'input_audio_buffer.append', audio: pcm.toString('base64') }));
    await delay(20);
  }
  assert.equal(ends, 0); assert.equal(submissions, 0);
  assert.ok(inputBytes > 85000);
  assert.equal(events.filter(e => e.type === 'error').length, 0);
  if (mode === 'peer-error') {
    // Exact terminal control shape from stt_server.py:788–794. The arbitrary
    // upstream message must NOT reach the candidate wire or become success.
    sttPeer.send(JSON.stringify({ type: 'error', message: 'neutral fixture failure' }));
    sttPeer.close(1011);
    await delay(20);
    ws.send(JSON.stringify({ type: 'input_audio_buffer.append', audio: pcm.toString('base64') }));
    await wait(() => events.some(e => e.type === 'error'));
    assert.equal(events.find(e => e.type === 'error').error.code, 'local_failure');
    assert.equal(JSON.stringify(events).includes('neutral fixture failure'), false);
    assert.equal(events.some(e => e.type === 'conversation.item.input_audio_transcription.completed'), false);
    assert.equal(ends, 0); assert.equal(submissions, 0);
    ws.close(1000); await once(ws, 'close');
    await wait(() => media.stats().pendingJobs === 0 && diagnostics.some(e => e.stage === 'open_voice_media'));
    const terminal = diagnostics.filter(e => e.stage === 'open_voice_stt');
    assert.equal(terminal.length, 1); assert.equal(terminal[0].cause, 6); // Public type:error, unknown prose.
    assert.equal(terminal[0].peerReason, 0); // Arbitrary peer prose is unknown, never harvested.
    assert.equal(terminal[0].endSent, 0);
    assert.ok([1006, 1011].includes(terminal[0].closeCode)); // Actual observed close, not intended close.
    assert.equal(terminal[0].inputBytes, 134 * 960);
    assert.equal(terminal[0].writtenBytes, inputBytes);
    const closed = diagnostics.find(e => e.stage === 'open_voice_media');
    assert.equal(closed.cause, 1); assert.equal(closed.ingressBytes, 135 * 960);
    assert.equal(closed.call_id, terminal[0].call_id); assert.equal(closed.media_epoch, terminal[0].media_epoch);
    assert.ok(closed.sequence > terminal[0].sequence);
    assert.equal(JSON.stringify(diagnostics).includes('neutral fixture failure'), false);
    assert.equal(JSON.stringify(diagnostics).includes('neutral fixture"'), false);
    return;
  }
  ws.send(JSON.stringify({ type: 'input_audio_buffer.commit' }));
  await wait(() => events.some(e => e.type === 'conversation.item.input_audio_transcription.completed'));
  assert.equal(inputBytes, 134 * 640); assert.equal(ends, 1); assert.equal(submissions, 0);
  assert.equal(events.find(e => e.type === 'conversation.item.input_audio_transcription.completed').transcript, 'neutral fixture');
});
