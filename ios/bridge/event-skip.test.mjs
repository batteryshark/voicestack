import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { SessionEvents, createBridge } from './server.mjs';
import { unpairedDesktop } from './fixtures/synthetic-desktop.mjs';

const sid = 'ses_owned', limit = 262144;
const good = (text = 'later owned event') => 'data: ' + JSON.stringify({ type: 'session.text.delta', data: { sessionID: sid, delta: text } }) + '\n\n';
const large = (sessionID = 'ses_unrelated') => 'data: ' + JSON.stringify({ type: 'session.tool.updated', data: { sessionID, value: 'PRIVATE_BIG_RECORD'.repeat(32768) } }) + '\n\n';
const deep = () => 'data: {"type":"session.tool.updated","data":{"sessionID":"'+sid+'","deep":'+'{"x":'.repeat(10000)+'0'+'}'.repeat(10000)+'}}\n\n';
function collect(options) {
  const notes = [], output = [];
  const filter = new SessionEvents(sid, { diagnostic: x => notes.push(x), ...options });
  filter.on('data', data => output.push(data));
  return { filter, notes, output, text: () => Buffer.concat(output).toString(),
    events: () => Buffer.concat(output).toString().split('\n\n').filter(x => x.startsWith('data: ')).map(x => JSON.parse(x.slice(6))) };
}
async function finish(fixture, chunks) {
  const done = once(fixture.filter, 'end');
  for (const chunk of chunks) fixture.filter.write(chunk);
  fixture.filter.end(); await done; return fixture;
}

test('oversized unrelated record never closes stream or leaks bytes; following owned event survives', async () => {
  const c = await finish(collect(), [large(), good()]);
  assert(c.notes.some(x => x.reason === 'event_oversize'));
  assert(c.events().some(x => x.data.delta === 'later owned event'));
  assert(!c.text().includes('PRIVATE') && !c.text().includes('ses_unrelated'));
  assert(c.events().every(x => x.data.sessionID === sid));
});
test('malformed JSON skips only its record; closed diagnostics contain no content', async () => {
  const c = await finish(collect(), ['data: {PRIVATE_MALFORMED\n\n', good()]);
  assert.deepEqual(c.notes.map(x => x.reason), ['invalid_json']);
  assert(c.events().some(x => x.data.delta === 'later owned event'));
  assert(!JSON.stringify(c.notes).includes('PRIVATE'));
  assert(!c.text().includes('MALFORMED'));
});
test('real recursive phoneProjection throw skips one deeply nested owned record', async () => {
  const nested = deep();
  assert(Buffer.byteLength(nested) < limit);
  const c = await finish(collect(), [nested, good()]);
  assert.deepEqual(c.notes.map(x => x.reason), ['projection_failed']);
  assert(c.events().some(x => x.data.delta === 'later owned event'));
  assert(!c.text().includes('deep'));
});
test('LF and every CRLF delimiter split recover out of skip mode', async () => {
  for (const delimiter of ['\n\n', '\r\n\r\n', '\n\r\n', '\r\n\n']) {
    for (let split = 1; split < delimiter.length; split++) {
      const c = await finish(collect(), [Buffer.alloc(limit+1, 120), delimiter.slice(0, split), delimiter.slice(split)+good()]);
      assert.equal(c.events().filter(x => x.data.delta === 'later owned event').length, 1);
      assert(c.filter.maxBufferedBytes <= limit && !c.filter.skipping);
    }
  }
});
test('oversized selected-session record produces build-18 inbox refresh hints at overflow and tail', async () => {
  const c = collect(), bytes = Buffer.from(large(sid));
  c.filter.write(bytes.subarray(0, limit+1));
  assert.equal(c.events().at(-1).type, 'session.inbox.delivered');
  const before = c.events().length;
  await finish(c, [bytes.subarray(limit+1), good()]);
  assert(c.events().length > before);
  assert(c.events().some(x => x.type === 'session.inbox.delivered' && x.data.sessionID === sid));
  assert(c.events().filter(x => x.type === 'session.inbox.delivered').every(x => Object.keys(x.data).length === 1));
});
test('unknown late session identity is conservative: no prefix assumption can suppress repair', async () => {
  const record = 'data: {"type":"session.tool.updated","data":{"large":"'+'x'.repeat(limit+1)+'","sessionID":"'+sid+'"}}\n\n';
  const c = await finish(collect(), [record]);
  assert(c.events().some(x => x.type === 'session.inbox.delivered'));
});
test('unterminated multi-megabyte skip holds at most 256KiB plus finite delimiter state', async () => {
  const c = collect();
  for (let i = 0; i < 128; i++) {
    c.filter.write(Buffer.alloc(65536, 120));
    assert(c.filter.bufferedBytes <= limit);
    assert.equal(c.filter.record.length, limit);
    assert([0, 1, 2].includes(c.filter.delimiterState));
  }
  assert(c.filter.skipping);
  await finish(c, ['\r\n\r', '\n'+good()]);
  assert.equal(c.filter.maxBufferedBytes, limit);
  assert.equal(c.filter.bufferedBytes, 0);
  assert(c.events().some(x => x.data.delta === 'later owned event'));
});
test('large chunk containing many individually bounded valid records is not oversized', async () => {
  const c = await finish(collect(), [good('x'.repeat(80000)).repeat(6)]);
  assert.equal(c.events().length, 6); assert.deepEqual(c.notes, []);
});
test('record bound includes delimiter: exact bound is accepted and bound plus one is skipped', async () => {
  const text = 'x'.repeat(limit - Buffer.byteLength(good('')));
  const c = await finish(collect(), [good(text), good(text+'x'), good()]);
  assert.equal(c.notes.filter(x => x.reason === 'event_oversize').length, 1);
  assert.equal(c.events().filter(x => x.type === 'session.text.delta').length, 2);
  assert.equal(c.filter.maxBufferedBytes, limit);
});
test('invalid selected-session shape is a closed skip, not a stream exception', async () => {
  const c = await finish(collect(), ['data: {"type":123,"data":{"sessionID":"'+sid+'"}}\n\n', good()]);
  assert.deepEqual(c.notes.map(x => x.reason), ['invalid_shape']);
  assert(c.events().some(x => x.data.delta === 'later owned event'));
});
test('UTF-8 split inside a codepoint survives; invalid UTF-8 is skipped without leak', async () => {
  const bytes = Buffer.from(good('hello 🌊')), location = bytes.indexOf(Buffer.from('🌊'))+2;
  const c = await finish(collect(), [bytes.subarray(0, location), bytes.subarray(location), Buffer.from([100,97,116,97,58,32,255,10,10]), good()]);
  assert(c.events().some(x => x.data.delta === 'hello 🌊'));
  assert(c.notes.some(x => x.reason === 'invalid_utf8'));
});
test('partial record at EOF is diagnosed and refreshes; throwing diagnostics cannot break stream', async () => {
  const c = await finish(collect({ diagnostic: () => { throw Error('not serializable'); } }), ['data: {', '\n\n', good(), 'data: {unfinished']);
  assert(c.events().some(x => x.data.delta === 'later owned event'));
  assert(c.events().at(-1).type === 'session.inbox.delivered');
});
test('real HTTP pipeline survives all bad records, preserves heartbeat and closes cleanly', async t => {
  const logs = [];
  const upstream = http.createServer((req, res) => {
    if (req.url === '/api/system/info') { res.end('{"runtime":"desktop"}'); return; }
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(large()); res.write('data: {bad\n\n'); res.write(deep());
    res.write(': PRIVATE_GLOBAL_COMMENT\n\n');
    res.write(large(sid).slice(0, -1)); res.write('\n'+good()); res.end();
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  const bridge = createBridge({ credentials: { device: () => ({ sessionID: sid, generation: 'fixture' }) }, ...unpairedDesktop(t, upstream), diagnostic: e => logs.push(e) });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  try {
    const request = http.get({ host: '127.0.0.1', port: bridge.address().port, path: '/floating-voice/v1/sessions/'+sid+'/events', headers: { 'X-FV-Generation': 'fixture' } });
    const [response] = await once(request, 'response');
    let body = ''; for await (const chunk of response) body += chunk;
    assert.equal(response.statusCode, 200); assert(response.complete);
    assert(body.includes('later owned event') && body.includes(': heartbeat'));
    assert(!body.includes('PRIVATE') && !body.includes('ses_unrelated'));
    assert(logs.some(x => x.category === 'skipped' && x.reason === 'event_oversize'));
    assert(logs.some(x => x.category === 'skipped' && x.reason === 'invalid_json'));
    assert(logs.some(x => x.category === 'skipped' && x.reason === 'projection_failed'));
    assert(!logs.some(x => x.reason === 'invalid_event' || x.reason === 'internal_error'));
    assert(logs.some(x => x.reason === 'clean_end'));
  } finally { bridge.shutdown(); upstream.closeAllConnections(); await new Promise(r => upstream.close(r)); }
});
