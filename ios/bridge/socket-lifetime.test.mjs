import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import crypto from 'node:crypto';
import { once } from 'node:events';
import { setImmediate } from 'node:timers/promises';
import { createBridge } from './server.mjs';
import { unpairedDesktop } from './fixtures/synthetic-desktop.mjs';

test('keep-alive proxy and SSE cycles keep socket close listeners bounded without warnings', { timeout: 10000 }, async t => {
  const warnings = [];
  const warning = w => { if (w.name === 'MaxListenersExceededWarning') warnings.push(w); };
  process.on('warning', warning);
  t.after(() => process.off('warning', warning));
  let holdEvents = false;
  const upstream = http.createServer((req, res) => {
    if (req.url === '/api/system/info') return res.end('{"runtime":"desktop"}');
    if (req.url === '/api/event') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.write(': upstream heartbeat\n\n');
      if (!holdEvents) res.end();
      return;
    }
    res.end('{}');
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { upstream.closeAllConnections(); upstream.close(); });
  const device = { deviceID: 'fixture', sessionID: 'ses_fixture', generation: 'fixture', mode: 'explicit' };
  const bridge = createBridge({ credentials: { device: () => device }, ...unpairedDesktop(t, upstream), ttsPort: upstream.address().port });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  t.after(() => bridge.shutdown());
  const sockets = [];
  bridge.on('connection', socket => sockets.push(socket));
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  // The bridge advertises a one-second keep-alive timeout. Disable the client's
  // one-second early-retirement buffer so this test actually exercises reuse.
  agent.agentKeepAliveTimeoutBuffer = 0;
  t.after(() => agent.destroy());
  async function request(route, cancel = false) {
    await new Promise((resolve, reject) => {
      const req = http.get({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/' + route,
        agent, headers: { 'X-FV-Generation': 'fixture' } }, res => {
        assert.equal(res.statusCode, 200);
        if (cancel) { res.once('data', () => res.destroy()); res.once('close', resolve); }
        else { res.resume(); res.once('end', resolve); }
        res.on('error', reject);
      });
      req.on('error', reject);
    });
    await setImmediate();
  }
  // Clean SSE ends can reuse the same HTTP socket, as do ordinary streamed responses.
  for (let i = 0; i < 120; i++) {
    await request('v1/health');
    await request('tts/v1/voices');
    await request('v1/sessions/ses_fixture/events');
  }
  assert.equal(sockets.length, 1, 'all 360 requests must reuse one downstream socket');
  assert.ok(sockets[0].listenerCount('close') <= 3, `retained close listeners: ${sockets[0].listenerCount('close')}`);
  // Mid-stream cancellation necessarily closes TCP; replacement sockets must not retain work.
  holdEvents = true;
  for (let i = 0; i < 100; i++) await request('v1/sessions/ses_fixture/events', true);
  await setImmediate();
  if (bridge.workStats().activeUpstreams) await once(bridge, 'upstreamIdle', { signal: AbortSignal.timeout(2000) });
  for (const socket of sockets) assert.ok(socket.listenerCount('close') <= 3);
  assert.deepEqual(warnings, []);
  assert.equal(bridge.workStats().activeUpstreams, 0);
});

test('100 ASR duplex upgrades stay below the socket listener limit and release upstream leases', { timeout: 10000 }, async t => {
  const warnings = [], sockets = [];
  const warning = w => { if (w.name === 'MaxListenersExceededWarning') warnings.push(w); };
  process.on('warning', warning); t.after(() => process.off('warning', warning));
  const upstream = http.createServer();
  let peak = 0, failPeer = false;
  upstream.on('upgrade', (req, socket) => {
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.on('error', () => {});
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('data', bytes => { if (failPeer) socket.destroy(); else socket.write(bytes); });
    socket.once('end', () => socket.end());
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => upstream.close());
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'fixture' }) }, ...unpairedDesktop(t, upstream), asrPort: upstream.address().port });
  bridge.on('connection', socket => {
    sockets.push(socket);
    socket.on('newListener', event => { if (event === 'close') peak = Math.max(peak, socket.listenerCount('close') + 1); });
  });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  t.after(() => bridge.shutdown());
  for (let i = 0; i < 100; i++) {
    failPeer = i % 2 === 1;
    await new Promise((resolve, reject) => {
      const req = http.get({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/asr/v1/transcribe?partials=1', agent: false,
        headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64') } });
      req.on('error', reject);
      req.on('upgrade', (_, socket) => {
        socket.on('error', reject); socket.once('close', resolve);
        socket.once('end', () => socket.destroy());
        socket.setTimeout(2000, () => socket.destroy(new Error(`ASR cycle ${i} timed out`)));
        socket.once('data', bytes => { assert.equal(bytes.toString(), 'fixture PCM'); socket.destroy(); });
        socket.write('fixture PCM');
      });
    });
    if (bridge.workStats().activeUpstreams) await once(bridge, 'upstreamIdle', { signal: AbortSignal.timeout(2000) });
  }
  await setImmediate();
  assert.equal(sockets.length, 100);
  t.diagnostic(`peak ASR socket close listeners: ${peak}`);
  assert.ok(peak <= 10, `peak socket close listeners: ${peak}`);
  assert.ok(sockets.every(socket => socket.destroyed));
  assert.equal(bridge.workStats().activeUpstreams, 0);
  assert.deepEqual(warnings, []);
});

test('ASR client half-close preserves a delayed final transcript until the peer closes', { timeout: 5000 }, async t => {
  const peers = new Set(), received = [];
  let sawFIN = false, replyTimer;
  const transcript = Buffer.from('{"type":"transcript.final","text":"Delayed fixture reply"}');
  const upstream = http.createServer();
  upstream.on('upgrade', (req, socket) => {
    peers.add(socket); socket.allowHalfOpen = true;
    socket.on('error', () => {});
    socket.once('close', () => peers.delete(socket));
    const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.on('data', bytes => received.push(bytes));
    socket.once('end', () => {
      sawFIN = true;
      replyTimer = setTimeout(() => socket.end(transcript), 150);
    });
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  t.after(() => { clearTimeout(replyTimer); for (const peer of peers) peer.destroy(); upstream.close(); });
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'fixture' }) }, ...unpairedDesktop(t, upstream), asrPort: upstream.address().port });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  t.after(() => bridge.shutdown());
  const chunks = [];
  await new Promise((resolve, reject) => {
    const req = http.get({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/asr/v1/transcribe?partials=1', agent: false,
      headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64') } });
    req.on('error', reject);
    req.on('upgrade', (_, socket, head) => {
      socket.allowHalfOpen = true;
      chunks.push(head);
      socket.on('data', bytes => chunks.push(bytes));
      socket.on('error', reject); socket.once('close', resolve);
      socket.once('end', () => socket.destroy());
      socket.setTimeout(2000, () => socket.destroy(new Error('delayed final transcript timeout')));
      socket.end('fixture audio followed by FIN');
    });
  });
  assert.deepEqual(Buffer.concat(chunks), transcript, 'client must receive the final transcript after its writable side ends');
  assert.equal(sawFIN, true, 'client FIN must propagate to the ASR peer');
  assert.equal(Buffer.concat(received).toString(), 'fixture audio followed by FIN');
  if (bridge.workStats().activeUpstreams) await once(bridge, 'upstreamIdle', { signal: AbortSignal.timeout(2000) });
  assert.equal(bridge.workStats().activeUpstreams, 0);
});
