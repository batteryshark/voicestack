import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import { once } from 'node:events';
import { createBridge, SessionEvents } from './server.mjs';
import { phoneProjection } from './rich-content.mjs';
import { classifySender } from './sender.mjs';

const fixture = JSON.parse(fs.readFileSync(new URL('../shared/opencode240-fixture.json', import.meta.url)));
const sid = fixture.sessionID;

test('2.4.0 fresh synthetic idle pages preserve fixture IDs/cursors and decorate only user records', () => {
  for (const page of [fixture.latestPage, fixture.olderPage]) {
    const before = structuredClone(page);
    const projected = phoneProjection(page);
    assert.deepEqual(projected.cursor, page.cursor);
    assert.deepEqual(projected.data.map(r => r.id), page.data.map(r => r.id));
    for (const [i, record] of page.data.entries()) {
      if (record.type !== 'user') assert.deepEqual(projected.data[i], record);
      else assert.deepEqual(projected.data[i].sender, { kind: 'canvas', label: 'Agent Canvas' });
    }
    assert.deepEqual(page, before, 'canonical fixture is never mutated');
  }
});

test('2.4.0 tool-input-ended SSE uses data.sessionID; wrong sessions and connected frames never leak', async () => {
  const event = { id: 'evt_input', created: 1, type: fixture.toolInputEndedShape.type,
    location: { directory: '/synthetic' },
    data: { sessionID: sid, assistantMessageID: 'msg_tool', id: 'tool_one', text: 'Synthetic tool input, not narration.' },
    durable: { aggregateID: sid, seq: 1, version: 1 } };
  assert.deepEqual(Object.keys(event).sort(), Object.keys(fixture.toolInputEndedShape).sort());
  assert.deepEqual(Object.keys(event.data).sort(), Object.keys(fixture.toolInputEndedShape.data).sort());
  const filter = new SessionEvents(sid); let output = '';
  filter.on('data', chunk => output += chunk);
  const frames = [
    { type: 'server.connected', data: {} }, event,
    { ...event, id: 'evt_other', data: { ...event.data, sessionID: 'ses_OTHER', text: 'NOT OUR SESSION' } },
    { location: event.location, payload: { ...event, id: 'evt_wrapped' } },
  ];
  const bytes = Buffer.from(': heartbeat\n\n' + frames.map(e => 'data: ' + JSON.stringify(e) + '\n\n').join(''));
  for (let i = 0; i < bytes.length; i += 17) filter.write(bytes.subarray(i, i + 17));
  filter.end(); await once(filter, 'end');
  const projected = output.split('\n\n').filter(s => s.startsWith('data:')).map(s => JSON.parse(s.slice(5)));
  assert.deepEqual(projected, [event, { ...event, id: 'evt_wrapped' }]);
  assert.ok(output.includes(': heartbeat'));
  assert.ok(!output.includes('NOT OUR SESSION'));
});

test('installed 2.0.32 request contract replays through actual bridge: selection, cursor, prompt, interrupt, active', async () => {
  // Every mutation in this test is sent ONLY to the owned ephemeral fake server.
  const writes = [], reads = [];
  const device = { deviceID: 'synthetic', sessionID: '', generation: '', mode: 'explicit' };
  const fake = http.createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, 'Bearer synthetic-desktop-client');
      const url = new URL(req.url, 'http://fixture');
      res.setHeader('Content-Type', 'application/json');
      if (req.method === 'GET') {
        reads.push(req.url);
        if (url.pathname === '/api/system/info') return res.end('{"runtime":"desktop","openchamberVersion":"2.4.0"}');
        if (url.pathname === '/api/session') return res.end(JSON.stringify({ data: [{ id: sid, title: 'Synthetic fixture', time: { updated: 1 } }], cursor: { next: 'opaque_next' } }));
        if (url.pathname === `/api/session/${sid}`) return res.end(JSON.stringify({ data: { id: sid, title: 'Synthetic fixture' } }));
        if (url.pathname === '/api/session/active') return res.end('{"data":{}}');
        if (url.pathname === `/api/session/${sid}/message`) return res.end(JSON.stringify(url.searchParams.has('cursor') ? fixture.olderPage : fixture.latestPage));
        res.statusCode = 404; return res.end('{}');
      }
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks));
      writes.push({ method: req.method, url: req.url, body });
      if (url.pathname.endsWith('/prompt')) return res.end(JSON.stringify({ data: { id: 'msg_receipt', type: 'user', delivery: body.delivery ?? 'steer', payload: { text: body.text } } }));
      if (url.pathname.endsWith('/interrupt')) return res.end('{"interrupted":true}');
      res.statusCode = 404; res.end('{}');
    } catch (error) { res.statusCode = 500; res.end(JSON.stringify({ error: error.message })); }
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const bridge = createBridge({
    credentials: { device: auth => { assert.equal(auth, 'Bearer synthetic-phone'); return device; }, save() {} },
    discover: () => fake.address().port,
    ocClient: { check: async () => ({ ownRecordMatches: true }), note() {},
      prepare: async port => ({ port, paired: true, headers: { Authorization: 'Bearer synthetic-desktop-client' } }), rejected: () => new Error('Synthetic auth rejection') },
  });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const base = `http://127.0.0.1:${bridge.address().port}/floating-voice`;
  async function call(route, body, generation = device.generation) {
    const response = await fetch(base + route, { method: body ? 'POST' : 'GET',
      headers: { Authorization: 'Bearer synthetic-phone', 'X-FV-Generation': generation,
        ...(body ? { 'Content-Type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() };
  }
  try {
    assert.equal((await call('/v1/health')).status, 200);
    assert.equal((await call('/v1/sessions')).body.data[0].id, sid);
    assert.equal((await call('/v1/selection', { sessionID: sid, mode: 'explicit' })).status, 200);
    assert.ok(device.generation);
    const route = `/v1/sessions/${sid}`;
    const latest = await call(route + '/messages?limit=2&order=desc');
    assert.equal(latest.status, 200); assert.deepEqual(latest.body, phoneProjection(fixture.latestPage));
    const cursor = latest.body.cursor.next;
    assert.deepEqual((await call(route + '/messages?limit=2&cursor=' + cursor)).body, phoneProjection(fixture.olderPage));
    assert.ok(reads.includes(`/api/session/${sid}/message?limit=2&cursor=${cursor}`));
    assert.deepEqual((await call(route + '/state')).body, { active: false });
    for (const data of [{ text: '[voice] Synthetic only.' }, { text: 'Queued', delivery: 'queue' }, { text: 'Steered', delivery: 'steer' }, { text: 'Admitted only', resume: false }]) {
      assert.equal((await call(route + '/prompt', data)).status, 200);
      assert.deepEqual(writes.at(-1), { method: 'POST', url: `/api/session/${sid}/prompt`, body: data });
    }
    assert.deepEqual((await call(route + '/interrupt', {})).body, { interrupted: true });
    assert.deepEqual(writes.at(-1), { method: 'POST', url: `/api/session/${sid}/interrupt?resume=false`, body: {} });
    const count = writes.length;
    assert.equal((await call(route + '/prompt', { text: 'Wrong generation' }, 'stale')).status, 409);
    assert.equal(writes.length, count);
  } finally {
    bridge.shutdown(); fake.closeAllConnections(); await new Promise(resolve => fake.close(resolve));
  }
});

test('2.0.32 optional message metadata remains scoped; session creator never grants authorship', () => {
  const record = fixture.olderPage.data[0];
  const projected = phoneProjection({ ...record, metadata: { a2a: { v: 1, from: 'local/ses_origin', traceId: 'a2a_fixture', hop: 0, kind: 'request' } } });
  assert.equal(projected.sender.kind, 'agent');
  assert.equal(phoneProjection(record).sender.kind, 'canvas');
  assert.deepEqual(classifySender('Ordinary desktop input', { metadata: { a2a: { createdBy: 'local/ses_origin' } } }).sender,
    { kind: 'system', label: 'Message' });
  assert.equal(classifySender('[voice] Spoken by principal').sender.kind, 'principal');
});
