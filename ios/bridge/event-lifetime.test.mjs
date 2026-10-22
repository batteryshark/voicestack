import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { eventLifetime } from './event-lifetime.mjs';
import { createBridge } from './server.mjs';
import { unpairedDesktop } from './fixtures/synthetic-desktop.mjs';

class Clock {
  now = 0; next = 0; jobs = new Map();
  setTimeout = (fn, delay) => { const id = ++this.next; this.jobs.set(id, { fn, at: this.now + delay }); return id; };
  clearTimeout = id => this.jobs.delete(id);
  setInterval = (fn, delay) => { const id = this.setTimeout(fn, delay); this.jobs.get(id).repeat = delay; return id; };
  clearInterval = this.clearTimeout;
  advance(ms) {
    const end = this.now + ms;
    for (;;) {
      const entry = [...this.jobs].filter(([, j]) => j.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!entry) break;
      const [id, j] = entry; this.now = j.at;
      if (j.repeat) j.at += j.repeat; else this.jobs.delete(id);
      j.fn();
    }
    this.now = end;
  }
}

test('downstream heartbeats cannot conceal a stale upstream; every timer closes', () => {
  const clock = new Clock(), beats = [], closes = [];
  eventLifetime({ clock, heartbeat: () => beats.push(clock.now), validate() {}, close: (...args) => closes.push(args) });
  clock.advance(75000);
  assert.equal(beats.length, 4);
  assert.deepEqual(closes, [['watchdog', 'upstream_idle', false]]);
  assert.equal(clock.jobs.size, 0);
  clock.advance(300000); assert.equal(closes.length, 1);
});

test('upstream bytes refresh only upstream watchdog; clean rotation and lease loss are distinct', () => {
  for (const revoked of [false, true]) {
    const clock = new Clock(), closes = [];
    let valid = true;
    const life = eventLifetime({ clock, heartbeat() {}, validate() { if (!valid) throw Error(); }, close: (...a) => closes.push(a) });
    for (let n = 0; n < 4; n++) { clock.advance(50000); life.bytes(); }
    if (revoked) valid = false;
    clock.advance(40000);
    assert.deepEqual(closes, [revoked ? ['bridge', 'lease_invalid', false] : ['bridge', 'rotation', true]]);
    assert.equal(clock.jobs.size, 0);
  }
});

test('client cancellation releases all event timers immediately', () => {
  const clock = new Clock();
  const life = eventLifetime({ clock, heartbeat() { assert.fail(); }, validate() {}, close() { assert.fail(); } });
  life.stop(); life.stop(); life.bytes(); clock.advance(300000);
  assert.equal(clock.jobs.size, 0);
});

test('loopback SSE flushes quiet headers, emits heartbeat, rotates with HTTP end and correlates reason', async t => {
  const clock = new Clock(), logs = [];
  let upstreamResponse;
  const fake = http.createServer((req, res) => {
    if (req.url === '/api/system/info') res.end('{"runtime":"desktop"}');
    else { upstreamResponse = res; res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.flushHeaders(); }
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const bridge = createBridge({ credentials: { device: () => ({ sessionID: 'ses_fixture', generation: 'fixture' }) }, ...unpairedDesktop(t, fake), eventClock: clock, diagnostic: e => logs.push(e) });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const attempt = '12345678-1234-1234-1234-123456789abc';
  try {
    const request = http.get({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/v1/sessions/ses_fixture/events', headers: { 'X-FV-Generation': 'fixture', 'X-FV-Attempt': attempt } });
    const [response] = await once(request, 'response');
    assert.equal(response.headers['x-accel-buffering'], 'no');
    assert.equal(response.headers['content-encoding'], 'identity');
    let body = ''; response.on('data', chunk => body += chunk);
    await once(response, 'data');
    clock.advance(15000); await once(response, 'data');
    assert.match(body, /: heartbeat/);
    for (let i = 0; i < 4; i++) {
      clock.advance(45000);
      upstreamResponse.write(`data: {"type":"fixture","data":{"sessionID":"ses_fixture","tick":${i}}}\n\n`);
      while (!body.includes(`"tick":${i}`)) await once(response, 'data');
    }
    const ended = once(response, 'end');
    clock.advance(45000);
    await ended;
    assert.equal(response.complete, true);
    assert.equal(clock.jobs.size, 0);
    assert.equal(logs.find(e => e.stage === 'events' && e.category === 'begin').attempt, attempt);
    assert.equal(logs.at(-1).reason, 'rotation');
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});
