import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { once } from 'node:events';
import { OpenChamberClient, discoverDesktop } from './oc-client.mjs';
import { createBridge } from './server.mjs';

const secret = 'oc_client_SYNTHETIC_NEVER_OUTPUT', replacement = 'oc_client_SYNTHETIC_REPLACEMENT';
const viewId = '11111111-1111-4111-8111-111111111111';
const listen = async s => { s.listen(0, '127.0.0.1'); await once(s, 'listening'); return s.address().port; };
const close = async s => { s.closeAllConnections(); await new Promise(resolve => s.close(resolve)); };

test('paired desktop transport and fail-closed lifecycle', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-oc-auth-'));
  const file = path.join(dir, 'client.json'), diagnostics = [], output = [], seen = [];
  let expected = secret, denied = '', rejectCode = 401, requireAuth = true, healthValid = true, clients;
  const interactions = [], receipts = new Map();
  let canvasDispatches = 0;
  const own = { id: 'own-id', clientKind: 'desktop', label: 'VoiceStack', deviceName: 'Voicestack' };
  clients = [own];
  const record = { id: 'msg_A', type: 'assistant', content: [
    { type: 'tool', id: 'tool_A', name: 'canvas_show', state: { status: 'completed',
      input: { format: 'openui', source: 'root = Stack([]);' },
      metadata: { viewId, revision: 1, truncated: false } } }
  ] };
  const handler = async (req, res) => {
    const route = req.url;
    if (route === '/health') {
      assert.ok(!req.headers.authorization, 'health must not receive bearer');
      res.end(JSON.stringify(healthValid ? { openchamberVersion: 'fake' } : { product: 'other' })); return;
    }
    if (route === '/v1/voices' || route === '/v1/audio/speech') {
      assert.ok(!req.headers.authorization, 'TTS must not receive any bearer');
      req.resume(); res.end(route === '/v1/voices' ? '[]' : 'synthetic audio'); return;
    }
    seen.push({ route, authorized: req.headers.authorization === `Bearer ${expected}`, anonymous: !req.headers.authorization });
    if ((requireAuth && req.headers.authorization !== `Bearer ${expected}`) || route === denied) {
      res.writeHead(rejectCode); res.end(JSON.stringify({ error: secret })); return;
    }
    if (route === '/api/client-auth/clients') { res.end(JSON.stringify({ clients })); return; }
    if (route === '/api/system/info') { res.end('{"runtime":"desktop"}'); return; }
    if (route.startsWith('/api/session?')) { res.end('{"data":[{"id":"ses_A","title":"Fixture"}]}'); return; }
    if (route === '/api/session/active') { res.end('{"data":{"ses_A":{}}}'); return; }
    if (route === '/api/session/ses_A') { res.end('{"id":"ses_A","location":{"directory":"/fixture"}}'); return; }
    if (route === '/api/session/ses_A/message/msg_A') { res.end(JSON.stringify(record)); return; }
    if (route.startsWith('/api/session/ses_A/message/msg_canvas')) {
      const receipt = receipts.get(route.split('/').at(-1));
      if (!receipt) res.writeHead(404);
      res.end(JSON.stringify(receipt ? { data: receipt } : { error: 'Synthetic missing receipt' })); return;
    }
    if (route.includes('/message?')) { res.end('{"data":[]}'); return; }
    if (route === '/api/event') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream' });
      res.end('data: {"type":"session.text.delta","data":{"sessionID":"ses_A","delta":"hello"}}\n\n'); return;
    }
    if (route === '/api/guests/agent-canvas/service/request') {
      const chunks = []; for await (const c of req) chunks.push(c);
      const envelope = JSON.parse(Buffer.concat(chunks)), inner = JSON.parse(envelope.body);
      let value;
      if (envelope.path === '/connect') value = { key: 'SYNTHETIC_VIEWER' };
      else if (inner.path === '/api/snapshot') value = { session: { key: 'SYNTHETIC_SESSION', sessionId: 'ses_A', directory: '/fixture' }, views: [{ id: viewId, latest: 1 }], interactions };
      else if (inner.path === '/api/submit') {
        canvasDispatches++;
        const messageId = 'msg_canvas' + inner.body.id.replaceAll('-', ''), prompt = 'Synthetic exact authenticated Canvas receipt';
        interactions.push({ ...inner.body, messageId, prompt, status: 'uncertain' });
        receipts.set(messageId, { id: messageId, type: 'user', text: prompt });
        value = { ...inner.body, status: 'queued', detail: 'Synthetic queued' };
      }
      else value = { sessionKey: 'SYNTHETIC_SESSION', number: 1, title: 'Fixture', summary: '', content: record.content[0].state.input };
      res.end(JSON.stringify({ status: 200, body: JSON.stringify(value) })); return;
    }
    if (route.includes('/prompt') || route.includes('/interrupt')) { req.resume(); res.end('{"ok":true}'); return; }
    res.writeHead(404); res.end('{}');
  };
  const fake = http.createServer((req, res) => { handler(req, res).catch(() => { res.destroy(); }); });
  let desktopPort = await listen(fake);
  const write = (token = expected) => {
    const tmp = file + '.new';
    fs.writeFileSync(tmp, JSON.stringify({ version: 1, clientId: own.id, clientKind: 'desktop', label: own.label,
      clientToken: token, enrolledOrigin: `http://127.0.0.1:${desktopPort}` }), { mode: 0o600 });
    fs.renameSync(tmp, file);
  };
  write();
  const client = new OpenChamberClient({ file, diagnostic: entry => diagnostics.push(entry) });
  const device = { deviceID: 'fixture', sessionID: 'ses_A', generation: 'one', mode: 'explicit' };
  const bridge = createBridge({ credentials: { device: () => device, save() {} }, discover: () => desktopPort,
    ocClient: client, ttsPort: desktopPort, asrPort: desktopPort, diagnostic: entry => diagnostics.push(entry) });
  const bridgePort = await listen(bridge);
  const call = async (route, data) => {
    const r = await fetch(`http://127.0.0.1:${bridgePort}/floating-voice` + route,
      { method: data === undefined ? 'GET' : 'POST', headers: { Authorization: 'Bearer phone-fixture',
        'X-FV-Generation': 'one', 'Content-Type': 'application/json' }, body: data === undefined ? undefined : JSON.stringify(data) });
    const text = await r.text(); output.push(text); return { status: r.status, text };
  };
  let second;
  try {
    await t.test('own record matches; extra, revoked, wrong-id and wrong-kind records fail', async () => {
      assert.equal((await client.check(() => desktopPort)).ownRecordMatches, true);
      for (const value of [[], [own, own], [{ ...own, revokedAt: 'now' }], [{ ...own, id: 'other' }], [{ ...own, clientKind: 'mobile' }]]) {
        clients = value; assert.equal((await client.check(() => desktopPort)).ownRecordMatches, false);
      }
      clients = [own];
    });
    await t.test('JSON GETs, prompt, interrupt, SSE and Canvas require and receive bearer', async () => {
      for (const route of ['/v1/health', '/v1/sessions', '/v1/sessions/ses_A/messages', '/v1/sessions/ses_A/state']) {
        assert.equal((await call(route)).status, 200);
      }
      assert.equal((await call('/v1/sessions/ses_A/prompt', { text: 'hello' })).status, 200);
      assert.equal((await call('/v1/sessions/ses_A/interrupt', {})).status, 200);
      const events = await call('/v1/sessions/ses_A/events'); assert.equal(events.status, 200); assert.ok(events.text.includes('hello'));
      assert.equal((await call('/v1/sessions/ses_A/canvas-show/resolve', { messageID: 'msg_A', blockOrdinal: 0 })).status, 200);
      assert.ok(seen.every(r => r.authorized), 'every desktop request is authenticated');
    });
    await t.test('durable receipt GET and every Canvas host request carry verified desktop bearer', async () => {
      const panel = JSON.parse((await call('/v1/sessions/ses_A/canvas-show/resolve', { messageID: 'msg_A', blockOrdinal: 0 })).text);
      assert.equal((await call('/v1/sessions/ses_A/canvas-show/page', { panelID: panel.panelID, offset: 0 })).status, 200);
      const input = { panelID: panel.panelID, id: '00000000-0000-4000-8000-0000000000a1', action: 'Choose', data: null, notes: '' };
      const before = canvasDispatches;
      assert.equal(JSON.parse((await call('/v1/sessions/ses_A/canvas-show/submit', input)).text).status, 'queued');
      const result = await call('/v1/sessions/ses_A/canvas-show/status', input);
      assert.equal(result.status, 200); assert.equal(JSON.parse(result.text).status, 'delivered');
      const receiptPath = '/api/session/ses_A/message/msg_canvas' + input.id.replaceAll('-', '');
      const receiptCalls = seen.filter(r => r.route === receiptPath);
      assert.equal(receiptCalls.length, 1); assert.ok(receiptCalls.every(r => r.authorized && !r.anonymous));
      assert.equal(canvasDispatches, before + 1);
      assert.ok(seen.every(r => r.authorized), 'no anonymous Canvas or desktop call');
    });
    await t.test('401/403 on receipt GET stays uncertain, no fallback, no resubmit and no secret disclosure', async () => {
      for (const code of [401, 403]) for (const [index, hostStatus] of ['queued', 'sending', 'uncertain'].entries()) {
        const panel = JSON.parse((await call('/v1/sessions/ses_A/canvas-show/resolve', { messageID: 'msg_A', blockOrdinal: 0 })).text);
        const input = { panelID: panel.panelID, id: '00000000-0000-4000-8000-' + (code * 4 + index).toString(16).padStart(12, '0'), action: 'Choose', data: null, notes: '' };
        await call('/v1/sessions/ses_A/canvas-show/submit', input);
        interactions.at(-1).status = hostStatus;
        const before = canvasDispatches, start = seen.length;
        denied = '/api/session/ses_A/message/msg_canvas' + input.id.replaceAll('-', ''); rejectCode = code;
        const result = await call('/v1/sessions/ses_A/canvas-show/status', input);
        assert.equal(result.status, 503);
        assert.match(result.text, /Mac connection needs re-pairing/);
        assert.ok(!result.text.includes(secret));
        assert.equal(seen.slice(start).filter(r => r.route === denied).length, 1, 'receipt read is never retried anonymously');
        assert.ok(seen.slice(start).every(r => r.authorized));
        assert.equal((await call('/v1/sessions/ses_A/canvas-show/retry', input)).status, 409);
        assert.equal(canvasDispatches, before);
        denied = ''; rejectCode = 401;
      }
    });
    await t.test('own-record authentication rejection also fails closed', async () => {
      denied = '/api/client-auth/clients';
      await assert.rejects(client.check(() => desktopPort), { status: 503, category: 'auth_rejected' });
      denied = '';
    });
    await t.test('paired client bearer is never sent to ASR or TTS', async () => {
      assert.equal((await call('/tts/v1/voices')).status, 200);
      assert.equal((await call('/asr/health')).status, 200);
      assert.equal((await call('/tts/health')).status, 200);
      assert.equal((await call('/tts/v1/audio/speech', { model: 'default', voice: 'default', input: 'Synthetic only', response_format: 'wav' })).status, 200);
    });
    await t.test('port rediscovery survives host restart', async () => {
      second = http.createServer((req, res) => { handler(req, res).catch(() => res.destroy()); });
      desktopPort = await listen(second);
      await close(fake);
      assert.equal((await call('/v1/health')).status, 200);
      assert.equal((await call('/v1/sessions/ses_A/events')).status, 200);
    });
    await t.test('401/403 on every transport returns calm 503, no fallback and one forced binding reload', async () => {
      const original = client.load.bind(client); let reloads = 0;
      client.load = force => { if (force) reloads++; return original(force); };
      for (const code of [401, 403]) {
        rejectCode = code;
        for (const [upstreamRoute, phoneRoute, data] of [
          ['/api/system/info', '/v1/health'],
          ['/api/session/ses_A/message?limit=100&order=asc', '/v1/sessions/ses_A/messages'],
          ['/api/event', '/v1/sessions/ses_A/events'],
          ['/api/session/ses_A/prompt', '/v1/sessions/ses_A/prompt', { text: 'hello' }],
          ['/api/session/ses_A/interrupt?resume=false', '/v1/sessions/ses_A/interrupt', {}],
          ['/api/guests/agent-canvas/service/request', '/v1/sessions/ses_A/canvas-show/resolve', { messageID: 'msg_A', blockOrdinal: 0 }]
        ]) {
          denied = upstreamRoute; const before = seen.length, reloaded = reloads;
          const response = await call(phoneRoute, data);
          assert.equal(response.status, 503); assert.ok(response.text.includes('Mac connection needs re-pairing'));
          assert.equal(reloads, reloaded + 1);
          assert.equal(seen.slice(before).filter(r => r.route === denied).length, 1, 'no retry');
          assert.ok(seen.slice(before).every(r => r.authorized), 'no unauthenticated fallback');
        }
      }
      denied = ''; rejectCode = 401;
      assert.ok(diagnostics.some(e => e.category === 'auth_rejected'));
    });
    await t.test('atomic re-pair binding replacement is read without process restart', async () => {
      expected = replacement; write(); assert.equal((await call('/v1/health')).status, 200);
    });
    await t.test('no bearer to a non-OpenChamber or non-loopback host', async () => {
      healthValid = false; const before = seen.length;
      assert.equal((await call('/v1/health')).status, 503); assert.equal(seen.length, before);
      healthValid = true;
      for (const origin of ['http://192.0.2.1:1234', 'http://localhost:1234', 'https://127.0.0.1:1234', 'http://user@127.0.0.1:1234']) {
        await assert.rejects(client.prepareOrigin(origin), { status: 503 });
      }
    });
    await t.test('removing an enrolled binding fails closed; never downgrades', async () => {
      fs.unlinkSync(file); const before = seen.length;
      assert.equal((await call('/v1/health')).status, 503); assert.equal(seen.length, before); write();
    });
    await t.test('bad modes and symlinks refuse before sending bearer', async () => {
      fs.chmodSync(file, 0o644); await assert.rejects(client.prepare(desktopPort), { status: 503 }); fs.chmodSync(file, 0o600);
      fs.renameSync(file, file + '.saved'); fs.symlinkSync(file + '.saved', file);
      await assert.rejects(client.prepare(desktopPort), { status: 503 }); fs.unlinkSync(file); fs.renameSync(file + '.saved', file);
      fs.chmodSync(dir, 0o755); await assert.rejects(client.prepare(desktopPort), { status: 503 }); fs.chmodSync(dir, 0o700);
    });
    await t.test('without a binding original unauthenticated loopback behavior remains', async () => {
      requireAuth = false;
      const absent = new OpenChamberClient({ file: path.join(dir, 'absent.json'), diagnostic: e => diagnostics.push(e) });
      const unauth = createBridge({ credentials: { device: () => device }, discover: () => desktopPort, ocClient: absent });
      const port = await listen(unauth);
      try {
        const response = await fetch(`http://127.0.0.1:${port}/floating-voice/v1/health`);
        output.push(await response.text()); assert.equal(response.status, 200);
        assert.ok(seen.at(-1).anonymous);
        assert.ok(diagnostics.some(e => e.category === 'binding_absent'));
      } finally { unauth.shutdown(); }
    });
    await t.test('tokens never appear in phone output, diagnostics or public errors', async () => {
      const text = JSON.stringify({ diagnostics, output });
      assert.ok(!text.includes(secret) && !text.includes(replacement), 'no credential output');
    });
  } finally {
    bridge.shutdown(); if (second) await close(second); if (fake.listening) await close(fake);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('desktopLocalPort is re-read, using only that discovery setting', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fv-oc-discovery-')), oldHome = process.env.HOME;
  try {
    process.env.HOME = dir; fs.mkdirSync(path.join(dir, '.config/openchamber'), { recursive: true });
    const file = path.join(dir, '.config/openchamber/settings.json');
    for (const port of [12345, 23456]) { fs.writeFileSync(file, JSON.stringify({ desktopLocalPort: port })); assert.equal(discoverDesktop(), port); }
  } finally { process.env.HOME = oldHome; fs.rmSync(dir, { recursive: true, force: true }); }
});
