import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { canvasShowAssociation, canvasAssociation, phoneProjection, showRevision } from './rich-content.mjs';
import { createBridge } from './server.mjs';

const viewId = '11111111-1111-4111-8111-111111111111';
export const record = { id: 'msg_A', type: 'assistant', content: [
  { type: 'text', text: 'Canvas created, revision 1. [Open Canvas](https://canvas.fixture.invalid/#key=[redacted]&view=' + viewId + ')' },
  { type: 'tool', id: 'tool_A', name: 'canvas_show', executed: false, state: { status: 'completed',
    input: { title: 'Fixture', summary: 'Synthetic only', format: 'openui', source: 'root = Stack([TextContent("Fixture")]);' },
    metadata: { title: 'Fixture', viewId, revision: 1, truncated: false },
    content: [{ type: 'text', text: 'View: ' + viewId + '\nRevision: 1\nhttps://canvas.fixture.invalid/#key=FAKE_VIEWER&view=' + viewId }] } }
] };
test('canvas_show metadata association and phone projection, never link/result/source parsing', () => {
  assert.deepEqual(canvasShowAssociation(record, 1), { viewId, revision: 1, toolID: 'tool_A', format: 'openui' });
  const projected = JSON.stringify(phoneProjection(record));
  for (const secret of ['canvas.fixture.invalid', 'FAKE_VIEWER', 'TextContent', 'key=']) assert.ok(!projected.includes(secret));
  assert.equal(phoneProjection(record).content[1].state.content, undefined);
  const prose = phoneProjection({ type: 'assistant', content: [{ type: 'text', text: '[Open Canvas](https://canvas.fixture.invalid/any/path)' }] });
  assert.ok(!JSON.stringify(prose).includes('canvas.fixture.invalid'));
  const encoded = phoneProjection('https://opaque.fixture.invalid/#%6bey=SYNTHETIC_SECRET&view=1');
  assert.ok(!encoded.includes('opaque.fixture.invalid') && !encoded.includes('SYNTHETIC_SECRET'));
  assert.ok(!phoneProjection('#key=[redacted]&view=1').includes('key='));
  assert.throws(() => canvasAssociation(record, 1));
  for (const mutate of [r => r.content[1].state.metadata.truncated = true, r => delete r.content[1].state.metadata.viewId, r => r.content[1].name = 'webfetch', r => r.content[1].state.metadata.revision = 0]) {
    const bad = structuredClone(record); mutate(bad); assert.throws(() => canvasShowAssociation(bad, 1));
  }
});
test('source authority fails closed on mismatched session, revision, format and source bounds', () => {
  const panel = { sessionKey: 'SYNTHETIC_SESSION', revision: 1, format: 'openui' };
  const good = { number: 1, sessionKey: panel.sessionKey, title: 'Fixture', summary: '', content: { format: 'openui', source: 'root = Stack([])' } };
  assert.equal(showRevision(good, panel).source, good.content.source);
  for (const change of [{ sessionKey: 'OTHER' }, { number: 2 }, { content: { format: 'html', source: '<p>No</p>' } }, { content: { format: 'openui', source: '' } }, { content: { format: 'openui', source: 'x'.repeat(200001) } }, { content: undefined }, { title: panel.sessionKey }, { content: { format: 'openui', source: panel.sessionKey } }]) assert.throws(() => showRevision({ ...good, ...change }, panel));
});
test('show broker isolates revision and input, keeps stable unknown UUID and lease binding', async t => {
  let generation = 'one', latest = 1, dispatches = 0, uncertain = false, interactions = [], changed = false, rejectCode = 0, changeOnSubmit = false, acknowledge = false;
  const receiptRecords = new Map(), receiptReads = [];
  let receiptUnavailable = false;
  const fake = http.createServer(async (req, res) => {
    assert.equal(req.headers.authorization, undefined);
    if (req.url === '/api/system/info') return res.end('{"runtime":"desktop"}');
    if (req.url === '/api/session/ses_A') return res.end(JSON.stringify({ data: { id: 'ses_A', location: { directory: '/fixture' } } }));
    if (req.url.startsWith('/api/session/ses_A/message/msg_canvas')) {
      receiptReads.push(req.url);
      if (receiptUnavailable) { res.writeHead(503); return res.end('{"error":"Synthetic receipt temporarily unavailable"}'); }
      const receipt = receiptRecords.get(req.url.split('/').at(-1));
      if (!receipt) res.writeHead(404);
      return res.end(JSON.stringify(receipt ? { data: receipt } : { error: 'Synthetic missing receipt' }));
    }
    if (/^\/api\/session\/ses_A\/message\/msg_[AB]$/.test(req.url)) {
      const r = structuredClone(record); r.id = req.url.split('/').at(-1);
      if (changed) r.content[1].id = 'changed'; r.content.push(r.content[1]);
      return res.end(JSON.stringify({ data: r }));
    }
    assert.equal(req.url, '/api/guests/agent-canvas/service/request');
    const chunks = []; for await (const c of req) chunks.push(c);
    const outer = JSON.parse(Buffer.concat(chunks)), inner = JSON.parse(outer.body);
    let result;
    if (outer.path === '/connect') result = { key: 'FAKE_VIEWER' };
    else if (inner.path === '/api/snapshot') result = { session: { key: 'FAKE_SESSION', sessionId: 'ses_A', directory: '/fixture' }, views: [{ id: viewId, latest }, { id: 'OTHER_PINNED_VIEW', latest: 99 }], interactions };
    else if (inner.path.startsWith(`/api/revision?id=${viewId}&revision=`)) result = { sessionKey: 'FAKE_SESSION', number: Number(inner.path.split('revision=')[1]), title: 'Fixture', summary: 'Synthetic only', content: record.content[1].state.input };
    else if (inner.path === '/api/submit') {
      dispatches++;
      assert.deepEqual(Object.keys(inner.body).sort(), ['id', 'sessionKey', 'viewId', 'revision', 'action', 'data', 'notes'].sort());
      assert.equal(inner.body.viewId, viewId); assert.equal(inner.body.action.trim(), 'Choose');
      if (rejectCode) { const status = rejectCode; rejectCode = 0; res.end(JSON.stringify({ status, body: JSON.stringify({ error: 'Synthetic input rejection' }) })); return; }
      if (uncertain) { req.socket.destroy(); return; }
      // Installed SubmissionSchema trims action; submit returns the flat Interaction.
      const stored = { ...inner.body, action: inner.body.action.trim(), status: 'queued', detail: 'Waiting for the agent to pick this up.' };
      result = stored;
      if (acknowledge) interactions = [{ ...stored, status: 'delivered', detail: 'Accepted into this OpenCode conversation.' }];
      if (changeOnSubmit) { generation = 'changedAfterDispatch'; changeOnSubmit = false; }
    } else if (inner.path === '/api/retry') { dispatches++; result = { status: 'queued' }; }
    else assert.fail('unexpected Canvas request');
    res.end(JSON.stringify({ status: 200, body: JSON.stringify(result) }));
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const bridge = createBridge({ credentials: { device: () => ({ deviceID: 'fixture', sessionID: 'ses_A', generation, mode: 'explicit' }) }, discover: () => fake.address().port });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  const base = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_A/canvas-show/`;
  const call = (op, obj, gen = generation) => fetch(base + op, { method: 'POST', headers: { Authorization: 'Bearer fixture', 'X-FV-Generation': gen, 'Content-Type': 'application/json' }, body: JSON.stringify(obj) });
  try {
    const response = await call('resolve', { messageID: 'msg_A', blockOrdinal: 1 }); assert.equal(response.status, 200);
    const text = await response.text(); for (const secret of ['FAKE_VIEWER', 'FAKE_SESSION', 'OTHER_PINNED_VIEW', 'browserUrl', 'document']) assert.ok(!text.includes(secret));
    const panel = JSON.parse(text); assert.equal(panel.format, 'openui'); assert.ok(panel.source.includes('Stack'));
    const pageResponse = await call('page', { panelID: panel.panelID });
    assert.equal(pageResponse.status, 200, await pageResponse.clone().text());
    let pageResult = await pageResponse.json(); const chunks = [];
    while (true) {
      assert.equal(pageResult.latest, 1); assert.ok(Buffer.byteLength(JSON.stringify(pageResult)) < 256 * 1024);
      chunks.push(Buffer.from(pageResult.chunk, 'base64'));
      if (pageResult.nextOffset === null) break;
      pageResult = await (await call('page', { panelID: panel.panelID, offset: pageResult.nextOffset })).json();
    }
    const page = Buffer.concat(chunks).toString('utf8'); assert.ok(page.includes('window.canvasRevision='));
    for (const secret of ['FAKE_VIEWER', 'FAKE_SESSION', 'OTHER_PINNED_VIEW', panel.panelID]) assert.ok(!page.includes(secret));
    const input = { panelID: panel.panelID, id: '00000000-0000-4000-8000-000000000001', action: 'Choose', data: { choice: 'A' }, notes: '' };
    await t.test('host-normalized action maps acknowledged delivery, not cached queued; no second dispatch', async () => {
      const padded = { ...input, id: '00000000-0000-4000-8000-00000000000a', action: '  Choose\n' };
      const before = dispatches; acknowledge = true;
      const queued = await (await call('submit', padded)).json();
      assert.equal(queued.status, 'queued');
      const delivered = await (await call('status', padded)).json();
      assert.deepEqual(delivered, { id: padded.id, status: 'delivered', detail: 'Accepted into this OpenCode conversation.' });
      assert.equal((await (await call('status', { ...padded, action: 'Choose' })).json()).status, 'delivered');
      assert.equal((await (await call('submit', padded)).json()).status, 'delivered');
      assert.equal(dispatches, before + 1);
      acknowledge = false; interactions = [];
    });
    await t.test('missing or mismatched snapshot interaction is unknown, never cached queued or another input delivery', async () => {
      const pending = { ...input, id: '00000000-0000-4000-8000-00000000000b' };
      await call('submit', pending); const before = dispatches;
      for (const change of [{ id: input.id }, { viewId: 'OTHER_VIEW' }, { revision: 2 }, { action: 'Other' }]) {
        interactions = [{ id: pending.id, viewId, revision: 1, action: 'Choose', status: 'delivered', ...change }];
        assert.equal((await (await call('status', pending)).json()).status, 'uncertain');
      }
      interactions = [];
      assert.equal((await (await call('status', pending)).json()).status, 'uncertain');
      assert.equal((await call('retry', pending)).status, 409);
      assert.equal(dispatches, before);
    });
    await t.test('installed flat status vocabulary maps exactly; unrecognized aliases never imply delivery', async () => {
      const pending = { ...input, id: '00000000-0000-4000-8000-00000000000c' };
      await call('submit', pending);
      for (const status of ['queued', 'sending', 'delivered', 'unsent', 'uncertain', 'sent', 'accepted', 'done', undefined]) {
        interactions = [{ id: pending.id, viewId, revision: 1, action: 'Choose', status, detail: 'Synthetic only', prompt: 'DO_NOT_PROJECT_PROMPT', sessionKey: 'DO_NOT_PROJECT_KEY' }];
        const result = await (await call('status', pending)).json();
        assert.equal(result.status, ['queued', 'sending', 'delivered', 'unsent', 'uncertain'].includes(status) ? status : 'uncertain');
        assert.deepEqual(Object.keys(result).sort(), ['detail', 'id', 'status']);
      }
      interactions = [];
    });
    await t.test('review2: queued/sending survive multiple broker polls without proof until a later exact receipt', async () => {
      const pending = { ...input, id: '00000000-0000-4000-8000-0000000000f1' };
      await call('submit', pending); const before = dispatches, readsBefore = receiptReads.length;
      const messageId = 'msg_canvas' + pending.id.replaceAll('-', ''), prompt = 'Synthetic delayed receipt';
      const interaction = { id: pending.id, sessionKey: 'FAKE_SESSION', viewId, revision: 1, action: 'Choose', messageId, prompt, status: 'queued' };
      interactions = [interaction];
      try {
        assert.equal((await (await call('status', pending)).json()).status, 'queued', 'first real broker poll has no receipt yet');
        interaction.status = 'sending'; receiptUnavailable = true;
        assert.equal((await (await call('status', pending)).json()).status, 'sending', 'temporary proof outage must not terminate polling');
        receiptUnavailable = false;
        assert.equal((await (await call('status', pending)).json()).status, 'sending', 'third poll still has no persisted receipt');
        receiptRecords.set(messageId, { id: messageId, type: 'user', text: prompt });
        const result = await (await call('status', pending)).json();
        assert.equal(result.status, 'delivered'); assert.match(result.detail, /session record/);
        assert.equal(receiptReads.length, readsBefore + 4); assert.equal(dispatches, before);
      } finally { receiptUnavailable = false; receiptRecords.delete(messageId); interactions = []; }
    });
    await t.test('review2: twenty real broker polls preserve pending, genuine host uncertainty remains uncertain without proof', async () => {
      const pending = { ...input, id: '00000000-0000-4000-8000-0000000000f2' };
      await call('submit', pending); const before = dispatches, readsBefore = receiptReads.length;
      const messageId = 'msg_canvas' + pending.id.replaceAll('-', '');
      const interaction = { id: pending.id, sessionKey: 'FAKE_SESSION', viewId, revision: 1, action: 'Choose', messageId, prompt: 'Synthetic never-persisted receipt', status: 'queued' };
      interactions = [interaction];
      try {
        for (let poll = 0; poll < 20; poll++) {
          interaction.status = poll === 0 ? 'queued' : 'sending';
          assert.equal((await (await call('status', pending)).json()).status, interaction.status);
        }
        assert.equal(receiptReads.length, readsBefore + 20);
        interaction.status = 'uncertain';
        assert.equal((await (await call('status', pending)).json()).status, 'uncertain');
        assert.equal((await call('retry', pending)).status, 409); assert.equal(dispatches, before);
      } finally { interactions = []; }
    });
    await t.test('scoped durable user receipt confirms pending/uncertain exactly once without another dispatch', async () => {
      for (const [index, status] of ['queued', 'sending', 'uncertain'].entries()) {
        const pending = { ...input, id: '00000000-0000-4000-8000-' + (171 + index).toString(16).toUpperCase().padStart(12, '0') };
        await call('submit', pending); const before = dispatches, readBefore = receiptReads.length;
        const messageId = 'msg_canvas' + pending.id.replaceAll('-', ''), prompt = 'Synthetic exact Canvas prompt ' + index;
        interactions = [{ id: pending.id, sessionKey: 'FAKE_SESSION', viewId, revision: 1, action: 'Choose', messageId, prompt, status, detail: 'Synthetic in-flight or uncertain acknowledgement' }];
        // Canonical V2 User deliberately has no sessionID field; ownership is its scoped endpoint.
        receiptRecords.set(messageId, { id: messageId, type: 'user', text: prompt });
        const delivered = await (await call('status', pending)).json();
        assert.equal(delivered.status, 'delivered'); assert.match(delivered.detail, /session record/);
        assert.deepEqual(Object.keys(delivered).sort(), ['detail', 'id', 'status']);
        assert.equal(receiptReads.at(-1), '/api/session/ses_A/message/' + messageId);
        receiptRecords.delete(messageId); interactions = [];
        assert.equal((await (await call('status', pending)).json()).status, 'delivered');
        assert.equal((await call('retry', pending)).status, 409);
        assert.equal(receiptReads.length, readBefore + 1); assert.equal(dispatches, before);
      }
    });
    await t.test('missing, wrong-id/role/session and non-exact prompt receipts never imply delivery or permit retry', async () => {
      const mismatches = [undefined, { id: 'msg_other' }, { type: 'assistant' }, { type: 'synthetic' }, { type: undefined },
        { sessionID: 'ses_OTHER' }, { sessionId: 'ses_OTHER' }, { text: 'Wrong prompt' }, { text: 'Synthetic exact receipt\n' }];
      for (const [index, mismatch] of mismatches.entries()) {
        const pending = { ...input, id: '00000000-0000-4000-8000-' + (200 + index).toString(16).padStart(12, '0') };
        await call('submit', pending); const before = dispatches;
        const messageId = 'msg_canvas' + pending.id.replaceAll('-', ''), prompt = 'Synthetic exact receipt';
        interactions = [{ id: pending.id, sessionKey: 'FAKE_SESSION', viewId, revision: 1, action: 'Choose', messageId, prompt, status: 'uncertain' }];
        if (mismatch) receiptRecords.set(messageId, { id: messageId, type: 'user', text: prompt, ...mismatch });
        const result = await (await call('status', pending)).json();
        assert.equal(result.status, 'uncertain'); assert.equal((await call('retry', pending)).status, 409);
        assert.equal(dispatches, before); receiptRecords.delete(messageId);
      }
      interactions = [];
    });
    await t.test('receipt lookup cannot follow a foreign Canvas session or arbitrary message id', async () => {
      for (const [index, change] of [{ sessionKey: 'OTHER_SESSION' }, { messageId: 'msg_arbitrary' }, { prompt: undefined }].entries()) {
        const pending = { ...input, id: '00000000-0000-4000-8000-' + (230 + index).toString(16).padStart(12, '0') };
        await call('submit', pending); const before = receiptReads.length;
        interactions = [{ id: pending.id, sessionKey: 'FAKE_SESSION', viewId, revision: 1, action: 'Choose', messageId: 'msg_canvas' + pending.id.replaceAll('-', ''), prompt: 'Synthetic exact receipt', status: 'uncertain', ...change }];
        assert.equal((await (await call('status', pending)).json()).status, 'uncertain');
        assert.equal(receiptReads.length, before);
      }
      interactions = [];
    });
    await t.test('review: legal data plus note fits, rejected input does not lock its UUID', async () => {
      const large = { ...input, id: '00000000-0000-4000-8000-000000000009', data: 'x'.repeat(30000), notes: 'n'.repeat(4000) };
      assert.equal((await call('submit', { ...large, data: 'x'.repeat(300000) })).status, 413);
      assert.equal((await call('submit', large)).status, 200);
      for (const code of [400, 413, 409]) {
        const rejected = { ...input, id: `00000000-0000-4000-8000-000000000${code}` };
        rejectCode = code; assert.equal((await call('submit', rejected)).status, code);
        assert.equal((await call('submit', { ...rejected, data: { corrected: true } })).status, 200);
      }
    });
    await t.test('review: page refresh learns latest and explicit reload preserves origin binding and unburned UUID', async () => {
      latest = 2;
      const refreshed = await (await call('page', { panelID: panel.panelID })).json();
      assert.equal(refreshed.latest, 2);
      const staleInput = { ...input, id: '00000000-0000-4000-8000-000000000008' };
      assert.equal((await call('submit', staleInput)).status, 409);
      const reloadedResponse = await call('resolve', { messageID: 'msg_A', blockOrdinal: 1, latest: true });
      assert.equal(reloadedResponse.status, 200); const reloaded = await reloadedResponse.json();
      assert.equal(reloaded.revision, 2); assert.equal(reloaded.viewId, viewId);
      assert.equal((await call('submit', { ...staleInput, panelID: reloaded.panelID })).status, 200);
    });
    latest = 1; rejectCode = 0; dispatches = 0;
    await t.test('lease change after host admission remains unknown, with its UUID retained', async () => {
      const crossing = { ...input, id: '00000000-0000-4000-8000-000000000007' };
      changeOnSubmit = true;
      assert.equal((await call('submit', crossing)).status, 503);
      generation = 'one';
      assert.equal((await call('submit', crossing)).status, 200);
      assert.equal(dispatches, 1);
    });
    dispatches = 0;
    latest = 2; assert.equal((await call('submit', input)).status, 409); latest = 1;
    for (const change of [{ action: 'x'.repeat(121) }, { data: 'x'.repeat(32001) }, { notes: 'x'.repeat(4001) }]) assert.equal((await call('submit', { ...input, ...change })).status, 400);
    assert.equal((await call('submit', { ...input, choiceID: 'go' })).status, 400);
    assert.equal((await (await call('submit', input)).json()).status, 'queued');
    await call('submit', input); assert.equal(dispatches, 1);
    for (const origin of [{ messageID: 'msg_B', blockOrdinal: 1 }, { messageID: 'msg_A', blockOrdinal: 2 }]) {
      const other = await (await call('resolve', origin)).json();
      assert.equal((await call('submit', { ...input, panelID: other.panelID })).status, 409);
    }
    assert.equal((await call('submit', { ...input, data: { choice: 'B' } })).status, 409);
    assert.equal((await call('retry', input)).status, 409);
    uncertain = true; const unknown = { ...input, id: '00000000-0000-4000-8000-000000000002' };
    assert.equal((await (await call('submit', unknown)).json()).status, 'uncertain');
    await call('submit', unknown); assert.equal(dispatches, 2); assert.equal((await call('retry', unknown)).status, 409);
    interactions = [{ id: input.id, viewId, revision: 1, action: 'Choose', status: 'unsent' }];
    assert.equal((await (await call('status', input)).json()).status, 'unsent');
    latest = 2; assert.equal((await call('retry', input)).status, 409); latest = 1;
    uncertain = false; await call('retry', input); assert.equal(dispatches, 3);
    changed = true; assert.equal((await call('submit', input)).status, 409); changed = false;
    generation = 'B'; assert.equal((await call('submit', input, 'one')).status, 409);
    generation = 'Aagain'; assert.equal((await call('submit', input)).status, 409);
  } finally { bridge.shutdown(); fake.closeAllConnections(); await new Promise(r => fake.close(r)); }
});
